// Copyright 2014 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// Port of Go's regexp/onepass.go.
//
// "One-pass" regexp execution.
// Some regexps can be analyzed to determine that they never need
// backtracking: they are guaranteed to run in one pass over the string
// without bothering to save all the usual NFA state.
// Detect those and execute them more quickly.

/// A onePassProg is a compiled one-pass regular expression program.
/// It is the same as syntax.Prog except for the use of onePassInst.
struct OnePassProg: Sendable {
  var inst: [OnePassInst]
  var start: Int  // index of start instruction
  var numCap: Int  // number of InstCapture insts in re
}

/// A onePassInst is a single instruction in a one-pass regular expression program.
/// It is the same as syntax.Inst except for the new 'Next' field.
struct OnePassInst: Sendable {
  var inst: Syntax.Inst
  var next: [UInt32] = []
}

/// onePassPrefix returns a literal string that all matches for the
/// regexp must start with. Complete is true if the prefix
/// is the entire match. Pc is the index of the last rune instruction
/// in the string. The onePassPrefix skips over the mandatory
/// EmptyBeginText.
func onePassPrefix(_ p: Syntax.Prog) -> (prefix: [UInt8], complete: Bool, pc: UInt32) {
  var i = p.inst[p.start]
  if i.op != .emptyWidth || Syntax.EmptyOp(rawValue: UInt8(truncatingIfNeeded: i.arg)).intersection(.beginText).isEmpty {
    return ([], i.op == .match, UInt32(p.start))
  }
  var pc = i.out
  i = p.inst[Int(pc)]
  while i.op == .nop {
    pc = i.out
    i = p.inst[Int(pc)]
  }
  // Avoid allocation of buffer if prefix is empty.
  if iop(i) != .rune || i.rune.count != 1 {
    return ([], i.op == .match, UInt32(p.start))
  }

  // Have prefix; gather characters.
  var buf: [UInt8] = []
  while iop(i) == .rune && i.rune.count == 1
    && Syntax.Flags(rawValue: UInt16(truncatingIfNeeded: i.arg)).intersection(.foldCase).isEmpty
    && i.rune[0] != GoUTF8.runeError
  {
    GoUTF8.appendRune(&buf, i.rune[0])
    pc = i.out
    i = p.inst[Int(i.out)]
  }
  var complete = false
  if i.op == .emptyWidth
    && !Syntax.EmptyOp(rawValue: UInt8(truncatingIfNeeded: i.arg)).intersection(.endText).isEmpty
    && p.inst[Int(i.out)].op == .match
  {
    complete = true
  }
  return (buf, complete, pc)
}

/// onePassNext selects the next actionable state of the prog, based on the input character.
/// It should only be called when i.Op == InstAlt or InstAltMatch, and from the one-pass machine.
/// One of the alternates may ultimately lead without input to end of line. If the instruction
/// is InstAltMatch the path to the InstMatch is in i.Out, the normal node in i.Next.
func onePassNext(_ i: OnePassInst, _ r: Rune) -> UInt32 {
  let next = i.inst.matchRunePos(r)
  if next >= 0 {
    return i.next[next]
  }
  if i.inst.op == .altMatch {
    return i.inst.out
  }
  return 0
}

private func iop(_ i: Syntax.Inst) -> Syntax.InstOp {
  i.opClass
}

/// Sparse Array implementation is used as a queueOnePass.
private struct QueueOnePass {
  var sparse: [UInt32]
  var dense: [UInt32]
  var size: UInt32 = 0
  var nextIndex: UInt32 = 0

  init(_ size: Int) {
    sparse = [UInt32](repeating: 0, count: size)
    dense = [UInt32](repeating: 0, count: size)
  }

  var isEmpty: Bool {
    nextIndex >= size
  }

  mutating func next() -> UInt32 {
    let n = dense[Int(nextIndex)]
    nextIndex += 1
    return n
  }

  mutating func clear() {
    size = 0
    nextIndex = 0
  }

  func contains(_ u: UInt32) -> Bool {
    if u >= UInt32(sparse.count) {
      return false
    }
    return sparse[Int(u)] < size && dense[Int(sparse[Int(u)])] == u
  }

  mutating func insert(_ u: UInt32) {
    if !contains(u) {
      insertNew(u)
    }
  }

  mutating func insertNew(_ u: UInt32) {
    if u >= UInt32(sparse.count) {
      return
    }
    sparse[Int(u)] = size
    dense[Int(size)] = u
    size += 1
  }
}

