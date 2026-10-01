// Copyright 2011 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// Port of Go's regexp/syntax/regexp.go and op_string.go.

/// Namespace for the port of Go's `regexp/syntax` package.
package enum Syntax {}

extension Syntax {
  /// A Regexp is a node in a regular expression syntax tree.
  ///
  /// Like Go's `*syntax.Regexp`, nodes have identity: the parser reuses them and the printer
  /// keys per-node state on them, so this is a class. Trees never escape a single compilation.
  package final class Regexp {
    package var op: Op = .noMatch
    package var flags: Flags = []
    package var sub: [Regexp] = []  // subexpressions, if any
    package var rune: [Rune] = []  // matched runes, for OpLiteral, OpCharClass
    package var min = 0  // min for OpRepeat
    package var max = 0  // max for OpRepeat
    package var cap = 0  // capturing index, for OpCapture
    package var name = ""  // capturing name, for OpCapture
    /// Free-list link used by the parser (Go reuses Sub0[0] for this).
    var nextFree: Regexp?

    package init(op: Op = .noMatch, flags: Flags = []) {
      self.op = op
      self.flags = flags
    }

    /// Resets every field, like Go's `*re = Regexp{}`.
    func reset() {
      op = .noMatch
      flags = []
      sub = []
      rune = []
      min = 0
      max = 0
      cap = 0
      name = ""
      nextFree = nil
    }

    /// A shallow copy (Go's `*nre = *re`).
    func copy() -> Regexp {
      let n = Regexp(op: op, flags: flags)
      n.sub = sub
      n.rune = rune
      n.min = min
      n.max = max
      n.cap = cap
      n.name = name
      return n
    }
  }

  /// An Op is a single regular expression operator.
  ///
  /// Operators are listed in precedence order, tightest binding to weakest.
  /// Character class operators are listed simplest to most complex
  /// (OpLiteral, OpCharClass, OpAnyCharNotNL, OpAnyChar).
  package struct Op: RawRepresentable, Hashable, Comparable, Sendable, CustomStringConvertible {
    package var rawValue: UInt8
    package init(rawValue: UInt8) { self.rawValue = rawValue }

    package static let noMatch = Op(rawValue: 1)  // matches no strings
    package static let emptyMatch = Op(rawValue: 2)  // matches empty string
    package static let literal = Op(rawValue: 3)  // matches Runes sequence
    package static let charClass = Op(rawValue: 4)  // matches Runes interpreted as range pair list
    package static let anyCharNotNL = Op(rawValue: 5)  // matches any character except newline
    package static let anyChar = Op(rawValue: 6)  // matches any character
    package static let beginLine = Op(rawValue: 7)  // matches empty string at beginning of line
    package static let endLine = Op(rawValue: 8)  // matches empty string at end of line
    package static let beginText = Op(rawValue: 9)  // matches empty string at beginning of text
    package static let endText = Op(rawValue: 10)  // matches empty string at end of text
    package static let wordBoundary = Op(rawValue: 11)  // matches word boundary `\b`
    package static let noWordBoundary = Op(rawValue: 12)  // matches word non-boundary `\B`
    package static let capture = Op(rawValue: 13)  // capturing subexpression with index Cap, optional name Name
    package static let star = Op(rawValue: 14)  // matches Sub[0] zero or more times
    package static let plus = Op(rawValue: 15)  // matches Sub[0] one or more times
    package static let quest = Op(rawValue: 16)  // matches Sub[0] zero or one times
    package static let `repeat` = Op(rawValue: 17)  // matches Sub[0] at least Min times, at most Max (Max == -1 is no limit)
    package static let concat = Op(rawValue: 18)  // matches concatenation of Subs
    package static let alternate = Op(rawValue: 19)  // matches alternation of Subs

    static let pseudo = Op(rawValue: 128)  // where pseudo-ops start
    // Pseudo-ops for parsing stack.
    static let leftParen = Op(rawValue: 128)
    static let verticalBar = Op(rawValue: 129)

    package static func < (a: Op, b: Op) -> Bool { a.rawValue < b.rawValue }

    private static let names = [
      "NoMatch", "EmptyMatch", "Literal", "CharClass", "AnyCharNotNL", "AnyChar", "BeginLine",
      "EndLine", "BeginText", "EndText", "WordBoundary", "NoWordBoundary", "Capture", "Star", "Plus",
      "Quest", "Repeat", "Concat", "Alternate",
    ]

    package var description: String {
      if rawValue >= 1 && rawValue <= 19 {
        return Op.names[Int(rawValue) - 1]
      }
      if rawValue == 128 {
        return "opPseudo"
      }
      return "Op(\(rawValue))"
    }
  }
}

