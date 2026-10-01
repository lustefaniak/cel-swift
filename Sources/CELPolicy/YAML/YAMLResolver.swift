//
// Copyright (c) 2011-2019 Canonical Ltd
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Ported from go.yaml.in/yaml/v3 resolve.go.
//
// go-yaml resolves plain scalars with its own rules: YAML 1.2 core schema booleans and nulls
// (`true`, `True`, `TRUE`, ...; `yes` / `on` stay strings), YAML 1.1 style octals kept for
// compatibility, `0b` / `0o` prefixes, underscores in numbers, and timestamps. Yams' resolver
// follows YAML 1.1, so the rules are ported here to get identical tags.

/// A scalar resolved to its tag and native value.
enum YAMLResolvedScalar: Equatable {
  case null
  case bool(Bool)
  case int(Int64)
  case uint(UInt64)
  case float(Double)
  case string(String)
  case timestamp(String)
  case merge

  static func == (lhs: YAMLResolvedScalar, rhs: YAMLResolvedScalar) -> Bool {
    switch (lhs, rhs) {
    case (.null, .null), (.merge, .merge): return true
    case let (.bool(a), .bool(b)): return a == b
    case let (.int(a), .int(b)): return a == b
    case let (.uint(a), .uint(b)): return a == b
    case let (.float(a), .float(b)): return a == b || (a.isNaN && b.isNaN)
    case let (.string(a), .string(b)): return a == b
    case let (.timestamp(a), .timestamp(b)): return a == b
    default: return false
    }
  }
}

enum YAMLResolver {
  private static let resolveMap: [String: (tag: String, value: YAMLResolvedScalar)] = {
    var m: [String: (tag: String, value: YAMLResolvedScalar)] = [:]
    for s in ["true", "True", "TRUE"] { m[s] = (YAMLTags.bool, .bool(true)) }
    for s in ["false", "False", "FALSE"] { m[s] = (YAMLTags.bool, .bool(false)) }
    for s in ["", "~", "null", "Null", "NULL"] { m[s] = (YAMLTags.null, .null) }
    for s in [".nan", ".NaN", ".NAN"] { m[s] = (YAMLTags.float, .float(.nan)) }
    for s in [".inf", ".Inf", ".INF", "+.inf", "+.Inf", "+.INF"] { m[s] = (YAMLTags.float, .float(.infinity)) }
    for s in ["-.inf", "-.Inf", "-.INF"] { m[s] = (YAMLTags.float, .float(-.infinity)) }
    m["<<"] = (YAMLTags.merge, .merge)
    return m
  }()

  private static func hint(_ c: Unicode.Scalar) -> Character? {
    switch c {
    case "+", "-": return "S"
    case "0"..."9": return "D"
    case "y", "Y", "n", "N", "t", "T", "f", "F", "o", "O", "~": return "M"
    case ".": return "."
    default: return nil
    }
  }

  private static func resolvable(_ tag: String) -> Bool {
    switch tag {
    case "", YAMLTags.str, YAMLTags.bool, YAMLTags.int, YAMLTags.float, YAMLTags.null, YAMLTags.timestamp:
      return true
    default:
      return false
    }
  }

  /// Resolves a scalar `value` carrying the (possibly empty) explicit `tag`.
  ///
  /// Returns the resolved short tag and native value, or an error message in go-yaml's format when
  /// an explicit tag does not match the content (`cannot decode !!str `x` as a !!int`).
  static func resolve(tag inTag: String, _ value: String) -> (tag: String, value: YAMLResolvedScalar, error: String?) {
    let tag = YAMLTags.shortTag(inTag)
    if !resolvable(tag) {
      return (tag, .string(value), nil)
    }
    let (rtag, out) = resolveUnchecked(tag: tag, value)
    switch tag {
    case "", rtag, YAMLTags.str, YAMLTags.binary:
      return (rtag, out, nil)
    case YAMLTags.float:
      if rtag == YAMLTags.int {
        switch out {
        case .int(let v): return (YAMLTags.float, .float(Double(v)), nil)
        default: break
        }
      }
    default:
      break
    }
    return (rtag, out, "cannot decode \(YAMLTags.shortTag(rtag)) `\(value)` as a \(YAMLTags.shortTag(tag))")
  }

