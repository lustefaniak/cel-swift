// Copyright 2023 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Ported from cel-go cel/folding.go (constantFoldingOptimizer).
//
// cel-go folds a sub-expression into a literal node holding any runtime value and converts those
// values back to CEL syntax (`adaptLiteral`) in a final pass. Here the folded node gets its
// literal syntax immediately and its value is recorded in `OptimizerContext.literalValues`, so
// the matchers treat it as a literal exactly as cel-go does; sub-expressions are evaluated with
// folded nodes replaced by their recorded values.

extension ExpressionOptimizer {
  /// Replaces calls, selections and comprehensions whose inputs are all literals with the
  /// literal they evaluate to (cel-go `NewConstantFoldingOptimizer`).
  ///
  /// `1 + 2 * 3` becomes `7`, `[1, 2].map(x, x * 2)` becomes `[2, 4]`, `true ? a : b` becomes
  /// `a`, and `x && false` becomes `false`. Functions declared with late binding are never
  /// evaluated. Only values with a literal form are folded; a fold that fails to evaluate leaves
  /// the expression as it is.
  ///
  /// - Parameters:
  ///   - maxIterations: How many times the expression is searched for foldable sub-expressions
  ///     (cel-go `MaxConstantFoldIterations`, default 100).
  ///   - knownValues: Values of variables to fold as literals too (cel-go `FoldKnownValues`);
  ///     with `nil`, variables are never folded, with empty variables named constants such as
  ///     enum values are.
  public static func constantFolding(maxIterations: Int = 100, knownValues: Variables? = nil) -> ExpressionOptimizer {
    let folder = ConstantFolder(maxIterations: maxIterations, knownValues: knownValues)
    return ExpressionOptimizer { folder.optimize(&$0) }
  }
}

/// The kind of a node as cel-go's matchers see it: folded nodes are literals.
private enum NodeKind {
  case literal, ident, select, call, list, map, `struct`, comprehension, unspecified
}

extension OptimizerContext {
  fileprivate func kind(_ e: Expr) -> NodeKind {
    if literalValues[e.id] != nil {
      return .literal
    }
    switch e.kind {
    case .literal: return .literal
    case .ident: return .ident
    case .select: return .select
    case .call: return .call
    case .list: return .list
    case .map: return .map
    case .struct: return .struct
    case .comprehension: return .comprehension
    case .unspecified: return .unspecified
    }
  }

  /// cel-go `ast.MatchDescendants` over the current expression, not descending into folded
  /// literals (which have no children in cel-go).
  fileprivate func match(_ root: NavigableExpr, _ matcher: (NavigableExpr) -> Bool) -> [NavigableExpr] {
    var matches: [NavigableExpr] = []
    func visit(_ nav: NavigableExpr) {
      if literalValues[nav.id] == nil {
        for child in nav.children {
          visit(child)
        }
      }
      if matcher(nav) {
        matches.append(nav)
      }
    }
    visit(root)
    return matches
  }

  /// Visits nodes in pre-order without descending into folded literals.
  fileprivate func preOrderVisit(_ e: Expr, _ visitor: (Expr) -> Void) {
    visitor(e)
    if literalValues[e.id] != nil {
      return
    }
    for child in e.children {
      preOrderVisit(child, visitor)
    }
  }
}

struct ConstantFolder: Sendable {
  let maxIterations: Int
  let knownValues: Variables?

  /// cel-go `constantFoldingOptimizer.Optimize`.
  func optimize(_ ctx: inout OptimizerContext) {
    // Walk the foldable expressions and continue to fold until there are none left.
    var foldable = ctx.match(NavigableExpr(root: ctx.ast.expr)) { constantExprMatcher(ctx, $0) }
    var foldCount = 0
    while !foldable.isEmpty && foldCount < maxIterations {
      for fold in foldable {
        guard let current = ctx.node(fold.id) else {
          continue
        }
        if case .call(let call) = current.kind, ctx.kind(current) == .call {
          // If the call is non-strict and its branches are pruned, continue with the next fold.
          if maybePruneBranches(&ctx, current, call) {
            continue
          }
          // Late-bound function calls cannot be folded.
          if isLateBoundFunctionCall(ctx, call) {
            continue
          }
        }
        if case .failed(let message)? = tryFold(&ctx, current) {
          ctx.reportError(at: ctx.ast.expr.id, "constant-folding evaluation failed: \(message)")
          return
        }
      }
      foldCount += 1
      foldable = ctx.match(NavigableExpr(root: ctx.ast.expr)) { constantExprMatcher(ctx, $0) }
    }
    // Once all of the constants have been folded, try the remaining comprehensions one last
    // time; they are only replaced when their evaluation succeeds.
    for compre in ctx.match(NavigableExpr(root: ctx.ast.expr), { ctx.kind($0.expr) == .comprehension }) {
      guard let current = ctx.node(compre.id) else {
        continue
      }
      if case .failed(let message)? = tryFold(&ctx, current) {
        ctx.reportError(at: ctx.ast.expr.id, "constant-folding evaluation failed: \(message)")
        return
      }
    }
    // Resolve optional entries of aggregate literals so resolved optionals do not surface in the
    // output literal.
    pruneOptionalElements(&ctx)
  }

