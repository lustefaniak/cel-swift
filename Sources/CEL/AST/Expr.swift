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

// Ported from cel-go common/ast/expr.go and common/ast/factory.go.
//
// cel-go models expressions as interfaces with `Kind()` / `As<Kind>()` accessors and mutable nodes.
// Here an expression is a value: `Expr` holds an id and an `Expr.Kind` enum whose payloads are the
// node structs. Rewrites mutate a copy.

/// A literal constant in the AST. Independent of the runtime value model on purpose: the checker and
/// interpreter convert constants to values.
package enum Constant: Hashable, Sendable {
  case null
  case bool(Bool)
  case int(Int64)
  case uint(UInt64)
  case double(Double)
  case string(String)
  case bytes([UInt8])
}

/// A node in a CEL abstract syntax tree.
package struct Expr: Hashable, Sendable {
  /// The id of the node, unique within an AST (0 for an unset expression).
  package var id: Int64
  /// The node kind and its payload.
  package var kind: Kind

  package init(id: Int64, kind: Kind) {
    self.id = id
    self.kind = kind
  }

  /// The kinds of expression node.
  package indirect enum Kind: Hashable, Sendable {
    /// An unset expression, produced for syntax errors.
    case unspecified
    /// A primitive literal.
    case literal(Constant)
    /// A simple variable, constant, or type identifier.
    case ident(String)
    /// A field selection or presence test.
    case select(Select)
    /// A global or member function call.
    case call(Call)
    /// A list literal.
    case list(List)
    /// A map literal.
    case map(Map)
    /// A message (struct) literal.
    case `struct`(Struct)
    /// A comprehension, produced by macros.
    case comprehension(Comprehension)
  }

  /// A field selection `operand.field`, or a presence test `has(operand.field)` when `testOnly`.
  package struct Select: Hashable, Sendable {
    package var operand: Expr
    package var field: String
    package var testOnly: Bool

    package init(operand: Expr, field: String, testOnly: Bool = false) {
      self.operand = operand
      self.field = field
      self.testOnly = testOnly
    }
  }

  /// A function call; a member call when `target` is set.
  package struct Call: Hashable, Sendable {
    package var function: String
    package var target: Expr?
    package var args: [Expr]

    package init(function: String, target: Expr? = nil, args: [Expr]) {
      self.function = function
      self.target = target
      self.args = args
    }

    /// Whether the call has a receiver (`target.function(args)`).
    package var isMemberFunction: Bool { target != nil }
  }

  /// A list literal; `optionalIndices` lists elements written as `?elem`.
  package struct List: Hashable, Sendable {
    package var elements: [Expr]
    package var optionalIndices: [Int32]

    package init(elements: [Expr], optionalIndices: [Int32] = []) {
      self.elements = elements
      self.optionalIndices = optionalIndices
    }

    /// Whether the element at `index` is optional.
    package func isOptional(_ index: Int32) -> Bool {
      optionalIndices.contains(index)
    }
  }

  /// A map literal.
  package struct Map: Hashable, Sendable {
    package var entries: [MapEntry]

    package init(entries: [MapEntry]) {
      self.entries = entries
    }
  }

  /// A `key: value` entry in a map literal, with its own id.
  package struct MapEntry: Hashable, Sendable {
    package var id: Int64
    package var key: Expr
    package var value: Expr
    package var isOptional: Bool

    package init(id: Int64, key: Expr, value: Expr, isOptional: Bool = false) {
      self.id = id
      self.key = key
      self.value = value
      self.isOptional = isOptional
    }
  }

  /// A message literal `TypeName{field: value, ...}`.
  package struct Struct: Hashable, Sendable {
    package var typeName: String
    package var fields: [StructField]

    package init(typeName: String, fields: [StructField]) {
      self.typeName = typeName
      self.fields = fields
    }
  }

  /// A `field: value` initializer in a message literal, with its own id.
  package struct StructField: Hashable, Sendable {
    package var id: Int64
    package var name: String
    package var value: Expr
    package var isOptional: Bool

    package init(id: Int64, name: String, value: Expr, isOptional: Bool = false) {
      self.id = id
      self.name = name
      self.value = value
      self.isOptional = isOptional
    }
  }

  /// A fold over a list or map. One-variable comprehensions leave `iterVar2` empty.
  package struct Comprehension: Hashable, Sendable {
    package var iterRange: Expr
    package var iterVar: String
    package var iterVar2: String
    package var accuVar: String
    package var accuInit: Expr
    package var loopCondition: Expr
    package var loopStep: Expr
    package var result: Expr

    package init(
      iterRange: Expr, iterVar: String, iterVar2: String = "", accuVar: String, accuInit: Expr,
      loopCondition: Expr, loopStep: Expr, result: Expr
    ) {
      self.iterRange = iterRange
      self.iterVar = iterVar
      self.iterVar2 = iterVar2
      self.accuVar = accuVar
      self.accuInit = accuInit
      self.loopCondition = loopCondition
      self.loopStep = loopStep
      self.result = result
    }

    /// Whether this is a two-variable comprehension.
    package var hasIterVar2: Bool { !iterVar2.isEmpty }
  }
}

