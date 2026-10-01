// Copyright 2018 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Ported from cel-go parser/unescape.go. Works on UTF-8 bytes, like the Go original, so that bytes
// literals can hold arbitrary octets.

/// The error raised by `unescape`; its message is reported verbatim by the parser.
struct UnescapeError: Error, Equatable {
  let message: String
}

/// Takes a quoted string literal (optionally `r`/`R` prefixed), unquotes and unescapes it.
///
/// Escaping is compatible with GoogleSQL. For bytes literals, octal and hex escapes denote byte
/// values rather than code points.
func unescape(_ text: String, isBytes: Bool) throws(UnescapeError) -> [UInt8] {
  // All strings normalize newlines to the \n representation.
  var value = normalizeNewlines(Array(text.utf8))
  var n = value.count

  // Nothing to unescape / decode.
  if n < 2 {
    throw UnescapeError(message: "unable to unescape string")
  }

  // Raw string preceded by the 'r|R' prefix.
  var isRawLiteral = false
  if value[0] == UInt8(ascii: "r") || value[0] == UInt8(ascii: "R") {
    value.removeFirst()
    n = value.count
    isRawLiteral = true
  }

  // Quoted string of some form, must have same first and last char.
  if n == 0 || value[0] != value[n - 1]
    || (value[0] != UInt8(ascii: "\"") && value[0] != UInt8(ascii: "'"))
  {
    throw UnescapeError(message: "unable to unescape string")
  }

  // Normalize the multi-line CEL string representation to a standard quoted string.
  if n >= 6 {
    let sq: [UInt8] = Array("'''".utf8)
    let dq: [UInt8] = Array("\"\"\"".utf8)
    if Array(value[0..<3]) == sq {
      if Array(value[(n - 3)...]) != sq {
        throw UnescapeError(message: "unable to unescape string")
      }
      value = [UInt8(ascii: "\"")] + Array(value[3..<(n - 3)]) + [UInt8(ascii: "\"")]
    } else if Array(value[0..<3]) == dq {
      if Array(value[(n - 3)...]) != dq {
        throw UnescapeError(message: "unable to unescape string")
      }
      value = [UInt8(ascii: "\"")] + Array(value[3..<(n - 3)]) + [UInt8(ascii: "\"")]
    }
    n = value.count
  }
  var s = value[1..<(n - 1)]
  // If there is nothing to escape, then return.
  if isRawLiteral || !s.contains(UInt8(ascii: "\\")) {
    return Array(s)
  }

  // Otherwise the string contains escape characters.
  var buf: [UInt8] = []
  buf.reserveCapacity(3 * n / 2)
  while !s.isEmpty {
    let (c, encode, rest) = try unescapeChar(s, isBytes: isBytes)
    s = rest
    if c < 0x80 || !encode {
      buf.append(UInt8(truncatingIfNeeded: c))
    } else if let scalar = Unicode.Scalar(c) {
      buf.append(contentsOf: Array(String(scalar).utf8))
    } else {
      buf.append(contentsOf: [0xEF, 0xBF, 0xBD])
    }
  }
  return buf
}

private func normalizeNewlines(_ b: [UInt8]) -> [UInt8] {
  guard b.contains(UInt8(ascii: "\r")) else {
    return b
  }
  var out: [UInt8] = []
  out.reserveCapacity(b.count)
  var i = 0
  while i < b.count {
    if b[i] == UInt8(ascii: "\r") {
      out.append(UInt8(ascii: "\n"))
      if i + 1 < b.count && b[i + 1] == UInt8(ascii: "\n") {
        i += 2
        continue
      }
    } else {
      out.append(b[i])
    }
    i += 1
  }
  return out
}