  enum FoldFailure {
    /// The sub-expression has no value without more input, or fails to evaluate; it is left as
    /// it is.
    case cannotFold
    /// The value has no literal form.
    case failed(String)
  }

  /// Evaluates a sub-expression and replaces it with the literal result (cel-go `tryFold`).
  ///
  /// - Returns: Why the expression was not folded, or `nil` when it was.
  @discardableResult
  private func tryFold(_ ctx: inout OptimizerContext, _ expr: Expr) -> FoldFailure? {
    guard let value = evaluate(ctx, expr) else {
      return .cannotFold
    }
    do {
      let literal = try ctx.newLiteral(value)
      ctx.updateExpr(expr.id, literal)
      return nil
    } catch {
      return .failed(error.description)
    }
  }

  /// Evaluates a sub-expression of the AST with the known values (cel-go `evaluateExpr`).
  ///
  /// Folded nodes are planned as placeholders and replaced by their values, so the evaluation
  /// sees exactly the values the folds produced.
  private func evaluate(_ ctx: OptimizerContext, _ expr: Expr) -> Value? {
    let values = ctx.literalValues
    var sub = expr
    sub.transformPostOrder { e in
      if values[e.id] != nil {
        e.kind = .literal(.null)
      }
    }
    var subAST = AST(expr: sub, sourceInfo: ctx.ast.sourceInfo)
    subAST.typeMap = ctx.ast.typeMap
    subAST.referenceMap = ctx.ast.referenceMap
    let substitute: ProgramDecorator = { interpretable in
      if interpretable is EvalConst, let value = values[interpretable.id] {
        return EvalConst(id: interpretable.id, value: value)
      }
      return interpretable
    }
    let options: [Program.Option] = [Program.Option { $0.decorators.append(substitute) }, .errorsAsValues]
    guard let program = try? ctx.env.makeProgram(subAST, source: ctx.source, options: options) else {
      return nil
    }
    let activation = knownValues?.makeActivation() ?? EmptyActivation()
    let value = program.run(activation).value
    switch value {
    case .error, .unknown:
      return nil
    default:
      return value
    }
  }

  private func isLateBoundFunctionCall(_ ctx: OptimizerContext, _ call: Expr.Call) -> Bool {
    ctx.env.configuration.functions.first { $0.name == call.function }?.hasLateBinding ?? false
  }

  // MARK: Branch pruning

  /// Removes branches of non-strict calls that literals decide (cel-go `maybePruneBranches`).
  private func maybePruneBranches(_ ctx: inout OptimizerContext, _ expr: Expr, _ call: Expr.Call) -> Bool {
    let args = call.args
    switch call.function {
    case Operators.logicalAnd, Operators.logicalOr:
      return maybeShortcircuitLogic(&ctx, call.function, args, expr)
    case Operators.conditional:
      let cond = args[0]
      if ctx.kind(cond) != .literal {
        return false
      }
      ctx.updateExpr(expr.id, ctx.literalValue(cond) == .bool(true) ? args[1] : args[2])
      return true
    case Operators.in:
      let needle = args[0]
      let haystack = args[1]
      if ctx.kind(haystack) == .list, let list = haystack.asList, list.elements.isEmpty {
        ctx.updateExpr(expr.id, ctx.newConstant(.bool(false)))
        return true
      }
      if (ctx.kind(needle) == .literal || isSelfEqualIdent(ctx, needle)) && ctx.kind(haystack) == .list,
        let list = haystack.asList, listContains(ctx, list, needle)
      {
        ctx.updateExpr(expr.id, ctx.newConstant(.bool(true)))
        return true
      }
    case Operators.add:
      if args.count == 2, ctx.kind(args[0]) == .list, ctx.kind(args[1]) == .list,
        let left = args[0].asList, let right = args[1].asList
      {
        let elements = left.elements + right.elements
        let offset = Int32(left.elements.count)
        let optionalIndices = left.optionalIndices + right.optionalIndices.map { $0 + offset }
        ctx.updateExpr(expr.id, ctx.newList(elements, optionalIndices))
        return true
      }
    default:
      break
    }
    return false
  }

