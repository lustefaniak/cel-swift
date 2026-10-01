// Copyright 2019 Google LLC
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

// Ported from cel-go parser/unparser.go.

/// An error raised by the unparser for unsupported expressions or invalid options.
package struct UnparseError: Error, Equatable, CustomStringConvertible {
  package let description: String
}

/// An unparser formatting option (cel-go `UnparserOption`).
package enum UnparserOption: Sendable {
  /// Wraps the output after an operator once the line reaches this column (must be at least 1).
  case wrapOnColumn(Int)
  /// The binary operator functions to wrap on; replaces the defaults `&&` and `||`.
  case wrapOnOperators([String])
  /// Whether to put the newline after the operator (the default) or before it.
  case wrapAfterColumnLimit(Bool)
}

/// Turns an AST back into CEL source (cel-go `parser.Unparse`).
///
/// The output often equals the original source, but formatting may change: string literals are double
/// quoted, bytes literals use octal escapes, doubles use the fewest digits needed, spacing around
/// punctuation is normalized and parentheses are only kept where they affect precedence.
package enum Unparser {
  /// Unparses `expr`, using the macro calls in `sourceInfo` to restore macro syntax.
  package static func unparse(
    _ expr: Expr, sourceInfo: SourceInfo, options: [UnparserOption] = []
  ) throws(UnparseError) -> String {
    var wrapOnColumn = 80
    var wrapAfterColumnLimit = true
    var operatorsToWrapOn: Set<String> = [Operators.logicalAnd, Operators.logicalOr]
    for option in options {
      switch option {
      case .wrapOnColumn(let col):
        if col < 1 {
          throw UnparseError(
            description:
              "Invalid unparser option. Wrap column value must be greater than or equal to 1. Got \(col) instead"
          )
        }
        wrapOnColumn = col
      case .wrapOnOperators(let symbols):
        operatorsToWrapOn = []
        for symbol in symbols {
          if Operators.findReverse(symbol) == nil {
            throw UnparseError(
              description: "Invalid unparser option. Unsupported operator: \(symbol)")
          }
          if Operators.arity(symbol) < 2 {
            throw UnparseError(
              description: "Invalid unparser option. Unary operators are unsupported: \(symbol)")
          }
          operatorsToWrapOn.insert(symbol)
        }
      case .wrapAfterColumnLimit(let wrapAfter):
        wrapAfterColumnLimit = wrapAfter
      }
    }
    var un = Writer(
      info: sourceInfo, wrapOnColumn: wrapOnColumn, operatorsToWrapOn: operatorsToWrapOn,
      wrapAfterColumnLimit: wrapAfterColumnLimit)
    try un.visit(expr)
    return un.str
  }

  /// Quotes a field name with backticks when it is not a plain identifier or is `in`.
  static func maybeQuoteField(_ field: String) -> String {
    if !isIdentifierPart(field) || field == "in" {
      return "`" + field + "`"
    }
    return field
  }

  /// `^[A-Za-z_][0-9A-Za-z_]*$`
  private static func isIdentifierPart(_ s: String) -> Bool {
    var first = true
    for scalar in s.unicodeScalars {
      let v = scalar.value
      let letter = (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) || v == 0x5F
      let digit = v >= 0x30 && v <= 0x39
      if first {
        if !letter { return false }
        first = false
      } else if !(letter || digit) {
        return false
      }
    }
    return !first
  }

  fileprivate struct Writer {
    var str = ""
    /// Byte length of `str`, as Go's strings.Builder.Len().
    var strLen = 0
    let info: SourceInfo
    let wrapOnColumn: Int
    let operatorsToWrapOn: Set<String>
    let wrapAfterColumnLimit: Bool
    var lastWrappedIndex = 0

    init(
      info: SourceInfo, wrapOnColumn: Int, operatorsToWrapOn: Set<String>,
      wrapAfterColumnLimit: Bool
    ) {
      self.info = info
      self.wrapOnColumn = wrapOnColumn
      self.operatorsToWrapOn = operatorsToWrapOn
      self.wrapAfterColumnLimit = wrapAfterColumnLimit
    }

    mutating func write(_ s: String) {
      str += s
      strLen += s.utf8.count
    }

    mutating func visit(_ expr: Expr) throws(UnparseError) {
      if let call = info.macroCall(expr.id) {
        try visit(call)
        return
      }
      switch expr.kind {
      case .call(let c):
        try visitCall(c)
      case .literal(let c):
        visitConst(c)
      case .ident(let name):
        write(name)
      case .list(let l):
        try visitList(l)
      case .map(let m):
        try visitStructMap(m)
      case .select(let s):
        try visitSelectInternal(s.operand, s.testOnly, ".", s.field)
      case .struct(let s):
        try visitStructMsg(s)
      case .unspecified:
        throw UnparseError(description: "unsupported expression")
      case .comprehension:
        throw UnparseError(description: "unsupported expression: \(ExprDebug.toDebugString(expr))")
      }
    }

    mutating func visitCall(_ c: Expr.Call) throws(UnparseError) {
      switch c.function {
      case Operators.conditional:
        try visitCallConditional(c)
      case Operators.optSelect:
        try visitOptSelect(c)
      case Operators.index:
        try visitCallIndex(c, "[")
      case Operators.optIndex:
        try visitCallIndex(c, "[?")
      case Operators.logicalNot, Operators.negate:
        try visitCallUnary(c)
      case Operators.add, Operators.divide, Operators.equals, Operators.greater,
        Operators.greaterEquals, Operators.in, Operators.less, Operators.lessEquals,
        Operators.logicalAnd, Operators.logicalOr, Operators.modulo, Operators.multiply,
        Operators.notEquals, Operators.oldIn, Operators.subtract:
        try visitCallBinary(c)
      default:
        try visitCallFunc(c)
      }
    }

    mutating func visitCallBinary(_ c: Expr.Call) throws(UnparseError) {
      let fun = c.function
      guard c.args.count >= 2 else {
        throw UnparseError(description: "unsupported expression")
      }
      let lhs = c.args[0]
      // add parens if the current operator is lower precedence than the lhs expr operator.
      let lhsParen = Unparser.isComplexOperatorWithRespectTo(fun, lhs)
      let rhs = c.args[1]
      // add parens if the current operator is lower precedence than the rhs expr operator,
      // or the same precedence and the operator is left recursive.
      var rhsParen = Unparser.isComplexOperatorWithRespectTo(fun, rhs)
      if !rhsParen && Unparser.isLeftRecursive(fun) {
        rhsParen = Unparser.isSamePrecedence(fun, rhs)
      }
      try visitMaybeNested(lhs, lhsParen)
      guard let unmangled = Operators.findReverseBinaryOperator(fun) else {
        throw UnparseError(description: "cannot unmangle operator: \(fun)")
      }
      writeOperatorWithWrapping(fun, unmangled)
      try visitMaybeNested(rhs, rhsParen)
    }

    mutating func visitCallConditional(_ c: Expr.Call) throws(UnparseError) {
      guard c.args.count >= 3 else {
        throw UnparseError(description: "unsupported expression")
      }
      // add parens if operand is a conditional itself.
      var nested = Unparser.isSamePrecedence(Operators.conditional, c.args[0]) || Unparser.isComplexOperator(c.args[0])
      try visitMaybeNested(c.args[0], nested)
      writeOperatorWithWrapping(Operators.conditional, "?")
      nested = Unparser.isSamePrecedence(Operators.conditional, c.args[1]) || Unparser.isComplexOperator(c.args[1])
      try visitMaybeNested(c.args[1], nested)
      write(" : ")
      nested = Unparser.isSamePrecedence(Operators.conditional, c.args[2]) || Unparser.isComplexOperator(c.args[2])
      try visitMaybeNested(c.args[2], nested)
    }

    mutating func visitCallFunc(_ c: Expr.Call) throws(UnparseError) {
      if let target = c.target {
        let nested = Unparser.isBinaryOrTernaryOperator(target)
        try visitMaybeNested(target, nested)
        write(".")
      }
      write(c.function)
      write("(")
      for (i, arg) in c.args.enumerated() {
        try visit(arg)
        if i < c.args.count - 1 {
          write(", ")
        }
      }
      write(")")
    }

    mutating func visitCallIndex(_ c: Expr.Call, _ op: String) throws(UnparseError) {
      guard c.args.count >= 2 else {
        throw UnparseError(description: "unsupported expression")
      }
      let nested = Unparser.isBinaryOrTernaryOperator(c.args[0])
      try visitMaybeNested(c.args[0], nested)
      write(op)
      try visit(c.args[1])
      write("]")
    }

    mutating func visitCallUnary(_ c: Expr.Call) throws(UnparseError) {
      guard let unmangled = Operators.findReverse(c.function) else {
        throw UnparseError(description: "cannot unmangle operator: \(c.function)")
      }
      guard let arg = c.args.first else {
        throw UnparseError(description: "unsupported expression")
      }
      write(unmangled)
      try visitMaybeNested(arg, Unparser.isComplexOperator(arg))
    }

    mutating func visitConst(_ c: Constant) {
      switch c {
      case .bool(let v):
        write(v ? "true" : "false")
      case .bytes(let v):
        // bytes constants are surrounded with b"<bytes>"
        write("b\"")
        write(Unparser.bytesToOctets(v))
        write("\"")
      case .double(let v):
        // represent the float using the minimum required digits
        let d = GoFormat.formatFloat(v)
        write(d)
        if !d.contains(".") && !d.contains("e") && !d.contains("E") {
          write(".0")
        }
      case .int(let v):
        write(String(v))
      case .null:
        write("null")
      case .string(let v):
        // strings will be double quoted with quotes escaped.
        write(GoFormat.quote(v))
      case .uint(let v):
        // uint literals have a 'u' suffix.
        write(String(v))
        write("u")
      }
    }

    mutating func visitList(_ l: Expr.List) throws(UnparseError) {
      let optIndices = Set(l.optionalIndices.map { Int($0) })
      write("[")
      for (i, elem) in l.elements.enumerated() {
        if optIndices.contains(i) {
          write("?")
        }
        try visit(elem)
        if i < l.elements.count - 1 {
          write(", ")
        }
      }
      write("]")
    }

    mutating func visitOptSelect(_ c: Expr.Call) throws(UnparseError) {
      guard c.args.count >= 2, case .literal(.string(let field)) = c.args[1].kind else {
        throw UnparseError(description: "unsupported expression")
      }
      try visitSelectInternal(c.args[0], false, ".?", field)
    }

    mutating func visitSelectInternal(_ operand: Expr, _ testOnly: Bool, _ op: String, _ field: String)
      throws(UnparseError)
    {
      // handle the case when the select expression was generated by the has() macro.
      if testOnly {
        write("has(")
      }
      let nested = !testOnly && Unparser.isBinaryOrTernaryOperator(operand)
      try visitMaybeNested(operand, nested)
      write(op)
      write(Unparser.maybeQuoteField(field))
      if testOnly {
        write(")")
      }
    }

    mutating func visitStructMsg(_ m: Expr.Struct) throws(UnparseError) {
      write(m.typeName)
      write("{")
      for (i, field) in m.fields.enumerated() {
        if field.isOptional {
          write("?")
        }
        write(Unparser.maybeQuoteField(field.name))
        write(": ")
        try visit(field.value)
        if i < m.fields.count - 1 {
          write(", ")
        }
      }
      write("}")
    }

    mutating func visitStructMap(_ m: Expr.Map) throws(UnparseError) {
      write("{")
      for (i, entry) in m.entries.enumerated() {
        if entry.isOptional {
          write("?")
        }
        try visit(entry.key)
        write(": ")
        try visit(entry.value)
        if i < m.entries.count - 1 {
          write(", ")
        }
      }
      write("}")
    }

    mutating func visitMaybeNested(_ expr: Expr, _ nested: Bool) throws(UnparseError) {
      if nested {
        write("(")
      }
      try visit(expr)
      if nested {
        write(")")
      }
    }

    /// Inserts a newline for operators configured for wrapping once the column limit is reached.
    mutating func writeOperatorWithWrapping(_ fun: String, _ unmangled: String) {
      let lineLength = strLen - lastWrappedIndex + fun.utf8.count
      if operatorsToWrapOn.contains(fun) && lineLength >= wrapOnColumn {
        lastWrappedIndex = strLen
        // wrapAfterColumnLimit dictates whether the newline goes before or after the operator.
        if wrapAfterColumnLimit {
          write(" ")
          write(unmangled)
          write("\n")
        } else {
          write("\n")
          write(unmangled)
          write(" ")
        }
        return
      }
      write(" ")
      write(unmangled)
      write(" ")
    }
  }

  /// Whether the parser resolves the call left-recursively, which changes how parentheses affect
  /// the order of operations.
  fileprivate static func isLeftRecursive(_ op: String) -> Bool {
    op != Operators.logicalAnd && op != Operators.logicalOr
  }

  /// Whether `expr` is a call whose operator has the same precedence as `op`.
  fileprivate static func isSamePrecedence(_ op: String, _ expr: Expr) -> Bool {
    guard let c = expr.asCall else {
      return false
    }
    return Operators.precedence(op) == Operators.precedence(c.function)
  }

  /// Whether `op` binds looser than the operator of the call `expr`.
  fileprivate static func isLowerPrecedence(_ op: String, _ expr: Expr) -> Bool {
    let other = expr.asCall?.function ?? ""
    return Operators.precedence(op) < Operators.precedence(other)
  }

  /// Whether `expr` is a call with two or more arguments.
  fileprivate static func isComplexOperator(_ expr: Expr) -> Bool {
    if let c = expr.asCall, c.args.count >= 2 {
      return true
    }
    return false
  }

  /// Whether `expr` is a complex operation with lower precedence than `op`.
  fileprivate static func isComplexOperatorWithRespectTo(_ op: String, _ expr: Expr) -> Bool {
    guard let c = expr.asCall, c.args.count >= 2 else {
      return false
    }
    return isLowerPrecedence(op, expr)
  }

  /// Whether `expr` is a binary or ternary operator call.
  fileprivate static func isBinaryOrTernaryOperator(_ expr: Expr) -> Bool {
    guard let c = expr.asCall, c.args.count >= 2 else {
      return false
    }
    let isBinaryOp = Operators.findReverseBinaryOperator(c.function) != nil
    return isBinaryOp || isSamePrecedence(Operators.conditional, expr)
  }

  /// Three-digit octal escapes for every byte.
  fileprivate static func bytesToOctets(_ bytes: [UInt8]) -> String {
    var out = ""
    for b in bytes {
      let o = String(b, radix: 8)
      out += "\\" + String(repeating: "0", count: 3 - o.utf8.count) + o
    }
    return out
  }
}
