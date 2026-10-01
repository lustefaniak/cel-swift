// Differential testing against cel-go (docs/plan.md § Testing, item 3).
//
//   swift test --filter CELDifferentialTests          fixed seeds (needs Go for tools/oracle) + regressions.jsonl
//
// Environment:
//   CEL_DIFF_SEEDS=1,2,3 | random | random:N           seeds (default: the fixed set below)
//   CEL_DIFF_CASES=N                                     cases per seed (default 100)
//   CEL_DIFF_WORKERS=N                                   parallel oracle processes (default 4)
//   CEL_DIFF_MINIMIZE=N                                  failures to minimise, one per category signature (default 10)
//   CEL_DIFF_RECORD=0                                    do not append minimised failures to regressions.jsonl
//   CEL_DIFF_REPORT=path                                 every mismatch as JSON lines (default .build/differential/mismatches.jsonl)
//   CEL_DIFF_EXTENSION_COSTS=1                           also compare costs of extension function calls
//   CEL_DIFF_ORACLE=path                                 use a prebuilt oracle binary
//
// regressions.jsonl holds minimised failures with cel-go's answer, so it runs without Go. An entry with
// `known_issue` is an open bug: it runs inside `withKnownIssue` and starts failing once the bug is fixed,
// which is the cue to drop the field.

import Foundation
import Testing

struct DifferentialTests {
  static let fixedSeeds: [UInt64] = [1, 2, 3, 4, 5, 6, 7, 8]
  static let regressionsFile = Oracle.packageRoot.appendingPathComponent("Tests/CELDifferentialTests/regressions.jsonl")
  static let env = ProcessInfo.processInfo.environment

  static var seeds: [UInt64] {
    guard let text = env["CEL_DIFF_SEEDS"], !text.isEmpty else { return fixedSeeds }
    if text.hasPrefix("random") {
      let count = Int(text.split(separator: ":").dropFirst().first ?? "") ?? 4
      var g = SystemRandomNumberGenerator()
      return (0..<count).map { _ in g.next() % 1_000_000_000 }
    }
    return text.split(separator: ",").compactMap { UInt64($0.trimmingCharacters(in: .whitespaces)) }
  }

  static var casesPerSeed: Int { Int(env["CEL_DIFF_CASES"] ?? "") ?? 100 }
  static var workers: Int { max(1, Int(env["CEL_DIFF_WORKERS"] ?? "") ?? 4) }
  static var maxMinimize: Int { Int(env["CEL_DIFF_MINIMIZE"] ?? "") ?? 10 }
  static var record: Bool { env["CEL_DIFF_RECORD"] != "0" }

  struct Failure: Sendable {
    var testCase: DiffCase
    var mismatches: [Mismatch]

    /// Groups failures for minimisation: the first category and, for messages, their first words.
    var signature: String {
      guard let m = mismatches.first else { return "" }
      func head(_ s: String) -> String {
        String(s.split(separator: " ").prefix(4).joined(separator: " ").prefix(60))
      }
      switch m.category {
      case .compile, .error, .kind, .harness: return "\(m.category.rawValue): \(head(m.oracle)) / \(head(m.swift))"
      default: return m.category.rawValue
      }
    }
  }

  /// What the generated cases did on cel-go, to keep an eye on the generator's coverage.
  struct Stats: Sendable {
    var compileErrors = 0
    var evalErrors = 0
    var values = 0
    var divergences = 0
    var usingExtensions = 0
    var messages: [String: Int] = [:]

    mutating func add(_ other: Stats) {
      compileErrors += other.compileErrors
      evalErrors += other.evalErrors
      values += other.values
      divergences += other.divergences
      usingExtensions += other.usingExtensions
      messages.merge(other.messages, uniquingKeysWith: +)
    }
  }

  /// Runs `cases` in chunks on `workers` oracle processes.
  static func run(_ cases: [DiffCase]) async throws -> ([Failure], Stats) {
    let chunkSize = 200
    let chunks = stride(from: 0, to: cases.count, by: chunkSize).map {
      Array(cases[$0..<min($0 + chunkSize, cases.count)])
    }
    var failures: [Failure] = []
    var stats = Stats()
    try await withThrowingTaskGroup(of: ([Failure], Stats).self) { group in
      var next = 0
      func submit() {
        guard next < chunks.count else { return }
        let chunk = chunks[next]
        next += 1
        group.addTask {
          var checker = Checker()
          let results = try checker.checkWithOutcomes(chunk)
          var stats = Stats()
          var failures: [Failure] = []
          for (c, result) in zip(chunk, results) {
            if !result.mismatches.isEmpty { failures.append(Failure(testCase: c, mismatches: result.mismatches)) }
            if result.diverged { stats.divergences += 1 }
            if c.root.anyUsesExtension { stats.usingExtensions += 1 }
            if let e = result.oracle.compileError {
              stats.compileErrors += 1
              let first = e.split(separator: "\n").first.map(String.init) ?? ""
              let message = first.split(separator: ":").dropFirst(3).joined(separator: ":")
              stats.messages["compile:" + String(message.prefix(60)), default: 0] += 1
            } else if let e = result.oracle.evalError {
              stats.evalErrors += 1
              stats.messages["eval: " + String(e.prefix(40)), default: 0] += 1
            } else {
              stats.values += 1
            }
          }
          return (failures, stats)
        }
      }
      for _ in 0..<workers { submit() }
      while let (result, chunkStats) = try await group.next() {
        failures += result
        stats.add(chunkStats)
        submit()
      }
    }
    return (failures.sorted { $0.testCase.id < $1.testCase.id }, stats)
  }