  /// Whether a literal or self-equal identifier needle is an element of a list literal.
  private func listContains(_ ctx: OptimizerContext, _ list: Expr.List, _ needle: Expr) -> Bool {
    let needleValue = ctx.kind(needle) == .literal ? ctx.literalValue(needle) : nil
    for element in list.elements {
      if let needleValue, ctx.kind(element) == .literal, let elementValue = ctx.literalValue(element),
        elementValue.celEquals(needleValue) == .bool(true)
      {
        return true
      }
      if needleValue == nil, ctx.kind(element) == .ident, let name = element.asIdent, name == needle.asIdent {
        return true
      }
    }
    return false
  }

  /// cel-go `maybeShortcircuitLogic`.
  private func maybeShortcircuitLogic(
    _ ctx: inout OptimizerContext, _ function: String, _ args: [Expr], _ expr: Expr
  ) -> Bool {
    let shortcircuit = Value.bool(function == Operators.logicalOr)
    let skip = Value.bool(function != Operators.logicalOr)
    var newArgs: [Expr] = []
    for arg in args {
      if ctx.kind(arg) != .literal {
        newArgs.append(arg)
        continue
      }
      let value = ctx.literalValue(arg)
      if value == skip {
        continue
      }
      if value == shortcircuit {
        ctx.updateExpr(expr.id, arg)
        return true
      }
    }
    if newArgs.isEmpty {
      newArgs.append(args[0])
    }
    if newArgs.count == args.count {
      return false
    }
    if newArgs.count == 1 {
      if !isBoolType(ctx, newArgs[0]) {
        return false
      }
      ctx.updateExpr(expr.id, newArgs[0])
      return true
    }
    ctx.updateExpr(expr.id, ctx.newCall(function, newArgs))
    return true
  }

  private func isBoolType(_ ctx: OptimizerContext, _ e: Expr) -> Bool {
    if ctx.type(of: e.id) == .bool {
      return true
    }
    if ctx.kind(e) == .literal, case .bool? = ctx.literalValue(e) {
      return true
    }
    return false
  }

  // MARK: Optional pruning

  /// Resolves optional elements of aggregate literals bottom-up (cel-go `pruneOptionalElements`).
  private func pruneOptionalElements(_ ctx: inout OptimizerContext) {
    let aggregates = ctx.match(NavigableExpr(root: ctx.ast.expr)) { nav in
      let kind = ctx.kind(nav.expr)
      return kind == .list || kind == .map || kind == .struct
    }
    for aggregate in aggregates {
      guard let current = ctx.node(aggregate.id) else {
        continue
      }
      switch current.kind {
      case .list(let list): pruneOptionalListElements(&ctx, current.id, list)
      case .map(let map): pruneOptionalMapEntries(&ctx, current.id, map)
      case .struct(let s): pruneOptionalStructFields(&ctx, current.id, s)
      default: break
      }
    }
  }

  private func pruneOptionalListElements(_ ctx: inout OptimizerContext, _ id: Int64, _ list: Expr.List) {
    if list.optionalIndices.isEmpty {
      return
    }
    var updatedElements: [Expr] = []
    var updatedIndices: [Int32] = []
    var newOptIndex: Int32 = -1
    for (i, element) in list.elements.enumerated() {
      newOptIndex += 1
      if !list.isOptional(Int32(i)) {
        updatedElements.append(element)
        continue
      }
      guard ctx.kind(element) == .literal, case .optional(let inner)? = ctx.literalValue(element) else {
        updatedElements.append(element)
        updatedIndices.append(newOptIndex)
        continue
      }
      guard let inner else {
        // Skipping causes the list to get smaller.
        newOptIndex -= 1
        continue
      }
      updatedElements.append(replaceWithLiteral(&ctx, element, inner))
    }
    ctx.updateExpr(id, ctx.newList(updatedElements, updatedIndices))
  }

