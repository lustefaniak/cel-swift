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

// Ported from cel-go policy/compiler.go.

import CEL

/// A compiled rule: variables and match blocks (cel-go `CompiledRule`).
package struct CompiledRule: Sendable {
  package var sourceID: Int64
  package var id: Policy.ValueString?
  package var variables: [CompiledVariable]
  package var matches: [CompiledMatch]
  package var semantic: Policy.Semantic
  /// The policy file the rule was compiled from; the composed AST reports positions in it.
  package var source: PolicySource?

  package init(
    sourceID: Int64 = 0, id: Policy.ValueString? = nil, variables: [CompiledVariable] = [],
    matches: [CompiledMatch] = [], semantic: Policy.Semantic = .firstMatch, source: PolicySource? = nil
  ) {
    self.sourceID = sourceID
    self.id = id
    self.variables = variables
    self.matches = matches
    self.semantic = semantic
    self.source = source
  }

  /// The output type of the first match; all are checked for agreement (cel-go `OutputType`).
  package var outputType: CELType {
    guard let m = matches.first else {
      return .dyn
    }
    if semantic == .aggregate {
      return .list(m.outputType)
    }
    return m.outputType
  }

  /// Whether the rule may produce no output, i.e. its result is optional
  /// (cel-go `HasOptionalOutput`).
  package var hasOptionalOutput: Bool {
    if semantic == .aggregate {
      return false
    }
    var optionalOutput = false
    for m in matches {
      if let nested = m.nestedRule, nested.hasOptionalOutput {
        if !m.conditionIsLiteral(true) {
          return true
        }
        optionalOutput = true
      } else if m.conditionIsLiteral(true) {
        return false
      } else {
        optionalOutput = true
      }
    }
    return optionalOutput
  }
}

/// A compiled variable (cel-go `CompiledVariable`).
package struct CompiledVariable: Sendable {
  package var sourceID: Int64
  package var name: String
  /// The compiled expression, `nil` when it failed to compile.
  package var expr: AST?
  package var declaration: VariableDecl
}

/// A compiled match: a condition and either an output or a nested rule (cel-go `CompiledMatch`).
package struct CompiledMatch: Sendable {
  package var sourceID: Int64
  /// The compiled condition, `nil` when it failed to compile.
  package var condition: AST?
  package var output: OutputValue?
  package var nestedRule: CompiledRule?

  package init(sourceID: Int64 = 0, condition: AST? = nil, output: OutputValue? = nil, nestedRule: CompiledRule? = nil) {
    self.sourceID = sourceID
    self.condition = condition
    self.output = output
    self.nestedRule = nestedRule
  }

  /// Whether the condition is the literal `value` (cel-go `ConditionIsLiteral`).
  package func conditionIsLiteral(_ value: Bool) -> Bool {
    guard let condition, case .literal(.bool(let b)) = condition.expr.kind else {
      return false
    }
    return b == value
  }

  /// The type of the output or of the nested rule's output (cel-go `OutputType`).
  package var outputType: CELType {
    if let output {
      return output.expr.map { $0.type(of: $0.expr.id) } ?? .error
    }
    if let nestedRule {
      return nestedRule.outputType
    }
    return .dyn
  }
}

/// A compiled output expression (cel-go `OutputValue`).
package struct OutputValue: Sendable {
  package var sourceID: Int64
  /// The compiled output, `nil` when it failed to compile.
  package var expr: AST?
}

/// Options for the policy compiler (cel-go `CompilerOption`).
package struct PolicyCompilerOptions: Sendable {
  /// Limits the number of variable and nested rule expressions (cel-go `MaxNestedExpressions`).
  package var maxNestedExpressions = 100
  /// Compiles match outputs (cel-go `CompileMatchOutput`); the default compiles the output
  /// expression in the rule environment.
  package var compileMatchOutput: CompileMatchOutput?

  package init(maxNestedExpressions: Int = 100) {
    self.maxNestedExpressions = maxNestedExpressions
  }
}

/// Compiles the output of a match: the rule environment, a relative source and an error reporter
/// are available through the compiler (cel-go `CompileMatchOutputFunc`).
package typealias CompileMatchOutput =
  @Sendable (_ compiler: MatchCompiler, _ match: Policy.Match, _ policy: Policy) -> (ast: AST?, errors: CELErrors?)

