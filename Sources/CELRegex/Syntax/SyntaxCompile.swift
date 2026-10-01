// Copyright 2011 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// Port of Go's regexp/syntax/compile.go.

/// A patchList is a list of instruction pointers that need to be filled in (patched).
/// Because the pointers haven't been filled in yet, we can reuse their storage
/// to hold the list. It's kind of sleazy, but works well in practice.
/// See https://swtch.com/~rsc/regexp/regexp1.html for inspiration.
///
/// These aren't really pointers: they're integers, so we can reinterpret them
/// this way without using package unsafe. A value l.head denotes
/// p.inst[l.head>>1].Out (l.head&1==0) or .Arg (l.head&1==1).
/// head == 0 denotes the empty list, okay because we start every program
/// with a fail instruction, so we'll never want to point at its output link.
private struct PatchList {
  var head: UInt32
  var tail: UInt32

  init(_ n: UInt32) {
    head = n
    tail = n
  }

  init(head: UInt32, tail: UInt32) {
    self.head = head
    self.tail = tail
  }

  static let empty = PatchList(0)

  func patch(_ p: inout Syntax.Prog, _ val: UInt32) {
    var head = self.head
    while head != 0 {
      let idx = Int(head >> 1)
      if head & 1 == 0 {
        head = p.inst[idx].out
        p.inst[idx].out = val
      } else {
        head = p.inst[idx].arg
        p.inst[idx].arg = val
      }
    }
  }

  func append(_ p: inout Syntax.Prog, _ l2: PatchList) -> PatchList {
    if head == 0 {
      return l2
    }
    if l2.head == 0 {
      return self
    }

    let idx = Int(tail >> 1)
    if tail & 1 == 0 {
      p.inst[idx].out = l2.head
    } else {
      p.inst[idx].arg = l2.head
    }
    return PatchList(head: head, tail: l2.tail)
  }
}

/// A frag represents a compiled program fragment.
private struct Frag {
  var i: UInt32 = 0  // index of first instruction
  var out = PatchList.empty  // where to record end instruction
  var nullable = false  // whether fragment can match empty string
}

private let anyRuneNotNL: [Rune] = [0, 0x0A - 1, 0x0A + 1, UnicodeTables.maxRune]
private let anyRune: [Rune] = [0, UnicodeTables.maxRune]

private struct Compiler {
  var p = Syntax.Prog()

  init() {
    p.numCap = 2  // implicit ( and ) for whole match $0
    _ = inst(.fail)
  }

  /// Pending work for the explicit-stack compile.
  private enum Task {
    case enter(Syntax.Regexp)
    case captureEnd(cap: Int, bra: Frag)
    case star(nongreedy: Bool)
    case plus(nongreedy: Bool)
    case quest(nongreedy: Bool)
    case concatNext(Syntax.Regexp, Int)
    case concatCat(Syntax.Regexp, Int)
    case alternateNext(Syntax.Regexp, Int)
    case alternateAlt(Syntax.Regexp, Int)
  }

