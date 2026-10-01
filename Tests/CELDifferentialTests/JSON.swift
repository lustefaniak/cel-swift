// A small JSON value with a parser and a deterministic serializer, for the oracle's JSON lines protocol.
//
// Numbers keep their source text so 64-bit integers and doubles survive unchanged; object keys keep their
// order, and the serializer writes them in that order, so a request renders to the same line every time.

enum JSON: Hashable, Sendable {
  case null
  case bool(Bool)
  case number(String)
  case string(String)
  case array([JSON])
  case object([(String, JSON)])

  static func == (lhs: JSON, rhs: JSON) -> Bool {
    switch (lhs, rhs) {
    case (.null, .null): return true
    case (.bool(let a), .bool(let b)): return a == b
    case (.number(let a), .number(let b)): return a == b
    case (.string(let a), .string(let b)): return a == b
    case (.array(let a), .array(let b)): return a == b
    case (.object(let a), .object(let b)):
      return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    default: return false
    }
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(rendered)
  }

  subscript(key: String) -> JSON? {
    if case .object(let fields) = self {
      return fields.first { $0.0 == key }?.1
    }
    return nil
  }

  var stringValue: String? {
    if case .string(let s) = self { return s }
    return nil
  }

  var arrayValue: [JSON]? {
    if case .array(let a) = self { return a }
    return nil
  }

  var objectValue: [(String, JSON)]? {
    if case .object(let o) = self { return o }
    return nil
  }

  var boolValue: Bool? {
    if case .bool(let b) = self { return b }
    return nil
  }

  var uint64Value: UInt64? {
    switch self {
    case .number(let n): return UInt64(n)
    case .string(let s): return UInt64(s)
    default: return nil
    }
  }

  /// A copy with `key` set (replacing an existing field in place, or appended).
  func setting(_ key: String, _ value: JSON?) -> JSON {
    guard case .object(var fields) = self else { return self }
    if let i = fields.firstIndex(where: { $0.0 == key }) {
      if let value {
        fields[i].1 = value
      } else {
        fields.remove(at: i)
      }
    } else if let value {
      fields.append((key, value))
    }
    return .object(fields)
  }

  // MARK: Serialization

  var rendered: String {
    var out = ""
    render(into: &out)
    return out
  }

  func render(into out: inout String) {
    switch self {
    case .null: out += "null"
    case .bool(let b): out += b ? "true" : "false"
    case .number(let n): out += n
    case .string(let s): JSON.renderString(s, into: &out)
    case .array(let items):
      out += "["
      for (i, item) in items.enumerated() {
        if i > 0 { out += "," }
        item.render(into: &out)
      }
      out += "]"
    case .object(let fields):
      out += "{"
      for (i, (key, value)) in fields.enumerated() {
        if i > 0 { out += "," }
        JSON.renderString(key, into: &out)
        out += ":"
        value.render(into: &out)
      }
      out += "}"
    }
  }

