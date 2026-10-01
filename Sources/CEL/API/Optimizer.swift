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
// Ported from cel-go cel/optimizer.go (StaticOptimizer, OptimizerContext, optimizerExprFactory,
// normalizeIDs, cleanupMacroRefs, idGenerator).
//
// cel-go mutates expression nodes in place through shared pointers (`SetKindCase`). Expressions
// here are values, so the context owns the AST being optimized and every update addresses a node
// by id: `updateExpr(_:_:)` gives the node with that id the kind of the replacement and keeps
// its id, which is what `SetKindCase` does. Constant folding additionally records the runtime
// value of every node it turns into a literal (see `literalValues`), because cel-go literals can
// hold any value while `Constant` holds only the scalar ones.

/// A rewrite applied to a checked expression by ``Environment/optimize(_:_:)``, such as constant
/// folding or variable inlining (cel-go `ASTOptimizer`).
public struct ExpressionOptimizer: Sendable {
  let run: @Sendable (inout OptimizerContext) -> Void
}

extension Environment {
  /// Applies optimizers to a checked expression in order (cel-go `StaticOptimizer.Optimize`).
  ///
  /// After each optimizer the expression ids are renumbered and the expression is type-checked
  /// again, so the result has the metadata a freshly compiled expression would have. Source
  /// positions are kept where nodes survive and are missing for nodes the optimizers create.
  ///
  /// ```swift
  /// let checked = try env.compile("x + (2 * 3) > 10 ? 'big' : 'small'")
  /// let folded = try env.optimize(checked, .constantFolding())
  /// folded.description   // (x + 6 > 10) ? "big" : "small"
  /// ```
  ///
  /// - Parameters:
  ///   - expression: An expression checked by this environment.
  ///   - optimizers: The optimizations to apply, in order.
  /// - Returns: The optimized, checked expression.
  /// - Throws: ``CompileError`` when an optimizer reports an issue or the optimized expression
  ///   no longer type-checks.
  public func optimize(
    _ expression: CheckedExpression, _ optimizers: ExpressionOptimizer...
  ) throws(CompileError) -> CheckedExpression {
    try optimize(expression, optimizers: optimizers)
  }

  /// Applies optimizers to a checked expression in order (cel-go `StaticOptimizer.Optimize`).
  ///
  /// - Parameters:
  ///   - expression: An expression checked by this environment.
  ///   - optimizers: The optimizations to apply, in order.
  /// - Returns: The optimized, checked expression.
  /// - Throws: ``CompileError`` when an optimizer reports an issue or the optimized expression
  ///   no longer type-checks.
  public func optimize(
    _ expression: CheckedExpression, optimizers: [ExpressionOptimizer]
  ) throws(CompileError) -> CheckedExpression {
    var context = OptimizerContext(env: self, ast: expression.ast, source: expression.source)
    for optimizer in optimizers {
      try context.apply(optimizer.run)
    }
    return CheckedExpression(ast: context.ast, source: context.source)
  }

  /// Applies one optimization pass that is not an ``ExpressionOptimizer``, such as the policy
  /// composer, whose passes keep state between them (cel-go `NewStaticOptimizer` with one
  /// `ASTOptimizer`).
  ///
  /// - Parameters:
  ///   - expression: An expression checked by this environment.
  ///   - sourceOverride: Replaces the expression's source and discards its source info (cel-go
  ///     `OptimizeWithSource`).
  ///   - pass: The optimization; it rewrites `OptimizerContext.ast`.
  package func optimize(
    _ expression: CheckedExpression, sourceOverride: (any Source)? = nil,
    pass: (inout OptimizerContext) -> Void
  ) throws(CompileError) -> CheckedExpression {
    var context = OptimizerContext(
      env: self, ast: expression.ast, source: expression.source, sourceOverride: sourceOverride)
    try context.apply(pass)
    return CheckedExpression(ast: context.ast, source: context.source)
  }
}

extension OptimizerContext {
  /// Runs one pass, then renumbers ids and type-checks the result with the context's environment
  /// (one iteration of cel-go `StaticOptimizer.Optimize`).
  mutating func apply(_ pass: (inout OptimizerContext) -> Void) throws(CompileError) {
    pass(&self)
    if !errors.errors.isEmpty {
      throw CompileError(errors)
    }
    // Normalize expression id metadata including coordination with macro call metadata.
    var fresh = StableIDGenerator(seed: 0)
    var expr = ast.expr
    var info = ast.sourceInfo
    normalizeIDs(&fresh, &expr, &info)
    cleanupMacroRefs(expr, &info)
    // Recheck the updated expression for any possible type-agreement or validation errors.
    let checked = try env.check(ParsedExpression(ast: AST(expr: expr, sourceInfo: info), source: source))
    ast = checked.ast
    literalValues = [:]
  }
}

