import Foundation

@testable import CELPolicy

/// Locates cel-go's test data in the `third_party/cel-go` submodule.
enum Testdata {
  static let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

  static let celGo = repositoryRoot.appendingPathComponent("third_party/cel-go")

  /// The `policy/testdata` directory.
  static let policyTestdata = celGo.appendingPathComponent("policy/testdata")

  /// Reads a file relative to `third_party/cel-go`.
  static func read(_ relativePath: String) throws -> String {
    try String(contentsOf: celGo.appendingPathComponent(relativePath), encoding: .utf8)
  }

  /// Reads `policy/testdata/<name>/policy.yaml` as a source described the way cel-go's tests
  /// describe it (`testdata/<name>/policy.yaml`), so error messages match.
  static func policySource(_ name: String) throws -> PolicySource {
    let description = "testdata/\(name)/policy.yaml"
    return PolicySource(try read("policy/\(description)"), description: description)
  }

  /// Names of the `policy/testdata` subdirectories.
  static func policyTestNames() -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: policyTestdata.path)) ?? []
    return names.filter { !$0.hasPrefix(".") }.sorted()
  }

  /// Paths, relative to `third_party/cel-go`, of the files under `directory` with one of the
  /// extensions.
  static func files(under directory: String, extensions: Set<String>) -> [String] {
    let base = celGo.appendingPathComponent(directory)
    guard let enumerator = FileManager.default.enumerator(atPath: base.path) else { return [] }
    var result: [String] = []
    for case let path as String in enumerator where extensions.contains((path as NSString).pathExtension) {
      result.append("\(directory)/\(path)")
    }
    return result.sorted()
  }
}
