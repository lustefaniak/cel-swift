// Copyright 2009 The Go Authors. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//    * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//    * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//    * Neither the name of Google Inc. nor the names of its
// contributors may be used to endorse or promote products derived from
// this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
// Ported from Go src/time/zoneinfo_read.go (LoadLocationFromTZData, loadTzinfoFromDirOrZip for
// plain directories) and src/time/zoneinfo.go (lookup, lookupFirstZone, tzset and helpers): the
// way cel-go's `time.LoadLocation` resolves IANA time zones from the system tz database.

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

/// A time zone loaded from a TZif file: zone types, transitions and the POSIX TZ rule that
/// extends them.
struct TZifLocation: Sendable {
  struct Zone: Sendable {
    var offset: Int64
    var isDST: Bool
  }

  struct Transition: Sendable {
    var when: Int64
    var index: Int
  }

  var zones: [Zone]
  var transitions: [Transition]
  var extend: [UInt8]

  /// Go's `alpha`: the start of time for a fake transition covering everything.
  private static let alpha: Int64 = -1 << 63

  /// The directories Go searches on Unix (`platformZoneSources`).
  static let zoneSources = [
    "/usr/share/zoneinfo/", "/usr/share/lib/zoneinfo/", "/usr/lib/locale/TZ/", "/etc/zoneinfo/",
  ]

  /// Loads a zone by IANA name from the first zone source that has it.
  static func load(named name: String) -> TZifLocation? {
    for dir in zoneSources {
      if let data = readFile(dir + name), let location = TZifLocation(data: data) {
        return location
      }
    }
    return nil
  }

  /// Loads a zone from a TZif file path.
  static func load(path: String) -> TZifLocation? {
    readFile(path).flatMap(TZifLocation.init(data:))
  }

  /// Parses TZif data (versions 1 to 3). Port of Go `LoadLocationFromTZData`.
  init?(data: [UInt8]) {
    var d = Reader(data: data)
    guard d.read(4)?.elementsEqual("TZif".utf8) == true, let header = d.read(16) else {
      return nil
    }
    let version: Int
    switch header[header.startIndex] {
    case 0: version = 1
    case UInt8(ascii: "2"): version = 2
    case UInt8(ascii: "3"): version = 3
    default: return nil
    }
    // UTC/local indicators, standard/wall indicators, leap seconds, transition times,
    // local time zones, abbreviation characters.
    func readCounts(_ d: inout Reader) -> [Int]? {
      var n: [Int] = []
      for _ in 0..<6 {
        guard let v = d.big4() else { return nil }
        n.append(Int(v))
      }
      return n
    }
    guard var n = readCounts(&d) else { return nil }
    let (nUTCLocal, nStdWall, nLeap, nTime, nZone, nChar) = (0, 1, 2, 3, 4, 5)
    var is64 = false
    if version > 1 {
      let skip =
        n[nTime] * 4 + n[nTime] + n[nZone] * 6 + n[nChar] + n[nLeap] * 8 + n[nStdWall]
        + n[nUTCLocal] + 4 + 16
      guard d.read(skip) != nil, let again = readCounts(&d) else { return nil }
      n = again
      is64 = true
    }
    let size = is64 ? 8 : 4
    guard let txTimes = d.read(n[nTime] * size),
      let txZones = d.read(n[nTime]),
      let zoneData = d.read(n[nZone] * 6),
      let abbrev = d.read(n[nChar]),
      d.read(n[nLeap] * (size + 4)) != nil,
      d.read(n[nStdWall]) != nil,
      d.read(n[nUTCLocal]) != nil
    else { return nil }

    let rest = d.rest
    if rest.count > 2 && rest.first == UInt8(ascii: "\n") && rest.last == UInt8(ascii: "\n") {
      extend = Array(rest.dropFirst().dropLast())
    } else {
      extend = []
    }

    if n[nZone] == 0 {
      return nil
    }
    var zr = Reader(data: Array(zoneData))
    var zones: [Zone] = []
    for _ in 0..<n[nZone] {
      guard let off = zr.big4(), let isDST = zr.byte(), let nameIndex = zr.byte(),
        Int(nameIndex) < abbrev.count
      else { return nil }
      zones.append(Zone(offset: Int64(Int32(bitPattern: off)), isDST: isDST != 0))
    }
    self.zones = zones

    var tr = Reader(data: Array(txTimes))
    var transitions: [Transition] = []
    let zoneIndices = Array(txZones)
    for i in 0..<n[nTime] {
      let when: Int64
      if is64 {
        guard let v = tr.big8() else { return nil }
        when = Int64(bitPattern: v)
      } else {
        guard let v = tr.big4() else { return nil }
        when = Int64(Int32(bitPattern: v))
      }
      let index = Int(zoneIndices[i])
      if index >= zones.count {
        return nil
      }
      transitions.append(Transition(when: when, index: index))
    }
    if transitions.isEmpty {
      transitions.append(Transition(when: TZifLocation.alpha, index: 0))
    }
    self.transitions = transitions
  }

