// Copyright 2009 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// Port of the parts of Go's unicode package (src/unicode/letter.go, graphic.go, digit.go) that
// regexp and regexp/syntax use. The tables themselves are generated from Go by
// tools/gen-unicode-tables into UnicodeTables.swift, so lookups agree with Go exactly.

/// Accessors over the generated Unicode tables.
enum UnicodeTables {
  /// A table: `count` packed ranges starting at `start` in `ranges`.
  struct TableRef: Sendable, Equatable {
    var start: Int
    var count: Int

    /// The closed ranges of the table, as a flat lo, hi, lo, hi, ... list in increasing order.
    /// Ranges longer than 2048 runes come in abutting chunks.
    func forEachRange(_ body: (Rune, Rune) -> Void) {
      for i in start..<(start + count) {
        let v = UnicodeTables.ranges[i]
        let lo = Rune(v >> 11)
        body(lo, lo + Rune(v & 0x7FF))
      }
    }

    /// Reports whether r is in the table.
    func contains(_ r: Rune) -> Bool {
      let table = UnicodeTables.ranges
      var lo = start
      var hi = start + count
      while lo < hi {
        let m = lo + (hi - lo) / 2
        let v = table[m]
        let rlo = Rune(v >> 11)
        let rhi = rlo + Rune(v & 0x7FF)
        if r < rlo {
          hi = m
        } else if r > rhi {
          lo = m + 1
        } else {
          return true
        }
      }
      return false
    }
  }

  static let maxRune: Rune = 0x10FFFF

  /// Decodes a generated table: 8 lowercase hex digits per value, line breaks ignored.
  static func decodeHex(_ s: String) -> [UInt32] {
    var out: [UInt32] = []
    out.reserveCapacity(s.utf8.count / 8)
    var v: UInt32 = 0
    var digits = 0
    for c in s.utf8 {
      let d: UInt32
      switch c {
      case UInt8(ascii: "0")...UInt8(ascii: "9"): d = UInt32(c - UInt8(ascii: "0"))
      case UInt8(ascii: "a")...UInt8(ascii: "f"): d = UInt32(c - UInt8(ascii: "a") + 10)
      default: continue
      }
      v = v << 4 | d
      digits += 1
      if digits == 8 {
        out.append(v)
        v = 0
        digits = 0
      }
    }
    return out
  }

  /// unicode.Categories["Cn"].
  static var cn: TableRef {
    categories["Cn", default: TableRef(start: 0, count: 0)]
  }

  /// unicode.SimpleFold: iterates over Unicode code points equivalent under the Unicode-defined
  /// simple case folding. Among the code points equivalent to r (including r itself), it returns
  /// the smallest that is greater than r if one exists, or else the smallest one.
  static func simpleFold(_ r: Rune) -> Rune {
    if r < 0 || r > maxRune {
      return r
    }
    let pairs = foldPairs
    let target = UInt32(r)
    var lo = 0
    var hi = pairs.count / 2
    while lo < hi {
      let m = lo + (hi - lo) / 2
      let k = pairs[2 * m]
      if k < target {
        lo = m + 1
      } else if k > target {
        hi = m
      } else {
        return Rune(pairs[2 * m + 1])
      }
    }
    return r
  }

  /// unicode.IsPrint.
  static func isPrint(_ r: Rune) -> Bool {
    print.contains(r)
  }

  /// unicode.IsLetter.
  static func isLetter(_ r: Rune) -> Bool {
    if r >= 0, r < 0x80 {
      return (r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A)
    }
    return letter.contains(r)
  }

  /// unicode.IsDigit.
  static func isDigit(_ r: Rune) -> Bool {
    if r >= 0, r < 0x80 {
      return r >= 0x30 && r <= 0x39
    }
    return digit.contains(r)
  }
}
