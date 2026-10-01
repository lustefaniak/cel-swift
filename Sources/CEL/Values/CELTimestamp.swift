// Copyright 2018 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Ported from cel-go common/types/timestamp.go.

/// A CEL `google.protobuf.Timestamp` value: an instant with nanosecond precision.
///
/// The valid CEL range is `0001-01-01T00:00:00Z` through `9999-12-31T23:59:59.999999999Z`.
/// Like a Go `time.Time` parsed from RFC 3339 text, a timestamp remembers the UTC offset it was
/// written with; the offset only affects ``celString``, never equality or ordering.
public struct CELTimestamp: Sendable, Hashable, Comparable {
  /// Whole seconds since the Unix epoch, `1970-01-01T00:00:00Z`.
  public let secondsSinceEpoch: Int64
  /// The nanosecond within the second, `0..<1_000_000_000`.
  public let nanoseconds: Int32
  /// The UTC offset in seconds used when formatting; `0` formats as `Z`.
  public let utcOffsetSeconds: Int32

  /// Creates a timestamp from whole seconds since the Unix epoch and the nanosecond within that
  /// second.
  ///
  /// - Precondition: `nanoseconds` is in `0..<1_000_000_000`. For an instant before the epoch
  ///   with a fraction, count the seconds down: `-0.5` seconds is `secondsSinceEpoch: -1,
  ///   nanoseconds: 500_000_000`.
  public init(secondsSinceEpoch: Int64, nanoseconds: Int32 = 0, utcOffsetSeconds: Int32 = 0) {
    precondition(
      nanoseconds >= 0 && Int64(nanoseconds) < CELDuration.nanosPerSecond,
      "CELTimestamp nanoseconds must be in 0..<1_000_000_000")
    self.secondsSinceEpoch = secondsSinceEpoch
    self.nanoseconds = nanoseconds
    self.utcOffsetSeconds = utcOffsetSeconds
  }

  /// Creates a timestamp from seconds and a nanosecond count that may lie outside one second,
  /// carrying whole seconds out of the nanoseconds as Go's `time.Unix` does, or `nil` if the
  /// seconds overflow.
  package init?(secondsSinceEpoch: Int64, carryingNanoseconds nanoseconds: Int64, utcOffsetSeconds: Int32 = 0) {
    var carry = nanoseconds / CELDuration.nanosPerSecond
    var nsec = nanoseconds % CELDuration.nanosPerSecond
    if nsec < 0 {
      carry -= 1
      nsec += CELDuration.nanosPerSecond
    }
    let (sec, overflow) = secondsSinceEpoch.addingReportingOverflow(carry)
    if overflow {
      return nil
    }
    self.init(secondsSinceEpoch: sec, nanoseconds: Int32(nsec), utcOffsetSeconds: utcOffsetSeconds)
  }

  /// The earliest valid CEL timestamp in Unix seconds, `0001-01-01T00:00:00Z`.
  public static let minSecondsSinceEpoch: Int64 = -62_135_596_800
  /// The latest valid CEL timestamp in Unix seconds, `9999-12-31T23:59:59Z`.
  public static let maxSecondsSinceEpoch: Int64 = 253_402_300_799

  /// Whether the timestamp lies within the CEL range.
  public var isInRange: Bool {
    secondsSinceEpoch >= CELTimestamp.minSecondsSinceEpoch
      && secondsSinceEpoch <= CELTimestamp.maxSecondsSinceEpoch
  }

  /// Equality of the instants, ignoring the formatting offset.
  public static func == (lhs: CELTimestamp, rhs: CELTimestamp) -> Bool {
    lhs.secondsSinceEpoch == rhs.secondsSinceEpoch && lhs.nanoseconds == rhs.nanoseconds
  }

  /// Hashes the instant, ignoring the formatting offset.
  public func hash(into hasher: inout Hasher) {
    hasher.combine(secondsSinceEpoch)
    hasher.combine(nanoseconds)
  }

  /// Orders timestamps by instant.
  public static func < (lhs: CELTimestamp, rhs: CELTimestamp) -> Bool {
    (lhs.secondsSinceEpoch, lhs.nanoseconds) < (rhs.secondsSinceEpoch, rhs.nanoseconds)
  }

  /// Whether this is Go's zero `time.Time`, `0001-01-01T00:00:00Z`.
  var isGoZeroTime: Bool {
    secondsSinceEpoch == CELTimestamp.minSecondsSinceEpoch && nanoseconds == 0
  }

  /// The RFC 3339 form with the shortest nanosecond fraction and the remembered offset, as Go
  /// `Format(time.RFC3339Nano)`: `2009-02-13T23:31:30.123Z`, `2009-02-13T23:31:30+01:00`.
  public var celString: String {
    formatRFC3339Nano(self, offsetSeconds: Int64(utcOffsetSeconds))
  }

  /// The RFC 3339 form in UTC, used by the debug formatter.
  var utcString: String {
    formatRFC3339Nano(self, offsetSeconds: 0)
  }
}

// MARK: - Civil calendar

