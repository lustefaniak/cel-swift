// Fields of closed (proto2) enum types holding numbers their enum does not declare. Not a ported file: cel-go
// stores any int32 in such a field (Go enums are int32s, protoreflect sets them as they are); swift-protobuf's
// closed enums cannot hold an undeclared number, so these fields keep such numbers in the message's unknown
// fields, in the wire format protobuf uses for the field, as swift-protobuf does when it decodes one.

import CEL
import Foundation
import SwiftProtobuf

/// The number conversions of an enum kind whose Swift enum is closed (a proto2 enum).
struct ClosedEnumNumbers<V: Sendable>: Sendable {
  /// The enum case of a declared number, `nil` for an undeclared one.
  let declared: @Sendable (Int32) -> V?
  /// The number of an enum case.
  let number: @Sendable (V) -> Int32
  /// A declared value, standing in for undeclared ones where swift-protobuf encodes map keys.
  let placeholder: V
  /// The fully qualified enum name, for value names in JSON.
  let enumTypeName: String?
  /// The number a CEL value assigns (an `int`, or a value of this enum), range checked.
  let fromValue: @Sendable (Value) -> Result<Int32, EvalError>
  /// The CEL value of a number: an `int`, or a value of this enum with strong enums.
  let toValue: @Sendable (Int32, ProtobufTypes) -> Value

  /// The protojson form of a number: the value name when declared, otherwise the number.
  func json(_ number: Int32, _ types: ProtobufTypes) -> Google_Protobuf_Value {
    if let enumTypeName, let name = types.enumValueName(enumTypeName, number) {
      return Google_Protobuf_Value(stringValue: name)
    }
    return Google_Protobuf_Value(numberValue: Double(number))
  }
}

extension ProtobufField {
  /// A singular closed enum field: an undeclared number is a varint in the unknown fields, which
  /// takes precedence over the typed value (it was decoded or assigned last).
  static func closedEnumSingular<V>(
    _ name: String, number: Int32, jsonName: String?, _ keyPath: WritableKeyPath<M, V> & Sendable,
    _ kind: ProtobufValueKind<V>, _ closed: ClosedEnumNumbers<V>, isTypedSet: @escaping @Sendable (M) -> Bool
  ) -> ProtobufField<M> {
    let effective: @Sendable (M) -> Int32? = { m in
      if let unknown = unknownVarints(m.unknownFields, number).last {
        return Int32(truncatingIfNeeded: unknown)
      }
      return isTypedSet(m) ? closed.number(m[keyPath: keyPath]) : nil
    }
    return ProtobufField(
      name: name,
      jsonName: jsonName ?? defaultJSONName(name),
      number: number,
      type: kind.celType,
      strongEnumType: kind.enumTypeName.map { _ in kind.celType(strongEnums: true) },
      get: { m, types in
        closed.toValue(effective(m) ?? closed.number(m[keyPath: keyPath]), types)
      },
      isSet: { m in effective(m) != nil },
      set: { m, value, _ in
        let n: Int32
        switch closed.fromValue(value) {
        case .success(let converted): n = converted
        case .failure(let error): return fieldTypeConversionError(M.self, name, error)
        }
        var unknown = removingUnknownFields(m.unknownFields, number)
        if let v = closed.declared(n) {
          m[keyPath: keyPath] = v
        } else {
          unknown += varintRecord(number, UInt64(bitPattern: Int64(n)))
        }
        setUnknownFields(&m, unknown)
        return nil
      },
      equal: { a, b, _ in effective(a) == effective(b) },
      holdsUndeclaredEnumNumbers: true,
      patchJSON: { m, json, _ in
        guard let n = unknownVarints(m.unknownFields, number).last else { return }
        json = Google_Protobuf_Value(numberValue: Double(Int32(truncatingIfNeeded: n)))
      }
    )
  }