/// mergeRuneSets merges two non-intersecting runesets, and returns the merged result,
/// and a NextIp array. The idea is that if a rune matches the OnePassRunes at index
/// i, NextIp[i/2] is the target. If the input sets intersect, an empty runeset and a
/// NextIp array with the single element mergeFailed is returned.
/// The code assumes that both inputs contain ordered and non-intersecting rune pairs.
private let mergeFailed = UInt32(0xffff_ffff)

private func mergeRuneSets(_ leftRunes: [Rune], _ rightRunes: [Rune], _ leftPC: UInt32, _ rightPC: UInt32)
  -> ([Rune], [UInt32])
{
  let leftLen = leftRunes.count
  let rightLen = rightRunes.count
  if leftLen & 0x1 != 0 || rightLen & 0x1 != 0 {
    preconditionFailure("mergeRuneSets odd length []rune")
  }
  var lx = 0
  var rx = 0
  var merged: [Rune] = []
  var next: [UInt32] = []

  var ix = -1
  func extend(_ newLow: inout Int, _ newArray: [Rune], _ pc: UInt32) -> Bool {
    if ix > 0 && newArray[newLow] <= merged[ix] {
      return false
    }
    merged.append(newArray[newLow])
    merged.append(newArray[newLow + 1])
    newLow += 2
    ix += 2
    next.append(pc)
    return true
  }

  while lx < leftLen || rx < rightLen {
    let ok: Bool
    if rx >= rightLen {
      ok = extend(&lx, leftRunes, leftPC)
    } else if lx >= leftLen {
      ok = extend(&rx, rightRunes, rightPC)
    } else if rightRunes[rx] < leftRunes[lx] {
      ok = extend(&rx, rightRunes, rightPC)
    } else {
      ok = extend(&lx, leftRunes, leftPC)
    }
    if !ok {
      return ([], [mergeFailed])
    }
  }
  return (merged, next)
}

/// cleanupOnePass drops working memory, and restores certain shortcut instructions.
private func cleanupOnePass(_ prog: inout OnePassProg, _ original: Syntax.Prog) {
  for (ix, instOriginal) in original.inst.enumerated() {
    switch instOriginal.op {
    case .alt, .altMatch, .rune:
      break
    case .capture, .emptyWidth, .nop, .match, .fail:
      prog.inst[ix].next = []
    case .rune1, .runeAny, .runeAnyNotNL:
      prog.inst[ix] = OnePassInst(inst: instOriginal)
    }
  }
}

/// onePassCopy creates a copy of the original Prog, as we'll be modifying it.
private func onePassCopy(_ prog: Syntax.Prog) -> OnePassProg {
  var p = OnePassProg(inst: prog.inst.map { OnePassInst(inst: $0) }, start: prog.start, numCap: prog.numCap)

  func isAlt(_ op: Syntax.InstOp) -> Bool { op == .alt || op == .altMatch }

  // rewrites one or more common Prog constructs that enable some otherwise
  // non-onepass Progs to be onepass. A:BD (for example) means an InstAlt at
  // ip A, that points to ips B & C.
  // A:BC + B:DA => A:BC + B:CD
  // A:BC + B:DC => A:DC + B:DC
  for pc in p.inst.indices {
    switch p.inst[pc].inst.op {
    case .alt, .altMatch:
      // A:Bx + B:Ay
      // pAAltIsArg: whether p_A_Alt points at A's Arg (else at A's Out); p_A_Other is the other field.
      var pAAltIsArg = true
      func getA(_ isArg: Bool) -> UInt32 { isArg ? p.inst[pc].inst.arg : p.inst[pc].inst.out }
      // make sure a target is another Alt
      var instAlt = p.inst[Int(getA(pAAltIsArg))].inst
      if !isAlt(instAlt.op) {
        pAAltIsArg.toggle()
        instAlt = p.inst[Int(getA(pAAltIsArg))].inst
        if !isAlt(instAlt.op) {
          continue
        }
      }
      let instOther = p.inst[Int(getA(!pAAltIsArg))].inst
      // Analyzing both legs pointing to Alts is for another day
      if isAlt(instOther.op) {
        // too complicated
        continue
      }
      // simple empty transition loop
      // A:BC + B:DA => A:BC + B:DC
      let b = Int(getA(pAAltIsArg))
      var pBAltIsArg = false  // p_B_Alt = &B.Out, p_B_Other = &B.Arg
      var patch = false
      if instAlt.out == UInt32(pc) {
        patch = true
      } else if instAlt.arg == UInt32(pc) {
        patch = true
        pBAltIsArg = true
      }
      if patch {
        let v = getA(!pAAltIsArg)
        if pBAltIsArg {
          p.inst[b].inst.arg = v
        } else {
          p.inst[b].inst.out = v
        }
      }

      // empty transition to common target
      // A:BC + B:DC => A:DC + B:DC
      let pBAlt = pBAltIsArg ? p.inst[b].inst.arg : p.inst[b].inst.out
      let pBOther = pBAltIsArg ? p.inst[b].inst.out : p.inst[b].inst.arg
      if getA(!pAAltIsArg) == pBAlt {
        if pAAltIsArg {
          p.inst[pc].inst.arg = pBOther
        } else {
          p.inst[pc].inst.out = pBOther
        }
      }
    default:
      continue
    }
  }
  return p
}

