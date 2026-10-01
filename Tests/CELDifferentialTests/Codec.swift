// Conversions between the oracle's typed JSON (tools/oracle/README.md § Value encoding), cel-swift values and
// types, and the canonical text both sides' results are compared in.

import CEL
import Foundation

/// The types the generator works with.
indirect enum GType: Hashable, Sendable, CustomStringConvertible {
  case int, uint, double, string, bytes, bool, null, duration, timestamp, dyn
  case list(GType)
  case map(GType, GType)
  case optional(GType)
  /// A protobuf message, by full name (see `Messages`).
  case message(String)

  var celType: CELType {
    switch self {
    case .int: return .int
    case .uint: return .uint
    case .double: return .double
    case .string: return .string
    case .bytes: return .bytes
    case .bool: return .bool
    case .null: return .null
    case .duration: return .duration
    case .timestamp: return .timestamp
    case .dyn: return .dyn
    case .list(let e): return .list(e.celType)
    case .map(let k, let v): return .map(key: k.celType, value: v.celType)
    case .optional(let e): return .optional(e.celType)
    case .message(let name): return .object(name)
    }
  }

  /// cel-go's env config `TypeDesc`.
  var typeDesc: JSON {
    func desc(_ name: String, _ params: [GType] = []) -> JSON {
      params.isEmpty
        ? .object([("type_name", .string(name))])
        : .object([("type_name", .string(name)), ("params", .array(params.map(\.typeDesc)))])
    }
    switch self {
    case .int: return desc("int")
    case .uint: return desc("uint")
    case .double: return desc("double")
    case .string: return desc("string")
    case .bytes: return desc("bytes")
    case .bool: return desc("bool")
    case .null: return desc("null_type")
    case .duration: return desc("google.protobuf.Duration")
    case .timestamp: return desc("google.protobuf.Timestamp")
    case .dyn: return desc("dyn")
    case .list(let e): return desc("list", [e])
    case .map(let k, let v): return desc("map", [k, v])
    case .optional(let e): return desc("optional_type", [e])
    case .message(let name): return desc(name)
    }
  }

  init?(typeDesc: JSON) {
    guard let name = typeDesc["type_name"]?.stringValue else { return nil }
    let params = (typeDesc["params"]?.arrayValue ?? []).compactMap(GType.init(typeDesc:))
    switch (name, params.count) {
    case ("int", 0): self = .int
    case ("uint", 0): self = .uint
    case ("double", 0): self = .double
    case ("string", 0): self = .string
    case ("bytes", 0): self = .bytes
    case ("bool", 0): self = .bool
    case ("null_type", 0): self = .null
    case ("google.protobuf.Duration", 0): self = .duration
    case ("google.protobuf.Timestamp", 0): self = .timestamp
    case ("dyn", 0): self = .dyn
    case ("list", 1): self = .list(params[0])
    case ("map", 2): self = .map(params[0], params[1])
    case ("optional_type", 1): self = .optional(params[0])
    case (let name, 0) where name.contains("."): self = .message(name)
    default: return nil
    }
  }

  var description: String { celType.description }

  var isOrderable: Bool {
    switch self {
    case .int, .uint, .double, .string, .bytes, .bool, .duration, .timestamp: return true
    default: return false
    }
  }

  var isMapKey: Bool {
    switch self {
    case .int, .uint, .string, .bool: return true
    default: return false
    }
  }
}

