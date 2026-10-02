@testable import AppleBuildAdapters
import Foundation
import MutationPlanner
import Testing

@Suite("SwiftPMTargetResolver.targetInfo(from:projectRoot:pathPrefix:)")
struct SwiftPMTargetResolverTargetInfoTests {
    private static let describeJSON = """
    {
      "targets": [
        {
          "name": "Core", "path": "Sources/Core", "sources": ["Presentation/LoadingState.swift"],
          "type": "library", "product_memberships": ["Core"]
        },
        {
          "name": "Root", "path": ".", "sources": ["Root.swift"],
          "type": "library", "product_memberships": ["Root"]
        }
      ],
      "products": []
    }
    """

    private static func targetInfo(pathPrefix: String?) throws -> [String: [SchemataTargetInfo]] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(SwiftPMTargetResolver.DescribeOutput.self, from: Data(describeJSON.utf8))
        return SwiftPMTargetResolver.targetInfo(
            from: decoded, projectRoot: URL(fileURLWithPath: "/tmp/umbrella/Foundation/Core"), pathPrefix: pathPrefix
        )
    }

    @Test("Keys are package-relative when the package is the project root")
    func packageRelativeKeysWithoutPrefix() throws {
        let info = try Self.targetInfo(pathPrefix: nil)

        #expect(Set(info.keys) == ["Sources/Core/Presentation/LoadingState.swift", "Root.swift"])
    }

    @Test("Keys are rebased onto the project root for a package nested under it")
    func keysRebasedForNestedPackage() throws {
        let info = try Self.targetInfo(pathPrefix: "Foundation/Core")

        #expect(Set(info.keys) == [
            "Foundation/Core/Sources/Core/Presentation/LoadingState.swift",
            "Foundation/Core/Root.swift"
        ])
        #expect(info["Foundation/Core/Sources/Core/Presentation/LoadingState.swift"]?.map(\.target) == ["Core"])
    }
}