/// An entry of a map or message literal, as handed to visitors (cel-go `ast.EntryExpr`).
package enum EntryExpr: Hashable, Sendable {
  case mapEntry(Expr.MapEntry)
  case structField(Expr.StructField)

  /// The id of the entry.
  package var id: Int64 {
    switch self {
    case .mapEntry(let e): return e.id
    case .structField(let f): return f.id
    }
  }
}

// MARK: - Constructors (cel-go ExprFactory)

extension Expr {
  /// An unset expression with the given id.
  package static func unspecified(id: Int64) -> Expr {
    Expr(id: id, kind: .unspecified)
  }

  /// A literal expression.
  package static func literal(id: Int64, _ value: Constant) -> Expr {
    Expr(id: id, kind: .literal(value))
  }

  /// An identifier expression.
  package static func ident(id: Int64, _ name: String) -> Expr {
    Expr(id: id, kind: .ident(name))
  }

  /// A field selection `operand.field`.
  package static func select(id: Int64, operand: Expr, field: String) -> Expr {
    Expr(id: id, kind: .select(Select(operand: operand, field: field)))
  }

  /// A presence test `has(operand.field)`.
  package static func presenceTest(id: Int64, operand: Expr, field: String) -> Expr {
    Expr(id: id, kind: .select(Select(operand: operand, field: field, testOnly: true)))
  }

  /// A global function call.
  package static func call(id: Int64, function: String, args: [Expr]) -> Expr {
    Expr(id: id, kind: .call(Call(function: function, target: nil, args: args)))
  }

  /// A member (receiver-style) function call.
  package static func memberCall(id: Int64, function: String, target: Expr, args: [Expr]) -> Expr {
    Expr(id: id, kind: .call(Call(function: function, target: target, args: args)))
  }

  /// A list literal.
  package static func list(id: Int64, elements: [Expr], optionalIndices: [Int32] = []) -> Expr {
    Expr(id: id, kind: .list(List(elements: elements, optionalIndices: optionalIndices)))
  }

  /// A map literal.
  package static func map(id: Int64, entries: [MapEntry]) -> Expr {
    Expr(id: id, kind: .map(Map(entries: entries)))
  }

  /// A message literal.
  package static func `struct`(id: Int64, typeName: String, fields: [StructField]) -> Expr {
    Expr(id: id, kind: .struct(Struct(typeName: typeName, fields: fields)))
  }

