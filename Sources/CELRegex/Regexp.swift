// Copyright 2009 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// Port of Go's regexp/regexp.go.
//
// The syntax of the regular expressions accepted is the same general syntax used by Perl, Python,
// and other languages. More precisely, it is the syntax accepted by RE2 and described at
// https://golang.org/s/re2syntax, except for \C.
//
// The implementation is guaranteed to run in time linear in the size of the input.
//
// All characters are UTF-8-encoded code points. Following Go's utf8.DecodeRune, each byte of an
// invalid UTF-8 sequence is treated as if it encoded utf8.RuneError (U+FFFD). Swift `String`s are
// always valid UTF-8; the `[UInt8]` overloads accept arbitrary bytes.
//
// All positions ("Index" results, match arrays) are UTF-8 byte offsets, as in Go.
//
// Not ported: the io.RuneReader methods (MatchReader, FindReaderIndex, FindReaderSubmatchIndex),
// Copy, MustCompile, and the encoding.Text(Un)Marshaler methods.

/// The error returned when a regular expression fails to compile. Its description is Go's
/// `err.Error()`, e.g. "error parsing regexp: missing closing ): `(a`".
package typealias RegexpError = Syntax.ParseError

/// Regexp is the representation of a compiled regular expression (Go's `regexp.Regexp`).
package struct Regexp: Sendable, CustomStringConvertible {
  let expr: String  // as passed to Compile
  let prog: Syntax.Prog  // compiled program
  let onepass: OnePassProg?  // onepass program or nil
  /// The number of parenthesized subexpressions in this Regexp.
  package let numSubexp: Int
  let maxBitStateLen: Int
  /// The names of the parenthesized subexpressions in this Regexp. The name for the first
  /// sub-expression is subexpNames[1], so that if m is a match slice, the name for m[i] is
  /// subexpNames[i]. Since the Regexp as a whole cannot be named, subexpNames[0] is always the
  /// empty string.
  package let subexpNames: [String]
  let prefix: [UInt8]  // required prefix in unanchored matches
  let prefixRune: Rune  // first rune in prefix
  let prefixEnd: UInt32  // pc for last rune in prefix
  let matchcap: Int  // size of recorded match lengths
  let prefixComplete: Bool  // prefix is the entire regexp
  let cond: Syntax.EmptyOp  // empty-width conditions required at start of match
  let minInputLen: Int  // minimum length of the input in bytes

  /// Whether searches prefer the leftmost-longest match (Go's `Longest()`), instead of
  /// leftmost-first.
  package var longest: Bool

  /// The source text used to compile the regular expression.
  package var description: String { expr }

  /// Compile parses a regular expression and returns, if successful,
  /// a Regexp object that can be used to match against text.
  ///
  /// When matching against text, the regexp returns a match that
  /// begins as early as possible in the input (leftmost), and among those
  /// it chooses the one that a backtracking search would have found first.
  /// This so-called leftmost-first matching is the same semantics
  /// that Perl, Python, and other implementations use, although this
  /// package implements it without the expense of backtracking.
  /// For POSIX leftmost-longest matching, see compilePOSIX.
  package init(_ expr: String) throws(RegexpError) {
    try self.init(expr, Syntax.Flags.perl, longest: false)
  }

  /// Compile (Go's `regexp.Compile`).
  package static func compile(_ expr: String) throws(RegexpError) -> Regexp {
    try Regexp(expr, Syntax.Flags.perl, longest: false)
  }

  /// CompilePOSIX is like Compile but restricts the regular expression
  /// to POSIX ERE (egrep) syntax and changes the match semantics to
  /// leftmost-longest.
  package static func compilePOSIX(_ expr: String) throws(RegexpError) -> Regexp {
    try Regexp(expr, Syntax.Flags.posix, longest: true)
  }

  init(_ expr: String, _ mode: Syntax.Flags, longest: Bool) throws(RegexpError) {
    var re = try Syntax.parse(expr, mode)
    let maxCap = re.maxCap()
    let capNames = re.capNames()

    re = re.simplify()
    let prog = Syntax.compile(re)
    self.expr = expr
    self.prog = prog
    self.onepass = compileOnePass(prog)
    self.numSubexp = maxCap
    self.subexpNames = capNames
    self.cond = prog.startCond()
    self.longest = longest
    self.matchcap = Swift.max(prog.numCap, 2)
    self.minInputLen = Regexp.minInputLen(re)
    if onepass == nil {
      (prefix, prefixComplete) = prog.prefix()
      maxBitStateLen = CELRegex.maxBitStateLen(prog)
      prefixEnd = 0
    } else {
      (prefix, prefixComplete, prefixEnd) = onePassPrefix(prog)
      maxBitStateLen = 0
    }
    if !prefix.isEmpty {
      prefixRune = prefix.withUnsafeBufferPointer { GoUTF8.decodeRune($0, at: 0).0 }
    } else {
      prefixRune = 0
    }
  }

  /// The number of instructions in the compiled program (Go's `len(prog.Inst)`).
  package var programSize: Int { prog.inst.count }

  /// The instruction count of `pattern` as cel-go's `types.RegexProgramSize` computes it:
  /// `len(syntax.Compile(syntax.Parse(pattern, syntax.Perl)).Inst)`, without simplifying.
  ///
  /// cel-go skips `Simplify`, so Go's compiler panics on counted repetitions (`a{2}`). Here such
  /// patterns are simplified before compiling instead, giving the size of the program that
  /// actually runs.
  package static func programSize(_ pattern: String) throws(RegexpError) -> Int {
    var re = try Syntax.parse(pattern, .perl)
    if re.containsRepeat() {
      re = re.simplify()
    }
    return Syntax.compile(re).inst.count
  }

  /// minInputLen walks the regexp to find the minimum length of any matchable input.
  ///
  /// Go's version recurses; this runs the same computation with an explicit stack, because
  /// simplified trees can be deeper than a 512 KB thread stack allows.
  static func minInputLen(_ root: Syntax.Regexp) -> Int {
    // Frames of (node, results of the children visited so far).
    var stack: [(re: Syntax.Regexp, children: [Int])] = [(root, [])]
    while true {
      let top = stack.count - 1
      let re = stack[top].re
      let needed = minInputLenChildren(re)
      if stack[top].children.count < needed {
        stack.append((re.sub[stack[top].children.count], []))
        continue
      }
      let value = minInputLen(re, stack[top].children)
      stack.removeLast()
      if stack.isEmpty {
        return value
      }
      stack[stack.count - 1].children.append(value)
    }
  }

  /// The number of children whose minInputLen Go's recursion looks at.
  private static func minInputLenChildren(_ re: Syntax.Regexp) -> Int {
    switch re.op {
    case .capture, .plus, .repeat:
      return 1
    case .concat, .alternate:
      return re.sub.count
    default:
      return 0
    }
  }

  /// One step of Go's minInputLen, given the values for the children.
  private static func minInputLen(_ re: Syntax.Regexp, _ children: [Int]) -> Int {
    switch re.op {
    case .anyChar, .anyCharNotNL, .charClass:
      return 1
    case .literal:
      var l = 0
      for r in re.rune {
        if r == GoUTF8.runeError {
          l += 1
        } else {
          l += GoUTF8.runeLen(r)
        }
      }
      return l
    case .capture, .plus:
      return children[0]
    case .repeat:
      return re.min * children[0]
    case .concat:
      return children.reduce(0, +)
    case .alternate:
      return children.min() ?? 0
    default:
      return 0
    }
  }

  /// SubexpIndex returns the index of the first subexpression with the given name,
  /// or -1 if there is no subexpression with that name.
  ///
  /// Note that multiple subexpressions can be written using the same name, as in
  /// (?P<bob>a+)(?P<bob>b+), which declares two subexpressions named "bob".
  /// In this case, SubexpIndex returns the index of the leftmost such subexpression
  /// in the regular expression.
  package func subexpIndex(_ name: String) -> Int {
    if !name.isEmpty {
      for (i, s) in subexpNames.enumerated() where name == s {
        return i
      }
    }
    return -1
  }

  /// LiteralPrefix returns a literal string that must begin any match
  /// of the regular expression re. It returns the boolean true if the
  /// literal string comprises the entire regular expression.
  package func literalPrefix() -> (prefix: String, complete: Bool) {
    (GoUTF8.string(prefix), prefixComplete)
  }

  // MARK: - Input helpers

  @inline(__always)
  func withInput<R>(_ s: String, _ body: (Input) throws -> R) rethrows -> R {
    var s = s
    return try s.withUTF8 { try body(Input(buf: $0)) }
  }

  @inline(__always)
  func withInput<R>(_ b: [UInt8], _ body: (Input) throws -> R) rethrows -> R {
    try b.withUnsafeBufferPointer { try body(Input(buf: $0)) }
  }

  @inline(__always)
  static func string(_ i: Input, _ a: Int, _ b: Int) -> String {
    String(decoding: UnsafeBufferPointer(rebasing: i.buf[a..<b]), as: UTF8.self)
  }

  @inline(__always)
  static func bytes(_ i: Input, _ a: Int, _ b: Int) -> [UInt8] {
    Array(i.buf[a..<b])
  }

  // MARK: - Match

  /// MatchString reports whether the string s
  /// contains any match of the regular expression re.
  package func matchString(_ s: String) -> Bool {
    withInput(s) { doExecute($0, 0, 0) != nil }
  }

  /// Match reports whether the byte slice b
  /// contains any match of the regular expression re.
  package func match(_ b: [UInt8]) -> Bool {
    withInput(b) { doExecute($0, 0, 0) != nil }
  }

  /// MatchString reports whether the string s
  /// contains any match of the regular expression pattern.
  package static func matchString(_ pattern: String, _ s: String) throws(RegexpError) -> Bool {
    try compile(pattern).matchString(s)
  }

  /// Match reports whether the byte slice b
  /// contains any match of the regular expression pattern.
  package static func match(_ pattern: String, _ b: [UInt8]) throws(RegexpError) -> Bool {
    try compile(pattern).match(b)
  }

  // MARK: - Replace

  /// ReplaceAllString returns a copy of src, replacing matches of the Regexp
  /// with the replacement string repl.
  /// Inside repl, $ signs are interpreted as in Expand.
  package func replaceAllString(_ src: String, _ repl: String) -> String {
    var n = 2
    if repl.utf8.contains(UInt8(ascii: "$")) {
      n = 2 * (numSubexp + 1)
    }
    let template = Array(repl.utf8)
    return withInput(src) { i in
      GoUTF8.string(
        replaceAll(i, n) { dst, match in
          expand(&dst, template, i, match)
        })
    }
  }

  /// ReplaceAllLiteralString returns a copy of src, replacing matches of the Regexp
  /// with the replacement string repl. The replacement repl is substituted directly,
  /// without using Expand.
  package func replaceAllLiteralString(_ src: String, _ repl: String) -> String {
    let r = Array(repl.utf8)
    return withInput(src) { i in
      GoUTF8.string(replaceAll(i, 2) { dst, _ in dst.append(contentsOf: r) })
    }
  }

  /// ReplaceAllStringFunc returns a copy of src in which all matches of the
  /// Regexp have been replaced by the return value of function repl applied
  /// to the matched substring. The replacement returned by repl is substituted
  /// directly, without using Expand.
  package func replaceAllStringFunc(_ src: String, _ repl: (String) -> String) -> String {
    withInput(src) { i in
      GoUTF8.string(
        replaceAll(i, 2) { dst, match in
          dst.append(contentsOf: repl(Regexp.string(i, match[0], match[1])).utf8)
        })
    }
  }

  /// ReplaceAll returns a copy of src, replacing matches of the Regexp
  /// with the replacement text repl.
  /// Inside repl, $ signs are interpreted as in Expand.
  package func replaceAll(_ src: [UInt8], _ repl: [UInt8]) -> [UInt8] {
    var n = 2
    if repl.contains(UInt8(ascii: "$")) {
      n = 2 * (numSubexp + 1)
    }
    return withInput(src) { i in
      replaceAll(i, n) { dst, match in
        expand(&dst, repl, i, match)
      }
    }
  }

  /// ReplaceAllLiteral returns a copy of src, replacing matches of the Regexp
  /// with the replacement bytes repl. The replacement repl is substituted directly,
  /// without using Expand.
  package func replaceAllLiteral(_ src: [UInt8], _ repl: [UInt8]) -> [UInt8] {
    withInput(src) { i in
      replaceAll(i, 2) { dst, _ in dst.append(contentsOf: repl) }
    }
  }

  /// ReplaceAllFunc returns a copy of src in which all matches of the
  /// Regexp have been replaced by the return value of function repl applied
  /// to the matched byte slice. The replacement returned by repl is substituted
  /// directly, without using Expand.
  package func replaceAllFunc(_ src: [UInt8], _ repl: ([UInt8]) -> [UInt8]) -> [UInt8] {
    withInput(src) { i in
      replaceAll(i, 2) { dst, match in
        dst.append(contentsOf: repl(Regexp.bytes(i, match[0], match[1])))
      }
    }
  }

  func replaceAll(_ i: Input, _ nmatch0: Int, _ repl: (inout [UInt8], [Int]) -> Void) -> [UInt8] {
    var lastMatchEnd = 0  // end position of the most recent match
    var searchPos = 0  // position where we next look for a match
    var buf: [UInt8] = []
    let endPos = i.count
    var nmatch = nmatch0
    if nmatch > prog.numCap {
      nmatch = prog.numCap
    }

    while searchPos <= endPos {
      guard let a = doExecute(i, searchPos, nmatch), !a.isEmpty else {
        break  // no more matches
      }

      // Copy the unmatched characters before this match.
      buf.append(contentsOf: i.buf[lastMatchEnd..<a[0]])

      // Now insert a copy of the replacement string, but not for a
      // match of the empty string immediately after another match.
      // (Otherwise, we get double replacement for patterns that
      // match both empty and nonempty strings.)
      if a[1] > lastMatchEnd || a[0] == 0 {
        repl(&buf, a)
      }
      lastMatchEnd = a[1]

      // Advance past this match; always advance at least one character.
      let width = searchPos < endPos ? GoUTF8.decodeRune(i.buf, at: searchPos).1 : 0
      if searchPos + width > a[1] {
        searchPos += width
      } else if searchPos + 1 > a[1] {
        // This clause is only needed at the end of the input
        // string. In that case, DecodeRuneInString returns width=0.
        searchPos += 1
      } else {
        searchPos = a[1]
      }
    }

    // Copy the unmatched characters after the last match.
    buf.append(contentsOf: i.buf[lastMatchEnd...])

    return buf
  }

  // MARK: - QuoteMeta

  /// special reports whether byte b needs to be escaped by QuoteMeta.
  private static func special(_ b: UInt8) -> Bool {
    switch b {
    case UInt8(ascii: "\\"), UInt8(ascii: "."), UInt8(ascii: "+"), UInt8(ascii: "*"), UInt8(ascii: "?"),
      UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "|"), UInt8(ascii: "["), UInt8(ascii: "]"),
      UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: "^"), UInt8(ascii: "$"):
      return true
    default:
      return false
    }
  }

  /// QuoteMeta returns a string that escapes all regular expression metacharacters
  /// inside the argument text; the returned string is a regular expression matching
  /// the literal text.
  package static func quoteMeta(_ s: String) -> String {
    GoUTF8.string(quoteMeta(bytes: Array(s.utf8)))
  }

  /// QuoteMeta over raw bytes.
  package static func quoteMeta(bytes s: [UInt8]) -> [UInt8] {
    // A byte loop is correct because all metacharacters are ASCII.
    var b: [UInt8] = []
    b.reserveCapacity(s.count)
    for c in s {
      if special(c) {
        b.append(UInt8(ascii: "\\"))
      }
      b.append(c)
    }
    return b
  }

  // MARK: - Find

  /// The number of capture values in the program may correspond
  /// to fewer capturing expressions than are in the regexp.
  /// For example, "(a){0}" turns into an empty program, so the
  /// maximum capture in the program is 0 but we need to return
  /// an expression for \1.  Pad appends -1s to the slice a as needed.
  func pad(_ a: [Int]?) -> [Int]? {
    guard var a else {
      // No match.
      return nil
    }
    let n = (1 + numSubexp) * 2
    while a.count < n {
      a.append(-1)
    }
    return a
  }

  /// allMatches calls deliver at most n times
  /// with the location of successive matches in the input text.
  func allMatches(_ i: Input, _ n: Int, _ deliver: ([Int]) -> Void) {
    let end = i.count
    var pos = 0
    var count = 0
    var prevMatchEnd = -1
    while count < n && pos <= end {
      guard let matches = doExecute(i, pos, prog.numCap), !matches.isEmpty else {
        break
      }

      var accept = true
      if matches[1] == pos {
        // We've found an empty match.
        if matches[0] == prevMatchEnd {
          // We don't allow an empty match right
          // after a previous match, so ignore it.
          accept = false
        }
        let (_, width) = i.step(pos)
        if width > 0 {
          pos += width
        } else {
          pos = end + 1
        }
      } else {
        pos = matches[1]
      }
      prevMatchEnd = matches[1]

      if accept, let padded = pad(matches) {
        deliver(padded)
        count += 1
      }
    }
  }

  /// Find returns a slice holding the text of the leftmost match in b of the regular expression.
  /// A return value of nil indicates no match.
  package func find(_ b: [UInt8]) -> [UInt8]? {
    withInput(b) { i in
      guard let a = doExecute(i, 0, 2) else { return nil }
      return Regexp.bytes(i, a[0], a[1])
    }
  }

  /// FindIndex returns a two-element slice of integers defining the location of
  /// the leftmost match in b of the regular expression. The match itself is at
  /// b[loc[0]..<loc[1]].
  /// A return value of nil indicates no match.
  package func findIndex(_ b: [UInt8]) -> [Int]? {
    withInput(b) { i in
      guard let a = doExecute(i, 0, 2) else { return nil }
      return Array(a[0..<2])
    }
  }

  /// FindString returns a string holding the text of the leftmost match in s of the regular
  /// expression. If there is no match, the return value is an empty string,
  /// but it will also be empty if the regular expression successfully matches
  /// an empty string. Use findStringIndex or findStringSubmatch if it is
  /// necessary to distinguish these cases.
  package func findString(_ s: String) -> String {
    withInput(s) { i in
      guard let a = doExecute(i, 0, 2) else { return "" }
      return Regexp.string(i, a[0], a[1])
    }
  }

  /// FindStringIndex returns a two-element slice of integers defining the
  /// location of the leftmost match in s of the regular expression, as UTF-8 byte offsets.
  /// A return value of nil indicates no match.
  package func findStringIndex(_ s: String) -> [Int]? {
    withInput(s) { i in
      guard let a = doExecute(i, 0, 2) else { return nil }
      return Array(a[0..<2])
    }
  }

  /// FindSubmatch returns a slice of slices holding the text of the leftmost
  /// match of the regular expression in b and the matches, if any, of its
  /// subexpressions. Unmatched subexpressions are nil.
  /// A return value of nil indicates no match.
  package func findSubmatch(_ b: [UInt8]) -> [[UInt8]?]? {
    withInput(b) { i in
      guard let a = doExecute(i, 0, prog.numCap) else { return nil }
      var ret = [[UInt8]?](repeating: nil, count: 1 + numSubexp)
      for k in ret.indices where 2 * k < a.count && a[2 * k] >= 0 {
        ret[k] = Regexp.bytes(i, a[2 * k], a[2 * k + 1])
      }
      return ret
    }
  }

  /// FindSubmatchIndex returns a slice holding the index pairs identifying the
  /// leftmost match of the regular expression in b and the matches, if any, of
  /// its subexpressions. Unmatched subexpressions have index -1.
  /// A return value of nil indicates no match.
  package func findSubmatchIndex(_ b: [UInt8]) -> [Int]? {
    withInput(b) { pad(doExecute($0, 0, prog.numCap)) }
  }

  /// FindStringSubmatch returns a slice of strings holding the text of the
  /// leftmost match of the regular expression in s and the matches, if any, of
  /// its subexpressions. Unmatched subexpressions are "".
  /// A return value of nil indicates no match.
  package func findStringSubmatch(_ s: String) -> [String]? {
    withInput(s) { i in
      guard let a = doExecute(i, 0, prog.numCap) else { return nil }
      var ret = [String](repeating: "", count: 1 + numSubexp)
      for k in ret.indices where 2 * k < a.count && a[2 * k] >= 0 {
        ret[k] = Regexp.string(i, a[2 * k], a[2 * k + 1])
      }
      return ret
    }
  }

  /// FindStringSubmatchIndex returns a slice holding the index pairs
  /// identifying the leftmost match of the regular expression in s and the
  /// matches, if any, of its subexpressions. Unmatched subexpressions have index -1.
  /// A return value of nil indicates no match.
  package func findStringSubmatchIndex(_ s: String) -> [Int]? {
    withInput(s) { pad(doExecute($0, 0, prog.numCap)) }
  }

  /// FindAll is the 'All' version of Find; it returns a slice of all successive
  /// matches of the expression. If n >= 0, it returns at most n matches.
  /// No matches give an empty array (Go returns nil).
  package func findAll(_ b: [UInt8], _ n: Int = -1) -> [[UInt8]] {
    let n = n < 0 ? b.count + 1 : n
    var result: [[UInt8]] = []
    withInput(b) { i in
      allMatches(i, n) { match in
        result.append(Regexp.bytes(i, match[0], match[1]))
      }
    }
    return result
  }

  /// FindAllIndex is the 'All' version of FindIndex.
  package func findAllIndex(_ b: [UInt8], _ n: Int = -1) -> [[Int]] {
    let n = n < 0 ? b.count + 1 : n
    var result: [[Int]] = []
    withInput(b) { i in
      allMatches(i, n) { match in
        result.append(Array(match[0..<2]))
      }
    }
    return result
  }

  /// FindAllString is the 'All' version of FindString; it returns a slice of all successive
  /// matches of the expression. If n >= 0, it returns at most n matches.
  package func findAllString(_ s: String, _ n: Int = -1) -> [String] {
    let n = n < 0 ? s.utf8.count + 1 : n
    var result: [String] = []
    withInput(s) { i in
      allMatches(i, n) { match in
        result.append(Regexp.string(i, match[0], match[1]))
      }
    }
    return result
  }

  /// FindAllStringIndex is the 'All' version of FindStringIndex.
  package func findAllStringIndex(_ s: String, _ n: Int = -1) -> [[Int]] {
    let n = n < 0 ? s.utf8.count + 1 : n
    var result: [[Int]] = []
    withInput(s) { i in
      allMatches(i, n) { match in
        result.append(Array(match[0..<2]))
      }
    }
    return result
  }

  /// FindAllSubmatch is the 'All' version of FindSubmatch.
  package func findAllSubmatch(_ b: [UInt8], _ n: Int = -1) -> [[[UInt8]?]] {
    let n = n < 0 ? b.count + 1 : n
    var result: [[[UInt8]?]] = []
    withInput(b) { i in
      allMatches(i, n) { match in
        var slice = [[UInt8]?](repeating: nil, count: match.count / 2)
        for j in slice.indices where match[2 * j] >= 0 {
          slice[j] = Regexp.bytes(i, match[2 * j], match[2 * j + 1])
        }
        result.append(slice)
      }
    }
    return result
  }

  /// FindAllSubmatchIndex is the 'All' version of FindSubmatchIndex.
  package func findAllSubmatchIndex(_ b: [UInt8], _ n: Int = -1) -> [[Int]] {
    let n = n < 0 ? b.count + 1 : n
    var result: [[Int]] = []
    withInput(b) { i in
      allMatches(i, n) { result.append($0) }
    }
    return result
  }

  /// FindAllStringSubmatch is the 'All' version of FindStringSubmatch.
  package func findAllStringSubmatch(_ s: String, _ n: Int = -1) -> [[String]] {
    let n = n < 0 ? s.utf8.count + 1 : n
    var result: [[String]] = []
    withInput(s) { i in
      allMatches(i, n) { match in
        var slice = [String](repeating: "", count: match.count / 2)
        for j in slice.indices where match[2 * j] >= 0 {
          slice[j] = Regexp.string(i, match[2 * j], match[2 * j + 1])
        }
        result.append(slice)
      }
    }
    return result
  }

  /// FindAllStringSubmatchIndex is the 'All' version of FindStringSubmatchIndex.
  package func findAllStringSubmatchIndex(_ s: String, _ n: Int = -1) -> [[Int]] {
    let n = n < 0 ? s.utf8.count + 1 : n
    var result: [[Int]] = []
    withInput(s) { i in
      allMatches(i, n) { result.append($0) }
    }
    return result
  }

  // MARK: - Expand

  /// Expand appends template to dst and returns the result; during the
  /// append, Expand replaces variables in the template with corresponding
  /// matches drawn from src. The match slice should have been returned by
  /// FindSubmatchIndex.
  ///
  /// In the template, a variable is denoted by a substring of the form
  /// $name or ${name}, where name is a non-empty sequence of letters,
  /// digits, and underscores. A purely numeric name like $1 refers to
  /// the submatch with the corresponding index; other names refer to
  /// capturing parentheses named with the (?P<name>...) syntax. A
  /// reference to an out of range or unmatched index or a name that is not
  /// present in the regular expression is replaced with an empty slice.
  ///
  /// In the $name form, name is taken to be as long as possible: $1x is
  /// equivalent to ${1x}, not ${1}x, and, $10 is equivalent to ${10}, not ${1}0.
  ///
  /// To insert a literal $ in the output, use $$ in the template.
  package func expand(_ dst: [UInt8], _ template: [UInt8], _ src: [UInt8], _ match: [Int]) -> [UInt8] {
    var dst = dst
    withInput(src) { i in
      expand(&dst, template, i, match)
    }
    return dst
  }

  /// ExpandString is like Expand but the template and source are strings.
  package func expandString(_ dst: [UInt8], _ template: String, _ src: String, _ match: [Int]) -> [UInt8] {
    var dst = dst
    let t = Array(template.utf8)
    withInput(src) { i in
      expand(&dst, t, i, match)
    }
    return dst
  }

  func expand(_ dst: inout [UInt8], _ template0: [UInt8], _ src: Input, _ match: [Int]) {
    var template = template0[...]
    while !template.isEmpty {
      guard let dollar = template.firstIndex(of: UInt8(ascii: "$")) else {
        break
      }
      dst.append(contentsOf: template[..<dollar])
      template = template[(dollar + 1)...]
      if let f = template.first, f == UInt8(ascii: "$") {
        // Treat $$ as $.
        dst.append(UInt8(ascii: "$"))
        template = template.dropFirst()
        continue
      }
      guard let (name, num, rest) = Regexp.extract(template) else {
        // Malformed; treat $ as raw text.
        dst.append(UInt8(ascii: "$"))
        continue
      }
      template = rest
      if num >= 0 {
        if 2 * num + 1 < match.count && match[2 * num] >= 0 {
          dst.append(contentsOf: src.buf[match[2 * num]..<match[2 * num + 1]])
        }
      } else {
        let nameStr = GoUTF8.string(name)
        for (i, namei) in subexpNames.enumerated()
        where nameStr == namei && 2 * i + 1 < match.count && match[2 * i] >= 0 {
          dst.append(contentsOf: src.buf[match[2 * i]..<match[2 * i + 1]])
          break
        }
      }
    }
    dst.append(contentsOf: template)
  }

  /// extract returns the name from a leading "name" or "{name}" in str.
  /// (The $ has already been removed by the caller.)
  /// If it is a number, extract returns num set to that number; otherwise num = -1.
  static func extract(_ str0: ArraySlice<UInt8>) -> (name: ArraySlice<UInt8>, num: Int, rest: ArraySlice<UInt8>)? {
    var str = str0
    if str.isEmpty {
      return nil
    }
    var brace = false
    if str.first == UInt8(ascii: "{") {
      brace = true
      str = str.dropFirst()
    }
    let s = Array(str)
    var i = 0
    s.withUnsafeBufferPointer { p in
      while i < p.count {
        let (rune, size) = GoUTF8.decodeRune(p, at: i)
        if !UnicodeTables.isLetter(rune) && !UnicodeTables.isDigit(rune) && rune != 0x5F {
          break
        }
        i += size
      }
    }
    if i == 0 {
      // empty name is not okay
      return nil
    }
    let name = s[..<i]
    if brace {
      if i >= s.count || s[i] != UInt8(ascii: "}") {
        // missing closing brace
        return nil
      }
      i += 1
    }

    // Parse number.
    var num = 0
    for c in name {
      if c < UInt8(ascii: "0") || UInt8(ascii: "9") < c || num >= 100_000_000 {
        num = -1
        break
      }
      num = num * 10 + Int(c) - 0x30
    }
    // Disallow leading zeros.
    if name.first == UInt8(ascii: "0") && name.count > 1 {
      num = -1
    }

    return (name, num, s[i...])
  }

  // MARK: - Split

  /// Split slices s into substrings separated by the expression and returns a slice of
  /// the substrings between those expression matches.
  ///
  /// The count determines the number of substrings to return:
  ///   - n > 0: at most n substrings; the last substring will be the unsplit remainder;
  ///   - n == 0: the result is empty (zero substrings);
  ///   - n < 0: all substrings.
  package func split(_ s: String, _ n: Int) -> [String] {
    if n == 0 {
      return []
    }

    if !expr.isEmpty && s.isEmpty {
      return [""]
    }

    let matches = findAllStringIndex(s, n)
    var strings: [String] = []

    var beg = 0
    var end = 0
    withInput(s) { i in
      for match in matches {
        if n > 0 && strings.count >= n - 1 {
          break
        }

        end = match[0]
        if match[1] != 0 {
          strings.append(Regexp.string(i, beg, end))
        }
        beg = match[1]
      }

      if end != i.count {
        strings.append(Regexp.string(i, beg, i.count))
      }
    }
    return strings
  }
}
