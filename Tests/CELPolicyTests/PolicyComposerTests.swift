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

// Ported from cel-go policy/composer_test.go and the composerUnnestTests table of
// policy/helper_test.go.

import CEL
import Testing

@testable import CELPolicy

struct PolicyComposerTests {
  struct ComposeCase: CustomTestStringConvertible, Sendable {
    var name: String
    var policy: String
    var unnestHeight = 25
    var wantUnparsed = ""
    var wantEval: Value?
    var checkInfo = false
    var testDescription: String { name }
  }

  static let composeTests: [ComposeCase] = [
    ComposeCase(
      name: "source_info",
      policy: """
        name: test_policy
        rule:
          match:
            - condition: "2 == 1"
              output: "'hi'"
            - output: "'hello' + ' world'"

        """,
      checkInfo: true),
    ComposeCase(
      name: "unnest",
      policy: """
        name: unnest
        rule:
          match:
            - condition: "2 == 1"
              output: "'hi'"
            - output: "'hello'"

        """,
      unnestHeight: 1,
      checkInfo: true),
    ComposeCase(
      name: "empty_aggregate",
      policy: """
        name: empty_nested_match_under_aggregate
        rule:
          aggregate:
            - condition: "true"
              rule:
                match: []

        """,
      wantUnparsed: "[]",
      wantEval: .list(ArrayList([]))),
    ComposeCase(
      name: "conditional_optional_nested",
      policy: """
        name: conditional_optional_nested
        rule:
          match:
            - condition: "2 == 2"
              rule:
                match:
                  - condition: "1 == 1"
                    output: "'foo'"
            - condition: "true"
              rule:
                match:
                  - condition: "3 == 3"
                    output: "'bar'"

        """,
      wantUnparsed:
        #"(2 == 2) ? ((1 == 1) ? optional.of("foo") : optional.none()) : ((3 == 3) ? optional.of("bar") : optional.none())"#,
      wantEval: .optional(.string("foo"))),
  ]

  /// cel-go `parseAndComposeRule`: `cel.NewEnv(cel.OptionalTypes(), ext.Bindings())`.
  static func parseAndComposeRule(_ policyYAML: String, _ filename: String, unnestHeight: Int = 25) throws
    -> (Environment, CompiledRule, CheckedExpression)
  {
    let policy = try PolicyParser().parse(PolicySource(policyYAML, description: filename))
    let env = try Environment(options: [.optionalTypes]).withPolicySupport()
    let (rule, errors) = compileRule(policy, env: env)
    #expect(errors.isEmpty, "\(errors)")
    let compiledRule = try #require(rule)
    let composer = try RuleComposer(env: env, exprUnnestHeight: unnestHeight)
    let (ast, composeErrors) = composer.compose(compiledRule)
    let composed = try #require(ast, "\(composeErrors)")
    return (env, compiledRule, CheckedExpression(ast: composed, source: policy.source))
  }

  @Test(arguments: composeTests)
  func compose(_ tc: ComposeCase) throws {
    let (env, rule, composed) = try Self.parseAndComposeRule(
      tc.policy, "\(tc.name).yaml", unnestHeight: tc.unnestHeight)
    if tc.checkInfo {
      #expect(composed.ast.sourceInfo.description == "\(tc.name).yaml")
      verifySourceInfoTransfer(rule, composed.ast)
    }
    if !tc.wantUnparsed.isEmpty {
      #expect(normalize(composed.description) == normalize(tc.wantUnparsed), "\(composed)")
    }
    if let want = tc.wantEval {
      let result = try env.program(composed).evaluate().value
      #expect(result.celEquals(want) == .bool(true), "\(result)")
    }
  }

