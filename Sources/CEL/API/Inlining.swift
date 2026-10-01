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
// Ported from cel-go cel/inlining.go (InlineVariable, inliningOptimizer).

/// A variable, or a qualified field selection, to replace with an expression by the
/// ``ExpressionOptimizer/inlining(_:)`` optimizer (cel-go `InlineVariable`).
public struct InlinedVariable: Sendable {
  /// The variable or qualified field selection to replace, such as `a` or `a.b.c`.
  public let name: String

  /// The name the definition is bound to with `cel.bind()` when the variable occurs more than
  /// once.
  public let alias: String

  /// The expression replacing the variable.
  public let definition: CheckedExpression

  /// Creates an inlined variable (cel-go `NewInlineVariable`, `NewInlineVariableWithAlias`).
  ///
  /// - Parameters:
  ///   - name: The variable or qualified field selection to replace.
  ///   - alias: The `cel.bind()` variable name used when the variable occurs more than once;
  ///     defaults to `name`.
  ///   - definition: The checked expression replacing the variable.
  public init(_ name: String, alias: String? = nil, definition: CheckedExpression) {
    self.name = name
    self.alias = alias ?? name
    self.definition = definition
  }

  /// The type of the definition.
  public var type: CELType { definition.outputType }
}

extension ExpressionOptimizer {
  /// Replaces variables with expressions (cel-go `NewInliningOptimizer`).
  ///
  /// A variable that occurs once is replaced by its definition. A variable that occurs more than
  /// once is replaced by its alias, and the definition is bound to the alias with `cel.bind()` at
  /// the closest common ancestor of the occurrences, so it is evaluated once. Occurrences inside
  /// comprehensions that declare a variable with the same name are left alone. Inside `has()`,
  /// the presence test becomes a test against the definition's zero value, such as
  /// `def.size() != 0`.
  ///
  /// Unparsing the result needs macro call tracking (``Environment/Option/macroCallTracking``) to
  /// print the `cel.bind()` calls.
  ///
  /// - Parameter variables: The variables to replace, in order.
  public static func inlining(_ variables: [InlinedVariable]) -> ExpressionOptimizer {
    let inliner = Inliner(variables: variables)
    return ExpressionOptimizer { inliner.optimize(&$0) }
  }

  /// Replaces variables with expressions (cel-go `NewInliningOptimizer`).
  ///
  /// - Parameter variables: The variables to replace, in order.
  public static func inlining(_ variables: InlinedVariable...) -> ExpressionOptimizer {
    inlining(variables)
  }
}

struct Inliner: Sendable {
  let variables: [InlinedVariable]

  /// cel-go `inliningOptimizer.Optimize`.
  func optimize(_ ctx: inout OptimizerContext) {
    for variable in variables {
      let root = NavigableExpr(root: ctx.ast.expr)
      let matches = root.matchDescendants(matchVariable(variable.name))
      // Skip cases where the variable isn't in the expression graph.
      if matches.isEmpty {
        continue
      }
      let type = variable.type
      // For a single match, replace the sub-graph directly.
      if matches.count == 1 || !isBindable(matches, type) {
        for match in matches {
          let copy = ctx.copyASTAndMetadata(variable.definition.ast)
          inlineExpr(&ctx, match.id, copy, type)
        }
        continue
      }
      // For multiple matches, find the least common ancestor and bind the definition there with
      // a cel.bind() macro.
      var lca = root
      var lcaAncestorCount = 0
      var ancestors: [Int64: Int] = [:]
      for match in matches {
        var parent: NavigableExpr? = match
        while let p = parent {
          guard let ancestorCount = ancestors[p.id] else {
            ancestors[p.id] = 1
            parent = p.parent
            continue
          }
          if lcaAncestorCount < ancestorCount || (lcaAncestorCount == ancestorCount && lca.depth < p.depth) {
            lca = p
            lcaAncestorCount = ancestorCount
          }
          ancestors[p.id] = ancestorCount + 1
          parent = p.parent
        }
        let alias = ctx.newIdent(variable.alias)
        inlineExpr(&ctx, match.id, alias, type)
      }
      let copy = ctx.copyASTAndMetadata(variable.definition.ast)
      guard let lcaExpr = ctx.node(lca.id) else {
        continue
      }
      let (inlined, bindMacro) = ctx.newBindMacro(lca.id, variable.alias, copy, lcaExpr)
      inlineExpr(&ctx, lca.id, inlined, type)
      ctx.setMacroCall(lca.id, bindMacro)
    }
  }