  /// compile is Go's recursive compile, run with an explicit stack: simplified trees can be
  /// thousands of nodes deep (x{0,1000} nests 2000 levels), more than a 512 KB thread stack
  /// holds. Instructions are emitted in exactly the order of Go's recursion.
  mutating func compile(_ root: Syntax.Regexp) -> Frag {
    var tasks: [Task] = [.enter(root)]
    var results: [Frag] = []
    while let task = tasks.popLast() {
      switch task {
      case .enter(let re):
        switch re.op {
        case .capture:
          let bra = cap(UInt32(re.cap << 1))
          tasks.append(.captureEnd(cap: re.cap, bra: bra))
          tasks.append(.enter(re.sub[0]))
        case .star:
          tasks.append(.star(nongreedy: re.flags.contains(.nonGreedy)))
          tasks.append(.enter(re.sub[0]))
        case .plus:
          tasks.append(.plus(nongreedy: re.flags.contains(.nonGreedy)))
          tasks.append(.enter(re.sub[0]))
        case .quest:
          tasks.append(.quest(nongreedy: re.flags.contains(.nonGreedy)))
          tasks.append(.enter(re.sub[0]))
        case .concat:
          if re.sub.isEmpty {
            results.append(nop())
          } else {
            tasks.append(.concatNext(re, 1))
            tasks.append(.enter(re.sub[0]))
          }
        case .alternate:
          results.append(Frag())
          tasks.append(.alternateNext(re, 0))
        default:
          results.append(compileLeaf(re))
        }
      case .captureEnd(let c, let bra):
        let sub = results.removeLast()
        let ket = cap(UInt32(c << 1 | 1))
        results.append(cat(cat(bra, sub), ket))
      case .star(let nongreedy):
        results.append(star(results.removeLast(), nongreedy))
      case .plus(let nongreedy):
        results.append(plus(results.removeLast(), nongreedy))
      case .quest(let nongreedy):
        results.append(quest(results.removeLast(), nongreedy))
      case .concatNext(let re, let i):
        if i < re.sub.count {
          tasks.append(.concatCat(re, i))
          tasks.append(.enter(re.sub[i]))
        }
      case .concatCat(let re, let i):
        let f2 = results.removeLast()
        let f1 = results.removeLast()
        results.append(cat(f1, f2))
        tasks.append(.concatNext(re, i + 1))
      case .alternateNext(let re, let i):
        if i < re.sub.count {
          tasks.append(.alternateAlt(re, i))
          tasks.append(.enter(re.sub[i]))
        }
      case .alternateAlt(let re, let i):
        let f2 = results.removeLast()
        let f1 = results.removeLast()
        results.append(alt(f1, f2))
        tasks.append(.alternateNext(re, i + 1))
      }
    }
    return results[0]
  }

  /// The cases of Go's compile that do not recurse.
  private mutating func compileLeaf(_ re: Syntax.Regexp) -> Frag {
    switch re.op {
    case .noMatch:
      return fail()
    case .emptyMatch:
      return nop()
    case .literal:
      if re.rune.isEmpty {
        return nop()
      }
      var f = Frag()
      for j in re.rune.indices {
        let f1 = rune([re.rune[j]], re.flags)
        if j == 0 {
          f = f1
        } else {
          f = cat(f, f1)
        }
      }
      return f
    case .charClass:
      return rune(re.rune, re.flags)
    case .anyCharNotNL:
      return rune(anyRuneNotNL, [])
    case .anyChar:
      return rune(anyRune, [])
    case .beginLine:
      return empty(.beginLine)
    case .endLine:
      return empty(.endLine)
    case .beginText:
      return empty(.beginText)
    case .endText:
      return empty(.endText)
    case .wordBoundary:
      return empty(.wordBoundary)
    case .noWordBoundary:
      return empty(.noWordBoundary)
    default:
      // OpRepeat: the regexp must have been simplified (Go panics the same way).
      preconditionFailure("regexp: unhandled case in compile")
    }
  }

  mutating func inst(_ op: Syntax.InstOp) -> Frag {
    // TODO: impose length limit
    let f = Frag(i: UInt32(p.inst.count), nullable: true)
    p.inst.append(Syntax.Inst(op: op))
    return f
  }

  mutating func nop() -> Frag {
    var f = inst(.nop)
    f.out = PatchList(f.i << 1)
    return f
  }

  func fail() -> Frag {
    Frag()
  }

  mutating func cap(_ arg: UInt32) -> Frag {
    var f = inst(.capture)
    f.out = PatchList(f.i << 1)
    p.inst[Int(f.i)].arg = arg

    if p.numCap < Int(arg) + 1 {
      p.numCap = Int(arg) + 1
    }
    return f
  }

  mutating func cat(_ f1: Frag, _ f2: Frag) -> Frag {
    // concat of failure is failure
    if f1.i == 0 || f2.i == 0 {
      return Frag()
    }

    // TODO: elide nop

    f1.out.patch(&p, f2.i)
    return Frag(i: f1.i, out: f2.out, nullable: f1.nullable && f2.nullable)
  }

