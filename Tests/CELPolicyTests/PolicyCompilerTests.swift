// Copyright 2024 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Ported from cel-go policy/compiler_test.go and the tables of policy/helper_test.go
// (policyTests, policyErrorTests).

import CEL
import Testing

@testable import CELPolicy

struct PolicyCompilerTests {
  struct PolicyCase: CustomTestStringConvertible, Sendable {
    var name: String
    var expr: String
    var options: [Environment.Option] = []
    var testDescription: String { name }
  }

  static let policyTests: [PolicyCase] = [
    PolicyCase(
      name: "k8s",
      expr: """
        cel.@block([
          resource.labels.?environment.orValue("prod"),
          resource.labels.?break_glass.orValue("false") == "true"],
          !(@index1 || resource.containers.all(c, c.startsWith(@index0 + ".")))
            ? optional.of("only %s containers are allowed in namespace %s".format([@index0, resource.namespace]))
            : optional.none())
        """),
    PolicyCase(
      name: "unnest",
      expr: """
        cel.@block([values.filter(x, x > 2)],
        ((@index0.size() == 0) ? false : @index0.all(x, x % 2 == 0))
        ? optional.of("some divisible by 2")
        : (values.map(x, x * 3).exists(x, x % 4 == 0)
           ? optional.of("at least one divisible by 4")
           : (values.map(x, x * x * x).exists(x, x % 6 == 0)
             ? optional.of("at least one power of 6")
             : optional.none())))
        """),
    PolicyCase(
      name: "restricted_destinations",
      expr: """
        cel.@block([
          locationCode(origin.ip) == spec.origin,
          has(request.auth.claims.nationality),
          @index1 && request.auth.claims.nationality == spec.origin,
          locationCode(destination.ip) in spec.restricted_destinations,
          resource.labels.location in spec.restricted_destinations,
          @index3 || @index4],
          (@index2 && @index5) ? true : ((!@index1 && @index0 && @index5) ? true : false))
        """,
      options: [TestFunctions.locationCode]),
    PolicyCase(
      name: "limits",
      expr: """
        cel.@block([
          "hello",
          "goodbye",
          "me",
          "%s, %s",
          @index3.format([@index1, @index2])],
          (now.getHours() >= 20)
          ? ((now.getHours() < 21)
            ? optional.of(@index4 + "!")
            : ((now.getHours() < 22)
              ? optional.of(@index4 + "!!")
              : ((now.getHours() < 24)
                ? optional.of(@index4 + "!!!")
                : optional.none())))
          : optional.of(@index3.format([@index0, @index2])))
        """),
    PolicyCase(
      name: "nested_rules_unconditional_chaining",
      expr: """
        cel.@block([3],
        ((x > @index0) ? optional.of("a") : ((x == @index0) ? optional.of("b") : optional.none()))
          .orValue("c"))
        """),
    PolicyCase(
      name: "nested_rules_unconditional_chaining_optional",
      expr: """
        cel.@block([3],
        ((x > @index0) ? optional.of("a") : ((x == @index0) ? optional.of("b") : optional.none()))
          .or((x == 1) ? optional.of("c") : optional.none()))
        """),
    PolicyCase(
      name: "nested_rules_unwrap_rewrap",
      expr: """
        (x == 1)
          ? optional.of(((y == 1) ? optional.of("a") : optional.none()).orValue("b"))
          : optional.none()
        """),
    PolicyCase(
      name: "agent_tool_execution_governance",
      expr: """
        (request.is_emergency ? ["REQUIRE_VP_APPROVAL"] : ((tool.is_mutation && request.env == "prod") ? ["REQUIRE_TECH_LEAD_2FA"] : (tool.is_mutation ? ["REQUIRE_PEER_CONFIRMATION"] : []))) + ((hasCreditCard(tool.call.args) ? ["REDACT_PCI"] : (hasEmailOrPhone(tool.call.args) ? ["REDACT_PII"] : [])) + ((tool.call.args.batch_size > 10000) ? ["THROTTLE_TIER_3"] : ((tool.call.args.batch_size > 1000) ? ["THROTTLE_TIER_2"] : ((tool.call.args.batch_size > 100) ? ["THROTTLE_TIER_1"] : []))))
        """,
      options: TestFunctions.agentFunctions),
  ]

