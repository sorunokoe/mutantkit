#include "mutantkit_protocol_v3.h"

#include <dlfcn.h>
#include <fcntl.h>
#include <inttypes.h>
#include <libkern/OSByteOrder.h>
#include <mach-o/loader.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct mutantkit_unit_descriptor_v3 {
    bool valid;
    uint8_t source_embedding_id[MUTANTKIT_V3_DIGEST_SIZE];
    uint8_t compilation_unit_id[MUTANTKIT_V3_DIGEST_SIZE];
    uint8_t image_uuid[MUTANTKIT_V3_UUID_SIZE];
};

// MARK: - Environment (token + run ID), parsed once lazily

typedef struct {
    bool has_token;
    uint64_t namespace_;
    uint32_t local_index;
    bool has_run_id;
    uint8_t run_id[MUTANTKIT_V3_RUN_ID_SIZE];
} mutantkit_v3_environment_t;

static pthread_once_t mutantkit_v3_environment_once = PTHREAD_ONCE_INIT;
static mutantkit_v3_environment_t mutantkit_v3_environment = {false, 0, 0, false, {0}};
static atomic_uint_fast64_t mutantkit_v3_sequence = 0;
// Only the first hit in this process is ever recorded, matching v2's own
// "hit at all, not hit count" scoring semantics -- a mutant that runs in a
// loop must not inflate its own evidence.
static atomic_bool mutantkit_v3_hit_recorded = false;

static bool mutantkit_v3_decode_hex(const char *hex, uint8_t *out, size_t out_length) {
    if (hex == NULL) {
        return false;
    }
    if (strlen(hex) != out_length * 2) {
        return false;
    }
    for (size_t i = 0; i < out_length; i++) {
        unsigned int byte;
        if (sscanf(hex + i * 2, "%2x", &byte) != 1) {
            return false;
        }
        out[i] = (uint8_t)byte;
    }
    return true;
}

/// Same parse-once-lazily reasoning as v2's `mutantkit_parse_token`: a
/// harness that sets these via `posix_spawn`/`Process` (after the child
/// image is mapped, before its first line of Swift runs) is still seen
/// correctly regardless of exactly when a C runtime constructor happens to
/// run relative to environment setup -- so this parses on first use, not
/// at image load time.
static void mutantkit_v3_parse_environment(void) {
    const char *token_raw = getenv("MUTANTKIT_SCHEMATA_TOKEN");
    if (token_raw != NULL) {
        uint64_t requested_namespace = 0;
        uint32_t requested_local_index = 0;
        int consumed = 0;
        // "%n" plus an explicit end-of-string check: sscanf happily accepts
        // "42:3garbage" as two valid conversions, silently ignoring the
        // trailing bytes -- a malformed token must be rejected outright.
        if (sscanf(token_raw, "%" SCNu64 ":%" SCNu32 "%n", &requested_namespace, &requested_local_index, &consumed) == 2
            && token_raw[consumed] == '\0'
            // localIndex 0 is the reserved inactive sentinel (see
            // SchemataSelectorToken) -- never a real token.
            && requested_local_index != 0) {
            mutantkit_v3_environment.namespace_ = requested_namespace;
            mutantkit_v3_environment.local_index = requested_local_index;
            mutantkit_v3_environment.has_token = true;
        }
    }

    const char *run_id_hex = getenv("MUTANTKIT_SCHEMATA_RUN_ID");
    if (run_id_hex != NULL) {
        mutantkit_v3_environment.has_run_id =
            mutantkit_v3_decode_hex(run_id_hex, mutantkit_v3_environment.run_id, MUTANTKIT_V3_RUN_ID_SIZE);
    }
}

// MARK: - Per-compilation-unit image identity