extension Syntax.Regexp {
  /// Equal reports whether x and y have identical structure.
  package func equal(_ y: Syntax.Regexp?) -> Bool {
    guard let y else { return false }
    let x = self
    if x.op != y.op {
      return false
    }
    switch x.op {
    case .endText:
      // The parse flags remember whether this is \z or \Z.
      if x.flags.intersection(.wasDollar) != y.flags.intersection(.wasDollar) {
        return false
      }

    case .literal, .charClass:
      return x.flags.intersection(.foldCase) == y.flags.intersection(.foldCase) && x.rune == y.rune

    case .alternate, .concat:
      if x.sub.count != y.sub.count {
        return false
      }
      for (a, b) in zip(x.sub, y.sub) where !a.equal(b) {
        return false
      }
      return true

    case .star, .plus, .quest:
      if x.flags.intersection(.nonGreedy) != y.flags.intersection(.nonGreedy) || !x.sub[0].equal(y.sub[0]) {
        return false
      }

    case .repeat:
      if x.flags.intersection(.nonGreedy) != y.flags.intersection(.nonGreedy) || x.min != y.min
        || x.max != y.max || !x.sub[0].equal(y.sub[0])
      {
        return false
      }

    case .capture:
      if x.cap != y.cap || x.name != y.name || !x.sub[0].equal(y.sub[0]) {
        return false
      }
    default:
      break
    }
    return true
  }
}

/// printFlags is a bit set indicating which flags (including non-capturing parens) to print around a regexp.
private struct PrintFlags: OptionSet {
  var rawValue: UInt8
  static let flagI = PrintFlags(rawValue: 1 << 0)  // (?i:
  static let flagM = PrintFlags(rawValue: 1 << 1)  // (?m:
  static let flagS = PrintFlags(rawValue: 1 << 2)  // (?s:
  static let flagOff = PrintFlags(rawValue: 1 << 3)  // )
  static let flagPrec = PrintFlags(rawValue: 1 << 4)  // (?: )
  static let negShift: UInt8 = 5  // flagI<<negShift is (?-i:

  func shiftedNeg() -> PrintFlags { PrintFlags(rawValue: rawValue << PrintFlags.negShift) }
}

private typealias FlagMap = [ObjectIdentifier: PrintFlags]

/// addSpan enables the flags f around start..last,
/// by setting flags[start] = f and flags[last] = flagOff.
private func addSpan(_ start: Syntax.Regexp, _ last: Syntax.Regexp, _ f: PrintFlags, _ flags: inout FlagMap) {
  flags[ObjectIdentifier(start)] = f
  flags[ObjectIdentifier(last), default: []].formUnion(.flagOff)  // maybe start==last
}