/// Decodes the escape or character at the front of `s`: returns the value, whether it must be
/// UTF-8 encoded, and the remaining input.
private func unescapeChar(_ s: ArraySlice<UInt8>, isBytes: Bool) throws(UnescapeError) -> (
  UInt32, Bool, ArraySlice<UInt8>
) {
  let c0 = s[s.startIndex]
  // 1. Character is not an escape sequence.
  if c0 >= 0x80 {
    let (scalar, width) = GoFormat.decodeRune(Array(s.prefix(4)), 0)
    return (scalar?.value ?? 0xFFFD, true, s.dropFirst(width))
  }
  if c0 != UInt8(ascii: "\\") {
    return (UInt32(c0), false, s.dropFirst())
  }

  // 2. Last character is the start of an escape sequence.
  if s.count <= 1 {
    throw UnescapeError(message: "unable to unescape string, found '\\' as last character")
  }

  let c = s[s.startIndex + 1]
  var rest = s.dropFirst(2)
  var value: UInt32
  var encode = false
  // 3. Common escape sequences shared with Google SQL
  switch c {
  case UInt8(ascii: "a"): value = 0x07
  case UInt8(ascii: "b"): value = 0x08
  case UInt8(ascii: "f"): value = 0x0C
  case UInt8(ascii: "n"): value = 0x0A
  case UInt8(ascii: "r"): value = 0x0D
  case UInt8(ascii: "t"): value = 0x09
  case UInt8(ascii: "v"): value = 0x0B
  case UInt8(ascii: "\\"): value = 0x5C
  case UInt8(ascii: "'"): value = 0x27
  case UInt8(ascii: "\""): value = 0x22
  case UInt8(ascii: "`"): value = 0x60
  case UInt8(ascii: "?"): value = 0x3F

  // 4. Unicode escape sequences, reproduced from `strconv/quote.go`
  case UInt8(ascii: "x"), UInt8(ascii: "X"), UInt8(ascii: "u"), UInt8(ascii: "U"):
    var n = 0
    encode = true
    switch c {
    case UInt8(ascii: "x"), UInt8(ascii: "X"):
      n = 2
      encode = !isBytes
    case UInt8(ascii: "u"):
      n = 4
      if isBytes {
        throw UnescapeError(message: "unable to unescape string")
      }
    default:
      n = 8
      if isBytes {
        throw UnescapeError(message: "unable to unescape string")
      }
    }
    if rest.count < n {
      throw UnescapeError(message: "unable to unescape string")
    }
    var v: UInt32 = 0
    for j in 0..<n {
      guard let x = unhex(rest[rest.startIndex + j]) else {
        throw UnescapeError(message: "unable to unescape string")
      }
      v = v << 4 | x
    }
    rest = rest.dropFirst(n)
    if !isBytes && !isValidRune(v) {
      throw UnescapeError(message: "invalid unicode code point")
    }
    value = v

  // 5. Octal escape sequences, must be three digits \[0-3][0-7][0-7]
  case UInt8(ascii: "0")...UInt8(ascii: "3"):
    if rest.count < 2 {
      throw UnescapeError(message: "unable to unescape octal sequence in string")
    }
    var v = UInt32(c - UInt8(ascii: "0"))
    for j in 0..<2 {
      let x = rest[rest.startIndex + j]
      if x < UInt8(ascii: "0") || x > UInt8(ascii: "7") {
        throw UnescapeError(message: "unable to unescape octal sequence in string")
      }
      v = v * 8 + UInt32(x - UInt8(ascii: "0"))
    }
    if !isBytes && !isValidRune(v) {
      throw UnescapeError(message: "invalid unicode code point")
    }
    value = v
    rest = rest.dropFirst(2)
    encode = !isBytes

  // Unknown escape sequence.
  default:
    throw UnescapeError(message: "unable to unescape string")
  }
  return (value, encode, rest)
}

private func isValidRune(_ v: UInt32) -> Bool {
  v < 0xD800 || (v > 0xDFFF && v <= 0x10FFFF)
}

private func unhex(_ b: UInt8) -> UInt32? {
  switch b {
  case UInt8(ascii: "0")...UInt8(ascii: "9"): return UInt32(b - UInt8(ascii: "0"))
  case UInt8(ascii: "a")...UInt8(ascii: "f"): return UInt32(b - UInt8(ascii: "a") + 10)
  case UInt8(ascii: "A")...UInt8(ascii: "F"): return UInt32(b - UInt8(ascii: "A") + 10)
  default: return nil
  }
}