/// Walks `header`'s load commands for `LC_UUID` and copies its 16 raw
/// bytes into `out`. Returns `false` if `header` is not a 64-bit Mach-O
/// image this runtime recognizes, or no `LC_UUID` command is present (an
/// exotic unsigned/hand-linked binary) -- a real, honest failure, never a
/// fabricated UUID.
static bool mutantkit_v3_uuid_from_header(const struct mach_header_64 *header, uint8_t *out) {
    if (header->magic != MH_MAGIC_64) {
        return false;
    }

    const uint8_t *cursor = (const uint8_t *)header + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *cmd = (const struct load_command *)cursor;
        // A corrupt or truncated header could report a cmdsize of 0, which
        // would loop forever advancing nowhere.
        if (cmd->cmdsize == 0) {
            return false;
        }
        if (cmd->cmd == LC_UUID) {
            const struct uuid_command *uuid_cmd = (const struct uuid_command *)cmd;
            memcpy(out, uuid_cmd->uuid, MUTANTKIT_V3_UUID_SIZE);
            return true;
        }
        cursor += cmd->cmdsize;
    }
    return false;
}

// MARK: - Transcript writing

static void mutantkit_v3_write_record(
    mutantkit_event_type_t event_type, const mutantkit_unit_descriptor_v3_t *descriptor, uint64_t namespace_value,
    uint32_t local_index
) {
    if (!mutantkit_v3_environment.has_run_id) {
        // A record with no run ID cannot be safely matched to the run
        // that expected it later -- the same fail-closed reasoning v2
        // applied to a missing run nonce. A harness that forgot to set
        // MUTANTKIT_SCHEMATA_RUN_ID gets no evidence at all, not evidence a
        // wrong-run match could later credit to the wrong run.
        return;
    }
    const char *path = getenv("MUTANTKIT_SCHEMATA_TRANSCRIPT_PATH");
    if (path == NULL) {
        return;
    }

    mutantkit_event_record_v3_t record;
    memset(&record, 0, sizeof(record));
    record.magic_be = OSSwapHostToBigInt32(MUTANTKIT_V3_MAGIC);
    record.record_size_be = OSSwapHostToBigInt16((uint16_t)sizeof(record));
    record.protocol_version_be = OSSwapHostToBigInt16((uint16_t)MUTANTKIT_V3_PROTOCOL_VERSION);
    record.event_type = (uint8_t)event_type;
    memcpy(record.run_id, mutantkit_v3_environment.run_id, MUTANTKIT_V3_RUN_ID_SIZE);
    memcpy(record.source_embedding_id, descriptor->source_embedding_id, MUTANTKIT_V3_DIGEST_SIZE);
    memcpy(record.compilation_unit_id, descriptor->compilation_unit_id, MUTANTKIT_V3_DIGEST_SIZE);
    record.namespace_be = OSSwapHostToBigInt64(namespace_value);
    record.local_index_be = OSSwapHostToBigInt32(local_index);
    record.process_id_be = OSSwapHostToBigInt32((int32_t)getpid());
    record.sequence_be = OSSwapHostToBigInt64(atomic_fetch_add(&mutantkit_v3_sequence, 1) + 1);
    memcpy(record.image_uuid, descriptor->image_uuid, MUTANTKIT_V3_UUID_SIZE);
    record.runtime_abi_be = OSSwapHostToBigInt32(MUTANTKIT_V3_RUNTIME_ABI_VERSION);

    // Owner-only: this file records per-run observability data (run ID,
    // PID, digests) with no reason to be group/other-readable.
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd < 0) {
        return;
    }
    // A single write(2) of one fixed-size record -- POSIX guarantees this
    // does not interleave with a concurrent writer's own single small
    // write(2) on the same file, matching v2's own reasoning for why no
    // additional lock is needed.
    ssize_t written = write(fd, &record, sizeof(record));
    (void)written; // Best-effort: a failed/partial write means a missed
                   // record, which a host already treats as "no chain
                   // proven" rather than a fabricated success.
    close(fd);
}

// MARK: - Image load

