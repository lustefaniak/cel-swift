// Copyright 2010 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// Port of Go's regexp/exec_test.go and exec2_test.go.
//
// re2-exhaustive.txt is 64 MB uncompressed. The Go repository stores it bzip2-compressed, and
// neither Foundation nor the swift:6.0-noble image can decompress bzip2 (the image has no bzip2,
// gzip or xz binary). So the default run uses re2-exhaustive-subset.txt, a checked-in
// deterministic subset: every stanza's strings, and every 50th regexp of each stanza with all its
// result lines (about 115k of the 5.7M cases), generated with
//
//   bzip2 -dc re2-exhaustive.txt.bz2 | awk -v N=50 '/^strings$/ { inre = 0; k = -1; print; next }
//     /^regexps$/ { inre = 1; print; next } inre && /^"/ { k++; keep = (k % N == 0); if (keep) print; next }
//     inre && /^[-0-9]/ { if (keep) print; next } { print }' > re2-exhaustive-subset.txt
//
// Setting CELREGEX_EXHAUSTIVE=1 runs the full file, decompressed with the bzip2 binary (which
// must then be on PATH); it takes about 4 minutes in a debug build.

import Foundation
import Testing

@testable import CELRegex

// MARK: - Go string unquoting

/// strconv.Unquote for double-quoted Go string literals, returning raw bytes (the result may be
/// invalid UTF-8).
func goUnquote(_ s: [UInt8]) -> [UInt8]? {
  guard s.count >= 2, s.first == 0x22, s.last == 0x22 else { return nil }
  let body = s[1..<(s.count - 1)]
  var out: [UInt8] = []
  var i = body.startIndex
  func hexVal(_ c: UInt8) -> Int? {
    switch c {
    case 0x30...0x39: return Int(c - 0x30)
    case 0x61...0x66: return Int(c - 0x61 + 10)
    case 0x41...0x46: return Int(c - 0x41 + 10)
    default: return nil
    }
  }
  while i < body.endIndex {
    let c = body[i]
    if c == 0x22 || c == 0x0A {
      return nil
    }
    if c != 0x5C {
      out.append(c)
      i += 1
      continue
    }
    i += 1
    guard i < body.endIndex else { return nil }
    let e = body[i]
    i += 1
    switch e {
    case UInt8(ascii: "a"): out.append(0x07)
    case UInt8(ascii: "b"): out.append(0x08)
    case UInt8(ascii: "f"): out.append(0x0C)
    case UInt8(ascii: "n"): out.append(0x0A)
    case UInt8(ascii: "r"): out.append(0x0D)
    case UInt8(ascii: "t"): out.append(0x09)
    case UInt8(ascii: "v"): out.append(0x0B)
    case UInt8(ascii: "\\"): out.append(0x5C)
    case UInt8(ascii: "\""): out.append(0x22)
    case UInt8(ascii: "x"), UInt8(ascii: "u"), UInt8(ascii: "U"):
      let n = e == UInt8(ascii: "x") ? 2 : (e == UInt8(ascii: "u") ? 4 : 8)
      guard i + n <= body.endIndex else { return nil }
      var v = 0
      for k in 0..<n {
        guard let h = hexVal(body[i + k]) else { return nil }
        v = v * 16 + h
      }
      i += n
      if e == UInt8(ascii: "x") {
        out.append(UInt8(v))
      } else {
        guard v <= 0x10FFFF, !(0xD800...0xDFFF).contains(v) else { return nil }
        GoUTF8.appendRune(&out, Rune(v))
      }
    case 0x30...0x37:
      guard i + 2 <= body.endIndex else { return nil }
      var v = Int(e - 0x30)
      for k in 0..<2 {
        let d = body[i + k]
        guard d >= 0x30 && d <= 0x37 else { return nil }
        v = v * 8 + Int(d - 0x30)
      }
      guard v <= 255 else { return nil }
      i += 2
      out.append(UInt8(v))
    default:
      return nil
    }
  }
  return out
}

/// The string for a Go source string that must be valid UTF-8 (a regexp).
private func validString(_ b: [UInt8]) -> String? {
  let s = String(decoding: b, as: UTF8.self)
  return Array(s.utf8) == b ? s : nil
}

