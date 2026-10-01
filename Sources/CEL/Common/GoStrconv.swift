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

// Ports of the Go standard library formatting that cel-go's debug printer and unparser rely on:
// strconv.Quote, strconv.IsPrint and strconv.FormatFloat(f, 'g', -1, 64) (which is also fmt's %v).

/// Go-compatible string formatting helpers.
package enum GoFormat {
  private static let lowerhex: [Unicode.Scalar] = Array("0123456789abcdef".unicodeScalars)

  /// `strconv.Quote` of a string.
  package static func quote(_ s: String) -> String {
    var out = "\""
    for r in s.unicodeScalars {
      appendEscapedRune(&out, r)
    }
    out += "\""
    return out
  }

  /// `strconv.Quote(string(bytes))`: valid UTF-8 sequences are quoted as runes, other bytes as `\xNN`.
  package static func quote(bytes: [UInt8]) -> String {
    var out = "\""
    var i = 0
    while i < bytes.count {
      let (scalar, width) = decodeRune(bytes, i)
      if let scalar {
        appendEscapedRune(&out, scalar)
      } else {
        let b = bytes[i]
        out += "\\x"
        out.unicodeScalars.append(lowerhex[Int(b >> 4)])
        out.unicodeScalars.append(lowerhex[Int(b & 0xF)])
      }
      i += width
    }
    out += "\""
    return out
  }

  /// Decodes one UTF-8 sequence at `i` the way Go does: `nil` with width 1 for an invalid byte.
  package static func decodeRune(_ b: [UInt8], _ i: Int) -> (Unicode.Scalar?, Int) {
    let n = b.count
    let c0 = b[i]
    if c0 < 0x80 {
      return (Unicode.Scalar(c0), 1)
    }
    func cont(_ j: Int) -> UInt32? {
      guard j < n, b[j] & 0xC0 == 0x80 else { return nil }
      return UInt32(b[j] & 0x3F)
    }
    if c0 >= 0xC2 && c0 <= 0xDF {
      if let c1 = cont(i + 1) {
        return (Unicode.Scalar((UInt32(c0 & 0x1F) << 6) | c1), 2)
      }
      return (nil, 1)
    }
    if c0 >= 0xE0 && c0 <= 0xEF {
      guard i + 1 < n else { return (nil, 1) }
      let b1 = b[i + 1]
      let lo: UInt8 = c0 == 0xE0 ? 0xA0 : 0x80
      let hi: UInt8 = c0 == 0xED ? 0x9F : 0xBF
      guard b1 >= lo && b1 <= hi, let c2 = cont(i + 2) else { return (nil, 1) }
      let v = (UInt32(c0 & 0x0F) << 12) | (UInt32(b1 & 0x3F) << 6) | c2
      return (Unicode.Scalar(v), 3)
    }
    if c0 >= 0xF0 && c0 <= 0xF4 {
      guard i + 1 < n else { return (nil, 1) }
      let b1 = b[i + 1]
      let lo: UInt8 = c0 == 0xF0 ? 0x90 : 0x80
      let hi: UInt8 = c0 == 0xF4 ? 0x8F : 0xBF
      guard b1 >= lo && b1 <= hi, let c2 = cont(i + 2), let c3 = cont(i + 3) else { return (nil, 1) }
      let v = (UInt32(c0 & 0x07) << 18) | (UInt32(b1 & 0x3F) << 12) | (c2 << 6) | c3
      return (Unicode.Scalar(v), 4)
    }
    return (nil, 1)
  }

  private static func appendEscapedRune(_ out: inout String, _ r: Unicode.Scalar) {
    if r == "\"" || r == "\\" {
      out += "\\"
      out.unicodeScalars.append(r)
      return
    }
    if isPrint(r) {
      out.unicodeScalars.append(r)
      return
    }
    switch r {
    case "\u{07}": out += "\\a"
    case "\u{08}": out += "\\b"
    case "\u{0C}": out += "\\f"
    case "\n": out += "\\n"
    case "\r": out += "\\r"
    case "\t": out += "\\t"
    case "\u{0B}": out += "\\v"
    default:
      let v = r.value
      if v < 0x20 || v == 0x7F {
        out += "\\x"
        out.unicodeScalars.append(lowerhex[Int(v >> 4)])
        out.unicodeScalars.append(lowerhex[Int(v & 0xF)])
      } else if v < 0x10000 {
        out += "\\u"
        for s in stride(from: 12, through: 0, by: -4) {
          out.unicodeScalars.append(lowerhex[Int((v >> UInt32(s)) & 0xF)])
        }
      } else {
        out += "\\U"
        for s in stride(from: 28, through: 0, by: -4) {
          out.unicodeScalars.append(lowerhex[Int((v >> UInt32(s)) & 0xF)])
        }
      }
    }
  }

  private static func bsearch<T: Comparable>(_ s: [T], _ v: T) -> (Int, Bool) {
    var i = 0
    var j = s.count
    while i < j {
      let h = i + (j - i) >> 1
      if s[h] < v {
        i = h + 1
      } else {
        j = h
      }
    }
    return (i, i < s.count && s[i] == v)
  }

  /// `strconv.IsPrint`: letters, marks, numbers, punctuation, symbols and the ASCII space.
  package static func isPrint(_ scalar: Unicode.Scalar) -> Bool {
    let r = scalar.value
    if r <= 0xFF {
      if 0x20 <= r && r <= 0x7E {
        return true
      }
      if 0xA1 <= r && r <= 0xFF {
        return r != 0xAD
      }
      return false
    }
    if r < 1 << 16 {
      let rr = UInt16(r)
      let table = GoIsPrintTables.isPrint16
      let (i, _) = bsearch(table, rr)
      if i >= table.count || rr < table[i & ~1] || table[i | 1] < rr {
        return false
      }
      let (_, found) = bsearch(GoIsPrintTables.isNotPrint16, rr)
      return !found
    }
    let table = GoIsPrintTables.isPrint32
    let (i, _) = bsearch(table, r)
    if i >= table.count || r < table[i & ~1] || table[i | 1] < r {
      return false
    }
    if r >= 0x20000 {
      return true
    }
    let (_, found) = bsearch(GoIsPrintTables.isNotPrint32, UInt16(r - 0x10000))
    return !found
  }

  /// `strconv.FormatFloat(f, 'g', -1, 64)`, which is also what Go's `%v` prints for a float64.
  package static func formatFloat(_ f: Double) -> String {
    if f.isNaN {
      return "NaN"
    }
    if f.isInfinite {
      return f < 0 ? "-Inf" : "+Inf"
    }
    let (digits, dp) = shortestDigits(Swift.abs(f))
    var out: [UInt8] = f.sign == .minus ? [UInt8(ascii: "-")] : []
    let nd = digits.count
    // %e is used if the exponent is less than -4 or greater than or equal to the precision; for the
    // shortest representation Go uses 6 as the precision for this decision.
    let exp = dp - 1
    if exp < -4 || exp >= 6 {
      out.append(nd > 0 ? digits[0] : UInt8(ascii: "0"))
      if nd > 1 {
        out.append(UInt8(ascii: "."))
        out.append(contentsOf: digits[1...])
      }
      out.append(UInt8(ascii: "e"))
      var e = nd == 0 ? 0 : exp
      if e < 0 {
        out.append(UInt8(ascii: "-"))
        e = -e
      } else {
        out.append(UInt8(ascii: "+"))
      }
      if e < 10 {
        out.append(UInt8(ascii: "0"))
      }
      out.append(contentsOf: Array(String(e).utf8))
      return String(decoding: out, as: UTF8.self)
    }
    // %f with max(nd - dp, 0) fraction digits.
    if dp > 0 {
      for i in 0..<dp {
        out.append(i < nd ? digits[i] : UInt8(ascii: "0"))
      }
    } else {
      out.append(UInt8(ascii: "0"))
    }
    let frac = Swift.max(nd - dp, 0)
    if frac > 0 {
      out.append(UInt8(ascii: "."))
      for i in 0..<frac {
        let j = dp + i
        out.append(j >= 0 && j < nd ? digits[j] : UInt8(ascii: "0"))
      }
    }
    return String(decoding: out, as: UTF8.self)
  }

  /// The shortest ASCII decimal digits that round-trip `f` (>= 0) and the decimal point position: the
  /// value is `0.d1d2...dn * 10^dp`. Zero yields no digits and `dp == 0`.
  package static func shortestDigits(_ f: Double) -> ([UInt8], Int) {
    if f == 0 {
      return ([], 0)
    }
    // Swift's description prints the shortest round-tripping digits, like Go's strconv.
    let text = Array(f.description.utf8)
    var digits: [UInt8] = []
    var dp = 0
    var seenPoint = false
    var exponent = 0
    var i = 0
    while i < text.count {
      let ch = text[i]
      if ch == UInt8(ascii: "e") || ch == UInt8(ascii: "E") {
        exponent = Int(String(decoding: text[(i + 1)...], as: UTF8.self)) ?? 0
        break
      }
      if ch == UInt8(ascii: ".") {
        seenPoint = true
      } else if ch >= UInt8(ascii: "0") && ch <= UInt8(ascii: "9") {
        digits.append(ch)
        if !seenPoint {
          dp += 1
        }
      }
      i += 1
    }
    while let first = digits.first, first == UInt8(ascii: "0") {
      digits.removeFirst()
      dp -= 1
    }
    while let last = digits.last, last == UInt8(ascii: "0") {
      digits.removeLast()
    }
    return (digits, dp + exponent)
  }
}
