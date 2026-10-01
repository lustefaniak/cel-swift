// TypedProgram: compiling expressions and policies against Swift facts and outputs, evaluation,
// partial evaluation with lazily resolved facts, explanations and error positions.

import CEL
import CELPolicy
import CELSwift
import Testing

private let selectPolicy = """
  name: select
  rule:
    id: select
    match:
      - condition: 'pr.title.startsWith("chore: bump ")'
        output: '{"rule": "skip-bumps", "action": "skip"}'
      - condition: pr.draft
        output: '{"rule": "skip-drafts", "action": "skip"}'
      - condition: has(signals.mechanical) && signals.mechanical > 0.9
        output: '{"rule": "skip-mechanical", "action": "skip"}'
      - output: '{"rule": "default", "action": "review"}'
  """

private let decidePolicy = """
  name: decide
  rule:
    variables:
      - name: size
        expression: pr.additions + pr.deletions
    match:
      - condition: >-
          pr.author in lists.trusted && review.verdict == "approve"
          && review.confidence >= 0.85 && variables.size <= 200
        output: '{"rule": "trusted-approve", "verdict": "approve"}'
      - condition: >-
          review.verdict == "request_changes" && review.confidence >= 0.9
          && review.findings.exists(f, f.severity >= severity.blocker)
        output: '{"rule": "flag-blockers", "verdict": "none", "flag": true}'
      - output: '{"rule": "nothing", "verdict": "none"}'
  """

private func baseEnvironment() throws -> Environment {
  try Environment(.enumConstants(Severity.self, namespace: "severity"))
}

struct TypedProgramTests {
  // MARK: Expressions

  @Test func expressionEvaluatesToSwiftTypes() throws {
    let program = try TypedProgram<SelectFacts, Bool>(
      expression: "pr.repo == 'acme/api' && 'bug' in pr.labels && pr.additions < 200", environment: Environment())
    #expect(try program.evaluate(.sample) == true)

    var facts = SelectFacts.sample
    facts.pr.additions = 500
    #expect(try program.evaluate(facts) == false)
  }

  @Test func expressionWithStructOutput() throws {
    let program = try TypedProgram<SelectFacts, Selection>(
      expression: "pr.draft ? {'rule': 'drafts', 'action': 'skip'} : {'rule': 'default', 'action': 'review'}",
      environment: Environment())
    #expect(try program.evaluate(.sample) == Selection(rule: "default", action: "review"))
  }

