// CEL types derived from Swift types: the fields a `Decodable` type asks for while decoding are
// its CEL fields, so a facts struct is the declaration expressions are checked against.
// Not a ported file.

import CEL

/// The CEL type of a Swift `Decodable` type, with the object types it uses.
///
/// The schema is read from the type's `Decodable` conformance: a schema-collecting decoder runs
/// `init(from:)` once and records every key the type asks for and the type it asks for it as. A
/// stage's facts struct therefore declares exactly the fields ``CELEncoder`` produces, and the type
/// checker rejects a misspelt field or a field of the wrong type when the expression is compiled.
///
/// ```swift
/// struct ChangeRequest: Codable {
///   var repo: String
///   var additions: Int
///   var reviewer: String?
/// }
/// let schema = try CELSchema(for: ChangeRequest.self)
/// schema.type   // .object("MyApp.ChangeRequest")
/// schema.structTypes[0].fields.map(\.name)   // ["repo", "additions", "reviewer"]
/// ```
///
/// Optional properties are fields that may hold `null`; scalars among them have the protobuf
/// wrapper types (`wrapper(string)` for `String?`), which compare with plain values and `null`.
/// Arrays and sets are lists, dictionaries maps, and dates, durations, data and URLs have the
/// types ``CELEncoder`` gives them.
///
/// The type's decoding must be able to run on placeholder values: `0`, `""`, empty collections,
/// `nil` for optionals and the first case of `CaseIterable` enums. Enums need `CaseIterable` (or
/// ``CELValueRepresentable``), and types whose `init(from:)` validates values must accept those
/// placeholders.
public struct CELSchema: Sendable {
  /// A field of an object type.
  public struct Field: Sendable, Hashable {
    /// The CEL field name, after the key strategy.
    public var name: String
    /// The field type.
    public var type: CELType
    /// Whether the field may be `null`: the Swift property is optional.
    public var isOptional: Bool

    /// Creates a field.
    public init(name: String, type: CELType, isOptional: Bool) {
      self.name = name
      self.type = type
      self.isOptional = isOptional
    }
  }

  /// A CEL object type derived from a Swift struct: its name and fields.
  ///
  /// Registered with an environment (see `Environment.Option.types(_:options:)`), it lets the
  /// type checker resolve field selections and struct literals such as `prbar.Decision{verdict:
  /// "approve"}`, which create the same objects ``CELEncoder`` does.
  public struct StructType: StructTypeDescriptor, Sendable {
    /// The fully qualified CEL type name.
    public let typeName: String
    /// The fields, in the order the Swift type decodes them.
    public let fields: [Field]

    /// Creates an object type.
    public init(typeName: String, fields: [Field]) {
      self.typeName = typeName
      self.fields = fields
    }

    /// The field names, in declaration order.
    public var fieldNames: [String] { fields.map(\.name) }

    /// The field with the given name, or `nil`.
    public func field(named name: String) -> Field? {
      fields.first { $0.name == name }
    }

    /// The type of a field for the type checker, or `nil` for an unknown name.
    public func fieldType(named name: String) -> StructFieldType? {
      field(named: name).map { StructFieldType(name: $0.name, type: $0.type) }
    }

    /// Creates an object from a struct literal's fields; fields not given are `null` when
    /// optional and the zero value of their type otherwise.
    public func newValue(fields values: [String: Value]) -> Value {
      for name in values.keys where field(named: name) == nil {
        return .error(EvalError("no such field: \(name)"))
      }
      let entries = fields.map { field in
        (field.name, values[field.name] ?? (field.isOptional ? .null : zeroValue(of: field.type)))
      }
      return .object(Record(typeName: typeName, entries: entries))
    }
  }

  /// The CEL type of the Swift type.
  public let type: CELType
  /// The object types the type uses, itself first when it is a struct, in the order they were
  /// first met. Empty with ``CELCodingOptions/StructRepresentation/maps``.
  public let structTypes: [StructType]
  /// The fields of the type when it decodes as keyed values (a struct), `nil` otherwise. Present
  /// with either struct representation: these become the variables of
  /// `Environment.Option.variables(from:options:)`.
  public let fields: [Field]?

  /// Derives the schema of a `Decodable` type.
  ///
  /// - Parameters:
  ///   - type: The Swift type.
  ///   - options: The key strategy and struct representation; use the options the values will be
  ///     encoded with.
  /// - Throws: `DeclarationError` when the type cannot be described: an enum that is neither
  ///   `CaseIterable` nor ``CELValueRepresentable``, a struct that contains itself other than
  ///   through an optional or a collection, a dictionary with keys CEL maps cannot have, or a
  ///   decoding that fails on placeholder values.
  public init<T: Decodable>(for type: T.Type, options: CELCodingOptions = CELCodingOptions()) throws(DeclarationError) {
    let builder = SchemaBuilder(options: options)
    do {
      let (_, celType, fields) = try builder.sample(T.self, path: celTypeName(of: T.self))
      self.type = celType
      self.fields = fields
    } catch let error as DeclarationError {
      throw error
    } catch {
      throw DeclarationError("cannot derive the CEL type of \(T.self): \(error)")
    }
    self.structTypes = builder.order.compactMap { builder.structs[$0] }
  }

  /// The object type with the given name, or `nil`.
  public func structType(named name: String) -> StructType? {
    structTypes.first { $0.typeName == name }
  }

  /// The CEL type of a Swift type for function signatures: static for leaves and collections,
  /// derived for other `Decodable` types.
  static func celType(of type: Any.Type, options: CELCodingOptions) throws(DeclarationError) -> CELType {
    do {
      return try SchemaBuilder(options: options).celType(of: type, path: celTypeName(of: type))
    } catch let error as DeclarationError {
      throw error
    } catch {
      throw DeclarationError("cannot derive the CEL type of \(type): \(error)")
    }
  }
}

/// The value a field that was not given takes in a struct literal.
func zeroValue(of type: CELType) -> Value {
  switch type {
  case .bool: return .bool(false)
  case .int: return .int(0)
  case .uint: return .uint(0)
  case .double: return .double(0)
  case .string: return .string("")
  case .bytes: return .bytes([])
  case .list: return .list(ArrayList())
  case .map: return .map(OrderedMap())
  case .duration: return .duration(CELDuration(nanoseconds: 0))
  case .timestamp: return .timestamp(CELTimestamp(secondsSinceEpoch: 0))
  default: return .null
  }
}

/// The CEL type of a scalar value, `nil` for other values.
func scalarType(of value: Value) -> CELType? {
  switch value {
  case .bool: return .bool
  case .int: return .int
  case .uint: return .uint
  case .double: return .double
  case .string: return .string
  case .bytes: return .bytes
  case .duration: return .duration
  case .timestamp: return .timestamp
  default: return nil
  }
}
