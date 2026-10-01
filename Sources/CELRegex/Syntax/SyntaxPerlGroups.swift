// Copyright 2013 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// Port of Go's regexp/syntax/perl_groups.go (generated there by make_perl_groups.pl).

extension Syntax {
  struct CharGroup {
    var sign: Int
    var `class`: [Rune]
  }

  private static let code1: [Rune] = [  // \d
    0x30, 0x39,
  ]

  private static let code2: [Rune] = [  // \s
    0x9, 0xa,
    0xc, 0xd,
    0x20, 0x20,
  ]

  private static let code3: [Rune] = [  // \w
    0x30, 0x39,
    0x41, 0x5a,
    0x5f, 0x5f,
    0x61, 0x7a,
  ]

  /// perlGroup looks up `\` followed by c (Go's perlGroup map).
  static func perlGroup(_ c: UInt8) -> CharGroup? {
    switch c {
    case UInt8(ascii: "d"): return CharGroup(sign: +1, class: code1)
    case UInt8(ascii: "D"): return CharGroup(sign: -1, class: code1)
    case UInt8(ascii: "s"): return CharGroup(sign: +1, class: code2)
    case UInt8(ascii: "S"): return CharGroup(sign: -1, class: code2)
    case UInt8(ascii: "w"): return CharGroup(sign: +1, class: code3)
    case UInt8(ascii: "W"): return CharGroup(sign: -1, class: code3)
    default: return nil
    }
  }

  private static let code4: [Rune] = [  // [:alnum:]
    0x30, 0x39,
    0x41, 0x5a,
    0x61, 0x7a,
  ]

  private static let code5: [Rune] = [  // [:alpha:]
    0x41, 0x5a,
    0x61, 0x7a,
  ]

  private static let code6: [Rune] = [  // [:ascii:]
    0x0, 0x7f,
  ]

  private static let code7: [Rune] = [  // [:blank:]
    0x9, 0x9,
    0x20, 0x20,
  ]

  private static let code8: [Rune] = [  // [:cntrl:]
    0x0, 0x1f,
    0x7f, 0x7f,
  ]

  private static let code9: [Rune] = [  // [:digit:]
    0x30, 0x39,
  ]

  private static let code10: [Rune] = [  // [:graph:]
    0x21, 0x7e,
  ]

  private static let code11: [Rune] = [  // [:lower:]
    0x61, 0x7a,
  ]

  private static let code12: [Rune] = [  // [:print:]
    0x20, 0x7e,
  ]

  private static let code13: [Rune] = [  // [:punct:]
    0x21, 0x2f,
    0x3a, 0x40,
    0x5b, 0x60,
    0x7b, 0x7e,
  ]

  private static let code14: [Rune] = [  // [:space:]
    0x9, 0xd,
    0x20, 0x20,
  ]

  private static let code15: [Rune] = [  // [:upper:]
    0x41, 0x5a,
  ]

  private static let code16: [Rune] = [  // [:word:]
    0x30, 0x39,
    0x41, 0x5a,
    0x5f, 0x5f,
    0x61, 0x7a,
  ]

  private static let code17: [Rune] = [  // [:xdigit:]
    0x30, 0x39,
    0x41, 0x46,
    0x61, 0x66,
  ]

  private static let posixGroups: [String: CharGroup] = [
    "[:alnum:]": CharGroup(sign: +1, class: code4),
    "[:^alnum:]": CharGroup(sign: -1, class: code4),
    "[:alpha:]": CharGroup(sign: +1, class: code5),
    "[:^alpha:]": CharGroup(sign: -1, class: code5),
    "[:ascii:]": CharGroup(sign: +1, class: code6),
    "[:^ascii:]": CharGroup(sign: -1, class: code6),
    "[:blank:]": CharGroup(sign: +1, class: code7),
    "[:^blank:]": CharGroup(sign: -1, class: code7),
    "[:cntrl:]": CharGroup(sign: +1, class: code8),
    "[:^cntrl:]": CharGroup(sign: -1, class: code8),
    "[:digit:]": CharGroup(sign: +1, class: code9),
    "[:^digit:]": CharGroup(sign: -1, class: code9),
    "[:graph:]": CharGroup(sign: +1, class: code10),
    "[:^graph:]": CharGroup(sign: -1, class: code10),
    "[:lower:]": CharGroup(sign: +1, class: code11),
    "[:^lower:]": CharGroup(sign: -1, class: code11),
    "[:print:]": CharGroup(sign: +1, class: code12),
    "[:^print:]": CharGroup(sign: -1, class: code12),
    "[:punct:]": CharGroup(sign: +1, class: code13),
    "[:^punct:]": CharGroup(sign: -1, class: code13),
    "[:space:]": CharGroup(sign: +1, class: code14),
    "[:^space:]": CharGroup(sign: -1, class: code14),
    "[:upper:]": CharGroup(sign: +1, class: code15),
    "[:^upper:]": CharGroup(sign: -1, class: code15),
    "[:word:]": CharGroup(sign: +1, class: code16),
    "[:^word:]": CharGroup(sign: -1, class: code16),
    "[:xdigit:]": CharGroup(sign: +1, class: code17),
    "[:^xdigit:]": CharGroup(sign: -1, class: code17),
  ]

  /// posixGroup looks up a POSIX class name like `[:alnum:]` (Go's posixGroup map).
  static func posixGroup(_ name: ArraySlice<UInt8>) -> CharGroup? {
    // All keys are ASCII; a name with other bytes cannot match.
    guard name.allSatisfy({ $0 < 0x80 }) else { return nil }
    return posixGroups[GoUTF8.string(name)]
  }
}
