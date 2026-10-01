// Copyright 2014 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// Port of Go's regexp/onepass_test.go.
//
// TestMergeRuneSet is not ported yet: mergeRuneSets is private in OnePass.swift.

import Testing

@testable import CELRegex

struct OnePassTests {
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
