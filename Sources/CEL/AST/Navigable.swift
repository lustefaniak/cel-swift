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

// Ported from cel-go common/ast/navigable.go.
//
// The type accessor of cel-go's NavigableExpr needs the checker's type map; the checker adds it.

/// The order in which a traversal reports nodes.
package enum VisitOrder: Sendable {
  case preOrder
  case postOrder
}

extension Expr {
  /// Walks the expression bottom-up, calling `expr` for every node and `entry` for every map entry or
  /// struct field.
  package func postOrderVisit(expr: (Expr) -> Void, entry: (EntryExpr) -> Void = { _ in }) {
    visit(order: .postOrder, depth: 0, maxDepth: 0, expr: expr, entry: entry)
  }

  /// Walks the expression top-down, calling `expr` for every node and `entry` for every map entry or
  /// struct field.
  package func preOrderVisit(expr: (Expr) -> Void, entry: (EntryExpr) -> Void = { _ in }) {
    visit(order: .preOrder, depth: 0, maxDepth: 0, expr: expr, entry: entry)
  }

  /// The traversal shared by the visit helpers. `maxDepth` > 0 stops descending at that depth.
  package func visit(
    order: VisitOrder, depth: Int, maxDepth: Int, expr visitExpr: (Expr) -> Void,
    entry visitEntry: (EntryExpr) -> Void
  ) {
    if maxDepth > 0 && depth == maxDepth {
      return
    }
    if order == .preOrder {
      visitExpr(self)
    }
    let next = depth + 1
    switch kind {
    case .call(let c):
      if let target = c.target {
        target.visit(order: order, depth: next, maxDepth: maxDepth, expr: visitExpr, entry: visitEntry)
      }
      for arg in c.args {
        arg.visit(order: order, depth: next, maxDepth: maxDepth, expr: visitExpr, entry: visitEntry)
      }
    case .comprehension(let c):
      for e in [c.iterRange, c.accuInit, c.loopCondition, c.loopStep, c.result] {
        e.visit(order: order, depth: next, maxDepth: maxDepth, expr: visitExpr, entry: visitEntry)
      }
    case .list(let l):
      for elem in l.elements {
        elem.visit(order: order, depth: next, maxDepth: maxDepth, expr: visitExpr, entry: visitEntry)
      }
    case .map(let m):
      for e in m.entries {
        if order == .preOrder {
          visitEntry(.mapEntry(e))
        }
        e.key.visit(order: order, depth: next, maxDepth: maxDepth, expr: visitExpr, entry: visitEntry)
        e.value.visit(order: order, depth: next, maxDepth: maxDepth, expr: visitExpr, entry: visitEntry)
        if order == .postOrder {
          visitEntry(.mapEntry(e))
        }
      }
    case .select(let s):
      s.operand.visit(order: order, depth: next, maxDepth: maxDepth, expr: visitExpr, entry: visitEntry)
    case .struct(let s):
      for f in s.fields {
        if order == .preOrder {
          visitEntry(.structField(f))
        }
        f.value.visit(order: order, depth: next, maxDepth: maxDepth, expr: visitExpr, entry: visitEntry)
        if order == .postOrder {
          visitEntry(.structField(f))
        }
      }
    case .unspecified, .literal, .ident:
      break
    }
    if order == .postOrder {
      visitExpr(self)
    }
  }

  /// The direct children of the node, in cel-go's navigation order.
  package var children: [Expr] {
    switch kind {
    case .select(let s):
      return [s.operand]
    case .call(let c):
      if let target = c.target {
        return [target] + c.args
      }
      return c.args
    case .list(let l):
      return l.elements
    case .map(let m):
      return m.entries.flatMap { [$0.key, $0.value] }
    case .struct(let s):
      return s.fields.map(\.value)
    case .comprehension(let c):
      return [c.iterRange, c.accuInit, c.loopCondition, c.loopStep, c.result]
    case .unspecified, .literal, .ident:
      return []
    }
  }
}

