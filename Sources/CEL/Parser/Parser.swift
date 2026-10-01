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

// Ported from cel-go parser/parser.go.

/// Parses CEL expressions into ASTs, expanding macros (cel-go `parser.Parser`).
package struct Parser: Sendable {
  package let options: ParserOptions
  /// The ANTLR prediction DFAs, warmed by every parse and shared by copies of this parser (antlr4-go
  /// keeps them in a process-wide static). Thread-safe.
  let predictionCache: PredictionCache

  /// Creates a parser; options are applied in order on top of cel-go's defaults.
  package init(_ options: ParserOption...) throws(ParserOptionError) {
    try self.init(options: options)
  }

  /// Creates a parser; options are applied in order on top of cel-go's defaults.
  package init(options: [ParserOption]) throws(ParserOptionError) {
    try self.init(options: options, sharingPredictionCacheWith: nil)
  }

  /// Creates a parser that shares the prediction cache of `other` when given. The cache depends only
  /// on the grammar, so parsers with different options may share it.
  package init(options: [ParserOption], sharingPredictionCacheWith other: Parser?) throws(ParserOptionError) {
    self.options = try ParserOptions(options)
    self.predictionCache = other?.predictionCache ?? PredictionCache(atn: celParserATN)
  }

  /// Parses `source`. The AST is always returned; it is only meaningful when `errors` is empty.
  package func parse(_ source: any Source) -> (ast: AST, errors: CELErrors) {
    var errors = CELErrors(source: source)
    let accu = options.enableHiddenAccumulatorName ? Macro.hiddenAccumulatorName : Macro.accumulatorName
    let helper = ParserHelper(source: source, factory: ExprFactory(accumulatorName: accu))
    let scalars = source.scalars
    var out: Expr?
    if scalars.count > options.expressionSizeCodePointLimit {
      let visitor = ParseVisitor(
        options: options, helper: helper, errors: errors, predictionCache: predictionCache)
      out = visitor.reportError(
        .location(.none),
        "expression code point size exceeds limit: size: \(scalars.count), limit \(options.expressionSizeCodePointLimit)"
      )
      errors = visitor.errors
    } else {
      let visitor = ParseVisitor(
        options: options, helper: helper, errors: errors, predictionCache: predictionCache)
      let units = min(LargeStack.nestingUnits(scalars), Parser.maxNestingUnits(options))
      if let stackSize = LargeStack.requiredStackSize(units: units) {
        LargeStack.run(stackSize: stackSize) {
          out = visitor.parse(scalars)
        }
      } else {
        out = visitor.parse(scalars)
      }
      errors = visitor.errors
    }
    return (AST(expr: out ?? .unspecified(id: 0), sourceInfo: helper.sourceInfo), errors)
  }

  /// The most nesting units the recursion limits allow: parser rules and the visitor are both bounded
  /// by the maximum recursion depth.
  static func maxNestingUnits(_ options: ParserOptions) -> Int {
    let depth = options.maxRecursionDepth
    return depth > Int.max / 8 ? Int.max : depth * 4
  }

  /// Parses a plain text expression with the description `<input>`.
  package func parse(_ text: String) -> (ast: AST, errors: CELErrors) {
    parse(TextSource(text))
  }
}

/// Identifiers that are not legal variable names. They are excluded after parsing since they are
/// valid field names for protos.
private let reservedIds: Set<String> = [
  "as", "break", "const", "continue", "else", "false", "for", "function", "if", "import", "in",
  "let", "loop", "package", "namespace", "null", "return", "true", "var", "void", "while",
]

/// Builds the AST from the parse tree (cel-go's `parser` visitor).
final class ParseVisitor {
  let options: ParserOptions
  let helper: ParserHelper
  var errors: CELErrors
  private let predictionCache: PredictionCache
  private var recursionDepth = 0

  init(options: ParserOptions, helper: ParserHelper, errors: CELErrors, predictionCache: PredictionCache) {
    self.options = options
    self.helper = helper
    self.errors = errors
    self.predictionCache = predictionCache
  }

