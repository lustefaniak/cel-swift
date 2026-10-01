// The CEL object a Swift struct is encoded to: a type name and the encoded fields in declaration
// order. Not a ported file.

import CEL

/// An encoded Swift struct: a CEL object whose fields are the struct's coding keys.
///
/// Fields encoded as `nil` hold `null`: reading them gives `null` and `has()` is false. Reading a
/// name the struct did not encode is a `no such field` error, as for protobuf messages.
struct Record: ObjectValue, CustomStringConvertible {
  let typeName: String
  let fieldNames: [String]
  let fields: [String: Value]

  init(typeName: String, entries: [(String, Value)]) {
    var names: [String] = []
    var fields: [String: Value] = [:]
    for (name, value) in entries {
      if fields.updateValue(value, forKey: name) == nil {
        names.append(name)
      }
    }
    self.typeName = typeName
    self.fieldNames = names
    self.fields = fields
  }

  var celType: CELType { .object(typeName) }

  func field(_ name: String) -> Value {
    fields[name] ?? .error(EvalError("no such field '\(name)'"))
  }

  func isFieldSet(_ name: String) -> Value {
    switch fields[name] {
    case nil: return .error(EvalError("no such field '\(name)'"))
    case .null?, .optional(nil)?: return .bool(false)
    default: return .bool(true)
    }
  }

  func isEqual(to other: any ObjectValue) -> Bool {
    guard let other = other as? Record, other.typeName == typeName, other.fields.count == fields.count else {
      return false
    }
    for (name, value) in fields {
      guard let otherValue = other.fields[name], value.celEquals(otherValue) == .bool(true) else {
        return false
      }
    }
    return true
  }

  /// `TypeName{field: value, ...}` in declaration order.
  var description: String {
    let body = fieldNames.map { "\($0): \(fields[$0] ?? .null)" }.joined(separator: ", ")
    return "\(typeName){\(body)}"
  }
}
