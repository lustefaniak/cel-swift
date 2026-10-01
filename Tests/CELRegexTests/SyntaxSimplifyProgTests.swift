// Copyright 2011 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// Port of Go's regexp/syntax/simplify_test.go and regexp/syntax/prog_test.go.

import Testing

@testable import CELRegex

struct SimplifyTest: Sendable, CustomTestStringConvertible {
  var regexp: String
  var simple: String
  init(_ regexp: String, _ simple: String) {
    self.regexp = regexp
    self.simple = simple
  }
  var testDescription: String { regexp }
}

private let simplifyTests: [SimplifyTest] = [
  // Already-simple constructs
  .init(#"a"#, #"a"#),
  .init(#"ab"#, #"ab"#),
  .init(#"a|b"#, #"[ab]"#),
  .init(#"ab|cd"#, #"ab|cd"#),
  .init(#"(ab)*"#, #"(ab)*"#),
  .init(#"(ab)+"#, #"(ab)+"#),
  .init(#"(ab)?"#, #"(ab)?"#),
  .init(#"."#, #"(?s:.)"#),
  .init(#"^"#, #"(?m:^)"#),
  .init(#"$"#, #"(?m:$)"#),
  .init(#"[ac]"#, #"[ac]"#),
  .init(#"[^ac]"#, #"[^ac]"#),

  // Posix character classes
  .init(#"[[:alnum:]]"#, #"[0-9A-Za-z]"#),
  .init(#"[[:alpha:]]"#, #"[A-Za-z]"#),
  .init(#"[[:blank:]]"#, #"[\t ]"#),
  .init(#"[[:cntrl:]]"#, #"[\x00-\x1f\x7f]"#),
  .init(#"[[:digit:]]"#, #"[0-9]"#),
  .init(#"[[:graph:]]"#, #"[!-~]"#),
  .init(#"[[:lower:]]"#, #"[a-z]"#),
  .init(#"[[:print:]]"#, #"[ -~]"#),
  .init(#"[[:punct:]]"#, "[!-/:-@\\[-`\\{-~]"),
  .init(#"[[:space:]]"#, #"[\t-\r ]"#),
  .init(#"[[:upper:]]"#, #"[A-Z]"#),
  .init(#"[[:xdigit:]]"#, #"[0-9A-Fa-f]"#),

  // Perl character classes
  .init(#"\d"#, #"[0-9]"#),
  .init(#"\s"#, #"[\t\n\f\r ]"#),
  .init(#"\w"#, #"[0-9A-Z_a-z]"#),
  .init(#"\D"#, #"[^0-9]"#),
  .init(#"\S"#, #"[^\t\n\f\r ]"#),
  .init(#"\W"#, #"[^0-9A-Z_a-z]"#),
  .init(#"[\d]"#, #"[0-9]"#),
  .init(#"[\s]"#, #"[\t\n\f\r ]"#),
  .init(#"[\w]"#, #"[0-9A-Z_a-z]"#),
  .init(#"[\D]"#, #"[^0-9]"#),
  .init(#"[\S]"#, #"[^\t\n\f\r ]"#),
  .init(#"[\W]"#, #"[^0-9A-Z_a-z]"#),

  // Posix repetitions
  .init(#"a{1}"#, #"a"#),
  .init(#"a{2}"#, #"aa"#),
  .init(#"a{5}"#, #"aaaaa"#),
  .init(#"a{0,1}"#, #"a?"#),
  // The next three are illegible because Simplify inserts (?:)
  // parens instead of () parens to avoid creating extra
  // captured subexpressions. The comments show a version with fewer parens.
  .init(#"(a){0,2}"#, #"(?:(a)(a)?)?"#),  //       (aa?)?
  .init(#"(a){0,4}"#, #"(?:(a)(?:(a)(?:(a)(a)?)?)?)?"#),  //   (a(a(aa?)?)?)?
  .init(#"(a){2,6}"#, #"(a)(a)(?:(a)(?:(a)(?:(a)(a)?)?)?)?"#),  // aa(a(a(aa?)?)?)?
  .init(#"a{0,2}"#, #"(?:aa?)?"#),  //       (aa?)?
  .init(#"a{0,4}"#, #"(?:a(?:a(?:aa?)?)?)?"#),  //   (a(a(aa?)?)?)?
  .init(#"a{2,6}"#, #"aa(?:a(?:a(?:aa?)?)?)?"#),  // aa(a(a(aa?)?)?)?
  .init(#"a{0,}"#, #"a*"#),
  .init(#"a{1,}"#, #"a+"#),
  .init(#"a{2,}"#, #"aa+"#),
  .init(#"a{5,}"#, #"aaaaa+"#),

  // Test that operators simplify their arguments.
  .init(#"(?:a{1,}){1,}"#, #"a+"#),
  .init(#"(a{1,}b{1,})"#, #"(a+b+)"#),
  .init(#"a{1,}|b{1,}"#, #"a+|b+"#),
  .init(#"(?:a{1,})*"#, #"(?:a+)*"#),
  .init(#"(?:a{1,})+"#, #"a+"#),
  .init(#"(?:a{1,})?"#, #"(?:a+)?"#),
  .init(#""#, #"(?:)"#),
  .init(#"a{0}"#, #"(?:)"#),

  // Character class simplification
  .init(#"[ab]"#, #"[ab]"#),
  .init(#"[abc]"#, #"[a-c]"#),
  .init(#"[a-za-za-z]"#, #"[a-z]"#),
  .init(#"[A-Za-zA-Za-z]"#, #"[A-Za-z]"#),
  .init(#"[ABCDEFGH]"#, #"[A-H]"#),
  .init(#"[AB-CD-EF-GH]"#, #"[A-H]"#),
  .init(#"[W-ZP-XE-R]"#, #"[E-Z]"#),
  .init(#"[a-ee-gg-m]"#, #"[a-m]"#),
  .init(#"[a-ea-ha-m]"#, #"[a-m]"#),
  .init(#"[a-ma-ha-e]"#, #"[a-m]"#),
  .init(#"[a-zA-Z0-9 -~]"#, #"[ -~]"#),

  // Empty character classes
  .init(#"[^[:cntrl:][:^cntrl:]]"#, #"[^\x00-\x{10FFFF}]"#),

  // Full character classes
  .init(#"[[:cntrl:][:^cntrl:]]"#, #"(?s:.)"#),

  // Unicode case folding.
  .init(#"(?i)A"#, #"(?i:A)"#),
  .init(#"(?i)a"#, #"(?i:A)"#),
  .init(#"(?i)[A]"#, #"(?i:A)"#),
  .init(#"(?i)[a]"#, #"(?i:A)"#),
  .init(#"(?i)K"#, #"(?i:K)"#),
  .init(#"(?i)k"#, #"(?i:K)"#),
  .init(#"(?i)\x{212a}"#, "(?i:K)"),
  .init(#"(?i)[K]"#, "[Kk\u{212A}]"),
  .init(#"(?i)[k]"#, "[Kk\u{212A}]"),
  .init(#"(?i)[\x{212a}]"#, "[Kk\u{212A}]"),
  .init(#"(?i)[a-z]"#, "[A-Za-z\u{017F}\u{212A}]"),
  .init(#"(?i)[\x00-\x{FFFD}]"#, "[\\x00-\u{FFFD}]"),
  .init(#"(?i)[\x00-\x{10FFFF}]"#, #"(?s:.)"#),

  // Empty string as a regular expression.
  // The empty string must be preserved inside parens in order
  // to make submatches work right, so these tests are less
  // interesting than they might otherwise be. String inserts
  // explicit (?:) in place of non-parenthesized empty strings,
  // to make them easier to spot for other parsers.
  .init(#"(a|b|c|)"#, #"([a-c]|(?:))"#),
  .init(#"(a|b|)"#, #"([ab]|(?:))"#),
  .init(#"(|)"#, #"()"#),
  .init(#"a()"#, #"a()"#),
  .init(#"(()|())"#, #"(()|())"#),
  .init(#"(a|)"#, #"(a|(?:))"#),
  .init(#"ab()cd()"#, #"ab()cd()"#),
  .init(#"()"#, #"()"#),
  .init(#"()*"#, #"()*"#),
  .init(#"()+"#, #"()+"#),
  .init(#"()?"#, #"()?"#),
  .init(#"(){0}"#, #"(?:)"#),
  .init(#"(){1}"#, #"()"#),
  .init(#"(){1,}"#, #"()+"#),
  .init(#"(){0,2}"#, #"(?:()()?)?"#),
]

struct CompileTest: Sendable, CustomTestStringConvertible {
  var regexp: String
  var prog: String
  init(_ regexp: String, _ prog: String) {
    self.regexp = regexp
    self.prog = prog
  }
  var testDescription: String { regexp }
}

private let compileTests: [CompileTest] = [
  .init(
    "a",
    """
      0\tfail
      1*\trune1 "a" -> 2
      2\tmatch

    """),
  .init(
    "[A-M][n-z]",
    """
      0\tfail
      1*\trune "AM" -> 2
      2\trune "nz" -> 3
      3\tmatch

    """),
  .init(
    "",
    """
      0\tfail
      1*\tnop -> 2
      2\tmatch

    """),
  .init(
    "a?",
    """
      0\tfail
      1\trune1 "a" -> 3
      2*\talt -> 1, 3
      3\tmatch

    """),
  .init(
    "a??",
    """
      0\tfail
      1\trune1 "a" -> 3
      2*\talt -> 3, 1
      3\tmatch

    """),
  .init(
    "a+",
    """
      0\tfail
      1*\trune1 "a" -> 2
      2\talt -> 1, 3
      3\tmatch

    """),
  .init(
    "a+?",
    """
      0\tfail
      1*\trune1 "a" -> 2
      2\talt -> 3, 1
      3\tmatch

    """),
  .init(
    "a*",
    """
      0\tfail
      1\trune1 "a" -> 2
      2*\talt -> 1, 3
      3\tmatch

    """),
  .init(
    "a*?",
    """
      0\tfail
      1\trune1 "a" -> 2
      2*\talt -> 3, 1
      3\tmatch

    """),
  .init(
    "a+b+",
    """
      0\tfail
      1*\trune1 "a" -> 2
      2\talt -> 1, 3
      3\trune1 "b" -> 4
      4\talt -> 3, 5
      5\tmatch

    """),
  .init(
    "(a+)(b+)",
    """
      0\tfail
      1*\tcap 2 -> 2
      2\trune1 "a" -> 3
      3\talt -> 2, 4
      4\tcap 3 -> 5
      5\tcap 4 -> 6
      6\trune1 "b" -> 7
      7\talt -> 6, 8
      8\tcap 5 -> 9
      9\tmatch

    """),
  .init(
    "a+|b+",
    """
      0\tfail
      1\trune1 "a" -> 2
      2\talt -> 1, 6
      3\trune1 "b" -> 4
      4\talt -> 3, 6
      5*\talt -> 1, 3
      6\tmatch

    """),
  .init(
    "A[Aa]",
    """
      0\tfail
      1*\trune1 "A" -> 2
      2\trune "A"/i -> 3
      3\tmatch

    """),
  .init(
    "(?:(?:^).)",
    """
      0\tfail
      1*\tempty 4 -> 2
      2\tanynotnl -> 3
      3\tmatch

    """),
  .init(
    "(?:|a)+",
    """
      0\tfail
      1\tnop -> 4
      2\trune1 "a" -> 4
      3*\talt -> 1, 2
      4\talt -> 3, 5
      5\tmatch

    """),
  .init(
    "(?:|a)*",
    """
      0\tfail
      1\tnop -> 4
      2\trune1 "a" -> 4
      3\talt -> 1, 2
      4\talt -> 3, 6
      5*\talt -> 3, 6
      6\tmatch

    """),
]

struct SyntaxSimplifyProgTests {
  @Test(arguments: simplifyTests)
  func simplify(_ tt: SimplifyTest) throws {
    let flags = Syntax.Flags.matchNL.union(Syntax.Flags.perl.subtracting(.oneLine))
    let re = try Syntax.parse(tt.regexp, flags)
    let s = re.simplify().description
    #expect(s == tt.simple, "Simplify(\(tt.regexp))")
  }

  @Test(arguments: compileTests)
  func compile(_ tt: CompileTest) throws {
    let re = try Syntax.parse(tt.regexp, .perl)
    let p = Syntax.compile(re)
    let s = p.description
    #expect(s == tt.prog, "compiled \(tt.regexp)")
  }

  /// EmptyOpContext over the input used by Go's BenchmarkEmptyOpContext, checked against
  /// LazyFlag, which the matchers use instead.
  @Test func emptyOpContextAgreesWithLazyFlag() {
    let text = Array("foo, bar, baz\nsome input text.\n".unicodeScalars).map { Rune($0.value) }
    var r1: Rune = -1
    for r2 in text + [-1] {
      let ops = Syntax.emptyOpContext(r1, r2)
      for bit in 0..<6 {
        let op = Syntax.EmptyOp(rawValue: 1 << bit)
        #expect(ops.contains(op) == LazyFlag(r1, r2).match(op))
      }
      r1 = r2
    }
  }
}
