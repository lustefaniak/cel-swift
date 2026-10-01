// How Swift values map to CEL values, shared by CELEncoder, CELDecoder and CELSchema so the three
// agree on field names and struct representation. Not a ported file.

import CEL

/// How Swift types and values map to CEL types and values.
///
/// ``CELEncoder``, ``CELDecoder`` and ``CELSchema`` take the same options, so a value encoded
/// for evaluation has exactly the fields and types the schema declared for type checking. Pass
/// the same options to all three; ``TypedProgram`` does this for you.
///
/// ```swift
/// var options = CELCodingOptions()
/// options.keyStrategy = .convertToSnakeCase   // lineStart is line_start in expressions
/// ```
public struct CELCodingOptions: Sendable {
  /// How Swift coding keys become CEL field and map key names.
  public enum KeyStrategy: Sendable {
    /// Uses the coding keys unchanged.
    case useDefaultKeys
    /// Converts camel-case coding keys to snake case: `headSha` becomes `head_sha`, `isDraft`
    /// becomes `is_draft`, the way `JSONEncoder.KeyEncodingStrategy.convertToSnakeCase` does.
    ///
    /// Decoding converts the requested keys the same way, so it accepts the names encoding
    /// produced. Dictionary keys are data, not field names, and are never converted.
    case convertToSnakeCase
    /// Converts each coding key with a closure.
    ///
    /// Decoding looks fields up by the converted name. Types whose decoding enumerates the keys
    /// it finds (`allKeys`) see the converted names.
    case custom(@Sendable (_ codingKey: String) -> String)
  }

  /// How Swift structs and classes with keyed coding become CEL values.
  public enum StructRepresentation: Sendable, Hashable {
    /// A struct is a CEL object of its own type, named after the Swift type (see
    /// ``CELNamedType``). The type checker knows its fields, so a misspelt field or a field of
    /// the wrong type is a compile error.
    case objects
    /// A struct is a `map(string, V)`: `V` is the field type when every field has the same type,
    /// `dyn` otherwise. Expressions can test keys with `in` and index with `[]`, but fields are no
    /// longer checked.
    case maps
  }

  /// How Swift coding keys become CEL field names. ``KeyStrategy/useDefaultKeys`` by default.
  public var keyStrategy: KeyStrategy
  /// How structs become CEL values. ``StructRepresentation/objects`` by default.
  public var structRepresentation: StructRepresentation

  /// Creates coding options.
  ///
  /// - Parameters:
  ///   - keyStrategy: How coding keys become CEL field names.
  ///   - structRepresentation: How structs become CEL values.
  public init(keyStrategy: KeyStrategy = .useDefaultKeys, structRepresentation: StructRepresentation = .objects) {
    self.keyStrategy = keyStrategy
    self.structRepresentation = structRepresentation
  }

  /// The CEL field name of a coding key.
  func fieldName(_ key: String) -> String {
    switch keyStrategy {
    case .useDefaultKeys: return key
    case .convertToSnakeCase: return snakeCased(key)
    case .custom(let convert): return convert(key)
    }
  }

  /// The coding key a CEL field name came from, for decoders that enumerate keys.
  func codingKey(forField name: String) -> String {
    switch keyStrategy {
    case .useDefaultKeys, .custom: return name
    case .convertToSnakeCase: return camelCased(name)
    }
  }
}

/// `JSONEncoder`'s snake-case conversion: words split where the case changes, an acronym followed
/// by a word keeps the acronym together (`myURLProperty` -> `my_url_property`), and leading or
/// trailing underscores are kept.
func snakeCased(_ key: String) -> String {
  let scalars = Array(key.unicodeScalars)
  guard !scalars.isEmpty else { return key }
  var words: [Range<Int>] = []
  var wordStart = 0
  var i = 0
  while i < scalars.count {
    let isUpper = scalars[i].properties.isUppercase
    if i > wordStart, isUpper {
      // An uppercase letter after a lowercase one starts a word; in a run of uppercase letters
      // the last one starts a word when a lowercase letter follows.
      let previousUpper = scalars[i - 1].properties.isUppercase
      let nextLower = i + 1 < scalars.count && scalars[i + 1].properties.isLowercase
      if !previousUpper || nextLower {
        words.append(wordStart..<i)
        wordStart = i
      }
    }
    i += 1
  }
  words.append(wordStart..<scalars.count)
  var result = String.UnicodeScalarView()
  for (index, word) in words.enumerated() {
    if index > 0 { result.append("_") }
    for scalar in scalars[word] {
      result.append(contentsOf: scalar.properties.lowercaseMapping.unicodeScalars)
    }
  }
  return String(result)
}

/// `JSONDecoder`'s snake-case to camel-case conversion: `head_sha` -> `headSha`, leading and
/// trailing underscores kept.
func camelCased(_ name: String) -> String {
  let scalars = Array(name.unicodeScalars)
  guard let first = scalars.firstIndex(where: { $0 != "_" }) else { return name }
  var last = scalars.count - 1
  while last > first, scalars[last] == "_" { last -= 1 }
  var result = String.UnicodeScalarView(scalars[..<first])
  var upperNext = false
  for scalar in scalars[first...last] {
    if scalar == "_" {
      upperNext = true
      continue
    }
    if upperNext {
      result.append(contentsOf: scalar.properties.uppercaseMapping.unicodeScalars)
      upperNext = false
    } else {
      result.append(scalar)
    }
  }
  result.append(contentsOf: scalars[(last + 1)...])
  return String(result)
}
