// Copyright 2009 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.
//
// Ported from Go src/internal/strconv/atof.go (special, readFloat, underscoreOK),
// src/internal/strconv/atoi.go, src/strconv/atob.go and src/time/format.go (ParseDuration,
// Duration.String), the parsers cel-go uses for string conversions.

private let ascii0 = UInt8(ascii: "0")
private let ascii9 = UInt8(ascii: "9")

private func lower(_ c: UInt8) -> UInt8 {
  c | 0x20
}

private func isDigit(_ c: UInt8) -> Bool {
  c >= ascii0 && c <= ascii9
}

// MARK: - ParseFloat

/// Go `strconv.ParseFloat(s, 64)`: returns `nil` for syntax errors and for values out of range
/// (which Go reports as `ErrRange`).
func parseGoFloat(_ text: String) -> Double? {
  let s = Array(text.utf8)
  if let special = goSpecialFloat(s) {
    return special
  }
  guard let cleaned = goReadFloat(s) else {
    return nil
  }
  guard let value = Double(String(decoding: cleaned, as: UTF8.self)), !value.isNaN else {
    return nil
  }
  if value.isInfinite {
    return nil
  }
  return value
}

/// Go `special`: `inf`, `infinity` (any case, optional sign) and `nan` (any case, no sign),
/// consuming the whole string.
private func goSpecialFloat(_ s: [UInt8]) -> Double? {
  guard let first = s.first else { return nil }
  var sign = 1.0
  var rest = s[...]
  switch first {
  case UInt8(ascii: "+"), UInt8(ascii: "-"), UInt8(ascii: "i"), UInt8(ascii: "I"):
    if first == UInt8(ascii: "+") || first == UInt8(ascii: "-") {
      sign = first == UInt8(ascii: "-") ? -1 : 1
      rest = rest.dropFirst()
    }
    let word = Array("infinity".utf8)
    var n = 0
    while n < rest.count && n < word.count && lower(rest[rest.startIndex + n]) == word[n] {
      n += 1
    }
    if 3 < n && n < 8 {
      n = 3
    }
    if (n == 3 || n == 8) && n == rest.count {
      return sign * .infinity
    }
  case UInt8(ascii: "n"), UInt8(ascii: "N"):
    if s.count == 3 && lower(s[1]) == UInt8(ascii: "a") && lower(s[2]) == UInt8(ascii: "n") {
      return .nan
    }
  default:
    break
  }
  return nil
}

/// Validates `s` against Go's `readFloat` grammar, requiring the whole string to be consumed,
/// and returns it without underscores for conversion.
private func goReadFloat(_ s: [UInt8]) -> [UInt8]? {
  var i = 0
  var underscores = false
  if i >= s.count {
    return nil
  }
  if s[i] == UInt8(ascii: "+") || s[i] == UInt8(ascii: "-") {
    i += 1
  }
  var base = 10
  var expChar = UInt8(ascii: "e")
  if i + 2 < s.count && s[i] == ascii0 && lower(s[i + 1]) == UInt8(ascii: "x") {
    base = 16
    i += 2
    expChar = UInt8(ascii: "p")
  }
  var sawDot = false
  var sawDigits = false
  loop: while i < s.count {
    let c = s[i]
    switch true {
    case c == UInt8(ascii: "_"):
      underscores = true
    case c == UInt8(ascii: "."):
      if sawDot {
        break loop
      }
      sawDot = true
    case isDigit(c):
      sawDigits = true
    case base == 16 && lower(c) >= UInt8(ascii: "a") && lower(c) <= UInt8(ascii: "f"):
      sawDigits = true
    default:
      break loop
    }
    i += 1
  }
  if !sawDigits {
    return nil
  }
  if i < s.count && lower(s[i]) == expChar {
    i += 1
    if i >= s.count {
      return nil
    }
    if s[i] == UInt8(ascii: "+") || s[i] == UInt8(ascii: "-") {
      i += 1
    }
    if i >= s.count || !isDigit(s[i]) {
      return nil
    }
    while i < s.count && (isDigit(s[i]) || s[i] == UInt8(ascii: "_")) {
      if s[i] == UInt8(ascii: "_") {
        underscores = true
      }
      i += 1
    }
  } else if base == 16 {
    return nil
  }
  if underscores && !goUnderscoreOK(s[0..<i]) {
    return nil
  }
  if i != s.count {
    return nil
  }
  return underscores ? s.filter { $0 != UInt8(ascii: "_") } : s
}

