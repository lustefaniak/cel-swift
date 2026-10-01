// Copyright 2011 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// Port of Go's regexp/exec.go: the NFA (Pike VM) matcher, the one-pass matcher driver, and
// doExecute, which picks an engine.
//
// Differences in mechanics, not behaviour: threads are indices into one flat capture buffer
// instead of heap objects; machines are allocated per call instead of pooled (no global mutable
// state); and machine.add uses an explicit stack instead of recursion, so very large programs
// cannot overflow the native stack. The order in which threads are added, and so match priority,
// is the same as Go's recursive version.

let endOfText: Rune = -1

/// input abstracts the text being matched: Go's inputString and inputBytes. Go's inputReader
/// (io.RuneReader) is not ported.
struct Input {
  let buf: UnsafeBufferPointer<UInt8>

  var count: Int { buf.count }

  /// step advances one rune.
  @inline(__always)
  func step(_ pos: Int) -> (Rune, Int) {
    if pos < buf.count {
      return GoUTF8.decodeRune(buf, at: pos)
    }
    return (endOfText, 0)
  }

  func hasPrefix(_ prefix: [UInt8]) -> Bool {
    if prefix.count > buf.count {
      return false
    }
    for (i, b) in prefix.enumerated() where buf[i] != b {
      return false
    }
    return true
  }

  /// index returns the offset from pos of the first occurrence of prefix in buf[pos...], or -1.
  func index(_ prefix: [UInt8], _ pos: Int) -> Int {
    let n = prefix.count
    if n == 0 {
      return 0
    }
    let first = prefix[0]
    var i = pos
    let last = buf.count - n
    while i <= last {
      if buf[i] == first {
        var j = 1
        while j < n && buf[i + j] == prefix[j] {
          j += 1
        }
        if j == n {
          return i - pos
        }
      }
      i += 1
    }
    return -1
  }

  func context(_ pos: Int) -> LazyFlag {
    var r1 = endOfText
    var r2 = endOfText
    // 0 < pos && pos <= len(i.str)
    if pos > 0 && pos <= buf.count {
      r1 = GoUTF8.decodeLastRune(buf, end: pos).0
    }
    // 0 <= pos && pos < len(i.str)
    if pos >= 0 && pos < buf.count {
      r2 = GoUTF8.decodeRune(buf, at: pos).0
    }
    return LazyFlag(r1, r2)
  }
}

/// A lazyFlag is a lazily-evaluated syntax.EmptyOp,
/// for checking zero-width flags like ^ $ \A \z \B \b.
/// It records the pair of relevant runes and does not
/// determine the implied flags until absolutely necessary
/// (most of the time, that means never).
struct LazyFlag {
  var r1: Rune
  var r2: Rune

  @inline(__always)
  init(_ r1: Rune, _ r2: Rune) {
    self.r1 = r1
    self.r2 = r2
  }

  func match(_ op0: Syntax.EmptyOp) -> Bool {
    var op = op0
    if op.isEmpty {
      return true
    }
    if op.contains(.beginLine) {
      if r1 != 0x0A && r1 >= 0 {
        return false
      }
      op.remove(.beginLine)
    }
    if op.contains(.beginText) {
      if r1 >= 0 {
        return false
      }
      op.remove(.beginText)
    }
    if op.isEmpty {
      return true
    }
    if op.contains(.endLine) {
      if r2 != 0x0A && r2 >= 0 {
        return false
      }
      op.remove(.endLine)
    }
    if op.contains(.endText) {
      if r2 >= 0 {
        return false
      }
      op.remove(.endText)
    }
    if op.isEmpty {
      return true
    }
    if Syntax.isWordChar(r1) != Syntax.isWordChar(r2) {
      op.remove(.wordBoundary)
    } else {
      op.remove(.noWordBoundary)
    }
    return op.isEmpty
  }
}

