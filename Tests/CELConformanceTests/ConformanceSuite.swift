// Runs every cel-spec simple test through the runner in each applicable mode and collects the results.

import CELSpecProtos
import Foundation

/// Status of one test in one mode, as written to the results file.
enum Status: String, Codable, Sendable {
  case pass
  case fail
  case notImplemented = "not-implemented"
  case skip
  /// The mode does not apply to the test (see `ConformanceMode`).
  case notApplicable = "n/a"
}

struct ModeResult: Codable, Sendable {
  var status: Status
  var detail: String?
}

struct TestResult: Codable, Sendable {
  /// `file/section/test`.
  var name: String
  /// The textproto file name without extension.
  var file: String
  /// The section and test names as written in the file (`name` may carry a `#NN` duplicate suffix).
  var section: String
  var test: String
  var checked: ModeResult
  var parseOnly: ModeResult

  enum CodingKeys: String, CodingKey {
    case name, file, section, test, checked
    case parseOnly = "parse_only"
  }

  func result(for mode: ConformanceMode) -> ModeResult {
    switch mode {
    case .checked: checked
    case .parseOnly: parseOnly
    }
  }
}

struct ModeCounts: Codable, Sendable {
  var pass = 0
  var fail = 0
  var notImplemented = 0
  var skip = 0
  var notApplicable = 0

  enum CodingKeys: String, CodingKey {
    case pass, fail, skip
    case notImplemented = "not_implemented"
    case notApplicable = "not_applicable"
  }

  mutating func add(_ status: Status) {
    switch status {
    case .pass: pass += 1
    case .fail: fail += 1
    case .notImplemented: notImplemented += 1
    case .skip: skip += 1
    case .notApplicable: notApplicable += 1
    }
  }
}

struct FileSummary: Codable, Sendable {
  /// The textproto file name without extension.
  var file: String
  /// The `name` field inside the file, used as the first component of test names.
  var name: String
  var tests: Int
  var checked = ModeCounts()
  var parseOnly = ModeCounts()

  enum CodingKeys: String, CodingKey {
    case file, name, tests, checked
    case parseOnly = "parse_only"
  }
}

struct SuiteResults: Codable, Sendable {
  var specVersion: String
  var runner: String
  var files: [FileSummary]
  var tests: [TestResult]

  enum CodingKeys: String, CodingKey {
    case specVersion = "spec_version"
    case runner, files, tests
  }

  var passing: Set<PassingKey> {
    var out: Set<PassingKey> = []
    for test in tests {
      for mode in ConformanceMode.allCases where test.result(for: mode).status == .pass {
        out.insert(PassingKey(mode: mode, name: test.name))
      }
    }
    return out
  }

  func write(to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try encoder.encode(self).write(to: url)
  }
}

enum ConformanceSuite {
  /// The cel-spec release the submodule is pinned to.
  static let specVersion = "v0.25.3"

  static func run(files: [SpecFile], runner: any ConformanceRunner, skips: SkipList) -> SuiteResults {
    var summaries: [FileSummary] = []
    var results: [TestResult] = []
    for file in files {
      let cases = file.cases
      var summary = FileSummary(file: file.fileName, name: file.proto.name, tests: cases.count)
      for testCase in cases {
        var perMode: [ConformanceMode: ModeResult] = [:]
        for mode in ConformanceMode.allCases {
          let result = run(testCase, mode: mode, runner: runner, skips: skips)
          perMode[mode] = result
          switch mode {
          case .checked: summary.checked.add(result.status)
          case .parseOnly: summary.parseOnly.add(result.status)
          }
        }
        results.append(
          TestResult(
            name: testCase.name,
            file: file.fileName,
            section: testCase.section,
            test: testCase.test.name,
            checked: perMode[.checked] ?? ModeResult(status: .notApplicable),
            parseOnly: perMode[.parseOnly] ?? ModeResult(status: .notApplicable)
          )
        )
      }
      summaries.append(summary)
    }
    return SuiteResults(specVersion: specVersion, runner: runner.name, files: summaries, tests: results)
  }

  private static func run(
    _ testCase: ConformanceCase,
    mode: ConformanceMode,
    runner: any ConformanceRunner,
    skips: SkipList
  ) -> ModeResult {
    guard testCase.modes.contains(mode) else { return ModeResult(status: .notApplicable) }
    if let skip = skips.entry(for: testCase.name, mode: mode) {
      return ModeResult(status: .skip, detail: "\(skip.reason) (\(skip.issue))")
    }
    let request = ConformanceRequest(name: testCase.name, mode: mode, test: testCase.test)
    switch Matcher.verdict(for: request, outcome: runner.run(request)) {
    case .pass: return ModeResult(status: .pass)
    case .fail(let detail): return ModeResult(status: .fail, detail: detail)
    case .notImplemented(let detail): return ModeResult(status: .notImplemented, detail: detail)
    }
  }

  /// A fixed-width per-file table of the results.
  static func table(_ results: SuiteResults) -> String {
    func pad(_ s: String, _ width: Int) -> String {
      s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }
    func lpad(_ s: String, _ width: Int) -> String {
      s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
    }
    var lines = [
      "\(pad("file", 18)) \(lpad("tests", 6)) \(lpad("checked", 8)) \(lpad("parse-only", 11)) \(lpad("skipped", 8))"
    ]
    var total = 0
    var checked = 0
    var parseOnly = 0
    var parseOnlyApplicable = 0
    var skipped = 0
    for file in results.files {
      let poApplicable = file.tests - file.parseOnly.notApplicable
      let fileSkipped = file.checked.skip + file.parseOnly.skip
      lines.append(
        "\(pad(file.file, 18)) \(lpad(String(file.tests), 6)) \(lpad(String(file.checked.pass), 8)) "
          + "\(lpad("\(file.parseOnly.pass)/\(poApplicable)", 11)) \(lpad(String(fileSkipped), 8))"
      )
      total += file.tests
      checked += file.checked.pass
      parseOnly += file.parseOnly.pass
      parseOnlyApplicable += poApplicable
      skipped += fileSkipped
    }
    lines.append(
      "\(pad("total", 18)) \(lpad(String(total), 6)) \(lpad(String(checked), 8)) "
        + "\(lpad("\(parseOnly)/\(parseOnlyApplicable)", 11)) \(lpad(String(skipped), 8))"
    )
    return lines.joined(separator: "\n")
  }
}
