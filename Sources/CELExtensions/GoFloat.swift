// Copyright 2009 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.
//
// Ported from Go src/strconv/ftoa.go (fmtE, fmtF, %e / %f with an explicit precision) and
// src/strconv/decimal.go (exact decimal conversion and round-half-even on exact ties), the float
// formatting `string.format` relies on: `fmt.Sprintf("%.Nf")`, `fmt.Sprintf("%1.Ne")` and
// `strconv.FormatFloat(f, 'f', -1, 64)`.
//
// Go formats with an explicit precision by converting the double to its exact decimal expansion
// (or an equivalent fixed-precision algorithm) and rounding half to even only on exact ties, so the
// result is the correctly rounded decimal. The port computes the exact expansion with a small
// base-10^9 big integer: a double is m × 2^e, which is m << e for e >= 0 and m × 5^-e / 10^-e
// otherwise.

import CEL

/// The exact decimal digits of a finite, non-negative double: `0.d1d2...dn × 10^decimalPoint`.
struct ExactDecimal {
  /// ASCII digits without leading or trailing zeros; empty for zero.
  var digits: [UInt8]
  /// The position of the decimal point relative to the first digit.
  var decimalPoint: Int

  init(digits: [UInt8], decimalPoint: Int) {
    self.digits = digits
    self.decimalPoint = decimalPoint
  }

  init(_ value: Double) {
    precondition(value.isFinite && value >= 0)
    if value == 0 {
      digits = []
      decimalPoint = 0
      return
    }
    let bits = value.bitPattern
    let biasedExponent = Int((bits >> 52) & 0x7FF)
    var mantissa = bits & ((1 << 52) - 1)
    var exponent: Int
    if biasedExponent == 0 {
      exponent = -1074
    } else {
      mantissa |= 1 << 52
      exponent = biasedExponent - 1075
    }
    // Strip trailing zero bits so the big integer stays small.
    while mantissa & 1 == 0 {
      mantissa >>= 1
      exponent += 1
    }
    var big = BigDecimalInt(mantissa)
    var pointShift = 0
    if exponent >= 0 {
      big.multiply(byPowerOf: 2, exponent)
    } else {
      big.multiply(byPowerOf: 5, -exponent)
      pointShift = -exponent
    }
    var ds = big.decimalDigits()
    let point = ds.count - pointShift
    while let last = ds.last, last == UInt8(ascii: "0") {
      ds.removeLast()
    }
    digits = ds
    decimalPoint = point
  }

  /// Whether rounding to `nd` digits rounds up (Go `shouldRoundUp`, exact digits, no truncation).
  private func shouldRoundUp(_ nd: Int) -> Bool {
    if digits[nd] == UInt8(ascii: "5") && nd + 1 == digits.count {
      // Exactly halfway: round to even.
      return nd > 0 && (digits[nd - 1] - UInt8(ascii: "0")) % 2 == 1
    }
    return digits[nd] >= UInt8(ascii: "5")
  }

  /// Rounds to `nd` significant digits (Go `decimal.Round`).
  mutating func round(toDigits nd: Int) {
    if nd < 0 || nd >= digits.count {
      return
    }
    if shouldRoundUp(nd) {
      roundUp(nd)
    } else {
      roundDown(nd)
    }
  }

  private mutating func roundDown(_ nd: Int) {
    digits.removeSubrange(nd...)
    trim()
  }

  private mutating func roundUp(_ nd: Int) {
    var i = nd - 1
    while i >= 0 {
      if digits[i] < UInt8(ascii: "9") {
        digits[i] += 1
        digits.removeSubrange((i + 1)...)
        return
      }
      i -= 1
    }
    // All nines: 999 rounds to 1000.
    digits = [UInt8(ascii: "1")]
    decimalPoint += 1
  }

  private mutating func trim() {
    while let last = digits.last, last == UInt8(ascii: "0") {
      digits.removeLast()
    }
    if digits.isEmpty {
      decimalPoint = 0
    }
  }

  func digit(_ i: Int) -> UInt8 {
    i >= 0 && i < digits.count ? digits[i] : UInt8(ascii: "0")
  }
}

/// A non-negative big integer in base 10^9 limbs, least significant first.
private struct BigDecimalInt {
  private static let base: UInt64 = 1_000_000_000
  private var limbs: [UInt64]

  init(_ value: UInt64) {
    limbs = []
    var v = value
    repeat {
      limbs.append(v % Self.base)
      v /= Self.base
    } while v > 0
  }