/// calcFlags calculates the flags to print around each subexpression in re,
/// storing that information in flags[sub] for each affected subexpression.
/// calcFlags also calculates the flags that must be active or can't be active
/// around re and returns those flags.
private func calcFlags(_ re: Syntax.Regexp, _ flags: inout FlagMap) -> (must: PrintFlags, cant: PrintFlags) {
  switch re.op {
  case .literal:
    // If literal is fold-sensitive, return (flagI, 0) or (0, flagI)
    // according to whether (?i) is active.
    // If literal is not fold-sensitive, return 0, 0.
    for r in re.rune {
      if Syntax.minFold <= r && r <= Syntax.maxFold && UnicodeTables.simpleFold(r) != r {
        if re.flags.contains(.foldCase) {
          return (.flagI, [])
        } else {
          return ([], .flagI)
        }
      }
    }
    return ([], [])

  case .charClass:
    // If literal is fold-sensitive, return 0, flagI - (?i) has been compiled out.
    // If literal is not fold-sensitive, return 0, 0.
    var i = 0
    while i < re.rune.count {
      let lo = max(Syntax.minFold, re.rune[i])
      let hi = min(Syntax.maxFold, re.rune[i + 1])
      if lo <= hi {
        for r in lo...hi {
          var f = UnicodeTables.simpleFold(r)
          while f != r {
            if !(lo <= f && f <= hi) && !Syntax.inCharClass(f, re.rune) {
              return ([], .flagI)
            }
            f = UnicodeTables.simpleFold(f)
          }
        }
      }
      i += 2
    }
    return ([], [])

  case .anyCharNotNL:  // (?-s).
    return ([], .flagS)

  case .anyChar:  // (?s).
    return (.flagS, [])

  case .beginLine, .endLine:  // (?m)^ (?m)$
    return (.flagM, [])

  case .endText:
    if re.flags.contains(.wasDollar) {  // (?-m)$
      return ([], .flagM)
    }
    return ([], [])

  case .capture, .star, .plus, .quest, .repeat:
    return calcFlags(re.sub[0], &flags)

  case .concat, .alternate:
    // Gather the must and cant for each subexpression.
    // When we find a conflicting subexpression, insert the necessary
    // flags around the previously identified span and start over.
    var must: PrintFlags = []
    var cant: PrintFlags = []
    var allCant: PrintFlags = []
    var start = 0
    var last = 0
    var did = false
    for (i, sub) in re.sub.enumerated() {
      let (subMust, subCant) = calcFlags(sub, &flags)
      if !must.intersection(subCant).isEmpty || !subMust.intersection(cant).isEmpty {
        if !must.isEmpty {
          addSpan(re.sub[start], re.sub[last], must, &flags)
        }
        must = []
        cant = []
        start = i
        did = true
      }
      must.formUnion(subMust)
      cant.formUnion(subCant)
      allCant.formUnion(subCant)
      if !subMust.isEmpty {
        last = i
      }
      if must.isEmpty && start == i {
        start += 1
      }
    }
    if !did {
      // No conflicts: pass the accumulated must and cant upward.
      return (must, cant)
    }
    if !must.isEmpty {
      // Conflicts found; need to finish final span.
      addSpan(re.sub[start], re.sub[last], must, &flags)
    }
    return ([], allCant)

  default:
    return ([], [])
  }
}

/// writeRegexp writes the Perl syntax for the regular expression re to b.
private func writeRegexp(_ b: inout String, _ re: Syntax.Regexp, _ f0: PrintFlags, _ flags: FlagMap) {
  var f = f0.union(flags[ObjectIdentifier(re)] ?? [])
  if f.contains(.flagPrec) && !f.subtracting([.flagOff, .flagPrec]).isEmpty && f.contains(.flagOff) {
    // flagPrec is redundant with other flags being added and terminated
    f.remove(.flagPrec)
  }
  if !f.subtracting([.flagOff, .flagPrec]).isEmpty {
    b += "(?"
    if f.contains(.flagI) {
      b += "i"
    }
    if f.contains(.flagM) {
      b += "m"
    }
    if f.contains(.flagS) {
      b += "s"
    }
    if !f.intersection(PrintFlags([.flagM, .flagS]).shiftedNeg()).isEmpty {
      b += "-"
      if !f.intersection(PrintFlags.flagM.shiftedNeg()).isEmpty {
        b += "m"
      }
      if !f.intersection(PrintFlags.flagS.shiftedNeg()).isEmpty {
        b += "s"
      }
    }
    b += ":"
  }
  var closers = ""
  if f.contains(.flagOff) {
    closers = ")"
  }
  if f.contains(.flagPrec) {
    b += "(?:"
    closers = ")" + closers
  }
  defer { b += closers }

  switch re.op {
  case .noMatch:
    b += #"[^\x00-\x{10FFFF}]"#
  case .emptyMatch:
    b += "(?:)"
  case .literal:
    for r in re.rune {
      escape(&b, r, false)
    }
  case .charClass:
    if re.rune.count % 2 != 0 {
      b += "[invalid char class]"
      break
    }
    b += "["
    if re.rune.isEmpty {
      b += #"^\x00-\x{10FFFF}"#
    } else if re.rune[0] == 0 && re.rune[re.rune.count - 1] == UnicodeTables.maxRune && re.rune.count > 2 {
      // Contains 0 and MaxRune. Probably a negated class.
      // Print the gaps.
      b += "^"
      var i = 1
      while i < re.rune.count - 1 {
        let lo = re.rune[i] + 1
        let hi = re.rune[i + 1] - 1
        escape(&b, lo, lo == 0x2D)
        if lo != hi {
          if hi != lo + 1 {
            b += "-"
          }
          escape(&b, hi, hi == 0x2D)
        }
        i += 2
      }
    } else {
      var i = 0
      while i < re.rune.count {
        let lo = re.rune[i]
        let hi = re.rune[i + 1]
        escape(&b, lo, lo == 0x2D)
        if lo != hi {
          if hi != lo + 1 {
            b += "-"
          }
          escape(&b, hi, hi == 0x2D)
        }
        i += 2
      }
    }
    b += "]"
  case .anyCharNotNL, .anyChar:
    b += "."
  case .beginLine:
    b += "^"
  case .endLine:
    b += "$"
  case .beginText:
    b += #"\A"#
  case .endText:
    if re.flags.contains(.wasDollar) {
      b += "$"
    } else {
      b += #"\z"#
    }
  case .wordBoundary:
    b += #"\b"#
  case .noWordBoundary:
    b += #"\B"#
  case .capture:
    if !re.name.isEmpty {
      b += "(?P<"
      b += re.name
      b += ">"
    } else {
      b += "("
    }
    if re.sub[0].op != .emptyMatch {
      writeRegexp(&b, re.sub[0], flags[ObjectIdentifier(re.sub[0])] ?? [], flags)
    }
    b += ")"
  case .star, .plus, .quest, .repeat:
    var p: PrintFlags = []
    let sub = re.sub[0]
    if sub.op > .capture || sub.op == .literal && sub.rune.count > 1 {
      p = .flagPrec
    }
    writeRegexp(&b, sub, p, flags)

    switch re.op {
    case .star:
      b += "*"
    case .plus:
      b += "+"
    case .quest:
      b += "?"
    default:
      b += "{"
      b += String(re.min)
      if re.max != re.min {
        b += ","
        if re.max >= 0 {
          b += String(re.max)
        }
      }
      b += "}"
    }
    if re.flags.contains(.nonGreedy) {
      b += "?"
    }
  case .concat:
    for sub in re.sub {
      var p: PrintFlags = []
      if sub.op == .alternate {
        p = .flagPrec
      }
      writeRegexp(&b, sub, p, flags)
    }
  case .alternate:
    for (i, sub) in re.sub.enumerated() {
      if i > 0 {
        b += "|"
      }
      writeRegexp(&b, sub, [], flags)
    }
  default:
    b += "<invalid op\(re.op.rawValue)>"
  }
}