/// Go `underscoreOK`: underscores may only separate digits, or follow a base prefix.
private func goUnderscoreOK(_ input: ArraySlice<UInt8>) -> Bool {
  var saw = UInt8(ascii: "^")
  var s = input
  if let first = s.first, first == UInt8(ascii: "-") || first == UInt8(ascii: "+") {
    s = s.dropFirst()
  }
  let chars = Array(s)
  var i = 0
  var hex = false
  if chars.count >= 2 && chars[0] == ascii0
    && [UInt8(ascii: "b"), UInt8(ascii: "o"), UInt8(ascii: "x")].contains(lower(chars[1]))
  {
    i = 2
    saw = ascii0
    hex = lower(chars[1]) == UInt8(ascii: "x")
  }
  while i < chars.count {
    let c = chars[i]
    if isDigit(c) || (hex && lower(c) >= UInt8(ascii: "a") && lower(c) <= UInt8(ascii: "f")) {
      saw = ascii0
    } else if c == UInt8(ascii: "_") {
      if saw != ascii0 {
        return false
      }
      saw = UInt8(ascii: "_")
    } else {
      if saw == UInt8(ascii: "_") {
        return false
      }
      saw = UInt8(ascii: "!")
    }
    i += 1
  }
  return saw != UInt8(ascii: "_")
}

// MARK: - ParseInt / ParseUint / ParseBool

/// Go `strconv.ParseUint(s, 10, 64)`: ASCII digits only, no sign.
func parseGoUint(_ text: String) -> UInt64? {
  let s = text.utf8
  if s.isEmpty {
    return nil
  }
  var n: UInt64 = 0
  for c in s {
    guard isDigit(c) else { return nil }
    let (m, o1) = n.multipliedReportingOverflow(by: 10)
    let (a, o2) = m.addingReportingOverflow(UInt64(c - ascii0))
    if o1 || o2 {
      return nil
    }
    n = a
  }
  return n
}

/// Go `strconv.ParseInt(s, 10, 64)`: an optional `+` or `-` sign followed by ASCII digits.
func parseGoInt(_ text: String) -> Int64? {
  var s = Substring(text)
  var neg = false
  if let first = s.utf8.first, first == UInt8(ascii: "+") || first == UInt8(ascii: "-") {
    neg = first == UInt8(ascii: "-")
    s = s.dropFirst()
  }
  guard let u = parseGoUint(String(s)) else {
    return nil
  }
  if neg {
    if u > UInt64(Int64.max) + 1 {
      return nil
    }
    return u == UInt64(Int64.max) + 1 ? Int64.min : -Int64(u)
  }
  return u > UInt64(Int64.max) ? nil : Int64(u)
}

/// Go `strconv.ParseBool`: `1`, `t`, `T`, `TRUE`, `true`, `True` and the `false` equivalents.
func parseGoBool(_ text: String) -> Bool? {
  switch text {
  case "1", "t", "T", "TRUE", "true", "True": return true
  case "0", "f", "F", "FALSE", "false", "False": return false
  default: return nil
  }
}

// MARK: - time.ParseDuration

private let durationUnits: [[UInt8]: UInt64] = [
  Array("ns".utf8): 1,
  Array("us".utf8): 1_000,
  Array("\u{00B5}s".utf8): 1_000,
  Array("\u{03BC}s".utf8): 1_000,
  Array("ms".utf8): 1_000_000,
  Array("s".utf8): 1_000_000_000,
  Array("m".utf8): 60_000_000_000,
  Array("h".utf8): 3_600_000_000_000,
]