  /// A comprehension; one-variable when `iterVar2` is empty.
  package static func comprehension(
    id: Int64, iterRange: Expr, iterVar: String, iterVar2: String = "", accuVar: String,
    accuInit: Expr, loopCondition: Expr, loopStep: Expr, result: Expr
  ) -> Expr {
    Expr(
      id: id,
      kind: .comprehension(
        Comprehension(
          iterRange: iterRange, iterVar: iterVar, iterVar2: iterVar2, accuVar: accuVar,
          accuInit: accuInit, loopCondition: loopCondition, loopStep: loopStep, result: result)))
  }
}

// MARK: - Accessors

extension Expr {
  /// The literal value, if this is a literal.
  package var asLiteral: Constant? {
    if case .literal(let c) = kind { return c }
    return nil
  }

  /// The identifier name, if this is an identifier.
  package var asIdent: String? {
    if case .ident(let name) = kind { return name }
    return nil
  }

  /// The selection, if this is a select or presence test.
  package var asSelect: Select? {
    if case .select(let s) = kind { return s }
    return nil
  }

  /// The call, if this is a call.
  package var asCall: Call? {
    if case .call(let c) = kind { return c }
    return nil
  }

  /// The list literal, if this is one.
  package var asList: List? {
    if case .list(let l) = kind { return l }
    return nil
  }

  /// The map literal, if this is one.
  package var asMap: Map? {
    if case .map(let m) = kind { return m }
    return nil
  }

  /// The message literal, if this is one.
  package var asStruct: Struct? {
    if case .struct(let s) = kind { return s }
    return nil
  }

  /// The comprehension, if this is one.
  package var asComprehension: Comprehension? {
    if case .comprehension(let c) = kind { return c }
    return nil
  }

  /// Whether this is an unset expression.
  package var isUnspecified: Bool {
    if case .unspecified = kind { return true }
    return false
  }

  /// Replaces every id in the expression (including entry ids) with `generate(oldID)`.
  package mutating func renumberIDs(_ generate: (Int64) -> Int64) {
    id = generate(id)
    switch kind {
    case .unspecified, .literal, .ident:
      break
    case .select(var s):
      s.operand.renumberIDs(generate)
      kind = .select(s)
    case .call(var c):
      if var target = c.target {
        target.renumberIDs(generate)
        c.target = target
      }
      for i in c.args.indices {
        c.args[i].renumberIDs(generate)
      }
      kind = .call(c)
    case .list(var l):
      for i in l.elements.indices {
        l.elements[i].renumberIDs(generate)
      }
      kind = .list(l)
    case .map(var m):
      for i in m.entries.indices {
        m.entries[i].id = generate(m.entries[i].id)
        m.entries[i].key.renumberIDs(generate)
        m.entries[i].value.renumberIDs(generate)
      }
      kind = .map(m)
    case .struct(var s):
      for i in s.fields.indices {
        s.fields[i].id = generate(s.fields[i].id)
        s.fields[i].value.renumberIDs(generate)
      }
      kind = .struct(s)
    case .comprehension(var c):
      c.iterRange.renumberIDs(generate)
      c.accuInit.renumberIDs(generate)
      c.loopCondition.renumberIDs(generate)
      c.loopStep.renumberIDs(generate)
      c.result.renumberIDs(generate)
      kind = .comprehension(c)
    }
  }
}

/// Builds expressions with a fixed accumulator variable name (cel-go `ast.ExprFactory`).
package struct ExprFactory: Sendable {
  /// The accumulator variable name used by comprehension macros.
  package let accumulatorName: String

  /// Creates a factory using the hidden accumulator name `@result`.
  package init() {
    self.accumulatorName = "@result"
  }

  /// Creates a factory using a custom accumulator name.
  package init(accumulatorName: String) {
    self.accumulatorName = accumulatorName
  }

  /// An identifier referring to the accumulator.
  package func newAccuIdent(id: Int64) -> Expr {
    .ident(id: id, accumulatorName)
  }

  /// A deep copy of `expr`. Expressions are values, so this is the identity; kept for parity with
  /// cel-go's `CopyExpr`.
  package func copyExpr(_ expr: Expr) -> Expr {
    expr
  }
}
