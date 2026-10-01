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

// Ported from cel-go policy/composer.go.

import CEL

/// Stitches the rules of a compiled policy into a single `cel.@block` expression
/// (cel-go `RuleComposer`).
package struct RuleComposer: Sendable {
  let env: Environment
  /// The height at which nested expressions are split into `cel.@block` slots
  /// (cel-go `ExpressionUnnestHeight`).
  let exprUnnestHeight: Int

  /// Creates a composer.
  ///
  /// - Throws: ``EnvironmentError`` when the unnest height is not positive.
  package init(env: Environment, exprUnnestHeight: Int = 25) throws {
    if exprUnnestHeight <= 0 {
      throw EnvironmentError("invalid unnest height: value must be positive: \(exprUnnestHeight)")
    }
    self.env = env
    self.exprUnnestHeight = exprUnnestHeight
  }

  package init(env: Environment) {
    self.env = env
    self.exprUnnestHeight = 25
  }

  /// Composes a compiled rule into a single checked AST (cel-go `Compose`).
  package func compose(_ rule: CompiledRule) -> (ast: AST?, errors: CELErrors) {
    let (ruleRoot, rootErrors) = env.compileSource(TextSource("true"))
    let source: any Source = rule.source ?? TextSource("true")
    guard let ruleRoot else {
      return (nil, rootErrors)
    }
    let composer = RuleComposerPass(rule: rule)
    let (composed, errors, composedSource) = optimize(
      composer, env: env, ast: ruleRoot, source: TextSource("true"), sourceOverride: source)
    guard let composed else {
      return (nil, errors)
    }
    let unnester = RuleUnnesterPass(
      nextVarIndex: composer.state.varIndices.count, varIndices: composer.state.varIndices,
      exprUnnestHeight: exprUnnestHeight)
    let (unnested, unnestErrors, _) = optimize(unnester, env: env, ast: composed, source: composedSource)
    return (unnested, unnestErrors)
  }
}

struct VarIndex {
  var index: Int
  var indexVar: String
  var localVar: String
  var expr: Expr
  var celType: CELType
}

final class ComposerState {
  var nextVarIndex = 0
  var varIndices: [VarIndex] = []
  var scopes: [[String: Int]] = []
}

/// cel-go `ruleComposerImpl`.
struct RuleComposerPass: ASTOptimizer {
  let rule: CompiledRule
  let state = ComposerState()

  func lookupLocal(_ name: String) -> Int? {
    for scope in state.scopes.reversed() {
      if let idx = scope[name] {
        return idx
      }
    }
    return nil
  }

  func optimize(_ ctx: OptimizerContext, _ ast: AST) -> AST {
    let ruleExpr = optimizeRule(ctx, rule, asList: false)
    if state.varIndices.isEmpty {
      return ctx.newAST(ruleExpr)
    }
    var varExprs: [Expr] = []
    for vi in state.varIndices {
      varExprs.append(vi.expr)
      do {
        try ctx.extendEnv(variables: [VariableDecl(name: vi.indexVar, type: vi.celType)])
      } catch {
        ctx.reportError(atID: ruleExpr.id, "\(error)")
      }
    }
    let blockExpr = ctx.newCall("cel.@block", [ctx.newList(varExprs), ruleExpr])
    return ctx.newAST(blockExpr)
  }

  func optimizeRule(_ ctx: OptimizerContext, _ r: CompiledRule, asList: Bool) -> Expr {
    state.scopes.append([:])
    defer { state.scopes.removeLast() }
    for v in r.variables {
      registerVariable(ctx, v)
    }
    let isAggregate = r.semantic == .aggregate
    let returnList = isAggregate || asList
    var output = createBaseStep(ctx, returnList: returnList, hasOptionalOutput: r.hasOptionalOutput)

    for m in r.matches.reversed() {
      let cond = m.condition.map { ctx.copyASTAndMetadata($0) } ?? ctx.newLiteral(.bool(true))
      let currentStep: CompositionStep
      if let outputValue = m.output {
        var out = outputValue.expr.map { ctx.copyASTAndMetadata($0) } ?? ctx.newLiteral(.null)
        if returnList {
          out = ctx.newList([out])
        }
        currentStep = CompositionStep(ctx: ctx, isOptional: false, condition: cond, expr: out)
      } else if let child = m.nestedRule {
        let nested = optimizeRule(ctx, child, asList: returnList)
        currentStep = CompositionStep(ctx: ctx, isOptional: child.hasOptionalOutput, condition: cond, expr: nested)
      } else {
        ctx.reportError(atID: cond.id, "unknown match kind: \(m.sourceID)")
        return cond
      }
      if isAggregate {
        output = combineAggregate(ctx, currentStep, output)
      } else {
        output = currentStep.combine(output)
      }
    }

    var matchExpr = output?.expr ?? ctx.newLiteral(.null)
    rewriteVariableNames(ctx, &matchExpr)
    return matchExpr
  }