/// A queue is a 'sparse array' holding pending threads of execution.
/// See https://research.swtch.com/2008/03/using-uninitialized-memory-for-fun-and.html
///
/// Each dense entry holds the instruction pc and the thread (-1 for none). Some queue entries are
/// just place holders so that the machine knows it has considered that pc.
struct Queue {
  var sparse: [UInt32]
  var densePC: [UInt32]
  var denseT: [Int32]
  var count = 0

  init(_ n: Int) {
    sparse = [UInt32](repeating: 0, count: n)
    densePC = [UInt32](repeating: 0, count: n)
    denseT = [Int32](repeating: -1, count: n)
  }

  @inline(__always)
  func contains(_ pc: UInt32) -> Bool {
    let j = Int(sparse[Int(pc)])
    return j < count && densePC[j] == pc
  }
}

/// A machine holds all the state during an NFA simulation for p.
struct Machine {
  private enum Work {
    case explore(UInt32)
    case restore(UInt32, Int)
  }

  let re: Regexp  // corresponding Regexp
  let prog: [Syntax.Inst]  // compiled program
  let ncap: Int
  /// Capture slots of all threads; thread t owns caps[t*ncap ..< (t+1)*ncap].
  /// Thread 0 is the machine's matchcap and is never pooled.
  var caps: [Int]
  var nthreads = 1
  var pool: [Int32] = []  // pool of available threads
  var matched = false  // whether a match was found
  private var work: [Work] = []

  init(_ re: Regexp, ncap: Int) {
    self.re = re
    self.prog = re.prog.inst
    self.ncap = ncap
    caps = [Int](repeating: -1, count: ncap)
  }

  var matchcap: ArraySlice<Int> { caps[0..<ncap] }

  /// alloc allocates a new thread.
  /// It uses the free pool if possible.
  @inline(__always)
  mutating func alloc() -> Int32 {
    if let t = pool.popLast() {
      return t
    }
    let t = Int32(nthreads)
    nthreads += 1
    if ncap > 0 {
      caps.append(contentsOf: repeatElement(0, count: ncap))
    }
    return t
  }

  @inline(__always)
  mutating func copyCaps(to dst: Int32, from src: Int32) {
    if ncap == 0 || dst == src {
      return
    }
    let d = Int(dst) * ncap
    let s = Int(src) * ncap
    for k in 0..<ncap {
      caps[d + k] = caps[s + k]
    }
  }

  /// match runs the machine over the input starting at pos.
  /// It reports whether a match was found.
  /// If so, matchcap holds the submatch information.
  mutating func match(_ i: Input, _ pos0: Int) -> Bool {
    var pos = pos0
    let startCond = re.cond
    if startCond == .impossible {  // impossible
      return false
    }
    matched = false
    for k in 0..<ncap {
      caps[k] = -1
    }
    var runq = Queue(prog.count)
    var nextq = Queue(prog.count)
    var r = endOfText
    var r1 = endOfText
    var width = 0
    var width1 = 0
    (r, width) = i.step(pos)
    if r != endOfText {
      (r1, width1) = i.step(pos + width)
    }
    var flag: LazyFlag
    if pos == 0 {
      flag = LazyFlag(-1, r)
    } else {
      flag = i.context(pos)
    }
    while true {
      if runq.count == 0 {
        if startCond.contains(.beginText) && pos != 0 {
          // Anchored match, past beginning of text.
          break
        }
        if matched {
          // Have match; finished exploring alternatives.
          break
        }
        if !re.prefix.isEmpty && r1 != re.prefixRune {
          // Match requires literal prefix; fast search for it.
          let advance = i.index(re.prefix, pos)
          if advance < 0 {
            break
          }
          pos += advance
          (r, width) = i.step(pos)
          (r1, width1) = i.step(pos + width)
        }
      }
      if !matched {
        if ncap > 0 {
          caps[0] = pos
        }
        _ = add(&runq, UInt32(re.prog.start), pos, capRef: 0, flag, spare: -1)
      }
      flag = LazyFlag(r, r1)
      step(&runq, &nextq, pos, pos + width, r, flag)
      if width == 0 {
        break
      }
      if ncap == 0 && matched {
        // Found a match and not paying attention
        // to where it is, so any match will do.
        break
      }
      pos += width
      (r, width) = (r1, width1)
      if r != endOfText {
        (r1, width1) = i.step(pos + width)
      }
      swap(&runq, &nextq)
    }
    return matched
  }