  private func pruneOptionalMapEntries(_ ctx: inout OptimizerContext, _ id: Int64, _ map: Expr.Map) {
    var updatedEntries: [Expr.MapEntry] = []
    var modified = false
    for entry in map.entries {
      // If the entry is not optional, or its value is not a resolved literal, keep it as-is.
      guard entry.isOptional, ctx.kind(entry.value) == .literal,
        case .optional(let inner)? = ctx.literalValue(entry.value)
      else {
        updatedEntries.append(entry)
        continue
      }
      // When the key is not a literal but the value is, restore the value to an optional.
      if ctx.kind(entry.key) != .literal {
        do {
          let undo = try ctx.adaptLiteral(.optional(inner))
          ctx.updateExpr(entry.value.id, undo)
        } catch {
          ctx.reportError(at: entry.value.id, "invalid map value literal \(Value.optional(inner)): \(error)")
        }
        var restored = entry
        restored.value = ctx.node(entry.value.id) ?? entry.value
        updatedEntries.append(restored)
        continue
      }
      modified = true
      guard let inner else {
        continue
      }
      let value = replaceWithLiteral(&ctx, entry.value, inner)
      updatedEntries.append(ctx.newMapEntry(entry.key, value, isOptional: false))
    }
    if modified {
      ctx.updateExpr(id, ctx.newMap(updatedEntries))
    }
  }

  private func pruneOptionalStructFields(_ ctx: inout OptimizerContext, _ id: Int64, _ s: Expr.Struct) {
    var updatedFields: [Expr.StructField] = []
    var modified = false
    for field in s.fields {
      guard field.isOptional, ctx.kind(field.value) == .literal,
        case .optional(let inner)? = ctx.literalValue(field.value)
      else {
        updatedFields.append(field)
        continue
      }
      modified = true
      guard let inner else {
        continue
      }
      let value = replaceWithLiteral(&ctx, field.value, inner)
      updatedFields.append(ctx.newStructField(field.name, value, isOptional: false))
    }
    if modified {
      ctx.updateExpr(id, ctx.newStruct(s.typeName, updatedFields))
    }
  }

  /// Turns `element` into the literal for `value` and returns the updated node.
  private func replaceWithLiteral(_ ctx: inout OptimizerContext, _ element: Expr, _ value: Value) -> Expr {
    do {
      let literal = try ctx.newLiteral(value)
      ctx.updateExpr(element.id, literal)
      return ctx.node(element.id) ?? Expr(id: element.id, kind: literal.kind)
    } catch {
      ctx.reportError(at: element.id, "constant-folding evaluation failed: \(error)")
      return element
    }
  }

  // MARK: Matchers

  /// Matches calls, selections and comprehensions whose arguments are all literals (cel-go
  /// `constantExprMatcher`).
  ///
  /// Only comprehensions which are not nested are candidates, and only if every variable they
  /// reference is one of their own iteration or accumulation variables.
  private func constantExprMatcher(_ ctx: OptimizerContext, _ e: NavigableExpr) -> Bool {
    switch ctx.kind(e.expr) {
    case .call:
      return constantCallMatcher(ctx, e)
    case .select:
      return e.children.first.map { constantMatcher(ctx, $0) } ?? false
    case .ident:
      return knownValues != nil && ctx.ast.referenceMap[e.id] != nil && !hasComprehensionVar(ctx, e)
    case .comprehension:
      if isNestedComprehension(e) {
        return false
      }
      var vars = Set<String>()
      var constantExprs = true
      ctx.preOrderVisit(e.expr) { node in
        if ctx.kind(node) == .comprehension, let nested = node.asComprehension {
          vars.insert(nested.accuVar)
          vars.insert(nested.iterVar)
          if !nested.iterVar2.isEmpty {
            vars.insert(nested.iterVar2)
          }
        }
        if ctx.kind(node) == .ident, let name = node.asIdent, !vars.contains(name) {
          constantExprs = false
        }
        // Late-bound function calls cannot be folded.
        if ctx.kind(node) == .call, let call = node.asCall, isLateBoundFunctionCall(ctx, call) {
          constantExprs = false
        }
      }
      return constantExprs
    default:
      return false
    }
  }