  private static func resolveUnchecked(tag: String, _ value: String) -> (String, YAMLResolvedScalar) {
    var h: Character? = "N"
    if let first = value.unicodeScalars.first {
      h = hint(first)
    }
    guard let hint = h, tag != YAMLTags.str, tag != YAMLTags.binary else {
      return (YAMLTags.str, .string(value))
    }
    if let item = resolveMap[value] {
      return (item.tag, item.value)
    }
    switch hint {
    case ".":
      if let f = parseDotFloat(value) {
        return (YAMLTags.float, .float(f))
      }
    case "D", "S":
      if tag.isEmpty || tag == YAMLTags.timestamp {
        if isTimestamp(value) {
          return (YAMLTags.timestamp, .timestamp(value))
        }
      }
      let plain = value.replacingAll("_", with: "")
      if let v = parseGoInt(plain) {
        return (YAMLTags.int, .int(v))
      }
      if let v = parseGoUInt(plain) {
        return (YAMLTags.int, .uint(v))
      }
      if isYAMLStyleFloat(plain), let f = Double(plain) {
        return (YAMLTags.float, .float(f))
      }
      if plain.hasPrefix("0b") {
        if let v = Int64(plain.dropFirst(2), radix: 2) { return (YAMLTags.int, .int(v)) }
        if let v = UInt64(plain.dropFirst(2), radix: 2) { return (YAMLTags.int, .uint(v)) }
      } else if plain.hasPrefix("-0b") {
        if let v = Int64("-" + plain.dropFirst(3), radix: 2) { return (YAMLTags.int, .int(v)) }
      }
      if plain.hasPrefix("0o") {
        if let v = Int64(plain.dropFirst(2), radix: 8) { return (YAMLTags.int, .int(v)) }
        if let v = UInt64(plain.dropFirst(2), radix: 8) { return (YAMLTags.int, .uint(v)) }
      } else if plain.hasPrefix("-0o") {
        if let v = Int64("-" + plain.dropFirst(3), radix: 8) { return (YAMLTags.int, .int(v)) }
      }
    default:
      break
    }
    return (YAMLTags.str, .string(value))
  }

  // MARK: - strconv emulation

  /// `strconv.ParseInt(s, 0, 64)`: optional sign, then a `0x` / `0o` / `0b` / `0` base prefix.
  static func parseGoInt(_ s: String) -> Int64? {
    var body = Substring(s)
    var negative = false
    if body.hasPrefix("+") || body.hasPrefix("-") {
      negative = body.hasPrefix("-")
      body = body.dropFirst()
    }
    guard let magnitude = parseGoUIntBody(body) else { return nil }
    if negative {
      if magnitude <= UInt64(Int64.max) { return -Int64(magnitude) }
      if magnitude == UInt64(Int64.max) + 1 { return Int64.min }
      return nil
    }
    return magnitude <= UInt64(Int64.max) ? Int64(magnitude) : nil
  }

  /// `strconv.ParseUint(s, 0, 64)`.
  static func parseGoUInt(_ s: String) -> UInt64? {
    parseGoUIntBody(Substring(s))
  }

  private static func parseGoUIntBody(_ s: Substring) -> UInt64? {
    guard !s.isEmpty else { return nil }
    var digits = s
    var radix = 10
    if s.count >= 2, s.hasPrefix("0") {
      let second = s[s.index(after: s.startIndex)]
      switch second {
      case "x", "X":
        radix = 16
        digits = s.dropFirst(2)
      case "o", "O":
        radix = 8
        digits = s.dropFirst(2)
      case "b", "B":
        radix = 2
        digits = s.dropFirst(2)
      default:
        radix = 8
        digits = s.dropFirst(1)
      }
    }
    guard !digits.isEmpty, digits.unicodeScalars.allSatisfy({ $0.properties.isASCIIHexDigit || $0 == "x" }) else {
      return nil
    }
    guard digits.first != "+", digits.first != "-" else { return nil }
    return UInt64(digits, radix: radix)
  }

  private static func isDigit(_ c: Unicode.Scalar) -> Bool {
    c >= "0" && c <= "9"
  }

  /// `strconv.ParseFloat` for values starting with `.` (the only floats that reach it).
  private static func parseDotFloat(_ s: String) -> Double? {
    isYAMLStyleFloat(s) ? Double(s) : nil
  }