/// A generated binding value.
indirect enum GValue: Sendable {
  case null
  case bool(Bool)
  case int(Int64)
  case uint(UInt64)
  case double(Double)
  case string(String)
  case bytes([UInt8])
  case duration(Int64)
  case timestamp(seconds: Int64, nanos: Int32)
  case list([GValue])
  case map([(GValue, GValue)])
  case optional(GValue?)
  /// A message by full name, with the fields that are set.
  case message(String, [(String, GValue)])

  /// The oracle's typed JSON.
  var json: JSON {
    switch self {
    case .null: return .object([("null", .null)])
    case .bool(let b): return .object([("bool", .bool(b))])
    case .int(let i): return .object([("int", .string(String(i)))])
    case .uint(let u): return .object([("uint", .string(String(u)))])
    case .double(let d): return .object([("double", Codec.encodeDouble(d))])
    case .string(let s): return .object([("string", .string(s))])
    case .bytes(let b): return .object([("bytes", .string(Data(b).base64EncodedString()))])
    case .duration(let n): return .object([("duration", .string(Codec.formatDuration(n)))])
    case .timestamp(let s, let n): return .object([("timestamp", .string(Codec.formatTimestamp(s, n)))])
    case .list(let items): return .object([("list", .array(items.map(\.json)))])
    case .map(let entries):
      return .object([
        ("map", .array(entries.map { .object([("key", $0.0.json), ("value", $0.1.json)]) }))
      ])
    case .optional(let v): return .object([("optional", v?.json ?? .null)])
    case .message(let name, _):
      return .object([("message", .object([("type", .string(name)), ("value", Messages.protoJSON(self))]))])
    }
  }
}

struct CodecError: Error, CustomStringConvertible {
  var description: String
}

enum Codec {
  static func encodeDouble(_ d: Double) -> JSON {
    if d.isNaN { return .string("NaN") }
    if d == .infinity { return .string("Infinity") }
    if d == -.infinity { return .string("-Infinity") }
    if d == 0 && d.sign == .minus { return .string("-0") }
    return .number("\(d)")
  }

  static func decodeDouble(_ j: JSON) -> Double? {
    switch j {
    case .number(let n): return Double(n)
    case .string("NaN"): return .nan
    case .string("Infinity"): return .infinity
    case .string("-Infinity"): return -.infinity
    case .string("-0"): return -0.0
    case .string(let s): return Double(s)
    default: return nil
    }
  }

  static func formatDuration(_ nanos: Int64) -> String {
    let negative = nanos < 0
    let magnitude = nanos.magnitude
    let secs = magnitude / 1_000_000_000
    let frac = magnitude % 1_000_000_000
    var s = negative ? "-" : ""
    s += String(secs)
    if frac != 0 {
      let digits = String(frac)
      s += "." + String(repeating: "0", count: 9 - digits.count) + digits
    }
    return s + "s"
  }

  /// Parses protobuf JSON durations such as `-1.000000001s` into nanoseconds.
  static func parseDuration(_ text: String) -> Int64? {
    guard text.hasSuffix("s") else { return nil }
    var body = Substring(text.dropLast())
    var negative = false
    if body.hasPrefix("-") {
      negative = true
      body = body.dropFirst()
    }
    let parts = body.split(separator: ".", omittingEmptySubsequences: false)
    guard let secs = Int64(parts[0]) else { return nil }
    var nanos: Int64 = 0
    if parts.count == 2 {
      let frac = String(parts[1].prefix(9))
      guard let f = Int64(frac) else { return nil }
      nanos = f
      for _ in frac.count..<9 { nanos *= 10 }
    }
    let total = secs.multipliedReportingOverflow(by: 1_000_000_000)
    guard !total.overflow else { return nil }
    // Negative durations are summed below zero so that -9223372036.854775808s (Int64.min) fits.
    let (sum, overflow) =
      negative
      ? (-total.partialValue).subtractingReportingOverflow(nanos) : total.partialValue.addingReportingOverflow(nanos)
    return overflow ? nil : sum
  }

  static func daysFromCivil(_ y0: Int64, _ m: Int64, _ d: Int64) -> Int64 {
    let y = m <= 2 ? y0 - 1 : y0
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let mp = (m + 9) % 12
    let doy = (153 * mp + 2) / 5 + d - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146_097 + doe - 719_468
  }

  static func civilFromDays(_ z0: Int64) -> (Int64, Int64, Int64) {
    let z = z0 + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
    let y = yoe + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = mp < 10 ? mp + 3 : mp - 9
    return (m <= 2 ? y + 1 : y, m, d)
  }

  static func pad(_ v: Int64, _ width: Int) -> String {
    let s = String(v)
    return String(repeating: "0", count: max(0, width - s.count)) + s
  }

