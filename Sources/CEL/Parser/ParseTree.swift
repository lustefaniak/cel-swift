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

  // Grammar labels. Which ones are used depends on `label`.
  @exclusivity(unchecked) var e: ParserRuleContext?
  @exclusivity(unchecked) var e1: ParserRuleContext?
  @exclusivity(unchecked) var e2: ParserRuleContext?
  @exclusivity(unchecked) var op: Token?
  @exclusivity(unchecked) var opt: Token?
  @exclusivity(unchecked) var leadingDot: Token?
  @exclusivity(unchecked) var sign: Token?
  @exclusivity(unchecked) var tok: Token?
  @exclusivity(unchecked) var open: Token?
  /// Token `id` labels (Ident, GlobalCall, MemberCall, SimpleIdentifier, EscapedIdentifier).
  @exclusivity(unchecked) var idToken: Token?
  /// Select's `id=escapeIdent` label.
  @exclusivity(unchecked) var idContext: ParserRuleContext?
  @exclusivity(unchecked) var args: ParserRuleContext?
  @exclusivity(unchecked) var elems: ParserRuleContext?
  @exclusivity(unchecked) var entries: ParserRuleContext?
  @exclusivity(unchecked) var index: ParserRuleContext?
  @exclusivity(unchecked) var ops: [Token] = []
  @exclusivity(unchecked) var ids: [Token] = []
  @exclusivity(unchecked) var cols: [Token] = []
  /// `e1+=...` in conditionalOr / conditionalAnd, `e+=expr` in exprList.
  @exclusivity(unchecked) var exprs: [ParserRuleContext] = []
  /// `elems+=optExpr` in listInit.
  @exclusivity(unchecked) var elemList: [ParserRuleContext] = []
  @exclusivity(unchecked) var fields: [ParserRuleContext] = []
  @exclusivity(unchecked) var values: [ParserRuleContext] = []
  @exclusivity(unchecked) var keys: [ParserRuleContext] = []

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