/// Renumbers ids from a seed, giving each old id the same new id every time (cel-go
/// `idGenerator`).
struct StableIDGenerator {
  var seed: Int64
  var idMap: [Int64: Int64] = [:]

  mutating func nextID() -> Int64 {
    seed += 1
    return seed
  }

  mutating func renumberStable(_ id: Int64) -> Int64 {
    if id == 0 {
      return 0
    }
    if let newID = idMap[id] {
      return newID
    }
    let newID = nextID()
    idMap[id] = newID
    return newID
  }
}

/// Renumbers the expression, its offset ranges and its macro calls consistently (cel-go
/// `normalizeIDs`).
func normalizeIDs(_ ids: inout StableIDGenerator, _ expr: inout Expr, _ info: inout SourceInfo) {
  expr.renumberIDs { ids.renumberStable($0) }
  info.renumberIDs { ids.renumberStable($0) }
  if info.macroCalls.isEmpty {
    return
  }
  // Sort the macro ids so renumbering macro-specific variables is stable across normalizations.
  let sortedMacroIDs = info.macroCalls.keys.sorted()
  var callIDMap: [Int64: Int64] = [:]
  for id in sortedMacroIDs {
    callIDMap[id] = ids.renumberStable(id)
  }
  var updates: [(id: Int64, call: Expr)] = []
  for oldID in sortedMacroIDs {
    guard let newID = callIDMap[oldID], var call = info.macroCall(oldID) else {
      continue
    }
    call.renumberIDs { ids.renumberStable($0) }
    updates.append((newID, call))
    info.clearMacroCall(oldID)
  }
  for update in updates {
    info.setMacroCall(update.id, update.call)
  }
}

/// Removes macro calls whose id no longer occurs in the expression or another macro call
/// (cel-go `cleanupMacroRefs`).
func cleanupMacroRefs(_ expr: Expr, _ info: inout SourceInfo) {
  if info.macroCalls.isEmpty {
    return
  }
  var referenced = Set<Int64>()
  let collect: (Expr) -> Void = { e in
    if e.id != 0 {
      referenced.insert(e.id)
    }
  }
  expr.postOrderVisit(expr: collect)
  for call in info.macroCalls.values {
    call.postOrderVisit(expr: collect)
  }
  for id in info.macroCalls.keys where !referenced.contains(id) {
    info.clearMacroCall(id)
  }
}

