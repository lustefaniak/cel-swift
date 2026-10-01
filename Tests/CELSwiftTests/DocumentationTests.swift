// The examples of Sources/CELSwift/CELSwift.docc (GettingStarted.md), so the article keeps compiling
// and stays true. Keep them in sync when either side changes.

import CEL
import CELPolicy
import CELSwift
import Testing

struct DocumentationTests {
  struct ChangeRequest: Codable, CELNamedType {
    static let celTypeName = "prbar.ChangeRequest"

    var repo: String
    var author: String
    var title: String
    var draft: Bool
    var labels: [String]
    var additions: Int
    var files: [String]
    var reviewer: String?
  }

  struct Signals: Codable {
    var mechanical: Double?
  }

  struct SelectFacts: Codable {
    var pr: ChangeRequest
    var trigger: String
    var signals: Signals
  }

  struct Selection: Codable, Equatable, CELNamedType {
    static let celTypeName = "prbar.Selection"

    var rule: String
    var action: String
  }

  enum Severity: String, Codable, CaseIterable, CELValueRepresentable {
    case info, suggestion, warning, blocker

    static var celType: CELType { .int }
    var celValue: Value { .int(Int64(Self.allCases.firstIndex(of: self) ?? 0)) }
    init(celValue: Value) throws {
      guard let rank = celValue.asInt, let index = Int(exactly: rank), Self.allCases.indices.contains(index)
      else { throw EvalError("not a severity: \(celValue)") }
      self = Self.allCases[index]
    }
  }

  struct Finding: Codable {
    var path: String
    var severity: Severity
  }

  struct Review: Codable {
    var verdict: String
    var confidence: Double
    var findings: [Finding]
  }

  struct DecideFacts: Codable {
    var pr: ChangeRequest
    var review: Review
  }

  let policyYAML = """
    name: select
    rule:
      match:
        - condition: 'pr.title.startsWith("chore: bump ")'
          output: '{"rule": "skip-bumps", "action": "skip"}'
        - condition: pr.draft
          output: '{"rule": "skip-drafts", "action": "skip"}'
        - condition: has(signals.mechanical) && signals.mechanical > 0.9
          output: '{"rule": "skip-mechanical", "action": "skip"}'
        - output: '{"rule": "default", "action": "review"}'
    """

  let pr = ChangeRequest(
    repo: "acme/api", author: "alice", title: "Fix the retry loop", draft: false, labels: ["bug"],
    additions: 120, files: ["Sources/Retry.swift"], reviewer: nil)

  var facts: SelectFacts { SelectFacts(pr: pr, trigger: "review_requested", signals: Signals()) }

  func select() throws -> TypedProgram<SelectFacts, Selection> {
    try TypedProgram<SelectFacts, Selection>(
      policy: PolicySource(policyYAML, description: "select.yaml"), environment: Environment())
  }

  func base() throws -> Environment {
    try Environment(
      .function("glob", .overload("glob_string_string") { (path: String, pattern: String) in
        pattern.hasSuffix("/**") ? path.hasPrefix(String(pattern.dropLast(2))) : path == pattern
      }),
      .function("isBot", .overload("is_bot_string") { (login: String) in login.hasSuffix("[bot]") })
    )
  }

  @Test func landingPage() throws {
    struct Facts: Codable {
      var pr: ChangeRequest
      var trigger: String
    }
    let rule = try TypedProgram<Facts, Bool>(
      expression: "pr.additions <= 200 && trigger == 'review_requested'", environment: Environment())
    let small = try rule.evaluate(Facts(pr: pr, trigger: "review_requested"))
    #expect(small)
  }

  @Test func compileAndEvaluate() throws {
    let selection = try select().evaluate(facts)
    #expect(selection == Selection(rule: "default", action: "review"))
  }

  @Test func loadErrors() {
    let misspelt = """
      name: select
      rule:
        match:
          - condition: pr.titel.startsWith("chore")
            output: '{"rule": "skip", "action": "skip"}'
          - output: '{"rule": "default", "action": "review"}'
      """
    #expect {
      _ = try TypedProgram<SelectFacts, Selection>(
        policy: PolicySource(misspelt, description: "select.yaml"), environment: Environment())
    } throws: { error in
      "\(error)" == """
        ERROR: select.yaml:4:20: undefined field 'titel'
         |     - condition: pr.titel.startsWith("chore")
         | ...................^
        """
    }
    let badOutput = """
      name: select
      rule:
        match:
          - condition: pr.draft
            output: '{"rule": "skip-drafts", "acton": "skip"}'
          - output: '{"rule": "default", "action": "review"}'
      """
    #expect {
      _ = try TypedProgram<SelectFacts, Selection>(
        policy: PolicySource(badOutput, description: "select.yaml"), environment: Environment())
    } throws: { error in
      guard let error = error as? ValidationError else { return false }
      return error.issues.first?.description
        == "select.yaml:5:40: 'acton' is not a field of prbar.Selection (fields: rule, action)"
        && "\(error)".hasSuffix(
          """
          ERROR: select.yaml:5:40: 'acton' is not a field of prbar.Selection (fields: rule, action)
           |       output: '{"rule": "skip-drafts", "acton": "skip"}'
           | .......................................^
          """)
    }
  }

  @Test func functions() throws {
    let botChange = try TypedProgram<SelectFacts, Bool>(
      expression: "isBot(pr.author) && pr.files.all(f, glob(f, 'Package.resolved'))", environment: base())
    #expect(try botChange.evaluate(facts) == false)
    var bump = facts
    bump.pr.author = "dependabot[bot]"
    bump.pr.files = ["Package.resolved"]
    #expect(try botChange.evaluate(bump) == true)
  }

  @Test func enumerations() throws {
    let blocking = try TypedProgram<DecideFacts, Bool>(
      expression: "review.findings.exists(f, f.severity >= severity.warning)",
      environment: base().extending(.enumConstants(Severity.self, namespace: "severity")))
    let review = Review(
      verdict: "approve", confidence: 0.9, findings: [Finding(path: "a.swift", severity: .suggestion)])
    #expect(try blocking.evaluate(DecideFacts(pr: pr, review: review)) == false)
    var flagged = review
    flagged.findings.append(Finding(path: "b.swift", severity: .blocker))
    #expect(try blocking.evaluate(DecideFacts(pr: pr, review: flagged)) == true)
  }

  @Test func lazySignals() async throws {
    let select = try select()
    let decided = try await select.evaluate(facts, unknowns: [UnknownPattern("signals").wildcard()]) {
      missing, facts in
      #expect(missing.map(\.description) == ["signals.mechanical"])
      facts.signals.mechanical = 0.97
    }
    #expect(decided == Selection(rule: "skip-mechanical", action: "skip"))

    var draft = facts
    draft.pr.draft = true
    let skipped = try await select.evaluate(draft, unknowns: [UnknownPattern("signals").wildcard()]) { _, _ in
      Issue.record("a draft is decided without signals")
    }
    #expect(skipped == Selection(rule: "skip-drafts", action: "skip"))
  }

  @Test func explain() throws {
    var large = facts
    large.pr.additions = 412
    let rule = try TypedProgram<SelectFacts, Bool>(
      expression: "pr.additions <= 200 && !pr.draft", environment: base())
    #expect(
      "\(try rule.explain(large))" == """
        <input>:1:1 pr.additions <= 200 && !pr.draft -> false
          false  pr.additions <= 200   (pr.additions = 412)
          false  pr.draft   (pr.draft = false)
        result: false
        """)
  }
}
