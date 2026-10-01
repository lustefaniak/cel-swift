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

// Ported from cel-go cel/optimizer.go (StaticOptimizer, OptimizerContext, optimizerExprFactory,
// normalizeIDs, cleanupMacroRefs, idGenerator), the parts the policy composer uses.
//
// cel-go's expressions are pointers that optimizers mutate in place (`UpdateExpr`); Swift's `Expr`
// is a value, so updates find the target node by id inside the tree being rewritten. Ids are
// unique within an AST, which makes the lookup unambiguous.
//
// TODO(api): the static optimizer belongs next to the public `Environment` in `CEL`; it lives here
// until the core has one.

import CEL

/// Generates expression ids, remapping old ids stably (cel-go `idGenerator`).
final class IDGenerator {
  private var idMap: [Int64: Int64] = [:]
  private(set) var seed: Int64

  init(seed: Int64) {
    self.seed = seed
  }

  func nextID() -> Int64 {
    seed += 1
    return seed
  }

  func renumberStable(_ id: Int64) -> Int64 {
    if id == 0 {
      return 0
    }
    if let newID = idMap[id] {
      return newID
    }
    let next = nextID()
    idMap[id] = next
    return next
  }
}

/// The state shared by an optimization pass: environment, expression factory, source info and
/// issues (cel-go `OptimizerContext`).
final class OptimizerContext {
  var env: Environment
  var sourceInfo: SourceInfo
  var errors: CELErrors
  private let ids: IDGenerator

  init(env: Environment, sourceInfo: SourceInfo, seed: Int64, source: any Source) {
    self.env = env
    self.sourceInfo = sourceInfo
    self.errors = CELErrors(source: source)
    self.ids = IDGenerator(seed: seed)
  }

  func nextID() -> Int64 {
    ids.nextID()
  }

  // MARK: Issues and environment

  func reportError(atID id: Int64, _ message: String) {
    // cel-go's optimizer issues carry no source info, so the location is unknown.
    errors.reportError(exprID: id, at: .none, message)
  }

  func extendEnv(variables: [VariableDecl]) throws {
    env = try env.declaring(variables)
  }

  // MARK: Factory

  func newAST(_ expr: Expr) -> AST {
    AST(expr: expr, sourceInfo: sourceInfo)
  }

  func newCall(_ function: String, _ args: [Expr]) -> Expr {
    .call(id: nextID(), function: function, args: args)
  }

  func newMemberCall(_ function: String, target: Expr, _ args: [Expr]) -> Expr {
    .memberCall(id: nextID(), function: function, target: target, args: args)
  }

  func newIdent(_ name: String) -> Expr {
    .ident(id: nextID(), name)
  }

  func newLiteral(_ value: Constant) -> Expr {
    .literal(id: nextID(), value)
  }

  func newList(_ elements: [Expr], optionalIndices: [Int32] = []) -> Expr {
    .list(id: nextID(), elements: elements, optionalIndices: optionalIndices)
  }

  /// Copies an AST with fresh ids (cel-go `CopyAST`).
  func copyAST(_ ast: AST) -> (Expr, SourceInfo) {
    let gen = IDGenerator(seed: nextID())
    var expr = ast.expr
    var info = ast.sourceInfo
    normalizeIDs(gen.renumberStable, &expr, &info)
    // Advance this context's ids past the copy.
    let last = gen.nextID()
    while ids.seed < last {
      _ = ids.nextID()
    }
    return (expr, info)
  }

  /// Copies an AST with fresh ids and merges its macro calls and positions into this context's
  /// source info (cel-go `CopyASTAndMetadata`).
  func copyASTAndMetadata(_ ast: AST) -> Expr {
    let (expr, info) = copyAST(ast)
    for (id, call) in info.macroCalls {
      sourceInfo.setMacroCall(id, call)
    }
    for (id, offset) in info.offsetRanges {
      sourceInfo.setOffsetRange(id, offset)
    }
    return expr
  }

