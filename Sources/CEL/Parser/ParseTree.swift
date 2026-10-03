// Copyright 2018 Google LLC
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

// The parse tree built while parsing, modelled on the contexts of cel-go's generated parser
// (parser/gen/cel_parser.go) and antlr's BaseParserRuleContext. One class serves every rule; `label`
// says which generated context type a node corresponds to, and the labelled fields hold the grammar
// labels (`e`, `op`, `ids`, ...) of that type.

/// CEL grammar rule indexes (cel-go `CELParserRULE_*`).
enum CELRule {
  static let start = 0
  static let expr = 1
  static let conditionalOr = 2
  static let conditionalAnd = 3
  static let relation = 4
  static let calc = 5
  static let unary = 6
  static let member = 7
  static let primary = 8
  static let exprList = 9
  static let listInit = 10
  static let fieldInitializerList = 11
  static let optField = 12
  static let mapInitializerList = 13
  static let escapeIdent = 14
  static let optExpr = 15
  static let literal = 16

  static let names = [
    "start", "expr", "conditionalOr", "conditionalAnd", "relation", "calc",
    "unary", "member", "primary", "exprList", "listInit", "fieldInitializerList",
    "optField", "mapInitializerList", "escapeIdent", "optExpr", "literal",
  ]
  static let count = 17
}

/// The generated context type a parse tree node corresponds to.
enum ContextLabel {
  case start, expr, conditionalOr, conditionalAnd, relation, calc
  case unary, memberExpr, logicalNot, negate
  case member, primaryExpr, select, memberCall, index
  case primary, ident, globalCall, nested, createList, createStruct, createMessage, constantLiteral
  case exprList, listInit, fieldInitializerList, optField, mapInitializerList
  case escapeIdent, simpleIdentifier, escapedIdentifier
  case optExpr
  case literal, int, uint, double, string, bytes, boolTrue, boolFalse, null

  /// The Go type name, as printed by `%T` in cel-go's "unknown parse element" error.
  var goTypeName: String {
    let name: String
    switch self {
    case .start: name = "Start"
    case .expr: name = "Expr"
    case .conditionalOr: name = "ConditionalOr"
    case .conditionalAnd: name = "ConditionalAnd"
    case .relation: name = "Relation"
    case .calc: name = "Calc"
    case .unary: name = "Unary"
    case .memberExpr: name = "MemberExpr"
    case .logicalNot: name = "LogicalNot"
    case .negate: name = "Negate"
    case .member: name = "Member"
    case .primaryExpr: name = "PrimaryExpr"
    case .select: name = "Select"
    case .memberCall: name = "MemberCall"
    case .index: name = "Index"
    case .primary: name = "Primary"
    case .ident: name = "Ident"
    case .globalCall: name = "GlobalCall"
    case .nested: name = "Nested"
    case .createList: name = "CreateList"
    case .createStruct: name = "CreateStruct"
    case .createMessage: name = "CreateMessage"
    case .constantLiteral: name = "ConstantLiteral"
    case .exprList: name = "ExprList"
    case .listInit: name = "ListInit"
    case .fieldInitializerList: name = "FieldInitializerList"
    case .optField: name = "OptField"
    case .mapInitializerList: name = "MapInitializerList"
    case .escapeIdent: name = "EscapeIdent"
    case .simpleIdentifier: name = "SimpleIdentifier"
    case .escapedIdentifier: name = "EscapedIdentifier"
    case .optExpr: name = "OptExpr"
    case .literal: name = "Literal"
    case .int: name = "Int"
    case .uint: name = "Uint"
    case .double: name = "Double"
    case .string: name = "String"
    case .bytes: name = "Bytes"
    case .boolTrue: name = "BoolTrue"
    case .boolFalse: name = "BoolFalse"
    case .null: name = "Null"
    }
    return "*gen.\(name)Context"
  }
}

/// A child of a parse tree node.
enum ParseTreeChild {
  case rule(ParserRuleContext)
  case terminal(Token)
  case error(Token)

  var text: String {
    switch self {
    case .rule(let ctx): return ctx.text
    case .terminal(let t), .error(let t): return t.text
    }
  }
}

/// A node of the parse tree (antlr `BaseParserRuleContext` plus the generated labels). A tree belongs to
/// one parse on one thread, so the stored properties skip the dynamic exclusivity checks.
final class ParserRuleContext {
  /// Unowned, not weak: a parent always outlives its children (the parser holds the rule being built and
  /// each node holds its children), and a weak reference gives every context a side table that sends all
  /// its retains and releases through the slow path, which cost more than a third of parsing.
  @exclusivity(unchecked) unowned var parent: ParserRuleContext?
  @exclusivity(unchecked) var invokingState: Int
  let ruleIndex: Int
  let label: ContextLabel
  @exclusivity(unchecked) var children: [ParseTreeChild] = []
  @exclusivity(unchecked) var start: Token?
  @exclusivity(unchecked) var stop: Token?
  @exclusivity(unchecked) var exception: RecognitionException?