__attribute__((constructor)) static void mutantkit_v3_record_image_loaded(void) {
    pthread_once(&mutantkit_v3_environment_once, mutantkit_v3_parse_environment);
    if (!mutantkit_v3_environment.has_token) {
        return;
    }

    Dl_info info;
    if (dladdr((const void *)&mutantkit_v3_record_image_loaded, &info) == 0 || info.dli_fbase == NULL) {
        return;
    }
    mutantkit_unit_descriptor_v3_t descriptor;
    memset(&descriptor, 0, sizeof(descriptor));
    if (!mutantkit_v3_uuid_from_header((const struct mach_header_64 *)info.dli_fbase, descriptor.image_uuid)) {
        return;
    }
    descriptor.valid = true;
    mutantkit_v3_write_record(
        MUTANTKIT_EVENT_LOADED, &descriptor, mutantkit_v3_environment.namespace_, mutantkit_v3_environment.local_index
    );
}

// MARK: - Public API

const mutantkit_unit_descriptor_v3_t *mutantkit_register_unit_v3(
    const char *source_embedding_hex, const char *compilation_unit_hex
) {
    pthread_once(&mutantkit_v3_environment_once, mutantkit_v3_parse_environment);

    mutantkit_unit_descriptor_v3_t *descriptor = calloc(1, sizeof(mutantkit_unit_descriptor_v3_t));
    if (descriptor == NULL) {
        return NULL;
    }

    if (!mutantkit_v3_decode_hex(source_embedding_hex, descriptor->source_embedding_id, MUTANTKIT_V3_DIGEST_SIZE)
        || !mutantkit_v3_decode_hex(compilation_unit_hex, descriptor->compilation_unit_id, MUTANTKIT_V3_DIGEST_SIZE)) {
        free(descriptor);
        return NULL;
    }

    // dladdr on the caller's own return address -- not this function's own
    // code, unlike v2's `dladdr`-on-its-own-function technique -- resolves
    // to whichever image the *calling compilation unit* actually lives in
    // (ADR-0006 Finding 2's fix). A statically-linked runtime otherwise has
    // no way to tell "the image containing runtime code" apart from "the
    // image the mutation site was actually compiled into" once more than
    // one image can be involved.
    void *caller = __builtin_return_address(0);
    Dl_info info;
    if (dladdr(caller, &info) == 0 || info.dli_fbase == NULL) {
        free(descriptor);
        return NULL;
    }
    if (!mutantkit_v3_uuid_from_header((const struct mach_header_64 *)info.dli_fbase, descriptor->image_uuid)) {
        free(descriptor);
        return NULL;
    }

    descriptor->valid = true;
    // Fires on every successful registration of a compilation unit whose
    // process actually requested a token -- a host can tell exactly which
    // compilation units actually loaded, independent of whether their
    // mutated site is ever reached (the same gap v2's startup event closed,
    // now scoped per compilation unit instead of per process/image).
    // Carries the process's own requested token, matching v2's STARTUP
    // event semantics -- not a literal (0, 0), which would encode the
    // reserved "no token" sentinel into a record a host parses expecting a
    // real token, and would fire even for a process that requested nothing
    // at all (v2 skipped writing STARTUP in exactly that case).
    if (mutantkit_v3_environment.has_token) {
        mutantkit_v3_write_record(
            MUTANTKIT_EVENT_STARTUP, descriptor, mutantkit_v3_environment.namespace_, mutantkit_v3_environment.local_index
        );
    }

    return descriptor;
}

bool mutantkit_is_active_v3(const mutantkit_unit_descriptor_v3_t *descriptor, uint64_t namespace_value, uint32_t local_index) {
    if (descriptor == NULL || !descriptor->valid) {
        return false;
    }

    pthread_once(&mutantkit_v3_environment_once, mutantkit_v3_parse_environment);

    if (!mutantkit_v3_environment.has_token) {
        return false;
    }
    if (mutantkit_v3_environment.namespace_ != namespace_value || mutantkit_v3_environment.local_index != local_index) {
        return false;
    }

    // atomic_exchange returns the *previous* value, so this records
    // exactly once even if many threads reach an active site at once.
    if (!atomic_exchange(&mutantkit_v3_hit_recorded, true)) {
        mutantkit_v3_write_record(MUTANTKIT_EVENT_HIT, descriptor, namespace_value, local_index);
    }
    return true;
}