private let anyRuneNotNL: [Rune] = [0, 0x0A - 1, 0x0A + 1, UnicodeTables.maxRune]
private let anyRune: [Rune] = [0, UnicodeTables.maxRune]

/// makeOnePass creates a onepass Prog, if possible. It is possible if at any alt,
/// the match engine can always tell which branch to take. The routine may modify
/// p if it is turned into a onepass Prog. If it isn't possible for this to be a
/// onepass Prog, nil is returned. makeOnePass is recursive
/// to the size of the Prog.
private func makeOnePass(_ p0: OnePassProg) -> OnePassProg? {
  var p = p0
  // If the machine is very long, it's not worth the time to check if we can use one pass.
  if p.inst.count >= 1000 {
    return nil
  }

  var instQueue = QueueOnePass(p.inst.count)
  var visitQueue = QueueOnePass(p.inst.count)
  var onePassRunes = [[Rune]](repeating: [], count: p.inst.count)
  var m = [Bool](repeating: false, count: p.inst.count)

  func makeNext(_ pc: Int, _ out: UInt32) {
    p.inst[pc].next = [UInt32](repeating: out, count: onePassRunes[pc].count / 2 + 1)
  }

  // check that paths from Alt instructions are unambiguous, and rebuild the new
  // program as a onepass program
  func check(_ pc: UInt32) -> Bool {
    var ok = true
    let ipc = Int(pc)
    if visitQueue.contains(pc) {
      return ok
    }
    visitQueue.insert(pc)
    switch p.inst[ipc].inst.op {
    case .alt, .altMatch:
      ok = check(p.inst[ipc].inst.out) && check(p.inst[ipc].inst.arg)
      // check no-input paths to InstMatch
      var matchOut = m[Int(p.inst[ipc].inst.out)]
      var matchArg = m[Int(p.inst[ipc].inst.arg)]
      if matchOut && matchArg {
        ok = false
        break
      }
      // Match on empty goes in inst.Out
      if matchArg {
        let o = p.inst[ipc].inst.out
        p.inst[ipc].inst.out = p.inst[ipc].inst.arg
        p.inst[ipc].inst.arg = o
        swap(&matchOut, &matchArg)
      }
      if matchOut {
        m[ipc] = true
        p.inst[ipc].inst.op = .altMatch
      }

      // build a dispatch operator from the two legs of the alt.
      let out = p.inst[ipc].inst.out
      let arg = p.inst[ipc].inst.arg
      (onePassRunes[ipc], p.inst[ipc].next) = mergeRuneSets(
        onePassRunes[Int(out)], onePassRunes[Int(arg)], out, arg)
      if let first = p.inst[ipc].next.first, first == mergeFailed {
        ok = false
        break
      }
    case .capture, .nop:
      let out = p.inst[ipc].inst.out
      ok = check(out)
      m[ipc] = m[Int(out)]
      // pass matching runes back through these no-ops.
      onePassRunes[ipc] = onePassRunes[Int(out)]
      makeNext(ipc, out)
    case .emptyWidth:
      let out = p.inst[ipc].inst.out
      ok = check(out)
      m[ipc] = m[Int(out)]
      onePassRunes[ipc] = onePassRunes[Int(out)]
      makeNext(ipc, out)
    case .match, .fail:
      m[ipc] = p.inst[ipc].inst.op == .match
    case .rune:
      m[ipc] = false
      if !p.inst[ipc].next.isEmpty {
        break
      }
      let inst = p.inst[ipc].inst
      instQueue.insert(inst.out)
      if inst.rune.isEmpty {
        onePassRunes[ipc] = []
        p.inst[ipc].next = [inst.out]
        break
      }
      var runes: [Rune] = []
      if inst.rune.count == 1 && Syntax.Flags(rawValue: UInt16(truncatingIfNeeded: inst.arg)).contains(.foldCase) {
        let r0 = inst.rune[0]
        runes.append(r0)
        runes.append(r0)
        var r1 = UnicodeTables.simpleFold(r0)
        while r1 != r0 {
          runes.append(r1)
          runes.append(r1)
          r1 = UnicodeTables.simpleFold(r1)
        }
        runes.sort()
      } else {
        runes.append(contentsOf: inst.rune)
      }
      onePassRunes[ipc] = runes
      makeNext(ipc, inst.out)
      p.inst[ipc].inst.op = .rune
    case .rune1:
      m[ipc] = false
      if !p.inst[ipc].next.isEmpty {
        break
      }
      let inst = p.inst[ipc].inst
      instQueue.insert(inst.out)
      var runes: [Rune] = []
      // expand case-folded runes
      if Syntax.Flags(rawValue: UInt16(truncatingIfNeeded: inst.arg)).contains(.foldCase) {
        let r0 = inst.rune[0]
        runes.append(r0)
        runes.append(r0)
        var r1 = UnicodeTables.simpleFold(r0)
        while r1 != r0 {
          runes.append(r1)
          runes.append(r1)
          r1 = UnicodeTables.simpleFold(r1)
        }
        runes.sort()
      } else {
        runes.append(inst.rune[0])
        runes.append(inst.rune[0])
      }
      onePassRunes[ipc] = runes
      makeNext(ipc, inst.out)
      p.inst[ipc].inst.op = .rune
    case .runeAny:
      m[ipc] = false
      if !p.inst[ipc].next.isEmpty {
        break
      }
      let out = p.inst[ipc].inst.out
      instQueue.insert(out)
      onePassRunes[ipc] = anyRune
      p.inst[ipc].next = [out]
    case .runeAnyNotNL:
      m[ipc] = false
      if !p.inst[ipc].next.isEmpty {
        break
      }
      let out = p.inst[ipc].inst.out
      instQueue.insert(out)
      onePassRunes[ipc] = anyRuneNotNL
      makeNext(ipc, out)
    }
    return ok
  }

  instQueue.clear()
  instQueue.insert(UInt32(p.start))
  var failed = false
  while !instQueue.isEmpty {
    visitQueue.clear()
    let pc = instQueue.next()
    if !check(pc) {
      failed = true
      break
    }
  }
  if failed {
    return nil
  }
  for i in p.inst.indices {
    p.inst[i].inst.rune = onePassRunes[i]
  }
  return p
}

