// Copyright 2011 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// Port of Go's regexp/syntax/parse.go.
//
// The pattern is parsed as UTF-8 bytes; where Go slices the remaining pattern string, this port
// keeps byte offsets into the pattern.

extension Syntax {
  /// An ErrorCode describes a failure to parse a regular expression.
  package struct ErrorCode: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    package var rawValue: String
    package init(rawValue: String) { self.rawValue = rawValue }
    package var description: String { rawValue }

    // Unexpected error
    package static let internalError = ErrorCode(rawValue: "regexp/syntax: internal error")

    // Parse errors
    package static let invalidCharClass = ErrorCode(rawValue: "invalid character class")
    package static let invalidCharRange = ErrorCode(rawValue: "invalid character class range")
    package static let invalidEscape = ErrorCode(rawValue: "invalid escape sequence")
    package static let invalidNamedCapture = ErrorCode(rawValue: "invalid named capture")
    package static let invalidPerlOp = ErrorCode(rawValue: "invalid or unsupported Perl syntax")
    package static let invalidRepeatOp = ErrorCode(rawValue: "invalid nested repetition operator")
    package static let invalidRepeatSize = ErrorCode(rawValue: "invalid repeat count")
    package static let invalidUTF8 = ErrorCode(rawValue: "invalid UTF-8")
    package static let missingBracket = ErrorCode(rawValue: "missing closing ]")
    package static let missingParen = ErrorCode(rawValue: "missing closing )")
    package static let missingRepeatArgument = ErrorCode(rawValue: "missing argument to repetition operator")
    package static let trailingBackslash = ErrorCode(rawValue: "trailing backslash at end of expression")
    package static let unexpectedParen = ErrorCode(rawValue: "unexpected )")
    package static let nestingDepth = ErrorCode(rawValue: "expression nests too deeply")
    package static let large = ErrorCode(rawValue: "expression too large")
  }

  /// An Error describes a failure to parse a regular expression
  /// and gives the offending expression.
  package struct ParseError: Error, Hashable, Sendable, CustomStringConvertible {
    package var code: ErrorCode
    package var expr: String

    package init(code: ErrorCode, expr: String) {
      self.code = code
      self.expr = expr
    }

    init(_ code: ErrorCode, _ expr: some Collection<UInt8>) {
      self.code = code
      self.expr = GoUTF8.string(expr)
    }

    package var description: String {
      "error parsing regexp: " + code.rawValue + ": `" + expr + "`"
    }
  }

  /// Flags control the behavior of the parser and record information about regexp context.
  package struct Flags: OptionSet, Hashable, Sendable {
    package var rawValue: UInt16
    package init(rawValue: UInt16) { self.rawValue = rawValue }

    package static let foldCase = Flags(rawValue: 1 << 0)  // case-insensitive match
    package static let literal = Flags(rawValue: 1 << 1)  // treat pattern as literal string
    package static let classNL = Flags(rawValue: 1 << 2)  // allow character classes like [^a-z] and [[:space:]] to match newline
    package static let dotNL = Flags(rawValue: 1 << 3)  // allow . to match newline
    package static let oneLine = Flags(rawValue: 1 << 4)  // treat ^ and $ as only matching at beginning and end of text
    package static let nonGreedy = Flags(rawValue: 1 << 5)  // make repetition operators default to non-greedy
    package static let perlX = Flags(rawValue: 1 << 6)  // allow Perl extensions
    package static let unicodeGroups = Flags(rawValue: 1 << 7)  // allow \p{Han}, \P{Han} for Unicode group and negation
    package static let wasDollar = Flags(rawValue: 1 << 8)  // regexp OpEndText was $, not \z
    package static let simple = Flags(rawValue: 1 << 9)  // regexp contains no counted repetition

    package static let matchNL: Flags = [.classNL, .dotNL]

    package static let perl: Flags = [.classNL, .oneLine, .perlX, .unicodeGroups]  // as close to Perl as possible
    package static let posix: Flags = []  // POSIX syntax
  }

  /// maxHeight is the maximum height of a regexp parse tree.
  /// It is somewhat arbitrarily chosen, but the idea is to be large enough
  /// that no one will actually hit in real use but at the same time small enough
  /// that recursion on the Regexp tree will not hit the stack limit.
  /// As an optimization, we don't even bother calculating heights
  /// until we've allocated at least maxHeight Regexp structures.
  static let maxHeight = 1000

  /// maxSize is the maximum size of a compiled regexp in Insts.
  static let instSize: Int64 = 5 * 8  // byte, 2 uint32, slice is 5 64-bit words
  static let maxSize: Int64 = (128 << 20) / instSize

  /// maxRunes is the maximum number of runes allowed in a regexp tree
  /// counting the runes in all the nodes.
  static let runeSize = 4  // rune is int32
  static let maxRunes = (128 << 20) / runeSize

  // minimum and maximum runes involved in folding.
  // checked during test.
  static let minFold: Rune = 0x0041
  static let maxFold: Rune = 0x1e943

  /// Parse parses a regular expression string s, controlled by the specified
  /// Flags, and returns a regular expression parse tree.
  package static func parse(_ s: String, _ flags: Flags) throws(ParseError) -> Regexp {
    try parse(bytes: Array(s.utf8), flags)
  }

  /// Parse over raw bytes, which may hold invalid UTF-8.
  package static func parse(bytes s: [UInt8], _ flags: Flags) throws(ParseError) -> Regexp {
    do {
      return try parseImpl(s, flags)
    } catch let e as LimitError {
      throw ParseError(e.code, s)
    } catch let e as ParseError {
      throw e
    } catch {
      throw ParseError(.internalError, s)
    }
  }

  /// Raised by the size and height checks; Go panics with the bare ErrorCode and parse recovers it.
  struct LimitError: Error {
    var code: ErrorCode
  }

  private static func parseImpl(_ s: [UInt8], _ flags: Flags) throws -> Regexp {
    if flags.contains(.literal) {
      // Trivial parser for literal string.
      try checkUTF8(s, 0, s.count)
      return literalRegexp(s, flags)
    }

    // Otherwise, must do real work.
    let p = Parser(s, flags)
    var lastRepeat: Int? = nil
    var t = 0
    let end = s.count
    while t < end {
      var repeatPos: Int? = nil
      bigSwitch: switch s[t] {
      case UInt8(ascii: "("):
        if p.flags.contains(.perlX) && end - t >= 2 && s[t + 1] == UInt8(ascii: "?") {
          // Flag changes and non-capturing groups.
          t = try p.parsePerlFlags(t)
          break
        }
        p.numCap += 1
        try p.op(.leftParen)?.cap = p.numCap
        t += 1
      case UInt8(ascii: "|"):
        try p.parseVerticalBar()
        t += 1
      case UInt8(ascii: ")"):
        try p.parseRightParen()
        t += 1
      case UInt8(ascii: "^"):
        if p.flags.contains(.oneLine) {
          try p.op(.beginText)
        } else {
          try p.op(.beginLine)
        }
        t += 1
      case UInt8(ascii: "$"):
        if p.flags.contains(.oneLine) {
          try p.op(.endText)?.flags.formUnion(.wasDollar)
        } else {
          try p.op(.endLine)
        }
        t += 1
      case UInt8(ascii: "."):
        if p.flags.contains(.dotNL) {
          try p.op(.anyChar)
        } else {
          try p.op(.anyCharNotNL)
        }
        t += 1
      case UInt8(ascii: "["):
        t = try p.parseClass(t)
      case UInt8(ascii: "*"), UInt8(ascii: "+"), UInt8(ascii: "?"):
        let before = t
        let op: Op
        switch s[t] {
        case UInt8(ascii: "*"): op = .star
        case UInt8(ascii: "+"): op = .plus
        default: op = .quest
        }
        let after = try p.repeat(op, 0, 0, before: before, after: t + 1, lastRepeat: lastRepeat)
        repeatPos = before
        t = after
      case UInt8(ascii: "{"):
        let before = t
        guard let (min, max, after) = p.parseRepeat(t) else {
          // If the repeat cannot be parsed, { is a literal.
          try p.literal(0x7B)
          t += 1
          break
        }
        if min < 0 || min > 1000 || max > 1000 || max >= 0 && min > max {
          // Numbers were too big, or max is present and min > max.
          throw ParseError(.invalidRepeatSize, s[before..<after])
        }
        let after2 = try p.repeat(.repeat, min, max, before: before, after: after, lastRepeat: lastRepeat)
        repeatPos = before
        t = after2
      case UInt8(ascii: "\\"):
        if p.flags.contains(.perlX) && end - t >= 2 {
          switch s[t + 1] {
          case UInt8(ascii: "A"):
            try p.op(.beginText)
            t += 2
            break bigSwitch
          case UInt8(ascii: "b"):
            try p.op(.wordBoundary)
            t += 2
            break bigSwitch
          case UInt8(ascii: "B"):
            try p.op(.noWordBoundary)
            t += 2
            break bigSwitch
          case UInt8(ascii: "C"):
            // any byte; not supported
            throw ParseError(.invalidEscape, s[t..<(t + 2)])
          case UInt8(ascii: "Q"):
            // \Q ... \E: the ... is always literals
            var litEnd = end
            var rest = end
            var i = t + 2
            while i + 1 < end {
              if s[i] == UInt8(ascii: "\\") && s[i + 1] == UInt8(ascii: "E") {
                litEnd = i
                rest = i + 2
                break
              }
              i += 1
            }
            var lit = t + 2
            while lit < litEnd {
              let (c, next) = try nextRune(s, lit, litEnd)
              try p.literal(c)
              lit = next
            }
            t = rest
            break bigSwitch
          case UInt8(ascii: "z"):
            try p.op(.endText)
            t += 2
            break bigSwitch
          default:
            break
          }
        }

        let re = p.newRegexp(.charClass)
        re.flags = p.flags

        // Look for Unicode character group like \p{Han}
        if end - t >= 2 && (s[t + 1] == UInt8(ascii: "p") || s[t + 1] == UInt8(ascii: "P")) {
          var r: [Rune] = []
          if let rest = try p.parseUnicodeClass(t, &r) {
            re.rune = r
            t = rest
            try p.push(re)
            break bigSwitch
          }
        }

        // Perl character class escape.
        var r: [Rune] = []
        if let rest = p.parsePerlClassEscape(t, &r) {
          re.rune = r
          t = rest
          try p.push(re)
          break bigSwitch
        }
        p.reuse(re)

        // Ordinary single-character escape.
        let (c, rest) = try p.parseEscape(t)
        t = rest
        try p.literal(c)
      default:
        let (c, rest) = try nextRune(s, t, end)
        t = rest
        try p.literal(c)
      }
      lastRepeat = repeatPos
    }

    try p.concat()
    if try p.swapVerticalBar() {
      // pop vertical bar
      p.stack.removeLast()
    }
    try p.alternate()

    if p.stack.count != 1 {
      throw ParseError(.missingParen, s)
    }
    return p.stack[0]
  }

  static func literalRegexp(_ s: [UInt8], _ flags: Flags) -> Regexp {
    let re = Regexp(op: .literal, flags: flags)
    re.rune = GoUTF8.runes(s)
    return re
  }

  // MARK: - Parser

  final class Parser {
    var flags: Flags  // parse mode flags
    var stack: [Regexp] = []  // stack of parsed expressions
    var free: Regexp?
    var numCap = 0  // number of capturing groups seen
    let wholeRegexp: [UInt8]
    var tmpClass: [Rune] = []  // temporary char class work space
    var numRegexp = 0  // number of regexps allocated
    var numRunes = 0  // number of runes in char classes
    var repeats: Int64 = 0  // product of all repetitions seen
    var height: [ObjectIdentifier: Int]?  // regexp height, for height limit check
    var size: [ObjectIdentifier: Int64]?  // regexp compiled size, for size limit check
    /// Keeps every allocated node alive so that ObjectIdentifier keys in height/size stay unique,
    /// as Go's pointer keys do.
    private var allocated: [Regexp] = []
    var s: [UInt8] { wholeRegexp }

    init(_ s: [UInt8], _ flags: Flags) {
      self.wholeRegexp = s
      self.flags = flags
    }

    func newRegexp(_ op: Op) -> Regexp {
      let re: Regexp
      if let f = free {
        free = f.nextFree
        f.reset()
        re = f
      } else {
        re = Regexp()
        allocated.append(re)
        numRegexp += 1
      }
      re.op = op
      return re
    }

    func reuse(_ re: Regexp) {
      height?[ObjectIdentifier(re)] = nil
      re.nextFree = free
      free = re
    }

    func checkLimits(_ re: Regexp) throws {
      if numRunes > Syntax.maxRunes {
        throw LimitError(code: .large)
      }
      try checkSize(re)
      try checkHeight(re)
    }

    func checkSize(_ re: Regexp) throws {
      if size == nil {
        // We haven't started tracking size yet.
        // Do a relatively cheap check to see if we need to start.
        // Maintain the product of all the repeats we've seen
        // and don't track if the total number of regexp nodes
        // we've seen times the repeat product is in budget.
        if repeats == 0 {
          repeats = 1
        }
        if re.op == .repeat {
          var n = re.max
          if n == -1 {
            n = re.min
          }
          if n <= 0 {
            n = 1
          }
          if Int64(n) > Syntax.maxSize / repeats {
            repeats = Syntax.maxSize
          } else {
            repeats *= Int64(n)
          }
        }
        if Int64(numRegexp) < Syntax.maxSize / repeats {
          return
        }

        // We need to start tracking size.
        // Make the map and belatedly populate it
        // with info about everything we've constructed so far.
        size = [:]
        for re in stack {
          try checkSize(re)
        }
      }

      if calcSize(re, true) > Syntax.maxSize {
        throw LimitError(code: .large)
      }
    }

    /// Go's recursive calcSize, run with an explicit stack (the tree may be up to maxHeight
    /// deep). Children are visited in Go's order and memoized the same way. Arithmetic wraps
    /// like Go's int64.
    func calcSize(_ root: Regexp, _ force: Bool) -> Int64 {
      if !force {
        if let size = size?[ObjectIdentifier(root)] {
          return size
        }
      }
      var stack: [(re: Regexp, next: Int, sizes: [Int64])] = [(root, 0, [])]
      while true {
        let top = stack.count - 1
        let re = stack[top].re
        if stack[top].next < calcSizeChildren(re) {
          let child = re.sub[stack[top].next]
          stack[top].next += 1
          if let s = size?[ObjectIdentifier(child)] {
            stack[top].sizes.append(s)
          } else {
            stack.append((child, 0, []))
          }
          continue
        }
        let s = calcSizeStep(re, stack[top].sizes)
        self.size?[ObjectIdentifier(re)] = s
        stack.removeLast()
        if stack.isEmpty {
          return s
        }
        stack[stack.count - 1].sizes.append(s)
      }
    }

    /// The number of children Go's calcSize consults.
    private func calcSizeChildren(_ re: Regexp) -> Int {
      switch re.op {
      case .capture, .star, .plus, .quest, .repeat:
        return 1
      case .concat, .alternate:
        return re.sub.count
      default:
        return 0
      }
    }

    /// One step of Go's calcSize, given the sizes of the children.
    private func calcSizeStep(_ re: Regexp, _ subs: [Int64]) -> Int64 {
      var size: Int64 = 0
      switch re.op {
      case .literal:
        size = Int64(re.rune.count)
      case .capture, .star:
        // star can be 1+ or 2+; assume 2 pessimistically
        size = 2 &+ subs[0]
      case .plus, .quest:
        size = 1 &+ subs[0]
      case .concat:
        for s in subs {
          size = size &+ s
        }
      case .alternate:
        for s in subs {
          size = size &+ s
        }
        if re.sub.count > 1 {
          size = size &+ (Int64(re.sub.count) - 1)
        }
      case .repeat:
        let sub = subs[0]
        if re.max == -1 {
          if re.min == 0 {
            size = 2 &+ sub  // x*
          } else {
            size = 1 &+ Int64(re.min) &* sub  // xxx+
          }
          break
        }
        // x{2,5} = xx(x(x(x)?)?)?
        size = Int64(re.max) &* sub &+ Int64(re.max - re.min)
      default:
        break
      }
      return Swift.max(1, size)
    }

    func checkHeight(_ re: Regexp) throws {
      if numRegexp < Syntax.maxHeight {
        return
      }
      if height == nil {
        height = [:]
        for re in stack {
          try checkHeight(re)
        }
      }
      if calcHeight(re, true) > Syntax.maxHeight {
        throw LimitError(code: .nestingDepth)
      }
    }

    /// Go's recursive calcHeight, run with an explicit stack and the same memoization.
    func calcHeight(_ root: Regexp, _ force: Bool) -> Int {
      if !force {
        if let h = height?[ObjectIdentifier(root)] {
          return h
        }
      }
      var stack: [(re: Regexp, next: Int, h: Int)] = [(root, 0, 1)]
      while true {
        let top = stack.count - 1
        let re = stack[top].re
        if stack[top].next < re.sub.count {
          let child = re.sub[stack[top].next]
          stack[top].next += 1
          if let hsub = height?[ObjectIdentifier(child)] {
            stack[top].h = Swift.max(stack[top].h, 1 + hsub)
          } else {
            stack.append((child, 0, 1))
          }
          continue
        }
        let h = stack[top].h
        height?[ObjectIdentifier(re)] = h
        stack.removeLast()
        if stack.isEmpty {
          return h
        }
        stack[stack.count - 1].h = Swift.max(stack[stack.count - 1].h, 1 + h)
      }
    }

    // Parse stack manipulation.

    /// push pushes the regexp re onto the parse stack and returns the regexp.
    @discardableResult
    func push(_ re: Regexp) throws -> Regexp? {
      numRunes += re.rune.count
      if re.op == .charClass && re.rune.count == 2 && re.rune[0] == re.rune[1] {
        // Single rune.
        if maybeConcat(re.rune[0], flags.subtracting(.foldCase)) {
          return nil
        }
        re.op = .literal
        re.rune = [re.rune[0]]
        re.flags = flags.subtracting(.foldCase)
      } else if re.op == .charClass && re.rune.count == 4 && re.rune[0] == re.rune[1]
        && re.rune[2] == re.rune[3] && UnicodeTables.simpleFold(re.rune[0]) == re.rune[2]
        && UnicodeTables.simpleFold(re.rune[2]) == re.rune[0]
        || re.op == .charClass && re.rune.count == 2 && re.rune[0] + 1 == re.rune[1]
          && UnicodeTables.simpleFold(re.rune[0]) == re.rune[1]
          && UnicodeTables.simpleFold(re.rune[1]) == re.rune[0]
      {
        // Case-insensitive rune like [Aa] or [Δδ].
        if maybeConcat(re.rune[0], flags.union(.foldCase)) {
          return nil
        }

        // Rewrite as (case-insensitive) literal.
        re.op = .literal
        re.rune = [re.rune[0]]
        re.flags = flags.union(.foldCase)
      } else {
        // Incremental concatenation.
        _ = maybeConcat(-1, [])
      }

      stack.append(re)
      try checkLimits(re)
      return re
    }

    /// maybeConcat implements incremental concatenation
    /// of literal runes into string nodes. The parser calls this
    /// before each push, so only the top fragment of the stack
    /// might need processing. Since this is called before a push,
    /// the topmost literal is no longer subject to operators like *
    /// (Otherwise ab* would turn into (ab)*.)
    /// If r >= 0 and there's a node left over, maybeConcat uses it
    /// to push r with the given flags.
    /// maybeConcat reports whether r was pushed.
    func maybeConcat(_ r: Rune, _ flags: Flags) -> Bool {
      let n = stack.count
      if n < 2 {
        return false
      }

      let re1 = stack[n - 1]
      let re2 = stack[n - 2]
      if re1.op != .literal || re2.op != .literal
        || re1.flags.intersection(.foldCase) != re2.flags.intersection(.foldCase)
      {
        return false
      }

      // Push re1 into re2.
      re2.rune.append(contentsOf: re1.rune)

      // Reuse re1 if possible.
      if r >= 0 {
        re1.rune = [r]
        re1.flags = flags
        return true
      }

      stack.removeLast()
      reuse(re1)
      return false  // did not push r
    }

    /// literal pushes a literal regexp for the rune r on the stack.
    func literal(_ r: Rune) throws {
      let re = newRegexp(.literal)
      re.flags = flags
      var r = r
      if flags.contains(.foldCase) {
        r = Syntax.minFoldRune(r)
      }
      re.rune = [r]
      try push(re)
    }

    /// op pushes a regexp with the given op onto the stack
    /// and returns that regexp.
    @discardableResult
    func op(_ op: Op) throws -> Regexp? {
      let re = newRegexp(op)
      re.flags = flags
      return try push(re)
    }

    /// repeat replaces the top stack element with itself repeated according to op, min, max.
    /// before is the regexp suffix starting at the repetition operator.
    /// after is the regexp suffix following after the repetition operator.
    /// repeat returns an updated 'after' and an error, if any.
    func `repeat`(_ op: Op, _ min: Int, _ max: Int, before: Int, after: Int, lastRepeat: Int?) throws -> Int {
      var after = after
      var flags = self.flags
      if self.flags.contains(.perlX) {
        if after < s.count && s[after] == UInt8(ascii: "?") {
          after += 1
          flags.formSymmetricDifference(.nonGreedy)
        }
        if let lastRepeat {
          // In Perl it is not allowed to stack repetition operators:
          // a** is a syntax error, not a doubled star, and a++ means
          // something else entirely, which we don't support!
          throw ParseError(.invalidRepeatOp, s[lastRepeat..<after])
        }
      }
      let n = stack.count
      if n == 0 {
        throw ParseError(.missingRepeatArgument, s[before..<after])
      }
      let sub = stack[n - 1]
      if sub.op >= .pseudo {
        throw ParseError(.missingRepeatArgument, s[before..<after])
      }

      let re = newRegexp(op)
      re.min = min
      re.max = max
      re.flags = flags
      re.sub = [sub]
      stack[n - 1] = re
      try checkLimits(re)

      if op == .repeat && (min >= 2 || max >= 2) && !Syntax.repeatIsValid(re, 1000) {
        throw ParseError(.invalidRepeatSize, s[before..<after])
      }

      return after
    }

    /// concat replaces the top of the stack (above the topmost '|' or '(') with its concatenation.
    @discardableResult
    func concat() throws -> Regexp? {
      _ = maybeConcat(-1, [])

      // Scan down to find pseudo-operator | or (.
      var i = stack.count
      while i > 0 && stack[i - 1].op < .pseudo {
        i -= 1
      }
      let subs = Array(stack[i...])
      stack.removeSubrange(i...)

      // Empty concatenation is special case.
      if subs.isEmpty {
        return try push(newRegexp(.emptyMatch))
      }

      return try push(collapse(subs, .concat))
    }

    /// alternate replaces the top of the stack (above the topmost '(') with its alternation.
    @discardableResult
    func alternate() throws -> Regexp? {
      // Scan down to find pseudo-operator (.
      // There are no | above (.
      var i = stack.count
      while i > 0 && stack[i - 1].op < .pseudo {
        i -= 1
      }
      let subs = Array(stack[i...])
      stack.removeSubrange(i...)

      // Make sure top class is clean.
      // All the others already are (see swapVerticalBar).
      if let last = subs.last {
        Syntax.cleanAlt(last)
      }

      // Empty alternate is special case
      // (shouldn't happen but easy to handle).
      if subs.isEmpty {
        return try push(newRegexp(.noMatch))
      }

      return try push(collapse(subs, .alternate))
    }

    /// collapse returns the result of applying op to sub.
    /// If sub contains op nodes, they all get hoisted up
    /// so that there is never a concat of a concat or an
    /// alternate of an alternate.
    ///
    /// In Go, collapse and factor recurse into each other once per factored common prefix,
    /// which for an alternation like `.....x|.....y` is once per leading item, close to the
    /// height limit of 1000. Here the same calls run as resumable frames on an explicit stack,
    /// in the same order (so nodes are allocated and reused exactly as in Go).
    func collapse(_ subs: [Regexp], _ op: Op) throws -> Regexp {
      var call = collapseEnter(subs, op)
      guard case .factor(let re) = call else {
        if case .done(let re) = call {
          return re
        }
        preconditionFailure("unreachable")
      }
      // Frames waiting for a result: a collapse waits for factor(re.sub), a factor for a
      // collapse of one of its runs.
      var frames: [FactorFrame] = [.collapse(re), .factor(FactorState(re.sub))]
      var ret: FactorReturn? = nil
      while let frame = frames.popLast() {
        switch frame {
        case .collapse(var re):
          guard case .list(let sub) = ret else { preconditionFailure("collapse resumed without factor result") }
          re.sub = sub
          if re.sub.count == 1 {
            let old = re
            re = re.sub[0]
            reuse(old)
          }
          ret = .regexp(re)
        case .factor(var state):
          var suffix: Regexp? = nil
          if case .regexp(let r) = ret {
            suffix = r
          }
          ret = nil
          switch try factorStep(&state, suffix) {
          case .done(let out):
            ret = .list(out)
          case .collapse(let run):
            frames.append(.factor(state))
            call = collapseEnter(run, .alternate)
            switch call {
            case .done(let re):
              ret = .regexp(re)
            case .factor(let re):
              frames.append(.collapse(re))
              frames.append(.factor(FactorState(re.sub)))
            }
          }
        }
      }
      guard case .regexp(let result) = ret else { preconditionFailure("collapse without result") }
      return result
    }

    private enum CollapseCall {
      case done(Regexp)  // collapse finished without factoring
      case factor(Regexp)  // alternation node built; its subs still need factor
    }

    private enum FactorFrame {
      case collapse(Regexp)
      case factor(FactorState)
    }

    private enum FactorReturn {
      case regexp(Regexp)
      case list([Regexp])
    }

    /// The part of Go's collapse before it calls factor.
    private func collapseEnter(_ subs: [Regexp], _ op: Op) -> CollapseCall {
      if subs.count == 1 {
        return .done(subs[0])
      }
      let re = newRegexp(op)
      re.sub = []
      for sub in subs {
        if sub.op == op {
          re.sub.append(contentsOf: sub.sub)
          reuse(sub)
        } else {
          re.sub.append(sub)
        }
      }
      if op == .alternate {
        return .factor(re)
      }
      return .done(re)
    }

    /// The local state of one call of Go's factor.
    private struct FactorState {
      enum Phase {
        case start, round1, round1Resume, round2Start, round2, round2Resume, rounds34
      }
      var phase = Phase.start
      var sub: [Regexp]
      var out: [Regexp] = []
      var start = 0
      var i = 0
      // Round 1.
      var str: [Rune] = []
      var strflags: Flags = []
      var pendingPrefix: Regexp? = nil
      var pendingIStr: [Rune] = []
      var pendingIFlags: Flags = []
      // Round 2.
      var first: Regexp? = nil
      var pendingIFirst: Regexp? = nil

      init(_ sub: [Regexp]) {
        self.sub = sub
      }
    }

    private enum FactorAction {
      case done([Regexp])
      case collapse([Regexp])  // call collapse(run, OpAlternate), then resume with its result
    }

    /// factor factors common prefixes from the alternation list sub.
    /// It returns a replacement list and frees (passes to p.reuse) any removed Regexps.
    ///
    /// For example,
    ///
    ///     ABC|ABD|AEF|BCX|BCY
    ///
    /// simplifies by literal prefix extraction to
    ///
    ///     A(B(C|D)|EF)|BC(X|Y)
    ///
    /// which simplifies by character class introduction to
    ///
    ///     A(B[CD]|EF)|BC[XY]
    ///
    /// Runs Go's factor until it finishes or needs the result of collapsing a run (the recursive
    /// call in Go); `suffix` is that result when resuming.
    private func factorStep(_ s: inout FactorState, _ suffix: Regexp?) throws -> FactorAction {
      while true {
        switch s.phase {
        case .start:
          if s.sub.count < 2 {
            return .done(s.sub)
          }
          // Round 1: Factor out common literal prefixes.
          s.str = []
          s.strflags = []
          s.start = 0
          s.out = []
          s.i = 0
          s.phase = .round1

        case .round1Resume:
          guard let suffix, let prefix = s.pendingPrefix else { preconditionFailure("factor resumed without suffix") }
          let re = newRegexp(.concat)
          re.sub = [prefix, suffix]
          s.out.append(re)
          s.pendingPrefix = nil
          // Prepare for next iteration.
          s.start = s.i
          s.str = s.pendingIStr
          s.strflags = s.pendingIFlags
          s.i += 1
          s.phase = .round1

        case .round1:
          if s.i > s.sub.count {
            s.sub = s.out
            s.phase = .round2Start
            continue
          }
          let i = s.i
          // Invariant: sub[start:i] consists of regexps that all begin
          // with str as modified by strflags.
          var istr: [Rune] = []
          var iflags: Flags = []
          if i < s.sub.count {
            (istr, iflags) = leadingString(s.sub[i])
            if iflags == s.strflags {
              var same = 0
              while same < s.str.count && same < istr.count && s.str[same] == istr[same] {
                same += 1
              }
              if same > 0 {
                // Matches at least one rune in current range.
                // Keep going around.
                s.str.removeSubrange(same...)
                s.i += 1
                continue
              }
            }
          }

          // Found end of a run with common leading literal string:
          // sub[start:i] all begin with str[:len(str)], but sub[i]
          // does not even begin with str[0].
          //
          // Factor out common string and append factored expression to out.
          if i == s.start {
            // Nothing to do - run of length 0.
          } else if i == s.start + 1 {
            // Just one: don't bother factoring.
            s.out.append(s.sub[s.start])
          } else {
            // Construct factored form: prefix(suffix1|suffix2|...)
            let prefix = newRegexp(.literal)
            prefix.flags = s.strflags
            prefix.rune = s.str

            for j in s.start..<i {
              s.sub[j] = removeLeadingString(s.sub[j], s.str.count)
              try checkLimits(s.sub[j])
            }
            s.pendingPrefix = prefix
            s.pendingIStr = istr
            s.pendingIFlags = iflags
            s.phase = .round1Resume
            return .collapse(Array(s.sub[s.start..<i]))  // recurse
          }

          // Prepare for next iteration.
          s.start = i
          s.str = istr
          s.strflags = iflags
          s.i += 1

        case .round2Start:
          // Round 2: Factor out common simple prefixes,
          // just the first piece of each concatenation.
          // This will be good enough a lot of the time.
          //
          // Complex subexpressions (e.g. involving quantifiers)
          // are not safe to factor because that collapses their
          // distinct paths through the automaton, which affects
          // correctness in some cases.
          s.start = 0
          s.out = []
          s.first = nil
          s.i = 0
          s.phase = .round2

        case .round2Resume:
          guard let suffix, let prefix = s.first else { preconditionFailure("factor resumed without suffix") }
          let re = newRegexp(.concat)
          re.sub = [prefix, suffix]
          s.out.append(re)
          // Prepare for next iteration.
          s.start = s.i
          s.first = s.pendingIFirst
          s.pendingIFirst = nil
          s.i += 1
          s.phase = .round2

        case .round2:
          if s.i > s.sub.count {
            s.sub = s.out
            s.phase = .rounds34
            continue
          }
          let i = s.i
          // Invariant: sub[start:i] consists of regexps that all begin with ifirst.
          var ifirst: Regexp? = nil
          if i < s.sub.count {
            ifirst = leadingRegexp(s.sub[i])
            if let first = s.first, first.equal(ifirst),
              // first must be a character class OR a fixed repeat of a character class.
              Syntax.isCharClass(first)
                || (first.op == .repeat && first.min == first.max && Syntax.isCharClass(first.sub[0]))
            {
              s.i += 1
              continue
            }
          }

          // Found end of a run with common leading regexp:
          // sub[start:i] all begin with first but sub[i] does not.
          //
          // Factor out common regexp and append factored expression to out.
          if i == s.start {
            // Nothing to do - run of length 0.
          } else if i == s.start + 1 {
            // Just one: don't bother factoring.
            s.out.append(s.sub[s.start])
          } else if s.first != nil {
            // Construct factored form: prefix(suffix1|suffix2|...)
            for j in s.start..<i {
              let reuse = j != s.start  // prefix came from sub[start]
              s.sub[j] = removeLeadingRegexp(s.sub[j], reuse)
              try checkLimits(s.sub[j])
            }
            s.pendingIFirst = ifirst
            s.phase = .round2Resume
            return .collapse(Array(s.sub[s.start..<i]))  // recurse
          }

          // Prepare for next iteration.
          s.start = i
          s.first = ifirst
          s.i += 1

        case .rounds34:
          return .done(factorRounds34(s.sub))
        }
      }
    }

    /// Rounds 3 and 4 of Go's factor, which do not recurse.
    private func factorRounds34(_ sub0: [Regexp]) -> [Regexp] {
      var sub = sub0
      // Round 3: Collapse runs of single literals into character classes.
      var start = 0
      var out: [Regexp] = []
      var i = 0
      while i <= sub.count {
        // Invariant: sub[start:i] consists of regexps that are either
        // literal runes or character classes.
        if i < sub.count && Syntax.isCharClass(sub[i]) {
          i += 1
          continue
        }

        // sub[i] is not a char or char class;
        // emit char class for sub[start:i]...
        if i == start {
          // Nothing to do - run of length 0.
        } else if i == start + 1 {
          out.append(sub[start])
        } else {
          // Make new char class.
          // Start with most complex regexp in sub[start].
          var max = start
          for j in (start + 1)..<i {
            if sub[max].op < sub[j].op || sub[max].op == sub[j].op && sub[max].rune.count < sub[j].rune.count {
              max = j
            }
          }
          sub.swapAt(start, max)

          for j in (start + 1)..<i {
            Syntax.mergeCharClass(sub[start], sub[j])
            reuse(sub[j])
          }
          Syntax.cleanAlt(sub[start])
          out.append(sub[start])
        }

        // ... and then emit sub[i].
        if i < sub.count {
          out.append(sub[i])
        }
        start = i + 1
        i += 1
      }
      sub = out

      // Round 4: Collapse runs of empty matches into a single empty match.
      out = []
      for i in sub.indices {
        if i + 1 < sub.count && sub[i].op == .emptyMatch && sub[i + 1].op == .emptyMatch {
          continue
        }
        out.append(sub[i])
      }
      return out
    }

    /// leadingString returns the leading literal string that re begins with.
    func leadingString(_ re0: Regexp) -> ([Rune], Flags) {
      var re = re0
      if re.op == .concat && !re.sub.isEmpty {
        re = re.sub[0]
      }
      if re.op != .literal {
        return ([], [])
      }
      return (re.rune, re.flags.intersection(.foldCase))
    }

    /// removeLeadingString removes the first n leading runes
    /// from the beginning of re. It returns the replacement for re.
    func removeLeadingString(_ re0: Regexp, _ n: Int) -> Regexp {
      var re = re0
      if re.op == .concat && !re.sub.isEmpty {
        // Removing a leading string in a concatenation
        // might simplify the concatenation.
        let sub = removeLeadingString(re.sub[0], n)
        re.sub[0] = sub
        if sub.op == .emptyMatch {
          reuse(sub)
          switch re.sub.count {
          case 0, 1:
            // Impossible but handle.
            re.op = .emptyMatch
            re.sub = []
          case 2:
            let old = re
            re = re.sub[1]
            reuse(old)
          default:
            re.sub.removeFirst()
          }
        }
        return re
      }

      if re.op == .literal {
        re.rune.removeFirst(Swift.min(n, re.rune.count))
        if re.rune.isEmpty {
          re.op = .emptyMatch
        }
      }
      return re
    }

    /// leadingRegexp returns the leading regexp that re begins with.
    /// The regexp refers to storage in re or its children.
    func leadingRegexp(_ re: Regexp) -> Regexp? {
      if re.op == .emptyMatch {
        return nil
      }
      if re.op == .concat && !re.sub.isEmpty {
        let sub = re.sub[0]
        if sub.op == .emptyMatch {
          return nil
        }
        return sub
      }
      return re
    }

    /// removeLeadingRegexp removes the leading regexp in re.
    /// It returns the replacement for re.
    /// If reuse is true, it passes the removed regexp (if no longer needed) to p.reuse.
    func removeLeadingRegexp(_ re0: Regexp, _ reuse: Bool) -> Regexp {
      var re = re0
      if re.op == .concat && !re.sub.isEmpty {
        if reuse {
          self.reuse(re.sub[0])
        }
        re.sub.removeFirst()
        switch re.sub.count {
        case 0:
          re.op = .emptyMatch
          re.sub = []
        case 1:
          let old = re
          re = re.sub[0]
          self.reuse(old)
        default:
          break
        }
        return re
      }
      if reuse {
        self.reuse(re)
      }
      return newRegexp(.emptyMatch)
    }

    /// parseRepeat parses {min} (max=min) or {min,} (max=-1) or {min,max}.
    /// If s is not of that form, it returns nil.
    /// If s has the right form but the values are too big, it returns min == -1.
    func parseRepeat(_ start: Int) -> (min: Int, max: Int, rest: Int)? {
      var t = start
      let end = s.count
      if t >= end || s[t] != UInt8(ascii: "{") {
        return nil
      }
      t += 1
      guard let (min0, t1) = parseInt(t) else {
        return nil
      }
      t = t1
      var min = min0
      if t >= end {
        return nil
      }
      var max: Int
      if s[t] != UInt8(ascii: ",") {
        max = min
      } else {
        t += 1
        if t >= end {
          return nil
        }
        if s[t] == UInt8(ascii: "}") {
          max = -1
        } else if let (m, t2) = parseInt(t) {
          max = m
          t = t2
          if max < 0 {
            // parseInt found too big a number
            min = -1
          }
        } else {
          return nil
        }
      }
      if t >= end || s[t] != UInt8(ascii: "}") {
        return nil
      }
      return (min, max, t + 1)
    }

    /// parsePerlFlags parses a Perl flag setting or non-capturing group or both,
    /// like (?i) or (?: or (?i:.  It removes the prefix from s and updates the parse state.
    /// The caller must have ensured that s begins with "(?".
    func parsePerlFlags(_ start: Int) throws -> Int {
      let end = s.count
      let n = end - start

      // Check for named captures, first introduced in Python's regexp library.
      // As usual, there are three slightly different syntaxes:
      //
      //   (?P<name>expr)   the original, introduced by Python
      //   (?<name>expr)    the .NET alteration, adopted by Perl 5.10
      //   (?'name'expr)    another .NET alteration, adopted by Perl 5.10
      //
      // Perl 5.10 gave in and implemented the Python version too,
      // but they claim that the last two are the preferred forms.
      // PCRE and languages based on it (specifically, PHP and Ruby)
      // support all three as well. EcmaScript 4 uses only the Python form.
      //
      // In both the open source world (via Code Search) and the
      // Google source tree, (?P<expr>name) and (?<expr>name) are the
      // dominant forms of named captures and both are supported.
      let startsWithP = n > 4 && s[start + 2] == UInt8(ascii: "P") && s[start + 3] == UInt8(ascii: "<")
      let startsWithName = n > 3 && s[start + 2] == UInt8(ascii: "<")

      if startsWithP || startsWithName {
        // position of expr start
        let exprStartPos = startsWithName ? 3 : 4

        // Pull out name.
        guard let endIdx = s[start..<end].firstIndex(of: UInt8(ascii: ">")) else {
          try Syntax.checkUTF8(s, start, end)
          throw ParseError(.invalidNamedCapture, s[start..<end])
        }

        let capture = s[start...endIdx]  // "(?P<name>" or "(?<name>"
        let nameStart = start + exprStartPos
        let name = nameStart <= endIdx ? s[nameStart..<endIdx] : s[endIdx..<endIdx]  // "name"
        try Syntax.checkUTF8(s, name.startIndex, name.endIndex)
        if !Syntax.isValidCaptureName(name) {
          throw ParseError(.invalidNamedCapture, capture)
        }

        // Like ordinary capture, but named.
        numCap += 1
        if let re = try op(.leftParen) {
          re.cap = numCap
          re.name = GoUTF8.string(name)
        }
        return endIdx + 1
      }

      // Non-capturing group. Might also twiddle Perl flags.
      var t = start + 2  // skip (?
      var flags = self.flags
      var sign = +1
      var sawFlag = false
      loop: while t < end {
        let (c, next) = try nextRune(s, t, end)
        t = next
        switch c {
        // Flags.
        case 0x69:  // 'i'
          flags.formUnion(.foldCase)
          sawFlag = true
        case 0x6D:  // 'm'
          flags.subtract(.oneLine)
          sawFlag = true
        case 0x73:  // 's'
          flags.formUnion(.dotNL)
          sawFlag = true
        case 0x55:  // 'U'
          flags.formUnion(.nonGreedy)
          sawFlag = true

        // Switch to negation.
        case 0x2D:  // '-'
          if sign < 0 {
            break loop
          }
          sign = -1
          // Invert flags so that | above turn into &^ and vice versa.
          // We'll invert flags again before using it below.
          flags = Flags(rawValue: ~flags.rawValue)
          sawFlag = false

        // End of flags, starting group or not.
        case 0x3A, 0x29:  // ':', ')'
          if sign < 0 {
            if !sawFlag {
              break loop
            }
            flags = Flags(rawValue: ~flags.rawValue)
          }
          if c == 0x3A {
            // Open new group
            try op(.leftParen)
          }
          self.flags = flags
          return t
        default:
          break loop
        }
      }

      throw ParseError(.invalidPerlOp, s[start..<t])
    }

    /// parseInt parses a decimal integer.
    func parseInt(_ start: Int) -> (n: Int, rest: Int)? {
      let end = s.count
      func isDigit(_ i: Int) -> Bool { i < end && s[i] >= UInt8(ascii: "0") && s[i] <= UInt8(ascii: "9") }
      if !isDigit(start) {
        return nil
      }
      // Disallow leading zeros.
      if end - start >= 2 && s[start] == UInt8(ascii: "0") && isDigit(start + 1) {
        return nil
      }
      var t = start
      while isDigit(t) {
        t += 1
      }
      // Have digits, compute value.
      var n = 0
      for i in start..<t {
        // Avoid overflow.
        if n >= 100_000_000 {
          n = -1
          break
        }
        n = n * 10 + Int(s[i]) - 0x30
      }
      return (n, t)
    }

    /// parseVerticalBar handles a | in the input.
    func parseVerticalBar() throws {
      try concat()

      // The concatenation we just parsed is on top of the stack.
      // If it sits above an opVerticalBar, swap it below
      // (things below an opVerticalBar become an alternation).
      // Otherwise, push a new vertical bar.
      if try !swapVerticalBar() {
        try op(.verticalBar)
      }
    }

    /// If the top of the stack is an element followed by an opVerticalBar
    /// swapVerticalBar swaps the two and returns true.
    /// Otherwise it returns false.
    func swapVerticalBar() throws -> Bool {
      // If above and below vertical bar are literal or char class,
      // can merge into a single char class.
      let n = stack.count
      if n >= 3 && stack[n - 2].op == .verticalBar && Syntax.isCharClass(stack[n - 1])
        && Syntax.isCharClass(stack[n - 3])
      {
        var re1 = stack[n - 1]
        var re3 = stack[n - 3]
        // Make re3 the more complex of the two.
        if re1.op > re3.op {
          swap(&re1, &re3)
          stack[n - 3] = re3
        }
        Syntax.mergeCharClass(re3, re1)
        reuse(re1)
        stack.removeLast()
        return true
      }

      if n >= 2 {
        let re1 = stack[n - 1]
        let re2 = stack[n - 2]
        if re2.op == .verticalBar {
          if n >= 3 {
            // Now out of reach.
            // Clean opportunistically.
            Syntax.cleanAlt(stack[n - 3])
          }
          stack[n - 2] = re1
          stack[n - 1] = re2
          return true
        }
      }
      return false
    }

    /// parseRightParen handles a ) in the input.
    func parseRightParen() throws {
      try concat()
      if try swapVerticalBar() {
        // pop vertical bar
        stack.removeLast()
      }
      try alternate()

      let n = stack.count
      if n < 2 {
        throw ParseError(.unexpectedParen, wholeRegexp)
      }
      let re1 = stack[n - 1]
      let re2 = stack[n - 2]
      stack.removeLast(2)
      if re2.op != .leftParen {
        throw ParseError(.unexpectedParen, wholeRegexp)
      }
      // Restore flags at time of paren.
      flags = re2.flags
      if re2.cap == 0 {
        // Just for grouping.
        try push(re1)
      } else {
        re2.op = .capture
        re2.sub = [re1]
        try push(re2)
      }
    }

    /// parseEscape parses an escape sequence at the beginning of s
    /// and returns the rune.
    func parseEscape(_ start: Int) throws -> (Rune, Int) {
      let end = s.count
      var t = start + 1
      if t >= end {
        throw ParseError(code: .trailingBackslash, expr: "")
      }
      var (c, next) = try nextRune(s, t, end)
      t = next

      switchLabel: switch c {
      // Octal escapes.
      case 0x31...0x37, 0x30:  // '1'...'7', '0'
        // Single non-zero digit is a backreference; not supported
        if c != 0x30 && (t >= end || s[t] < UInt8(ascii: "0") || s[t] > UInt8(ascii: "7")) {
          break
        }
        // Consume up to three octal digits; already have one.
        var r = c - 0x30
        for _ in 1..<3 {
          if t >= end || s[t] < UInt8(ascii: "0") || s[t] > UInt8(ascii: "7") {
            break
          }
          r = r * 8 + Rune(s[t]) - 0x30
          t += 1
        }
        return (r, t)

      // Hexadecimal escapes.
      case 0x78:  // 'x'
        if t >= end {
          break
        }
        (c, t) = try nextRune(s, t, end)
        if c == 0x7B {  // '{'
          // Any number of digits in braces.
          // Perl accepts any text at all; it ignores all text
          // after the first non-hex digit. We require only hex digits,
          // and at least one.
          var nhex = 0
          var r: Rune = 0
          while true {
            if t >= end {
              break switchLabel
            }
            (c, t) = try nextRune(s, t, end)
            if c == 0x7D {  // '}'
              break
            }
            let v = Syntax.unhex(c)
            if v < 0 {
              break switchLabel
            }
            r = r * 16 + v
            if r > UnicodeTables.maxRune {
              break switchLabel
            }
            nhex += 1
          }
          if nhex == 0 {
            break switchLabel
          }
          return (r, t)
        }

        // Easy case: two hex digits.
        let x = Syntax.unhex(c)
        (c, t) = try nextRune(s, t, end)
        let y = Syntax.unhex(c)
        if x < 0 || y < 0 {
          break
        }
        return (x * 16 + y, t)

      // C escapes. There is no case 'b', to avoid misparsing
      // the Perl word-boundary \b as the C backspace \b
      // when in POSIX mode. In Perl, /\b/ means word-boundary
      // but /[\b]/ means backspace. We don't support that.
      // If you want a backspace, embed a literal backspace
      // character or use \x08.
      case 0x61:  // 'a'
        return (0x07, t)
      case 0x66:  // 'f'
        return (0x0C, t)
      case 0x6E:  // 'n'
        return (0x0A, t)
      case 0x72:  // 'r'
        return (0x0D, t)
      case 0x74:  // 't'
        return (0x09, t)
      case 0x76:  // 'v'
        return (0x0B, t)
      default:
        if c < GoUTF8.runeSelf && !Syntax.isalnum(c) {
          // Escaped non-word characters are always themselves.
          // PCRE is not quite so rigorous: it accepts things like
          // \q, but we don't. We once rejected \_, but too many
          // programs and people insist on using it, so allow \_.
          return (c, t)
        }
      }
      throw ParseError(.invalidEscape, s[start..<t])
    }

    /// parseClassChar parses a character class character at the beginning of s
    /// and returns it.
    func parseClassChar(_ t: Int, wholeClass: Int) throws -> (Rune, Int) {
      if t >= s.count {
        throw ParseError(.missingBracket, s[wholeClass...])
      }

      // Allow regular escape sequences even though
      // many need not be escaped in this context.
      if s[t] == UInt8(ascii: "\\") {
        return try parseEscape(t)
      }

      return try nextRune(s, t, s.count)
    }

    /// parsePerlClassEscape parses a leading Perl character class escape like \d
    /// from the beginning of s. If one is present, it appends the characters to r
    /// and returns the remainder of the string.
    func parsePerlClassEscape(_ t: Int, _ r: inout [Rune]) -> Int? {
      if !flags.contains(.perlX) || s.count - t < 2 || s[t] != UInt8(ascii: "\\") {
        return nil
      }
      guard let g = Syntax.perlGroup(s[t + 1]) else {
        return nil
      }
      appendGroup(&r, g)
      return t + 2
    }

    /// parseNamedClass parses a leading POSIX named character class like [:alnum:]
    /// from the beginning of s. If one is present, it appends the characters to r
    /// and returns the remainder of the string.
    func parseNamedClass(_ t: Int, _ r: inout [Rune]) throws -> Int? {
      let end = s.count
      if end - t < 2 || s[t] != UInt8(ascii: "[") || s[t + 1] != UInt8(ascii: ":") {
        return nil
      }

      var i = t + 2
      var found = -1
      while i + 1 < end {
        if s[i] == UInt8(ascii: ":") && s[i + 1] == UInt8(ascii: "]") {
          found = i
          break
        }
        i += 1
      }
      if found < 0 {
        return nil
      }
      let name = s[t..<(found + 2)]
      guard let g = Syntax.posixGroup(name) else {
        throw ParseError(.invalidCharRange, name)
      }
      appendGroup(&r, g)
      return found + 2
    }

    func appendGroup(_ r: inout [Rune], _ g: CharGroup) {
      if !flags.contains(.foldCase) {
        if g.sign < 0 {
          Syntax.appendNegatedClass(&r, g.class)
        } else {
          Syntax.appendClass(&r, g.class)
        }
      } else {
        tmpClass.removeAll(keepingCapacity: true)
        Syntax.appendFoldedClass(&tmpClass, g.class)
        Syntax.cleanClass(&tmpClass)
        if g.sign < 0 {
          Syntax.appendNegatedClass(&r, tmpClass)
        } else {
          Syntax.appendClass(&r, tmpClass)
        }
      }
    }

    /// parseUnicodeClass parses a leading Unicode character class like \p{Han}
    /// from the beginning of s. If one is present, it appends the characters to r
    /// and returns the remainder of the string.
    func parseUnicodeClass(_ start: Int, _ r: inout [Rune]) throws -> Int? {
      let end = s.count
      if !flags.contains(.unicodeGroups) || end - start < 2 || s[start] != UInt8(ascii: "\\")
        || s[start + 1] != UInt8(ascii: "p") && s[start + 1] != UInt8(ascii: "P")
      {
        return nil
      }

      // Committed to parse or return error.
      var sign = +1
      if s[start + 1] == UInt8(ascii: "P") {
        sign = -1
      }
      var t = start + 2
      let (c, next) = try nextRune(s, t, end)
      t = next
      let seq: ArraySlice<UInt8>
      var name: ArraySlice<UInt8>
      if c != 0x7B {  // '{'
        // Single-letter name.
        seq = s[start..<t]
        name = seq.dropFirst(2)
      } else {
        // Name is in braces.
        guard let endIdx = s[start..<end].firstIndex(of: UInt8(ascii: "}")) else {
          try Syntax.checkUTF8(s, start, end)
          throw ParseError(.invalidCharRange, s[start..<end])
        }
        seq = s[start...endIdx]
        t = endIdx + 1
        name = s[(start + 3)..<endIdx]
        try Syntax.checkUTF8(s, name.startIndex, name.endIndex)
      }

      // Group can have leading negation too.  \p{^Han} == \P{Han}, \P{^Han} == \p{Han}.
      if let f = name.first, f == UInt8(ascii: "^") {
        sign = -sign
        name = name.dropFirst()
      }

      guard let (tab, fold, tsign) = Syntax.unicodeTable(GoUTF8.string(name)) else {
        throw ParseError(.invalidCharRange, seq)
      }
      if tsign < 0 {
        sign = -sign
      }

      if !flags.contains(.foldCase) || fold == nil {
        if sign > 0 {
          Syntax.appendTable(&r, tab)
        } else {
          Syntax.appendNegatedTable(&r, tab)
        }
      } else if let fold {
        // Merge and clean tab and fold in a temporary buffer.
        // This is necessary for the negative case and just tidy
        // for the positive case.
        tmpClass.removeAll(keepingCapacity: true)
        Syntax.appendTable(&tmpClass, tab)
        Syntax.appendTable(&tmpClass, fold)
        Syntax.cleanClass(&tmpClass)
        if sign > 0 {
          Syntax.appendClass(&r, tmpClass)
        } else {
          Syntax.appendNegatedClass(&r, tmpClass)
        }
      }
      return t
    }

    /// parseClass parses a character class at the beginning of s
    /// and pushes it onto the parse stack.
    func parseClass(_ start: Int) throws -> Int {
      let end = s.count
      var t = start + 1  // chop [
      let re = newRegexp(.charClass)
      re.flags = flags
      var cls: [Rune] = []

      var sign = +1
      if t < end && s[t] == UInt8(ascii: "^") {
        sign = -1
        t += 1

        // If character class does not match \n, add it here,
        // so that negation later will do the right thing.
        if !flags.contains(.classNL) {
          cls.append(contentsOf: [0x0A, 0x0A])
        }
      }

      var first = true  // ] and - are okay as first char in class
      while t >= end || s[t] != UInt8(ascii: "]") || first {
        // POSIX: - is only okay unescaped as first or last in class.
        // Perl: - is okay anywhere.
        if t < end && s[t] == UInt8(ascii: "-") && !flags.contains(.perlX) && !first
          && (end - t == 1 || s[t + 1] != UInt8(ascii: "]"))
        {
          let (_, size) = s.withUnsafeBufferPointer { GoUTF8.decodeRune($0, at: t + 1) }
          throw ParseError(.invalidCharRange, s[t..<(t + 1 + size)])
        }
        first = false

        // Look for POSIX [:alnum:] etc.
        if end - t > 2 && s[t] == UInt8(ascii: "[") && s[t + 1] == UInt8(ascii: ":") {
          if let nt = try parseNamedClass(t, &cls) {
            t = nt
            continue
          }
        }

        // Look for Unicode character group like \p{Han}.
        if let nt = try parseUnicodeClass(t, &cls) {
          t = nt
          continue
        }

        // Look for Perl character class symbols (extension).
        if let nt = parsePerlClassEscape(t, &cls) {
          t = nt
          continue
        }

        // Single character or simple range.
        let rng = t
        let (lo, next) = try parseClassChar(t, wholeClass: start)
        t = next
        var hi = lo
        // [a-] means (a|-) so check for final ].
        if end - t >= 2 && s[t] == UInt8(ascii: "-") && s[t + 1] != UInt8(ascii: "]") {
          t += 1
          (hi, t) = try parseClassChar(t, wholeClass: start)
          if hi < lo {
            throw ParseError(.invalidCharRange, s[rng..<t])
          }
        }
        if !flags.contains(.foldCase) {
          Syntax.appendRange(&cls, lo, hi)
        } else {
          Syntax.appendFoldedRange(&cls, lo, hi)
        }
      }
      t += 1  // chop ]

      Syntax.cleanClass(&cls)
      if sign < 0 {
        Syntax.negateClass(&cls)
      }
      re.rune = cls
      try push(re)
      return t
    }
  }

  // MARK: - Helpers

  /// minFoldRune returns the minimum rune fold-equivalent to r.
  static func minFoldRune(_ r: Rune) -> Rune {
    if r < minFold || r > maxFold {
      return r
    }
    var m = r
    let r0 = r
    var r = UnicodeTables.simpleFold(r)
    while r != r0 {
      m = Swift.min(m, r)
      r = UnicodeTables.simpleFold(r)
    }
    return m
  }

  /// repeatIsValid reports whether the repetition re is valid.
  /// Valid means that the combination of the top-level repetition
  /// and any inner repetitions does not exceed n copies of the
  /// innermost thing.
  /// This function rewalks the regexp tree and is called for every repetition,
  /// so we have to worry about inducing quadratic behavior in the parser.
  /// We avoid this by only calling repeatIsValid when min or max >= 2.
  /// In that case the depth of any >= 2 nesting can only get to 9 without
  /// triggering a parse error, so each subtree can only be rewalked 9 times.
  static func repeatIsValid(_ root: Regexp, _ n0: Int) -> Bool {
    // Go recurses; the same (node, budget) pairs are checked here with an explicit stack.
    var stack: [(Regexp, Int)] = [(root, n0)]
    while let (re, n0) = stack.popLast() {
      var n = n0
      if re.op == .repeat {
        var m = re.max
        if m == 0 {
          continue  // this subtree is valid
        }
        if m < 0 {
          m = re.min
        }
        if m > n {
          return false
        }
        if m > 0 {
          n /= m
        }
      }
      for sub in re.sub.reversed() {
        stack.append((sub, n))
      }
    }
    return true
  }

  /// cleanAlt cleans re for eventual inclusion in an alternation.
  static func cleanAlt(_ re: Regexp) {
    switch re.op {
    case .charClass:
      cleanClass(&re.rune)
      if re.rune.count == 2 && re.rune[0] == 0 && re.rune[1] == UnicodeTables.maxRune {
        re.rune = []
        re.op = .anyChar
        return
      }
      if re.rune.count == 4 && re.rune[0] == 0 && re.rune[1] == 0x0A - 1 && re.rune[2] == 0x0A + 1
        && re.rune[3] == UnicodeTables.maxRune
      {
        re.rune = []
        re.op = .anyCharNotNL
        return
      }
    default:
      break
    }
  }

  /// can this be represented as a character class?
  /// single-rune literal string, char class, ., and .|\n.
  static func isCharClass(_ re: Regexp) -> Bool {
    re.op == .literal && re.rune.count == 1 || re.op == .charClass || re.op == .anyCharNotNL
      || re.op == .anyChar
  }

  /// does re match r?
  static func matchRune(_ re: Regexp, _ r: Rune) -> Bool {
    switch re.op {
    case .literal:
      return re.rune.count == 1 && re.rune[0] == r
    case .charClass:
      var i = 0
      while i < re.rune.count {
        if re.rune[i] <= r && r <= re.rune[i + 1] {
          return true
        }
        i += 2
      }
      return false
    case .anyCharNotNL:
      return r != 0x0A
    case .anyChar:
      return true
    default:
      return false
    }
  }

  /// mergeCharClass makes dst = dst|src.
  /// The caller must ensure that dst.Op >= src.Op,
  /// to reduce the amount of copying.
  static func mergeCharClass(_ dst: Regexp, _ src: Regexp) {
    switch dst.op {
    case .anyChar:
      // src doesn't add anything.
      break
    case .anyCharNotNL:
      // src might add \n
      if matchRune(src, 0x0A) {
        dst.op = .anyChar
      }
    case .charClass:
      // src is simpler, so either literal or char class
      if src.op == .literal {
        appendLiteral(&dst.rune, src.rune[0], src.flags)
      } else {
        appendClass(&dst.rune, src.rune)
      }
    case .literal:
      // both literal
      if src.rune[0] == dst.rune[0] && src.flags == dst.flags {
        break
      }
      dst.op = .charClass
      let d0 = dst.rune[0]
      dst.rune = []
      appendLiteral(&dst.rune, d0, dst.flags)
      appendLiteral(&dst.rune, src.rune[0], src.flags)
    default:
      break
    }
  }

  /// unicodeTable returns the unicode table identified by name
  /// and the table of additional fold-equivalent code points.
  /// If sign < 0, the result should be inverted.
  static func unicodeTable(_ name0: String) -> (UnicodeClass, UnicodeClass?, Int)? {
    let name = canonicalName(name0)

    // Special cases: Any, Assigned, and ASCII.
    // Also LC is the only non-canonical Categories key, so handle it here.
    switch name {
    case "Any":
      return (.any, .any, +1)
    case "Assigned":
      return (.table(UnicodeTables.cn), .table(UnicodeTables.cn), -1)  // invert Cn (unassigned)
    case "Ascii":
      return (.ascii, .asciiFold, +1)
    case "Lc":
      guard let t = UnicodeTables.categories["LC"] else { return nil }
      return (.table(t), UnicodeTables.foldCategory["LC"].map(UnicodeClass.table), +1)
    default:
      break
    }
    if let t = UnicodeTables.categories[name] {
      return (.table(t), UnicodeTables.foldCategory[name].map(UnicodeClass.table), +1)
    }
    if let t = UnicodeTables.scripts[name] {
      return (.table(t), UnicodeTables.foldScript[name].map(UnicodeClass.table), +1)
    }

    // unicode.CategoryAliases makes liberal use of underscores in its names
    // (they are defined that way by Unicode), but we want to match ignoring
    // the underscores, so make our own map with canonical names.
    if let actual = categoryAliases[name], let t = UnicodeTables.categories[actual] {
      return (.table(t), UnicodeTables.foldCategory[actual].map(UnicodeClass.table), +1)
    }
    return nil
  }

  /// categoryAliases is a copy of unicode.CategoryAliases
  /// but with the keys passed through canonicalName, to support inexact matches.
  static let categoryAliases: [String: String] = {
    var m: [String: String] = [:]
    for (name, actual) in UnicodeTables.categoryAliases {
      m[canonicalName(name)] = actual
    }
    return m
  }()

  /// canonicalName returns the canonical lookup string for name.
  /// The canonical name has a leading uppercase letter and then lowercase letters,
  /// and it omits all underscores, spaces, and hyphens.
  /// (We could have used all lowercase, but this way most package unicode
  /// map keys are already canonical.)
  static func canonicalName(_ name: String) -> String {
    var b: [UInt8] = []
    var first = true
    for var c in name.utf8 {
      switch c {
      case UInt8(ascii: "_"), UInt8(ascii: "-"), UInt8(ascii: " "):
        continue
      default:
        if first {
          if UInt8(ascii: "a") <= c && c <= UInt8(ascii: "z") {
            c -= 0x20
          }
          first = false
        } else if UInt8(ascii: "A") <= c && c <= UInt8(ascii: "Z") {
          c += 0x20
        }
      }
      b.append(c)
    }
    return GoUTF8.string(b)
  }

  /// cleanClass sorts the ranges (pairs of elements of r),
  /// merges them, and eliminates duplicates.
  static func cleanClass(_ r: inout [Rune]) {
    // Sort by lo increasing, hi decreasing to break ties.
    let n = r.count / 2
    if n > 1 {
      var pairs: [(Rune, Rune)] = []
      pairs.reserveCapacity(n)
      for i in 0..<n {
        pairs.append((r[2 * i], r[2 * i + 1]))
      }
      pairs.sort { a, b in a.0 < b.0 || a.0 == b.0 && a.1 > b.1 }
      for i in 0..<n {
        r[2 * i] = pairs[i].0
        r[2 * i + 1] = pairs[i].1
      }
    }

    if r.count < 2 {
      return
    }

    // Merge abutting, overlapping.
    var w = 2  // write index
    var i = 2
    while i < r.count {
      let lo = r[i]
      let hi = r[i + 1]
      if lo <= r[w - 1] + 1 {
        // merge with previous range
        if hi > r[w - 1] {
          r[w - 1] = hi
        }
        i += 2
        continue
      }
      // new disjoint range
      r[w] = lo
      r[w + 1] = hi
      w += 2
      i += 2
    }

    r.removeSubrange(w...)
  }

  /// inCharClass reports whether r is in the class.
  /// It assumes the class has been cleaned by cleanClass.
  static func inCharClass(_ r: Rune, _ cls: [Rune]) -> Bool {
    var lo = 0
    var hi = cls.count / 2
    while lo < hi {
      let m = lo + (hi - lo) / 2
      let clo = cls[2 * m]
      let chi = cls[2 * m + 1]
      if r > chi {
        lo = m + 1
      } else if r < clo {
        hi = m
      } else {
        return true
      }
    }
    return false
  }

  /// appendLiteral returns the result of appending the literal x to the class r.
  static func appendLiteral(_ r: inout [Rune], _ x: Rune, _ flags: Flags) {
    if flags.contains(.foldCase) {
      appendFoldedRange(&r, x, x)
    } else {
      appendRange(&r, x, x)
    }
  }

  /// appendRange returns the result of appending the range lo-hi to the class r.
  static func appendRange(_ r: inout [Rune], _ lo: Rune, _ hi: Rune) {
    // Expand last range or next to last range if it overlaps or abuts.
    // Checking two ranges helps when appending case-folded
    // alphabets, so that one range can be expanding A-Z and the
    // other expanding a-z.
    let n = r.count
    var i = 2
    while i <= 4 {  // twice, using i=2, i=4
      if n >= i {
        let rlo = r[n - i]
        let rhi = r[n - i + 1]
        if lo <= rhi + 1 && rlo <= hi + 1 {
          if lo < rlo {
            r[n - i] = lo
          }
          if hi > rhi {
            r[n - i + 1] = hi
          }
          return
        }
      }
      i += 2
    }

    r.append(lo)
    r.append(hi)
  }

  /// appendFoldedRange returns the result of appending the range lo-hi
  /// and its case folding-equivalent runes to the class r.
  static func appendFoldedRange(_ r: inout [Rune], _ lo0: Rune, _ hi0: Rune) {
    var lo = lo0
    var hi = hi0
    // Optimizations.
    if lo <= minFold && hi >= maxFold {
      // Range is full: folding can't add more.
      appendRange(&r, lo, hi)
      return
    }
    if hi < minFold || lo > maxFold {
      // Range is outside folding possibilities.
      appendRange(&r, lo, hi)
      return
    }
    if lo < minFold {
      // [lo, minFold-1] needs no folding.
      appendRange(&r, lo, minFold - 1)
      lo = minFold
    }
    if hi > maxFold {
      // [maxFold+1, hi] needs no folding.
      appendRange(&r, maxFold + 1, hi)
      hi = maxFold
    }

    // Brute force. Depend on appendRange to coalesce ranges on the fly.
    for c in lo...hi {
      appendRange(&r, c, c)
      var f = UnicodeTables.simpleFold(c)
      while f != c {
        appendRange(&r, f, f)
        f = UnicodeTables.simpleFold(f)
      }
    }
  }

  /// appendClass returns the result of appending the class x to the class r.
  /// It assume x is clean.
  static func appendClass(_ r: inout [Rune], _ x: [Rune]) {
    var i = 0
    while i < x.count {
      appendRange(&r, x[i], x[i + 1])
      i += 2
    }
  }

  /// appendFoldedClass returns the result of appending the case folding of the class x to the class r.
  static func appendFoldedClass(_ r: inout [Rune], _ x: [Rune]) {
    var i = 0
    while i < x.count {
      appendFoldedRange(&r, x[i], x[i + 1])
      i += 2
    }
  }

  /// appendNegatedClass returns the result of appending the negation of the class x to the class r.
  /// It assumes x is clean.
  static func appendNegatedClass(_ r: inout [Rune], _ x: [Rune]) {
    var nextLo: Rune = 0
    var i = 0
    while i < x.count {
      let lo = x[i]
      let hi = x[i + 1]
      if nextLo <= lo - 1 {
        appendRange(&r, nextLo, lo - 1)
      }
      nextLo = hi + 1
      i += 2
    }
    if nextLo <= UnicodeTables.maxRune {
      appendRange(&r, nextLo, UnicodeTables.maxRune)
    }
  }

  /// appendTable returns the result of appending x to the class r.
  static func appendTable(_ r: inout [Rune], _ x: UnicodeClass) {
    x.forEachRange { lo, hi in
      appendRange(&r, lo, hi)
    }
  }

  /// appendNegatedTable returns the result of appending the negation of x to the class r.
  static func appendNegatedTable(_ r: inout [Rune], _ x: UnicodeClass) {
    var nextLo: Rune = 0  // lo end of next class to add
    x.forEachRange { lo, hi in
      if nextLo <= lo - 1 {
        appendRange(&r, nextLo, lo - 1)
      }
      nextLo = hi + 1
    }
    if nextLo <= UnicodeTables.maxRune {
      appendRange(&r, nextLo, UnicodeTables.maxRune)
    }
  }

  /// negateClass overwrites r and returns r's negation.
  /// It assumes the class r is already clean.
  static func negateClass(_ r: inout [Rune]) {
    var nextLo: Rune = 0  // lo end of next class to add
    var w = 0  // write index
    var i = 0
    while i < r.count {
      let lo = r[i]
      let hi = r[i + 1]
      if nextLo <= lo - 1 {
        r[w] = nextLo
        r[w + 1] = lo - 1
        w += 2
      }
      nextLo = hi + 1
      i += 2
    }
    r.removeSubrange(w...)
    if nextLo <= UnicodeTables.maxRune {
      // It's possible for the negation to have one more
      // range - this one - than the original class, so use append.
      r.append(nextLo)
      r.append(UnicodeTables.maxRune)
    }
  }

  static func checkUTF8(_ s: [UInt8], _ start: Int, _ end: Int) throws {
    var i = start
    while i < end {
      let (rune, size) = s.withUnsafeBufferPointer { GoUTF8.decodeRune(UnsafeBufferPointer(rebasing: $0[..<end]), at: i) }
      if rune == GoUTF8.runeError && size == 1 {
        throw ParseError(.invalidUTF8, s[i..<end])
      }
      i += size
    }
  }

  /// nextRune decodes the rune at s[start..<end]. At end of input it returns (RuneError, end)
  /// like Go's DecodeRuneInString(""), without error.
  static func nextRune(_ s: [UInt8], _ start: Int, _ end: Int) throws -> (Rune, Int) {
    let (c, size) = s.withUnsafeBufferPointer { GoUTF8.decodeRune(UnsafeBufferPointer(rebasing: $0[..<end]), at: start) }
    if c == GoUTF8.runeError && size == 1 {
      throw ParseError(.invalidUTF8, s[start..<end])
    }
    return (c, start + size)
  }

  static func isalnum(_ c: Rune) -> Bool {
    0x30 <= c && c <= 0x39 || 0x41 <= c && c <= 0x5A || 0x61 <= c && c <= 0x7A
  }

  /// isValidCaptureName reports whether name
  /// is a valid capture name: [A-Za-z0-9_]+.
  /// PCRE limits names to 32 bytes.
  /// Python rejects names starting with digits.
  /// We don't enforce either of those.
  static func isValidCaptureName(_ name: ArraySlice<UInt8>) -> Bool {
    if name.isEmpty {
      return false
    }
    for c in GoUTF8.runes(Array(name)) {
      if c != 0x5F && !isalnum(c) {
        return false
      }
    }
    return true
  }

  static func unhex(_ c: Rune) -> Rune {
    if 0x30 <= c && c <= 0x39 {
      return c - 0x30
    }
    if 0x61 <= c && c <= 0x66 {
      return c - 0x61 + 10
    }
    if 0x41 <= c && c <= 0x46 {
      return c - 0x41 + 10
    }
    return -1
  }

  /// A set of runes from a Unicode table or one of the parser's special tables
  /// (Go's anyTable, asciiTable, asciiFoldTable).
  enum UnicodeClass {
    case table(UnicodeTables.TableRef)
    case any
    case ascii
    case asciiFold

    func forEachRange(_ body: (Rune, Rune) -> Void) {
      switch self {
      case .table(let t):
        t.forEachRange(body)
      case .any:
        body(0, 0xFFFF)
        body(0x10000, UnicodeTables.maxRune)
      case .ascii:
        body(0, 0x7F)
      case .asciiFold:
        body(0, 0x7F)
        body(0x017F, 0x017F)  // Old English long s (ſ), folds to S/s.
        body(0x212A, 0x212A)  // Kelvin K, folds to K/k.
      }
    }
  }
}