  /// `^[-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?$`
  static func isYAMLStyleFloat(_ s: String) -> Bool {
    let u = Array(s.unicodeScalars)
    var i = 0
    if i < u.count, u[i] == "+" || u[i] == "-" { i += 1 }
    if i < u.count, u[i] == "." {
      i += 1
      let start = i
      while i < u.count, isDigit(u[i]) { i += 1 }
      if i == start { return false }
    } else {
      let start = i
      while i < u.count, isDigit(u[i]) { i += 1 }
      if i == start { return false }
      if i < u.count, u[i] == "." {
        i += 1
        while i < u.count, isDigit(u[i]) { i += 1 }
      }
    }
    if i < u.count, u[i] == "e" || u[i] == "E" {
      i += 1
      if i < u.count, u[i] == "+" || u[i] == "-" { i += 1 }
      let start = i
      while i < u.count, isDigit(u[i]) { i += 1 }
      if i == start { return false }
    }
    return i == u.count
  }

  // MARK: - Timestamps

  /// Whether `s` parses with one of go-yaml's `allowedTimestampFormats` under Go's `time.Parse`:
  /// `2006-1-2T15:4:5.999999999Z07:00` (`T` or `t`), `2006-1-2 15:4:5.999999999`, `2006-1-2`.
  static func isTimestamp(_ s: String) -> Bool {
    let u = Array(s.unicodeScalars)
    var i = 0
    while i < u.count, isDigit(u[i]) { i += 1 }
    if i != 4 || i == u.count || u[i] != "-" {
      return false
    }
    i += 1
    func number(maxDigits: Int) -> Int? {
      let start = i
      var v = 0
      while i < u.count, i - start < maxDigits, isDigit(u[i]) {
        v = v * 10 + Int(u[i].value - 48)
        i += 1
      }
      return i == start ? nil : v
    }
    guard let year = Int(String(String.UnicodeScalarView(u[0..<4]))) else { return false }
    guard let month = number(maxDigits: 2), (1...12).contains(month) else { return false }
    guard i < u.count, u[i] == "-" else { return false }
    i += 1
    guard let day = number(maxDigits: 2), day >= 1, day <= daysIn(month: month, year: year) else { return false }
    if i == u.count {
      return true
    }
    let separator = u[i]
    guard separator == "T" || separator == "t" || separator == " " else { return false }
    i += 1
    guard let hour = number(maxDigits: 2), hour < 24 else { return false }
    guard i < u.count, u[i] == ":" else { return false }
    i += 1
    guard let minute = number(maxDigits: 2), minute < 60 else { return false }
    guard i < u.count, u[i] == ":" else { return false }
    i += 1
    guard let second = number(maxDigits: 2), second < 60 else { return false }
    if i < u.count, u[i] == "." || u[i] == ",", i + 1 < u.count, isDigit(u[i + 1]) {
      i += 1
      while i < u.count, isDigit(u[i]) { i += 1 }
    }
    if separator == " " {
      return i == u.count
    }
    guard i < u.count else { return false }
    if u[i] == "Z" {
      return i + 1 == u.count
    }
    guard u[i] == "+" || u[i] == "-" else { return false }
    i += 1
    let hStart = i
    guard let tzHour = number(maxDigits: 2), i - hStart == 2, tzHour < 24 else { return false }
    guard i < u.count, u[i] == ":" else { return false }
    i += 1
    let mStart = i
    guard let tzMinute = number(maxDigits: 2), i - mStart == 2, tzMinute < 60 else { return false }
    return i == u.count
  }

  private static func daysIn(month: Int, year: Int) -> Int {
    switch month {
    case 2:
      let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
      return leap ? 29 : 28
    case 4, 6, 9, 11:
      return 30
    default:
      return 31
    }
  }
}

extension String {
  /// Replaces every occurrence of `target` with `replacement`, without Foundation.
  func replacingAll(_ target: String, with replacement: String) -> String {
    guard !target.isEmpty else { return self }
    var result = ""
    var rest = Substring(self)
    while let range = rest.range(of: target) {
      result += rest[rest.startIndex..<range.lowerBound]
      result += replacement
      rest = rest[range.upperBound...]
    }
    result += rest
    return result
  }
}

extension Substring {
  fileprivate func range(of target: String) -> Range<Index>? {
    let t = Array(target.unicodeScalars)
    let scalars = unicodeScalars
    var i = scalars.startIndex
    while i != scalars.endIndex {
      var j = i
      var k = 0
      while k < t.count, j != scalars.endIndex, scalars[j] == t[k] {
        j = scalars.index(after: j)
        k += 1
      }
      if k == t.count {
        return i..<j
      }
      i = scalars.index(after: i)
    }
    return nil
  }
}