extension Syntax.Regexp: CustomStringConvertible {
  package var description: String {
    var b = ""
    var flags: FlagMap = [:]
    var (must, cant) = calcFlags(self, &flags)
    must.formUnion(cant.subtracting(.flagI).shiftedNeg())
    if !must.isEmpty {
      must.formUnion(.flagOff)
    }
    writeRegexp(&b, self, must, flags)
    return b
  }
}

private let meta = Array(#"\.+*?()|[]{}^$"#.unicodeScalars).map { Rune($0.value) }

private func escape(_ b: inout String, _ r: Rune, _ force: Bool) {
  if UnicodeTables.isPrint(r) {
    if meta.contains(r) || force {
      b += "\\"
    }
    b += GoUTF8.string(runes: CollectionOfOne(r))
    return
  }

  switch r {
  case 0x07:
    b += #"\a"#
  case 0x0C:
    b += #"\f"#
  case 0x0A:
    b += #"\n"#
  case 0x0D:
    b += #"\r"#
  case 0x09:
    b += #"\t"#
  case 0x0B:
    b += #"\v"#
  default:
    if r < 0x100 {
      b += #"\x"#
      let s = String(r, radix: 16)
      if s.utf8.count == 1 {
        b += "0"
      }
      b += s
      break
    }
    b += #"\x{"#
    b += String(r, radix: 16)
    b += "}"
  }
}

extension Syntax.Regexp {
  /// MaxCap walks the regexp to find the maximum capture index.
  package func maxCap() -> Int {
    var m = 0
    if op == .capture {
      m = cap
    }
    for sub in sub {
      let n = sub.maxCap()
      if m < n {
        m = n
      }
    }
    return m
  }

  /// CapNames walks the regexp to find the names of capturing groups.
  package func capNames() -> [String] {
    var names = [String](repeating: "", count: maxCap() + 1)
    capNames(&names)
    return names
  }

  private func capNames(_ names: inout [String]) {
    if op == .capture {
      names[cap] = name
    }
    for sub in sub {
      sub.capNames(&names)
    }
  }
}