  /// A repeated closed enum field. A list with an undeclared number is kept entirely in the unknown
  /// fields, one varint per element, so reads return the elements in order; decoded messages hold the
  /// declared numbers typed and the others unknown, and read the typed ones first.
  static func closedEnumRepeated<V>(
    _ name: String, number: Int32, jsonName: String?, _ keyPath: WritableKeyPath<M, [V]> & Sendable,
    _ kind: ProtobufValueKind<V>, _ closed: ClosedEnumNumbers<V>
  ) -> ProtobufField<M> {
    let effective: @Sendable (M) -> [Int32] = { m in
      m[keyPath: keyPath].map(closed.number)
        + unknownVarints(m.unknownFields, number, packed: true).map { Int32(truncatingIfNeeded: $0) }
    }
    return ProtobufField(
      name: name,
      jsonName: jsonName ?? defaultJSONName(name),
      number: number,
      type: .list(kind.celType),
      strongEnumType: kind.enumTypeName.map { _ in .list(kind.celType(strongEnums: true)) },
      get: { m, types in
        if !hasUnknownFields(m.unknownFields, number) {
          return .list(ProtobufRepeatedList(elements: m[keyPath: keyPath], kind: kind, types: types))
        }
        return .list(ArrayList(effective(m).map { closed.toValue($0, types) }))
      },
      isSet: { m in !m[keyPath: keyPath].isEmpty || hasUnknownFields(m.unknownFields, number) },
      set: { m, value, _ in
        guard case .list(let list) = value else {
          return unsupportedFieldTypeError(M.self, name, value)
        }
        var numbers: [Int32] = []
        numbers.reserveCapacity(list.count)
        for i in 0..<list.count {
          switch closed.fromValue(list.element(at: i)) {
          case .success(let n): numbers.append(n)
          case .failure(let error): return fieldTypeConversionError(M.self, name, error)
          }
        }
        var unknown = removingUnknownFields(m.unknownFields, number)
        let elements = numbers.compactMap(closed.declared)
        if elements.count == numbers.count {
          m[keyPath: keyPath] = elements
        } else {
          m[keyPath: keyPath] = []
          for n in numbers {
            unknown += varintRecord(number, UInt64(bitPattern: Int64(n)))
          }
        }
        setUnknownFields(&m, unknown)
        return nil
      },
      equal: { a, b, _ in effective(a) == effective(b) },
      holdsUndeclaredEnumNumbers: true,
      patchJSON: { m, json, types in
        guard hasUnknownFields(m.unknownFields, number) else { return }
        json = Google_Protobuf_Value(
          listValue: Google_Protobuf_ListValue(values: effective(m).map { closed.json($0, types) }))
      }
    )
  }