/// What a match output compiler can use (cel-go `MatchCompiler`).
package struct MatchCompiler {
  package let env: PolicyEnvironment
  let relSource: (Policy.ValueString) -> RelativeSource

  /// The source of a policy string, positioned within the policy file (cel-go `RelSource`).
  package func relativeSource(_ string: Policy.ValueString) -> RelativeSource {
    relSource(string)
  }
}

/// Compiles a policy into a single checked expression (cel-go `policy.Compile`).
package func compilePolicy(
  _ policy: Policy, env: PolicyEnvironment, options: PolicyCompilerOptions = PolicyCompilerOptions()
) -> (ast: AST?, errors: PolicyError) {
  let (rule, errors) = compileRule(policy, env: env, options: options)
  guard let rule, errors.isEmpty else {
    return (nil, errors)
  }
  let (ast, composeErrors) = RuleComposer(env: env).compose(rule)
  var result = PolicyError(source: policy.source)
  result.errors = result.errors.appending(composeErrors.errors)
  return (ast, result)
}

/// Compiles a policy's rule tree (cel-go `policy.CompileRule`).
package func compileRule(
  _ policy: Policy, env: PolicyEnvironment, options: PolicyCompilerOptions = PolicyCompilerOptions()
) -> (rule: CompiledRule?, errors: PolicyError) {
  var c = PolicyRuleCompiler(policy: policy, env: env, options: options)
  if options.maxNestedExpressions <= 0 {
    c.reportError(
      atID: policy.name.id,
      "error configuring compiler option: nested expression limit must be non-negative, non-zero value: \(options.maxNestedExpressions)"
    )
    return (nil, c.errors)
  }
  if !policy.imports.isEmpty {
    var importNames: [String] = []
    for imp in policy.imports {
      let typeName = imp.name.value
      do {
        _ = try Container(.abbreviations(typeName))
        importNames.append(typeName)
      } catch {
        c.reportError(atID: imp.name.id, "error configuring import: \(error)")
      }
    }
    do {
      try c.env.addAbbreviations(importNames)
    } catch {
      c.reportError(atID: policy.imports[0].sourceID, "error configuring imports: \(error)")
    }
  }
  guard let rule = policy.rule else {
    return (nil, c.errors)
  }
  let compiled = c.compile(rule, ruleEnv: c.env, hasAggregateAncestor: false)
  return (compiled, c.errors)
}

/// The variables namespace (cel-go `variablePrefix`).
let policyVariablePrefix = "variables"

/// Port of cel-go's `compiler` struct.
struct PolicyRuleCompiler {
  let policy: Policy
  var env: PolicyEnvironment
  let options: PolicyCompilerOptions
  var errors: PolicyError
  var nestedCount = 0

  init(policy: Policy, env: PolicyEnvironment, options: PolicyCompilerOptions) {
    self.policy = policy
    self.env = env
    self.options = options
    self.errors = PolicyError(source: policy.source)
  }

  mutating func reportError(atID id: Int64, _ message: String) {
    errors.report(id: id, location: policy.sourceInfo.startLocation(id), message: message)
  }

  mutating func append(_ errs: CELErrors) {
    errors.errors = errors.errors.appending(errs.errors)
  }