  mutating func alt(_ f1: Frag, _ f2: Frag) -> Frag {
    // alt of failure is other
    if f1.i == 0 {
      return f2
    }
    if f2.i == 0 {
      return f1
    }

    var f = inst(.alt)
    p.inst[Int(f.i)].out = f1.i
    p.inst[Int(f.i)].arg = f2.i
    f.out = f1.out.append(&p, f2.out)
    f.nullable = f1.nullable || f2.nullable
    return f
  }

  mutating func quest(_ f1: Frag, _ nongreedy: Bool) -> Frag {
    var f = inst(.alt)
    if nongreedy {
      p.inst[Int(f.i)].arg = f1.i
      f.out = PatchList(f.i << 1)
    } else {
      p.inst[Int(f.i)].out = f1.i
      f.out = PatchList(f.i << 1 | 1)
    }
    f.out = f.out.append(&p, f1.out)
    return f
  }

  /// loop returns the fragment for the main loop of a plus or star.
  /// For plus, it can be used after changing the entry to f1.i.
  /// For star, it can be used directly when f1 can't match an empty string.
  /// (When f1 can match an empty string, f1* must be implemented as (f1+)?
  /// to get the priority match order correct.)
  mutating func loop(_ f1: Frag, _ nongreedy: Bool) -> Frag {
    var f = inst(.alt)
    if nongreedy {
      p.inst[Int(f.i)].arg = f1.i
      f.out = PatchList(f.i << 1)
    } else {
      p.inst[Int(f.i)].out = f1.i
      f.out = PatchList(f.i << 1 | 1)
    }
    f1.out.patch(&p, f.i)
    return f
  }

  mutating func star(_ f1: Frag, _ nongreedy: Bool) -> Frag {
    if f1.nullable {
      // Use (f1+)? to get priority match order correct.
      // See golang.org/issue/46123.
      return quest(plus(f1, nongreedy), nongreedy)
    }
    return loop(f1, nongreedy)
  }

  mutating func plus(_ f1: Frag, _ nongreedy: Bool) -> Frag {
    Frag(i: f1.i, out: loop(f1, nongreedy).out, nullable: f1.nullable)
  }

  mutating func empty(_ op: Syntax.EmptyOp) -> Frag {
    var f = inst(.emptyWidth)
    p.inst[Int(f.i)].arg = UInt32(op.rawValue)
    f.out = PatchList(f.i << 1)
    return f
  }

  mutating func rune(_ r: [Rune], _ flags0: Syntax.Flags) -> Frag {
    var f = inst(.rune)
    f.nullable = false
    let idx = Int(f.i)
    p.inst[idx].rune = r
    var flags = flags0.intersection(.foldCase)  // only relevant flag is FoldCase
    if r.count != 1 || UnicodeTables.simpleFold(r[0]) == r[0] {
      // and sometimes not even that
      flags.remove(.foldCase)
    }
    p.inst[idx].arg = UInt32(flags.rawValue)
    f.out = PatchList(f.i << 1)

    // Special cases for exec machine.
    if !flags.contains(.foldCase) && (r.count == 1 || r.count == 2 && r[0] == r[1]) {
      p.inst[idx].op = .rune1
    } else if r.count == 2 && r[0] == 0 && r[1] == UnicodeTables.maxRune {
      p.inst[idx].op = .runeAny
    } else if r.count == 4 && r[0] == 0 && r[1] == 0x0A - 1 && r[2] == 0x0A + 1 && r[3] == UnicodeTables.maxRune {
      p.inst[idx].op = .runeAnyNotNL
    }

    return f
  }
}

extension Syntax {
  /// Compile compiles the regexp into a program to be executed.
  /// The regexp should have been simplified already (returned from re.Simplify).
  package static func compile(_ re: Regexp) -> Prog {
    var c = Compiler()
    let f = c.compile(re)
    let m = c.inst(.match)
    f.out.patch(&c.p, m.i)
    c.p.start = Int(f.i)
    return c.p
  }
}