  /// A composer combining two unconditional non-optional steps: the first wins
  /// (cel-go `testUnconditionalComposer`).
  static func unconditionalComposer(_ ctx: inout OptimizerContext) {
    let trueCond = ctx.newConstant(.bool(true))
    let out1 = ctx.newConstant(.string("first"))
    let out2 = ctx.newConstant(.string("second"))
    let s = CompositionStep(isOptional: false, condition: trueCond, expr: out1)
    let step = CompositionStep(isOptional: false, condition: trueCond, expr: out2)
    ctx.ast.expr = s.combine(&ctx, step).expr
  }

  // Unreachable through the policy format (the compiler rejects unreachable outputs), but kept
  // for defense in depth.
  @Test func nonOptionalCompositionStepUnconditionalCombine() throws {
    let env = try Environment()
    let dummy = try env.compile("true")
    let result = try env.optimize(dummy, pass: Self.unconditionalComposer)
    #expect(result.description == #""first""#)
  }

  @Test func ruleComposerError() throws {
    #expect {
      _ = try RuleComposer(env: try Environment(), exprUnnestHeight: -1)
    } throws: { error in
      "\(error)".contains("invalid unnest")
    }
  }

  struct UnnestCase: CustomTestStringConvertible, Sendable {
    var name: String
    var unnestHeight: Int
    var composed: String
    var options: [Environment.Option] = []
    var outputType: CELType
    var testDescription: String { "\(name) \(unnestHeight)" }
  }

  static let composerUnnestTests: [UnnestCase] = [
    UnnestCase(
      name: "unnest",
      unnestHeight: 2,
      composed: """
        cel.@block([
          values.filter(x, x > 2),
          @index0.size() == 0,
          @index1 ? false : @index0.all(x, x % 2 == 0),
          values.map(x, x * x * x).exists(x, x % 6 == 0)
            ? optional.of("at least one power of 6")
          : optional.none(),
          values.map(x, x * 3).exists(x, x % 4 == 0)
            ? optional.of("at least one divisible by 4")
          : @index3],
          @index2 ? optional.of("some divisible by 2") : @index4)
        """,
      outputType: .optional(.string)),
    UnnestCase(
      name: "limits",
      unnestHeight: 3,
      composed: """
        cel.@block([
          "hello",
          "goodbye",
          "me",
          "%s, %s",
          @index3.format([@index1, @index2]),
          (now.getHours() < 24) ? optional.of(@index4 + "!!!") : optional.none(),
          optional.of(@index3.format([@index0, @index2]))],
          (now.getHours() >= 20)
          ? ((now.getHours() < 21) ? optional.of(@index4 + "!") :
            ((now.getHours() < 22) ? optional.of(@index4 + "!!") : @index5))
          : @index6)
        """,
      outputType: .optional(.string)),
    UnnestCase(
      name: "limits",
      unnestHeight: 4,
      composed: """
        cel.@block([
          "hello",
          "goodbye",
          "me",
          "%s, %s",
          @index3.format([@index1, @index2]),
          (now.getHours() < 22) ? optional.of(@index4 + "!!") :
          ((now.getHours() < 24) ? optional.of(@index4 + "!!!") : optional.none())],
          (now.getHours() >= 20)
          ? ((now.getHours() < 21) ? optional.of(@index4 + "!") : @index5)
          : optional.of(@index3.format([@index0, @index2])))
        """,
      outputType: .optional(.string)),
    UnnestCase(
      name: "limits",
      unnestHeight: 5,
      composed: """
        cel.@block([
          "hello",
          "goodbye",
          "me",
          "%s, %s",
          @index3.format([@index1, @index2]),
          (now.getHours() < 21) ? optional.of(@index4 + "!") :
          ((now.getHours() < 22) ? optional.of(@index4 + "!!") :
          ((now.getHours() < 24) ? optional.of(@index4 + "!!!") : optional.none()))],
          (now.getHours() >= 20) ? @index5 : optional.of(@index3.format([@index0, @index2])))
        """,
      outputType: .optional(.string)),
    UnnestCase(
      name: "agent_tool_execution_governance",
      unnestHeight: 2,
      composed:
        #"cel.@block([tool.is_mutation && request.env == "prod", tool.is_mutation ? ["REQUIRE_PEER_CONFIRMATION"] : [], hasEmailOrPhone(tool.call.args) ? ["REDACT_PII"] : [], tool.call.args.batch_size > 10000, tool.call.args.batch_size > 1000, tool.call.args.batch_size > 100, request.is_emergency ? ["REQUIRE_VP_APPROVAL"] : (@index0 ? ["REQUIRE_TECH_LEAD_2FA"] : @index1)], @index6 + ((hasCreditCard(tool.call.args) ? ["REDACT_PCI"] : @index2) + (@index3 ? ["THROTTLE_TIER_3"] : (@index4 ? ["THROTTLE_TIER_2"] : (@index5 ? ["THROTTLE_TIER_1"] : [])))))"#,
      options: TestFunctions.agentFunctions,
      outputType: .list(.string)),
  ]

  /// cel-go `TestRuleComposerUnnest`: compiles the rule in the test environment, composes it
  /// with a small unnest height, and runs the policy's tests against the result.
  @Test(arguments: composerUnnestTests)
  func ruleComposerUnnest(_ tc: UnnestCase) throws {
    let policy = try parseTestPolicy(tc.name)
    let env = try testEnvironment(tc.name, options: tc.options).withPolicySupport()
    let (rule, errors) = compileRule(policy, env: env)
    #expect(errors.isEmpty, "\(errors)")
    let compiledRule = try #require(rule)
    let composer = try RuleComposer(env: env, exprUnnestHeight: tc.unnestHeight)
    let (ast, composeErrors) = composer.compose(compiledRule)
    let composed = CheckedExpression(ast: try #require(ast, "\(composeErrors)"), source: policy.source)
    verifySourceInfoCoverage(policy, composed)
    #expect(normalize(composed.description) == normalize(tc.composed), "\(composed)")
    #expect(composed.outputType == tc.outputType)
    try runPolicyTests(tc.name, CompiledPolicy(expression: composed, environment: env))
  }
}

