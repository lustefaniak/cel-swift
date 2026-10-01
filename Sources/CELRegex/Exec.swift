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
/// just place holders so that the machine knows it has considered that pc. The storage belongs to
/// the Machine.
struct Queue {
  let sparse: UnsafeMutablePointer<UInt32>
  let densePC: UnsafeMutablePointer<UInt32>
  let denseT: UnsafeMutablePointer<Int32>
  var count = 0

  init(_ n: Int) {
    sparse = .allocate(capacity: Swift.max(n, 1))
    sparse.initialize(repeating: 0, count: Swift.max(n, 1))
    densePC = .allocate(capacity: Swift.max(n, 1))
    densePC.initialize(repeating: 0, count: Swift.max(n, 1))
    denseT = .allocate(capacity: Swift.max(n, 1))
    denseT.initialize(repeating: -1, count: Swift.max(n, 1))
  }

  func deallocate() {
    sparse.deallocate()
    densePC.deallocate()
    denseT.deallocate()
  }

  @inline(__always)
  func contains(_ pc: UInt32) -> Bool {
    let j = Int(sparse[Int(pc)])
    return j < count && densePC[j] == pc
  }
}

/// The program's instruction fields as flat arrays, built once per Regexp, so that the Pike VM's
/// inner loops read plain memory instead of copying `Syntax.Inst` values (and retaining their rune
/// arrays) per thread step.
struct FlatProg: Sendable {
  var ops: [Syntax.InstOp]
  var outs: [UInt32]
  var args: [UInt32]
  var runeOff: [Int]  // instruction pc's runes are runes[runeOff[pc] ..< runeOff[pc + 1]]
  var runes: [Rune]
  var fold: [Bool]  // FoldCase flag of InstRune instructions

  init(_ p: Syntax.Prog) {
    ops = p.inst.map(\.op)
    outs = p.inst.map(\.out)
    args = p.inst.map(\.arg)
    fold = p.inst.map { Syntax.Flags(rawValue: UInt16(truncatingIfNeeded: $0.arg)).contains(.foldCase) }
    runeOff = [0]
    runes = []
    for inst in p.inst {
      runes.append(contentsOf: inst.rune)
      runeOff.append(runes.count)
    }
  }

  struct Pointers {
    let ops: UnsafeBufferPointer<Syntax.InstOp>
    let outs: UnsafeBufferPointer<UInt32>
    let args: UnsafeBufferPointer<UInt32>
    let runeOff: UnsafeBufferPointer<Int>
    let runes: UnsafeBufferPointer<Rune>
    let fold: UnsafeBufferPointer<Bool>

    @inline(__always)
    func runes(_ pc: Int) -> UnsafeBufferPointer<Rune> {
      UnsafeBufferPointer(rebasing: runes[runeOff[pc]..<runeOff[pc + 1]])
    }
  }

  func withPointers<R>(_ body: (Pointers) -> R) -> R {
    ops.withUnsafeBufferPointer { ops in
      outs.withUnsafeBufferPointer { outs in
        args.withUnsafeBufferPointer { args in
          runeOff.withUnsafeBufferPointer { runeOff in
            runes.withUnsafeBufferPointer { runes in
              fold.withUnsafeBufferPointer { fold in
                body(Pointers(ops: ops, outs: outs, args: args, runeOff: runeOff, runes: runes, fold: fold))
              }
            }
          }
        }
      }
    }
  }
}

/// A machine holds all the state during an NFA simulation for p.
///
/// It lives for one doExecute call, which deallocates its manually allocated buffers: the inner
/// loops then do no copy-on-write or dynamic exclusivity checks.
struct Machine {
  private enum Work {
    case explore(UInt32)
    case restore(UInt32, Int)
  }

  let re: Regexp  // corresponding Regexp
  let n: Int  // number of instructions
  // The compiled program, flattened.
  private let p: FlatProg.Pointers
  private let q0: Queue
  private let q1: Queue
  let ncap: Int
  /// Capture slots of all threads; thread t owns caps[t*ncap ..< (t+1)*ncap].
  /// Thread 0 is the machine's matchcap and is never pooled. At most 2n threads are alive at
  /// once (one per entry of the two queues), so 2n+1 threads never need to grow.
  ///
  /// Go allocates a thread's slots when the thread is created; here the buffer starts small and
  /// doubles when a new thread needs room, so memory follows the threads actually alive rather
  /// than the bound (which is quadratic in the pattern for capture-heavy patterns).
  private var caps: UnsafeMutablePointer<Int>
  /// The number of threads `caps` has room for.
  private(set) var allocatedThreads: Int
  private let maxThreads: Int
  private var nthreads = 1
  private let pool: UnsafeMutablePointer<Int32>  // pool of available threads
  private var poolCount = 0
  var matched = false  // whether a match was found
  // Explicit stack for add. Each push accompanies a newly queued pc, so n entries suffice.
  private let work: UnsafeMutablePointer<Work>
  private var workCount = 0

