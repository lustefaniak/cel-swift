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
//
// The passes run through the core's static optimizer (`Environment.optimize(_:sourceOverride:pass:)`).
// cel-go's passes return the optimized AST; here they replace `OptimizerContext.ast.expr`, whose
// source info is the factory's.

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
    let rootSource = TextSource("true")
    let (ruleRoot, rootErrors) = env.compileSource(rootSource)
    // ruleRoot is a placeholder expression used as the root of the AST before optimization; the
    // composed expression reports positions in the policy source instead.
    let source: any Source = rule.source ?? rootSource
    guard let ruleRoot else {
      return (nil, rootErrors)
    }
    do {
      var composer = RuleComposerPass(rule: rule)
      let composed = try env.optimize(
        CheckedExpression(ast: ruleRoot, source: rootSource), sourceOverride: source
      ) { composer.optimize(&$0) }
      var unnester = RuleUnnesterPass(
        nextVarIndex: composer.varIndices.count, varIndices: composer.varIndices,
        exprUnnestHeight: exprUnnestHeight)
      let unnested = try env.optimize(composed) { unnester.optimize(&$0) }
      return (unnested.ast, CELErrors(source: source))
    } catch {
      return (nil, error.errors)
    }
  }
}

struct VarIndex {
  var index: Int
  var indexVar: String
  var localVar: String
  var expr: Expr
  var celType: CELType
}

/// cel-go `ruleComposerImpl`.
struct RuleComposerPass {
  let rule: CompiledRule
  var nextVarIndex = 0
  var varIndices: [VarIndex] = []
  var scopes: [[String: Int]] = []

  init(rule: CompiledRule) {
    self.rule = rule
  }

  func lookupLocal(_ name: String) -> Int? {
    for scope in scopes.reversed() {
      if let idx = scope[name] {
        return idx
      }
    }
    return nil
  }

  mutating func optimize(_ ctx: inout OptimizerContext) {
    // The input is a placeholder expression, completely replaced by the composed rule.
    let ruleExpr = optimizeRule(&ctx, rule, asList: false)
    if varIndices.isEmpty {
      ctx.ast.expr = ruleExpr
      return
    }
    var varExprs: [Expr] = []
    for vi in varIndices {
      varExprs.append(vi.expr)
      do {
        try ctx.extendEnvironment(variables: [VariableDecl(name: vi.indexVar, type: vi.celType)])
      } catch {
        ctx.reportError(at: ruleExpr.id, "\(error)")
      }
    }
    let list = ctx.newList(varExprs, [])
    ctx.ast.expr = ctx.newCall("cel.@block", [list, ruleExpr])
  }

  mutating func optimizeRule(_ ctx: inout OptimizerContext, _ r: CompiledRule, asList: Bool) -> Expr {
    scopes.append([:])
    defer { scopes.removeLast() }
    for v in r.variables {
      registerVariable(&ctx, v)
    }
    let isAggregate = r.semantic == .aggregate
    let returnList = isAggregate || asList
    var output = createBaseStep(&ctx, returnList: returnList, hasOptionalOutput: r.hasOptionalOutput)

    for m in r.matches.reversed() {
      let cond = m.condition.map { ctx.copyASTAndMetadata($0) } ?? ctx.newConstant(.bool(true))
      let currentStep: CompositionStep
      if let outputValue = m.output {
        var out = outputValue.expr.map { ctx.copyASTAndMetadata($0) } ?? ctx.newConstant(.null)
        if returnList {
          out = ctx.newList([out], [])
        }
        currentStep = CompositionStep(isOptional: false, condition: cond, expr: out)
      } else if let child = m.nestedRule {
        let nested = optimizeRule(&ctx, child, asList: returnList)
        currentStep = CompositionStep(isOptional: child.hasOptionalOutput, condition: cond, expr: nested)
      } else {
        ctx.reportError(at: cond.id, "unknown match kind: \(m.sourceID)")
        return cond
      }
      if isAggregate {
        output = combineAggregate(&ctx, currentStep, output)
      } else {
        output = currentStep.combine(&ctx, output)
      }
    }

    var matchExpr = output?.expr ?? ctx.newConstant(.null)
    rewriteVariableNames(&ctx, &matchExpr)
    return matchExpr
  }