  /// A map field with closed enum values: entries with an undeclared number are map entries in the
  /// unknown fields, written in key order. swift-protobuf encodes and decodes their keys: an entry is
  /// built with a declared stand-in value whose varint is then replaced.
  static func closedEnumMap<K: Hashable, V>(
    _ name: String, number: Int32, jsonName: String?, _ keyPath: WritableKeyPath<M, [K: V]> & Sendable,
    key: ProtobufValueKind<K>, value: ProtobufValueKind<V>, _ closed: ClosedEnumNumbers<V>
  ) -> ProtobufField<M> {
    /// The unknown entries as keys and numbers, decoded with swift-protobuf.
    let unknownEntries: @Sendable (M) -> [(K, Int32)] = { m in
      var result: [(K, Int32)] = []
      for record in unknownRecords(m.unknownFields, number) where record.wireType == 2 {
        guard let (entry, n) = replacingMapValue(record.payload, with: closed.number(closed.placeholder)),
          let n
        else { continue }
        var scratch = M()
        let bytes = lengthDelimitedRecord(number, entry)
        guard (try? scratch.merge(serializedBytes: bytes, partial: true)) != nil,
          let k = scratch[keyPath: keyPath].keys.first
        else { continue }
        result.append((k, Int32(truncatingIfNeeded: n)))
      }
      return result
    }
    /// Typed and unknown entries; an unknown entry wins over a typed one with the same key.
    let effective: @Sendable (M) -> [K: Int32] = { m in
      var entries = m[keyPath: keyPath].mapValues(closed.number)
      for (k, n) in unknownEntries(m) {
        entries[k] = n
      }
      return entries
    }
    let toMapKey = key.toMapKey
    return ProtobufField(
      name: name,
      jsonName: jsonName ?? defaultJSONName(name),
      number: number,
      type: .map(key: key.celType, value: value.celType),
      strongEnumType: value.enumTypeName.map { _ in
        .map(key: key.celType, value: value.celType(strongEnums: true))
      },
      get: { m, types in
        guard hasUnknownFields(m.unknownFields, number), let toMapKey else {
          return .map(ProtobufMap(entries: m[keyPath: keyPath], keyKind: key, valueKind: value, types: types))
        }
        var map = OrderedMap()
        for (k, n) in effective(m).map({ (toMapKey($0.key), $0.value) }).sorted(by: { mapKeyPrecedes($0.0, $1.0) }) {
          map[k] = closed.toValue(n, types)
        }
        return .map(map)
      },
      isSet: { m in !m[keyPath: keyPath].isEmpty || hasUnknownFields(m.unknownFields, number) },
      set: { m, mapValue, types in
        guard case .map(let source) = mapValue else {
          return unsupportedFieldTypeError(M.self, name, mapValue)
        }
        var entries: [K: V] = [:]
        var undeclared: [(key: K, mapKey: MapKey, number: Int32)] = []
        let failure = source.firstNonNil { sourceKey -> EvalError? in
          let k: K
          switch key.fromValue(sourceKey.value, types) {
          case .success(let converted?): k = converted
          case .success(nil): return nil
          case .failure(let error): return fieldTypeConversionError(M.self, name, error)
          }
          let n: Int32
          switch closed.fromValue(source.value(forKey: sourceKey) ?? .null) {
          case .success(let converted): n = converted
          case .failure(let error): return fieldTypeConversionError(M.self, name, error)
          }
          if let v = closed.declared(n) {
            entries[k] = v
          } else {
            undeclared.append((k, sourceKey, n))
          }
          return nil
        }
        if let failure {
          return failure
        }
        m[keyPath: keyPath] = entries
        var unknown = removingUnknownFields(m.unknownFields, number)
        // Key order, as Go's deterministic encoding writes map entries.
        for entry in undeclared.sorted(by: { mapKeyPrecedes($0.mapKey, $1.mapKey) }) {
          var scratch = M()
          scratch[keyPath: keyPath] = [entry.key: closed.placeholder]
          guard let bytes: [UInt8] = try? scratch.serializedBytes(partial: true),
            let record = unknownRecords(bytes, number).first,
            let (rewritten, _) = replacingMapValue(record.payload, with: entry.number)
          else {
            return EvalError("cannot encode the map entry of \(M.protoMessageName).\(name)")
          }
          unknown += lengthDelimitedRecord(number, rewritten)
        }
        setUnknownFields(&m, unknown)
        return nil
      },
      equal: { a, b, _ in effective(a) == effective(b) },
      holdsUndeclaredEnumNumbers: true,
      patchJSON: { m, json, types in
        guard hasUnknownFields(m.unknownFields, number), let toMapKey else { return }
        var object = Google_Protobuf_Struct()
        for (k, n) in effective(m) {
          object.fields[jsonMapKey(toMapKey(k))] = closed.json(n, types)
        }
        json = Google_Protobuf_Value(structValue: object)
      }
    )
  }
}

// MARK: - Unknown fields

/// One record of protobuf wire format.
struct WireRecord {
  var fieldNumber: UInt64
  var wireType: UInt64
  /// The whole record, tag included.
  var bytes: ArraySlice<UInt8>
  /// The value: the varint's bytes, or a length-delimited record's content.
  var payload: [UInt8]
}

/// The records of encoded fields with the given field number.
func unknownRecords(_ bytes: [UInt8], _ fieldNumber: Int32) -> [WireRecord] {
  var records: [WireRecord] = []
  var index = 0
  while index < bytes.count {
    let start = index
    guard let (tag, afterTag) = consumeVarint(bytes, at: index), let (number, end) = consumeField(bytes, at: index)
    else { break }
    index = end
    guard number == UInt64(fieldNumber) else { continue }
    var payload = Array(bytes[afterTag..<end])
    if tag & 7 == 2, let (_, afterLength) = consumeVarint(bytes, at: afterTag) {
      payload = Array(bytes[afterLength..<end])
    }
    records.append(WireRecord(fieldNumber: number, wireType: tag & 7, bytes: bytes[start..<end], payload: payload))
  }
  return records
}