  func parse(_ input: [Unicode.Scalar]) -> Expr? {
    let runtime = ParserRuntime(
      input: input, sourceInfo: helper.sourceInfo, errors: errors,
      maxRecursionDepth: options.maxRecursionDepth, errorReportingLimit: options.errorReportingLimit,
      errorRecoveryLimit: options.errorRecoveryLimit,
      lookaheadLimit: options.errorRecoveryTokenLookaheadLimit,
      cache: predictionCache)
    let tree: ParserRuleContext
    do {
      tree = try runtime.start()
      errors = runtime.errors
    } catch {
      errors = runtime.errors
      handleAbort(error)
      return nil
    }
    do {
      return try visit(tree)
    } catch {
      handleAbort(error)
      return nil
    }
  }

  /// cel-go recovers its parser panics: recursion and lookahead limits become internal errors; the
  /// error reporting and recovery limits were already reported.
  private func handleAbort(_ error: any Error) {
    guard let abort = error as? ParseAbort else {
      return
    }
    switch abort {
    case .lookahead(let msg), .recursion(let msg):
      errors.reportError(exprID: 0, at: .none, msg)
    case .tooManyErrors, .recoveryLimit:
      break
    }
  }

  // MARK: - Visitor

  func visit(_ tree: ParserRuleContext?) throws -> Expr {
    let t = unnest(tree)
    guard let t else {
      return unknownParseElement(nil)
    }
    switch t.label {
    case .start:
      return try visitStart(t)
    case .expr:
      try checkAndIncrementRecursionDepth()
      let out = try visitExpr(t)
      decrementRecursionDepth()
      return out
    case .conditionalAnd:
      return try visitConditionalAnd(t)
    case .conditionalOr:
      return try visitConditionalOr(t)
    case .relation:
      try checkAndIncrementRecursionDepth()
      let out = try visitRelation(t)
      decrementRecursionDepth()
      return out
    case .calc:
      try checkAndIncrementRecursionDepth()
      let out = try visitCalc(t)
      decrementRecursionDepth()
      return out
    case .logicalNot:
      return try visitLogicalNot(t)
    case .ident:
      return visitIdent(t)
    case .globalCall:
      return try visitGlobalCall(t)
    case .select:
      try checkAndIncrementRecursionDepth()
      let out = try visitSelect(t)
      decrementRecursionDepth()
      return out
    case .memberCall:
      try checkAndIncrementRecursionDepth()
      let out = try visitMemberCall(t)
      decrementRecursionDepth()
      return out
    case .negate:
      return try visitNegate(t)
    case .index:
      try checkAndIncrementRecursionDepth()
      let out = try visitIndex(t)
      decrementRecursionDepth()
      return out
    case .unary:
      return helper.newLiteral(.context(t), .string("<<error>>"))
    case .createList:
      return try visitCreateList(t)
    case .createMessage:
      return try visitCreateMessage(t)
    case .createStruct:
      return try visitCreateStruct(t)
    case .int:
      return visitInt(t)
    case .uint:
      return visitUint(t)
    case .double:
      return visitDouble(t)
    case .string:
      return visitString(t)
    case .bytes:
      return visitBytes(t)
    case .boolFalse:
      return helper.newLiteral(.context(t), .bool(false))
    case .boolTrue:
      return helper.newLiteral(.context(t), .bool(true))
    case .null:
      return helper.newLiteral(.context(t), .null)
    default:
      return unknownParseElement(t)
    }
  }

  /// Reports at least one error if the visitor reaches an unknown parse element, which typically
  /// happens after a syntax error elsewhere.
  private func unknownParseElement(_ t: ParserRuleContext?) -> Expr {
    if errors.errors.isEmpty {
      let txt = t.map { "<<\($0.label.goTypeName)>>" } ?? "<<nil>>"
      return reportError(.location(.none), "unknown parse element encountered: \(txt)")
    }
    return helper.newExpr(.location(.none))
  }

  private func visitStart(_ ctx: ParserRuleContext) throws -> Expr {
    try visit(ctx.child(rule: CELRule.expr))
  }

  private func visitExpr(_ ctx: ParserRuleContext) throws -> Expr {
    let result = try visit(ctx.e)
    guard let op = ctx.op else {
      return result
    }
    let opID = helper.id(.token(op))
    let ifTrue = try visit(ctx.e1)
    let ifFalse = try visit(ctx.e2)
    return try globalCallOrMacro(opID, Operators.conditional, [result, ifTrue, ifFalse])
  }

