// The cel-spec conformance suite (third_party/cel-spec/tests/simple/testdata) run through `conformanceRunner`.
//
//   swift test --filter CELConformanceTests                      run, compare with passing.txt
//   CEL_CONFORMANCE_UPDATE=1 swift test --filter CELConformanceTests   rewrite passing.txt
//   CEL_CONFORMANCE_RESULTS=path.json                            results file (default .build/conformance-results.json)
//   tools/dashboard/dashboard.py                                 per-file table against cel-go, cel-rust, cel-cpp

import CELSpecProtos
import Foundation
import Testing

struct ConformanceTests {
  /// The 31 simple test files of cel-spec v0.25.3.
  static let expectedFileCount = 31

  @Test func everySpecFileIsPresent() throws {
    let names = try SpecPaths.specFileNames()
    #expect(names.count == Self.expectedFileCount, "cel-spec test files: \(names)")
  }

  @Test(arguments: (try? SpecPaths.specFileNames()) ?? [])
  func specFileDecodes(_ fileName: String) throws {
    let file = try SpecFile.load(fileName)
    #expect(file.proto.name.isEmpty == false)
    let names = file.cases.map(\.name)
    #expect(Set(names).count == names.count, "duplicate test names in \(fileName)")
    for testCase in file.cases {
      #expect(testCase.test.expr.isEmpty == false, "\(testCase.name) has no expression")
    }
  }

  @Test func skipListIsWellFormed() throws {
    _ = try SkipList.load()
  }

  /// Runs every test in every applicable mode, enforces the skip list and the passing.txt ratchet, and writes
  /// the results file the dashboard reads.
  @Test func suite() throws {
    let files = try SpecFile.loadAll()
    let skips = try SkipList.load()
    let results = ConformanceSuite.run(files: files, runner: conformanceRunner, skips: skips)
    try results.write(to: SpecPaths.results)
    print("cel-spec \(ConformanceSuite.specVersion) conformance, runner \(results.runner):")
    print(ConformanceSuite.table(results))

    // A skip entry that matches nothing is stale (renamed or removed test, or a typo).
    let names = results.tests.map(\.name)
    for entry in skips.entries {
      let used = names.contains { name in entry.modes.contains { entry.matches(name, mode: $0) } }
      #expect(used, "skip.txt:\(entry.line): '\(entry.path)' matches no test")
    }

    let passing = results.passing
    if PassingList.updateRequested {
      try PassingList.render(passing).write(to: SpecPaths.passingList, atomically: true, encoding: .utf8)
      print("passing.txt rewritten with \(passing.count) entries")
      return
    }

    let expected = try PassingList.load()
    let byName = Dictionary(results.tests.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    for key in expected.sorted() where passing.contains(key) == false {
      let result = byName[key.name]?.result(for: key.mode)
      let detail = result.map { "\($0.status.rawValue): \($0.detail ?? "")" } ?? "test not found"
      Issue.record("regression: \(key.line) is in passing.txt but \(detail)")
    }
    let newlyPassing = passing.subtracting(expected).sorted()
    if newlyPassing.isEmpty == false {
      print("\(newlyPassing.count) newly passing (CEL_CONFORMANCE_UPDATE=1 adds them to passing.txt):")
      for key in newlyPassing { print("  \(key.line)") }
    }
  }
}