  @Test(arguments: policyTests)
  func compile(_ tc: PolicyCase) throws {
    let policy = try parseTestPolicy(tc.name)
    let env = try testEnvironment(tc.name, options: tc.options)
    let compiled = try PolicyCompiler().compile(policy, environment: env)
    #expect(normalize(compiled.expression.description) == normalize(tc.expr), "\(compiled.expression)")
    verifySourceInfoCoverage(policy, compiled.expression)
    try runPolicyTests(tc.name, compiled)
  }

  struct ErrorCase: CustomTestStringConvertible, Sendable {
    var name: String
    var err: String
    var maxNestedExpressions = 100
    var testDescription: String { "\(name) \(maxNestedExpressions)" }
  }

  static let policyErrorTests: [ErrorCase] = [
    ErrorCase(
      name: "errors",
      err: """
        ERROR: testdata/errors/policy.yaml:19:1: error configuring import: invalid qualified name: punc.Import!, wanted name of the form 'qualified.name'
         |       punc.Import!
         | ^
        ERROR: testdata/errors/policy.yaml:20:12: error configuring import: invalid qualified name: bad import, wanted name of the form 'qualified.name'
         |   - name: "bad import"
         | ...........^
        ERROR: testdata/errors/policy.yaml:24:19: undeclared reference to 'spec' (in container '')
         |       expression: spec.labels
         | ..................^
        ERROR: testdata/errors/policy.yaml:25:7: invalid variable declaration: overlapping identifier for name 'variables.want'
         |     - name: want
         | ......^
        ERROR: testdata/errors/policy.yaml:28:50: Syntax error: mismatched input 'resource' expecting ')'
         |       expression: variables.want.filter(l, !(lin resource.labels))
         | .................................................^
        ERROR: testdata/errors/policy.yaml:28:66: Syntax error: extraneous input ')' expecting <EOF>
         |       expression: variables.want.filter(l, !(lin resource.labels))
         | .................................................................^
        ERROR: testdata/errors/policy.yaml:30:27: Syntax error: mismatched input '2' expecting {'}', ','}
         |       expression: "{1:305 2:569}"
         | ..........................^
        ERROR: testdata/errors/policy.yaml:38:75: Syntax error: extraneous input ']' expecting ')'
         |         "missing one or more required labels: %s".format(variables.missing])
         | ..........................................................................^
        ERROR: testdata/errors/policy.yaml:41:67: undeclared reference to 'format' (in container '')
         |         "invalid values provided on one or more labels: %s".format([variables.invalid])
         | ..................................................................^
        ERROR: testdata/errors/policy.yaml:45:16: incompatible output types: block has output type string, but previous outputs have type bool
         |       output: "'false'"
         | ...............^
        """),
    ErrorCase(
      name: "limits",
      err: """
        ERROR: testdata/limits/policy.yaml:22:14: variable exceeds nested expression limit
         |     - name: "person"
         | .............^
        """,
      maxNestedExpressions: 2),
    ErrorCase(
      name: "limits",
      err: """
        ERROR: testdata/limits/policy.yaml:30:9: rule exceeds nested expression limit
         |         id: "farewells"
         | ........^
        """,
      maxNestedExpressions: 5),
    ErrorCase(
      name: "errors_unreachable",
      err: """
        ERROR: testdata/errors_unreachable/policy.yaml:28:9: rule creates unreachable outputs
         |         match:
         | ........^
        ERROR: testdata/errors_unreachable/policy.yaml:36:13: match creates unreachable outputs
         |           - output: |
         | ............^
        ERROR: testdata/errors_unreachable/policy.yaml:38:13: Condition is always false
         |           - condition: "false"
         | ............^
        """),
    ErrorCase(
      name: "nested_incompatible_outputs",
      err: """
        ERROR: testdata/nested_incompatible_outputs/policy.yaml:22:9: incompatible output types: block has output type string, but previous outputs have type bool
         |         match:
         | ........^
        """),
    ErrorCase(
      name: "aggregate_errors",
      err: """
        ERROR: testdata/aggregate_errors/policy.yaml:21:13: match creates unreachable outputs
         |           - condition: "true"
         | ............^
        ERROR: testdata/aggregate_errors/policy.yaml:24:22: incompatible output types: block has output type int, but previous outputs have type optional_type(string)
         |             output: "403"
         | .....................^
        """),
    ErrorCase(
      name: "aggregate_list_errors",
      err: """
        ERROR: testdata/aggregate_list_errors/policy.yaml:21:13: match creates unreachable outputs
         |           - condition: "true"
         | ............^
        ERROR: testdata/aggregate_list_errors/policy.yaml:24:22: incompatible output types: block has output type int, but previous outputs have type list(string)
         |             output: "403"
         | .....................^
        """),
    ErrorCase(
      name: "aggregate_nested_mixed_semantics",
      err: """
        ERROR: testdata/aggregate_nested_mixed_semantics/policy.yaml:23:15: nested aggregate rules are not allowed
         |               aggregate:
         | ..............^
        """),
    ErrorCase(
      name: "limits",
      err: """
        ERROR: testdata/limits/policy.yaml:15:8: error configuring compiler option: nested expression limit must be non-negative, non-zero value: -1
         | name: "limits"
         | .......^
        """,
      maxNestedExpressions: -1),
  ]