/// compileOnePass returns a new program suitable for onePass execution if the original Prog
/// can be recharacterized as a one-pass regexp program, or nil if the
/// Prog cannot be converted. For a one pass prog, the fundamental condition that must
/// be true is: at any InstAlt, there must be no ambiguity about what branch to  take.
func compileOnePass(_ prog: Syntax.Prog) -> OnePassProg? {
  if prog.start == 0 {
    return nil
  }
  // onepass regexp is anchored
  if prog.inst[prog.start].op != .emptyWidth
    || !Syntax.EmptyOp(rawValue: UInt8(truncatingIfNeeded: prog.inst[prog.start].arg)).contains(.beginText)
  {
    return nil
  }
  var hasAlt = false
  for inst in prog.inst where inst.op == .alt || inst.op == .altMatch {
    hasAlt = true
    break
  }
  // If we have alternates, every instruction leading to InstMatch must be EmptyEndText.
  // Also, any match on empty text must be $.
  for inst in prog.inst {
    let opOut = prog.inst[Int(inst.out)].op
    switch inst.op {
    case .alt, .altMatch:
      if opOut == .match || prog.inst[Int(inst.arg)].op == .match {
        return nil
      }
    case .emptyWidth:
      if opOut == .match {
        if Syntax.EmptyOp(rawValue: UInt8(truncatingIfNeeded: inst.arg)).contains(.endText) {
          continue
        }
        return nil
      }
    default:
      if opOut == .match && hasAlt {
        return nil
      }
    }
  }
  // Creates a slightly optimized copy of the original Prog
  // that cleans up some Prog idioms that block valid onepass programs
  let p = onePassCopy(prog)

  // checkAmbiguity on InstAlts, build onepass Prog if possible
  guard var p = makeOnePass(p) else {
    return nil
  }

  cleanupOnePass(&p, prog)
  return p
}