  /// Replaces the kind of `target` with that of `updated`, keeping the target id, and keeps the
  /// macro call metadata consistent (cel-go `UpdateExpr`).
  func updateExpr(_ target: inout Expr, _ updated: Expr) {
    target.kind = updated.kind
    if sourceInfo.macroCalls.isEmpty {
      return
    }
    let targetID = target.id
    let targetIsMacro = sourceInfo.macroCall(targetID) != nil
    let updatedMacro = sourceInfo.macroCall(updated.id)
    if let updatedMacro {
      sourceInfo.clearMacroCall(updated.id)
      sourceInfo.setMacroCall(targetID, updatedMacro)
    } else if targetIsMacro {
      sourceInfo.clearMacroCall(targetID)
    }

    // Macro references inside the replacement become placeholders, as in parsed macro calls.
    var macroExpr = target
    let calls = sourceInfo.macroCalls
    macroExpr.postOrderTransform { e in
      if calls[e.id] != nil {
        e.kind = .unspecified
      }
    }
    let updatedIsMacro = updatedMacro != nil
    for (id, var call) in sourceInfo.macroCalls {
      var changed = false
      call.postOrderTransform { c in
        if c.id == targetID {
          c.kind = macroExpr.kind
          changed = true
        }
        if c.id == updated.id {
          c.kind = updatedIsMacro ? .unspecified : macroExpr.kind
          c.renumberIDs { $0 == updated.id ? targetID : $0 }
          changed = true
        }
      }
      if changed {
        sourceInfo.setMacroCall(id, call)
      }
    }
  }

  /// Applies `updateExpr` to the node with the given id inside `root`.
  func updateExpr(in root: inout Expr, id: Int64, _ updated: Expr) {
    _ = root.mutateNode(id: id) { self.updateExpr(&$0, updated) }
  }
}

/// Renumbers the ids of an expression and its source info, including macro calls
/// (cel-go `normalizeIDs`).
func normalizeIDs(_ gen: (Int64) -> Int64, _ expr: inout Expr, _ info: inout SourceInfo) {
  expr.renumberIDs(gen)
  info.renumberIDs(gen)
  if info.macroCalls.isEmpty {
    return
  }
  let sortedMacroIDs = info.macroCalls.keys.sorted()
  var callIDMap: [Int64: Int64] = [:]
  for id in sortedMacroIDs {
    callIDMap[id] = gen(id)
  }
  var updates: [(Int64, Expr)] = []
  for oldID in sortedMacroIDs {
    guard var call = info.macroCall(oldID), let newID = callIDMap[oldID] else {
      continue
    }
    call.renumberIDs(gen)
    updates.append((newID, call))
    info.clearMacroCall(oldID)
  }
  for (id, call) in updates {
    info.setMacroCall(id, call)
  }
}

/// Removes macro calls no longer referenced by the expression or another macro call
/// (cel-go `cleanupMacroRefs`).
func cleanupMacroRefs(_ expr: Expr, _ info: inout SourceInfo) {
  if info.macroCalls.isEmpty {
    return
  }
  var refs = Set<Int64>()
  expr.postOrderVisit(expr: { if $0.id != 0 { refs.insert($0.id) } })
  for call in info.macroCalls.values {
    call.postOrderVisit(expr: { if $0.id != 0 { refs.insert($0.id) } })
  }
  for id in info.macroCalls.keys where !refs.contains(id) {
    info.clearMacroCall(id)
  }
}

/// A single optimization pass (cel-go `ASTOptimizer`).
protocol ASTOptimizer {
  func optimize(_ ctx: OptimizerContext, _ ast: AST) -> AST
}