  @Test(.enabled(if: Oracle.isAvailable, "the cel-go oracle could not be built: \(Oracle.unavailableReason)"))
  func generatedCases() async throws {
    let seeds = Self.seeds
    let perSeed = Self.casesPerSeed
    print("differential: seeds \(seeds.map(String.init).joined(separator: ",")), \(perSeed) cases each")
    var cases: [DiffCase] = []
    for seed in seeds {
      for i in 0..<perSeed { cases.append(DiffCase.generate(seed: seed, index: i)) }
    }
    let started = Date()
    let (failures, stats) = try await Self.run(cases)
    let elapsed = Date().timeIntervalSince(started)

    print("differential: \(cases.count) cases in \(String(format: "%.1f", elapsed)) s, \(failures.count) mismatching")
    print(
      "  cel-go: \(stats.values) values, \(stats.evalErrors) evaluation errors, \(stats.compileErrors) compile errors; "
        + "\(stats.usingExtensions) use extensions, \(stats.divergences) hit a documented divergence")
    if Self.env["CEL_DIFF_STATS"] == "1" {
      for (message, count) in stats.messages.sorted(by: { $0.value > $1.value }).prefix(40) {
        print("    \(count) \(message)")
      }
    }
    var byCategory: [Mismatch.Category: Int] = [:]
    for f in failures {
      for m in f.mismatches { byCategory[m.category, default: 0] += 1 }
    }
    for (category, count) in byCategory.sorted(by: { $0.key < $1.key }) {
      print("  \(category.rawValue): \(count)")
    }
    try Self.writeReport(failures)

    // Minimise one failure per signature and record it.
    var signatures: [String: Failure] = [:]
    for f in failures where signatures[f.signature] == nil { signatures[f.signature] = f }
    var checker = Checker()
    var recorded: [JSON] = []
    for (signature, failure) in signatures.sorted(by: { $0.key < $1.key }).prefix(Self.maxMinimize) {
      guard let category = failure.mismatches.first?.category else { continue }
      let reduced = try Reducer.reduce(failure.testCase, category: category, checker: &checker)
      let request = Self.pruned(reduced.request)
      let answer = try Oracle.evaluate([request])[0]
      let observed = checker.swift.run(request)
      let mismatches = Mismatch.compare(
        oracle: Outcome(oracle: answer), swift: observed, usesExtensions: request["uses_extensions"]?.boolValue ?? false
      )
      print("minimised [\(signature)] \(failure.testCase.id): \(reduced.expr)")
      for m in mismatches { print("    \(m)") }
      recorded.append(
        .object([
          ("category", .string(category.rawValue)), ("request", request), ("expected", Outcome.stripped(answer)),
        ]))
    }
    if Self.record && !recorded.isEmpty {
      try Self.appendRegressions(recorded)
    }
    for f in failures.prefix(20) {
      let details = f.mismatches.map(\.description).joined(separator: "\n  ")
      Issue.record("\(f.testCase.id) \(f.testCase.expr)\n  \(details)")
    }
  }

  /// The request without the variables its expression does not mention.
  static func pruned(_ request: JSON) -> JSON {
    let text = request["expr"]?.stringValue ?? ""
    func keep(_ name: String) -> Bool { Reducer.mentions(text, name) }
    var config = request["config"] ?? .object([])
    let variables = (config["variables"]?.arrayValue ?? []).filter { keep($0["name"]?.stringValue ?? "") }
    config = config.setting("variables", .array(variables))
    var out = request.setting("config", config)
    for key in ["bindings", "size_hints"] {
      if let fields = request[key]?.objectValue {
        out = out.setting(key, .object(fields.filter { keep($0.0) }))
      }
    }
    return out
  }

