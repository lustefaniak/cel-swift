// Protobuf messages in differential cases: the cel-spec conformance TestAllTypes messages (proto2 and
// proto3), which the oracle registers with its `test_types` extension and cel-swift with CELSpecProtos.

import CEL
import CELProtobuf
import CELSpecProtos
import Foundation
import SwiftProtobuf

enum Messages {
  /// The container the `proto` profile compiles in, so `proto3.TestAllTypes` names a message.
  static let container = "cel.expr.conformance"

  static let types = CELSpecProtos.protobufTypes

  /// The messages the generator builds, by full name, with their generated Swift types.
  static let swiftTypes: [(String, any SwiftProtobuf.Message.Type)] = [
    ("cel.expr.conformance.proto3.TestAllTypes", Cel_Expr_Conformance_Proto3_TestAllTypes.self),
    (
      "cel.expr.conformance.proto3.TestAllTypes.NestedMessage",
      Cel_Expr_Conformance_Proto3_TestAllTypes.NestedMessage.self
    ),
    ("cel.expr.conformance.proto3.NestedTestAllTypes", Cel_Expr_Conformance_Proto3_NestedTestAllTypes.self),
    ("cel.expr.conformance.proto2.TestAllTypes", Cel_Expr_Conformance_Proto2_TestAllTypes.self),
    (
      "cel.expr.conformance.proto2.TestAllTypes.NestedMessage",
      Cel_Expr_Conformance_Proto2_TestAllTypes.NestedMessage.self
    ),
    ("cel.expr.conformance.proto2.NestedTestAllTypes", Cel_Expr_Conformance_Proto2_NestedTestAllTypes.self),
  ]

  static func swiftType(_ name: String) -> (any SwiftProtobuf.Message.Type)? {
    swiftTypes.first { $0.0 == name }?.1
  }

  /// A message field the generator reads and writes.
  struct Field: Sendable {
    var name: String
    var type: GType
    /// A `google.protobuf.*Value` wrapper, which also accepts `null`.
    var isWrapper: Bool
  }

  /// The fields of every generated message whose CEL type the generator models.
  static let fields: [String: [Field]] = {
    var out: [String: [Field]] = [:]
    for (name, _) in swiftTypes {
      var list: [Field] = []
      for fieldName in types.findStructFieldNames(name) ?? [] {
        guard let celType = types.findStructFieldType(name, fieldName: fieldName)?.type else { continue }
        var wrapper = false
        var t = celType
        if case .wrapper(let inner) = celType {
          wrapper = true
          t = inner
        }
        guard let g = gType(t) else { continue }
        list.append(Field(name: fieldName, type: g, isWrapper: wrapper))
      }
      out[name] = list
    }
    return out
  }()

  static func gType(_ t: CELType) -> GType? {
    switch t {
    case .int: return .int
    case .uint: return .uint
    case .double: return .double
    case .string: return .string
    case .bytes: return .bytes
    case .bool: return .bool
    case .duration: return .duration
    case .timestamp: return .timestamp
    case .null: return .null
    case .dyn: return .dyn
    case .list(let e): return gType(e).map { .list($0) }
    case .map(let k, let v):
      guard let kk = gType(k), let vv = gType(v) else { return nil }
      return .map(kk, vv)
    case .object(let name): return swiftType(name) == nil ? nil : .message(name)
    default: return nil
    }
  }

  /// The name of a message relative to ``container``.
  static func shortName(_ name: String) -> String {
    name.hasPrefix(container + ".") ? String(name.dropFirst(container.count + 1)) : name
  }

  static let enumConstants: [String] = [
    "proto3.TestAllTypes.NestedEnum.FOO", "proto3.TestAllTypes.NestedEnum.BAR", "proto3.TestAllTypes.NestedEnum.BAZ",
    "proto2.TestAllTypes.NestedEnum.BAZ", "proto3.GlobalEnum.GAR", "proto2.GlobalEnum.GAZ",
  ]

  // MARK: Values