  static func formatTimestamp(_ seconds: Int64, _ nanos: Int32) -> String {
    let days = seconds >= 0 ? seconds / 86400 : (seconds - 86399) / 86400
    let rem = seconds - days * 86400
    let (y, m, d) = civilFromDays(days)
    var s = "\(pad(y, 4))-\(pad(m, 2))-\(pad(d, 2))T\(pad(rem / 3600, 2)):\(pad(rem / 60 % 60, 2)):\(pad(rem % 60, 2))"
    if nanos != 0 {
      s += "." + pad(Int64(nanos), 9)
    }
    return s + "Z"
  }

  /// Parses RFC 3339 into Unix seconds and nanoseconds.
  static func parseTimestamp(_ text: String) -> (Int64, Int32)? {
    let b = Array(text.utf8)
    func num(_ from: Int, _ count: Int) -> Int64? {
      guard from + count <= b.count else { return nil }
      return Int64(String(decoding: b[from..<from + count], as: UTF8.self))
    }
    guard b.count >= 20, let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2), let h = num(11, 2),
      let mi = num(14, 2), let s = num(17, 2)
    else { return nil }
    var pos = 19
    var nanos: Int64 = 0
    if pos < b.count, b[pos] == UInt8(ascii: ".") {
      pos += 1
      var digits = 0
      while pos < b.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b[pos]) {
        if digits < 9 {
          nanos = nanos * 10 + Int64(b[pos] - UInt8(ascii: "0"))
          digits += 1
        }
        pos += 1
      }
      for _ in digits..<9 { nanos *= 10 }
    }
    var offset: Int64 = 0
    guard pos < b.count else { return nil }
    if b[pos] == UInt8(ascii: "Z") {
      pos += 1
    } else {
      let sign: Int64 = b[pos] == UInt8(ascii: "-") ? -1 : 1
      guard let oh = num(pos + 1, 2), let om = num(pos + 4, 2) else { return nil }
      offset = sign * (oh * 3600 + om * 60)
      pos += 6
    }
    guard pos == b.count else { return nil }
    let secs = daysFromCivil(y, mo, d) * 86400 + h * 3600 + mi * 60 + s - offset
    return (secs, Int32(nanos))
  }

  // MARK: JSON -> cel-swift

  static func value(_ j: JSON) throws -> Value {
    guard let fields = j.objectValue, fields.count == 1 else {
      throw CodecError(description: "bad value \(j.rendered)")
    }
    let (kind, payload) = fields[0]
    switch kind {
    case "null": return .null
    case "bool":
      guard let b = payload.boolValue else { break }
      return .bool(b)
    case "int":
      if let s = payload.stringValue, let i = Int64(s) { return .int(i) }
      if case .number(let n) = payload, let i = Int64(n) { return .int(i) }
    case "uint":
      if let u = payload.uint64Value { return .uint(u) }
    case "double":
      if let d = decodeDouble(payload) { return .double(d) }
    case "string":
      if let s = payload.stringValue { return .string(s) }
    case "bytes":
      if let s = payload.stringValue, let data = Data(base64Encoded: s) { return .bytes(Array(data)) }
    case "duration":
      if let s = payload.stringValue, let n = parseDuration(s) { return .duration(CELDuration(nanoseconds: n)) }
    case "timestamp":
      if let s = payload.stringValue, let (sec, n) = parseTimestamp(s) {
        return .timestamp(CELTimestamp(secondsSinceEpoch: sec, nanoseconds: Int64(n)))
      }
    case "optional":
      if payload == .null { return .optional(nil) }
      return .optional(try value(payload))
    case "message":
      return try Messages.value(payload)
    case "list":
      if let items = payload.arrayValue { return .list(ArrayList(try items.map(value))) }
    case "map":
      if let entries = payload.arrayValue {
        var map = OrderedMap()
        for entry in entries {
          guard let k = entry["key"], let v = entry["value"], let key = MapKey(try value(k)) else {
            throw CodecError(description: "bad map entry \(entry.rendered)")
          }
          _ = map.insert(try value(v), forKey: key)
        }
        return .map(map)
      }
    default: break
    }
    throw CodecError(description: "bad value \(j.rendered)")
  }

  static func celType(_ desc: JSON) throws -> CELType {
    guard let t = GType(typeDesc: desc) else { throw CodecError(description: "unsupported type \(desc.rendered)") }
    return t.celType
  }

  // MARK: Canonical text

  static func quote(_ s: String) -> String {
    var out = ""
    JSON.renderString(s, into: &out)
    return out
  }

  static func hex(_ bytes: [UInt8]) -> String {
    let digits = Array("0123456789abcdef")
    return String(bytes.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 15)]] })
  }

  /// Doubles by their shortest round-trip text; every NaN is the same.
  static func canonicalDouble(_ d: Double) -> String {
    d.isNaN ? "nan" : "\(d)"
  }

  /// Canonical text of an oracle result value.
  static func canonical(json j: JSON) -> String {
    guard let fields = j.objectValue, fields.count == 1 else { return "?\(j.rendered)" }
    let (kind, p) = fields[0]
    switch kind {
    case "null": return "null"
    case "bool": return "bool:\(p.boolValue.map(String.init) ?? "?")"
    case "int": return "int:\(p.stringValue ?? p.rendered)"
    case "uint": return "uint:\(p.stringValue ?? p.rendered)"
    case "double": return "double:\(decodeDouble(p).map(canonicalDouble) ?? p.rendered)"
    case "string": return "string:" + quote(p.stringValue ?? "")
    case "bytes": return "bytes:" + hex(Array(Data(base64Encoded: p.stringValue ?? "") ?? Data()))
    case "duration": return "duration:\(parseDuration(p.stringValue ?? "").map(String.init) ?? p.rendered)"
    case "timestamp":
      if let (s, n) = parseTimestamp(p.stringValue ?? "") { return "timestamp:\(s).\(pad(Int64(n), 9))" }
      return "timestamp:?\(p.rendered)"
    case "type": return "type:\(p.stringValue ?? "?")"
    case "optional": return p == .null ? "optional.none" : "optional(\(canonical(json: p)))"
    case "list": return "[" + (p.arrayValue ?? []).map { canonical(json: $0) }.joined(separator: ", ") + "]"
    case "map":
      let entries = (p.arrayValue ?? []).map {
        canonical(json: $0["key"] ?? .null) + ": " + canonical(json: $0["value"] ?? .null)
      }
      return "{" + entries.sorted().joined(separator: ", ") + "}"
    case "message": return Messages.canonical(json: p)
    default: return "?\(j.rendered)"
    }
  }

  /// Canonical text of a cel-swift value, in the same form as ``canonical(json:)``.
  static func canonical(_ v: Value) -> String {
    switch v {
    case .null: return "null"
    case .bool(let b): return "bool:\(b)"
    case .int(let i): return "int:\(i)"
    case .uint(let u): return "uint:\(u)"
    case .double(let d): return "double:\(canonicalDouble(d))"
    case .string(let s): return "string:" + quote(s)
    case .bytes(let b): return "bytes:" + hex(b)
    case .duration(let d): return "duration:\(d.nanoseconds)"
    case .timestamp(let t): return "timestamp:\(t.secondsSinceEpoch).\(pad(Int64(t.nanoseconds), 9))"
    case .type(let t): return "type:\(t.runtimeTypeName)"
    case .optional(let o): return o.map { "optional(\(canonical($0)))" } ?? "optional.none"
    case .list(let l): return "[" + l.elements.map(canonical).joined(separator: ", ") + "]"
    case .map:
      var entries: [String] = []
      for (k, value) in (v.asMap ?? [:]) {
        entries.append(canonical(k.value) + ": " + canonical(value))
      }
      return "{" + entries.sorted().joined(separator: ", ") + "}"
    case .object(let o): return Messages.canonical(o)
    case .error(let e): return "error:\(e.message)"
    case .unknown(let u): return "unknown:" + u.exprIDs.sorted().map(String.init).joined(separator: ",")
    }
  }
}