  /// Literals, and list, map and message literals made only of literals (cel-go
  /// `ConstantValueMatcher`).
  private func constantMatcher(_ ctx: OptimizerContext, _ e: NavigableExpr) -> Bool {
    switch ctx.kind(e.expr) {
    case .literal:
      return true
    case .list, .map, .struct:
      return e.children.allSatisfy { constantMatcher(ctx, $0) }
    default:
      return false
    }
  }

  /// Identifies strict and non-strict calls which can be folded (cel-go `constantCallMatcher`).
  private func constantCallMatcher(_ ctx: OptimizerContext, _ e: NavigableExpr) -> Bool {
    guard let call = e.expr.asCall else {
      return false
    }
    let children = e.children
    let function = call.function
    if function == Operators.logicalAnd || function == Operators.logicalOr {
      if children.contains(where: { ctx.kind($0.expr) == .literal }) {
        return true
      }
    }
    if function == Operators.conditional {
      let cond = children[0].expr
      if ctx.kind(cond) == .literal, case .bool? = ctx.literalValue(cond) {
        return true
      }
    }
    if function == Operators.equals || function == Operators.notEquals {
      if hasComprehensionVar(ctx, e) {
        return false
      }
      if isLiteralBool(ctx, children[0].expr) || isLiteralBool(ctx, children[1].expr) {
        return true
      }
    }
    if function == Operators.in {
      if hasComprehensionVar(ctx, e) {
        return false
      }
      let haystack = children[1].expr
      if ctx.kind(haystack) == .list, let list = haystack.asList {
        if list.elements.isEmpty {
          return true
        }
        let needle = children[0].expr
        if ctx.kind(needle) == .literal || isSelfEqualIdent(ctx, needle), listContains(ctx, list, needle) {
          return true
        }
      }
    }
    if function == Operators.add {
      if children.count == 2, ctx.kind(children[0].expr) == .list, ctx.kind(children[1].expr) == .list {
        return true
      }
    }
    // Fold all other calls with constant arguments.
    return children.allSatisfy { constantMatcher(ctx, $0) }
  }

  private func isLiteralBool(_ ctx: OptimizerContext, _ e: Expr) -> Bool {
    if ctx.kind(e) == .literal, case .bool? = ctx.literalValue(e) {
      return true
    }
    return false
  }

  /// Whether the expression is an identifier whose static type guarantees its value equals
  /// itself (cel-go `isSelfEqualIdent`): a double may be NaN, and dyn, abstract and message
  /// types may hold one.
  private func isSelfEqualIdent(_ ctx: OptimizerContext, _ e: Expr) -> Bool {
    guard ctx.kind(e) == .ident else {
      return false
    }
    return isSelfEqualType(ctx.type(of: e.id))
  }

  private func isSelfEqualType(_ type: CELType?) -> Bool {
    guard let type else {
      return false
    }
    switch type.kind {
    case .bool, .bytes, .duration, .int, .nullType, .string, .timestamp, .type, .uint:
      return true
    case .list, .map:
      // Aggregates compare element-wise, so they are self-equal exactly when their type
      // parameters are.
      return type.parameters.allSatisfy(isSelfEqualType)
    default:
      return false
    }
  }

  /// Whether an identifier below `e` refers to a comprehension variable of an enclosing
  /// comprehension (cel-go `hasComprehensionVar`).
  private func hasComprehensionVar(_ ctx: OptimizerContext, _ e: NavigableExpr) -> Bool {
    for ident in ctx.match(e, { ctx.kind($0.expr) == .ident }) {
      guard let name = ident.expr.asIdent else {
        continue
      }
      var current = ident
      var parent = ident.parent
      while let p = parent {
        if let compre = p.expr.asComprehension,
          compre.accuVar == name || compre.iterVar == name || compre.iterVar2 == name,
          current.id != compre.iterRange.id, current.id != compre.accuInit.id
        {
          return true
        }
        current = p
        parent = p.parent
      }
    }
    return false
  }

  private func isNestedComprehension(_ e: NavigableExpr) -> Bool {
    var parent = e.parent
    while let p = parent {
      if case .comprehension = p.expr.kind {
        return true
      }
      parent = p.parent
    }
    return false
  }
}