  private mutating func multiply(by factor: UInt64) {
    var carry: UInt64 = 0
    for i in limbs.indices {
      let product = limbs[i] * factor + carry
      limbs[i] = product % Self.base
      carry = product / Self.base
    }
    while carry > 0 {
      limbs.append(carry % Self.base)
      carry /= Self.base
    }
  }

  /// Multiplies by `base^power` for base 2 or 5, in chunks that keep products below 2^64.
  mutating func multiply(byPowerOf base: UInt64, _ power: Int) {
    // 2^29 and 5^12 stay below 2^30, so limb (< 10^9) × chunk + carry fits in 64 bits.
    let (chunk, chunkPower): (UInt64, Int) = base == 2 ? (1 << 29, 29) : (244_140_625, 12)
    var remaining = power
    while remaining >= chunkPower {
      multiply(by: chunk)
      remaining -= chunkPower
    }
    if remaining > 0 {
      var factor: UInt64 = 1
      for _ in 0..<remaining {
        factor *= base
      }
      multiply(by: factor)
    }
  }

  func decimalDigits() -> [UInt8] {
    var out: [UInt8] = []
    var first = true
    for limb in limbs.reversed() {
      var chunk = Array(String(limb).utf8)
      if !first {
        chunk = Array(repeating: UInt8(ascii: "0"), count: 9 - chunk.count) + chunk
      }
      first = false
      out += chunk
    }
    return out
  }
}

enum GoFloat {
  /// `fmt.Sprintf("%.<prec>f", value)` for a finite value: the sign, then the correctly rounded
  /// digits.
  static func fixed(_ value: Double, precision: Int) -> String {
    var d = ExactDecimal(Swift.abs(value))
    d.round(toDigits: d.decimalPoint + precision)
    var out: [UInt8] = []
    if value.sign == .minus {
      out.append(UInt8(ascii: "-"))
    }
    appendFixed(&out, d, precision: precision)
    return String(decoding: out, as: UTF8.self)
  }

  /// The integer and fraction digits of a rounded decimal (Go `fmtF` without the sign).
  static func appendFixed(_ out: inout [UInt8], _ d: ExactDecimal, precision: Int) {
    if d.decimalPoint > 0 {
      var m = min(d.digits.count, d.decimalPoint)
      out += d.digits[0..<m]
      while m < d.decimalPoint {
        out.append(UInt8(ascii: "0"))
        m += 1
      }
    } else {
      out.append(UInt8(ascii: "0"))
    }
    if precision > 0 {
      out.append(UInt8(ascii: "."))
      for i in 1...precision {
        out.append(d.digit(d.decimalPoint + i - 1))
      }
    }
  }

  /// `fmt.Sprintf("%.<prec>e", value)` for a finite value (Go `fmtE`: at least two exponent digits).
  static func scientific(_ value: Double, precision: Int) -> String {
    var d = ExactDecimal(Swift.abs(value))
    d.round(toDigits: precision + 1)
    var out: [UInt8] = []
    if value.sign == .minus {
      out.append(UInt8(ascii: "-"))
    }
    out.append(d.digits.isEmpty ? UInt8(ascii: "0") : d.digits[0])
    if precision > 0 {
      out.append(UInt8(ascii: "."))
      for i in 1...precision {
        out.append(d.digit(i))
      }
    }
    out.append(UInt8(ascii: "e"))
    var exp = d.digits.isEmpty ? 0 : d.decimalPoint - 1
    if exp < 0 {
      out.append(UInt8(ascii: "-"))
      exp = -exp
    } else {
      out.append(UInt8(ascii: "+"))
    }
    if exp < 10 {
      out.append(UInt8(ascii: "0"))
    }
    out += Array(String(exp).utf8)
    return String(decoding: out, as: UTF8.self)
  }

  /// `strconv.FormatFloat(value, 'f', -1, 64)` for a finite value: the shortest digits that
  /// round-trip, without an exponent.
  static func shortestFixed(_ value: Double) -> String {
    let (digits, point) = GoFormat.shortestDigits(Swift.abs(value))
    var out: [UInt8] = []
    if value.sign == .minus {
      out.append(UInt8(ascii: "-"))
    }
    // Go fmtF with prec = max(nd - dp, 0).
    let precision = max(digits.count - point, 0)
    appendFixed(
      &out, ExactDecimal(digits: digits, decimalPoint: digits.isEmpty ? 0 : point),
      precision: precision)
    return String(decoding: out, as: UTF8.self)
  }
}