  /// Replaces the node `id` with the inlined expression; inside a presence test, rewrites the
  /// test so it applies to the inlined value (cel-go `inlineExpr`).
  private func inlineExpr(_ ctx: inout OptimizerContext, _ id: Int64, _ inlined: Expr, _ type: CELType) {
    if let previous = ctx.node(id), let sel = previous.asSelect, sel.testOnly {
      rewritePresenceExpr(&ctx, id, inlined, type)
      return
    }
    ctx.updateExpr(id, inlined)
  }

  /// Converts a presence test on the inlined expression into a test appropriate for its type,
  /// or reports an error when there is none (cel-go `rewritePresenceExpr`).
  private func rewritePresenceExpr(_ ctx: inout OptimizerContext, _ id: Int64, _ inlined: Expr, _ type: CELType) {
    // A select expression keeps working with has().
    if let sel = inlined.asSelect {
      let (presenceTest, hasMacro) = ctx.newHasMacro(id, sel)
      ctx.updateExpr(id, presenceTest)
      ctx.setMacroCall(id, hasMacro)
      return
    }
    ctx.clearMacroCall(id)
    if type.isAssignable(from: .null) {
      let null = ctx.newConstant(.null)
      ctx.updateExpr(id, ctx.newCall(Operators.notEquals, [inlined, null]))
      return
    }
    if type.hasTrait(.sizer) {
      let size = ctx.newMemberCall("size", inlined, [])
      let zero = ctx.newConstant(.int(0))
      ctx.updateExpr(id, ctx.newCall(Operators.notEquals, [size, zero]))
      return
    }
    if let zero = zeroValueExpr(&ctx, type) {
      ctx.updateExpr(id, ctx.newCall(Operators.notEquals, [inlined, zero]))
      return
    }
    ctx.reportError(at: id, "unable to inline expression type \(type) into presence test")
  }

  /// The zero value of a type as an expression (cel-go `zeroValueExpr`); bytes, strings, lists
  /// and maps are tested with `size()` instead.
  private func zeroValueExpr(_ ctx: inout OptimizerContext, _ type: CELType) -> Expr? {
    switch type.kind {
    case .bool:
      return ctx.newConstant(.bool(false))
    case .double:
      return ctx.newConstant(.double(0))
    case .duration:
      let text = ctx.newConstant(.string("0s"))
      return ctx.newCall("duration", [text])
    case .int:
      return ctx.newConstant(.int(0))
    case .timestamp:
      let epoch = ctx.newConstant(.int(0))
      return ctx.newCall("timestamp", [epoch])
    case .struct:
      return ctx.newStruct(type.runtimeTypeName, [])
    case .uint:
      return ctx.newConstant(.uint(0))
    default:
      return nil
    }
  }

  /// Whether the definition can be bound with `cel.bind()` when some occurrences are presence
  /// tests: types with `size()` or a null value can always be tested (cel-go `isBindable`).
  private func isBindable(_ matches: [NavigableExpr], _ type: CELType) -> Bool {
    if type.isAssignable(from: .null) || type.hasTrait(.sizer) {
      return true
    }
    for match in matches {
      if let sel = match.expr.asSelect, sel.testOnly {
        return false
      }
    }
    return true
  }

  /// Matches identifiers, selections and presence tests spelling `name`, unless a comprehension
  /// variable shadows it (cel-go `matchVariable`).
  private func matchVariable(_ name: String) -> (NavigableExpr) -> Bool {
    { e in
      guard variableName(e.expr) == name else {
        return false
      }
      // The variable is shadowed when an enclosing comprehension declares it.
      var parent = e.parent
      while let p = parent {
        if let compre = p.expr.asComprehension,
          name == compre.accuVar || name == compre.iterVar || name == compre.iterVar2
        {
          return false
        }
        parent = p.parent
      }
      return true
    }
  }

  /// The qualified name an identifier, selection or presence test spells (cel-go
  /// `maybeAsVariableName`).
  private func variableName(_ e: Expr) -> String? {
    switch e.kind {
    case .ident(let name):
      return name
    case .select(let sel):
      // Presence tests are included, unlike in Container.qualifiedName(of:).
      guard let qualifier = Container.qualifiedName(of: sel.operand) else {
        return nil
      }
      return qualifier + "." + sel.field
    default:
      return nil
    }
  }
}