/// cel-go `verifySourceInfoTransfer`: every positioned node of the compiled rule has a node with
/// the same range and the same text in the composed AST.
func verifySourceInfoTransfer(
  _ rule: CompiledRule, _ composed: AST, sourceLocation: SourceLocation = #_sourceLocation
) {
  var dstRanges: [OffsetRange: Expr] = [:]
  composed.expr.postOrderVisit(expr: { e in
    if let range = composed.sourceInfo.offsetRange(e.id) {
      dstRanges[range] = e
    }
  })
  func check(_ a: AST?) {
    guard let a else {
      return
    }
    a.expr.postOrderVisit(expr: { src in
      guard let srcRange = a.sourceInfo.offsetRange(src.id), srcRange.start != 0 else {
        // Skips the synthetic `true` default condition, which has no real position.
        return
      }
      guard let dst = dstRanges[srcRange] else {
        Issue.record(
          "composed node not found for rule node: \(ExprDebug.toDebugString(src))", sourceLocation: sourceLocation)
        return
      }
      if let ident = dst.asIdent, ident.hasPrefix("@index") {
        return
      }
      let dstText = try? Unparser.unparse(dst, sourceInfo: composed.sourceInfo)
      let srcText = try? Unparser.unparse(src, sourceInfo: a.sourceInfo)
      if srcText != dstText {
        Issue.record(
          "mismatched nodes, rule: \(srcText ?? "<nil>") composed: \(dstText ?? "<nil>")",
          sourceLocation: sourceLocation)
      }
    })
  }
  for v in rule.variables {
    check(v.expr)
  }
  for m in rule.matches {
    check(m.condition)
    if let output = m.output {
      check(output.expr)
    } else if let nested = m.nestedRule {
      verifySourceInfoTransfer(nested, composed, sourceLocation: sourceLocation)
    }
  }
}