  private func visitConditionalOr(_ ctx: ParserRuleContext) throws -> Expr {
    let result = try visit(ctx.e)
    var l = newLogicManager(Operators.logicalOr, result)
    let rest = ctx.exprs
    for (i, op) in ctx.ops.enumerated() {
      if i >= rest.count {
        return reportError(.context(ctx), "unexpected character, wanted '||'")
      }
      let next = try visit(rest[i])
      let opID = helper.id(.token(op))
      l.addTerm(opID, next)
    }
    return l.toExpr()
  }

  private func visitConditionalAnd(_ ctx: ParserRuleContext) throws -> Expr {
    let result = try visit(ctx.e)
    var l = newLogicManager(Operators.logicalAnd, result)
    let rest = ctx.exprs
    for (i, op) in ctx.ops.enumerated() {
      if i >= rest.count {
        return reportError(.context(ctx), "unexpected character, wanted '&&'")
      }
      let next = try visit(rest[i])
      let opID = helper.id(.token(op))
      l.addTerm(opID, next)
    }
    return l.toExpr()
  }

  private func visitRelation(_ ctx: ParserRuleContext) throws -> Expr {
    let opText = ctx.op?.text ?? ""
    if let op = Operators.find(opText) {
      let lhs = try visit(ctx.child(rule: CELRule.relation, 0))
      let opID = helper.id(.token(ctx.op))
      let rhs = try visit(ctx.child(rule: CELRule.relation, 1))
      return try globalCallOrMacro(opID, op, [lhs, rhs])
    }
    return reportError(.context(ctx), "operator not found")
  }

  private func visitCalc(_ ctx: ParserRuleContext) throws -> Expr {
    let opText = ctx.op?.text ?? ""
    if let op = Operators.find(opText) {
      let lhs = try visit(ctx.child(rule: CELRule.calc, 0))
      let opID = helper.id(.token(ctx.op))
      let rhs = try visit(ctx.child(rule: CELRule.calc, 1))
      return try globalCallOrMacro(opID, op, [lhs, rhs])
    }
    return reportError(.context(ctx), "operator not found")
  }

  private func visitLogicalNot(_ ctx: ParserRuleContext) throws -> Expr {
    if ctx.ops.count % 2 == 0 {
      return try visit(ctx.child(rule: CELRule.member))
    }
    let opID = helper.id(.token(ctx.ops[0]))
    let target = try visit(ctx.child(rule: CELRule.member))
    return try globalCallOrMacro(opID, Operators.logicalNot, [target])
  }

  private func visitNegate(_ ctx: ParserRuleContext) throws -> Expr {
    if ctx.ops.count % 2 == 0 {
      return try visit(ctx.child(rule: CELRule.member))
    }
    let opID = helper.id(.token(ctx.ops[0]))
    let target = try visit(ctx.child(rule: CELRule.member))
    return try globalCallOrMacro(opID, Operators.negate, [target])
  }

  private func visitSelect(_ ctx: ParserRuleContext) throws -> Expr {
    let operand = try visit(ctx.child(rule: CELRule.member))
    // Handle the error case where no valid identifier is specified.
    guard let idCtx = ctx.idContext, let op = ctx.op else {
      return helper.newExpr(.context(ctx))
    }
    var id = ""
    do {
      id = try normalizeIdent(idCtx)
    } catch {
      _ = reportError(.context(idCtx), error.message)
    }
    if ctx.opt != nil {
      if !options.enableOptionalSyntax {
        return reportError(.token(op), "unsupported syntax '.?'")
      }
      let field = helper.newLiteral(.context(idCtx), .string(id))
      return helper.newGlobalCall(.token(op), Operators.optSelect, [operand, field])
    }
    return helper.newSelect(.token(op), operand, id)
  }

  private func visitMemberCall(_ ctx: ParserRuleContext) throws -> Expr {
    let operand = try visit(ctx.child(rule: CELRule.member))
    // Handle the error case where no valid identifier is specified.
    guard let idToken = ctx.idToken else {
      return helper.newExpr(.context(ctx))
    }
    let id = idToken.text
    let opID = helper.id(.token(ctx.open))
    let args = try visitExprList(ctx.args)
    return try receiverCallOrMacro(opID, id, operand, args)
  }