private func splitLines(_ data: Data) -> [ArraySlice<UInt8>] {
  let all = [UInt8](data)
  var lines: [ArraySlice<UInt8>] = []
  var start = 0
  for (i, c) in all.enumerated() where c == 0x0A {
    lines.append(all[start..<i])
    start = i + 1
  }
  if start < all.count {
    lines.append(all[start...])
  }
  return lines
}

// MARK: - testRE2

private func isSingleBytes(_ s: [UInt8]) -> Bool {
  s.allSatisfy { $0 < 0x80 }
}

/// parseResult parses "-" (no match) or a space-separated list of "lo-hi" or "-" pairs.
private func parseResult(_ res: Substring) -> [Int]?? {
  // A single - indicates no match.
  if res == "-" {
    return .some(nil)
  }
  var out: [Int] = []
  for pair in res.split(separator: " ", omittingEmptySubsequences: false) {
    if pair == "-" {
      out.append(-1)
      out.append(-1)
      continue
    }
    let parts = pair.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2, let lo = Int(parts[0]), let hi = Int(parts[1]), lo <= hi else {
      return nil
    }
    out.append(lo)
    out.append(hi)
  }
  return .some(out)
}

private struct RE2Stats {
  var ncase = 0
  var nfail = 0
}

/// testRE2 runs a re2-search.txt style log; see the format description in Go's exec_test.go.
private func testRE2(file: String, lines: [ArraySlice<UInt8>]) -> RE2Stats {
  var stats = RE2Stats()
  var str: [[UInt8]] = []
  var input: [[UInt8]] = []
  var inputIndex = 0
  var inStrings = false
  var re: Regexp? = nil
  var refull: Regexp? = nil

  func fail(_ lineno: Int, _ msg: String) -> Bool {
    Issue.record("\(file):\(lineno): \(msg)")
    stats.nfail += 1
    return stats.nfail >= 100
  }

  for (idx, line) in lines.enumerated() {
    let lineno = idx + 1
    guard let first = line.first else {
      Issue.record("\(file):\(lineno): unexpected blank line")
      return stats
    }
    if first == UInt8(ascii: "#") {
      continue
    }
    if first >= UInt8(ascii: "A") && first <= UInt8(ascii: "Z") {
      // Test name.
      continue
    }
    if line.elementsEqual("strings".utf8) {
      str.removeAll()
      inStrings = true
    } else if line.elementsEqual("regexps".utf8) {
      inStrings = false
    } else if first == 0x22 {
      guard let q = goUnquote(Array(line)) else {
        // Fatal because we'll get out of sync.
        Issue.record("\(file):\(lineno): unquote \(String(decoding: line, as: UTF8.self))")
        return stats
      }
      if inStrings {
        str.append(q)
        continue
      }
      // Is a regexp.
      if inputIndex < input.count {
        Issue.record("\(file):\(lineno): out of sync: have \(input.count - inputIndex) strings left")
        return stats
      }
      guard let qs = validString(q) else {
        re = nil
        if fail(lineno, "regexp \(goQuote(q)) is not valid UTF-8") { return stats }
        continue
      }
      do {
        re = try Regexp.compile(qs)
      } catch {
        re = nil
        if error.description == #"error parsing regexp: invalid escape sequence: `\C`"# {
          // We don't and likely never will support \C; keep going.
          continue
        }
        if fail(lineno, "compile \(qs): \(error)") { return stats }
        continue
      }
      let full = #"\A(?:"# + qs + #")\z"#
      do {
        refull = try Regexp.compile(full)
      } catch {
        // Fatal because q worked, so this should always work.
        Issue.record("\(file):\(lineno): compile full \(full): \(error)")
        return stats
      }
      input = str
      inputIndex = 0
    } else if first == UInt8(ascii: "-") || (first >= UInt8(ascii: "0") && first <= UInt8(ascii: "9")) {
      // A sequence of match results.
      stats.ncase += 1
      guard var re, var refull else {
        // Failed to compile: skip results.
        continue
      }
      if inputIndex >= input.count {
        Issue.record("\(file):\(lineno): out of sync: no input remaining")
        return stats
      }
      let text = input[inputIndex]
      inputIndex += 1
      if !isSingleBytes(text) && re.description.contains(#"\B"#) {
        // RE2's \B considers every byte position,
        // so it sees 'not word boundary' in the
        // middle of UTF-8 sequences. This package
        // only considers the positions between runes,
        // so it disagrees. Skip those cases.
        continue
      }
      let lineStr = String(decoding: line, as: UTF8.self)
      let res = lineStr.split(separator: ";", omittingEmptySubsequences: false)
      if res.count != 4 {
        Issue.record("\(file):\(lineno): have \(res.count) test results, want 4")
        return stats
      }
      for i in 0..<4 {
        // run[i] / match[i]: full, partial, full longest, partial longest.
        let useFull = i == 0 || i == 2
        let longest = i >= 2
        let suffix = ["[full]", "", "[full,longest]", "[longest]"][i]
        guard let want = parseResult(res[i]) else {
          Issue.record("\(file):\(lineno): invalid result \(res[i])")
          return stats
        }
        let have: [Int]?
        let b: Bool
        if useFull {
          refull.longest = longest
          have = refull.findSubmatchIndex(text)
          b = refull.match(text)
        } else {
          re.longest = longest
          have = re.findSubmatchIndex(text)
          b = re.match(text)
        }
        if have != want {
          if fail(lineno, "\(re)\(suffix).FindSubmatchIndex(\(goQuote(text))) = \(String(describing: have)), want \(String(describing: want))") {
            return stats
          }
          continue
        }
        if b != (want != nil) {
          if fail(lineno, "\(re)\(suffix).MatchString(\(goQuote(text))) = \(b), want \(!b)") {
            return stats
          }
          continue
        }
      }
    } else {
      Issue.record("\(file):\(lineno): out of sync: \(String(decoding: line, as: UTF8.self))")
      return stats
    }
  }
  if inputIndex < input.count {
    Issue.record("\(file): out of sync: have \(input.count - inputIndex) strings left at EOF")
  }
  return stats
}