extension AST {
  /// Whether the expression nests deeper than `maxDepth` levels (the root has depth 0).
  ///
  /// The walk descends at most `maxDepth + 1` levels, so it is safe on adversarially deep input.
  /// A non-positive `maxDepth` disables the check.
  package func exceedsDepth(_ maxDepth: Int) -> Bool {
    if maxDepth <= 0 {
      return false
    }
    var exceeds = false
    NavigableExpr(root: expr).visitNavigable(order: .postOrder, maxDepth: maxDepth + 1) { nav in
      if nav.depth >= maxDepth {
        exceeds = true
      }
    }
    return exceeds
  }
}

/// An expression node that knows its parent and depth (cel-go `ast.NavigableExpr`).
package final class NavigableExpr: Sendable {
  /// The underlying expression.
  package let expr: Expr
  /// The parent node, `nil` for the root.
  package let parent: NavigableExpr?
  /// The depth in the tree; the root has depth 0.
  package let depth: Int

  /// Creates a navigable root for `root`.
  package convenience init(root: Expr) {
    self.init(expr: root, parent: nil, depth: 0)
  }

  private init(expr: Expr, parent: NavigableExpr?, depth: Int) {
    self.expr = expr
    self.parent = parent
    self.depth = depth
  }

  /// The id of the node.
  package var id: Int64 { expr.id }

  /// The child nodes, in navigation order.
  package var children: [NavigableExpr] {
    expr.children.map { NavigableExpr(expr: $0, parent: self, depth: depth + 1) }
  }

  /// All descendants (including this node) matching `matcher`, in post-order.
  package func matchDescendants(_ matcher: (NavigableExpr) -> Bool) -> [NavigableExpr] {
    var matches: [NavigableExpr] = []
    visitNavigable(order: .postOrder, maxDepth: 0) { nav in
      if matcher(nav) {
        matches.append(nav)
      }
    }
    return matches
  }

  /// Walks this node and its descendants.
  package func visitNavigable(
    order: VisitOrder, maxDepth: Int, _ visitor: (NavigableExpr) -> Void
  ) {
    visitNavigable(order: order, relativeDepth: 0, maxDepth: maxDepth, visitor)
  }

  private func visitNavigable(
    order: VisitOrder, relativeDepth: Int, maxDepth: Int, _ visitor: (NavigableExpr) -> Void
  ) {
    if maxDepth > 0 && relativeDepth == maxDepth {
      return
    }
    if order == .preOrder {
      visitor(self)
    }
    for child in children {
      child.visitNavigable(order: order, relativeDepth: relativeDepth + 1, maxDepth: maxDepth, visitor)
    }
    if order == .postOrder {
      visitor(self)
    }
  }

  /// All nodes in `exprs` and their descendants matching `matcher`, in post-order.
  package static func matchSubset(
    _ exprs: [NavigableExpr], _ matcher: (NavigableExpr) -> Bool
  ) -> [NavigableExpr] {
    var matches: [NavigableExpr] = []
    for e in exprs {
      e.visitNavigable(order: .postOrder, maxDepth: 1) { nav in
        if matcher(nav) {
          matches.append(nav)
        }
      }
    }
    return matches
  }

  /// Matches literals and list, map and struct literals made only of constants.
  package static func isConstantValue(_ e: NavigableExpr) -> Bool {
    switch e.expr.kind {
    case .literal:
      return true
    case .struct, .map, .list:
      return e.children.allSatisfy(isConstantValue)
    default:
      return false
    }
  }

  /// A matcher for nodes calling `function`.
  package static func functionMatcher(_ function: String) -> @Sendable (NavigableExpr) -> Bool {
    { e in e.expr.asCall?.function == function }
  }

  /// A matcher accepting every node.
  package static func allMatcher() -> @Sendable (NavigableExpr) -> Bool {
    { _ in true }
  }
}