/// The state shared by the optimizers: the environment, the AST being optimized, an id
/// generator for new nodes and the issues reported so far (cel-go `OptimizerContext` and
/// `optimizerExprFactory`).
package struct OptimizerContext {
  /// The environment the passes check against; ``extendEnvironment(variables:)`` adds to it.
  package private(set) var env: Environment
  /// The AST being optimized; its source info holds the macro calls the factory methods update.
  package var ast: AST
  let source: any Source
  var ids: StableIDGenerator
  var errors: CELErrors
  /// The runtime values of nodes constant folding turned into literals, by node id. A node with
  /// an entry is a literal for every matcher, whatever its syntax (`[1, 2]`, `duration("1s")`,
  /// `optional.of(1)`), and its sub-nodes are not visited.
  var literalValues: [Int64: Value] = [:]

  init(env: Environment, ast: AST, source: any Source, sourceOverride: (any Source)? = nil) {
    self.env = env
    // Ids continue after the input expression's, even when its source info is discarded.
    self.ids = StableIDGenerator(seed: ast.maxID)
    var ast = ast
    if let sourceOverride {
      ast.sourceInfo = SourceInfo(source: sourceOverride)
    }
    self.ast = ast
    self.source = sourceOverride ?? source
    self.errors = CELErrors(source: sourceOverride ?? source)
  }

  package mutating func nextID() -> Int64 {
    ids.nextID()
  }

  /// Reports an issue for the node `id` (cel-go `Issues.ReportErrorAtID`). cel-go's optimizer
  /// issues have no source info, so the issue has no location.
  package mutating func reportError(at id: Int64, _ message: String) {
    errors.reportError(exprID: id, at: .none, message)
  }

  /// Declares variables in the environment later passes and the type-check after this pass use
  /// (cel-go `OptimizerContext.ExtendEnv`).
  package mutating func extendEnvironment(variables: [VariableDecl]) throws(DeclarationError) {
    env = try env.extending(.variables(variables))
  }

  /// The current version of the node `id`, if it is still part of the expression.
  func node(_ id: Int64) -> Expr? {
    ast.expr.node(id)
  }

  /// The type the last type-check deduced for the node `id`.
  func type(of id: Int64) -> CELType? {
    ast.typeMap[id]
  }

  // MARK: Literals

  /// Whether the node is a literal: a constant or a value constant folding produced.
  func isLiteral(_ e: Expr) -> Bool {
    if literalValues[e.id] != nil {
      return true
    }
    if case .literal = e.kind {
      return true
    }
    return false
  }

  /// The value of a literal node.
  func literalValue(_ e: Expr) -> Value? {
    if let value = literalValues[e.id] {
      return value
    }
    if case .literal(let c) = e.kind {
      return c.value
    }
    return nil
  }

  // MARK: Factory (cel-go optimizerExprFactory)

  package mutating func newCall(_ function: String, _ args: [Expr]) -> Expr {
    .call(id: nextID(), function: function, args: args)
  }

  package mutating func newMemberCall(_ function: String, _ target: Expr, _ args: [Expr]) -> Expr {
    .memberCall(id: nextID(), function: function, target: target, args: args)
  }

  package mutating func newIdent(_ name: String) -> Expr {
    .ident(id: nextID(), name)
  }

  package mutating func newConstant(_ value: Constant) -> Expr {
    .literal(id: nextID(), value)
  }

  package mutating func newList(_ elements: [Expr], _ optionalIndices: [Int32]) -> Expr {
    .list(id: nextID(), elements: elements, optionalIndices: optionalIndices)
  }

  mutating func newMap(_ entries: [Expr.MapEntry]) -> Expr {
    .map(id: nextID(), entries: entries)
  }

  mutating func newMapEntry(_ key: Expr, _ value: Expr, isOptional: Bool) -> Expr.MapEntry {
    Expr.MapEntry(id: nextID(), key: key, value: value, isOptional: isOptional)
  }

  mutating func newSelect(_ operand: Expr, _ field: String) -> Expr {
    .select(id: nextID(), operand: operand, field: field)
  }

  mutating func newStruct(_ typeName: String, _ fields: [Expr.StructField]) -> Expr {
    .struct(id: nextID(), typeName: typeName, fields: fields)
  }

  mutating func newStructField(_ name: String, _ value: Expr, isOptional: Bool) -> Expr.StructField {
    Expr.StructField(id: nextID(), name: name, value: value, isOptional: isOptional)
  }

  /// A literal node for `value`, in its literal syntax, remembered as a folded value (cel-go
  /// `NewLiteral` followed by the `adaptLiteral` pass).
  mutating func newLiteral(_ value: Value) throws(OptimizerError) -> Expr {
    let expr = try adaptLiteral(value)
    literalValues[expr.id] = value
    return expr
  }

  /// The expression that evaluates to `value`: a constant, or a call, list, map or message
  /// literal for values without a constant form (cel-go `adaptLiteral`).
  mutating func adaptLiteral(_ value: Value) throws(OptimizerError) -> Expr {
    switch value {
    case .null: return newConstant(.null)
    case .bool(let b): return newConstant(.bool(b))
    case .int(let i): return newConstant(.int(i))
    case .uint(let u): return newConstant(.uint(u))
    case .double(let d): return newConstant(.double(d))
    case .string(let s): return newConstant(.string(s))
    case .bytes(let b): return newConstant(.bytes(b))
    case .duration(let d):
      let text = newConstant(.string(d.celString))
      return newCall("duration", [text])
    case .timestamp(let t):
      let text = newConstant(.string(t.celString))
      return newCall("timestamp", [text])
    case .optional(let inner):
      guard let inner else {
        return newCall("optional.none", [])
      }
      let target = try adaptLiteral(inner)
      return newCall("optional.of", [target])
    case .type(let type):
      return newIdent(type.runtimeTypeName)
    case .list(let list):
      var elements: [Expr] = []
      for element in list.elements {
        elements.append(try adaptLiteral(element))
      }
      return newList(elements, [])
    case .map(let map):
      var entries: [Expr.MapEntry] = []
      for key in map.keys {
        let keyExpr = try adaptLiteral(key.value)
        let valueExpr = try adaptLiteral(map.value(forKey: key) ?? .null)
        entries.append(newMapEntry(keyExpr, valueExpr, isOptional: false))
      }
      return newMap(entries)
    case .object(let object):
      let typeName = object.celType.runtimeTypeName
      guard case .object = object.celType, let fields = env.typeProvider.findStructFieldNames(typeName) else {
        throw OptimizerError("failed to adapt \(value) to literal")
      }
      var inits: [Expr.StructField] = []
      for field in fields where object.isFieldSet(field) == .bool(true) {
        let fieldExpr = try adaptLiteral(object.field(field))
        inits.append(newStructField(field, fieldExpr, isOptional: false))
      }
      return newStruct(typeName, inits)
    case .error, .unknown:
      throw OptimizerError("failed to adapt \(value) to literal")
    }
  }

  // MARK: Macros

  mutating func setMacroCall(_ id: Int64, _ call: Expr) {
    ast.sourceInfo.setMacroCall(id, call)
  }

  mutating func clearMacroCall(_ id: Int64) {
    ast.sourceInfo.clearMacroCall(id)
  }

  /// A renumbered copy of an AST's expression and source info, with ids that cannot collide with
  /// the expression being optimized (cel-go `CopyAST`).
  mutating func copyAST(_ other: AST) -> (Expr, SourceInfo) {
    var copyIDs = StableIDGenerator(seed: nextID())
    var expr = other.expr
    var info = other.sourceInfo
    normalizeIDs(&copyIDs, &expr, &info)
    ids.seed = copyIDs.nextID()
    return (expr, info)
  }

  /// Copies an AST and moves its macro calls and offset ranges into the AST being optimized
  /// (cel-go `CopyASTAndMetadata`).
  package mutating func copyASTAndMetadata(_ other: AST) -> Expr {
    let (expr, info) = copyAST(other)
    for (id, call) in info.macroCalls {
      setMacroCall(id, call)
    }
    for (id, range) in info.offsetRanges {
      ast.sourceInfo.setOffsetRange(id, range)
    }
    return expr
  }

  /// The expanded `cel.bind()` comprehension rooted at `macroID` and the call it expands, for the
  /// macro metadata (cel-go `NewBindMacro`).
  mutating func newBindMacro(
    _ macroID: Int64, _ varName: String, _ varInit: Expr, _ remaining: Expr
  ) -> (expr: Expr, macro: Expr) {
    let varID = nextID()
    let remainingID = nextID()
    var remaining = remaining
    remaining.renumberIDs { $0 == macroID ? remainingID : $0 }
    if let call = ast.sourceInfo.macroCall(macroID) {
      setMacroCall(remainingID, call)
    }
    let iterRange = newList([], [])
    let loopCondition = newConstant(.bool(false))
    let expr = Expr.comprehension(
      id: macroID, iterRange: iterRange, iterVar: "#unused", accuVar: varName, accuInit: varInit,
      loopCondition: loopCondition, loopStep: .ident(id: varID, varName), result: remaining)
    let cel = newIdent("cel")
    var macro = Expr.memberCall(
      id: 0, function: "bind", target: cel, args: [.ident(id: varID, varName), varInit, remaining])
    sanitizeMacro(macroID, &macro)
    return (expr, macro)
  }

  /// A presence test rooted at `macroID` for the select expression `s`, and the `has()` call it
  /// expands, for the macro metadata (cel-go `NewHasMacro`).
  mutating func newHasMacro(_ macroID: Int64, _ s: Expr.Select) -> (expr: Expr, macro: Expr) {
    let expr = Expr.presenceTest(id: macroID, operand: s.operand, field: s.field)
    let select = newSelect(s.operand, s.field)
    var macro = Expr.call(id: 0, function: "has", args: [select])
    sanitizeMacro(macroID, &macro)
    return (expr, macro)
  }

  /// Punches holes in a macro call where it refers to other macros (cel-go `sanitizeMacro`).
  private func sanitizeMacro(_ macroID: Int64, _ macro: inout Expr) {
    let info = ast.sourceInfo
    macro.transformPostOrder { e in
      if info.macroCall(e.id) != nil && e.id != macroID {
        e.kind = .unspecified
      }
    }
  }

  // MARK: Updates

  /// Replaces the node `targetID` with `updated`, keeping the target's id, and keeps the macro
  /// metadata consistent (cel-go `UpdateExpr`).
  ///
  /// The update moves `updated`'s macro call, if any, to the target id, or clears the target's
  /// macro call when the update is not a macro. Macro calls that refer to the target or to
  /// `updated` are rewritten to the new content.
  mutating func updateExpr(_ targetID: Int64, _ updated: Expr) {
    ast.expr.updateNode(targetID) { $0.kind = updated.kind }
    updateMetadata(targetID, updated)
  }

  /// Gives `target`, a node outside `ast` that is to become part of it, the kind of `updated`
  /// and keeps the macro metadata consistent, as the id-based `updateExpr` does.
  package mutating func updateExpr(_ target: inout Expr, _ updated: Expr) {
    target.kind = updated.kind
    updateMetadata(target.id, updated)
  }

  private mutating func updateMetadata(_ targetID: Int64, _ updated: Expr) {
    if updated.id != targetID {
      literalValues[targetID] = literalValues[updated.id]
    }
    if ast.sourceInfo.macroCalls.isEmpty {
      return
    }
    let targetIsMacro = ast.sourceInfo.macroCall(targetID) != nil
    let updatedMacro = ast.sourceInfo.macroCall(updated.id)
    if let updatedMacro {
      // The updated macro moves into the target id slot.
      clearMacroCall(updated.id)
      setMacroCall(targetID, updatedMacro)
    } else if targetIsMacro {
      clearMacroCall(targetID)
    }
    // Punch holes in the updated value where macro references exist.
    let info = ast.sourceInfo
    var macroExpr = Expr(id: targetID, kind: updated.kind)
    macroExpr.transformPostOrder { e in
      if info.macroCall(e.id) != nil {
        e.kind = .unspecified
      }
    }
    let updatedIsMacro = updatedMacro != nil
    let updatedID = updated.id
    // Update any references to the expression within a macro.
    for id in info.macroCalls.keys {
      guard var call = info.macroCall(id) else {
        continue
      }
      call.transformPostOrder { e in
        if e.id == targetID {
          e.kind = macroExpr.kind
        }
        if e.id == updatedID {
          e.kind = updatedIsMacro ? .unspecified : macroExpr.kind
          e.renumberIDs { $0 == updatedID ? targetID : $0 }
        }
      }
      setMacroCall(id, call)
    }
  }
}