  func createBaseStep(_ ctx: OptimizerContext, returnList: Bool, hasOptionalOutput: Bool) -> CompositionStep? {
    if returnList {
      return CompositionStep(ctx: ctx, isOptional: false, condition: ctx.newLiteral(.bool(true)), expr: ctx.newList([]))
    }
    if hasOptionalOutput {
      return CompositionStep(
        ctx: ctx, isOptional: true, condition: ctx.newLiteral(.bool(true)), expr: ctx.newCall("optional.none", []))
    }
    return nil
  }

  func combineAggregate(_ ctx: OptimizerContext, _ step: CompositionStep, _ accumulated: CompositionStep?)
    -> CompositionStep
  {
    let trueCondition = ctx.newLiteral(.bool(true))
    let currentListPart = step.expr
    let conditionalListPart: Expr
    if step.isConditional {
      let emptyList = ctx.newList([])
      conditionalListPart = ctx.newCall(Operators.conditional, [step.condition, currentListPart, emptyList])
    } else {
      conditionalListPart = currentListPart
    }
    guard let accumulated else {
      return CompositionStep(ctx: ctx, isOptional: false, condition: trueCondition, expr: conditionalListPart)
    }
    if case .list(let l) = accumulated.expr.kind, l.elements.isEmpty {
      return CompositionStep(ctx: ctx, isOptional: false, condition: trueCondition, expr: conditionalListPart)
    }
    let concatenated = ctx.newCall(Operators.add, [conditionalListPart, accumulated.expr])
    return CompositionStep(ctx: ctx, isOptional: false, condition: trueCondition, expr: concatenated)
  }

  func rewriteVariableNames(_ ctx: OptimizerContext, _ expr: inout Expr) {
    expr.postOrderTransform { e in
      guard let name = e.asIdent, name.utf8.starts(with: "variables.".utf8), let idx = lookupLocal(name) else {
        return
      }
      ctx.updateExpr(&e, ctx.newIdent(state.varIndices[idx].indexVar))
    }
  }

  func registerVariable(_ ctx: OptimizerContext, _ v: CompiledVariable) {
    let varName = "variables.\(v.name)"
    let indexVar = "@index\(state.nextVarIndex)"
    var varExpr = v.expr.map { ctx.copyASTAndMetadata($0) } ?? ctx.newLiteral(.null)
    rewriteVariableNames(ctx, &varExpr)
    state.varIndices.append(
      VarIndex(
        index: state.nextVarIndex, indexVar: indexVar, localVar: varName, expr: varExpr,
        celType: v.declaration.type))
    if !state.scopes.isEmpty {
      state.scopes[state.scopes.count - 1][varName] = state.varIndices.count - 1
    }
    state.nextVarIndex += 1
  }
}

/// cel-go `ruleUnnesterImpl`.
struct RuleUnnesterPass: ASTOptimizer {
  final class State {
    var nextVarIndex: Int
    var varIndices: [VarIndex]

    init(nextVarIndex: Int, varIndices: [VarIndex]) {
      self.nextVarIndex = nextVarIndex
      self.varIndices = varIndices
    }
  }

  let state: State
  let exprUnnestHeight: Int

  init(nextVarIndex: Int, varIndices: [VarIndex], exprUnnestHeight: Int) {
    self.state = State(nextVarIndex: nextVarIndex, varIndices: varIndices)
    self.exprUnnestHeight = exprUnnestHeight
  }

  func optimize(_ ctx: OptimizerContext, _ a: AST) -> AST {
    var ruleExpr = a.expr
    var varExprs: [Expr] = []
    var varDecls: [VariableDecl] = []
    let unnestOffset = state.nextVarIndex
    if let call = ruleExpr.asCall, call.function == "cel.@block", call.args.count == 2 {
      ruleExpr = call.args[1]
      let count = call.args[0].asList?.elements.count ?? 0
      if count != state.varIndices.count {
        ctx.reportError(atID: ruleExpr.id, "ast block list and computed one have different sizes")
        return a
      }
      for vi in state.varIndices {
        varDecls.append(VariableDecl(name: vi.indexVar, type: vi.celType))
        varExprs.append(vi.expr)
      }
    }
    if !varDecls.isEmpty {
      do {
        try ctx.extendEnv(variables: varDecls)
      } catch {
        ctx.reportError(atID: ruleExpr.id, "\(error)")
      }
    }

    // Types of the checked rule expression, for the unnested slot declarations.
    maybeUnnestRule(ctx, &ruleExpr, typeOf: { a.type(of: $0) })
    if state.varIndices.isEmpty {
      return a
    }
    for i in unnestOffset..<state.varIndices.count {
      let vi = state.varIndices[i]
      varExprs.append(vi.expr)
      do {
        try ctx.extendEnv(variables: [VariableDecl(name: vi.indexVar, type: vi.celType)])
      } catch {
        ctx.reportError(atID: ruleExpr.id, "\(error)")
      }
    }
    let blockExpr = ctx.newCall("cel.@block", [ctx.newList(varExprs), ruleExpr])
    return ctx.newAST(blockExpr)
  }

