// Copyright 2011 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// Port of Go's regexp/syntax/prog.go.

extension Syntax {
  /// A Prog is a compiled regular expression program.
  package struct Prog: Sendable {
    package var inst: [Inst] = []
    package var start = 0  // index of start instruction
    package var numCap = 0  // number of InstCapture insts in re
  }

  /// An InstOp is an instruction opcode.
  package enum InstOp: UInt8, Sendable, CustomStringConvertible {
    case alt = 0
    case altMatch
    case capture
    case emptyWidth
    case match
    case fail
    case nop
    case rune
    case rune1
    case runeAny
    case runeAnyNotNL

    package var description: String {
      switch self {
      case .alt: return "InstAlt"
      case .altMatch: return "InstAltMatch"
      case .capture: return "InstCapture"
      case .emptyWidth: return "InstEmptyWidth"
      case .match: return "InstMatch"
      case .fail: return "InstFail"
      case .nop: return "InstNop"
      case .rune: return "InstRune"
      case .rune1: return "InstRune1"
      case .runeAny: return "InstRuneAny"
      case .runeAnyNotNL: return "InstRuneAnyNotNL"
      }
    }
  }

  /// An EmptyOp specifies a kind or mixture of zero-width assertions.
  package struct EmptyOp: OptionSet, Hashable, Sendable {
    package var rawValue: UInt8
    package init(rawValue: UInt8) { self.rawValue = rawValue }

    package static let beginLine = EmptyOp(rawValue: 1 << 0)
    package static let endLine = EmptyOp(rawValue: 1 << 1)
    package static let beginText = EmptyOp(rawValue: 1 << 2)
    package static let endText = EmptyOp(rawValue: 1 << 3)
    package static let wordBoundary = EmptyOp(rawValue: 1 << 4)
    package static let noWordBoundary = EmptyOp(rawValue: 1 << 5)

    /// ^EmptyOp(0): no match is possible.
    package static let impossible = EmptyOp(rawValue: 0xFF)
  }

  /// EmptyOpContext returns the zero-width assertions
  /// satisfied at the position between the runes r1 and r2.
  /// Passing r1 == -1 indicates that the position is
  /// at the beginning of the text.
  /// Passing r2 == -1 indicates that the position is
  /// at the end of the text.
  package static func emptyOpContext(_ r1: Rune, _ r2: Rune) -> EmptyOp {
    var op: EmptyOp = .noWordBoundary
    var boundary: UInt8 = 0
    if isWordChar(r1) {
      boundary = 1
    } else if r1 == 0x0A {
      op.formUnion(.beginLine)
    } else if r1 < 0 {
      op.formUnion([.beginText, .beginLine])
    }
    if isWordChar(r2) {
      boundary ^= 1
    } else if r2 == 0x0A {
      op.formUnion(.endLine)
    } else if r2 < 0 {
      op.formUnion([.endText, .endLine])
    }
    if boundary != 0 {  // IsWordChar(r1) != IsWordChar(r2)
      op.formSymmetricDifference([.wordBoundary, .noWordBoundary])
    }
    return op
  }

  /// IsWordChar reports whether r is considered a “word character”
  /// during the evaluation of the \b and \B zero-width assertions.
  /// These assertions are ASCII-only: the word characters are [A-Za-z0-9_].
  @inline(__always)
  package static func isWordChar(_ r: Rune) -> Bool {
    // Test for lowercase letters first, as these occur more
    // frequently than uppercase letters in common cases.
    0x61 <= r && r <= 0x7A || 0x41 <= r && r <= 0x5A || 0x30 <= r && r <= 0x39 || r == 0x5F
  }

  /// An Inst is a single instruction in a regular expression program.
  package struct Inst: Sendable {
    package var op: InstOp
    package var out: UInt32 = 0  // all but InstMatch, InstFail
    package var arg: UInt32 = 0  // InstAlt, InstAltMatch, InstCapture, InstEmptyWidth
    package var rune: [Rune] = []

    package init(op: InstOp) {
      self.op = op
    }
  }
}

extension Syntax.Prog: CustomStringConvertible {
  package var description: String {
    var b = ""
    dumpProg(&b, self)
    return b
  }

  /// skipNop follows any no-op or capturing instructions.
  func skipNop(_ pc: UInt32) -> Syntax.Inst {
    var i = inst[Int(pc)]
    while i.op == .nop || i.op == .capture {
      i = inst[Int(i.out)]
    }
    return i
  }

  /// Prefix returns a literal string that all matches for the
  /// regexp must start with. Complete is true if the prefix
  /// is the entire match.
  package func prefix() -> (prefix: [UInt8], complete: Bool) {
    var i = skipNop(UInt32(start))

    // Avoid allocation of buffer if prefix is empty.
    if i.opClass != .rune || i.rune.count != 1 {
      return ([], i.op == .match)
    }

    // Have prefix; gather characters.
    var buf: [UInt8] = []
    while i.opClass == .rune && i.rune.count == 1 && Syntax.Flags(rawValue: UInt16(truncatingIfNeeded: i.arg))
      .intersection(.foldCase).isEmpty && i.rune[0] != GoUTF8.runeError
    {
      GoUTF8.appendRune(&buf, i.rune[0])
      i = skipNop(i.out)
    }
    return (buf, i.op == .match)
  }

  /// StartCond returns the leading empty-width conditions that must
  /// be true in any match. It returns ^EmptyOp(0) if no matches are possible.
  package func startCond() -> Syntax.EmptyOp {
    var flag: Syntax.EmptyOp = []
    var pc = UInt32(start)
    var i = inst[Int(pc)]
    loop: while true {
      switch i.op {
      case .emptyWidth:
        flag.formUnion(Syntax.EmptyOp(rawValue: UInt8(truncatingIfNeeded: i.arg)))
      case .fail:
        return .impossible
      case .capture, .nop:
        // skip
        break
      default:
        break loop
      }
      pc = i.out
      i = inst[Int(pc)]
    }
    return flag
  }
}

