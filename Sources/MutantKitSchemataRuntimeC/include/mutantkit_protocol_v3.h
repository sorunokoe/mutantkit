#ifndef MUTANTKIT_PROTOCOL_V3_H
#define MUTANTKIT_PROTOCOL_V3_H

#include <stdbool.h>
#include <stdint.h>

/// ADR-0006 Stage 2: a fixed-length binary protocol replacing the v2 text
/// format entirely (no v2 parsing path is kept alive alongside this one in
/// production once the lowerer/collector cut over — see the doc comments
/// on `mutantkit_register_unit_v3`/`mutantkit_is_active_v3` below).
///
/// This header is the *only* specification of the wire format: both this
/// C runtime and the Swift-side host collector (a later stage-2 task)
/// `import`/parse against these exact field offsets, so a field cannot be
/// added, removed, or reordered on one side without the other failing to
/// build or to parse — unlike v2's hand-maintained parallel text format,
/// where the two sides could silently drift.
///
/// Every multi-byte integer field is big-endian ("network byte order"),
/// named with a `_be` suffix, so the format itself does not depend on
/// which architecture produced it — this runtime and its host currently
/// only ever run on little-endian Apple silicon/Intel, but the wire format
/// should not quietly assume that stays true forever.
#define MUTANTKIT_V3_MAGIC 0x4D4B5633U /* "MKV3" */
#define MUTANTKIT_V3_PROTOCOL_VERSION 3U
#define MUTANTKIT_V3_RUNTIME_ABI_VERSION 1U

#define MUTANTKIT_V3_DIGEST_SIZE 32U /* a SHA-256 digest's raw bytes */
#define MUTANTKIT_V3_UUID_SIZE 16U /* a Mach-O LC_UUID's raw bytes */
#define MUTANTKIT_V3_RUN_ID_SIZE 16U /* a RunID's raw bytes */

typedef enum {
    MUTANTKIT_EVENT_STARTUP = 1,
    MUTANTKIT_EVENT_HIT = 2,
    /// Written once per image, at load time, by this runtime's own
    /// constructor -- proof the runtime was linked into and loaded by the
    /// test process with this run's token, independent of whether any
    /// mutated site ever executes. Lets a host tell "the mutated code was
    /// never reached" apart from "the runtime never ran at all". Its
    /// digest fields are zero: it belongs to an image, not a compilation
    /// unit.
    MUTANTKIT_EVENT_LOADED = 3
} mutantkit_event_type_t;

#pragma pack(push, 1)
/// One fixed-size record — a STARTUP or a HIT, distinguished by
/// `event_type`. `record_size_be` is included so a host reading a
/// transcript file can detect a size mismatch (a stale prebuilt runtime
/// linked against a newer host, or vice versa) and refuse to parse rather
/// than silently misreading a reordered/resized field as something else —
/// the same defense `MUTANTKIT_PROTOCOL_VERSION` served in v2, now checked
/// structurally instead of trusted from a text field.
typedef struct {
    uint32_t magic_be;
    uint16_t record_size_be;
    uint16_t protocol_version_be;
    uint8_t event_type;
    uint8_t reserved[3];

    uint8_t run_id[MUTANTKIT_V3_RUN_ID_SIZE];
    uint8_t source_embedding_id[MUTANTKIT_V3_DIGEST_SIZE];
    uint8_t compilation_unit_id[MUTANTKIT_V3_DIGEST_SIZE];

    uint64_t namespace_be;
    uint32_t local_index_be;
    int32_t process_id_be;
    uint64_t sequence_be;

    uint8_t image_uuid[MUTANTKIT_V3_UUID_SIZE];
    uint32_t runtime_abi_be;
} mutantkit_event_record_v3_t;
#pragma pack(pop)

/// A layout change here must be intentional and must bump
/// `MUTANTKIT_V3_PROTOCOL_VERSION` — this assertion catches an accidental
/// field addition/removal/reorder at compile time, on either side that
/// includes this header.
_Static_assert(sizeof(mutantkit_event_record_v3_t) == 136, "mutantkit_event_record_v3_t layout changed");

/// Opaque per-compilation-unit identity, registered once at process
/// startup by the generated preamble the lowerer emits at each mutated
/// compilation unit (ADR-0006 Finding 2's fix): unlike v2's single
/// process-wide `dladdr`-derived image UUID, this ties a HIT event's
/// identity to the specific compilation unit whose call site actually ran,
/// independent of which Mach-O image happens to link this runtime.
typedef struct mutantkit_unit_descriptor_v3 mutantkit_unit_descriptor_v3_t;

/// Registers one compilation unit's identity and writes its STARTUP
/// record, unconditionally, the moment this call returns successfully —
/// unlike v2's constructor-fired-once-per-image startup event, this fires
/// once per compilation unit, so a host can tell exactly which
/// compilation units actually loaded versus which were planned but never
/// linked into anything that ran.
///
/// `source_embedding_hex`/`compilation_unit_hex` are 64-character
/// lowercase-hex `SHA256Digest`/`CompilationUnitID` strings (Swift-side
/// types), generated as string literals into the lowered source itself —
/// see the generated preamble's own doc comment (a later stage-2 task).
///
/// Returns `NULL` on any failure (malformed hex, no `LC_UUID` found for
/// the caller's own image) — `mutantkit_is_active_v3` treats a `NULL`
/// descriptor exactly like an inactive token: it returns `false`,
/// preserving the original, unmutated behavior exactly. A failed
/// registration is a real, discoverable fact (no STARTUP record for that
/// compilation unit ever appears), never a silent, differently-wrong
/// success.
const mutantkit_unit_descriptor_v3_t *mutantkit_register_unit_v3(
    const char *source_embedding_hex, const char *compilation_unit_hex
);

/// The runtime half of a schemata mutation's selector, v3. `descriptor`
/// must be whatever `mutantkit_register_unit_v3` returned for the calling
/// compilation unit — a `NULL` descriptor (a failed registration) always
/// returns `false`, matching original behavior.
///
/// On the first match against this process's requested token
/// (`MUTANTKIT_SCHEMATA_TOKEN`, unchanged format from v2:
/// `"<namespace>:<localIndex>"` decimal), records one HIT record —
/// carrying `descriptor`'s own identity, so the event traces to the exact
/// compilation unit whose call site reached it, not merely "some image
/// that links this runtime." Subsequent activations of any site in this
/// process are not re-recorded, matching v2's own "hit at all, not hit
/// count" scoring semantics.
bool mutantkit_is_active_v3(
    const mutantkit_unit_descriptor_v3_t *descriptor, uint64_t namespace_value, uint32_t local_index
);

#endif
