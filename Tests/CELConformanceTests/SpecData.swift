// Loads the cel-spec simple test files and enumerates their tests the way cel-go conformance_test.go does.

import CELSpecProtos
import Foundation
import SwiftProtobuf

enum SpecPaths {
  /// The repository root, derived from this file's location (Tests/CELConformanceTests/SpecData.swift).
  static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

  static let testData = repositoryRoot.appendingPathComponent("third_party/cel-spec/tests/simple/testdata")
  static let harnessDirectory = repositoryRoot.appendingPathComponent("Tests/CELConformanceTests")
  static let skipList = harnessDirectory.appendingPathComponent("skip.txt")
  static let passingList = harnessDirectory.appendingPathComponent("passing.txt")

  /// Where the machine-readable results go: `$CEL_CONFORMANCE_RESULTS`, else `.build/conformance-results.json`.
  static var results: URL {
    if let path = ProcessInfo.processInfo.environment["CEL_CONFORMANCE_RESULTS"], path.isEmpty == false {
      return URL(fileURLWithPath: path, relativeTo: repositoryRoot)
    }
    return repositoryRoot.appendingPathComponent(".build/conformance-results.json")
  }

  /// The `*.textproto` file names (without extension) in the test data directory, sorted.
  static func specFileNames() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: testData.path)
      .filter { $0.hasSuffix(".textproto") }
      .map { String($0.dropLast(".textproto".count)) }
      .sorted()
  }
}

/// One test of one file, with the defaults cel-go applies.
struct ConformanceCase: Sendable {
  /// The `name` field of the file, which is what cel-go uses in test names (`type_deduction.textproto` is named
  /// `type_deductions`).
  var file: String
  var section: String
  /// `file/section/test`.
  var name: String
  /// The test, with a missing result matcher replaced by `value { bool_value: true }`.
  var test: Cel_Expr_Conformance_Test_SimpleTest

  /// The modes this test runs in.
  var modes: [ConformanceMode] {
    if test.disableCheck || test.checkOnly {
      return [.checked]
    }
    return [.checked, .parseOnly]
  }
}

/// A decoded test file.
struct SpecFile: Sendable {
  /// File name without `.textproto`.
  var fileName: String
  var proto: Cel_Expr_Conformance_Test_SimpleTestFile

  /// The tests in file order. Duplicate names get Go's subtest suffixes (`name#01`, `name#02`, ...) so they
  /// match cel-go's test names and stay distinguishable in passing.txt; cel-spec v0.25.3 has a few duplicates.
  var cases: [ConformanceCase] {
    var out: [ConformanceCase] = []
    var seen: [String: Int] = [:]
    for section in proto.section {
      for test in section.test {
        var test = test
        if test.resultMatcher == nil {
          var value = Cel_Expr_Value()
          value.boolValue = true
          test.resultMatcher = .value(value)
        }
        var name = "\(proto.name)/\(section.name)/\(test.name)"
        if let count = seen[name] {
          seen[name] = count + 1
          name += "#" + (count < 10 ? "0" : "") + String(count)
        } else {
          seen[name] = 1
        }
        out.append(ConformanceCase(file: proto.name, section: section.name, name: name, test: test))
      }
    }
    return out
  }

  /// Registers the conformance messages so text-format `Any` fields (`[type.googleapis.com/...] { }`) decode.
  private static let anyTypesRegistered: Bool = {
    for type in CELSpecProtos.messageTypes {
      Google_Protobuf_Any.register(messageType: type)
    }
    return true
  }()

  static func load(_ fileName: String) throws -> SpecFile {
    precondition(anyTypesRegistered)
    let url = SpecPaths.testData.appendingPathComponent("\(fileName).textproto")
    let text = try String(contentsOf: url, encoding: .utf8)
      // swift-protobuf 1.37 rejects the optional ':' between an expanded Any type URL and its message
      // (`[type.googleapis.com/T]: { ... }`), which the text format allows and proto2*.textproto use.
      .replacingOccurrences(
        of: #"(\[type\.googleapis\.com/[A-Za-z0-9_.]+\])\s*:\s*([{<])"#,
        with: "$1 $2",
        options: .regularExpression
      )
    let proto = try Cel_Expr_Conformance_Test_SimpleTestFile(
      textFormatString: text,
      extensions: CELSpecProtos.extensions
    )
    return SpecFile(fileName: fileName, proto: proto)
  }

  static func loadAll() throws -> [SpecFile] {
    try SpecPaths.specFileNames().map(load)
  }
}
