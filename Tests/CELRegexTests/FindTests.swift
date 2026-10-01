// Copyright 2010 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// Port of Go's regexp/find_test.go.
//
// Texts are byte arrays because some hold invalid UTF-8; the String API variants run only on texts
// that are valid UTF-8 (a Swift String cannot hold anything else). Go's All variants return nil for
// no match; ours return an empty array, so "nil" expectations map to "empty".
// Not ported: TestFindReaderIndex, TestFindReaderSubmatchIndex (no io.RuneReader API), and the
// cap(result) == len(result) checks (Go slice capacity has no Swift equivalent).

import Testing

@testable import CELRegex

/// For each pattern/text pair, what is the expected output of each function?
/// We can derive the textual results from the indexed results, the non-submatch
/// results from the submatched results, the single results from the 'all' results,
/// and the byte results from the string results. Therefore the table includes
/// only the FindAllStringSubmatchIndex result.
struct FindTest: Sendable, CustomTestStringConvertible {
  var pat: String
  var text: [UInt8]
  var matches: [[Int]]?

  init(_ pat: String, _ text: String, _ matches: [[Int]]?) {
    self.pat = pat
    self.text = Array(text.utf8)
    self.matches = matches
  }

  init(_ pat: String, bytes text: [UInt8], _ matches: [[Int]]?) {
    self.pat = pat
    self.text = text
    self.matches = matches
  }

  /// The text as a String, if it is valid UTF-8.
  var textString: String? {
    let s = String(decoding: text, as: UTF8.self)
    return Array(s.utf8) == text ? s : nil
  }

  var testDescription: String { "pat: \(goQuote(pat)) text: \(goQuote(text))" }

  func sub(_ a: Int, _ b: Int) -> [UInt8] { Array(text[a..<b]) }
  func subString(_ a: Int, _ b: Int) -> String { String(decoding: text[a..<b], as: UTF8.self) }
}

/// build is a helper to construct a [][]int by extracting n sequences from x.
/// This represents n matches with len(x)/n submatches each.
func build(_ n: Int, _ x: Int...) -> [[Int]] {
  let runLength = x.count / n
  var ret: [[Int]] = []
  var j = 0
  for _ in 0..<n {
    ret.append(Array(x[j..<(j + runLength)]))
    j += runLength
  }
  return ret
}

