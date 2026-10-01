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

// Ported from cel-go parser/unparser_test.go, parser/helper_test.go, parser/macro_test.go and
// parser/unescape_test.go. The TestUnparse table is extracted from the Go source by tools/parsedump.

import Testing

@testable import CEL

extension UnparserTestCase {
  /// Maps the Go source of an unparser option in the table to its Swift equivalent.
  func unparserOptions() -> [UnparserOption] {
    (options ?? []).map { source in
      func ops(_ s: String) -> [String] {
        let inner = s.dropFirst("WrapOnOperators(".count).dropLast()
        return inner.split(separator: ",").map { name -> String in
          switch name.trimmingCharacters(in: " ") {
          case "operators.Divide": return Operators.divide
          case "operators.Greater": return Operators.greater
          case "operators.Less": return Operators.less
          case "operators.LogicalAnd": return Operators.logicalAnd
          case "operators.Multiply": return Operators.multiply
          case "operators.Modulo": return Operators.modulo
          case "operators.LogicalOr": return Operators.logicalOr
          case "operators.In": return Operators.in
          case "operators.GreaterEquals": return Operators.greaterEquals
          case "operators.LessEquals": return Operators.lessEquals
          case "operators.Add": return Operators.add
          case "operators.Subtract": return Operators.subtract
          case "operators.NotEquals": return Operators.notEquals
          case "operators.Equals": return Operators.equals
          case "operators.Conditional": return Operators.conditional
          default: fatalError("unmapped operator \(name)")
          }
        }
      }
      if source.hasPrefix("WrapOnOperators(") {
        return .wrapOnOperators(ops(source))
      }
      if source.hasPrefix("WrapOnColumn("), let n = Int(source.dropFirst(13).dropLast()) {
        return .wrapOnColumn(n)
      }
      if source == "WrapAfterColumnLimit(false)" {
        return .wrapAfterColumnLimit(false)
      }
      fatalError("unmapped unparser option: \(source)")
    }
  }
}

extension StringProtocol {
  fileprivate func trimmingCharacters(in set: String) -> String {
    var s = Substring(self)
    while let f = s.unicodeScalars.first, set.unicodeScalars.contains(f) { s = s.dropFirst() }
    while let l = s.unicodeScalars.last, set.unicodeScalars.contains(l) { s = s.dropLast() }
    return String(s)
  }
}

@Suite struct UnparserTests {
  @Test(arguments: ParserTestTables.shared.unparser)
  func unparse(_ tc: UnparserTestCase) throws {
    let prsr = try Parser(
      .macros(Macro.allMacros), .populateMacroCalls(tc.requiresMacroCalls ?? false),
      .enableOptionalSyntax(true), .enableIdentEscapeSyntax(true))
    let (p, iss) = prsr.parse(TextSource(tc.in))
    #expect(iss.isEmpty, "\(iss.toDisplayString())")
    let out = try Unparser.unparse(p.expr, sourceInfo: p.sourceInfo, options: tc.unparserOptions())
    #expect(out == (tc.out ?? tc.in))
    let (p2, iss2) = prsr.parse(TextSource(out))
    #expect(iss2.isEmpty, "roundtrip failed: \(iss2.toDisplayString())")
    #expect(p.expr == p2.expr, "Roundtrip Parse() differs from original")
  }

  @Test func unparseErrors() {
    let info = SourceInfo(source: nil)
    let null = Expr.literal(id: 0, .null)
    let cases: [(String, Expr, String, [UnparserOption])] = [
      ("empty_expr", .unspecified(id: 0), "unsupported expression", []),
      (
        "bad_args", .call(id: 0, function: "_&&_", args: [.unspecified(id: 0), .unspecified(id: 0)]),
        "unsupported expression", []
      ),
      (
        "bad_index", .call(id: 0, function: "_[_]", args: [.unspecified(id: 0), .unspecified(id: 0)]),
        "unsupported expression", []
      ),
      (
        "wrap_column_zero", null,
        "Invalid unparser option. Wrap column value must be greater than or equal to 1. Got 0 instead",
        [.wrapOnColumn(0)]
      ),
      (
        "wrap_column_negative", null,
        "Invalid unparser option. Wrap column value must be greater than or equal to 1. Got -1 instead",
        [.wrapOnColumn(-1)]
      ),
      (
        "unsupported_operator", null, "Invalid unparser option. Unsupported operator: bogus",
        [.wrapOnOperators(["bogus"])]
      ),
      (
        "unary_operator", null,
        "Invalid unparser option. Unary operators are unsupported: " + Operators.negate,
        [.wrapOnOperators([Operators.negate])]
      ),
    ]
    for (name, expr, want, opts) in cases {
      do {
        let out = try Unparser.unparse(expr, sourceInfo: info, options: opts)
        Issue.record("\(name): got \(out), wanted error \(want)")
      } catch {
        #expect(error.description.contains(want), "\(name): \(error)")
      }
    }
  }
}