  func maybeUnnestRule(_ ctx: OptimizerContext, _ ruleExpr: inout Expr, typeOf: (Int64) -> CELType) {
    var heights = AST(expr: ruleExpr, sourceInfo: SourceInfo(source: nil)).heights
    var unnestMap: [Int64: Bool] = [:]
    var unnestExprs: [NavigableExpr] = []
    let root = NavigableExpr(root: ruleExpr)
    _ = root.matchDescendants { e in
      if case .comprehension(let c) = e.expr.kind {
        for id in comprehensionSubExprIDs(c) {
          unnestMap[id] = nil
        }
        return false
      }
      guard case .call = e.expr.kind else {
        return false
      }
      let height = heights[e.id] ?? 0
      if height < exprUnnestHeight {
        return false
      }
      unnestMap[e.id] = true
      unnestExprs.append(e)
      return true
    }
    // Stable sort by height.
    let sorted = unnestExprs.enumerated().sorted { lhs, rhs in
      let ha = heights[lhs.element.id] ?? 0
      let hb = heights[rhs.element.id] ?? 0
      return ha != hb ? ha < hb : lhs.offset < rhs.offset
    }.map(\.element)

    var idx = 0
    while idx < sorted.count - 1 {
      defer { idx += 1 }
      let e = sorted[idx]
      guard unnestMap[e.id] == true else {
        continue
      }
      let height = heights[e.id] ?? 0
      if height < exprUnnestHeight {
        continue
      }
      reduceHeight(&heights, e, exprUnnestHeight)
      registerUnnestVariable(ctx, &ruleExpr, e.id, type: typeOf(e.id))
    }
  }

  func registerUnnestVariable(_ ctx: OptimizerContext, _ ruleExpr: inout Expr, _ id: Int64, type: CELType) {
    let indexVar = "@index\(state.nextVarIndex)"
    // The current state of the node, with already unnested descendants replaced.
    guard let current = ruleExpr.node(id: id) else {
      return
    }
    let copy = ctx.copyASTAndMetadata(ctx.newAST(current))
    state.varIndices.append(
      VarIndex(index: state.nextVarIndex, indexVar: indexVar, localVar: "", expr: copy, celType: type))
    ctx.updateExpr(in: &ruleExpr, id: id, ctx.newIdent(indexVar))
    state.nextVarIndex += 1
  }
}

func comprehensionSubExprIDs(_ c: Expr.Comprehension) -> [Int64] {
  var ids: [Int64] = []
  for e in [c.accuInit, c.loopCondition, c.loopStep, c.result] {
    e.preOrderVisit(expr: { ids.append($0.id) })
  }
  return ids
}

func reduceHeight(_ heights: inout [Int64: Int], _ e: NavigableExpr, _ amount: Int) {
  var current: NavigableExpr? = e
  while let node = current {
    let height = heights[node.id] ?? 0
    if height < amount {
      return
    }
    heights[node.id] = height - amount
    current = node.parent
  }
}

/// An intermediate stage of composition: a condition and an output, optional or not
/// (cel-go `compositionStep`, `nonOptionalCompositionStep`, `optionalCompositionStep`).
struct CompositionStep {
  let ctx: OptimizerContext
  let isOptional: Bool
  let condition: Expr
  let expr: Expr

  var isConditional: Bool {
    if case .literal(.bool(true)) = condition.kind {
      return false
    }
    return true
  }

  func combine(_ step: CompositionStep?) -> CompositionStep {
    guard let step else {
      return self
    }
    let trueCondition = ctx.newLiteral(.bool(true))
    if !isOptional {
      if step.isOptional {
        if isConditional {
          return CompositionStep(
            ctx: ctx, isOptional: true, condition: trueCondition,
            expr: ctx.newCall(
              Operators.conditional, [condition, ctx.newCall("optional.of", [expr]), step.expr]))
        }
        return self
      }
      if !isConditional {
        return self
      }
      return CompositionStep(
        ctx: ctx, isOptional: false, condition: trueCondition,
        expr: ctx.newCall(Operators.conditional, [condition, expr, step.expr]))
    }
    if step.isOptional {
      if isConditional {
        return CompositionStep(
          ctx: ctx, isOptional: true, condition: trueCondition,
          expr: ctx.newCall(Operators.conditional, [condition, expr, step.expr]))
      }
      if !isOptionalNone(step.expr) {
        return CompositionStep(
          ctx: ctx, isOptional: true, condition: trueCondition,
          expr: ctx.newMemberCall("or", target: expr, [step.expr]))
      }
      return self
    }
    if isConditional {
      return CompositionStep(
        ctx: ctx, isOptional: true, condition: trueCondition,
        expr: ctx.newCall(Operators.conditional, [condition, expr, ctx.newCall("optional.of", [step.expr])]))
    }
    return CompositionStep(
      ctx: ctx, isOptional: false, condition: trueCondition,
      expr: ctx.newMemberCall("orValue", target: expr, [step.expr]))
  }
}

func isOptionalNone(_ e: Expr) -> Bool {
  guard let call = e.asCall else {
    return false
  }
  return call.function == "optional.none" && call.args.isEmpty && call.target == nil
}