  func createBaseStep(_ ctx: inout OptimizerContext, returnList: Bool, hasOptionalOutput: Bool) -> CompositionStep? {
    if returnList {
      return CompositionStep(isOptional: false, condition: ctx.newConstant(.bool(true)), expr: ctx.newList([], []))
    }
    if hasOptionalOutput {
      return CompositionStep(
        isOptional: true, condition: ctx.newConstant(.bool(true)), expr: ctx.newCall("optional.none", []))
    }
    return nil
  }

  func combineAggregate(_ ctx: inout OptimizerContext, _ step: CompositionStep, _ accumulated: CompositionStep?)
    -> CompositionStep
  {
    let trueCondition = ctx.newConstant(.bool(true))
    let currentListPart = step.expr
    let conditionalListPart: Expr
    if step.isConditional {
      let emptyList = ctx.newList([], [])
      conditionalListPart = ctx.newCall(Operators.conditional, [step.condition, currentListPart, emptyList])
    } else {
      conditionalListPart = currentListPart
    }
    guard let accumulated else {
      return CompositionStep(isOptional: false, condition: trueCondition, expr: conditionalListPart)
    }
    if case .list(let l) = accumulated.expr.kind, l.elements.isEmpty {
      return CompositionStep(isOptional: false, condition: trueCondition, expr: conditionalListPart)
    }
    let concatenated = ctx.newCall(Operators.add, [conditionalListPart, accumulated.expr])
    return CompositionStep(isOptional: false, condition: trueCondition, expr: concatenated)
  }

  func rewriteVariableNames(_ ctx: inout OptimizerContext, _ expr: inout Expr) {
    expr.transformPostOrder { e in
      guard let name = e.asIdent, name.utf8.starts(with: "variables.".utf8), let idx = lookupLocal(name) else {
        return
      }
      let ident = ctx.newIdent(varIndices[idx].indexVar)
      ctx.updateExpr(&e, ident)
    }
  }

  mutating func registerVariable(_ ctx: inout OptimizerContext, _ v: CompiledVariable) {
    let varName = "variables.\(v.name)"
    let indexVar = "@index\(nextVarIndex)"
    var varExpr = v.expr.map { ctx.copyASTAndMetadata($0) } ?? ctx.newConstant(.null)
    rewriteVariableNames(&ctx, &varExpr)
    varIndices.append(
      VarIndex(
        index: nextVarIndex, indexVar: indexVar, localVar: varName, expr: varExpr,
        celType: v.declaration.type))
    if !scopes.isEmpty {
      scopes[scopes.count - 1][varName] = varIndices.count - 1
    }
    nextVarIndex += 1
  }
}

/// cel-go `ruleUnnesterImpl`.
struct RuleUnnesterPass {
  var nextVarIndex: Int
  var varIndices: [VarIndex]
  let exprUnnestHeight: Int

