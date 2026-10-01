// Copyright 2009 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// Port of the parts of Go's unicode/utf8 (src/unicode/utf8/utf8.go) that regexp uses.
// Decoding follows Go exactly: each byte of an invalid sequence decodes as RuneError with width 1.

/// A Unicode code point, or -1 for end of text, as Go's `rune` (int32).
package typealias Rune = Int32

enum GoUTF8 {
  static let runeError: Rune = 0xFFFD
  static let runeSelf: Rune = 0x80
  static let maxRune: Rune = 0x10FFFF
  static let utfMax = 4

  private static let surrogateMin: Rune = 0xD800
  private static let surrogateMax: Rune = 0xDFFF

  /// DecodeRune unpacks the first UTF-8 encoding in p[pos...] and returns the rune and its width
  /// in bytes. Empty input gives (RuneError, 0); an invalid encoding gives (RuneError, 1).
  @inline(__always)
  static func decodeRune(_ p: UnsafeBufferPointer<UInt8>, at pos: Int) -> (Rune, Int) {
    let n = p.count - pos
    if n < 1 {
      return (runeError, 0)
    }
    let p0 = p[pos]
    if p0 < 0x80 {
      return (Rune(p0), 1)
    }
    return decodeRuneSlow(p, at: pos, n: n, p0: p0)
  }

  private static func decodeRuneSlow(_ p: UnsafeBufferPointer<UInt8>, at pos: Int, n: Int, p0: UInt8)
    -> (Rune, Int)
  {
    // First-byte classification (Go's `first` table and `acceptRanges`).
    let sz: Int
    var lo: UInt8 = 0x80
    var hi: UInt8 = 0xBF
    switch p0 {
    case 0xC2...0xDF:
      sz = 2
    case 0xE0:
      sz = 3
      lo = 0xA0
    case 0xE1...0xEC, 0xEE...0xEF:
      sz = 3
    case 0xED:
      sz = 3
      hi = 0x9F
    case 0xF0:
      sz = 4
      lo = 0x90
    case 0xF1...0xF3:
      sz = 4
    case 0xF4:
      sz = 4
      hi = 0x8F
    default:
      return (runeError, 1)
    }
    if n < sz {
      return (runeError, 1)
    }
    let b1 = p[pos + 1]
    if b1 < lo || hi < b1 {
      return (runeError, 1)
    }
    if sz == 2 {
      return (Rune(p0 & 0x1F) << 6 | Rune(b1 & 0x3F), 2)
    }
    let b2 = p[pos + 2]
    if b2 < 0x80 || 0xBF < b2 {
      return (runeError, 1)
    }
    if sz == 3 {
      return (Rune(p0 & 0x0F) << 12 | Rune(b1 & 0x3F) << 6 | Rune(b2 & 0x3F), 3)
    }
    let b3 = p[pos + 3]
    if b3 < 0x80 || 0xBF < b3 {
      return (runeError, 1)
    }
    return (Rune(p0 & 0x07) << 18 | Rune(b1 & 0x3F) << 12 | Rune(b2 & 0x3F) << 6 | Rune(b3 & 0x3F), 4)
  }

  /// DecodeLastRune unpacks the last UTF-8 encoding in p[..<end].
  static func decodeLastRune(_ p: UnsafeBufferPointer<UInt8>, end: Int) -> (Rune, Int) {
    if end == 0 {
      return (runeError, 0)
    }
    var start = end - 1
    let r = Rune(p[start])
    if r < runeSelf {
      return (r, 1)
    }
    // guard against O(n^2) behavior when traversing
    // backwards through strings with long sequences of
    // invalid UTF-8.
    let lim = max(end - utfMax, 0)
    start -= 1
    while start >= lim {
      if isRuneStart(p[start]) {
        break
      }
      start -= 1
    }
    if start < 0 {
      start = 0
    }
    let (r2, size) = decodeRune(UnsafeBufferPointer(rebasing: p[start..<end]), at: 0)
    if start + size != end {
      return (runeError, 1)
    }
    return (r2, size)
  }

  @inline(__always)
  static func isRuneStart(_ b: UInt8) -> Bool {
    b & 0xC0 != 0x80
  }

  /// RuneLen returns the number of bytes in the UTF-8 encoding of the rune, or -1 if the rune is
  /// not a valid value to encode in UTF-8.
  static func runeLen(_ r: Rune) -> Int {
    switch r {
    case ..<0: return -1
    case ...0x7F: return 1
    case ...0x7FF: return 2
    case surrogateMin...surrogateMax: return -1
    case ...0xFFFF: return 3
    case ...maxRune: return 4
    default: return -1
    }
  }

  /// AppendRune appends the UTF-8 encoding of r to p; invalid runes encode as RuneError.
  static func appendRune(_ p: inout [UInt8], _ r: Rune) {
    let i = UInt32(bitPattern: r)
    switch i {
    case 0...0x7F:
      p.append(UInt8(i))
    case 0x80...0x7FF:
      p.append(0xC0 | UInt8(i >> 6))
      p.append(0x80 | UInt8(i & 0x3F))
    case 0x800..<0xD800, 0xE000...0xFFFF:
      p.append(0xE0 | UInt8(i >> 12))
      p.append(0x80 | UInt8((i >> 6) & 0x3F))
      p.append(0x80 | UInt8(i & 0x3F))
    case 0x10000...0x10FFFF:
      p.append(0xF0 | UInt8(i >> 18))
      p.append(0x80 | UInt8((i >> 12) & 0x3F))
      p.append(0x80 | UInt8((i >> 6) & 0x3F))
      p.append(0x80 | UInt8(i & 0x3F))
    default:
      p.append(contentsOf: [0xEF, 0xBF, 0xBD])
    }
  }

  /// Decodes a byte array into runes the way Go's `for _, r := range string(b)` does.
  static func runes(_ bytes: [UInt8]) -> [Rune] {
    bytes.withUnsafeBufferPointer { p in
      var out: [Rune] = []
      out.reserveCapacity(p.count)
      var i = 0
      while i < p.count {
        let (r, w) = decodeRune(p, at: i)
        out.append(r)
        i += w
      }
      return out
    }
  }

  /// Encodes runes as UTF-8 bytes (Go's `string([]rune)`).
  static func bytes(_ runes: some Sequence<Rune>) -> [UInt8] {
    var out: [UInt8] = []
    for r in runes {
      appendRune(&out, r)
    }
    return out
  }

  /// Converts UTF-8 bytes to a String, repairing invalid sequences with U+FFFD.
  static func string(_ bytes: some Collection<UInt8>) -> String {
    String(decoding: bytes, as: UTF8.self)
  }

  /// Converts a rune sequence to a String (Go's `string([]rune)`).
  static func string(runes: some Sequence<Rune>) -> String {
    string(bytes(runes))
  }
}