  private func visitIndex(_ ctx: ParserRuleContext) throws -> Expr {
    let target = try visit(ctx.child(rule: CELRule.member))
    // Handle the error case where no valid identifier is specified.
    guard let op = ctx.op else {
      return helper.newExpr(.context(ctx))
    }
    let opID = helper.id(.token(op))
    let index = try visit(ctx.index)
    var operatorName = Operators.index
    if ctx.opt != nil {
      if !options.enableOptionalSyntax {
        return reportError(.token(op), "unsupported syntax '[?'")
      }
      operatorName = Operators.optIndex
    }
    return try globalCallOrMacro(opID, operatorName, [target, index])
  }

  private func visitCreateMessage(_ ctx: ParserRuleContext) throws -> Expr {
    var messageName = ctx.ids.map(\.text).joined(separator: ".")
    if ctx.leadingDot != nil {
      messageName = "." + messageName
    }
    let objID = helper.id(.token(ctx.op))
    let entries = try visitFieldInitializerList(ctx.entries)
    return helper.newObject(.id(objID), messageName, entries)
  }

  private func visitFieldInitializerList(_ ctx: ParserRuleContext?) throws -> [Expr.StructField] {
    guard let ctx, !ctx.fields.isEmpty else {
      // This is the result of a syntax error handled elsewhere, return empty.
      return []
    }
    var result: [Expr.StructField] = []
    let cols = ctx.cols
    let vals = ctx.values
    for (i, f) in ctx.fields.enumerated() {
      if i >= cols.count || i >= vals.count {
        // This is the result of a syntax error detected elsewhere.
        return []
      }
      let initID = helper.id(.token(cols[i]))
      let optional = f.opt != nil
      if !options.enableOptionalSyntax && optional {
        _ = reportError(.context(f), "unsupported syntax '?'")
        continue
      }
      // The field may be empty due to a prior error.
      let fieldName: String
      do {
        fieldName = try normalizeIdent(f.child(rule: CELRule.escapeIdent))
      } catch {
        _ = reportError(.context(ctx), error.message)
        continue
      }
      let value = try visit(vals[i])
      result.append(helper.newObjectField(initID, fieldName, value, optional))
    }
    return result
  }

  private func visitIdent(_ ctx: ParserRuleContext) -> Expr {
    var identName = ctx.leadingDot != nil ? "." : ""
    // Handle the error case where no valid identifier is specified.
    guard let idToken = ctx.idToken else {
      return helper.newExpr(.context(ctx))
    }
    // Handle reserved identifiers.
    let id = idToken.text
    if reservedIds.contains(id) {
      return reportError(.context(ctx), "reserved identifier: \(id)")
    }
    identName += id
    return helper.newIdent(.token(idToken), identName)
  }

  private func visitGlobalCall(_ ctx: ParserRuleContext) throws -> Expr {
    var identName = ctx.leadingDot != nil ? "." : ""
    // Handle the error case where no valid identifier is specified.
    guard let idToken = ctx.idToken else {
      return helper.newExpr(.context(ctx))
    }
    // Handle reserved identifiers.
    let id = idToken.text
    if reservedIds.contains(id) {
      return reportError(.context(ctx), "reserved identifier: \(id)")
    }
    identName += id
    let opID = helper.id(.token(ctx.op))
    return try globalCallOrMacro(opID, identName, try visitExprList(ctx.args))
  }

  private func visitCreateList(_ ctx: ParserRuleContext) throws -> Expr {
    let listID = helper.id(.token(ctx.op))
    let (elems, optionals) = try visitListInit(ctx.elems)
    return helper.newList(.id(listID), elems, optionals)
  }

  private func visitCreateStruct(_ ctx: ParserRuleContext) throws -> Expr {
    let structID = helper.id(.token(ctx.op))
    var entries: [Expr.MapEntry] = []
    if let e = ctx.entries {
      entries = try visitMapInitializerList(e)
    }
    return helper.newMap(.id(structID), entries)
  }

  private func visitMapInitializerList(_ ctx: ParserRuleContext) throws -> [Expr.MapEntry] {
    if ctx.keys.isEmpty {
      // This is the result of a syntax error handled elsewhere, return empty.
      return []
    }
    var result: [Expr.MapEntry] = []
    let keys = ctx.keys
    let vals = ctx.values
    for (i, col) in ctx.cols.enumerated() {
      let colID = helper.id(.token(col))
      if i >= keys.count || i >= vals.count {
        // This is the result of a syntax error detected elsewhere.
        return []
      }
      let optKey = keys[i]
      let optional = optKey.opt != nil
      if !options.enableOptionalSyntax && optional {
        _ = reportError(.context(optKey), "unsupported syntax '?'")
        continue
      }
      let key = try visit(optKey.e)
      let value = try visit(vals[i])
      result.append(helper.newMapEntry(colID, key, value, optional))
    }
    return result
  }

