// Copyright 2009 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.
//
// Ported from Go src/strings/strings.go (Count, Index, LastIndex, Replace, genSplit, explode,
// TrimSpace) and src/unicode (IsSpace), the parts of Go's standard library the string extension
// functions call. Go strings are UTF-8 bytes, so these work on the UTF-8 view; the inputs are valid
// Swift strings, and every cut falls on a character boundary, so results are valid UTF-8 again.

/// Go string operations on UTF-8 bytes.
enum GoStrings {
  /// The width of the UTF-8 sequence starting with `lead` (valid UTF-8 assumed).
  static func runeWidth(_ lead: UInt8) -> Int {
    switch lead {
    case 0..<0x80: 1
    case 0xC0..<0xE0: 2
    case 0xE0..<0xF0: 3
    default: 4
    }
  }

  static func string(_ bytes: ArraySlice<UInt8>) -> String {
    String(decoding: bytes, as: UTF8.self)
  }

  /// The number of runes in `s` (Go `utf8.RuneCount`).
  static func runeCount(_ s: ArraySlice<UInt8>) -> Int {
    var n = 0
    var i = s.startIndex
    while i < s.endIndex {
      i += runeWidth(s[i])
      n += 1
    }
    return n
  }

  /// Go `strings.Index`: the byte offset of the first `sep` in `s`, relative to `s.startIndex`.
  static func index(_ s: ArraySlice<UInt8>, _ sep: [UInt8]) -> Int? {
    if sep.isEmpty {
      return 0
    }
    if sep.count > s.count {
      return nil
    }
    let first = sep[0]
    var i = s.startIndex
    let last = s.endIndex - sep.count
    while i <= last {
      if s[i] == first && s[i..<(i + sep.count)].elementsEqual(sep) {
        return i - s.startIndex
      }
      i += 1
    }
    return nil
  }

  /// Go `strings.Count`: non-overlapping occurrences; `runeCount + 1` for an empty `sep`.
  static func count(_ s: ArraySlice<UInt8>, _ sep: [UInt8]) -> Int {
    if sep.isEmpty {
      return runeCount(s) + 1
    }
    var n = 0
    var rest = s
    while let i = index(rest, sep) {
      n += 1
      rest = rest[(rest.startIndex + i + sep.count)...]
    }
    return n
  }

  /// Go `strings.Replace(s, old, new, n)`; `n < 0` replaces every occurrence.
  static func replace(_ str: String, _ oldStr: String, _ newStr: String, _ limit: Int) -> String {
    let s = Array(str.utf8)
    let old = Array(oldStr.utf8)
    let new = Array(newStr.utf8)
    if old == new || limit == 0 {
      return str
    }
    var n = limit
    let m = count(s[...], old)
    if m == 0 {
      return str
    } else if n < 0 || m < n {
      n = m
    }
    var b: [UInt8] = []
    b.reserveCapacity(max(0, s.count + n * (new.count - old.count)))
    var start = 0
    for i in 0..<n {
      var j = start
      if old.isEmpty {
        if i > 0 {
          j += runeWidth(s[start])
        }
      } else {
        j += index(s[start...], old) ?? 0
      }
      b.append(contentsOf: s[start..<j])
      b.append(contentsOf: new)
      start = j + old.count
    }
    b.append(contentsOf: s[start...])
    return string(b[...])
  }

  /// Go `strings.SplitN(s, sep, n)` (`genSplit` with `sepSave` 0); `n < 0` splits everywhere.
  static func split(_ str: String, _ sepStr: String, _ limit: Int) -> [String] {
    var n = limit
    if n == 0 {
      return []
    }
    var s = Array(str.utf8)[...]
    let sep = Array(sepStr.utf8)
    if sep.isEmpty {
      return explode(s, n)
    }
    if n < 0 {
      n = count(s, sep) + 1
    }
    if n > s.count + 1 {
      n = s.count + 1
    }
    var a: [String] = []
    a.reserveCapacity(n)
    n -= 1
    var i = 0
    while i < n {
      guard let m = index(s, sep) else { break }
      a.append(string(s[s.startIndex..<(s.startIndex + m)]))
      s = s[(s.startIndex + m + sep.count)...]
      i += 1
    }
    a.append(string(s))
    return a
  }

  /// Go `explode`: splits into runes, the last element holding the rest.
  private static func explode(_ s: ArraySlice<UInt8>, _ limit: Int) -> [String] {
    let l = runeCount(s)
    var n = limit
    if n < 0 || n > l {
      n = l
    }
    var a: [String] = []
    a.reserveCapacity(n)
    var rest = s
    var i = 0
    while i < n - 1 {
      let size = runeWidth(rest[rest.startIndex])
      a.append(string(rest[rest.startIndex..<(rest.startIndex + size)]))
      rest = rest[(rest.startIndex + size)...]
      i += 1
    }
    if n > 0 {
      a.append(string(rest))
    }
    return a
  }

  /// Go `unicode.IsSpace`.
  static func isSpace(_ r: Unicode.Scalar) -> Bool {
    switch r.value {
    case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0:
      true
    case 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
      true
    default:
      false
    }
  }

  /// Go `strings.TrimSpace`: strips leading and trailing Unicode white space.
  static func trimSpace(_ s: String) -> String {
    let scalars = Array(s.unicodeScalars)
    var start = 0
    var end = scalars.count
    while start < end && isSpace(scalars[start]) {
      start += 1
    }
    while end > start && isSpace(scalars[end - 1]) {
      end -= 1
    }
    var result = String.UnicodeScalarView()
    result.append(contentsOf: scalars[start..<end])
    return String(result)
  }
}

extension String {
  /// Builds a string from Unicode scalars.
  init<S: Sequence>(scalars: S) where S.Element == Unicode.Scalar {
    var view = String.UnicodeScalarView()
    view.append(contentsOf: scalars)
    self = String(view)
  }
}