  // Grammar labels. Which ones are used depends on `label`, and no context type uses more than three
  // context labels, three token labels and two of each kind of list label, so the labels share these
  // slots (fewer stored properties make contexts cheaper to allocate and free, a large part of parsing).
  // Labels in the same slot never belong to the same context type.
  @exclusivity(unchecked) private var c0: ParserRuleContext?
  @exclusivity(unchecked) private var c1: ParserRuleContext?
  @exclusivity(unchecked) private var c2: ParserRuleContext?
  @exclusivity(unchecked) private var t0: Token?
  @exclusivity(unchecked) private var t1: Token?
  @exclusivity(unchecked) private var t2: Token?
  @exclusivity(unchecked) private var ta0: [Token] = []
  @exclusivity(unchecked) private var ta1: [Token] = []
  @exclusivity(unchecked) private var ca0: [ParserRuleContext] = []
  @exclusivity(unchecked) private var ca1: [ParserRuleContext] = []
  var e: ParserRuleContext? {
    _read { yield c0 }
    _modify { yield &c0 }
  }
  var e1: ParserRuleContext? {
    _read { yield c1 }
    _modify { yield &c1 }
  }
  var e2: ParserRuleContext? {
    _read { yield c2 }
    _modify { yield &c2 }
  }
  var op: Token? {
    _read { yield t0 }
    _modify { yield &t0 }
  }
  var opt: Token? {
    _read { yield t1 }
    _modify { yield &t1 }
  }
  var leadingDot: Token? {
    _read { yield t1 }
    _modify { yield &t1 }
  }
  var sign: Token? {
    _read { yield t1 }
    _modify { yield &t1 }
  }
  var tok: Token? {
    _read { yield t2 }
    _modify { yield &t2 }
  }
  var open: Token? {
    _read { yield t1 }
    _modify { yield &t1 }
  }
  /// Token `id` labels (Ident, GlobalCall, MemberCall, SimpleIdentifier, EscapedIdentifier).
  var idToken: Token? {
    _read { yield t2 }
    _modify { yield &t2 }
  }
  /// Select's `id=escapeIdent` label.
  var idContext: ParserRuleContext? {
    _read { yield c0 }
    _modify { yield &c0 }
  }
  var args: ParserRuleContext? {
    _read { yield c0 }
    _modify { yield &c0 }
  }
  var elems: ParserRuleContext? {
    _read { yield c0 }
    _modify { yield &c0 }
  }
  var entries: ParserRuleContext? {
    _read { yield c0 }
    _modify { yield &c0 }
  }
  var index: ParserRuleContext? {
    _read { yield c0 }
    _modify { yield &c0 }
  }
  var ops: [Token] {
    _read { yield ta0 }
    _modify { yield &ta0 }
  }
  var ids: [Token] {
    _read { yield ta1 }
    _modify { yield &ta1 }
  }
  var cols: [Token] {
    _read { yield ta0 }
    _modify { yield &ta0 }
  }
  /// `e1+=...` in conditionalOr / conditionalAnd, `e+=expr` in exprList.
  var exprs: [ParserRuleContext] {
    _read { yield ca0 }
    _modify { yield &ca0 }
  }
  /// `elems+=optExpr` in listInit.
  var elemList: [ParserRuleContext] {
    _read { yield ca0 }
    _modify { yield &ca0 }
  }
  var fields: [ParserRuleContext] {
    _read { yield ca0 }
    _modify { yield &ca0 }
  }
  var values: [ParserRuleContext] {
    _read { yield ca1 }
    _modify { yield &ca1 }
  }
  var keys: [ParserRuleContext] {
    _read { yield ca0 }
    _modify { yield &ca0 }
  }

  init(parent: ParserRuleContext?, invokingState: Int, ruleIndex: Int, label: ContextLabel) {
    self.parent = parent
    self.invokingState = parent == nil ? -1 : invokingState
    self.ruleIndex = ruleIndex
    self.label = label
  }

  /// A labelled-alternative context copied from `ctx` (antlr `CopyFrom`): parent, invoking state,
  /// start and stop, but no children.
  init(copying ctx: ParserRuleContext, label: ContextLabel) {
    self.parent = ctx.parent
    self.invokingState = ctx.invokingState
    self.ruleIndex = ctx.ruleIndex
    self.label = label
    self.start = ctx.start
    self.stop = ctx.stop
  }

  /// The concatenated text of all children (hidden tokens are not part of the tree).
  var text: String {
    var s = ""
    for child in children {
      s += child.text
    }
    return s
  }

  func addChild(_ child: ParserRuleContext) {
    children.append(.rule(child))
  }

  func removeLastChild() {
    if !children.isEmpty {
      children.removeLast()
    }
  }

  /// The first child context of the given rule (the generated typed accessors, e.g. `Member()`).
  func child(rule: Int) -> ParserRuleContext? {
    child(rule: rule, 0)
  }

  /// The `i`-th child context of the given rule (e.g. `Relation(1)`).
  func child(rule: Int, _ i: Int) -> ParserRuleContext? {
    var j = 0
    for child in children {
      if case .rule(let ctx) = child, ctx.ruleIndex == rule {
        if j == i {
          return ctx
        }
        j += 1
      }
    }
    return nil
  }
}

/// A syntax error raised while parsing (antlr `RecognitionException`).
final class RecognitionException {
  enum Kind {
    case noViableAlt(startToken: Token, offendingToken: Token)
    case inputMismatch(offendingToken: Token)
    case failedPredicate(message: String, offendingToken: Token)
  }

  var kind: Kind
  /// The parser state when the exception was created.
  var offendingState: Int
  /// The rule context when the exception was created. Weak: the context keeps its exception
  /// (`ParserRuleContext.exception`), and the tree owns the context while errors are reported.
  weak var ctx: ParserRuleContext?

  init(kind: Kind, offendingState: Int, ctx: ParserRuleContext?) {
    self.kind = kind
    self.offendingState = offendingState
    self.ctx = ctx
  }
}