let findTests: [FindTest] = [
  .init(#""#, "", build(1, 0, 0)),
  .init(#"^abcdefg"#, "abcdefg", build(1, 0, 7)),
  .init(#"a+"#, "baaab", build(1, 1, 4)),
  .init("abcd..", "abcdef", build(1, 0, 6)),
  .init(#"a"#, "a", build(1, 0, 1)),
  .init(#"x"#, "y", nil),
  .init(#"b"#, "abc", build(1, 1, 2)),
  .init(#"."#, "a", build(1, 0, 1)),
  .init(#".*"#, "abcdef", build(1, 0, 6)),
  .init(#"^"#, "abcde", build(1, 0, 0)),
  .init(#"$"#, "abcde", build(1, 5, 5)),
  .init(#"^abcd$"#, "abcd", build(1, 0, 4)),
  .init(#"^bcd'"#, "abcdef", nil),
  .init(#"^abcd$"#, "abcde", nil),
  .init(#"a+"#, "baaab", build(1, 1, 4)),
  .init(#"a*"#, "baaab", build(3, 0, 0, 1, 4, 5, 5)),
  .init(#"[a-z]+"#, "abcd", build(1, 0, 4)),
  .init(#"[^a-z]+"#, "ab1234cd", build(1, 2, 6)),
  .init(#"[a\-\]z]+"#, "az]-bcz", build(2, 0, 4, 6, 7)),
  .init(#"[^\n]+"#, "abcd\n", build(1, 0, 4)),
  .init(#"[日本語]+"#, "日本語日本語", build(1, 0, 18)),
  .init(#"日本語+"#, "日本語", build(1, 0, 9)),
  .init(#"日本語+"#, "日本語語語語", build(1, 0, 18)),
  .init(#"()"#, "", build(1, 0, 0, 0, 0)),
  .init(#"(a)"#, "a", build(1, 0, 1, 0, 1)),
  .init(#"(.)(.)"#, "日a", build(1, 0, 4, 0, 3, 3, 4)),
  .init(#"(.*)"#, "", build(1, 0, 0, 0, 0)),
  .init(#"(.*)"#, "abcd", build(1, 0, 4, 0, 4)),
  .init(#"(..)(..)"#, "abcd", build(1, 0, 4, 0, 2, 2, 4)),
  .init(#"(([^xyz]*)(d))"#, "abcd", build(1, 0, 4, 0, 4, 0, 3, 3, 4)),
  .init(#"((a|b|c)*(d))"#, "abcd", build(1, 0, 4, 0, 4, 2, 3, 3, 4)),
  .init(#"(((a|b|c)*)(d))"#, "abcd", build(1, 0, 4, 0, 4, 0, 3, 2, 3, 3, 4)),
  .init(#"\a\f\n\r\t\v"#, "\u{07}\u{0C}\n\r\t\u{0B}", build(1, 0, 6)),
  .init(#"[\a\f\n\r\t\v]+"#, "\u{07}\u{0C}\n\r\t\u{0B}", build(1, 0, 6)),

  .init(#"a*(|(b))c*"#, "aacc", build(1, 0, 4, 2, 2, -1, -1)),
  .init(#"(.*).*"#, "ab", build(1, 0, 2, 0, 2)),
  .init(#"[.]"#, ".", build(1, 0, 1)),
  .init(#"/$"#, "/abc/", build(1, 4, 5)),
  .init(#"/$"#, "/abc", nil),

  // multiple matches
  .init(#"."#, "abc", build(3, 0, 1, 1, 2, 2, 3)),
  .init(#"(.)"#, "abc", build(3, 0, 1, 0, 1, 1, 2, 1, 2, 2, 3, 2, 3)),
  .init(#".(.)"#, "abcd", build(2, 0, 2, 1, 2, 2, 4, 3, 4)),
  .init(#"ab*"#, "abbaab", build(3, 0, 3, 3, 4, 4, 6)),
  .init(#"a(b*)"#, "abbaab", build(3, 0, 3, 1, 3, 3, 4, 4, 4, 4, 6, 5, 6)),

  // fixed bugs
  .init(#"ab$"#, "cab", build(1, 1, 3)),
  .init(#"axxb$"#, "axxcb", nil),
  .init(#"data"#, "daXY data", build(1, 5, 9)),
  .init(#"da(.)a$"#, "daXY data", build(1, 5, 9, 7, 8)),
  .init(#"zx+"#, "zzx", build(1, 1, 3)),
  .init(#"ab$"#, "abcab", build(1, 3, 5)),
  .init(#"(aa)*$"#, "a", build(1, 1, 1, -1, -1)),
  .init(#"(?:.|(?:.a))"#, "", nil),
  .init(#"(?:A(?:A|a))"#, "Aa", build(1, 0, 2)),
  .init(#"(?:A|(?:A|a))"#, "a", build(1, 0, 1)),
  .init(#"(a){0}"#, "", build(1, 0, 0, -1, -1)),
  .init(#"(?-s)(?:(?:^).)"#, "\n", nil),
  .init(#"(?s)(?:(?:^).)"#, "\n", build(1, 0, 1)),
  .init(#"(?:(?:^).)"#, "\n", nil),
  .init(#"\b"#, "x", build(2, 0, 0, 1, 1)),
  .init(#"\b"#, "xx", build(2, 0, 0, 2, 2)),
  .init(#"\b"#, "x y", build(4, 0, 0, 1, 1, 2, 2, 3, 3)),
  .init(#"\b"#, "xx yy", build(4, 0, 0, 2, 2, 3, 3, 5, 5)),
  .init(#"\B"#, "x", nil),
  .init(#"\B"#, "xx", build(1, 1, 1)),
  .init(#"\B"#, "x y", nil),
  .init(#"\B"#, "xx yy", build(2, 1, 1, 4, 4)),
  .init(#"(|a)*"#, "aa", build(3, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2)),
  .init(#"0A|0[aA]"#, "0a", build(1, 0, 2)),
  .init(#"0[aA]|0A"#, "0a", build(1, 0, 2)),

  // RE2 tests
  .init(#"[^\S\s]"#, "abcd", nil),
  .init(#"[^\S[:space:]]"#, "abcd", nil),
  .init(#"[^\D\d]"#, "abcd", nil),
  .init(#"[^\D[:digit:]]"#, "abcd", nil),
  .init(#"(?i)\W"#, "x", nil),
  .init(#"(?i)\W"#, "k", nil),
  .init(#"(?i)\W"#, "s", nil),

  // can backslash-escape any punctuation
  .init(
    ##"\!\"\#\$\%\&\'\(\)\*\+\,\-\.\/\:\;\<\=\>\?\@\[\\\]\^\_\{\|\}\~"##,
    ##"!"#$%&'()*+,-./:;<=>?@[\]^_{|}~"##, build(1, 0, 31)),
  .init(
    ##"[\!\"\#\$\%\&\'\(\)\*\+\,\-\.\/\:\;\<\=\>\?\@\[\\\]\^\_\{\|\}\~]+"##,
    ##"!"#$%&'()*+,-./:;<=>?@[\]^_{|}~"##, build(1, 0, 31)),
  .init("\\`", "`", build(1, 0, 1)),
  .init("[\\`]+", "`", build(1, 0, 1)),

  .init("\u{fffd}", bytes: [0xff], build(1, 0, 1)),
  .init("\u{fffd}", bytes: goBytes("hello", 0xff, "world"), build(1, 5, 6)),
  .init(#".*"#, bytes: goBytes("hello", 0xff, "world"), build(1, 0, 11)),
  .init(#"\x{fffd}"#, bytes: [0xc2, 0x00], build(1, 0, 1)),
  .init("[\u{fffd}]", bytes: [0xff], build(1, 0, 1)),
  .init(#"[\x{fffd}]"#, bytes: [0xc2, 0x00], build(1, 0, 1)),

  // long set of matches (longer than startSize)
  .init(
    ".",
    "qwertyuiopasdfghjklzxcvbnm1234567890",
    build(
      36, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10,
      10, 11, 11, 12, 12, 13, 13, 14, 14, 15, 15, 16, 16, 17, 17, 18, 18, 19, 19, 20,
      20, 21, 21, 22, 22, 23, 23, 24, 24, 25, 25, 26, 26, 27, 27, 28, 28, 29, 29, 30,
      30, 31, 31, 32, 32, 33, 33, 34, 34, 35, 35, 36)
  ),
]

private func compile(_ pat: String) throws -> Regexp {
  try Regexp.compile(pat)
}

// MARK: - helpers

private func testFindIndex(_ test: FindTest, _ result: [Int]?) {
  switch (test.matches, result) {
  case (nil, nil):
    break
  case (nil, let r?):
    Issue.record("got match \(r), want none: \(test.testDescription)")
  case (_?, nil):
    Issue.record("got no match, want one: \(test.testDescription)")
  case (let m?, let r?):
    let want = m[0]
    #expect(want[0] == r[0] && want[1] == r[1], "got \(r), want \(want): \(test.testDescription)")
  }
}

private func testFindAllIndex(_ test: FindTest, _ result: [[Int]]) {
  guard let matches = test.matches else {
    #expect(result.isEmpty, "got match \(result), want none: \(test.testDescription)")
    return
  }
  if result.isEmpty {
    Issue.record("got no match, want one: \(test.testDescription)")
    return
  }
  if matches.count != result.count {
    Issue.record("got \(result.count) matches, want \(matches.count): \(test.testDescription)")
    return
  }
  for (k, e) in matches.enumerated() {
    #expect(e[0] == result[k][0] && e[1] == result[k][1], "match \(k): got \(result[k]), want \(e): \(test.testDescription)")
  }
}

private func testSubmatchBytes(_ test: FindTest, _ n: Int, _ submatches: [Int], _ result: [[UInt8]?]) {
  if submatches.count != result.count * 2 {
    Issue.record("match \(n): got \(result.count) submatches, want \(submatches.count / 2): \(test.testDescription)")
    return
  }
  var k = 0
  while k < submatches.count {
    defer { k += 2 }
    if submatches[k] == -1 {
      #expect(result[k / 2] == nil, "match \(n): got \(String(describing: result[k / 2])), want nil: \(test.testDescription)")
      continue
    }
    let want = test.sub(submatches[k], submatches[k + 1])
    guard let got = result[k / 2], got == want else {
      Issue.record("match \(n): got \(String(describing: result[k / 2])), want \(want): \(test.testDescription)")
      return
    }
  }
}

private func testSubmatchString(_ test: FindTest, _ n: Int, _ submatches: [Int], _ result: [String]) {
  if submatches.count != result.count * 2 {
    Issue.record("match \(n): got \(result.count) submatches, want \(submatches.count / 2): \(test.testDescription)")
    return
  }
  var k = 0
  while k < submatches.count {
    defer { k += 2 }
    if submatches[k] == -1 {
      #expect(result[k / 2] == "", "match \(n): got \(result), want empty string: \(test.testDescription)")
      continue
    }
    let want = test.subString(submatches[k], submatches[k + 1])
    if want != result[k / 2] {
      Issue.record("match \(n): got \(goQuote(result[k / 2])), want \(goQuote(want)): \(test.testDescription)")
      return
    }
  }
}

private func testSubmatchIndices(_ test: FindTest, _ n: Int, _ want: [Int], _ result: [Int]) {
  if want.count != result.count {
    Issue.record("match \(n): got \(result.count / 2) matches, want \(want.count / 2): \(test.testDescription)")
    return
  }
  #expect(want == result, "match \(n): submatch error: got \(result), want \(want): \(test.testDescription)")
}

private func testFindSubmatchIndex(_ test: FindTest, _ result: [Int]?) {
  switch (test.matches, result) {
  case (nil, nil):
    break
  case (nil, let r?):
    Issue.record("got match \(r), want none: \(test.testDescription)")
  case (_?, nil):
    Issue.record("got no match, want one: \(test.testDescription)")
  case (let m?, let r?):
    testSubmatchIndices(test, 0, m[0], r)
  }
}

private func testFindAllSubmatchIndex(_ test: FindTest, _ result: [[Int]]) {
  guard let matches = test.matches else {
    #expect(result.isEmpty, "got match \(result), want none: \(test.testDescription)")
    return
  }
  if result.isEmpty {
    Issue.record("got no match, want one: \(test.testDescription)")
  } else if matches.count != result.count {
    Issue.record("got \(result.count) matches, want \(matches.count): \(test.testDescription)")
  } else {
    for (k, match) in matches.enumerated() {
      testSubmatchIndices(test, k, match, result[k])
    }
  }
}

// MARK: - Tests

struct FindTests {
  // First the simple cases.

  @Test(arguments: findTests)
  func find(_ test: FindTest) throws {
    let re = try compile(test.pat)
    #expect(re.description == test.pat, "re.String()")
    let result = re.find(test.text)
    switch (test.matches, result) {
    case (let m, let r) where (m ?? []).isEmpty && (r ?? []).isEmpty:
      break
    case (nil, let r?):
      Issue.record("got match \(r), want none: \(test.testDescription)")
    case (_?, nil):
      Issue.record("got no match, want one: \(test.testDescription)")
    case (let m?, let r?):
      let want = test.sub(m[0][0], m[0][1])
      #expect(want == r, "got \(r), want \(want): \(test.testDescription)")
    default:
      break
    }
  }

  @Test(arguments: findTests)
  func findString(_ test: FindTest) throws {
    guard let text = test.textString else { return }
    let result = try compile(test.pat).findString(text)
    switch test.matches {
    case nil:
      #expect(result == "", "got match \(goQuote(result)), want none: \(test.testDescription)")
    case let m?:
      if result.isEmpty {
        // Tricky because an empty result has two meanings: no match or empty match.
        #expect(m[0][0] == m[0][1], "got no match, want one: \(test.testDescription)")
      } else {
        let want = test.subString(m[0][0], m[0][1])
        #expect(want == result, "got \(goQuote(result)), want \(goQuote(want)): \(test.testDescription)")
      }
    }
  }

  @Test(arguments: findTests)
  func findIndex(_ test: FindTest) throws {
    testFindIndex(test, try compile(test.pat).findIndex(test.text))
  }

  @Test(arguments: findTests)
  func findStringIndex(_ test: FindTest) throws {
    guard let text = test.textString else { return }
    testFindIndex(test, try compile(test.pat).findStringIndex(text))
  }

  // Now come the simple All cases.

  @Test(arguments: findTests)
  func findAll(_ test: FindTest) throws {
    let result = try compile(test.pat).findAll(test.text, -1)
    guard let matches = test.matches else {
      #expect(result.isEmpty, "got match \(result), want none: \(test.testDescription)")
      return
    }
    try #require(!result.isEmpty, "got no match, want one: \(test.testDescription)")
    try #require(matches.count == result.count, "got \(result.count) matches, want \(matches.count): \(test.testDescription)")
    for (k, e) in matches.enumerated() {
      let want = test.sub(e[0], e[1])
      #expect(want == result[k], "match \(k): got \(result[k]), want \(want): \(test.testDescription)")
    }
  }

  @Test(arguments: findTests)
  func findAllString(_ test: FindTest) throws {
    guard let text = test.textString else { return }
    let result = try compile(test.pat).findAllString(text, -1)
    guard let matches = test.matches else {
      #expect(result.isEmpty, "got match \(result), want none: \(test.testDescription)")
      return
    }
    try #require(!result.isEmpty, "got no match, want one: \(test.testDescription)")
    try #require(matches.count == result.count, "got \(result.count) matches, want \(matches.count): \(test.testDescription)")
    for (k, e) in matches.enumerated() {
      let want = test.subString(e[0], e[1])
      #expect(want == result[k], "got \(goQuote(result[k])), want \(goQuote(want)): \(test.testDescription)")
    }
  }

  @Test(arguments: findTests)
  func findAllIndex(_ test: FindTest) throws {
    testFindAllIndex(test, try compile(test.pat).findAllIndex(test.text, -1))
  }

  @Test(arguments: findTests)
  func findAllStringIndex(_ test: FindTest) throws {
    guard let text = test.textString else { return }
    testFindAllIndex(test, try compile(test.pat).findAllStringIndex(text, -1))
  }

  // Now come the Submatch cases.

  @Test(arguments: findTests)
  func findSubmatch(_ test: FindTest) throws {
    let result = try compile(test.pat).findSubmatch(test.text)
    switch (test.matches, result) {
    case (nil, nil):
      break
    case (nil, let r?):
      Issue.record("got match \(r), want none: \(test.testDescription)")
    case (_?, nil):
      Issue.record("got no match, want one: \(test.testDescription)")
    case (let m?, let r?):
      testSubmatchBytes(test, 0, m[0], r)
    }
  }

  @Test(arguments: findTests)
  func findStringSubmatch(_ test: FindTest) throws {
    guard let text = test.textString else { return }
    let result = try compile(test.pat).findStringSubmatch(text)
    switch (test.matches, result) {
    case (nil, nil):
      break
    case (nil, let r?):
      Issue.record("got match \(r), want none: \(test.testDescription)")
    case (_?, nil):
      Issue.record("got no match, want one: \(test.testDescription)")
    case (let m?, let r?):
      testSubmatchString(test, 0, m[0], r)
    }
  }

  @Test(arguments: findTests)
  func findSubmatchIndex(_ test: FindTest) throws {
    testFindSubmatchIndex(test, try compile(test.pat).findSubmatchIndex(test.text))
  }

  @Test(arguments: findTests)
  func findStringSubmatchIndex(_ test: FindTest) throws {
    guard let text = test.textString else { return }
    testFindSubmatchIndex(test, try compile(test.pat).findStringSubmatchIndex(text))
  }

  // Now come the monster AllSubmatch cases.

  @Test(arguments: findTests)
  func findAllSubmatch(_ test: FindTest) throws {
    let result = try compile(test.pat).findAllSubmatch(test.text, -1)
    guard let matches = test.matches else {
      #expect(result.isEmpty, "got match \(result), want none: \(test.testDescription)")
      return
    }
    if result.isEmpty {
      Issue.record("got no match, want one: \(test.testDescription)")
    } else if matches.count != result.count {
      Issue.record("got \(result.count) matches, want \(matches.count): \(test.testDescription)")
    } else {
      for (k, match) in matches.enumerated() {
        testSubmatchBytes(test, k, match, result[k])
      }
    }
  }

  @Test(arguments: findTests)
  func findAllStringSubmatch(_ test: FindTest) throws {
    guard let text = test.textString else { return }
    let result = try compile(test.pat).findAllStringSubmatch(text, -1)
    guard let matches = test.matches else {
      #expect(result.isEmpty, "got match \(result), want none: \(test.testDescription)")
      return
    }
    if result.isEmpty {
      Issue.record("got no match, want one: \(test.testDescription)")
    } else if matches.count != result.count {
      Issue.record("got \(result.count) matches, want \(matches.count): \(test.testDescription)")
    } else {
      for (k, match) in matches.enumerated() {
        testSubmatchString(test, k, match, result[k])
      }
    }
  }

  @Test(arguments: findTests)
  func findAllSubmatchIndex(_ test: FindTest) throws {
    testFindAllSubmatchIndex(test, try compile(test.pat).findAllSubmatchIndex(test.text, -1))
  }

  @Test(arguments: findTests)
  func findAllStringSubmatchIndex(_ test: FindTest) throws {
    guard let text = test.textString else { return }
    testFindAllSubmatchIndex(test, try compile(test.pat).findAllStringSubmatchIndex(text, -1))
  }
}