  /// step executes one step of the machine, running each of the threads
  /// on runq and appending new threads to nextq.
  /// The step processes the rune c (which may be endOfText),
  /// which starts at position pos and ends at nextPos.
  /// nextCond gives the setting for the empty-width flags after c.
  private mutating func step(
    _ runq: inout Queue, _ nextq: inout Queue, _ pos: Int, _ nextPos: Int, _ c: Rune, _ nextCond: LazyFlag
  ) {
    let longest = re.longest
    var j = 0
    while j < runq.count {
      var t = runq.denseT[j]
      if t < 0 {
        j += 1
        continue
      }
      if longest && matched && ncap > 0 && caps[0] < caps[Int(t) * ncap] {
        pool.append(t)
        j += 1
        continue
      }
      let pc = runq.densePC[j]
      var add = false
      switch prog[Int(pc)].op {
      case .match:
        if ncap > 0 && (!longest || !matched || caps[1] < pos) {
          caps[Int(t) * ncap + 1] = pos
          copyCaps(to: 0, from: t)
        }
        if !longest {
          // First-match mode: cut off all lower-priority threads.
          for k in (j + 1)..<Swift.max(j + 1, runq.count) where runq.denseT[k] >= 0 {
            pool.append(runq.denseT[k])
          }
          runq.count = 0
        }
        matched = true

      case .rune:
        add = prog[Int(pc)].matchRune(c)
      case .rune1:
        add = c == prog[Int(pc)].rune[0]
      case .runeAny:
        add = true
      case .runeAnyNotNL:
        add = c != 0x0A
      default:
        preconditionFailure("bad inst")
      }
      if add {
        t = self.add(&nextq, prog[Int(pc)].out, nextPos, capRef: t, nextCond, spare: t)
      }
      if t >= 0 {
        pool.append(t)
      }
      j += 1
    }
    runq.count = 0
  }

  /// add adds an entry to q for pc, unless the q already has such an entry.
  /// It also adds an entry for all instructions reachable from pc by following
  /// empty-width conditions satisfied by cond.  pos gives the current position
  /// in the input. capRef is the thread whose capture slots are the current captures;
  /// spare is a thread that may be consumed instead of allocating (or -1).
  /// add returns the spare thread if it was not consumed, else -1.
  private mutating func add(
    _ q: inout Queue, _ pc0: UInt32, _ pos: Int, capRef: Int32, _ cond: LazyFlag, spare: Int32
  ) -> Int32 {
    var t = spare
    var pendingRestores = 0
    work.removeAll(keepingCapacity: true)
    work.append(.explore(pc0))
    while let w = work.popLast() {
      var pc: UInt32
      switch w {
      case .restore(let arg, let opos):
        caps[Int(capRef) * ncap + Int(arg)] = opos
        pendingRestores -= 1
        continue
      case .explore(let p):
        pc = p
      }
      again: while true {
        if pc == 0 {
          break again
        }
        if q.contains(pc) {
          break again
        }

        let j = q.count
        q.count += 1
        q.densePC[j] = pc
        q.denseT[j] = -1
        q.sparse[Int(pc)] = UInt32(j)

        let ipc = Int(pc)
        let iop = prog[ipc].op
        let iout = prog[ipc].out
        let iarg = prog[ipc].arg
        switch iop {
        case .fail:
          // nothing
          break again
        case .alt, .altMatch:
          work.append(.explore(iarg))
          pc = iout
          continue again
        case .emptyWidth:
          if cond.match(Syntax.EmptyOp(rawValue: UInt8(truncatingIfNeeded: iarg))) {
            pc = iout
            continue again
          }
          break again
        case .nop:
          pc = iout
          continue again
        case .capture:
          if Int(iarg) < ncap {
            let slot = Int(capRef) * ncap + Int(iarg)
            let opos = caps[slot]
            caps[slot] = pos
            work.append(.restore(iarg, opos))
            pendingRestores += 1
            pc = iout
            continue again
          } else {
            pc = iout
            continue again
          }
        case .match, .rune, .rune1, .runeAny, .runeAnyNotNL:
          // Inside a capture's subtree Go passes no spare thread, so the spare
          // (whose slots may be the ones being temporarily modified) is never consumed there.
          let nt: Int32
          if t >= 0 && pendingRestores == 0 {
            nt = t
            t = -1
          } else {
            nt = alloc()
          }
          copyCaps(to: nt, from: capRef)
          q.denseT[j] = nt
          break again
        }
      }
    }
    return t
  }
}