  /// A message from the oracle's `{"type", "value"}` form, as a cel-swift value.
  static func value(_ payload: JSON) throws -> Value {
    guard let name = payload["type"]?.stringValue, let swiftType = swiftType(name), let json = payload["value"] else {
      throw CodecError(description: "unsupported message \(payload.rendered)")
    }
    let message = try swiftType.init(jsonString: json.rendered)
    return types.value(of: message)
  }

  /// Canonical text of a message from the oracle: its text format as SwiftProtobuf writes it.
  static func canonical(json payload: JSON) -> String {
    guard let name = payload["type"]?.stringValue, let swiftType = swiftType(name), let json = payload["value"],
      let message = try? swiftType.init(jsonString: json.rendered)
    else {
      return "message:?\(payload.rendered)"
    }
    return "message:\(name){\(normalisingNullValues(message.textFormatString()))}"
  }

  /// Canonical text of a message value from cel-swift, in the form of ``canonical(json:)``.
  static func canonical(_ object: any ObjectValue) -> String {
    let name = object.celType.runtimeTypeName
    guard let swiftType = swiftType(name), let text = textFormat(swiftType, .object(object)) else {
      return "message:\(name)"
    }
    return "message:\(name){\(text)}"
  }

  /// The message's text format with NullValue numbers normalised (see ``normalisingNullValues(_:)``).
  private static func textFormat<M: SwiftProtobuf.Message>(_ type: M.Type, _ value: Value) -> String? {
    guard let message = try? types.message(from: value, as: type) else { return nil }
    return normalisingNullValues(message.textFormatString())
  }

  /// Text format with every number in a `google.protobuf.NullValue` field (`*null_value`, or the `value` of
  /// a `map_*_null_value` entry) written as `NULL_VALUE`: cel-go stores the number, but protojson, and so
  /// the oracle, writes `null`.
  static func normalisingNullValues(_ text: String) -> String {
    var blocks: [String] = []
    var out: [String] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasSuffix("{") {
        blocks.append(String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces))
      } else if trimmed == "}" {
        _ = blocks.popLast()
      }
      let indent = line.prefix { $0 == " " }
      let parts = trimmed.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
      guard parts.count == 2 else {
        out.append(String(line))
        continue
      }
      let (key, value) = (parts[0], parts[1])
      if key.hasSuffix("null_value") && !key.hasPrefix("repeated") {
        // A singular NullValue field: protojson's `null` reads back as unset, whatever was stored.
        continue
      }
      if key.hasSuffix("null_value") && value.hasPrefix("[") {
        let count = value.split(separator: ",").count
        out.append("\(indent)\(key): [" + Array(repeating: "NULL_VALUE", count: count).joined(separator: ", ") + "]")
      } else if Int64(value) != nil,
        key.hasSuffix("null_value") || (key == "value" && (blocks.last ?? "").hasSuffix("null_value"))
      {
        out.append("\(indent)\(key): NULL_VALUE")
      } else {
        out.append(String(line))
      }
    }
    return out.joined(separator: "\n")
  }

  /// A field value in protobuf JSON (bindings).
  static func protoJSON(_ v: GValue) -> JSON {
    switch v {
    case .null: return .null
    case .bool(let b): return .bool(b)
    case .int(let i): return .number(String(i))
    case .uint(let u): return .number(String(u))
    case .double(let d): return Codec.encodeDouble(d)
    case .string(let s): return .string(s)
    case .bytes(let b): return .string(Data(b).base64EncodedString())
    case .duration(let n): return .string(Codec.formatDuration(n))
    case .timestamp(let s, let n): return .string(Codec.formatTimestamp(s, n))
    case .list(let items): return .array(items.map(protoJSON))
    case .map(let entries):
      return .object(
        entries.map { key, value in
          let k: String
          switch key {
          case .string(let s): k = s
          case .int(let i): k = String(i)
          case .uint(let u): k = String(u)
          case .bool(let b): k = b ? "true" : "false"
          default: k = "?"
          }
          return (k, protoJSON(value))
        })
    case .optional(let o): return o.map(protoJSON) ?? .null
    case .message(_, let fields): return .object(fields.map { ($0.0, protoJSON($0.1)) })
    }
  }
}
