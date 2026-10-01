// Copyright 2009 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.
//
// Ported from Go src/internal/strconv/ftoa.go (formatDigits, fmtE, fmtF), as used by cel-go for `string(double)`, duration formatting and
// `types.Format`. Shortest round-trip digits come from Swift's `Double.description`, which, like
// Go's shortest formatting, yields the shortest digit string that round-trips, choosing the
// closest candidate.

/// The formatting styles of Go `strconv.FormatFloat` with precision `-1` (shortest).
enum GoFloatFormat {
  /// `'f'`: no exponent.
  case fixed
  /// `'g'`: exponent form when the decimal exponent is below -4 or at least 6, else fixed.
  case general
}

/// Shortest decimal digits of a finite double: the value is `0.d1d2... × 10^decimalPoint`.
private struct ShortestDecimal {
  var digits: [UInt8] = []
  var decimalPoint = 0
}

private func shortestDecimal(_ magnitude: Double) -> ShortestDecimal {
  var result = ShortestDecimal()
  if magnitude == 0 {
    return result
  }
  let text = Array(magnitude.description.utf8)
  var mantissa: [UInt8] = []
  var intDigits = 0
  var sawDot = false
  var exponent = 0
  var i = 0
  while i < text.count {
    let c = text[i]
    if c == UInt8(ascii: ".") {
      sawDot = true
    } else if c == UInt8(ascii: "e") || c == UInt8(ascii: "E") {
      var sign = 1
      i += 1
      if i < text.count && (text[i] == UInt8(ascii: "-") || text[i] == UInt8(ascii: "+")) {
        sign = text[i] == UInt8(ascii: "-") ? -1 : 1
        i += 1
      }
      var e = 0
      while i < text.count {
        e = e * 10 + Int(text[i] - UInt8(ascii: "0"))
        i += 1
      }
      exponent = sign * e
      break
    } else {
      mantissa.append(c)
      if !sawDot {
        intDigits += 1
      }
    }
    i += 1
  }
  var dp = intDigits + exponent
  var start = 0
  while start < mantissa.count && mantissa[start] == UInt8(ascii: "0") {
    start += 1
    dp -= 1
  }
  var end = mantissa.count
  while end > start && mantissa[end - 1] == UInt8(ascii: "0") {
    end -= 1
  }
  result.digits = Array(mantissa[start..<end])
  result.decimalPoint = dp
  return result
}

/// Go `strconv.FormatFloat(value, fmt, -1, 64)` for `'f'` and `'g'`.
func formatGoFloat(_ value: Double, format: GoFloatFormat) -> String {
  if value.isNaN {
    return "NaN"
  }
  if value.isInfinite {
    return value < 0 ? "-Inf" : "+Inf"
  }
  let neg = value.sign == .minus
  let digs = shortestDecimal(value.magnitude)
  var out: [UInt8] = []
  switch format {
  case .fixed:
    fmtF(&out, neg, digs, max(digs.digits.count - digs.decimalPoint, 0))
  case .general:
    let eprec = 6
    let exp = digs.decimalPoint - 1
    if exp < -4 || exp >= eprec {
      fmtE(&out, neg, digs, digs.digits.count - 1)
    } else {
      fmtF(&out, neg, digs, max(digs.digits.count - digs.decimalPoint, 0))
    }
  }
  return String(decoding: out, as: UTF8.self)
}

private func fmtE(_ dst: inout [UInt8], _ neg: Bool, _ d: ShortestDecimal, _ prec: Int) {
  if neg {
    dst.append(UInt8(ascii: "-"))
  }
  dst.append(d.digits.first ?? UInt8(ascii: "0"))
  if prec > 0 {
    dst.append(UInt8(ascii: "."))
    var i = 1
    let m = min(d.digits.count, prec + 1)
    if i < m {
      dst.append(contentsOf: d.digits[i..<m])
      i = m
    }
    while i <= prec {
      dst.append(UInt8(ascii: "0"))
      i += 1
    }
  }
  dst.append(UInt8(ascii: "e"))
  var exp = d.decimalPoint - 1
  if d.digits.isEmpty {
    exp = 0
  }
  if exp < 0 {
    dst.append(UInt8(ascii: "-"))
    exp = -exp
  } else {
    dst.append(UInt8(ascii: "+"))
  }
  let zero = UInt8(ascii: "0")
  if exp < 10 {
    dst.append(contentsOf: [zero, zero + UInt8(exp)])
  } else if exp < 100 {
    dst.append(contentsOf: [zero + UInt8(exp / 10), zero + UInt8(exp % 10)])
  } else {
    dst.append(contentsOf: [zero + UInt8(exp / 100), zero + UInt8((exp / 10) % 10), zero + UInt8(exp % 10)])
  }
}

private func fmtF(_ dst: inout [UInt8], _ neg: Bool, _ d: ShortestDecimal, _ prec: Int) {
  if neg {
    dst.append(UInt8(ascii: "-"))
  }
  if d.decimalPoint > 0 {
    let m = min(d.digits.count, d.decimalPoint)
    dst.append(contentsOf: d.digits[0..<m])
    if m < d.decimalPoint {
      dst.append(contentsOf: repeatElement(UInt8(ascii: "0"), count: d.decimalPoint - m))
    }
  } else {
    dst.append(UInt8(ascii: "0"))
  }
  if prec > 0 {
    dst.append(UInt8(ascii: "."))
    for i in 0..<prec {
      let j = d.decimalPoint + i
      dst.append(0 <= j && j < d.digits.count ? d.digits[j] : UInt8(ascii: "0"))
    }
  }
}

// MARK: - strconv.Quote

/// Go `strconv.Quote`, shared with the debug printer (`Common/GoStrconv.swift`).
func goQuote(_ s: String) -> String {
  GoFormat.quote(s)
}

// MARK: - fmt %v

/// Formats a value as Go's `fmt` `%v` verb does for cel-go values, used in error messages such as
/// `no such key: x`.
package func formatGoValue(_ value: Value) -> String {
  switch value {
  case .null: return "NULL_VALUE"
  case .bool(let b): return b ? "true" : "false"
  case .int(let i): return String(i)
  case .uint(let u): return String(u)
  case .double(let d): return formatGoFloat(d, format: .general)
  case .string(let s): return s
  case .bytes(let b): return "[" + b.map { String($0) }.joined(separator: " ") + "]"
  case .duration(let d): return goDurationString(d.nanoseconds)
  case .timestamp(let t): return t.celString
  case .error(let e): return e.message
  case .type(let t): return t.description
  default: return value.description
  }
}
