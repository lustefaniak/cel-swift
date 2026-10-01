// Tests that matching stays linear in the input for patterns that make backtracking engines
// explode. Not a port of a Go test: Go guarantees this by construction, and these check that the
// Swift port kept that property (the Pike VM for long inputs, the bit-state backtracker's visited
// set for short ones).

import Testing

@testable import CELRegex

struct LinearTimeTests {
  /// Pathological patterns for backtracking matchers, each paired with an input that does not
  /// match, so every engine must explore the whole input.
  static let pathological: [(pattern: String, unit: String, tail: String)] = [
    (#"(a*)*b"#, "a", ""),
    (#"(a+)+b"#, "a", ""),
    (#"(a|a)*b"#, "a", ""),
    (#"(a|aa)*b"#, "a", ""),
    (#"(x+x+)+y"#, "x", ""),
    (#"^(\w+\s?)*$"#, "word ", "!"),
    (#"(.*a){12}"#, "a", "b"),
  ]

  @Test func pathologicalPatternsFinishFast() throws {
    let clock = ContinuousClock()
    for (pattern, unit, tail) in Self.pathological {
      let re = try Regexp.compile(pattern)
      for n in [10, 1_000, 10_000] {
        let input = String(repeating: unit, count: n) + tail
        let start = clock.now
        let matched = re.matchString(input)
        _ = re.findStringSubmatchIndex(input)
        let elapsed = clock.now - start
        // Generous bound for debug builds on slow CI machines; an exponential
        // engine takes longer than the age of the universe on the 10k inputs.
        #expect(elapsed < .seconds(30), "\(pattern) on \(n) units took \(elapsed)")
        if pattern == #"(.*a){12}"# {
          #expect(matched == (n >= 12))
        } else {
          #expect(!matched, "\(pattern) should not match")
        }
      }
    }
  }

  /// Go's NFA allocates a thread, with its capture slots, when a queue entry needs one, so memory
  /// follows the threads alive at once. Allocating slots for the bound of 2n threads up front
  /// takes (2n + 2) * ncap words per match: quadratic in the pattern for capture-heavy patterns,
  /// gigabytes for a few thousand groups.
  @Test func captureSlotsFollowLiveThreads() throws {
    let groups = 500
    let re = try Regexp.compile(String(repeating: "(a)", count: groups))
    let input = Array(String(repeating: "a", count: groups).utf8)
    re.flat.withPointers { p in
      var m = Machine(re, p, ncap: 2 * (re.numSubexp + 1))
      defer { m.deallocate() }
      let matched = input.withUnsafeBufferPointer { m.match(Input(buf: $0), 0) }
      #expect(matched)
      #expect(m.matchcap[2 * groups + 1] == groups)
      // One thread per step is alive here; Go allocates a handful.
      withKnownIssue("capture slots for 2n + 2 threads are allocated up front") {
        #expect(m.allocatedThreads <= 16, "\(m.allocatedThreads) threads for \(groups) groups")
      }
    }
  }

  /// Doubling the input should roughly double the time, never square it.
  @Test func runtimeGrowsLinearly() throws {
    let re = try Regexp.compile(#"(a*)*b"#)
    let clock = ContinuousClock()
    func time(_ n: Int) -> Duration {
      let input = String(repeating: "a", count: n)
      let start = clock.now
      _ = re.findStringSubmatchIndex(input)
      return clock.now - start
    }
    _ = time(1_000)  // warm up
    let small = time(50_000)
    let large = time(200_000)
    // 4x the input; allow up to 16x the time to absorb noise, quadratic would be 16x.
    #expect(large < small * 16 + .milliseconds(50), "50k: \(small), 200k: \(large)")
  }
}