  @Test func misspeltFactIsACompileErrorWithPosition() throws {
    #expect {
      _ = try TypedProgram<SelectFacts, Bool>(
        expression: "pr.titel.startsWith('chore')", sourceName: "prbar.yaml#plan[0]", environment: Environment())
    } throws: { error in
      guard let error = error as? ValidationError else { return false }
      return error.issues == [
        ValidationError.Issue(message: "undefined field 'titel'", sourceName: "prbar.yaml#plan[0]", line: 1, column: 3)
      ]
        && error.description == """
          ERROR: prbar.yaml#plan[0]:1:3: undefined field 'titel'
           | pr.titel.startsWith('chore')
           | ..^
          """
    }
  }

  @Test func factFromAnotherStageIsUndeclared() {
    #expect(throws: ValidationError.self) {
      _ = try TypedProgram<SelectFacts, Bool>(expression: "review.confidence > 0.5", environment: Environment())
    }
  }

  @Test func outputTypeMustDecode() throws {
    #expect {
      _ = try TypedProgram<SelectFacts, Bool>(expression: "pr.additions + 1", environment: Environment())
    } throws: { error in
      (error as? ValidationError)?.issues.map(\.message) == ["output type int cannot be decoded as bool"]
    }
  }

  @Test func mapLiteralOutputsAreCheckedAgainstTheOutputStruct() throws {
    #expect {
      _ = try TypedProgram<SelectFacts, Selection>(
        expression: "{'rule': 'r', 'acton': 'skip'}", environment: Environment())
    } throws: { error in
      guard let error = error as? ValidationError else { return false }
      return error.issues.map(\.message) == [
        "'acton' is not a field of CELSwiftTests.Selection (fields: rule, action)",
        "missing field 'action' of CELSwiftTests.Selection",
      ]
    }
    #expect {
      _ = try TypedProgram<SelectFacts, Selection>(
        expression: "{'rule': 'r', 'action': 1}", environment: Environment())
    } throws: { error in
      (error as? ValidationError)?.issues.map(\.message)
        == ["field 'action' of CELSwiftTests.Selection has type string, found int"]
    }
  }

  @Test func evaluationErrorsCarryTheirPosition() throws {
    let program = try TypedProgram<SelectFacts, Bool>(
      expression: "pr.additions / (pr.deletions - 30) > 1", sourceName: "rules.yaml", environment: Environment())
    #expect {
      _ = try program.evaluate(.sample)
    } throws: { error in
      guard let error = error as? EvaluationError else { return false }
      return error.message == "division by zero" && error.line == 1 && error.column == 14
        && error.description == """
          ERROR: rules.yaml:1:14: division by zero
           | pr.additions / (pr.deletions - 30) > 1
           | .............^
          """
    }
  }

  @Test func resultThatDoesNotDecodeIsAnEvaluationError() throws {
    let program = try TypedProgram<SelectFacts, Selection>(
      expression: "pr.draft ? {'rule': 'x'} : {'rule': 'y', 'action': 'review'}", environment: Environment())
    var facts = SelectFacts.sample
    #expect(try program.evaluate(facts) == Selection(rule: "y", action: "review"))
    facts.pr.draft = true
    #expect(throws: EvaluationError.self) {
      _ = try program.evaluate(facts)
    }
  }

  // MARK: Policies

  @Test func firstMatchPolicy() throws {
    let select = try TypedProgram<SelectFacts, Selection>(
      policy: PolicySource(selectPolicy, description: "select.yaml"), environment: Environment())
    #expect(try select.evaluate(.sample) == Selection(rule: "default", action: "review"))

    var facts = SelectFacts.sample
    facts.pr.title = "chore: bump yams"
    #expect(try select.evaluate(facts) == Selection(rule: "skip-bumps", action: "skip"))

    facts = .sample
    facts.signals.mechanical = 0.95
    #expect(try select.evaluate(facts) == Selection(rule: "skip-mechanical", action: "skip"))
  }

  @Test func policyWithVariablesAndEnumConstants() throws {
    let decide = try TypedProgram<DecideFacts, Decision>(
      policy: PolicySource(decidePolicy, description: "decide.yaml"), environment: baseEnvironment())
    #expect(try decide.evaluate(.sample) == Decision(rule: "trusted-approve", verdict: "approve", flag: nil))

    var facts = DecideFacts.sample
    facts.review.verdict = .requestChanges
    facts.review.findings.append(Finding(path: "a.swift", lineStart: 1, severity: .blocker, title: nil))
    #expect(try decide.evaluate(facts) == Decision(rule: "flag-blockers", verdict: "none", flag: true))

    facts = .sample
    facts.pr.author = "mallory"
    #expect(try decide.evaluate(facts) == Decision(rule: "nothing", verdict: "none", flag: nil))
  }

  @Test func policyOutputsAreCheckedAtLoad() throws {
    let yaml = """
      name: select
      rule:
        match:
          - condition: pr.draft
            output: '{"rule": "skip-drafts", "acton": "skip"}'
          - output: '{"rule": "default", "action": "review"}'
      """
    #expect {
      _ = try TypedProgram<SelectFacts, Selection>(
        policy: PolicySource(yaml, description: "select.yaml"), environment: Environment())
    } throws: { error in
      guard let error = error as? ValidationError else { return false }
      return error.issues == [
        ValidationError.Issue(
          message: "'acton' is not a field of CELSwiftTests.Selection (fields: rule, action)",
          sourceName: "select.yaml", line: 5, column: 40),
        ValidationError.Issue(
          message: "missing field 'action' of CELSwiftTests.Selection", sourceName: "select.yaml", line: 5,
          column: 16),
      ]
    }
  }

  @Test func policyCompileErrorsArePositionedInTheFile() throws {
    let yaml = """
      name: select
      rule:
        match:
          - condition: pr.titel.startsWith("chore")
            output: '{"rule": "skip", "action": "skip"}'
          - output: '{"rule": "default", "action": "review"}'
      """
    #expect {
      _ = try TypedProgram<SelectFacts, Selection>(
        policy: PolicySource(yaml, description: "select.yaml"), environment: Environment())
    } throws: { error in
      guard let error = error as? ValidationError else { return false }
      return error.issues == [
        ValidationError.Issue(message: "undefined field 'titel'", sourceName: "select.yaml", line: 4, column: 20)
      ]
        && error.description == """
          ERROR: select.yaml:4:20: undefined field 'titel'
           |     - condition: pr.titel.startsWith("chore")
           | ...................^
          """
    }
  }

  @Test func policyWithoutDefaultNeedsAnOptionalOutput() throws {
    let yaml = """
      name: select
      rule:
        match:
          - condition: pr.draft
            output: '{"rule": "skip-drafts", "action": "skip"}'
      """
    #expect {
      _ = try TypedProgram<SelectFacts, Selection>(
        policy: PolicySource(yaml, description: "select.yaml"), environment: Environment())
    } throws: { error in
      (error as? ValidationError)?.issues.map(\.message) == [
        "the policy produces no output when no match applies; add a match without a condition or decode the output as an Optional"
      ]
    }
    let optional = try TypedProgram<SelectFacts, Selection?>(
      policy: PolicySource(yaml, description: "select.yaml"), environment: Environment())
    #expect(try optional.evaluate(.sample) == nil)
    var facts = SelectFacts.sample
    facts.pr.draft = true
    #expect(try optional.evaluate(facts) == Selection(rule: "skip-drafts", action: "skip"))
  }

  @Test func aggregatePolicyDecodesAsAnArray() throws {
    let yaml = """
      name: attachments
      rule:
        aggregate:
          - rule:
              id: verdict
              match:
                - condition: review.verdict == "approve" && review.confidence >= 0.85
                  output: '{"rule": "approve", "verdict": "approve"}'
          - rule:
              id: inline
              match:
                - condition: review.findings.exists(f, f.severity >= severity.suggestion)
                  output: '{"rule": "share-findings", "verdict": "none"}'
      """
    let program = try TypedProgram<DecideFacts, [Decision]>(
      policy: PolicySource(yaml, description: "attachments.yaml"), environment: baseEnvironment())
    #expect(
      try program.evaluate(.sample) == [
        Decision(rule: "approve", verdict: "approve", flag: nil),
        Decision(rule: "share-findings", verdict: "none", flag: nil),
      ])
  }

  @Test func structLiteralOutputsAreTypeChecked() throws {
    let yaml = """
      name: decide
      rule:
        match:
          - condition: review.confidence > 0.5
            output: 'prbar.Decision{rule: "share", verdict: "none"}'
          - output: 'prbar.Decision{rule: "nothing", verdict: "none", flag: false}'
      """
    let program = try TypedProgram<DecideFacts, Decision>(
      policy: PolicySource(yaml, description: "decide.yaml"), environment: Environment())
    #expect(try program.evaluate(.sample) == Decision(rule: "share", verdict: "none", flag: nil))

    let misspelt = """
      name: decide
      rule:
        match:
          - output: 'prbar.Decision{rule: "nothing", verdcit: "none"}'
      """
    #expect {
      _ = try TypedProgram<DecideFacts, Decision>(
        policy: PolicySource(misspelt, description: "decide.yaml"), environment: Environment())
    } throws: { error in
      (error as? ValidationError)?.issues.map(\.message) == ["undefined field 'verdcit'"]
    }
  }

  // MARK: Partial evaluation

  @Test func decidedWithoutUnknownSignals() throws {
    let select = try TypedProgram<SelectFacts, Selection>(
      policy: PolicySource(selectPolicy, description: "select.yaml"), environment: Environment())
    var facts = SelectFacts.sample
    facts.pr.draft = true
    let outcome = try select.evaluate(facts, unknowns: [UnknownPattern("signals").wildcard()])
    #expect(outcome.value == Selection(rule: "skip-drafts", action: "skip"))
  }

  @Test func unknownSignalsAreNamed() throws {
    let select = try TypedProgram<SelectFacts, Selection>(
      policy: PolicySource(selectPolicy, description: "select.yaml"), environment: Environment())
    let outcome = try select.evaluate(.sample, unknowns: [UnknownPattern("signals").wildcard()])
    guard case .unknown(let missing) = outcome else {
      Issue.record("expected unknown signals, got \(outcome)")
      return
    }
    #expect(missing.map(\.description) == ["signals.mechanical"])
  }

  @Test func resolvesOnlyTheSignalsTheOutputNeeds() async throws {
    let select = try TypedProgram<SelectFacts, Selection>(
      policy: PolicySource(selectPolicy, description: "select.yaml"), environment: Environment())
    var requests: [[String]] = []
    let selection = try await select.evaluate(.sample, unknowns: [UnknownPattern("signals").wildcard()]) {
      missing, facts in
      requests.append(missing.map(\.description))
      facts.signals.mechanical = 0.97
    }
    #expect(selection == Selection(rule: "skip-mechanical", action: "skip"))
    #expect(requests == [["signals.mechanical"]])

    var draft = SelectFacts.sample
    draft.pr.draft = true
    requests = []
    let skipped = try await select.evaluate(draft, unknowns: [UnknownPattern("signals").wildcard()]) { missing, _ in
      requests.append(missing.map(\.description))
    }
    #expect(skipped == Selection(rule: "skip-drafts", action: "skip"))
    #expect(requests.isEmpty)
  }

  @Test func signalThatCannotBeFetchedStaysAbsent() async throws {
    let select = try TypedProgram<SelectFacts, Selection>(
      policy: PolicySource(selectPolicy, description: "select.yaml"), environment: Environment())
    let selection = try await select.evaluate(.sample, unknowns: [UnknownPattern("signals").wildcard()]) { _, _ in
      // The service failed: the signal stays nil and has(signals.mechanical) is false.
    }
    #expect(selection == Selection(rule: "default", action: "review"))
  }

  @Test @MainActor func resolverRunsOnTheCallersActor() async throws {
    let select = try TypedProgram<SelectFacts, Selection>(
      policy: PolicySource(selectPolicy, description: "select.yaml"), environment: Environment())
    let selection = try await select.evaluate(.sample, unknowns: [UnknownPattern("signals").wildcard()]) { _, facts in
      MainActor.assertIsolated()
      facts.signals.mechanical = 0.5
    }
    #expect(selection == Selection(rule: "default", action: "review"))
  }

  // MARK: Explanations

  @Test func explainsAPolicyConditionByCondition() throws {
    let decide = try TypedProgram<DecideFacts, Decision>(
      policy: PolicySource(decidePolicy, description: "decide.yaml"), environment: baseEnvironment())
    var facts = DecideFacts.sample
    facts.pr.additions = 412
    let explanation = try decide.explain(facts)
    #expect(try explanation.result.get() == Decision(rule: "nothing", verdict: "none", flag: nil))
    let first = try #require(explanation.conditions.first)
    #expect(first.line == 8)
    #expect(first.column == 9)
    #expect(first.value == false)
    #expect(
      first.text == #"pr.author in lists.trusted && review.verdict == "approve" && review.confidence >= 0.85 && variables.size <= 200"#
    )
    #expect(first.output == #"{"rule": "trusted-approve", "verdict": "approve"}"#)
    #expect(first.terms.map(\.text) == [
      "pr.author in lists.trusted", #"review.verdict == "approve""#, "review.confidence >= 0.85",
      "variables.size <= 200",
    ])
    #expect(first.terms.map(\.value) == [true, true, true, false])
    let size = try #require(first.terms.last)
    #expect(size.inputs.map(\.text) == ["variables.size"])
    #expect(size.inputs.map(\.value) == [442])
    #expect(explanation.conditions.count == 2)
    #expect(explanation.conditions[1].value == false)
    #expect(explanation.description.contains("decide.yaml:8:9 pr.author in lists.trusted"))
  }

  @Test func explainsAnExpression() throws {
    let program = try TypedProgram<SelectFacts, Bool>(
      expression: "pr.additions <= 200 && !pr.draft", environment: Environment())
    var facts = SelectFacts.sample
    facts.pr.additions = 412
    let explanation = try program.explain(facts)
    #expect(try explanation.result.get() == false)
    let condition = try #require(explanation.conditions.first)
    #expect(condition.text == "pr.additions <= 200 && !pr.draft")
    #expect(condition.value == false)
    #expect(condition.terms.map(\.text) == ["pr.additions <= 200", "pr.draft"])
    #expect(condition.terms.map(\.value) == [false, false])
    #expect(condition.terms[0].inputs.map(\.text) == ["pr.additions"])
    #expect(condition.terms[0].inputs.map(\.value) == [412])
    #expect(
      explanation.description == """
        <input>:1:1 pr.additions <= 200 && !pr.draft -> false
          false  pr.additions <= 200   (pr.additions = 412)
          false  pr.draft   (pr.draft = false)
        result: false
        """)
  }

  @Test func explanationKeepsEvaluationErrors() throws {
    let program = try TypedProgram<SelectFacts, Bool>(
      expression: "pr.deletions > 0 && pr.additions / (pr.deletions - 30) > 1", environment: Environment())
    let explanation = try program.explain(.sample)
    guard case .failure(let error) = explanation.result else {
      Issue.record("expected a failure")
      return
    }
    #expect(error.message == "division by zero")
    #expect(explanation.conditions.first?.terms.last?.value?.asError?.message == "division by zero")
  }
}