  @Test(arguments: policyErrorTests)
  func compileError(_ tc: ErrorCase) throws {
    let policy = try parseTestPolicy(tc.name)
    let env = try testEnvironment(tc.name)
    let compiler = PolicyCompiler(maxNestedExpressions: tc.maxNestedExpressions)
    do {
      _ = try compiler.compile(policy, environment: env)
      Issue.record("compile(\(tc.name)) did not error, wanted \(tc.err)")
    } catch {
      #expect(error.description == tc.err)
    }
  }

  @Test func whitespaceHandling() throws {
    let cases: [(String, String)] = [
      ("folded_unambiguous", "a string expression that is folded"),
      ("folded_line_break", "a string expression that\n        is folded"),
      ("folded_line_break_indent", "a string expression that\n          is folded"),
      ("literal_unambiguous", "a string expression that is a literal block"),
      ("literal_line_break", "a string expression that\n        is a literal block"),
      ("literal_line_break_indent", "a string expression that\n          is a literal block"),
    ]
    let policy = try parseTestPolicy("yaml_parsing")
    let compiled = try PolicyCompiler().compile(policy, environment: try testEnvironment("yaml_parsing"))
    let program = try compiled.program()
    for (matchID, want) in cases {
      let result = try program.evaluate(["match_id": .string(matchID)])
      #expect(result.value == .string(want), "\(matchID)")
    }
  }

  @Test func whitespaceHandlingErrorPresentation() throws {
    let policy = try parseTestPolicy("yaml_parsing_cel_error")
    let wantErrors = [
      """
      ERROR: testdata/yaml_parsing_cel_error/policy.yaml:11:16: found no matching overload for '_+_' applied to '(string, int)'
       |         ("bar" + 1)
       | ...............^
      """,
      """
      ERROR: testdata/yaml_parsing_cel_error/policy.yaml:15:18: found no matching overload for '_+_' applied to '(string, int)'
       |           ("bar" + 1)
       | .................^
      """,
      """
      ERROR: testdata/yaml_parsing_cel_error/policy.yaml:19:16: found no matching overload for '_+_' applied to '(string, int)'
       |         ("bar" + 1)
       | ...............^
      """,
      """
      ERROR: testdata/yaml_parsing_cel_error/policy.yaml:23:18: found no matching overload for '_+_' applied to '(string, int)'
       |           ("bar" + 1)
       | .................^
      """,
    ]
    do {
      _ = try PolicyCompiler().compile(policy, environment: try testEnvironment("yaml_parsing_cel_error"))
      Issue.record("compile did not error")
    } catch {
      for want in wantErrors {
        #expect(error.description.contains(want), "\(error.description)")
      }
    }
  }

  @Test func compiledRuleHasOptionalOutput() throws {
    let env = try Environment()
    func cond(_ e: String) throws -> AST {
      try env.compile(e).ast
    }
    #expect(CompiledRule().hasOptionalOutput == false)
    #expect(CompiledRule(matches: [CompiledMatch()]).hasOptionalOutput == true)
    #expect(CompiledRule(matches: [CompiledMatch(condition: try cond("true"))]).hasOptionalOutput == false)
    #expect(CompiledRule(matches: [CompiledMatch(condition: try cond("1 < 0"))]).hasOptionalOutput == true)
    let nested = CompiledRule(matches: [CompiledMatch(condition: try cond("1 > 0"))])
    let rule = CompiledRule(matches: [
      CompiledMatch(condition: try cond("true"), nestedRule: nested),
      CompiledMatch(condition: try cond("true")),
    ])
    #expect(rule.hasOptionalOutput == false)
  }