/// Go `time.ParseDuration`: a signed sequence of decimal numbers with optional fractions and
/// unit suffixes, such as `300ms`, `-1.5h` or `2h45m`. Returns the duration in nanoseconds.
func parseGoDuration(_ text: String) -> Int64? {
  var s = Array(text.utf8)[...]
  var d: UInt64 = 0
  var neg = false
  if let c = s.first, c == UInt8(ascii: "-") || c == UInt8(ascii: "+") {
    neg = c == UInt8(ascii: "-")
    s = s.dropFirst()
  }
  if s.count == 1 && s.first == ascii0 {
    return 0
  }
  if s.isEmpty {
    return nil
  }
  let limit: UInt64 = 1 << 63
  while !s.isEmpty {
    var v: UInt64 = 0
    var f: UInt64 = 0
    var scale: Double = 1
    guard let c0 = s.first, c0 == UInt8(ascii: ".") || isDigit(c0) else {
      return nil
    }
    // leadingInt
    let pl = s.count
    while let c = s.first, isDigit(c) {
      if v > limit / 10 {
        return nil
      }
      v = v * 10 + UInt64(c - ascii0)
      if v > limit {
        return nil
      }
      s = s.dropFirst()
    }
    let pre = pl != s.count
    var post = false
    if s.first == UInt8(ascii: ".") {
      s = s.dropFirst()
      let pl2 = s.count
      // leadingFraction
      var overflow = false
      while let c = s.first, isDigit(c) {
        s = s.dropFirst()
        if overflow {
          continue
        }
        if f > (limit - 1) / 10 {
          overflow = true
          continue
        }
        let y = f * 10 + UInt64(c - ascii0)
        if y > limit {
          overflow = true
          continue
        }
        f = y
        scale *= 10
      }
      post = pl2 != s.count
    }
    if !pre && !post {
      return nil
    }
    var i = s.startIndex
    while i < s.endIndex {
      let c = s[i]
      if c == UInt8(ascii: ".") || isDigit(c) {
        break
      }
      i += 1
    }
    if i == s.startIndex {
      return nil
    }
    let unitName = Array(s[s.startIndex..<i])
    s = s[i...]
    guard let unit = durationUnits[unitName] else {
      return nil
    }
    if v > limit / unit {
      return nil
    }
    v *= unit
    if f > 0 {
      v += UInt64(Double(f) * (Double(unit) / scale))
      if v > limit {
        return nil
      }
    }
    d += v
    if d > limit {
      return nil
    }
  }
  if neg {
    return d == limit ? Int64.min : -Int64(d)
  }
  if d > limit - 1 {
    return nil
  }
  return Int64(d)
}

/// Go `time.Duration.String`, such as `1h2m3.5s`, `1.5ms` or `0s`.
func goDurationString(_ nanoseconds: Int64) -> String {
  var buf: [UInt8] = []
  var u = nanoseconds.magnitude
  let neg = nanoseconds < 0

  func fmtFrac(_ v: UInt64, _ prec: Int) -> UInt64 {
    var v = v
    var digits: [UInt8] = []
    var print = false
    for _ in 0..<prec {
      let digit = v % 10
      print = print || digit != 0
      if print {
        digits.append(UInt8(digit) + ascii0)
      }
      v /= 10
    }
    if print {
      buf.append(contentsOf: digits)
      buf.append(UInt8(ascii: "."))
    }
    return v
  }
  func fmtInt(_ v: UInt64) {
    if v == 0 {
      buf.append(ascii0)
      return
    }
    var v = v
    while v > 0 {
      buf.append(UInt8(v % 10) + ascii0)
      v /= 10
    }
  }

  // Built in reverse, as Go does, then reversed at the end.
  if u < 1_000_000_000 {
    buf.append(UInt8(ascii: "s"))
    let prec: Int
    if u == 0 {
      return "0s"
    } else if u < 1_000 {
      prec = 0
      buf.append(UInt8(ascii: "n"))
    } else if u < 1_000_000 {
      prec = 3
      // U+00B5 'µ' encoded as 0xC2 0xB5, appended in reverse.
      buf.append(0xB5)
      buf.append(0xC2)
    } else {
      prec = 6
      buf.append(UInt8(ascii: "m"))
    }
    u = fmtFrac(u, prec)
    fmtInt(u)
  } else {
    buf.append(UInt8(ascii: "s"))
    u = fmtFrac(u, 9)
    fmtInt(u % 60)
    u /= 60
    if u > 0 {
      buf.append(UInt8(ascii: "m"))
      fmtInt(u % 60)
      u /= 60
      if u > 0 {
        buf.append(UInt8(ascii: "h"))
        fmtInt(u)
      }
    }
  }
  if neg {
    buf.append(UInt8(ascii: "-"))
  }
  return String(decoding: buf.reversed(), as: UTF8.self)
}
