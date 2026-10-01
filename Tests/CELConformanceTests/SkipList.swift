// skip.txt and passing.txt: the two checked-in lists that gate the conformance suite.

import Foundation

/// One skip.txt entry.
///
/// Format, one entry per line, `#` starts a comment line:
///
///     <path> | <modes> | <reason> | <issue>
///
/// - `path` is a test name prefix on `/` boundaries, as in cel-go's `--skip_tests`: `file`, `file/section`
///   or `file/section/test`.
/// - `modes` is `checked`, `parse-only` or `*`.
/// - `reason` says why the test cannot pass; `issue` links the tracking issue. Both are required.
struct SkipEntry: Sendable, Equatable {
  var path: String
  var modes: Set<ConformanceMode>
  var reason: String
  var issue: String
  var line: Int

  func matches(_ name: String, mode: ConformanceMode) -> Bool {
    guard modes.contains(mode), name.hasPrefix(path) else { return false }
    let rest = name.dropFirst(path.count)
    return rest.isEmpty || rest.hasPrefix("/")
  }
}

struct SkipList: Sendable {
  var entries: [SkipEntry]

  static func parse(_ text: String) throws -> SkipList {
    var entries: [SkipEntry] = []
    for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") { continue }
      let fields = line.split(separator: "|", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
      guard fields.count == 4 else {
        throw HarnessError("skip.txt:\(index + 1): want 4 '|'-separated fields, got \(fields.count)")
      }
      let modes: Set<ConformanceMode>
      switch fields[1] {
      case "*": modes = Set(ConformanceMode.allCases)
      default:
        guard let mode = ConformanceMode(rawValue: fields[1]) else {
          throw HarnessError("skip.txt:\(index + 1): unknown mode '\(fields[1])'")
        }
        modes = [mode]
      }
      guard fields[0].isEmpty == false, fields[2].isEmpty == false, fields[3].isEmpty == false else {
        throw HarnessError("skip.txt:\(index + 1): path, reason and issue are all required")
      }
      entries.append(SkipEntry(path: fields[0], modes: modes, reason: fields[2], issue: fields[3], line: index + 1))
    }
    return SkipList(entries: entries)
  }

  static func load() throws -> SkipList {
    try parse(String(contentsOf: SpecPaths.skipList, encoding: .utf8))
  }

  func entry(for name: String, mode: ConformanceMode) -> SkipEntry? {
    entries.first { $0.matches(name, mode: mode) }
  }
}

/// A test in one mode, as written in passing.txt (`<mode> <name>`).
struct PassingKey: Hashable, Comparable, Sendable {
  var mode: ConformanceMode
  var name: String

  var line: String { "\(mode.rawValue) \(name)" }

  static func < (a: PassingKey, b: PassingKey) -> Bool {
    (a.name, a.mode.rawValue) < (b.name, b.mode.rawValue)
  }
}

/// The ratchet: tests expected to pass. A listed test that fails is a regression; a passing test that is not
/// listed is reported as newly passing. `CEL_CONFORMANCE_UPDATE=1` rewrites the file from the current results.
enum PassingList {
  static let header = """
    # Conformance tests expected to pass, one "<mode> <file/section/test>" per line, sorted by name.
    # A listed test that fails fails the suite. Regenerate with:
    #   CEL_CONFORMANCE_UPDATE=1 swift test --filter CELConformanceTests
    """

  static func parse(_ text: String) throws -> Set<PassingKey> {
    var out: Set<PassingKey> = []
    for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") { continue }
      guard let space = line.firstIndex(of: " "),
        let mode = ConformanceMode(rawValue: String(line[..<space]))
      else {
        throw HarnessError("passing.txt:\(index + 1): want '<mode> <name>', got '\(line)'")
      }
      out.insert(PassingKey(mode: mode, name: String(line[line.index(after: space)...])))
    }
    return out
  }

  static func load() throws -> Set<PassingKey> {
    guard FileManager.default.fileExists(atPath: SpecPaths.passingList.path) else { return [] }
    return try parse(String(contentsOf: SpecPaths.passingList, encoding: .utf8))
  }

  static func render(_ keys: Set<PassingKey>) -> String {
    ([header] + keys.sorted().map(\.line)).joined(separator: "\n") + "\n"
  }

  static var updateRequested: Bool {
    ProcessInfo.processInfo.environment["CEL_CONFORMANCE_UPDATE"] == "1"
  }
}

struct HarnessError: Error, CustomStringConvertible {
  var description: String
  init(_ description: String) { self.description = description }
}