  // MARK: - Aggregate (TestCompileYAMLPolicy_Aggregate)

  struct AggregateCase: CustomTestStringConvertible, Sendable {
    var name: String
    var policy: String
    var options: [Environment.Option] = []
    var unparsed = ""
    var evals: [([String: Value], Value)] = []
    var wantErr = ""
    var testDescription: String { name }
  }

  static let aggregateTests: [AggregateCase] = [
    AggregateCase(
      name: "eval_aggregate",
      policy: """
        name: "aggregate_policy"
        rule:
          aggregate:
            - condition: 'true'
              output: '"PII"'
            - condition: 'true'
              output: '"CONFIDENTIAL"'
        """,
      unparsed: #"["PII"] + ["CONFIDENTIAL"]"#,
      evals: [([:], .list(ArrayList(["PII", "CONFIDENTIAL"])))]),
    AggregateCase(
      name: "aggregate_with_block_variables",
      policy: """
        name: "block_policy"
        rule:
          variables:
            - name: val1
              expression: '"PII"'
            - name: val2
              expression: '"CONFIDENTIAL"'
          aggregate:
            - condition: 'true'
              output: 'variables.val1'
            - condition: 'true'
              output: 'variables.val2'
        """,
      unparsed: #"cel.@block(["PII", "CONFIDENTIAL"], [@index0] + [@index1])"#,
      evals: [([:], .list(ArrayList(["PII", "CONFIDENTIAL"])))]),
    AggregateCase(
      name: "aggregate_conditions_and_block_variables",
      policy: """
        name: "cse_policy"
        rule:
          variables:
            - name: threshold
              expression: "5"
          aggregate:
            - condition: "size(resource.payload) > variables.threshold"
              output: '"CSE1"'
            - condition: "size(resource.payload) > variables.threshold"
              output: '"CSE2"'
            - condition: 'true'
              output: '"ALWAYS"'
        """,
      options: [.variable("resource", .map(key: .string, value: .list(.int)))],
      unparsed:
        #"cel.@block([5], ((size(resource.payload) > @index0) ? ["CSE1"] : []) + (((size(resource.payload) > @index0) ? ["CSE2"] : []) + ["ALWAYS"]))"#,
      evals: [
        (
          ["resource": .map(OrderedMap([(.string("payload"), .list(ArrayList([1, 2, 3, 4, 5, 6])))]))],
          .list(ArrayList(["CSE1", "CSE2", "ALWAYS"]))
        ),
        (
          ["resource": .map(OrderedMap([(.string("payload"), .list(ArrayList([1, 2, 3])))]))],
          .list(ArrayList(["ALWAYS"]))
        ),
      ]),
    AggregateCase(
      name: "aggregate_macros_preserved",
      policy: """
        name: aggregate_macros_preserved
        rule:
          variables:
            - name: min_val
              expression: "10"
          aggregate:
            - condition: "cond"
              rule:
                match:
                  - condition: "true"
                    output: "payload.filter(x, x > variables.min_val).exists(y, y % 2 == 0)"
            - condition: "true"
              output: "payload.all(x, x > 0)"
        """,
      options: [.variable("cond", .bool), .variable("payload", .list(.int))],
      unparsed:
        "cel.@block([10], (cond ? [payload.filter(x, x > @index0).exists(y, y % 2 == 0)] : []) + [payload.all(x, x > 0)])"
    ),
    AggregateCase(
      name: "nested_aggregate_throws",
      policy: """
        name: nested_aggregate
        rule:
          aggregate:
            - condition: 'true'
              rule:
                aggregate:
                  - condition: 'true'
                    output: "'foo'"
        """,
      wantErr: "nested aggregate rules are not allowed"),
    AggregateCase(
      name: "nested_aggregate_with_match_throws",
      policy: """
        name: nested_aggregate_with_match
        rule:
          aggregate:
            - condition: 'true'
              rule:
                match:
                  - condition: 'true'
                    rule:
                      aggregate:
                        - condition: 'true'
                          output: "'foo'"
        """,
      wantErr: "nested aggregate rules are not allowed"),
    AggregateCase(
      name: "aggregate_under_match_success",
      policy: """
        name: aggregate_under_match
        rule:
          match:
            - condition: 'true'
              rule:
                aggregate:
                  - condition: 'true'
                    output: "'foo'"
        """,
      unparsed: #"["foo"]"#),
    AggregateCase(
      name: "condition_always_false",
      policy: """
        name: condition_always_false
        rule:
          aggregate:
            - condition: 'false'
              output: "'foo'"
        """,
      wantErr: "Condition is always false"),
  ]

  /// cel-go `parseAndCompilePolicy`: `cel.NewEnv` with optional types, macro call tracking and
  /// bindings.
  static func parseAndCompile(_ name: String, _ source: String, options: [Environment.Option]) throws
    -> CompiledPolicy
  {
    let policy = try PolicyParser().parse(PolicySource(source, description: name))
    var all: [Environment.Option] = [.optionalTypes, .macroCallTracking]
    if let bindings = PolicyExtensions.resolve("bindings", version: Library.latestVersion) {
      all.append(.library(bindings))
    }
    let env = try Environment(options: all + options)
    return try PolicyCompiler().compile(policy, environment: env)
  }

  @Test(arguments: aggregateTests)
  func aggregate(_ tc: AggregateCase) throws {
    if !tc.wantErr.isEmpty {
      do {
        _ = try Self.parseAndCompile(tc.name, tc.policy, options: tc.options)
        Issue.record("Compile() succeeded, wanted error \(tc.wantErr)")
      } catch {
        #expect("\(error)".contains(tc.wantErr), "\(error)")
      }
      return
    }
    let compiled = try Self.parseAndCompile(tc.name, tc.policy, options: tc.options)
    if !tc.unparsed.isEmpty {
      #expect(normalize(compiled.expression.description) == normalize(tc.unparsed), "\(compiled.expression)")
    }
    let program = try compiled.program()
    for (input, want) in tc.evals {
      let out = try program.evaluate(input).value
      #expect(out.celEquals(want) == .bool(true), "got \(out), wanted \(want)")
    }
  }

  @Test func compiledRuleSemantic() throws {
    let policy = try PolicyParser().parse(
      PolicySource(
        """
        name: aggregate_semantic
        rule:
          aggregate:
            - condition: 'true'
              output: "'foo'"
        """, description: "aggregate_semantic"))
    let (rule, errors) = compileRule(policy, env: try Environment())
    #expect(errors.isEmpty)
    #expect(rule?.semantic == .aggregate)
  }
}

/// cel-go `verifySourceInfoCoverage`: every recorded position belongs to a node of the composed
/// AST and every source line of a policy expression is covered by at least one node.
func verifySourceInfoCoverage(_ policy: Policy, _ expression: CheckedExpression, sourceLocation: SourceLocation = #_sourceLocation) {
  let ast = expression.ast
  let ids = ast.ids
  var covered = Set<Int>()
  for (id, range) in ast.sourceInfo.offsetRanges {
    if range.start <= 0 {
      Issue.record("id \(id) has invalid offset \(range.start)", sourceLocation: sourceLocation)
    }
    if !ids.contains(id) {
      Issue.record("id \(id) not found in AST", sourceLocation: sourceLocation)
    }
    if let loc = policy.source.offsetLocation(range.start) {
      covered.insert(loc.line)
    }
  }
  var lines = Set<Int>()
  func add(_ vs: Policy.ValueString) {
    guard let range = policy.sourceInfo.offsetRange(vs.id), let start = policy.source.offsetLocation(range.start) else {
      return
    }
    let text = vs.value
    if text.unicodeScalars.contains("'") && text.contains("'''") || text.contains("\"\"\"") {
      return
    }
    let count = text.unicodeScalars.filter { $0 == "\n" }.count
    for i in 0...count {
      lines.insert(start.line + i)
    }
  }
  func traverse(_ r: Policy.Rule) {
    for v in r.variables {
      add(v.expression)
    }
    for m in r.matches {
      if !m.condition.value.hasPrefix("true") {
        add(m.condition)
      }
      if let output = m.output {
        add(output)
      }
      if let nested = m.rule {
        traverse(nested)
      }
    }
  }
  if let rule = policy.rule {
    traverse(rule)
  }
  for line in lines.sorted() where !covered.contains(line) {
    Issue.record("Line \(line) expected to be covered by SourceInfo, but was not", sourceLocation: sourceLocation)
  }
}