extension Regexp {
  /// doOnePass implements doExecute using the one-pass execution engine.
  func doOnePass(_ i: Input, _ pos0: Int, _ ncap: Int) -> [Int]? {
    var pos = pos0
    let startCond = cond
    if startCond == .impossible {  // impossible
      return nil
    }
    guard let onepass else { return nil }

    var matchcap = [Int](repeating: -1, count: ncap)
    var matched = false

    var r = endOfText
    var r1 = endOfText
    var width = 0
    var width1 = 0
    (r, width) = i.step(pos)
    if r != endOfText {
      (r1, width1) = i.step(pos + width)
    }
    var flag: LazyFlag
    if pos == 0 {
      flag = LazyFlag(-1, r)
    } else {
      flag = i.context(pos)
    }
    var pc = onepass.start
    var inst = onepass.inst[pc]
    // If there is a simple literal prefix, skip over it.
    if pos == 0 && flag.match(Syntax.EmptyOp(rawValue: UInt8(truncatingIfNeeded: inst.inst.arg)))
      && !prefix.isEmpty
    {
      // Match requires literal prefix; fast search for it.
      if !i.hasPrefix(prefix) {
        return nil
      }
      pos += prefix.count
      (r, width) = i.step(pos)
      (r1, width1) = i.step(pos + width)
      flag = i.context(pos)
      pc = Int(prefixEnd)
    }
    loop: while true {
      inst = onepass.inst[pc]
      pc = Int(inst.inst.out)
      switch inst.inst.op {
      case .match:
        matched = true
        if ncap > 0 {
          matchcap[0] = 0
          matchcap[1] = pos
        }
        break loop
      case .rune:
        if !inst.inst.matchRune(r) {
          break loop
        }
      case .rune1:
        if r != inst.inst.rune[0] {
          break loop
        }
      case .runeAny:
        // Nothing
        break
      case .runeAnyNotNL:
        if r == 0x0A {
          break loop
        }
      // peek at the input rune to see which branch of the Alt to take
      case .alt, .altMatch:
        pc = Int(onePassNext(inst, r))
        continue loop
      case .fail:
        break loop
      case .nop:
        continue loop
      case .emptyWidth:
        if !flag.match(Syntax.EmptyOp(rawValue: UInt8(truncatingIfNeeded: inst.inst.arg))) {
          break loop
        }
        continue loop
      case .capture:
        if Int(inst.inst.arg) < ncap {
          matchcap[Int(inst.inst.arg)] = pos
        }
        continue loop
      }
      if width == 0 {
        break
      }
      flag = LazyFlag(r, r1)
      pos += width
      (r, width) = (r1, width1)
      if r != endOfText {
        (r1, width1) = i.step(pos + width)
      }
    }

    if !matched {
      return nil
    }
    return matchcap
  }

  /// doExecute finds the leftmost match in the input and returns the position
  /// of its subexpressions (ncap entries), or nil if there is no match.
  func doExecute(_ i: Input, _ pos: Int, _ ncap: Int) -> [Int]? {
    if i.count < minInputLen {
      return nil
    }

    if onepass != nil {
      return doOnePass(i, pos, ncap)
    }
    if i.count < maxBitStateLen {
      return backtrack(i, pos, ncap)
    }

    var m = Machine(self, ncap: ncap)
    if !m.match(i, pos) {
      return nil
    }
    return Array(m.matchcap)
  }
}