/// A broken-down civil time, the equivalent of Go `time.Time` accessors in a fixed offset.
struct CivilTime: Equatable {
  var year: Int64
  /// 1...12.
  var month: Int64
  /// 1...31.
  var day: Int64
  var hour: Int64
  var minute: Int64
  var second: Int64
  var nanosecond: Int64
  /// 0 = Sunday.
  var weekday: Int64
  /// 1...366.
  var yearDay: Int64

  /// Breaks down `seconds` since the epoch (already shifted by any UTC offset).
  init(localSeconds seconds: Int64, nanosecond: Int64) {
    let days = floorDiv(seconds, 86_400)
    let secOfDay = seconds - days * 86_400
    let (y, m, d) = civilFromDays(days)
    year = y
    month = m
    day = d
    hour = secOfDay / 3600
    minute = (secOfDay % 3600) / 60
    second = secOfDay % 60
    self.nanosecond = nanosecond
    // 1970-01-01 was a Thursday.
    weekday = floorMod(days + 4, 7)
    yearDay = days - daysFromCivil(year: y, month: 1, day: 1) + 1
  }
}

func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
  let q = a / b
  return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
}

func floorMod(_ a: Int64, _ b: Int64) -> Int64 {
  a - floorDiv(a, b) * b
}

/// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
func daysFromCivil(year: Int64, month: Int64, day: Int64) -> Int64 {
  let y = month <= 2 ? year - 1 : year
  let era = floorDiv(y, 400)
  let yoe = y - era * 400
  let mp = (month + 9) % 12
  let doy = (153 * mp + 2) / 5 + day - 1
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
  return era * 146_097 + doe - 719_468
}

/// The proleptic Gregorian date for days since 1970-01-01 (Howard Hinnant's algorithm).
func civilFromDays(_ days: Int64) -> (year: Int64, month: Int64, day: Int64) {
  let z = days + 719_468
  let era = floorDiv(z, 146_097)
  let doe = z - era * 146_097
  let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
  let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
  let mp = (5 * doy + 2) / 153
  let day = doy - (153 * mp + 2) / 5 + 1
  let month = mp < 10 ? mp + 3 : mp - 9
  let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
  return (year, month, day)
}

func isLeapYear(_ year: Int64) -> Bool {
  year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
}

func daysIn(month: Int64, year: Int64) -> Int64 {
  switch month {
  case 2: return isLeapYear(year) ? 29 : 28
  case 4, 6, 9, 11: return 30
  default: return 31
  }
}

extension CELTimestamp {
  /// The civil time at a UTC offset.
  func civil(offsetSeconds: Int64) -> CivilTime {
    CivilTime(localSeconds: secondsSinceEpoch &+ offsetSeconds, nanosecond: Int64(nanoseconds))
  }
}

// MARK: - RFC 3339

private func appendPadded(_ out: inout String, _ value: Int64, width: Int) {
  let digits = String(value.magnitude)
  if value < 0 {
    out.append("-")
  }
  if digits.utf8.count < width {
    out.append(String(repeating: "0", count: width - digits.utf8.count))
  }
  out.append(digits)
}

/// Go `Format(time.RFC3339Nano)` for a timestamp at a fixed offset.
func formatRFC3339Nano(_ ts: CELTimestamp, offsetSeconds: Int64) -> String {
  let c = ts.civil(offsetSeconds: offsetSeconds)
  var out = ""
  appendPadded(&out, c.year, width: 4)
  out.append("-")
  appendPadded(&out, c.month, width: 2)
  out.append("-")
  appendPadded(&out, c.day, width: 2)
  out.append("T")
  appendPadded(&out, c.hour, width: 2)
  out.append(":")
  appendPadded(&out, c.minute, width: 2)
  out.append(":")
  appendPadded(&out, c.second, width: 2)
  if c.nanosecond != 0 {
    var value = c.nanosecond
    var width = 9
    while value % 10 == 0 {
      value /= 10
      width -= 1
    }
    out.append(".")
    appendPadded(&out, value, width: width)
  }
  if offsetSeconds == 0 {
    out.append("Z")
  } else {
    let zone = offsetSeconds / 60
    out.append(zone < 0 ? "-" : "+")
    let absZone = zone.magnitude
    appendPadded(&out, Int64(absZone / 60), width: 2)
    out.append(":")
    appendPadded(&out, Int64(absZone % 60), width: 2)
  }
  return out
}

