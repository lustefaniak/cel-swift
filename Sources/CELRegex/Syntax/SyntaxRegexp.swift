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

    /// Releases the subtree iteratively. Simplified trees can be thousands of nodes deep
    /// (x{1,1000} becomes x(x(x...)?)?), and the default recursive release would overflow a
    /// 512 KB thread stack; Go's garbage collector has no such recursion.
    deinit {
      if sub.isEmpty && nextFree == nil {
        return
      }
      var stack = sub
      sub = []
      if let f = nextFree {
        stack.append(f)
        nextFree = nil
      }
      while var node = stack.popLast() {
        if isKnownUniquelyReferenced(&node) {
          stack.append(contentsOf: node.sub)
          node.sub = []
          if let f = node.nextFree {
            stack.append(f)
            node.nextFree = nil
          }
        }
      }
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
  ///
  /// Go's version recurses; this compares the same node pairs with an explicit stack.
  package func equal(_ y: Syntax.Regexp?) -> Bool {
    guard let y else { return false }
    var pairs: [(Syntax.Regexp, Syntax.Regexp)] = [(self, y)]
    while let (x, y) = pairs.popLast() {
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
        if !(x.flags.intersection(.foldCase) == y.flags.intersection(.foldCase) && x.rune == y.rune) {
          return false
        }

      case .alternate, .concat:
        if x.sub.count != y.sub.count {
          return false
        }
        pairs.append(contentsOf: zip(x.sub, y.sub).reversed())

      case .star, .plus, .quest:
        if x.flags.intersection(.nonGreedy) != y.flags.intersection(.nonGreedy) {
          return false
        }
        pairs.append((x.sub[0], y.sub[0]))

      case .repeat:
        if x.flags.intersection(.nonGreedy) != y.flags.intersection(.nonGreedy) || x.min != y.min
          || x.max != y.max
        {
          return false
        }
        pairs.append((x.sub[0], y.sub[0]))

      case .capture:
        if x.cap != y.cap || x.name != y.name {
          return false
        }
        pairs.append((x.sub[0], y.sub[0]))
      default:
        break
      }
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
private func calcFlags(_ root: Syntax.Regexp, _ flags: inout FlagMap) -> (must: PrintFlags, cant: PrintFlags) {
  // Go's calcFlags recurses; here each node is a frame and child results are fed back one at a
  // time, so the side effects on flags (addSpan) happen in exactly Go's order.
  struct Frame {
    var re: Syntax.Regexp
    var i = 0
    var must: PrintFlags = []
    var cant: PrintFlags = []
    var allCant: PrintFlags = []
    var start = 0
    var last = 0
    var did = false
  }
  var frames = [Frame(re: root)]
  var ret: (must: PrintFlags, cant: PrintFlags)? = nil
  while let top = frames.indices.last {
    let re = frames[top].re
    switch re.op {
    case .capture, .star, .plus, .quest, .repeat:
      if ret == nil {
        frames.append(Frame(re: re.sub[0]))
        continue
      }
      // Pass the child's result up unchanged.
      frames.removeLast()

    case .concat, .alternate:
      // Gather the must and cant for each subexpression.
      // When we find a conflicting subexpression, insert the necessary
      // flags around the previously identified span and start over.
      if let (subMust, subCant) = ret {
        ret = nil
        var f = frames[top]
        let i = f.i
        if !f.must.intersection(subCant).isEmpty || !subMust.intersection(f.cant).isEmpty {
          if !f.must.isEmpty {
            addSpan(re.sub[f.start], re.sub[f.last], f.must, &flags)
          }
          f.must = []
          f.cant = []
          f.start = i
          f.did = true
        }
        f.must.formUnion(subMust)
        f.cant.formUnion(subCant)
        f.allCant.formUnion(subCant)
        if !subMust.isEmpty {
          f.last = i
        }
        if f.must.isEmpty && f.start == i {
          f.start += 1
        }
        f.i += 1
        frames[top] = f
      }
      let f = frames[top]
      if f.i < re.sub.count {
        frames.append(Frame(re: re.sub[f.i]))
        continue
      }
      frames.removeLast()
      if !f.did {
        // No conflicts: pass the accumulated must and cant upward.
        ret = (f.must, f.cant)
      } else {
        if !f.must.isEmpty {
          // Conflicts found; need to finish final span.
          addSpan(re.sub[f.start], re.sub[f.last], f.must, &flags)
        }
        ret = ([], f.allCant)
      }

    default:
      frames.removeLast()
      ret = calcFlagsLeaf(re)
    }
  }
  return ret ?? ([], [])
}

/// The cases of Go's calcFlags that do not recurse.
private func calcFlagsLeaf(_ re: Syntax.Regexp) -> (must: PrintFlags, cant: PrintFlags) {
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

  default:
    return ([], [])
  }
}

/// writeRegexp writes the Perl syntax for the regular expression re to b.
///
/// Go's writeRegexp recurses; here each node is a frame that writes its opening, its children
/// one at a time, and then its closing, which produces the same text.
private func writeRegexp(_ b: inout String, _ root: Syntax.Regexp, _ f0: PrintFlags, _ flags: FlagMap) {
  struct Frame {
    var re: Syntax.Regexp
    var f: PrintFlags
    var closers = ""
    var i = -1  // -1: not started; otherwise the next child to write
  }
  var frames = [Frame(re: root, f: f0)]
  while let top = frames.indices.last {
    let re = frames[top].re
    if frames[top].i < 0 {
      frames[top].closers = writeFlagsPrefix(&b, re, frames[top].f, flags)
      frames[top].i = 0
      switch re.op {
      case .capture:
        if !re.name.isEmpty {
          b += "(?P<"
          b += re.name
          b += ">"
        } else {
          b += "("
        }
      case .star, .plus, .quest, .repeat, .concat, .alternate:
        break
      default:
        writeLeaf(&b, re)
        b += frames[top].closers
        frames.removeLast()
        continue
      }
    }

    let i = frames[top].i
    frames[top].i += 1
    switch re.op {
    case .capture:
      if i == 0 && re.sub[0].op != .emptyMatch {
        frames.append(Frame(re: re.sub[0], f: flags[ObjectIdentifier(re.sub[0])] ?? []))
        continue
      }
      b += ")"
    case .star, .plus, .quest, .repeat:
      if i == 0 {
        var p: PrintFlags = []
        let sub = re.sub[0]
        if sub.op > .capture || sub.op == .literal && sub.rune.count > 1 {
          p = .flagPrec
        }
        frames.append(Frame(re: sub, f: p))
        continue
      }
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
      if i < re.sub.count {
        let sub = re.sub[i]
        var p: PrintFlags = []
        if sub.op == .alternate {
          p = .flagPrec
        }
        frames.append(Frame(re: sub, f: p))
        continue
      }
    case .alternate:
      if i < re.sub.count {
        if i > 0 {
          b += "|"
        }
        frames.append(Frame(re: re.sub[i], f: []))
        continue
      }
    default:
      break
    }
    b += frames[top].closers
    frames.removeLast()
  }
}

/// The flag prefix of Go's writeRegexp; returns the closing text its defers would write.
private func writeFlagsPrefix(_ b: inout String, _ re: Syntax.Regexp, _ f0: PrintFlags, _ flags: FlagMap) -> String {
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
  return closers
}

/// The cases of Go's writeRegexp that do not recurse.
private func writeLeaf(_ b: inout String, _ re: Syntax.Regexp) {
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
  /// Visits the nodes of the tree in pre-order (Go's recursion order), without recursing.
  func forEachPreOrder(_ body: (Syntax.Regexp) -> Void) {
    var stack: [Syntax.Regexp] = [self]
    while let re = stack.popLast() {
      body(re)
      stack.append(contentsOf: re.sub.reversed())
    }
  }

  /// MaxCap walks the regexp to find the maximum capture index.
  package func maxCap() -> Int {
    var m = 0
    forEachPreOrder { re in
      if re.op == .capture && m < re.cap {
        m = re.cap
      }
    }
    return m
  }

  /// CapNames walks the regexp to find the names of capturing groups.
  package func capNames() -> [String] {
    var names = [String](repeating: "", count: maxCap() + 1)
    forEachPreOrder { re in
      if re.op == .capture {
        names[re.cap] = re.name
      }
    }
    return names
  }
}