func unknownRecords(_ storage: UnknownStorage, _ fieldNumber: Int32) -> [WireRecord] {
  storage.data.isEmpty ? [] : unknownRecords([UInt8](storage.data), fieldNumber)
}

/// Whether the unknown fields hold a record with the field number.
func hasUnknownFields(_ storage: UnknownStorage, _ fieldNumber: Int32) -> Bool {
  !storage.data.isEmpty && !unknownRecords(storage, fieldNumber).isEmpty
}

/// The varints of a field number in the unknown fields; with `packed`, also the varints of packed
/// (length-delimited) records.
func unknownVarints(_ storage: UnknownStorage, _ fieldNumber: Int32, packed: Bool = false) -> [UInt64] {
  var values: [UInt64] = []
  for record in unknownRecords(storage, fieldNumber) {
    switch record.wireType {
    case 0:
      if let (value, _) = consumeVarint(record.payload, at: 0) {
        values.append(value)
      }
    case 2 where packed:
      var index = 0
      while index < record.payload.count, let (value, next) = consumeVarint(record.payload, at: index) {
        values.append(value)
        index = next
      }
    default:
      continue
    }
  }
  return values
}

/// The unknown fields without the records of a field number.
func removingUnknownFields(_ storage: UnknownStorage, _ fieldNumber: Int32) -> [UInt8] {
  removingUnknownFields(storage, [fieldNumber])
}

/// The unknown fields without the records of some field numbers.
func removingUnknownFields(_ storage: UnknownStorage, _ fieldNumbers: [Int32]) -> [UInt8] {
  let bytes = [UInt8](storage.data)
  var result: [UInt8] = []
  var index = 0
  while index < bytes.count {
    guard let (number, end) = consumeField(bytes, at: index) else {
      result += bytes[index...]
      break
    }
    if !fieldNumbers.contains(where: { UInt64($0) == number }) {
      result += bytes[index..<end]
    }
    index = end
  }
  return result
}

/// Replaces a message's unknown fields with `bytes`. swift-protobuf only fills unknown fields while
/// decoding, so they are decoded into a message without fields, all of whose fields are unknown.
func setUnknownFields<M: SwiftProtobuf.Message>(_ message: inout M, _ bytes: [UInt8]) {
  guard let carrier = try? Google_Protobuf_Empty(serializedBytes: bytes, partial: true) else { return }
  message.unknownFields = carrier.unknownFields
}

func appendVarint(_ value: UInt64, to bytes: inout [UInt8]) {
  var v = value
  while v >= 0x80 {
    bytes.append(UInt8(truncatingIfNeeded: v) | 0x80)
    v >>= 7
  }
  bytes.append(UInt8(v))
}

/// A varint record: tag and value.
func varintRecord(_ fieldNumber: Int32, _ value: UInt64) -> [UInt8] {
  var bytes: [UInt8] = []
  appendVarint(UInt64(fieldNumber) << 3, to: &bytes)
  appendVarint(value, to: &bytes)
  return bytes
}

/// A length-delimited record: tag, length and content.
func lengthDelimitedRecord(_ fieldNumber: Int32, _ content: [UInt8]) -> [UInt8] {
  var bytes: [UInt8] = []
  appendVarint(UInt64(fieldNumber) << 3 | 2, to: &bytes)
  appendVarint(UInt64(content.count), to: &bytes)
  return bytes + content
}

/// A map entry's content with its value (field 2, a varint) replaced by `number`, and the value it
/// held (`nil` when the entry had none).
func replacingMapValue(_ entry: [UInt8], with number: Int32) -> ([UInt8], UInt64?)? {
  var result: [UInt8] = []
  var old: UInt64?
  var index = 0
  while index < entry.count {
    guard let (tag, afterTag) = consumeVarint(entry, at: index), let (fieldNumber, end) = consumeField(entry, at: index)
    else { return nil }
    if fieldNumber == 2 && tag & 7 == 0 {
      old = consumeVarint(entry, at: afterTag)?.0
    } else {
      result += entry[index..<end]
    }
    index = end
  }
  result += varintRecord(2, UInt64(bitPattern: Int64(number)))
  return (result, old)
}