// MARK: - Fowler

private struct FowlerResult {
  var ok = false
  var compiled = false
  var matched = false
  var pos: [Int] = []
}

private func parseFowlerResult(_ s0: [UInt8]) -> FowlerResult {
  var r = FowlerResult()
  var s = s0[...]
  if s.isEmpty {
    // Match with no position information.
    r.ok = true
    r.compiled = true
    r.matched = true
    return r
  }
  if s.elementsEqual("NOMATCH".utf8) {
    // Match failure.
    r.ok = true
    r.compiled = true
    r.matched = false
    return r
  }
  if let f = s.first, f >= UInt8(ascii: "A") && f <= UInt8(ascii: "Z") {
    // All the other error codes are compile errors.
    r.ok = true
    r.compiled = false
    return r
  }
  r.compiled = true

  var x: [Int] = []
  while !s.isEmpty {
    var end = UInt8(ascii: ")")
    if x.count % 2 == 0 {
      if s.first != UInt8(ascii: "(") {
        r.ok = false
        return r
      }
      s = s.dropFirst()
      end = UInt8(ascii: ",")
    }
    var i = s.startIndex
    while i < s.endIndex && s[i] != end {
      i += 1
    }
    if i == s.startIndex || i == s.endIndex {
      r.ok = false
      return r
    }
    var v = -1
    let field = String(decoding: s[s.startIndex..<i], as: UTF8.self)
    if field != "?" {
      guard let n = Int(field) else {
        r.ok = false
        return r
      }
      v = n
    }
    x.append(v)
    s = s[(i + 1)...]
  }
  if x.count % 2 != 0 {
    r.ok = false
    return r
  }
  r.ok = true
  r.matched = true
  r.pos = x
  return r
}