  static func writeReport(_ failures: [Failure]) throws {
    let path =
      env["CEL_DIFF_REPORT"] ?? Oracle.packageRoot.appendingPathComponent(".build/differential/mismatches.jsonl").path
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let lines = failures.map { f -> String in
      JSON.object([
        ("id", .string(f.testCase.id)), ("signature", .string(f.signature)), ("expr", .string(f.testCase.expr)),
        (
          "mismatches",
          .array(
            f.mismatches.map {
              .object([
                ("category", .string($0.category.rawValue)), ("cel_go", .string($0.oracle)),
                ("cel_swift", .string($0.swift)),
              ])
            })
        ),
        ("request", f.testCase.request),
      ]).rendered
    }
    try Data((lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).utf8).write(to: url)
  }

  static func loadRegressions() throws -> [JSON] {
    guard let data = FileManager.default.contents(atPath: regressionsFile.path) else { return [] }
    return try String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      return trimmed.isEmpty || trimmed.hasPrefix("//") ? nil : try JSON.parse(trimmed)
    }
  }

  static func appendRegressions(_ entries: [JSON]) throws {
    let existing = try loadRegressions()
    let seen = Set(
      existing.compactMap { e -> String? in
        guard let r = e["request"] else { return nil }
        return r.setting("id", nil).rendered
      })
    var text =
      FileManager.default.contents(atPath: regressionsFile.path).map { String(decoding: $0, as: UTF8.self) } ?? ""
    for entry in entries where !seen.contains(entry["request"]?.setting("id", nil).rendered ?? "") {
      text += entry.rendered + "\n"
    }
    try Data(text.utf8).write(to: regressionsFile)
  }

  @Test func regressions() throws {
    var swift = SwiftSide()
    for entry in try Self.loadRegressions() {
      let request = try #require(entry["request"])
      let expected = Outcome(oracle: try #require(entry["expected"]))
      let observed = swift.run(request)
      let mismatches = Mismatch.compare(
        oracle: expected, swift: observed, usesExtensions: request["uses_extensions"]?.boolValue ?? false)
      let label = "\(request["id"]?.stringValue ?? "?"): \(request["expr"]?.stringValue ?? "")"
      if let issue = entry["known_issue"]?.stringValue {
        withKnownIssue(Comment(rawValue: issue)) {
          for m in mismatches { Issue.record("\(label)\n  \(m)") }
        }
      } else {
        for m in mismatches { Issue.record("\(label)\n  \(m)") }
      }
    }
  }

  /// Triage helper: `CEL_DIFF_EXPR='expr; expr2'` runs each expression in the `full` environment (with the
  /// bindings of case 0 of seed 0, `CEL_DIFF_UNCHECKED=1` for parse-only) and prints both answers.
  @Test(.enabled(if: env["CEL_DIFF_EXPR"] != nil && Oracle.isAvailable))
  func adHoc() throws {
    let texts = (Self.env["CEL_DIFF_EXPR"] ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
    var base = DiffCase.generate(seed: 0, index: 0)
    base.profile = .full
    base.extensions = Profile.extensionVersions.map { ($0.0, "latest") }
    base.checked = Self.env["CEL_DIFF_UNCHECKED"] != "1"
    base.unknowns = (Self.env["CEL_DIFF_UNKNOWN"] ?? "").split(separator: ",").map {
      .object([("variable", .string(String($0))), ("path", .array([]))])
    }
    base.costLimit = (Self.env["CEL_DIFF_COST_LIMIT"]).flatMap { UInt64($0) }
    var swift = SwiftSide()
    for text in texts {
      let request = base.request.setting("expr", .string(text))
      let answer = try Oracle.evaluate([request])[0]
      let o = Outcome(oracle: answer)
      let s = swift.run(request)
      print("expr: \(text)\n  cel-go:    \(o)\n  cel-swift: \(s)")
    }
  }

  /// Triage helper: `CEL_DIFF_REPLAY=path` runs the requests of a `CEL_DIFF_TRACE` file, in order, through
  /// one cel-swift side (no oracle), to reproduce a crash.
  @Test(.enabled(if: env["CEL_DIFF_REPLAY"] != nil))
  func replay() throws {
    let path = try #require(Self.env["CEL_DIFF_REPLAY"])
    let text = String(decoding: FileManager.default.contents(atPath: path) ?? Data(), as: UTF8.self)
    var swift = SwiftSide()
    for line in text.split(separator: "\n") {
      let request = try JSON.parse(String(line))
      print("replay \(request["id"]?.stringValue ?? "?")")
      _ = swift.run(request)
    }
  }

  /// The generator is deterministic and its output parses.
  @Test func generatorIsDeterministic() {
    for i in 0..<50 {
      let a = DiffCase.generate(seed: 42, index: i)
      let b = DiffCase.generate(seed: 42, index: i)
      #expect(a.request == b.request)
    }
  }
}