  mutating func compile(_ r: Policy.Rule, ruleEnv: PolicyEnvironment, hasAggregateAncestor: Bool) -> CompiledRule {
    var ruleEnv = ruleEnv
    if hasAggregateAncestor && r.semantic == .aggregate {
      reportError(atID: r.sourceID, "nested aggregate rules are not allowed")
    }
    var compiledVars: [CompiledVariable] = []
    for v in r.variables {
      let exprSrc = relSource(v.expression)
      let (varAST, exprErrs) = ruleEnv.compile(exprSrc)
      let varName = v.name.value
      var varType = CELType.dyn
      if let varAST {
        varType = varAST.type(of: varAST.expr.id)
      } else {
        append(exprErrs)
      }
      let decl = VariableDecl(name: "\(policyVariablePrefix).\(varName)", type: varType)
      do {
        try ruleEnv.declare(variables: [decl])
      } catch {
        reportError(atID: v.sourceID, "invalid variable declaration: \(error)")
      }
      let compiled = CompiledVariable(sourceID: v.name.id, name: varName, expr: varAST, declaration: decl)
      compiledVars.append(compiled)
      nestedCount += 1
      if nestedCount == options.maxNestedExpressions + 1 {
        reportError(atID: compiled.sourceID, "variable exceeds nested expression limit")
      }
    }

    var compiledMatches: [CompiledMatch] = []
    for m in r.matches {
      let condSrc = relSource(m.condition)
      let (condAST, condErrs) = ruleEnv.compile(condSrc)
      append(condErrs)
      if m.output != nil && m.rule != nil {
        reportError(atID: m.condition.id, "either output or rule may be set but not both")
        continue
      }
      if let output = m.output {
        let (outAST, outErrs): (AST?, CELErrors?)
        if let custom = options.compileMatchOutput {
          let mc = MatchCompiler(env: ruleEnv, relSource: { [self] in self.relSource($0) })
          (outAST, outErrs) = custom(mc, m, policy)
        } else {
          let (a, e) = ruleEnv.compile(relSource(output))
          (outAST, outErrs) = (a, e)
        }
        if let outErrs {
          append(outErrs)
        }
        compiledMatches.append(
          CompiledMatch(
            sourceID: m.sourceID, condition: condAST,
            output: OutputValue(sourceID: output.id, expr: outAST)))
        continue
      }
      if let rule = m.rule {
        let nextHasAggregateAncestor = hasAggregateAncestor || r.semantic == .aggregate
        let nested = compile(rule, ruleEnv: ruleEnv, hasAggregateAncestor: nextHasAggregateAncestor)
        compiledMatches.append(CompiledMatch(sourceID: m.sourceID, condition: condAST, nestedRule: nested))
        nestedCount += 1
        if nestedCount == options.maxNestedExpressions + 1 {
          reportError(atID: nested.sourceID, "rule exceeds nested expression limit")
        }
      }
    }

    let rule = CompiledRule(
      sourceID: r.sourceID, id: r.id, variables: compiledVars, matches: compiledMatches,
      semantic: r.semantic, source: policy.source)
    checkMatchOutputTypesAgree(rule)
    checkUnreachableCode(rule)
    return rule
  }

  mutating func checkMatchOutputTypesAgree(_ rule: CompiledRule) {
    var outputType: CELType?
    for m in rule.matches {
      if outputType == nil {
        outputType = m.outputType
        if outputType == .error {
          outputType = nil
          continue
        }
      }
      let matchOutputType = m.outputType
      if matchOutputType == .error {
        continue
      }
      guard let current = outputType else {
        continue
      }
      if !(current.isAssignable(from: matchOutputType) || matchOutputType.isAssignable(from: current)) {
        var sourceID = m.sourceID
        if let output = m.output {
          sourceID = output.sourceID
        } else if let nested = m.nestedRule {
          sourceID = nested.sourceID
        }
        reportError(
          atID: sourceID,
          "incompatible output types: block has output type \(matchOutputType), but previous outputs have type \(current)"
        )
        return
      }
    }
  }

  mutating func checkUnreachableCode(_ rule: CompiledRule) {
    let matches = rule.matches
    for i in stride(from: matches.count - 1, through: 0, by: -1) {
      let m = matches[i]
      let triviallyTrue = m.conditionIsLiteral(true)
      if m.conditionIsLiteral(false) {
        reportError(atID: m.sourceID, "Condition is always false")
      }
      let isExhaustive = triviallyTrue && !(m.nestedRule?.hasOptionalOutput ?? false)
      if rule.semantic == .firstMatch && isExhaustive && i != matches.count - 1 {
        if m.output != nil {
          reportError(atID: m.sourceID, "match creates unreachable outputs")
        }
        if let nested = m.nestedRule {
          reportError(atID: nested.sourceID, "rule creates unreachable outputs")
        }
        break
      }
    }
  }

  /// The relative source of a policy string (cel-go `relSource`).
  func relSource(_ pstr: Policy.ValueString) -> RelativeSource {
    var line = 0
    var col = 1
    if let offset = policy.sourceInfo.offsetRange(pstr.id),
      let loc = policy.source.offsetLocation(offset.start)
    {
      line = loc.line
      col = loc.column
    }
    return policy.source.relative(pstr.value, line: line, column: col)
  }
}