private func testFowler(_ file: String) throws {
  let notab = try Regexp.compilePOSIX(#"[^\t]+"#)
  let data = try resourceData(file)
  // Go reads lines with ReadString('\n'); a final line without '\n' is dropped.
  var all = [UInt8](data)
  if let last = all.lastIndex(of: 0x0A) {
    all = Array(all[...last])
  } else {
    all = []
  }
  var lines: [[UInt8]] = []
  var start = 0
  for (i, c) in all.enumerated() where c == 0x0A {
    lines.append(Array(all[start...i]))
    start = i + 1
  }

  var lastRegexp: [UInt8] = []
  reading: for (idx, line0) in lines.enumerated() {
    let lineno = idx + 1
    if line0[0] == UInt8(ascii: "#") || line0[0] == 0x0A {
      continue reading
    }
    let line = Array(line0.dropLast())
    var field = notab.findAll(line, -1)
    for (i, f) in field.enumerated() {
      if f.elementsEqual("NULL".utf8) {
        field[i] = []
      }
      if f.elementsEqual("NIL".utf8) {
        continue reading
      }
    }
    if field.isEmpty {
      continue reading
    }

    var flag = field[0][...]
    switch flag.first ?? 0 {
    case UInt8(ascii: "?"), UInt8(ascii: "&"), UInt8(ascii: "|"), UInt8(ascii: ";"), UInt8(ascii: "{"),
      UInt8(ascii: "}"):
      // Ignore all the control operators.
      // Just run everything.
      flag = flag.dropFirst()
      if flag.isEmpty {
        continue reading
      }
    case UInt8(ascii: ":"):
      let rest = flag.dropFirst()
      guard let colon = rest.firstIndex(of: UInt8(ascii: ":")) else {
        continue reading
      }
      flag = rest[(colon + 1)...]
    case UInt8(ascii: "C"), UInt8(ascii: "N"), UInt8(ascii: "T"), UInt8(ascii: "0")...UInt8(ascii: "9"):
      continue reading
    default:
      break
    }

    // Can check field count now that we've handled the myriad comment formats.
    if field.count < 4 {
      Issue.record("\(file):\(lineno): too few fields: \(goQuote(line))")
      continue reading
    }

    // Expand C escapes (a.k.a. Go escapes).
    if flag.contains(UInt8(ascii: "$")) {
      for k in 1...2 {
        let f = [0x22] + field[k] + [0x22]
        if let u = goUnquote(f) {
          field[k] = u
        } else {
          Issue.record("\(file):\(lineno): cannot unquote \(goQuote(f))")
        }
      }
    }

    //   Field 2: the regular expression pattern; SAME uses the pattern from
    //     the previous specification.
    if field[1].elementsEqual("SAME".utf8) {
      field[1] = lastRegexp
    }
    lastRegexp = field[1]

    //   Field 3: the string to match.
    let text = field[2]

    //   Field 4: the test outcome...
    let result = parseFowlerResult(field[3])
    if !result.ok {
      Issue.record("\(file):\(lineno): cannot parse result \(goQuote(field[3]))")
      continue reading
    }

    // Run test once for each specified capital letter mode that we support.
    testing: for c in flag {
      var pattern = field[1]
      var syn: Syntax.Flags = [.classNL]  // syntax.POSIX | syntax.ClassNL
      switch c {
      case UInt8(ascii: "E"):
        // extended regexp (what we support)
        break
      case UInt8(ascii: "L"):
        // literal
        pattern = Regexp.quoteMeta(bytes: pattern)
      default:
        continue testing
      }

      if flag.contains(UInt8(ascii: "i")) {
        syn.formUnion(.foldCase)
      }

      guard let patternStr = validString(pattern) else {
        Issue.record("\(file):\(lineno): pattern \(goQuote(pattern)) is not valid UTF-8")
        continue testing
      }
      let re: Regexp
      do {
        re = try Regexp(patternStr, syn, longest: true)
      } catch {
        if result.compiled {
          Issue.record("\(file):\(lineno): \(patternStr) did not compile")
        }
        continue testing
      }
      if !result.compiled {
        Issue.record("\(file):\(lineno): \(patternStr) should not compile")
        continue testing
      }
      let match = re.match(text)
      if match != result.matched {
        Issue.record("\(file):\(lineno): \(patternStr).Match(\(goQuote(text))) = \(match), want \(result.matched)")
        continue testing
      }
      var have = re.findSubmatchIndex(text) ?? []
      if (have.count > 0) != match {
        Issue.record(
          "\(file):\(lineno): \(patternStr).Match(\(goQuote(text))) = \(match), but FindSubmatchIndex = \(have)")
        continue testing
      }
      if have.count > result.pos.count {
        have = Array(have[..<result.pos.count])
      }
      #expect(have == result.pos, "\(file):\(lineno): \(patternStr).FindSubmatchIndex(\(goQuote(text)))")
    }
  }
}

// MARK: - Tests

struct ExecTests {
  @Test func re2Search() throws {
    let stats = testRE2(file: "re2-search.txt", lines: splitLines(try resourceData("re2-search.txt")))
    #expect(stats.ncase > 0)
  }

  /// Go's TestRE2Exhaustive (exec2_test.go), on the checked-in deterministic subset by default
  /// and on the full file when CELREGEX_EXHAUSTIVE=1.
  @Test func re2Exhaustive() throws {
    if ProcessInfo.processInfo.environment["CELREGEX_EXHAUSTIVE"] == "1" {
      let data = try bunzip2(resourcePath("re2-exhaustive.txt.bz2"))
      let stats = testRE2(file: "re2-exhaustive.txt", lines: splitLines(data))
      #expect(stats.ncase > 5_000_000)
    } else {
      let stats = testRE2(
        file: "re2-exhaustive-subset.txt", lines: splitLines(try resourceData("re2-exhaustive-subset.txt")))
      #expect(stats.ncase > 0)
    }
  }

  @Test(arguments: ["basic.dat", "nullsubexpr.dat", "repetition.dat"])
  func fowler(_ file: String) throws {
    try testFowler(file)
  }

  @Test func longest() throws {
    var re = try Regexp.compile(#"a(|b)"#)
    #expect(re.findString("ab") == "a", "first match")
    re.longest = true
    #expect(re.findString("ab") == "ab", "longest match")
  }

  /// TestProgramTooLongForBacktrack tests that a regex which is too long
  /// for the backtracker still executes properly.
  @Test func programTooLongForBacktrack() throws {
    let longRegex = try Regexp.compile(
      #"(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|twentyone|twentytwo|twentythree|twentyfour|twentyfive|twentysix|twentyseven|twentyeight|twentynine|thirty|thirtyone|thirtytwo|thirtythree|thirtyfour|thirtyfive|thirtysix|thirtyseven|thirtyeight|thirtynine|forty|fortyone|fortytwo|fortythree|fortyfour|fortyfive|fortysix|fortyseven|fortyeight|fortynine|fifty|fiftyone|fiftytwo|fiftythree|fiftyfour|fiftyfive|fiftysix|fiftyseven|fiftyeight|fiftynine|sixty|sixtyone|sixtytwo|sixtythree|sixtyfour|sixtyfive|sixtysix|sixtyseven|sixtyeight|sixtynine|seventy|seventyone|seventytwo|seventythree|seventyfour|seventyfive|seventysix|seventyseven|seventyeight|seventynine|eighty|eightyone|eightytwo|eightythree|eightyfour|eightyfive|eightysix|eightyseven|eightyeight|eightynine|ninety|ninetyone|ninetytwo|ninetythree|ninetyfour|ninetyfive|ninetysix|ninetyseven|ninetyeight|ninetynine|onehundred)"#
    )
    #expect(longRegex.matchString("two"))
    #expect(!longRegex.matchString("xxx"))
  }

  /// BenchmarkMatch_onepass_regex asserts that this regexp is one-pass.
  @Test func onepassBenchmarkRegexIsOnePass() throws {
    let r = try Regexp.compile(#"(?s)\A.*\z"#)
    #expect(r.onepass != nil)
  }
}

// MARK: - bzip2 (full exhaustive run only)

private func resourcePath(_ name: String) throws -> String {
  guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources") else {
    throw CocoaError(.fileNoSuchFile)
  }
  return url.path
}

private func bunzip2(_ path: String) throws -> Data {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  p.arguments = ["bzip2", "-dc", path]
  let out = Pipe()
  p.standardOutput = out
  try p.run()
  let data = out.fileHandleForReading.readDataToEndOfFile()
  p.waitUntilExit()
  guard p.terminationStatus == 0 else {
    throw CocoaError(.fileReadCorruptFile)
  }
  return data
}
