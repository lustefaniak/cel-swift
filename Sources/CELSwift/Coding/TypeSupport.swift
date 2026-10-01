// What the encoder, the decoder and the schema need to know about standard library and
// Foundation types without decoding them: optionals, collections, and the leaf types CEL has a
// native type for (dates, durations, bytes). Not a ported file.

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import CEL

/// `Optional`, seen from generic code that does not know its wrapped type.
protocol OptionalMarker {
  static var wrappedType: Any.Type { get }
  static var absent: Self { get }
  var isNone: Bool { get }
}

extension Optional: OptionalMarker {
  static var wrappedType: Any.Type { Wrapped.self }
  static var absent: Self { nil }
  var isNone: Bool { self == nil }
}

/// `Array`, `ContiguousArray` and `Set`: encoded as CEL lists.
protocol SequenceMarker {
  static var elementType: Any.Type { get }
  static var empty: Self { get }
}

extension Array: SequenceMarker {
  static var elementType: Any.Type { Element.self }
  static var empty: Self { [] }
}

extension ContiguousArray: SequenceMarker {
  static var elementType: Any.Type { Element.self }
  static var empty: Self { [] }
}

extension Set: SequenceMarker {
  static var elementType: Any.Type { Element.self }
  static var empty: Self { [] }
}

/// `Dictionary`: encoded as a CEL map whose keys come from the dictionary keys, never converted by
/// the key strategy.
protocol DictionaryMarker {
  static var keyType: Any.Type { get }
  static var valueType: Any.Type { get }
  static var empty: Self { get }
}

extension Dictionary: DictionaryMarker {
  static var keyType: Any.Type { Key.self }
  static var valueType: Any.Type { Value.self }
  static var empty: Self { [:] }
}

/// The CEL map key type for a Swift dictionary key type: `int` for signed integers (and
/// `Int`-backed enums), `uint` for unsigned ones, `bool`, otherwise `string`.
func mapKeyType(for type: Any.Type) -> CELType {
  switch type {
  case is Int.Type, is Int8.Type, is Int16.Type, is Int32.Type, is Int64.Type: return .int
  case is UInt.Type, is UInt8.Type, is UInt16.Type, is UInt32.Type, is UInt64.Type: return .uint
  case is Bool.Type: return .bool
  default:
    if let raw = type as? any RawRepresentable.Type, rawValueType(raw) == .int {
      return .int
    }
    return .string
  }
}

private func rawValueType<R: RawRepresentable>(_ type: R.Type) -> CELType? {
  primitiveType(of: R.RawValue.self)
}

/// The CEL type of a Swift scalar, `nil` for anything else.
func primitiveType(of type: Any.Type) -> CELType? {
  switch type {
  case is Bool.Type: return .bool
  case is String.Type: return .string
  case is Int.Type, is Int8.Type, is Int16.Type, is Int32.Type, is Int64.Type: return .int
  case is UInt.Type, is UInt8.Type, is UInt16.Type, is UInt32.Type, is UInt64.Type: return .uint
  case is Double.Type, is Float.Type: return .double
  default: return nil
  }
}

/// The CEL type of a leaf type with a native CEL counterpart, `nil` for anything else.
func leafType(of type: Any.Type) -> CELType? {
  if let representable = type as? any CELValueRepresentable.Type {
    return representable.celType
  }
  switch type {
  case is Date.Type: return .timestamp
  case is Swift.Duration.Type: return .duration
  case is Data.Type: return .bytes
  case is URL.Type, is UUID.Type: return .string
  default: return primitiveType(of: type)
  }
}

/// The type of a field or element that may be absent: scalars become their protobuf wrapper
/// types (`wrapper(int)` reads as `null` or an `int`), anything else keeps its type and reads as
/// `null` when absent.
func nullable(_ type: CELType) -> CELType {
  switch type {
  case .bool, .bytes, .double, .int, .string, .uint: return .wrapper(type)
  default: return type
  }
}

// MARK: - Leaf conversions

/// Converts a leaf value (scalar, date, duration, data, URL, ``CELValueRepresentable``) to a CEL
/// value; `nil` when `value` is not a leaf.
func leafValue(_ value: Any, codingPath: [any CodingKey]) throws -> Value? {
  switch value {
  case let representable as any CELValueRepresentable: return representable.celValue
  case let v as Bool: return .bool(v)
  case let v as String: return .string(v)
  case let v as Int: return .int(Int64(v))
  case let v as Int8: return .int(Int64(v))
  case let v as Int16: return .int(Int64(v))
  case let v as Int32: return .int(Int64(v))
  case let v as Int64: return .int(v)
  case let v as UInt: return .uint(UInt64(v))
  case let v as UInt8: return .uint(UInt64(v))
  case let v as UInt16: return .uint(UInt64(v))
  case let v as UInt32: return .uint(UInt64(v))
  case let v as UInt64: return .uint(v)
  case let v as Double: return .double(v)
  case let v as Float: return .double(Double(v))
  case let date as Date:
    guard let timestamp = CELTimestamp(date) else {
      throw EncodingError.invalidValue(
        date,
        EncodingError.Context(
          codingPath: codingPath,
          debugDescription: "\(date) is outside the CEL timestamp range (years 1 to 9999)"))
    }
    return .timestamp(timestamp)
  case let duration as Swift.Duration:
    guard let value = Value(duration) else {
      throw EncodingError.invalidValue(
        duration,
        EncodingError.Context(
          codingPath: codingPath,
          debugDescription: "\(duration) is outside the CEL duration range or finer than a nanosecond"))
    }
    return value
  case let data as Data: return .bytes([UInt8](data))
  case let url as URL: return .string(url.absoluteString)
  default: return nil
  }
}

extension CELTimestamp {
  /// The timestamp of a date, rounded to the nanosecond; `nil` outside years 1 to 9999.
  init?(_ date: Date) {
    let interval = date.timeIntervalSince1970
    guard interval.isFinite else { return nil }
    var seconds = interval.rounded(.down)
    var nanos = ((interval - seconds) * 1_000_000_000).rounded()
    if nanos >= 1_000_000_000 {
      seconds += 1
      nanos -= 1_000_000_000
    }
    guard
      seconds >= Double(CELTimestamp.minSecondsSinceEpoch),
      seconds <= Double(CELTimestamp.maxSecondsSinceEpoch)
    else { return nil }
    self.init(secondsSinceEpoch: Int64(seconds), nanoseconds: Int32(nanos))
  }

  /// The date of the timestamp, to the precision of `Date`.
  var date: Date {
    Date(timeIntervalSince1970: Double(secondsSinceEpoch) + Double(nanoseconds) / 1_000_000_000)
  }
}

extension CELDuration {
  /// The duration as a Swift duration.
  var swiftDuration: Swift.Duration {
    .nanoseconds(nanoseconds)
  }
}