  private func visitInt(_ ctx: ParserRuleContext) -> Expr {
    guard let tok = ctx.tok else {
      return helper.newExpr(.context(ctx))
    }
    var text = Substring(tok.text)
    var radix = 10
    if text.hasPrefix("0x") {
      radix = 16
      text = text.dropFirst(2)
    }
    var full = String(text)
    if let sign = ctx.sign {
      full = sign.text + full
    }
    guard let i = Int64(full, radix: radix) else {
      return reportError(.context(ctx), "invalid int literal")
    }
    return helper.newLiteral(.context(ctx), .int(i))
  }

  private func visitUint(_ ctx: ParserRuleContext) -> Expr {
    guard let tok = ctx.tok else {
      return helper.newExpr(.context(ctx))
    }
    // trim the 'u' designator included in the uint literal.
    var text = Substring(tok.text).dropLast()
    var radix = 10
    if text.hasPrefix("0x") {
      radix = 16
      text = text.dropFirst(2)
    }
    guard let i = UInt64(String(text), radix: radix) else {
      return reportError(.context(ctx), "invalid uint literal")
    }
    return helper.newLiteral(.context(ctx), .uint(i))
  }

  private func visitDouble(_ ctx: ParserRuleContext) -> Expr {
    guard let tok = ctx.tok else {
      return helper.newExpr(.context(ctx))
    }
    var txt = tok.text
    if let sign = ctx.sign {
      txt = sign.text + txt
    }
    guard let f = Double(txt), f.isFinite else {
      return reportError(.context(ctx), "invalid double literal")
    }
    return helper.newLiteral(.context(ctx), .double(f))
  }

  private func visitString(_ ctx: ParserRuleContext) -> Expr {
    let text = ctx.tok?.text ?? ""
    let bytes = unquote(ctx, text, isBytes: false)
    return helper.newLiteral(.context(ctx), .string(String(decoding: bytes, as: UTF8.self)))
  }

  private func visitBytes(_ ctx: ParserRuleContext) -> Expr {
    let text = String((ctx.tok?.text ?? "").unicodeScalars.dropFirst())
    return helper.newLiteral(.context(ctx), .bytes(unquote(ctx, text, isBytes: true)))
  }

  private func visitExprList(_ ctx: ParserRuleContext?) throws -> [Expr] {
    guard let ctx else {
      return []
    }
    return try ctx.exprs.map { try visit($0) }
  }

  private func visitListInit(_ ctx: ParserRuleContext?) throws -> ([Expr], [Int32]) {
    guard let ctx else {
      return ([], [])
    }
    var result: [Expr] = []
    var optionals: [Int32] = []
    for (i, e) in ctx.elemList.enumerated() {
      let ex = try visit(e.e)
      result.append(ex)
      if let opt = e.opt {
        if !options.enableOptionalSyntax {
          _ = reportError(.token(opt), "unsupported syntax '?'")
          continue
        }
        optionals.append(Int32(i))
      }
    }
    return (result, optionals)
  }

  private func unquote(_ ctx: ParserRuleContext, _ value: String, isBytes: Bool) -> [UInt8] {
    do {
      return try unescape(value, isBytes: isBytes)
    } catch {
      _ = reportError(.context(ctx), error.message)
      return Array(value.utf8)
    }
  }

  private func normalizeIdent(_ ctx: ParserRuleContext?) throws(UnescapeError) -> String {
    guard let ctx else {
      throw UnescapeError(message: "unsupported ident kind")
    }
    switch ctx.label {
    case .simpleIdentifier:
      return ctx.idToken?.text ?? ""
    case .escapedIdentifier:
      if !options.enableIdentEscapeSyntax {
        throw UnescapeError(message: "unsupported syntax: '`'")
      }
      let text = ctx.idToken?.text ?? ""
      if text.utf8.count <= 2 {
        throw UnescapeError(message: "invalid escaped identifier: underflow")
      }
      return String(text.unicodeScalars.dropFirst().dropLast())
    default:
      throw UnescapeError(message: "unsupported ident kind")
    }
  }