  /// The UTC offset in seconds in effect at `sec` seconds since the epoch. Port of Go
  /// `Location.lookup` (offset only).
  func offset(at sec: Int64) -> Int64 {
    if zones.isEmpty {
      return 0
    }
    if transitions.isEmpty || sec < transitions[0].when {
      return zones[lookupFirstZone()].offset
    }
    var lo = 0
    var hi = transitions.count
    while hi - lo > 1 {
      let m = (lo + hi) / 2
      if sec < transitions[m].when {
        hi = m
      } else {
        lo = m
      }
    }
    let zone = zones[transitions[lo].index]
    if lo == transitions.count - 1 && !extend.isEmpty,
      let offset = tzset(extend, lastTxSec: transitions[lo].when, sec: sec)
    {
      return offset
    }
    return zone.offset
  }

  /// Port of Go `lookupFirstZone`: the zone for times before the first transition.
  private func lookupFirstZone() -> Int {
    if !transitions.contains(where: { $0.index == 0 }) {
      return 0
    }
    if let first = transitions.first, zones[first.index].isDST {
      var zi = first.index - 1
      while zi >= 0 {
        if !zones[zi].isDST {
          return zi
        }
        zi -= 1
      }
    }
    if let zi = zones.firstIndex(where: { !$0.isDST }) {
      return zi
    }
    return 0
  }
}

// MARK: - POSIX TZ rules (Go tzset)

private let secondsPerHour: Int64 = 3600
private let secondsPerDay: Int64 = 86_400

private enum RuleKind {
  case julian, dayOfYear, monthWeekDay
}

private struct Rule {
  var kind = RuleKind.julian
  var day: Int64 = 0
  var week: Int64 = 0
  var mon: Int64 = 0
  var time: Int64 = 0
}

/// Port of Go `tzset`, returning only the offset in effect at `sec`.
private func tzset(_ input: [UInt8], lastTxSec: Int64, sec: Int64) -> Int64? {
  var s = input[...]
  guard tzsetName(&s) != nil, var stdOffset = tzsetOffset(&s) else { return nil }
  stdOffset = -stdOffset
  if s.isEmpty || s.first == UInt8(ascii: ",") {
    return stdOffset
  }
  guard tzsetName(&s) != nil else { return nil }
  var dstOffset: Int64
  if s.isEmpty || s.first == UInt8(ascii: ",") {
    dstOffset = stdOffset + secondsPerHour
  } else {
    guard let off = tzsetOffset(&s) else { return nil }
    dstOffset = -off
  }
  if s.isEmpty {
    s = Array(",M3.2.0,M11.1.0".utf8)[...]
  }
  guard let sep = s.first, sep == UInt8(ascii: ",") || sep == UInt8(ascii: ";") else {
    return nil
  }
  s = s.dropFirst()
  guard let startRule = tzsetRule(&s), s.first == UInt8(ascii: ",") else { return nil }
  s = s.dropFirst()
  guard let endRule = tzsetRule(&s), s.isEmpty else { return nil }

  let civil = CivilTime(localSeconds: sec, nanosecond: 0)
  let ysec = (civil.yearDay - 1) * secondsPerDay + sec % secondsPerDay
  var startSec = tzruleTime(civil.year, startRule, stdOffset)
  var endSec = tzruleTime(civil.year, endRule, dstOffset)
  var stdOff = stdOffset
  var dstOff = dstOffset
  if endSec < startSec {
    swap(&startSec, &endSec)
    swap(&stdOff, &dstOff)
  }
  if ysec < startSec {
    return stdOff
  } else if ysec >= endSec {
    return stdOff
  }
  return dstOff
}

private func tzsetName(_ s: inout ArraySlice<UInt8>) -> ArraySlice<UInt8>? {
  if s.isEmpty {
    return nil
  }
  if s.first != UInt8(ascii: "<") {
    for (i, c) in zip(s.indices, s) {
      switch c {
      case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: ","), UInt8(ascii: "-"),
        UInt8(ascii: "+"):
        if i - s.startIndex < 3 {
          return nil
        }
        let name = s[s.startIndex..<i]
        s = s[i...]
        return name
      default:
        continue
      }
    }
    if s.count < 3 {
      return nil
    }
    let name = s
    s = s[s.endIndex...]
    return name
  }
  guard let close = s.firstIndex(of: UInt8(ascii: ">")) else { return nil }
  let name = s[(s.startIndex + 1)..<close]
  s = s[(close + 1)...]
  return name
}

private func tzsetOffset(_ s: inout ArraySlice<UInt8>) -> Int64? {
  if s.isEmpty {
    return nil
  }
  var neg = false
  if s.first == UInt8(ascii: "+") {
    s = s.dropFirst()
  } else if s.first == UInt8(ascii: "-") {
    s = s.dropFirst()
    neg = true
  }
  guard let hours = tzsetNum(&s, 0, 24 * 7) else { return nil }
  var off = hours * secondsPerHour
  if s.first != UInt8(ascii: ":") {
    return neg ? -off : off
  }
  s = s.dropFirst()
  guard let mins = tzsetNum(&s, 0, 59) else { return nil }
  off += mins * 60
  if s.first != UInt8(ascii: ":") {
    return neg ? -off : off
  }
  s = s.dropFirst()
  guard let secs = tzsetNum(&s, 0, 59) else { return nil }
  off += secs
  return neg ? -off : off
}