/// An issue an optimizer could not recover from.
struct OptimizerError: Error, CustomStringConvertible {
  var description: String

  init(_ description: String) {
    self.description = description
  }
}

// MARK: - Expression tree helpers

extension Expr {
  /// The node with the given id, searching this expression and its descendants.
  package func node(_ id: Int64) -> Expr? {
    if self.id == id {
      return self
    }
    for child in children {
      if let found = child.node(id) {
        return found
      }
    }
    return nil
  }

  /// Applies `body` to the node with the given id; returns whether it was found.
  @discardableResult
  package mutating func updateNode(_ id: Int64, _ body: (inout Expr) -> Void) -> Bool {
    if self.id == id {
      body(&self)
      return true
    }
    var found = false
    mutateChildren { child in
      if !found {
        found = child.updateNode(id, body)
      }
    }
    return found
  }

  /// Applies `body` to every node, children before their parent (cel-go `PostOrderVisit` with a
  /// visitor that mutates nodes).
  package mutating func transformPostOrder(_ body: (inout Expr) -> Void) {
    mutateChildren { $0.transformPostOrder(body) }
    body(&self)
  }

  /// Applies `body` to each direct child, in navigation order.
  mutating func mutateChildren(_ body: (inout Expr) -> Void) {
    switch kind {
    case .unspecified, .literal, .ident:
      return
    case .select(var s):
      body(&s.operand)
      kind = .select(s)
    case .call(var c):
      if var target = c.target {
        body(&target)
        c.target = target
      }
      for i in c.args.indices {
        body(&c.args[i])
      }
      kind = .call(c)
    case .list(var l):
      for i in l.elements.indices {
        body(&l.elements[i])
      }
      kind = .list(l)
    case .map(var m):
      for i in m.entries.indices {
        body(&m.entries[i].key)
        body(&m.entries[i].value)
      }
      kind = .map(m)
    case .struct(var s):
      for i in s.fields.indices {
        body(&s.fields[i].value)
      }
      kind = .struct(s)
    case .comprehension(var c):
      body(&c.iterRange)
      body(&c.accuInit)
      body(&c.loopCondition)
      body(&c.loopStep)
      body(&c.result)
      kind = .comprehension(c)
    }
  }
}
