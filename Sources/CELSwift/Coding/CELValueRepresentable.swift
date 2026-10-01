// Customisation points for how a Swift type appears in CEL: a value conversion of its own, or the
// name of its object type. Not a ported file.

import CEL

/// A Swift type with its own CEL representation, used instead of its `Codable` conformance.
///
/// Conform types whose natural CEL form differs from what `Codable` produces. An enum that
/// expressions compare by rank, for example, is better an `int` than its raw string:
///
/// ```swift
/// enum Severity: String, Codable, CaseIterable, CELValueRepresentable {
///   case info, suggestion, warning, blocker
///
///   static var celType: CELType { .int }
///   var celValue: Value { .int(Int64(Self.allCases.firstIndex(of: self) ?? 0)) }
///   init(celValue: Value) throws {
///     guard let rank = celValue.asInt, Self.allCases.indices.contains(Int(rank)) else {
///       throw EvalError("not a severity: \(celValue)")
///     }
///     self = Self.allCases[Int(rank)]
///   }
/// }
/// // review.maxSeverity >= 2 type-checks, and compares ranks
/// ```
///
/// ``CELEncoder``, ``CELDecoder``, ``CELSchema`` and typed functions use the conformance wherever
/// the type appears: as a field, an element, a function argument or a result.
public protocol CELValueRepresentable {
  /// The CEL type of every value of this type.
  static var celType: CELType { get }

  /// The value as CEL sees it; must be of type ``celType``.
  var celValue: Value { get }

  /// Creates a value from its CEL representation.
  ///
  /// - Parameter celValue: A value of type ``celType``.
  /// - Throws: Any error when the value does not represent an instance; decoding reports it as a
  ///   `DecodingError.dataCorrupted`.
  init(celValue: Value) throws
}

/// A Swift type that names its CEL object type.
///
/// A struct encoded as a CEL object (``CELCodingOptions/StructRepresentation/objects``) is named
/// after its Swift type by default, module included: `PRBarEngine.ChangeRequest`. That name
/// appears in error messages, in `type(x)` and in struct literals such as
/// `PRBarEngine.Decision{verdict: "approve"}`. Conform to choose it:
///
/// ```swift
/// struct Decision: Codable, CELNamedType {
///   static let celTypeName = "prbar.Decision"
///   var verdict: String
/// }
/// ```
public protocol CELNamedType {
  /// The fully qualified CEL type name: identifiers separated by dots, such as `prbar.Decision`.
  static var celTypeName: String { get }
}

/// The CEL object type name of a Swift type: its ``CELNamedType`` name, or its fully qualified
/// Swift name (`Module.Outer.Inner`) without anonymous contexts such as those of private and local
/// types, and with every character that cannot appear in a CEL identifier replaced by `_`
/// (`Module.Box<Swift.Int>` is `Module.Box_Swift_Int_`).
func celTypeName(of type: Any.Type) -> String {
  if let named = type as? any CELNamedType.Type {
    return named.celTypeName
  }
  // Split the reflected name into its dot-separated components, keeping generic arguments and
  // parenthesised contexts (`(unknown context at $1023a)`, `(extension in M)`) inside one.
  var components: [[Unicode.Scalar]] = []
  var current: [Unicode.Scalar] = []
  var depth = 0
  for scalar in String(reflecting: type).unicodeScalars {
    switch scalar {
    case "<", "(":
      depth += 1
    case ">", ")":
      depth = max(0, depth - 1)
    case "." where depth == 0:
      components.append(current)
      current = []
      continue
    default:
      break
    }
    current.append(scalar)
  }
  components.append(current)
  var names: [String] = []
  for component in components where component.first != "(" && !component.isEmpty {
    var name = String.UnicodeScalarView()
    for scalar in component {
      switch scalar {
      case "a"..."z", "A"..."Z", "0"..."9", "_": name.append(scalar)
      default: name.append("_")
      }
    }
    if let first = name.first, ("0"..."9").contains(first) {
      name.insert("_", at: name.startIndex)
    }
    names.append(String(name))
  }
  return names.joined(separator: ".")
}
