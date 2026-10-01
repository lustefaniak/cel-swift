// Copyright 2015 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// Port of Go's regexp/backtrack.go.
//
// backtrack is a regular expression search with submatch
// tracking for small regular expressions and texts. It allocates
// a bit vector with (length of input) * (length of prog) bits,
// to make sure it never explores the same (character position, instruction)
// state multiple times. This limits the search to run in time linear in
// the length of the test.
//
// backtrack is a fast replacement for the NFA code on small
// regexps when onepass cannot be used.

/// A job is an entry on the backtracker's job stack. It holds
/// the instruction pc and the position in the input.
private struct Job {
  var pc: UInt32
  var arg: Bool
  var pos: Int
}

private let visitedBits = 32
let maxBacktrackProg = 500  // len(prog.Inst) <= max
let maxBacktrackVector = 256 * 1024  // bit vector size <= max (bits)

/// bitState holds state for the backtracker.
private struct BitState {
  var end: Int
  var cap: [Int]
  var matchcap: [Int]
  var jobs: [Job] = []
  var visited: [UInt32]

  /// reset resets the state of the backtracker.
  /// end is the end position in the input.
  /// ncap is the number of captures.
  init(_ prog: Syntax.Prog, _ end: Int, _ ncap: Int) {
    self.end = end
    jobs.reserveCapacity(256)
    let visitedSize = (prog.inst.count * (end + 1) + visitedBits - 1) / visitedBits
    visited = [UInt32](repeating: 0, count: visitedSize)
    cap = [Int](repeating: -1, count: ncap)
    matchcap = [Int](repeating: -1, count: ncap)
  }

  /// shouldVisit reports whether the combination of (pc, pos) has not
  /// been visited yet.
  @inline(__always)
  mutating func shouldVisit(_ pc: UInt32, _ pos: Int) -> Bool {
    let n = UInt(Int(pc) * (end + 1) + pos)
    let w = Int(n / UInt(visitedBits))
    let bit = UInt32(1) << UInt32(n & UInt(visitedBits - 1))
    if visited[w] & bit != 0 {
      return false
    }
    visited[w] |= bit
    return true
  }

  /// push pushes (pc, pos, arg) onto the job stack if it should be
  /// visited.
  @inline(__always)
  mutating func push(_ prog: [Syntax.Inst], _ pc: UInt32, _ pos: Int, _ arg: Bool) {
    // Only check shouldVisit when arg is false.
    // When arg is true, we are continuing a previous visit.
    if prog[Int(pc)].op != .fail && (arg || shouldVisit(pc, pos)) {
      jobs.append(Job(pc: pc, arg: arg, pos: pos))
    }
  }
}

/// maxBitStateLen returns the maximum length of a string to search with
/// the backtracker using prog.
func maxBitStateLen(_ prog: Syntax.Prog) -> Int {
  if !shouldBacktrack(prog) {
    return 0
  }
  return maxBacktrackVector / prog.inst.count
}

/// shouldBacktrack reports whether the program is too
/// long for the backtracker to run.
func shouldBacktrack(_ prog: Syntax.Prog) -> Bool {
  prog.inst.count <= maxBacktrackProg
}