/// Applies an optimization pass, then renumbers ids and type-checks the result
/// (cel-go `StaticOptimizer.Optimize` with one optimizer).
///
/// - Parameters:
///   - sourceOverride: Replaces the AST's source and discards its source info
///     (cel-go `OptimizeWithSource`).
func optimize(
  _ optimizer: some ASTOptimizer, env: Environment, ast: AST, source: any Source,
  sourceOverride: (any Source)? = nil
) -> (ast: AST?, errors: CELErrors, source: any Source) {
  let effectiveSource = sourceOverride ?? source
  let sourceInfo = sourceOverride.map { SourceInfo(source: $0) } ?? ast.sourceInfo
  let ctx = OptimizerContext(env: env, sourceInfo: sourceInfo, seed: ast.maxID, source: effectiveSource)
  let result = optimizer.optimize(ctx, ast)
  if !ctx.errors.isEmpty {
    return (nil, ctx.errors, effectiveSource)
  }
  let fresh = IDGenerator(seed: 0)
  var expr = result.expr
  var info = result.sourceInfo
  normalizeIDs(fresh.renumberStable, &expr, &info)
  cleanupMacroRefs(expr, &info)
  let (checked, errors) = ctx.env.checkAST(AST(expr: expr, sourceInfo: info), source: effectiveSource)
  return (checked, errors, effectiveSource)
}

extension Expr {
  /// Rewrites the expression bottom-up: children first, then the node (the mutable counterpart of
  /// `postOrderVisit` for expression nodes).
  mutating func postOrderTransform(_ f: (inout Expr) -> Void) {
    switch kind {
    case .unspecified, .literal, .ident:
      break
    case .select(var s):
      s.operand.postOrderTransform(f)
      kind = .select(s)
    case .call(var c):
      if var target = c.target {
        target.postOrderTransform(f)
        c.target = target
      }
      for i in c.args.indices {
        c.args[i].postOrderTransform(f)
      }
      kind = .call(c)
    case .list(var l):
      for i in l.elements.indices {
        l.elements[i].postOrderTransform(f)
      }
      kind = .list(l)
    case .map(var m):
      for i in m.entries.indices {
        m.entries[i].key.postOrderTransform(f)
        m.entries[i].value.postOrderTransform(f)
      }
      kind = .map(m)
    case .struct(var s):
      for i in s.fields.indices {
        s.fields[i].value.postOrderTransform(f)
      }
      kind = .struct(s)
    case .comprehension(var c):
      c.iterRange.postOrderTransform(f)
      c.accuInit.postOrderTransform(f)
      c.loopCondition.postOrderTransform(f)
      c.loopStep.postOrderTransform(f)
      c.result.postOrderTransform(f)
      kind = .comprehension(c)
    }
    f(&self)
  }

  /// Mutates the node with the given id; returns whether it was found.
  mutating func mutateNode(id: Int64, _ f: (inout Expr) -> Void) -> Bool {
    if self.id == id {
      f(&self)
      return true
    }
    var found = false
    switch kind {
    case .unspecified, .literal, .ident:
      break
    case .select(var s):
      found = s.operand.mutateNode(id: id, f)
      if found { kind = .select(s) }
    case .call(var c):
      if var target = c.target, target.mutateNode(id: id, f) {
        c.target = target
        found = true
      } else {
        for i in c.args.indices where c.args[i].mutateNode(id: id, f) {
          found = true
          break
        }
      }
      if found { kind = .call(c) }
    case .list(var l):
      for i in l.elements.indices where l.elements[i].mutateNode(id: id, f) {
        found = true
        break
      }
      if found { kind = .list(l) }
    case .map(var m):
      for i in m.entries.indices {
        if m.entries[i].key.mutateNode(id: id, f) || m.entries[i].value.mutateNode(id: id, f) {
          found = true
          break
        }
      }
      if found { kind = .map(m) }
    case .struct(var s):
      for i in s.fields.indices where s.fields[i].value.mutateNode(id: id, f) {
        found = true
        break
      }
      if found { kind = .struct(s) }
    case .comprehension(var c):
      found =
        c.iterRange.mutateNode(id: id, f) || c.accuInit.mutateNode(id: id, f)
        || c.loopCondition.mutateNode(id: id, f) || c.loopStep.mutateNode(id: id, f)
        || c.result.mutateNode(id: id, f)
      if found { kind = .comprehension(c) }
    }
    return found
  }

  /// Returns the node with the given id, if present.
  func node(id: Int64) -> Expr? {
    var result: Expr?
    postOrderVisit(expr: { if result == nil && $0.id == id { result = $0 } })
    return result
  }
}
