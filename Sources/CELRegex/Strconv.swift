// Copyright 2009 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// Port of the quoting functions of Go's strconv/quote.go (Quote, QuoteToASCII) that regexp uses
// for program dumps and error messages.

enum GoStrconv {
  private static let lowerhex = Array("0123456789abcdef".utf8)

  /// strconv.Quote.
  static func quote(_ s: [UInt8]) -> String {
    quoteWith(s, asciiOnly: false)
  }

  /// strconv.QuoteToASCII.
  static func quoteToASCII(_ s: [UInt8]) -> String {
    quoteWith(s, asciiOnly: true)
  }

  private static func quoteWith(_ s: [UInt8], asciiOnly: Bool) -> String {
    var buf: [UInt8] = [0x22]
    s.withUnsafeBufferPointer { p in
      var i = 0
      while i < p.count {
        let (r, width) = GoUTF8.decodeRune(p, at: i)
        if width == 1 && r == GoUTF8.runeError {
          buf.append(contentsOf: Array(#"\x"#.utf8))
          buf.append(lowerhex[Int(p[i] >> 4)])
          buf.append(lowerhex[Int(p[i] & 0xF)])
          i += width
          continue
        }
        appendEscapedRune(&buf, r, asciiOnly: asciiOnly)
        i += width
      }
    }
    buf.append(0x22)
    return GoUTF8.string(buf)
  }

  private static func appendEscapedRune(_ buf: inout [UInt8], _ r: Rune, asciiOnly: Bool) {
    if r == 0x22 || r == 0x5C {  // always backslashed
      buf.append(0x5C)
      buf.append(UInt8(r))
      return
    }
    if asciiOnly {
      if r < GoUTF8.runeSelf && UnicodeTables.isPrint(r) {
        buf.append(UInt8(r))
        return
      }
    } else if UnicodeTables.isPrint(r) {
      GoUTF8.appendRune(&buf, r)
      return
    }
    switch r {
    case 0x07: buf.append(contentsOf: Array(#"\a"#.utf8))
    case 0x08: buf.append(contentsOf: Array(#"\b"#.utf8))
    case 0x0C: buf.append(contentsOf: Array(#"\f"#.utf8))
    case 0x0A: buf.append(contentsOf: Array(#"\n"#.utf8))
    case 0x0D: buf.append(contentsOf: Array(#"\r"#.utf8))
    case 0x09: buf.append(contentsOf: Array(#"\t"#.utf8))
    case 0x0B: buf.append(contentsOf: Array(#"\v"#.utf8))
    default:
      var r = r
      if r < 0x20 || r == 0x7F {
        buf.append(contentsOf: Array(#"\x"#.utf8))
        buf.append(lowerhex[Int((r >> 4) & 0xF)])
        buf.append(lowerhex[Int(r & 0xF)])
        return
      }
      if GoUTF8.runeLen(r) < 0 {
        r = 0xFFFD
      }
      if r < 0x10000 {
        buf.append(contentsOf: Array(#"\u"#.utf8))
        var s = 12
        while s >= 0 {
          buf.append(lowerhex[Int((r >> Rune(s)) & 0xF)])
          s -= 4
        }
      } else {
        buf.append(contentsOf: Array(#"\U"#.utf8))
        var s = 28
        while s >= 0 {
          buf.append(lowerhex[Int((r >> Rune(s)) & 0xF)])
          s -= 4
        }
      }
    }
  }
}