extension Regexp {
  /// tryBacktrack runs a backtracking search starting at pos.
  private func tryBacktrack(_ b: inout BitState, _ i: Input, _ pc0: UInt32, _ pos0: Int) -> Bool {
    let longest = self.longest
    let prog = self.prog.inst

    b.push(prog, pc0, pos0, false)
    while let job = b.jobs.popLast() {
      // Pop job off the stack.
      var pc = job.pc
      var pos = job.pos
      var arg = job.arg

      // Optimization: rather than push and pop,
      // code that is going to Push and continue
      // the loop simply updates ip, p, and arg
      // and jumps to CheckAndLoop. We have to
      // do the ShouldVisit check that Push
      // would have, but we avoid the stack
      // manipulation.
      var skipCheck = true
      checkAndLoop: while true {
        if !skipCheck && !b.shouldVisit(pc, pos) {
          break checkAndLoop
        }
        skipCheck = false

        let inst = prog[Int(pc)]

        switch inst.op {
        case .fail:
          preconditionFailure("unexpected InstFail")
        case .alt:
          // Cannot just
          //   b.push(inst.Out, pos, false)
          //   b.push(inst.Arg, pos, false)
          // If during the processing of inst.Out, we encounter
          // inst.Arg via another path, we want to process it then.
          // Pushing it here will inhibit that. Instead, re-push
          // inst with arg==true as a reminder to push inst.Arg out
          // later.
          if arg {
            // Finished inst.Out; try inst.Arg.
            arg = false
            pc = inst.arg
            continue checkAndLoop
          } else {
            b.push(prog, pc, pos, true)
            pc = inst.out
            continue checkAndLoop
          }

        case .altMatch:
          // One opcode consumes runes; the other leads to match.
          switch prog[Int(inst.out)].op {
          case .rune, .rune1, .runeAny, .runeAnyNotNL:
            // inst.Arg is the match.
            b.push(prog, inst.arg, pos, false)
            pc = inst.arg
            pos = b.end
            continue checkAndLoop
          default:
            break
          }
          // inst.Out is the match - non-greedy
          b.push(prog, inst.out, b.end, false)
          pc = inst.out
          continue checkAndLoop

        case .rune:
          let (r, width) = i.step(pos)
          if !inst.matchRune(r) {
            break checkAndLoop
          }
          pos += width
          pc = inst.out
          continue checkAndLoop

        case .rune1:
          let (r, width) = i.step(pos)
          if r != inst.rune[0] {
            break checkAndLoop
          }
          pos += width
          pc = inst.out
          continue checkAndLoop

        case .runeAnyNotNL:
          let (r, width) = i.step(pos)
          if r == 0x0A || r == endOfText {
            break checkAndLoop
          }
          pos += width
          pc = inst.out
          continue checkAndLoop

        case .runeAny:
          let (r, width) = i.step(pos)
          if r == endOfText {
            break checkAndLoop
          }
          pos += width
          pc = inst.out
          continue checkAndLoop

        case .capture:
          if arg {
            // Finished inst.Out; restore the old value.
            b.cap[Int(inst.arg)] = pos
            break checkAndLoop
          } else {
            if Int(inst.arg) < b.cap.count {
              // Capture pos to register, but save old value.
              b.push(prog, pc, b.cap[Int(inst.arg)], true)  // come back when we're done.
              b.cap[Int(inst.arg)] = pos
            }
            pc = inst.out
            continue checkAndLoop
          }

        case .emptyWidth:
          let flag = i.context(pos)
          if !flag.match(Syntax.EmptyOp(rawValue: UInt8(truncatingIfNeeded: inst.arg))) {
            break checkAndLoop
          }
          pc = inst.out
          continue checkAndLoop

        case .nop:
          pc = inst.out
          continue checkAndLoop

        case .match:
          // We found a match. If the caller doesn't care
          // where the match is, no point going further.
          if b.cap.isEmpty {
            return true
          }

          // Record best match so far.
          // Only need to check end point, because this entire
          // call is only considering one start position.
          if b.cap.count > 1 {
            b.cap[1] = pos
          }
          let old = b.matchcap[1]
          if old == -1 || (longest && pos > 0 && pos > old) {
            b.matchcap = b.cap
          }

          // If going for first match, we're done.
          if !longest {
            return true
          }

          // If we used the entire text, no longer match is possible.
          if pos == b.end {
            return true
          }

          // Otherwise, continue on in hope of a longer match.
          break checkAndLoop
        }
      }
    }

    return longest && b.matchcap.count > 1 && b.matchcap[1] >= 0
  }

  /// backtrack runs a backtracking search of prog on the input starting at pos.
  func backtrack(_ i: Input, _ pos0: Int, _ ncap: Int) -> [Int]? {
    var pos = pos0
    let startCond = cond
    if startCond == .impossible {  // impossible
      return nil
    }
    if startCond.contains(.beginText) && pos != 0 {
      // Anchored match, past beginning of text.
      return nil
    }

    let end = i.count
    var b = BitState(prog, end, ncap)

    // Anchored search must start at the beginning of the input
    if startCond.contains(.beginText) {
      if !b.cap.isEmpty {
        b.cap[0] = pos
      }
      if !tryBacktrack(&b, i, UInt32(prog.start), pos) {
        return nil
      }
    } else {
      // Unanchored search, starting from each possible text position.
      // Notice that we have to try the empty string at the end of
      // the text, so the loop condition is pos <= end, not pos < end.
      // This looks like it's quadratic in the size of the text,
      // but we are not clearing visited between calls to TrySearch,
      // so no work is duplicated and it ends up still being linear.
      var width = -1
      var found = false
      while pos <= end && width != 0 {
        if !prefix.isEmpty {
          // Match requires literal prefix; fast search for it.
          let advance = i.index(prefix, pos)
          if advance < 0 {
            return nil
          }
          pos += advance
        }

        if !b.cap.isEmpty {
          b.cap[0] = pos
        }
        if tryBacktrack(&b, i, UInt32(prog.start), pos) {
          // Match must be leftmost; done.
          found = true
          break
        }
        (_, width) = i.step(pos)
        pos += width
      }
      if !found {
        return nil
      }
    }

    return b.matchcap
  }
}