private func tzsetRule(_ s: inout ArraySlice<UInt8>) -> Rule? {
  var r = Rule()
  guard let first = s.first else { return nil }
  if first == UInt8(ascii: "J") {
    s = s.dropFirst()
    guard let jday = tzsetNum(&s, 1, 365) else { return nil }
    r.kind = .julian
    r.day = jday
  } else if first == UInt8(ascii: "M") {
    s = s.dropFirst()
    guard let mon = tzsetNum(&s, 1, 12), s.first == UInt8(ascii: ".") else { return nil }
    s = s.dropFirst()
    guard let week = tzsetNum(&s, 1, 5), s.first == UInt8(ascii: ".") else { return nil }
    s = s.dropFirst()
    guard let day = tzsetNum(&s, 0, 6) else { return nil }
    r.kind = .monthWeekDay
    r.day = day
    r.week = week
    r.mon = mon
  } else {
    guard let day = tzsetNum(&s, 0, 365) else { return nil }
    r.kind = .dayOfYear
    r.day = day
  }
  if s.first != UInt8(ascii: "/") {
    r.time = 2 * secondsPerHour
    return r
  }
  s = s.dropFirst()
  guard let offset = tzsetOffset(&s) else { return nil }
  r.time = offset
  return r
}

private func tzsetNum(_ s: inout ArraySlice<UInt8>, _ min: Int64, _ max: Int64) -> Int64? {
  if s.isEmpty {
    return nil
  }
  var num: Int64 = 0
  var consumed = 0
  for c in s {
    if c < UInt8(ascii: "0") || c > UInt8(ascii: "9") {
      if consumed == 0 || num < min {
        return nil
      }
      s = s.dropFirst(consumed)
      return num
    }
    num = num * 10 + Int64(c - UInt8(ascii: "0"))
    if num > max {
      return nil
    }
    consumed += 1
  }
  if num < min {
    return nil
  }
  s = s[s.endIndex...]
  return num
}

private let daysBefore: [Int64] = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365]

private func tzruleTime(_ year: Int64, _ r: Rule, _ off: Int64) -> Int64 {
  var s: Int64
  switch r.kind {
  case .julian:
    s = (r.day - 1) * secondsPerDay
    if isLeapYear(year) && r.day >= 60 {
      s += secondsPerDay
    }
  case .dayOfYear:
    s = r.day * secondsPerDay
  case .monthWeekDay:
    // Zeller's Congruence.
    let m1 = (r.mon + 9) % 12 + 1
    var yy0 = year
    if r.mon <= 2 {
      yy0 -= 1
    }
    let yy1 = yy0 / 100
    let yy2 = yy0 % 100
    var dow = ((26 * m1 - 2) / 10 + 1 + yy2 + yy2 / 4 + yy1 / 4 - 2 * yy1) % 7
    if dow < 0 {
      dow += 7
    }
    var d = r.day - dow
    if d < 0 {
      d += 7
    }
    var i: Int64 = 1
    while i < r.week {
      if d + 7 >= daysIn(month: r.mon, year: year) {
        break
      }
      d += 7
      i += 1
    }
    d += daysBefore[Int(r.mon) - 1]
    if isLeapYear(year) && r.mon > 2 {
      d += 1
    }
    s = d * secondsPerDay
  }
  return s + r.time - off
}

// MARK: - Byte reading

private struct Reader {
  let data: [UInt8]
  var pos = 0

  init(data: [UInt8]) {
    self.data = data
  }

  mutating func read(_ n: Int) -> ArraySlice<UInt8>? {
    if n < 0 || n > data.count - pos {
      return nil
    }
    defer { pos += n }
    return data[pos..<(pos + n)]
  }

  mutating func big4() -> UInt32? {
    guard let p = read(4) else { return nil }
    return p.reduce(0) { $0 << 8 | UInt32($1) }
  }

  mutating func big8() -> UInt64? {
    guard let p = read(8) else { return nil }
    return p.reduce(0) { $0 << 8 | UInt64($1) }
  }

  mutating func byte() -> UInt8? {
    read(1)?.first
  }

  var rest: ArraySlice<UInt8> {
    data[pos...]
  }
}

/// Reads a whole file, up to 1 MiB (TZif files are a few KiB), or returns `nil`.
private func readFile(_ path: String) -> [UInt8]? {
  #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
    guard let file = fopen(path, "rb") else { return nil }
    defer { fclose(file) }
    var result: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let n = buffer.withUnsafeMutableBytes { fread($0.baseAddress, 1, $0.count, file) }
      if n > 0 {
        result.append(contentsOf: buffer[0..<n])
        if result.count > 1 << 20 {
          return nil
        }
      }
      if n < buffer.count {
        return ferror(file) == 0 ? result : nil
      }
    }
  #else
    return nil
  #endif
}