extension Syntax.Inst: CustomStringConvertible {
  static let noMatch = -1

  /// op returns i.Op but merges all the Rune special cases into InstRune
  var opClass: Syntax.InstOp {
    switch op {
    case .rune1, .runeAny, .runeAnyNotNL:
      return .rune
    default:
      return op
    }
  }

  /// MatchRune reports whether the instruction matches (and consumes) r.
  /// It should only be called when i.Op == InstRune.
  @inline(__always)
  package func matchRune(_ r: Rune) -> Bool {
    matchRunePos(r) != Syntax.Inst.noMatch
  }

  /// MatchRunePos checks whether the instruction matches (and consumes) r.
  /// If so, MatchRunePos returns the index of the matching rune pair
  /// (or, when len(i.Rune) == 1, rune singleton).
  /// If not, MatchRunePos returns -1.
  package func matchRunePos(_ r: Rune) -> Int {
    let foldCase = Syntax.Flags(rawValue: UInt16(truncatingIfNeeded: arg)).contains(.foldCase)
    return rune.withUnsafeBufferPointer { Syntax.Inst.matchRunePos($0, foldCase: foldCase, r) }
  }

  /// The body of MatchRunePos over the instruction's runes; the Pike VM calls it with the
  /// program's flattened rune storage.
  @inline(__always)
  static func matchRunePos(_ rune: UnsafeBufferPointer<Rune>, foldCase: Bool, _ r: Rune) -> Int {
    switch rune.count {
    case 0:
      return Syntax.Inst.noMatch

    case 1:
      // Special case: single-rune slice is from literal string, not char class.
      let r0 = rune[0]
      if r == r0 {
        return 0
      }
      if foldCase {
        var r1 = UnicodeTables.simpleFold(r0)
        while r1 != r0 {
          if r == r1 {
            return 0
          }
          r1 = UnicodeTables.simpleFold(r1)
        }
      }
      return Syntax.Inst.noMatch

    case 2:
      if r >= rune[0] && r <= rune[1] {
        return 0
      }
      return Syntax.Inst.noMatch

    case 4, 6, 8:
      // Linear search for a few pairs.
      // Should handle ASCII well.
      var j = 0
      while j < rune.count {
        if r < rune[j] {
          return Syntax.Inst.noMatch
        }
        if r <= rune[j + 1] {
          return j / 2
        }
        j += 2
      }
      return Syntax.Inst.noMatch

    default:
      // Otherwise binary search.
      var lo = 0
      var hi = rune.count / 2
      while lo < hi {
        let m = Int(UInt(lo + hi) >> 1)
        let c = rune[2 * m]
        if c <= r {
          if r <= rune[2 * m + 1] {
            return m
          }
          lo = m + 1
        } else {
          hi = m
        }
      }
      return Syntax.Inst.noMatch
    }
  }

  /// MatchEmptyWidth reports whether the instruction matches
  /// an empty string between the runes before and after.
  /// It should only be called when i.Op == InstEmptyWidth.
  package func matchEmptyWidth(_ before: Rune, _ after: Rune) -> Bool {
    switch Syntax.EmptyOp(rawValue: UInt8(truncatingIfNeeded: arg)) {
    case .beginLine:
      return before == 0x0A || before == -1
    case .endLine:
      return after == 0x0A || after == -1
    case .beginText:
      return before == -1
    case .endText:
      return after == -1
    case .wordBoundary:
      return Syntax.isWordChar(before) != Syntax.isWordChar(after)
    case .noWordBoundary:
      return Syntax.isWordChar(before) == Syntax.isWordChar(after)
    default:
      preconditionFailure("unknown empty width arg")
    }
  }

  package var description: String {
    var b = ""
    dumpInst(&b, self)
    return b
  }
}

private func dumpProg(_ b: inout String, _ p: Syntax.Prog) {
  for (j, i) in p.inst.enumerated() {
    var pc = String(j)
    if pc.utf8.count < 3 {
      b += String(repeating: " ", count: 3 - pc.utf8.count)
    }
    if j == p.start {
      pc += "*"
    }
    b += pc + "\t"
    dumpInst(&b, i)
    b += "\n"
  }
}

private func dumpInst(_ b: inout String, _ i: Syntax.Inst) {
  switch i.op {
  case .alt:
    b += "alt -> \(i.out), \(i.arg)"
  case .altMatch:
    b += "altmatch -> \(i.out), \(i.arg)"
  case .capture:
    b += "cap \(i.arg) -> \(i.out)"
  case .emptyWidth:
    b += "empty \(i.arg) -> \(i.out)"
  case .match:
    b += "match"
  case .fail:
    b += "fail"
  case .nop:
    b += "nop -> \(i.out)"
  case .rune:
    b += "rune " + GoStrconv.quoteToASCII(GoUTF8.bytes(i.rune))
    if Syntax.Flags(rawValue: UInt16(truncatingIfNeeded: i.arg)).contains(.foldCase) {
      b += "/i"
    }
    b += " -> \(i.out)"
  case .rune1:
    b += "rune1 " + GoStrconv.quoteToASCII(GoUTF8.bytes(i.rune)) + " -> \(i.out)"
  case .runeAny:
    b += "any -> \(i.out)"
  case .runeAnyNotNL:
    b += "anynotnl -> \(i.out)"
  }
}