  private func newLogicManager(_ function: String, _ term: Expr) -> LogicManager {
    LogicManager(function: function, term: term, variadic: options.enableVariadicOperatorASTs)
  }

  @discardableResult
  func reportError(_ ctx: IDSource, _ message: String) -> Expr {
    let err = helper.newExpr(ctx)
    let location: Location
    switch ctx {
    case .location(let l):
      location = l
    case .token, .context:
      location = helper.location(err.id)
    default:
      location = .none
    }
    errors.reportError(exprID: err.id, at: location, message)
    return err
  }

  private func globalCallOrMacro(_ exprID: Int64, _ function: String, _ args: [Expr]) throws -> Expr {
    if let expr = try expandMacro(exprID, function, nil, args) {
      return expr
    }
    return helper.newGlobalCall(.id(exprID), function, args)
  }

  private func receiverCallOrMacro(
    _ exprID: Int64, _ function: String, _ target: Expr, _ args: [Expr]
  ) throws -> Expr {
    if let expr = try expandMacro(exprID, function, target, args) {
      return expr
    }
    return helper.newReceiverCall(.id(exprID), function, target, args)
  }

  private func expandMacro(_ exprID: Int64, _ function: String, _ target: Expr?, _ args: [Expr])
    throws -> Expr?
  {
    let isReceiver = target != nil
    guard
      let macro = options.macros[Macro.key(function, args.count, receiverStyle: isReceiver)]
        ?? options.macros[Macro.varArgKey(function, receiverStyle: isReceiver)]
    else {
      return nil
    }
    if helper.expressionCount > options.maxExpressionNodeCount {
      let loc = helper.location(exprID)
      helper.deleteID(exprID)
      return reportError(
        .location(loc),
        "expression count exceeds limit of \(options.maxExpressionNodeCount) while expanding macro '\(function)'"
      )
    }
    let eh = ExprHelper(helper: helper, callID: exprID)
    let expanded: Expr?
    var expansionError: CELError? = nil
    do {
      expanded = try macro.expander(eh, target, args)
    } catch {
      expanded = nil
      expansionError = error
    }
    if helper.expressionCount > options.maxExpressionNodeCount {
      let loc = helper.location(exprID)
      helper.deleteID(exprID)
      return reportError(
        .location(loc),
        "expression count exceeds limit of \(options.maxExpressionNodeCount) while expanding macro '\(function)'"
      )
    }
    // An error indicates that the macro was matched, but the arguments were not well-formed.
    if let expansionError {
      let loc = expansionError.location
      helper.deleteID(exprID)
      return reportError(.location(loc), expansionError.message)
    }
    // A nil value from the macro indicates that the macro implementation decided that
    // an expansion should not be performed.
    guard let expr = expanded else {
      return nil
    }
    if options.populateMacroCalls {
      helper.addMacroCall(expr.id, function, target, args)
    }
    helper.deleteID(exprID)
    return expr
  }

  private func checkAndIncrementRecursionDepth() throws {
    recursionDepth += 1
    if recursionDepth > options.maxRecursionDepth {
      throw ParseAbort.recursion("max recursion depth exceeded")
    }
  }

  private func decrementRecursionDepth() {
    recursionDepth -= 1
  }

  /// Walks down the left-hand side of the parse tree to the first compound node or leaf.
  private func unnest(_ tree: ParserRuleContext?) -> ParserRuleContext? {
    var tree = tree
    while let t = tree {
      switch t.label {
      case .expr:
        // conditionalOr op='?' conditionalOr : expr
        if t.op != nil {
          return t
        }
        tree = t.e
      case .conditionalOr, .conditionalAnd:
        // conditionalAnd (ops=|| conditionalAnd)*
        if !t.ops.isEmpty {
          return t
        }
        tree = t.e
      case .relation:
        // relation op relation
        if t.op != nil {
          return t
        }
        tree = t.child(rule: CELRule.calc)
      case .calc:
        // calc op calc
        if t.op != nil {
          return t
        }
        tree = t.child(rule: CELRule.unary)
      case .memberExpr:
        tree = t.child(rule: CELRule.member)
      case .primaryExpr:
        tree = t.child(rule: CELRule.primary)
      case .nested:
        tree = t.e
      case .constantLiteral:
        tree = t.child(rule: CELRule.literal)
      default:
        return t
      }
    }
    return tree
  }
}