  mutating func optimize(_ ctx: inout OptimizerContext) {
    let a = ctx.ast
    var ruleExpr = a.expr
    var varExprs: [Expr] = []
    var varDecls: [VariableDecl] = []
    let unnestOffset = nextVarIndex
    if let call = ruleExpr.asCall, call.function == "cel.@block", call.args.count == 2 {
      ruleExpr = call.args[1]
      let blockExprs = call.args[0].asList?.elements ?? []
      if blockExprs.count != varIndices.count {
        ctx.reportError(at: ruleExpr.id, "ast block list and computed one have different sizes")
        return
      }
      // cel-go reuses `vi.expr`, a pointer the previous pass renumbered in place; the Swift
      // values keep the old ids, so the slots come from the block in the checked AST instead.
      for (i, vi) in varIndices.enumerated() {
        varIndices[i].expr = blockExprs[i]
        varDecls.append(VariableDecl(name: vi.indexVar, type: vi.celType))
        varExprs.append(blockExprs[i])
      }
    }
    if !varDecls.isEmpty {
      do {
        try ctx.extendEnvironment(variables: varDecls)
      } catch {
        ctx.reportError(at: ruleExpr.id, "\(error)")
      }
    }

    // Types of the checked rule expression, for the unnested slot declarations.
    maybeUnnestRule(&ctx, &ruleExpr, typeOf: { a.type(of: $0) })
    if varIndices.isEmpty {
      return
    }
    for i in unnestOffset..<varIndices.count {
      let vi = varIndices[i]
      varExprs.append(vi.expr)
      do {
        try ctx.extendEnvironment(variables: [VariableDecl(name: vi.indexVar, type: vi.celType)])
      } catch {
        ctx.reportError(at: ruleExpr.id, "\(error)")
      }
    }
    let list = ctx.newList(varExprs, [])
    ctx.ast.expr = ctx.newCall("cel.@block", [list, ruleExpr])
  }

  mutating func maybeUnnestRule(_ ctx: inout OptimizerContext, _ ruleExpr: inout Expr, typeOf: (Int64) -> CELType) {
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
      registerUnnestVariable(&ctx, &ruleExpr, e.id, type: typeOf(e.id))
    }
  }

  mutating func registerUnnestVariable(
    _ ctx: inout OptimizerContext, _ ruleExpr: inout Expr, _ id: Int64, type: CELType
  ) {
    let indexVar = "@index\(nextVarIndex)"
    // The current state of the node, with already unnested descendants replaced.
    guard let current = ruleExpr.node(id) else {
      return
    }
    let copy = ctx.copyASTAndMetadata(AST(expr: current, sourceInfo: ctx.ast.sourceInfo))
    varIndices.append(
      VarIndex(index: nextVarIndex, indexVar: indexVar, localVar: "", expr: copy, celType: type))
    let ident = ctx.newIdent(indexVar)
    ruleExpr.updateNode(id) { ctx.updateExpr(&$0, ident) }
    nextVarIndex += 1
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
  let isOptional: Bool
  let condition: Expr
  let expr: Expr

  var isConditional: Bool {
    if case .literal(.bool(true)) = condition.kind {
      return false
    }
    return true
  }

  func combine(_ ctx: inout OptimizerContext, _ step: CompositionStep?) -> CompositionStep {
    guard let step else {
      return self
    }
    let trueCondition = ctx.newConstant(.bool(true))
    if !isOptional {
      if step.isOptional {
        if isConditional {
          return CompositionStep(
            isOptional: true, condition: trueCondition,
            expr: ctx.newCall(
              Operators.conditional, [condition, ctx.newCall("optional.of", [expr]), step.expr]))
        }
        return self
      }
      if !isConditional {
        return self
      }
      return CompositionStep(
        isOptional: false, condition: trueCondition,
        expr: ctx.newCall(Operators.conditional, [condition, expr, step.expr]))
    }
    if step.isOptional {
      if isConditional {
        return CompositionStep(
          isOptional: true, condition: trueCondition,
          expr: ctx.newCall(Operators.conditional, [condition, expr, step.expr]))
      }
      if !isOptionalNone(step.expr) {
        return CompositionStep(
          isOptional: true, condition: trueCondition,
          expr: ctx.newMemberCall("or", expr, [step.expr]))
      }
      return self
    }
    if isConditional {
      return CompositionStep(
        isOptional: true, condition: trueCondition,
        expr: ctx.newCall(Operators.conditional, [condition, expr, ctx.newCall("optional.of", [step.expr])]))
    }
    return CompositionStep(
      isOptional: false, condition: trueCondition,
      expr: ctx.newMemberCall("orValue", expr, [step.expr]))
  }
}

func isOptionalNone(_ e: Expr) -> Bool {
  guard let call = e.asCall else {
    return false
  }
  return call.function == "optional.none" && call.args.isEmpty && call.target == nil
}