  static func renderString(_ s: String, into out: inout String) {
    out += "\""
    for scalar in s.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      default:
        if scalar.value < 0x20 || scalar.value == 0x7f || (0x2028...0x2029).contains(scalar.value) {
          out += "\\u" + hex4(scalar.value)
        } else {
          out.unicodeScalars.append(scalar)
        }
      }
    }
    out += "\""
  }

  static func hex4(_ v: UInt32) -> String {
    let s = String(v, radix: 16)
    return String(repeating: "0", count: max(0, 4 - s.count)) + s
  }

  // MARK: Parsing

  struct ParseError: Error, CustomStringConvertible {
    var description: String
  }

  static func parse(_ text: String) throws -> JSON {
    var parser = Parser(Array(text.utf8))
    let value = try parser.value()
    parser.skipSpace()
    if parser.pos != parser.bytes.count {
      throw ParseError(description: "trailing characters at \(parser.pos)")
    }
    return value
  }

  struct Parser {
    let bytes: [UInt8]
    var pos = 0

    init(_ bytes: [UInt8]) {
      self.bytes = bytes
    }

    mutating func skipSpace() {
      while pos < bytes.count, [0x20, 0x09, 0x0a, 0x0d].contains(bytes[pos]) {
        pos += 1
      }
    }

    mutating func expect(_ literal: String) throws {
      for b in literal.utf8 {
        guard pos < bytes.count, bytes[pos] == b else {
          throw ParseError(description: "expected \(literal) at \(pos)")
        }
        pos += 1
      }
    }

    mutating func value() throws -> JSON {
      skipSpace()
      guard pos < bytes.count else { throw ParseError(description: "unexpected end") }
      switch bytes[pos] {
      case UInt8(ascii: "n"):
        try expect("null")
        return .null
      case UInt8(ascii: "t"):
        try expect("true")
        return .bool(true)
      case UInt8(ascii: "f"):
        try expect("false")
        return .bool(false)
      case UInt8(ascii: "\""):
        return .string(try string())
      case UInt8(ascii: "["):
        pos += 1
        var items: [JSON] = []
        skipSpace()
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "]") {
          pos += 1
          return .array(items)
        }
        while true {
          items.append(try value())
          skipSpace()
          guard pos < bytes.count else { throw ParseError(description: "unterminated array") }
          if bytes[pos] == UInt8(ascii: ",") {
            pos += 1
          } else if bytes[pos] == UInt8(ascii: "]") {
            pos += 1
            return .array(items)
          } else {
            throw ParseError(description: "expected , or ] at \(pos)")
          }
        }
      case UInt8(ascii: "{"):
        pos += 1
        var fields: [(String, JSON)] = []
        skipSpace()
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "}") {
          pos += 1
          return .object(fields)
        }
        while true {
          skipSpace()
          let key = try string()
          skipSpace()
          try expect(":")
          fields.append((key, try value()))
          skipSpace()
          guard pos < bytes.count else { throw ParseError(description: "unterminated object") }
          if bytes[pos] == UInt8(ascii: ",") {
            pos += 1
          } else if bytes[pos] == UInt8(ascii: "}") {
            pos += 1
            return .object(fields)
          } else {
            throw ParseError(description: "expected , or } at \(pos)")
          }
        }
      default:
        let start = pos
        while pos < bytes.count, "+-0123456789.eE".utf8.contains(bytes[pos]) {
          pos += 1
        }
        guard pos > start else { throw ParseError(description: "unexpected byte at \(pos)") }
        return .number(String(decoding: bytes[start..<pos], as: UTF8.self))
      }
    }

    mutating func string() throws -> String {
      try expect("\"")
      var scalars = String.UnicodeScalarView()
      var raw: [UInt8] = []
      func flush() {
        if !raw.isEmpty {
          scalars.append(contentsOf: String(decoding: raw, as: UTF8.self).unicodeScalars)
          raw.removeAll()
        }
      }
      while true {
        guard pos < bytes.count else { throw ParseError(description: "unterminated string") }
        let b = bytes[pos]
        pos += 1
        if b == UInt8(ascii: "\"") {
          flush()
          return String(scalars)
        }
        if b != UInt8(ascii: "\\") {
          raw.append(b)
          continue
        }
        flush()
        guard pos < bytes.count else { throw ParseError(description: "bad escape") }
        let e = bytes[pos]
        pos += 1
        switch e {
        case UInt8(ascii: "n"): scalars.append("\n")
        case UInt8(ascii: "t"): scalars.append("\t")
        case UInt8(ascii: "r"): scalars.append("\r")
        case UInt8(ascii: "b"): scalars.append("\u{08}")
        case UInt8(ascii: "f"): scalars.append("\u{0c}")
        case UInt8(ascii: "u"):
          var code = try hex4()
          if (0xD800...0xDBFF).contains(code), pos + 1 < bytes.count, bytes[pos] == UInt8(ascii: "\\"),
            bytes[pos + 1] == UInt8(ascii: "u")
          {
            pos += 2
            let low = try hex4()
            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
          }
          scalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
        default: scalars.append(Unicode.Scalar(e))
        }
      }
    }

    mutating func hex4() throws -> UInt32 {
      guard pos + 4 <= bytes.count,
        let v = UInt32(String(decoding: bytes[pos..<pos + 4], as: UTF8.self), radix: 16)
      else {
        throw ParseError(description: "bad \\u escape at \(pos)")
      }
      pos += 4
      return v
    }
  }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral {
  init(stringLiteral value: String) { self = .string(value) }
  init(booleanLiteral value: Bool) { self = .bool(value) }
}