  /// The pointers must stay valid for the machine's lifetime (doExecute holds them).
  init(_ re: Regexp, _ p: FlatProg.Pointers, ncap: Int) {
    self.re = re
    self.p = p
    n = p.ops.count
    q0 = Queue(n)
    q1 = Queue(n)
    self.ncap = ncap
    maxThreads = 2 * n + 2
    allocatedThreads = Swift.min(maxThreads, 8)
    caps = .allocate(capacity: Swift.max(allocatedThreads * ncap, 1))
    caps.initialize(repeating: -1, count: Swift.max(allocatedThreads * ncap, 1))
    pool = .allocate(capacity: maxThreads)
    work = .allocate(capacity: n + 1)
  }

  func deallocate() {
    work.deallocate()
    q0.deallocate()
    q1.deallocate()
    caps.deallocate()
    pool.deallocate()
  }

  var matchcap: [Int] { Array(UnsafeBufferPointer(start: caps, count: ncap)) }

  @inline(__always)
  private mutating func free(_ t: Int32) {
    pool[poolCount] = t
    poolCount += 1
  }

  @inline(__always)
  private mutating func push(_ w: Work) {
    precondition(workCount <= n, "regexp: work stack bound exceeded")
    (work + workCount).initialize(to: w)
    workCount += 1
  }

  /// alloc allocates a new thread.
  /// It uses the free pool if possible.
  @inline(__always)
  private mutating func alloc() -> Int32 {
    if poolCount > 0 {
      poolCount -= 1
      return pool[poolCount]
    }
    precondition(nthreads < maxThreads, "regexp: thread bound exceeded")
    if nthreads == allocatedThreads {
      growCaps()
    }
    let t = Int32(nthreads)
    nthreads += 1
    return t
  }

  /// Doubles the room in `caps`, up to the thread bound.
  private mutating func growCaps() {
    let threads = Swift.min(maxThreads, allocatedThreads * 2)
    let grown = UnsafeMutablePointer<Int>.allocate(capacity: Swift.max(threads * ncap, 1))
    let used = allocatedThreads * ncap
    grown.moveInitialize(from: caps, count: used)
    (grown + used).initialize(repeating: -1, count: Swift.max(threads * ncap, 1) - used)
    caps.deallocate()
    caps = grown
    allocatedThreads = threads
  }

  @inline(__always)
  private func copyCaps(to dst: Int32, from src: Int32) {
    if ncap == 0 || dst == src {
      return
    }
    (caps + Int(dst) * ncap).update(from: caps + Int(src) * ncap, count: ncap)
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
    var runq = q0
    var nextq = q1
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
        free(t)
        j += 1
        continue
      }
      let pc = Int(runq.densePC[j])
      var add = false
      switch p.ops[pc] {
      case .match:
        if ncap > 0 && (!longest || !matched || caps[1] < pos) {
          caps[Int(t) * ncap + 1] = pos
          copyCaps(to: 0, from: t)
        }
        if !longest {
          // First-match mode: cut off all lower-priority threads.
          var k = j + 1
          while k < runq.count {
            if runq.denseT[k] >= 0 {
              free(runq.denseT[k])
            }
            k += 1
          }
          runq.count = 0
        }
        matched = true

      case .rune:
        add = Syntax.Inst.matchRunePos(p.runes(pc), foldCase: p.fold[pc], c) != Syntax.Inst.noMatch
      case .rune1:
        add = c == p.runes[p.runeOff[pc]]
      case .runeAny:
        add = true
      case .runeAnyNotNL:
        add = c != 0x0A
      default:
        preconditionFailure("bad inst")
      }
      if add {
        t = self.add(&nextq, p.outs[pc], nextPos, capRef: t, nextCond, spare: t)
      }
      if t >= 0 {
        free(t)
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
    // The work stack is empty between calls; the first pc is explored without pushing it.
    var next: UInt32? = pc0
    while true {
      var pc: UInt32
      if let n = next {
        pc = n
        next = nil
      } else {
        if workCount == 0 {
          break
        }
        workCount -= 1
        switch work[workCount] {
        case .restore(let arg, let opos):
          caps[Int(capRef) * ncap + Int(arg)] = opos
          pendingRestores -= 1
          continue
        case .explore(let p):
          pc = p
        }
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
        let iout = p.outs[ipc]
        let iarg = p.args[ipc]
        switch p.ops[ipc] {
        case .fail:
          // nothing
          break again
        case .alt, .altMatch:
          push(.explore(iarg))
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
            push(.restore(iarg, opos))
            pendingRestores += 1
          }
          pc = iout
          continue again
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

    return flat.withPointers { p in
      var m = Machine(self, p, ncap: ncap)
      defer { m.deallocate() }
      if !m.match(i, pos) {
        return nil
      }
      return m.matchcap
    }
  }
}