@Suite struct ParserHelperTests {
  @Test func exprHelperCopy() throws {
    let src = TextSource(
      "noop([1, 2, 3].map(i, Msg{first: 1 + 2, second: a.b, third: {true: true}}))", description: "")
    let p = try Parser(
      .populateMacroCalls(true),
      .macros([
        Macro.map,
        Macro.global("noop", argCount: 1) {
          (eh: ExprHelper, _: Expr?, args: [Expr]) throws(CELError) -> Expr? in eh.copy(args[0])
        },
      ]))
    let (parsed, errs) = p.parse(src)
    #expect(errs.isEmpty, "\(errs.toDisplayString())")
    // '27' refers to the macro expression that is the sole argument to the noop() macro.
    let macroTarget = try #require(parsed.sourceInfo.macroCall(27))
    #expect(macroTarget != parsed.expr, "Copy() failed to provide unique ids")
  }

  @Test func receiverVarArgMacro() {
    let m = Macro.receiverVarArg(
      "varargs", documentation: ["convert variable argument lists to a list literal"],
      examples: ["varargs(1,2,3) // [1, 2, 3]"]
    ) { (_: ExprHelper, _: Expr?, _: [Expr]) throws(CELError) -> Expr? in nil }
    #expect(m.argCount == 0)
    #expect(m.function == "varargs")
    #expect(m.key == "varargs:*:true")
    #expect(m.isReceiverStyle)
    #expect(m.documentation == ["convert variable argument lists to a list literal"])
    #expect(m.examples == ["varargs(1,2,3) // [1, 2, 3]"])
  }

  @Test(arguments: [
    ("'hello'", "hello", false), ("r'hello'", "hello", false), ("\"\"", "", false),
    (#""\\\"""#, #"\""#, false), (#""\\""#, #"\"#, false), ("'''x''x'''", "x''x", false),
    (#""""x""x""""#, #"x""x"#, false), (#""\303\277""#, "Ã¿", false), (#""\377""#, "ÿ", false),
    (#""☺☺""#, "☺☺", false),
    (
      #""\a\b\f\n\r\t\v\'\"\\\? Legal escapes""#, "\u{07}\u{08}\u{0C}\n\r\t\u{0B}'\"\\? Legal escapes",
      false
    ),
  ])
  func unescapeStrings(input: String, out: String, isBytes: Bool) throws {
    #expect(String(decoding: try unescape(input, isBytes: isBytes), as: UTF8.self) == out)
  }

  @Test(arguments: [
    (#""abc""#, [0x61, 0x62, 0x63]), (#""ÿ""#, [0xc3, 0xbf]), (#""\303\277""#, [0xc3, 0xbf]),
    (#""\377""#, [0xff]), (#""\xff""#, [0xff]), (#""\xc3\xbf""#, [0xc3, 0xbf]),
    (#"'''"Kim\t"'''"#, [0x22, 0x4b, 0x69, 0x6d, 0x09, 0x22]),
  ] as [(String, [UInt8])])
  func unescapeBytes(input: String, out: [UInt8]) throws {
    #expect(try unescape(input, isBytes: true) == out)
  }

  @Test(arguments: [
    (#""\a\b\f\n\r\t\v\'\"\\\? Illegal escape \>""#, "unable to unescape string", false),
    (#""\u00f""#, "unable to unescape string", false),
    (#""\u00fÿ""#, "unable to unescape string", false),
    (#""\u00ff""#, "unable to unescape string", true),
    (#""\U00ff""#, "unable to unescape string", true),
    (#""\26""#, "unable to unescape octal sequence", false),
    (#""\268""#, "unable to unescape octal sequence", false),
    (#""\267\""#, #"found '\' as last character"#, false),
    ("'", "unable to unescape string", false), ("*hello*", "unable to unescape string", false),
    ("r'''hello'", "unable to unescape string", false),
    (#"r"""hello""#, "unable to unescape string", false),
  ])
  func unescapeErrors(input: String, message: String, isBytes: Bool) {
    do {
      _ = try unescape(input, isBytes: isBytes)
      Issue.record("expected error for \(input)")
    } catch {
      #expect(error.message.contains(message))
    }
  }
}
