// Copyright 2014 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// Port of Go's regexp/onepass_test.go.

import Testing

@testable import CELRegex

struct OnePassTests {
  static let runeMergeTests:
    [(left: [Rune], right: [Rune], merged: [Rune], next: [UInt32], leftPC: UInt32, rightPC: UInt32)] = [
      // empty rhs
      ([69, 69], [], [69, 69], [1], 1, 2),
      // identical runes, identical targets
      ([69, 69], [69, 69], [], [mergeFailed], 1, 1),
      // identical runes, different targets
      ([69, 69], [69, 69], [], [mergeFailed], 1, 2),
      // append right-first
      ([69, 69], [71, 71], [69, 69, 71, 71], [1, 2], 1, 2),
      // append, left-first
      ([71, 71], [69, 69], [69, 69, 71, 71], [2, 1], 1, 2),
      // successful interleave
      ([60, 60, 71, 71, 101, 101], [69, 69, 88, 88], [60, 60, 69, 69, 71, 71, 88, 88, 101, 101], [1, 2, 1, 2, 1], 1, 2),
      // left surrounds right
      ([69, 74], [71, 71], [], [mergeFailed], 1, 2),
      // right surrounds left
      ([69, 74], [68, 75], [], [mergeFailed], 1, 2),
      // overlap at interval begin
      ([69, 74], [74, 75], [], [mergeFailed], 1, 2),
      // overlap ar interval end
      ([69, 74], [65, 69], [], [mergeFailed], 1, 2),
      // overlap from above
      ([69, 74], [71, 74], [], [mergeFailed], 1, 2),
      // overlap from below
      ([69, 74], [65, 71], [], [mergeFailed], 1, 2),
      // out of order []rune
      ([69, 74, 60, 65], [66, 67], [], [mergeFailed], 1, 2),
    ]

  @Test func mergeRuneSet() {
    for (ix, test) in Self.runeMergeTests.enumerated() {
      let (merged, next) = mergeRuneSets(test.left, test.right, test.leftPC, test.rightPC)
      #expect(merged == test.merged, "mergeRuneSet :\(ix) (\(test.left), \(test.right)) merged")
      #expect(next == test.next, "mergeRuneSet :\(ix) (\(test.left), \(test.right)) next")
    }
  }

  static let onePassTests: [(re: String, isOnePass: Bool)] = [
    (#"^(?:a|(?:a*))$"#, false),
    (#"^(?:(a)|(?:a*))$"#, false),
    (#"^(?:(?:(?:.(?:$))?))$"#, true),
    (#"^abcd$"#, true),
    (#"^abcd"#, true),
    (#"^(?:(?:a{0,})*?)$"#, false),
    (#"^(?:(?:a+)*)$"#, true),
    (#"^(?:(?:a|(?:aa)))$"#, true),
    (#"^(?:[^\s\S])$"#, true),
    (#"^(?:(?:a{3,4}){0,})$"#, false),
    (#"^(?:(?:(?:a*)+))$"#, true),
    (#"^[a-c]+$"#, true),
    (#"^[a-c]*$"#, true),
    (#"^(?:a*)$"#, true),
    (#"^(?:(?:aa)|a)$"#, true),
    (#"^[a-c]*"#, false),
    (#"^...$"#, true),
    (#"^..."#, true),
    (#"^(?:a|(?:aa))$"#, true),
    (#"^a((b))c$"#, true),
    (#"^a.[l-nA-Cg-j]?e$"#, true),
    (#"^a((b))$"#, true),
    (#"^a(?:(b)|(c))c$"#, true),
    (#"^a(?:(b*)|(c))c$"#, false),
    (#"^a(?:b|c)$"#, true),
    (#"^a(?:b?|c)$"#, true),
    (#"^a(?:b?|c?)$"#, false),
    (#"^a(?:b?|c+)$"#, true),
    (#"^a(?:b+|(bc))d$"#, false),
    (#"^a(?:bc)+$"#, true),
    (#"^a(?:[bcd])+$"#, true),
    (#"^a((?:[bcd])+)$"#, true),
    (#"^a(:?b|c)*d$"#, true),
    (#"^.bc(d|e)*$"#, true),
    (#"^(?:(?:aa)|.)$"#, false),
    (#"^(?:(?:a{1,2}){1,2})$"#, false),
    (#"^l"# + String(repeating: "o", count: 2 << 8) + #"ng$"#, true),
  ]

  @Test func compileOnePass() throws {
    for test in Self.onePassTests {
      var re = try Syntax.parse(test.re, .perl)
      // needs to be done before compile...
      re = re.simplify()
      let p = Syntax.compile(re)
      let isOnePass = CELRegex.compileOnePass(p) != nil
      #expect(isOnePass == test.isOnePass, "CompileOnePass(\(test.re))")
    }
  }

  // TODO(cespare): Unify with onePassTests and rationalize one-pass test cases.
  static let onePassTests1: [(re: String, match: String)] = [
    (#"^a(/b+(#c+)*)*$"#, "a/b#c")  // golang.org/issue/11905
  ]

  @Test func runOnePass() throws {
    for test in Self.onePassTests1 {
      let re = try Regexp.compile(test.re)
      try #require(re.onepass != nil, "Compile(\(test.re)): got nil, want one-pass")
      #expect(re.matchString(test.match), "onepass \(test.re) did not match \(test.match)")
    }
  }
}
