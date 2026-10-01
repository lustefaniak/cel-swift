// Copyright 2011 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// Port of Go's regexp/syntax/parse_test.go.

import Foundation
import Testing

@testable import CELRegex

struct ParseTest: Sendable, CustomTestStringConvertible {
  var regexp: String
  var dump: String
  init(_ regexp: String, _ dump: String) {
    self.regexp = regexp
    self.dump = dump
  }
  var testDescription: String { regexp.utf8.count > 60 ? String(regexp.prefix(60)) + "…" : regexp }
}

private let parseTests: [ParseTest] = [
  // Base cases
  .init(#"a"#, #"lit{a}"#),
  .init(#"a."#, #"cat{lit{a}dot{}}"#),
  .init(#"a.b"#, #"cat{lit{a}dot{}lit{b}}"#),
  .init(#"ab"#, #"str{ab}"#),
  .init(#"a.b.c"#, #"cat{lit{a}dot{}lit{b}dot{}lit{c}}"#),
  .init(#"abc"#, #"str{abc}"#),
  .init(#"a|^"#, #"alt{lit{a}bol{}}"#),
  .init(#"a|b"#, #"cc{0x61-0x62}"#),
  .init(#"(a)"#, #"cap{lit{a}}"#),
  .init(#"(a)|b"#, #"alt{cap{lit{a}}lit{b}}"#),
  .init(#"a*"#, #"star{lit{a}}"#),
  .init(#"a+"#, #"plus{lit{a}}"#),
  .init(#"a?"#, #"que{lit{a}}"#),
  .init(#"a{2}"#, #"rep{2,2 lit{a}}"#),
  .init(#"a{2,3}"#, #"rep{2,3 lit{a}}"#),
  .init(#"a{2,}"#, #"rep{2,-1 lit{a}}"#),
  .init(#"a*?"#, #"nstar{lit{a}}"#),
  .init(#"a+?"#, #"nplus{lit{a}}"#),
  .init(#"a??"#, #"nque{lit{a}}"#),
  .init(#"a{2}?"#, #"nrep{2,2 lit{a}}"#),
  .init(#"a{2,3}?"#, #"nrep{2,3 lit{a}}"#),
  .init(#"a{2,}?"#, #"nrep{2,-1 lit{a}}"#),
  // Malformed { } are treated as literals.
  .init(#"x{1001"#, #"str{x{1001}"#),
  .init(#"x{9876543210"#, #"str{x{9876543210}"#),
  .init(#"x{9876543210,"#, #"str{x{9876543210,}"#),
  .init(#"x{2,1"#, #"str{x{2,1}"#),
  .init(#"x{1,9876543210"#, #"str{x{1,9876543210}"#),
  .init(#""#, #"emp{}"#),
  .init(#"|"#, #"emp{}"#),  // alt{emp{}emp{}} but got factored
  .init(#"|x|"#, #"alt{emp{}lit{x}emp{}}"#),
  .init(#"."#, #"dot{}"#),
  .init(#"^"#, #"bol{}"#),
  .init(#"$"#, #"eol{}"#),
  .init(#"\|"#, #"lit{|}"#),
  .init(#"\("#, #"lit{(}"#),
  .init(#"\)"#, #"lit{)}"#),
  .init(#"\*"#, #"lit{*}"#),
  .init(#"\+"#, #"lit{+}"#),
  .init(#"\?"#, #"lit{?}"#),
  .init(#"{"#, #"lit{{}"#),
  .init(#"}"#, #"lit{}}"#),
  .init(#"\."#, #"lit{.}"#),
  .init(#"\^"#, #"lit{^}"#),
  .init(#"\$"#, #"lit{$}"#),
  .init(#"\\"#, #"lit{\}"#),
  .init(#"[ace]"#, #"cc{0x61 0x63 0x65}"#),
  .init(#"[abc]"#, #"cc{0x61-0x63}"#),
  .init(#"[a-z]"#, #"cc{0x61-0x7a}"#),
  .init(#"[a]"#, #"lit{a}"#),
  .init(#"\-"#, #"lit{-}"#),
  .init(#"-"#, #"lit{-}"#),
  .init(#"\_"#, #"lit{_}"#),
  .init(#"abc"#, #"str{abc}"#),
  .init(#"abc|def"#, #"alt{str{abc}str{def}}"#),
  .init(#"abc|def|ghi"#, #"alt{str{abc}str{def}str{ghi}}"#),

  // Posix and Perl extensions
  .init(#"[[:lower:]]"#, #"cc{0x61-0x7a}"#),
  .init(#"[a-z]"#, #"cc{0x61-0x7a}"#),
  .init(#"[^[:lower:]]"#, #"cc{0x0-0x60 0x7b-0x10ffff}"#),
  .init(#"[[:^lower:]]"#, #"cc{0x0-0x60 0x7b-0x10ffff}"#),
  .init(#"(?i)[[:lower:]]"#, #"cc{0x41-0x5a 0x61-0x7a 0x17f 0x212a}"#),
  .init(#"(?i)[a-z]"#, #"cc{0x41-0x5a 0x61-0x7a 0x17f 0x212a}"#),
  .init(#"(?i)[^[:lower:]]"#, #"cc{0x0-0x40 0x5b-0x60 0x7b-0x17e 0x180-0x2129 0x212b-0x10ffff}"#),
  .init(#"(?i)[[:^lower:]]"#, #"cc{0x0-0x40 0x5b-0x60 0x7b-0x17e 0x180-0x2129 0x212b-0x10ffff}"#),
  .init(#"\d"#, #"cc{0x30-0x39}"#),
  .init(#"\D"#, #"cc{0x0-0x2f 0x3a-0x10ffff}"#),
  .init(#"\s"#, #"cc{0x9-0xa 0xc-0xd 0x20}"#),
  .init(#"\S"#, #"cc{0x0-0x8 0xb 0xe-0x1f 0x21-0x10ffff}"#),
  .init(#"\w"#, #"cc{0x30-0x39 0x41-0x5a 0x5f 0x61-0x7a}"#),
  .init(#"\W"#, #"cc{0x0-0x2f 0x3a-0x40 0x5b-0x5e 0x60 0x7b-0x10ffff}"#),
  .init(#"(?i)\w"#, #"cc{0x30-0x39 0x41-0x5a 0x5f 0x61-0x7a 0x17f 0x212a}"#),
  .init(#"(?i)\W"#, #"cc{0x0-0x2f 0x3a-0x40 0x5b-0x5e 0x60 0x7b-0x17e 0x180-0x2129 0x212b-0x10ffff}"#),
  .init(#"[^\\]"#, #"cc{0x0-0x5b 0x5d-0x10ffff}"#),
  //  { `\C`, `byte{}` },  // probably never

  // Unicode, negatives, and a double negative.
  .init(#"\p{Braille}"#, #"cc{0x2800-0x28ff}"#),
  .init(#"\P{Braille}"#, #"cc{0x0-0x27ff 0x2900-0x10ffff}"#),
  .init(#"\p{^Braille}"#, #"cc{0x0-0x27ff 0x2900-0x10ffff}"#),
  .init(#"\P{^Braille}"#, #"cc{0x2800-0x28ff}"#),
  .init(#"\pZ"#, #"cc{0x20 0xa0 0x1680 0x2000-0x200a 0x2028-0x2029 0x202f 0x205f 0x3000}"#),
  .init(#"[\p{Braille}]"#, #"cc{0x2800-0x28ff}"#),
  .init(#"[\P{Braille}]"#, #"cc{0x0-0x27ff 0x2900-0x10ffff}"#),
  .init(#"[\p{^Braille}]"#, #"cc{0x0-0x27ff 0x2900-0x10ffff}"#),
  .init(#"[\P{^Braille}]"#, #"cc{0x2800-0x28ff}"#),
  .init(#"[\pZ]"#, #"cc{0x20 0xa0 0x1680 0x2000-0x200a 0x2028-0x2029 0x202f 0x205f 0x3000}"#),
  // \p{Lu}, \p{Uppercase_Letter}, ... (?i)[\p{Lu}], \p{Assigned}, \p{^Assigned}: the expected
  // dumps are computed from Go's package unicode; see unicodeClassTests.
  .init(#"\p{Any}"#, #"dot{}"#),
  .init(#"\p{^Any}"#, #"cc{}"#),
  .init(#"(?i)\p{ascii}"#, #"cc{0x0-0x7f 0x17f 0x212a}"#),

  // Hex, octal.
  .init(#"[\012-\234]\141"#, #"cat{cc{0xa-0x9c}lit{a}}"#),
  .init(#"[\x{41}-\x7a]\x61"#, #"cat{cc{0x41-0x7a}lit{a}}"#),

  // More interesting regular expressions.
  .init(#"a{,2}"#, #"str{a{,2}}"#),
  .init(#"\.\^\$\\"#, #"str{.^$\}"#),
  .init(#"[a-zABC]"#, #"cc{0x41-0x43 0x61-0x7a}"#),
  .init(#"[^a]"#, #"cc{0x0-0x60 0x62-0x10ffff}"#),
  .init(#"[α-ε☺]"#, #"cc{0x3b1-0x3b5 0x263a}"#),  // utf-8
  .init(#"a*{"#, #"cat{star{lit{a}}lit{{}}"#),

  // Test precedences
  .init(#"(?:ab)*"#, #"star{str{ab}}"#),
  .init(#"(ab)*"#, #"star{cap{str{ab}}}"#),
  .init(#"ab|cd"#, #"alt{str{ab}str{cd}}"#),
  .init(#"a(b|c)d"#, #"cat{lit{a}cap{cc{0x62-0x63}}lit{d}}"#),

  // Test flattening.
  .init(#"(?:a)"#, #"lit{a}"#),
  .init(#"(?:ab)(?:cd)"#, #"str{abcd}"#),
  .init(#"(?:a+b+)(?:c+d+)"#, #"cat{plus{lit{a}}plus{lit{b}}plus{lit{c}}plus{lit{d}}}"#),
  .init(#"(?:a+|b+)|(?:c+|d+)"#, #"alt{plus{lit{a}}plus{lit{b}}plus{lit{c}}plus{lit{d}}}"#),
  .init(#"(?:a|b)|(?:c|d)"#, #"cc{0x61-0x64}"#),
  .init(#"a|."#, #"dot{}"#),
  .init(#".|a"#, #"dot{}"#),
  .init(#"(?:[abc]|A|Z|hello|world)"#, #"alt{cc{0x41 0x5a 0x61-0x63}str{hello}str{world}}"#),
  .init(#"(?:[abc]|A|Z)"#, #"cc{0x41 0x5a 0x61-0x63}"#),

  // Test Perl quoted literals
  .init(#"\Q+|*?{[\E"#, #"str{+|*?{[}"#),
  .init(#"\Q+\E+"#, #"plus{lit{+}}"#),
  .init(#"\Qab\E+"#, #"cat{lit{a}plus{lit{b}}}"#),
  .init(#"\Q\\E"#, #"lit{\}"#),
  .init(#"\Q\\\E"#, #"str{\\}"#),

  // Test Perl \A and \z
  .init(#"(?m)^"#, #"bol{}"#),
  .init(#"(?m)$"#, #"eol{}"#),
  .init(#"(?-m)^"#, #"bot{}"#),
  .init(#"(?-m)$"#, #"eot{}"#),
  .init(#"(?m)\A"#, #"bot{}"#),
  .init(#"(?m)\z"#, #"eot{\z}"#),
  .init(#"(?-m)\A"#, #"bot{}"#),
  .init(#"(?-m)\z"#, #"eot{\z}"#),

  // Test named captures
  .init(#"(?P<name>a)"#, #"cap{name:lit{a}}"#),
  .init(#"(?<name>a)"#, #"cap{name:lit{a}}"#),

  // Case-folded literals
  .init(#"[Aa]"#, #"litfold{A}"#),
  .init(#"[\x{100}\x{101}]"#, #"litfold{Ā}"#),
  .init(#"[Δδ]"#, #"litfold{Δ}"#),

  // Strings
  .init(#"abcde"#, #"str{abcde}"#),
  .init(#"[Aa][Bb]cd"#, #"cat{strfold{AB}str{cd}}"#),

  // Factoring.
  .init(#"abc|abd|aef|bcx|bcy"#, #"alt{cat{lit{a}alt{cat{lit{b}cc{0x63-0x64}}str{ef}}}cat{str{bc}cc{0x78-0x79}}}"#),
  .init(#"ax+y|ax+z|ay+w"#, #"cat{lit{a}alt{cat{plus{lit{x}}lit{y}}cat{plus{lit{x}}lit{z}}cat{plus{lit{y}}lit{w}}}}"#),

  // Bug fixes.
  .init(#"(?:.)"#, #"dot{}"#),
  .init(#"(?:x|(?:xa))"#, #"cat{lit{x}alt{emp{}lit{a}}}"#),
  .init(#"(?:.|(?:.a))"#, #"cat{dot{}alt{emp{}lit{a}}}"#),
  .init(#"(?:A(?:A|a))"#, #"cat{lit{A}litfold{A}}"#),
  .init(#"(?:A|a)"#, #"litfold{A}"#),
  .init(#"A|(?:A|a)"#, #"litfold{A}"#),
  .init(#"(?s)."#, #"dot{}"#),
  .init(#"(?-s)."#, #"dnl{}"#),
  .init(#"(?:(?:^).)"#, #"cat{bol{}dot{}}"#),
  .init(#"(?-s)(?:(?:^).)"#, #"cat{bol{}dnl{}}"#),
  .init(#"[\s\S]a"#, #"cat{cc{0x0-0x10ffff}lit{a}}"#),

  // RE2 prefix_tests
  .init(#"abc|abd"#, #"cat{str{ab}cc{0x63-0x64}}"#),
  .init(#"a(?:b)c|abd"#, #"cat{str{ab}cc{0x63-0x64}}"#),
  .init(
    #"abc|abd|aef|bcx|bcy"#,
    #"alt{cat{lit{a}alt{cat{lit{b}cc{0x63-0x64}}str{ef}}}"# + #"cat{str{bc}cc{0x78-0x79}}}"#),
  .init(#"abc|x|abd"#, #"alt{str{abc}lit{x}str{abd}}"#),
  .init(#"(?i)abc|ABD"#, #"cat{strfold{AB}cc{0x43-0x44 0x63-0x64}}"#),
  .init(#"[ab]c|[ab]d"#, #"cat{cc{0x61-0x62}cc{0x63-0x64}}"#),
  .init(#".c|.d"#, #"cat{dot{}cc{0x63-0x64}}"#),
  .init(#"x{2}|x{2}[0-9]"#, #"cat{rep{2,2 lit{x}}alt{emp{}cc{0x30-0x39}}}"#),
  .init(#"x{2}y|x{2}[0-9]y"#, #"cat{rep{2,2 lit{x}}alt{lit{y}cat{cc{0x30-0x39}lit{y}}}}"#),
  .init(#"a.*?c|a.*?b"#, #"cat{lit{a}alt{cat{nstar{dot{}}lit{c}}cat{nstar{dot{}}lit{b}}}}"#),

  // Valid repetitions.
  .init(#"((((((((((x{2}){2}){2}){2}){2}){2}){2}){2}){2}))"#, ""),
  .init(#"((((((((((x{1}){2}){2}){2}){2}){2}){2}){2}){2}){2})"#, ""),

  // Valid nesting.
  .init(String(repeating: "(", count: 999) + String(repeating: ")", count: 999), ""),
  .init(String(repeating: "(?:", count: 999) + String(repeating: ")*", count: 999), ""),
  .init("(" + String(repeating: "|", count: 12345) + ")", ""),  // not nested at all
]

private let testFlags: Syntax.Flags = [.matchNL, .perlX, .unicodeGroups]

private let foldcaseTests: [ParseTest] = [
  .init(#"AbCdE"#, #"strfold{ABCDE}"#),
  .init(#"[Aa]"#, #"litfold{A}"#),
  .init(#"a"#, #"litfold{A}"#),

  // 0x17F is an old English long s (looks like an f) and folds to s.
  // 0x212A is the Kelvin symbol and folds to k.
  .init(#"A[F-g]"#, #"cat{litfold{A}cc{0x41-0x7a 0x17f 0x212a}}"#),  // [Aa][A-z...]
  .init(#"[[:upper:]]"#, #"cc{0x41-0x5a 0x61-0x7a 0x17f 0x212a}"#),
  .init(#"[[:lower:]]"#, #"cc{0x41-0x5a 0x61-0x7a 0x17f 0x212a}"#),
]

private let literalTests: [ParseTest] = [
  .init("(|)^$.[*+?]{5,10},\\", "str{(|)^$.[*+?]{5,10},\\}")
]

private let matchnlTests: [ParseTest] = [
  .init(#"."#, #"dot{}"#),
  .init("\n", "lit{\n}"),
  .init(#"[^a]"#, #"cc{0x0-0x60 0x62-0x10ffff}"#),
  .init(#"[a\n]"#, #"cc{0xa 0x61}"#),
]

private let nomatchnlTests: [ParseTest] = [
  .init(#"."#, #"dnl{}"#),
  .init("\n", "lit{\n}"),
  .init(#"[^a]"#, #"cc{0x0-0x9 0xb-0x60 0x62-0x10ffff}"#),
  .init(#"[a\n]"#, #"cc{0xa 0x61}"#),
]

/// The parse tests whose expected dumps Go computes from package unicode (mkCharClass), loaded
/// from Resources/unicode-classes.txt (generated by tools/gen-unicode-tables/testdata).
private func unicodeClassTests() throws -> [ParseTest] {
  let text = String(decoding: try resourceData("unicode-classes.txt"), as: UTF8.self)
  return text.split(separator: "\n").map { line in
    let parts = line.split(separator: "\t", maxSplits: 1)
    return ParseTest(String(parts[0]), String(parts[1]))
  }
}

// MARK: - dump

private let opNames: [UInt8: String] = [
  Syntax.Op.noMatch.rawValue: "no",
  Syntax.Op.emptyMatch.rawValue: "emp",
  Syntax.Op.literal.rawValue: "lit",
  Syntax.Op.charClass.rawValue: "cc",
  Syntax.Op.anyCharNotNL.rawValue: "dnl",
  Syntax.Op.anyChar.rawValue: "dot",
  Syntax.Op.beginLine.rawValue: "bol",
  Syntax.Op.endLine.rawValue: "eol",
  Syntax.Op.beginText.rawValue: "bot",
  Syntax.Op.endText.rawValue: "eot",
  Syntax.Op.wordBoundary.rawValue: "wb",
  Syntax.Op.noWordBoundary.rawValue: "nwb",
  Syntax.Op.capture.rawValue: "cap",
  Syntax.Op.star.rawValue: "star",
  Syntax.Op.plus.rawValue: "plus",
  Syntax.Op.quest.rawValue: "que",
  Syntax.Op.repeat.rawValue: "rep",
  Syntax.Op.concat.rawValue: "cat",
  Syntax.Op.alternate.rawValue: "alt",
]

/// dump prints a string representation of the regexp showing
/// the structure explicitly.
func dump(_ re: Syntax.Regexp) -> String {
  var b = ""
  dumpRegexp(&b, re)
  return b
}

private func hex(_ r: Rune) -> String {
  "0x" + String(r, radix: 16)
}

/// dumpRegexp writes an encoding of the syntax tree for the regexp re to b.
/// It is used during testing to distinguish between parses that might print
/// the same using re's String method.
private func dumpRegexp(_ b: inout String, _ re: Syntax.Regexp) {
  if let name = opNames[re.op.rawValue] {
    switch re.op {
    case .star, .plus, .quest, .repeat:
      if re.flags.contains(.nonGreedy) {
        b += "n"
      }
      b += name
    case .literal:
      if re.rune.count > 1 {
        b += "str"
      } else {
        b += "lit"
      }
      if re.flags.contains(.foldCase) {
        for r in re.rune where UnicodeTables.simpleFold(r) != r {
          b += "fold"
          break
        }
      }
    default:
      b += name
    }
  } else {
    b += "op\(re.op.rawValue)"
  }
  b += "{"
  switch re.op {
  case .endText:
    if !re.flags.contains(.wasDollar) {
      b += #"\z"#
    }
  case .literal:
    b += GoUTF8.string(runes: re.rune)
  case .concat, .alternate:
    for sub in re.sub {
      dumpRegexp(&b, sub)
    }
  case .star, .plus, .quest:
    dumpRegexp(&b, re.sub[0])
  case .repeat:
    b += "\(re.min),\(re.max) "
    dumpRegexp(&b, re.sub[0])
  case .capture:
    if !re.name.isEmpty {
      b += re.name
      b += ":"
    }
    dumpRegexp(&b, re.sub[0])
  case .charClass:
    var sep = ""
    var i = 0
    while i < re.rune.count {
      b += sep
      sep = " "
      let lo = re.rune[i]
      let hi = re.rune[i + 1]
      if lo == hi {
        b += hex(lo)
      } else {
        b += hex(lo) + "-" + hex(hi)
      }
      i += 2
    }
  default:
    break
  }
  b += "}"
}

// MARK: - Tests

/// Test Parse -> Dump.
private func testParseDump(_ tt: ParseTest, _ flags: Syntax.Flags) {
  let re: Syntax.Regexp
  do {
    re = try Syntax.parse(tt.regexp, flags)
  } catch {
    Issue.record("Parse(\(tt.regexp)): \(error)")
    return
  }
  if tt.dump.isEmpty {
    // It parsed. That's all we care about.
    return
  }
  let d = dump(re)
  #expect(d == tt.dump, "Parse(\(tt.regexp)).Dump()")
}

struct SyntaxParseTests {
  @Test(arguments: parseTests)
  func parseSimple(_ tt: ParseTest) {
    testParseDump(tt, testFlags)
  }

  @Test func parseUnicodeClasses() throws {
    let tests = try unicodeClassTests()
    #expect(tests.count == 8)
    for tt in tests {
      testParseDump(tt, testFlags)
    }
  }

  @Test(arguments: foldcaseTests)
  func parseFoldCase(_ tt: ParseTest) {
    testParseDump(tt, .foldCase)
  }

  @Test(arguments: literalTests)
  func parseLiteral(_ tt: ParseTest) {
    testParseDump(tt, .literal)
  }

  @Test(arguments: matchnlTests)
  func parseMatchNL(_ tt: ParseTest) {
    testParseDump(tt, .matchNL)
  }

  @Test(arguments: nomatchnlTests)
  func parseNoMatchNL(_ tt: ParseTest) {
    testParseDump(tt, [])
  }

  @Test func foldConstants() {
    var last: Rune = -1
    for i in Rune(0)...UnicodeTables.maxRune {
      if UnicodeTables.simpleFold(i) == i {
        continue
      }
      if last == -1 && Syntax.minFold != i {
        Issue.record("minFold=\(Syntax.minFold) should be \(i)")
      }
      last = i
    }
    #expect(Syntax.maxFold == last)
  }

  @Test func appendRangeCollapse() {
    // AppendRange should collapse each of the new ranges
    // into the earlier ones (it looks back two ranges), so that
    // the slice never grows very large.
    // Note that we are not calling cleanClass.
    var r: [Rune] = []
    for i in Rune(0x41)...Rune(0x5A) {
      Syntax.appendRange(&r, i, i)
      Syntax.appendRange(&r, i + 0x20, i + 0x20)
    }
    #expect(GoUTF8.string(runes: r) == "AZaz")
  }

  static let invalidRegexps: [[UInt8]] = [
    bytes(#"("#),
    bytes(#")"#),
    bytes(#"(a"#),
    bytes(#"a)"#),
    bytes(#"(a))"#),
    bytes(#"(a|b|"#),
    bytes(#"a|b|)"#),
    bytes(#"(a|b|))"#),
    bytes(#"(a|b"#),
    bytes(#"a|b)"#),
    bytes(#"(a|b))"#),
    bytes(#"[a-z"#),
    bytes(#"([a-z)"#),
    bytes(#"[a-z)"#),
    bytes(#"([a-z]))"#),
    bytes(#"x{1001}"#),
    bytes(#"x{9876543210}"#),
    bytes(#"x{2,1}"#),
    bytes(#"x{1,9876543210}"#),
    [0xff],  // Invalid UTF-8
    goBytes("[", 0xff, "]"),
    goBytes("[\\", 0xff, "]"),
    goBytes("\\", 0xff),
    bytes(#"(?P<name>a"#),
    bytes(#"(?P<name>"#),
    bytes(#"(?P<name"#),
    bytes(#"(?P<x y>a)"#),
    bytes(#"(?P<>a)"#),
    bytes(#"(?<name>a"#),
    bytes(#"(?<name>"#),
    bytes(#"(?<name"#),
    bytes(#"(?<x y>a)"#),
    bytes(#"(?<>a)"#),
    bytes(#"[a-Z]"#),
    bytes(#"(?i)[a-Z]"#),
    bytes(#"\Q\E*"#),
    bytes(#"a{100000}"#),  // too much repetition
    bytes(#"a{100000,}"#),  // too much repetition
    bytes("((((((((((x{2}){2}){2}){2}){2}){2}){2}){2}){2}){2})"),  // too much repetition
    bytes(String(repeating: "(", count: 1000) + String(repeating: ")", count: 1000)),  // too deep
    bytes(String(repeating: "(?:", count: 1000) + String(repeating: ")*", count: 1000)),  // too deep
    bytes("(" + String(repeating: "(xx?)", count: 1000) + "){1000}"),  // too long
    bytes(String(repeating: "(xx?){1000}", count: 1000)),  // too long
    bytes(String(repeating: #"\pL"#, count: 27000)),  // too many runes
  ]

  static let onlyPerl: [String] = [
    #"[a-b-c]"#,
    #"\Qabc\E"#,
    #"\Q*+?{[\E"#,
    #"\Q\\E"#,
    #"\Q\\\E"#,
    #"\Q\\\\E"#,
    #"\Q\\\\\E"#,
    #"(?:a)"#,
    #"(?P<name>a)"#,
  ]

  static let onlyPOSIX: [String] = [
    "a++",
    "a**",
    "a?*",
    "a+*",
    "a{1}*",
    ".{1}{2}.{3}",
  ]

  @Test func parseInvalidRegexps() {
    for regexp in Self.invalidRegexps {
      if let re = try? Syntax.parse(bytes: regexp, .perl) {
        Issue.record("Parse(\(goQuote(regexp)), Perl) = \(dump(re)), should have failed")
      }
      if let re = try? Syntax.parse(bytes: regexp, .posix) {
        Issue.record("Parse(\(goQuote(regexp)), POSIX) = \(dump(re)), should have failed")
      }
    }
    for regexp in Self.onlyPerl {
      #expect(throws: Never.self, "Parse(\(regexp), Perl)") { try Syntax.parse(regexp, .perl) }
      if let re = try? Syntax.parse(regexp, .posix) {
        Issue.record("Parse(\(regexp), POSIX) = \(dump(re)), should have failed")
      }
    }
    for regexp in Self.onlyPOSIX {
      if let re = try? Syntax.parse(regexp, .perl) {
        Issue.record("Parse(\(regexp), Perl) = \(dump(re)), should have failed")
      }
      #expect(throws: Never.self, "Parse(\(regexp), POSIX)") { try Syntax.parse(regexp, .posix) }
    }
  }

  @Test(arguments: parseTests)
  func toStringEquivalentParse(_ tt: ParseTest) throws {
    let re = try Syntax.parse(tt.regexp, testFlags)
    if tt.dump.isEmpty {
      // It parsed. That's all we care about.
      return
    }
    let d = dump(re)
    try #require(d == tt.dump, "Parse(\(tt.regexp)).Dump()")

    let s = re.description
    if s != tt.regexp {
      // If ToString didn't return the original regexp,
      // it must have found one with fewer parens.
      // Unfortunately we can't check the length here, because
      // ToString produces "\\{" for a literal brace,
      // but "{" is a shorter equivalent in some contexts.
      let nre = try Syntax.parse(s, testFlags)
      let nd = dump(nre)
      #expect(d == nd, "Parse(\(tt.regexp)) -> \(s)")

      let ns = nre.description
      #expect(s == ns, "Parse(\(tt.regexp)) -> \(s) -> \(ns)")
    }
  }

  static let stringTests: [(re: String, out: String)] = [
    (#"x(?i:ab*c|d?e)1"#, #"x(?i:AB*C|D?E)1"#),
    (#"x(?i:ab*cd?e)1"#, #"x(?i:AB*CD?E)1"#),
    (#"0(?i:ab*c|d?e)1"#, #"(?i:0(?:AB*C|D?E)1)"#),
    (#"0(?i:ab*cd?e)1"#, #"(?i:0AB*CD?E1)"#),
    (#"x(?i:ab*c|d?e)"#, #"x(?i:AB*C|D?E)"#),
    (#"x(?i:ab*cd?e)"#, #"x(?i:AB*CD?E)"#),
    (#"0(?i:ab*c|d?e)"#, #"(?i:0(?:AB*C|D?E))"#),
    (#"0(?i:ab*cd?e)"#, #"(?i:0AB*CD?E)"#),
    (#"(?i:ab*c|d?e)1"#, #"(?i:(?:AB*C|D?E)1)"#),
    (#"(?i:ab*cd?e)1"#, #"(?i:AB*CD?E1)"#),
    (#"(?i:ab)[123](?i:cd)"#, #"(?i:AB[1-3]CD)"#),
    (#"(?i:ab*c|d?e)"#, #"(?i:AB*C|D?E)"#),
    (#"[Aa][Bb]"#, #"(?i:AB)"#),
    (#"[Aa][Bb]*[Cc]"#, #"(?i:AB*C)"#),
    (#"A(?:[Bb][Cc]|[Dd])[Zz]"#, #"A(?i:(?:BC|D)Z)"#),
    (#"[Aa](?:[Bb][Cc]|[Dd])Z"#, #"(?i:A(?:BC|D))Z"#),
  ]

  @Test func string() throws {
    for tt in Self.stringTests {
      let re = try Syntax.parse(tt.re, .perl)
      #expect(re.description == tt.out, "Parse(\(tt.re)).String()")
    }
  }

  /// The error messages CEL surfaces come from Go's (*syntax.Error).Error().
  @Test func errorMessages() {
    let cases: [(String, String)] = [
      ("(a", "error parsing regexp: missing closing ): `(a`"),
      ("a)", "error parsing regexp: unexpected ): `a)`"),
      ("[a", "error parsing regexp: missing closing ]: `[a`"),
      ("a**", "error parsing regexp: invalid nested repetition operator: `**`"),
      ("*", "error parsing regexp: missing argument to repetition operator: `*`"),
      (#"\8"#, #"error parsing regexp: invalid escape sequence: `\8`"#),
      (#"\p{Foo}"#, #"error parsing regexp: invalid character class range: `\p{Foo}`"#),
      ("x{1001}", "error parsing regexp: invalid repeat count: `{1001}`"),
      ("(?<x y>a)", "error parsing regexp: invalid named capture: `(?<x y>`"),
      ("(?z)", "error parsing regexp: invalid or unsupported Perl syntax: `(?z`"),
      (#"a\"#, "error parsing regexp: trailing backslash at end of expression: ``"),
    ]
    for (re, want) in cases {
      do {
        _ = try Syntax.parse(re, .perl)
        Issue.record("Parse(\(re)) succeeded, want \(want)")
      } catch {
        #expect(error.description == want)
      }
    }
  }
}