/// Port of cel-go `isStrictRFC3339`: validates the shape of an RFC 3339 timestamp before parsing.
func isStrictRFC3339(_ s: [UInt8]) -> Bool {
  if s.count < 20 {
    return false
  }
  func inRange(_ slice: ArraySlice<UInt8>, _ lo: UInt64, _ hi: UInt64) -> Bool {
    guard let u = parseGoUint(slice) else { return false }
    return u >= lo && u <= hi
  }
  func isChar(_ got: UInt8, _ want: UInt8) -> Bool {
    got == want || (got >= 0x41 && got <= 0x5A && got + 0x20 == want)
  }
  func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
  if !inRange(s[0..<4], 0, 9999) || !isChar(s[4], 0x2D) || !inRange(s[5..<7], 1, 12)
    || !isChar(s[7], 0x2D) || !inRange(s[8..<10], 1, 31) || !isChar(s[10], 0x74)
    || !inRange(s[11..<13], 0, 23) || !isChar(s[13], 0x3A) || !inRange(s[14..<16], 0, 59)
    || !isChar(s[16], 0x3A) || !inRange(s[17..<19], 0, 60)
  {
    return false
  }
  var rest = s[19...]
  if rest.first == 0x2E {
    rest = rest.dropFirst()
    var n = 0
    while n < rest.count && isDigit(rest[rest.startIndex + n]) {
      n += 1
    }
    if n == 0 {
      return false
    }
    rest = rest.dropFirst(n)
  }
  if rest.count == 1 {
    return isChar(rest[rest.startIndex], 0x7A)
  }
  if rest.count == 6, let first = rest.first, first == 0x2B || first == 0x2D {
    let b = rest.startIndex
    return inRange(rest[(b + 1)..<(b + 3)], 0, 23) && isChar(rest[b + 3], 0x3A)
      && inRange(rest[(b + 4)..<(b + 6)], 0, 59)
  }
  return false
}

/// Parses an unsigned decimal of ASCII digits, as Go `strconv.ParseUint(s, 10, 64)`.
private func parseGoUint(_ s: ArraySlice<UInt8>) -> UInt64? {
  if s.isEmpty { return nil }
  var n: UInt64 = 0
  for c in s {
    guard c >= 0x30 && c <= 0x39 else { return nil }
    let (m, o1) = n.multipliedReportingOverflow(by: 10)
    let (a, o2) = m.addingReportingOverflow(UInt64(c - 0x30))
    if o1 || o2 { return nil }
    n = a
  }
  return n
}

/// Port of Go `time.parseRFC3339` (the fast path of `time.Parse(time.RFC3339, s)`).
///
/// Returns `nil` when the text is not a valid RFC 3339 timestamp; Go's general layout parser,
/// which runs after a fast-path failure, accepts nothing more once ``isStrictRFC3339(_:)`` holds.
func parseRFC3339(_ text: String) -> CELTimestamp? {
  let s = Array(text.utf8)
  if s.count < 19 {
    return nil
  }
  var ok = true
  func parseUint(_ slice: ArraySlice<UInt8>, _ min: Int64, _ max: Int64) -> Int64 {
    var x: Int64 = 0
    for c in slice {
      if c < 0x30 || c > 0x39 {
        ok = false
        return min
      }
      x = x * 10 + Int64(c - 0x30)
    }
    if x < min || max < x {
      ok = false
      return min
    }
    return x
  }
  let year = parseUint(s[0..<4], 0, 9999)
  let month = parseUint(s[5..<7], 1, 12)
  let day = parseUint(s[8..<10], 1, daysIn(month: month, year: year))
  let hour = parseUint(s[11..<13], 0, 23)
  let minute = parseUint(s[14..<16], 0, 59)
  let second = parseUint(s[17..<19], 0, 59)
  if !ok || !(s[4] == 0x2D && s[7] == 0x2D && s[10] == 0x54 && s[13] == 0x3A && s[16] == 0x3A) {
    return nil
  }
  var rest = s[19...]
  var nsec: Int64 = 0
  if rest.count >= 2, rest[rest.startIndex] == 0x2E,
    (0x30...0x39).contains(rest[rest.startIndex + 1])
  {
    var n = 2
    while n < rest.count && (0x30...0x39).contains(rest[rest.startIndex + n]) {
      n += 1
    }
    // Go parseNanoseconds: at most nine digits are significant.
    var digits = 0
    for c in rest[(rest.startIndex + 1)..<(rest.startIndex + n)] where digits < 9 {
      nsec = nsec * 10 + Int64(c - 0x30)
      digits += 1
    }
    while digits < 9 {
      nsec *= 10
      digits += 1
    }
    rest = rest.dropFirst(n)
  }
  var seconds =
    daysFromCivil(year: year, month: month, day: day) * 86_400 + hour * 3600 + minute * 60 + second
  var offset: Int64 = 0
  if !(rest.count == 1 && rest[rest.startIndex] == 0x5A) {
    if rest.count != 6 {
      return nil
    }
    let b = rest.startIndex
    let hr = parseUint(rest[(b + 1)..<(b + 3)], 0, 23)
    let mm = parseUint(rest[(b + 4)..<(b + 6)], 0, 59)
    if !ok || !((rest[b] == 0x2D || rest[b] == 0x2B) && rest[b + 3] == 0x3A) {
      return nil
    }
    offset = (hr * 60 + mm) * 60
    if rest[b] == 0x2D {
      offset = -offset
    }
    seconds -= offset
  }
  return CELTimestamp(
    secondsSinceEpoch: seconds, nanoseconds: Int32(nsec), utcOffsetSeconds: Int32(offset))
}
