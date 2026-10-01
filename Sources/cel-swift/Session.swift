// The environment the cel-swift subcommands compile against, built from command line options or
// REPL commands. Modelled on cel-go repl/evaluator.go (Evaluator: lets, declarations, options),
// reduced to variables: function lets and descriptor loading are not supported.

import CEL
import CELExtensions
import Foundation

/// Declarations, bound values and libraries an expression is compiled and evaluated with.
struct Session {
  /// A variable declared with a type and, for lets, a value.
  struct Binding {
    var name: String
    var type: CELType
    var value: Value?
    /// The source of a let, shown by `%status`.
    var source: String?
  }

  var container = ""
  var libraries: [String] = []
  var bindings: [Binding] = []

  /// The options common to every subcommand that compiles expressions.
  static let options: Set<String> = ["container", "ext", "declare", "let", "json"]

  /// The help text for ``options``.
  static let optionsHelp = """
    Environment options:
      --container NAME        resolve unqualified names in NAME
      --ext NAME[:VERSION]    add an extension library: \(LibraryCatalog.names.joined(separator: ", "))
      --declare NAME:TYPE     declare a variable, e.g. --declare 'x:map(string, int)'
      --let NAME=EXPR         declare a variable bound to the value of EXPR
      --json FILE             bind the members of the JSON object in FILE ('-' for stdin) as dyn variables
    """

  /// Creates a session from the environment options of a parsed command line.
  init(arguments: Arguments) throws {
    container = arguments.last("container") ?? ""
    for ext in arguments.all("ext") {
      try addLibrary(ext)
    }
    for path in arguments.all("json") {
      try bindJSON(path: path)
    }
    for declaration in arguments.all("declare") {
      guard let colon = declaration.firstIndex(of: ":") else {
        throw UsageError("--declare expects NAME:TYPE, got '\(declaration)'")
      }
      let name = declaration[..<colon].trimmingCharacters(in: .whitespaces)
      let type = try TypeParser.parse(String(declaration[declaration.index(after: colon)...]))
      declare(name, type: type)
    }
    for definition in arguments.all("let") {
      guard let equals = definition.firstIndex(of: "=") else {
        throw UsageError("--let expects NAME=EXPR, got '\(definition)'")
      }
      let name = definition[..<equals].trimmingCharacters(in: .whitespaces)
      try bind(name, to: String(definition[definition.index(after: equals)...]), type: nil)
    }
  }

  init() {}

  /// The environment with the configured libraries and every binding declared.
  func environment() throws -> Environment {
    // Macro call tracking lets `parse` print macros back in their source form.
    var options: [Environment.Option] = [.macroCallTracking]
    if !container.isEmpty {
      options.append(.container(container))
    }
    for name in libraries {
      options.append(.library(try LibraryCatalog.library(name)))
    }
    options.append(.variables(bindings.map { VariableDecl(name: $0.name, type: $0.type) }))
    return try Environment(options: options)
  }

  /// The values of the bindings that have one.
  var values: [String: Value] {
    var result: [String: Value] = [:]
    for binding in bindings {
      if let value = binding.value {
        result[binding.name] = value
      }
    }
    return result
  }

  /// Adds an extension library given as `NAME` or `NAME:VERSION`.
  mutating func addLibrary(_ specification: String) throws {
    _ = try LibraryCatalog.library(specification)
    if !libraries.contains(specification) {
      libraries.append(specification)
    }
  }

  /// Declares a variable without a value, replacing an earlier binding with the same name.
  mutating func declare(_ name: String, type: CELType) {
    replace(Binding(name: name, type: type, value: nil, source: nil))
  }

  /// Evaluates `source` and binds its value to `name`, checking it against `type` when given.
  mutating func bind(_ name: String, to source: String, type: CELType?) throws {
    let env = try environment()
    let checked = try env.compile(source)
    if let type, !type.isAssignable(from: checked.outputType) {
      throw CommandFailure("'\(name)' has type \(checked.outputType), not \(type)")
    }
    let value = try env.program(checked).evaluate(values).value
    replace(Binding(name: name, type: type ?? checked.outputType, value: value, source: source))
  }

  /// Removes a binding; returns whether it existed.
  mutating func remove(_ name: String) -> Bool {
    let count = bindings.count
    bindings.removeAll { $0.name == name }
    return bindings.count != count
  }

  private mutating func replace(_ binding: Binding) {
    if let index = bindings.firstIndex(where: { $0.name == binding.name }) {
      bindings[index] = binding
    } else {
      bindings.append(binding)
    }
  }

  /// Binds each member of a JSON object as a `dyn` variable.
  mutating func bindJSON(path: String) throws {
    let data: Data
    if path == "-" {
      data = Data(readStandardInput().utf8)
    } else {
      guard let contents = FileManager.default.contents(atPath: path) else {
        throw CommandFailure("cannot read \(path)")
      }
      data = contents
    }
    let json: JSON
    do {
      json = try JSONDecoder().decode(JSON.self, from: data)
    } catch {
      throw CommandFailure("\(path): invalid JSON: \(error)")
    }
    guard case .object(let members) = json else {
      throw CommandFailure("\(path): expected a JSON object")
    }
    for (name, member) in members.sorted(by: { $0.key < $1.key }) {
      replace(Binding(name: name, type: .dyn, value: member.value, source: nil))
    }
  }

  /// Compiles an expression in the session's environment.
  func compile(_ text: String) throws -> (Environment, CheckedExpression) {
    let env = try environment()
    return (env, try env.compile(text))
  }
}

/// A JSON document, converted to CEL values the way cel-go converts `google.protobuf.Value`:
/// numbers become doubles, objects maps with string keys.
enum JSON: Decodable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSON])
  case object([String: JSON])

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let bool = try? container.decode(Bool.self) {
      self = .bool(bool)
    } else if let number = try? container.decode(Double.self) {
      self = .number(number)
    } else if let string = try? container.decode(String.self) {
      self = .string(string)
    } else if let array = try? container.decode([JSON].self) {
      self = .array(array)
    } else {
      self = .object(try container.decode([String: JSON].self))
    }
  }

  var value: Value {
    switch self {
    case .null: return .null
    case .bool(let bool): return Value(bool)
    case .number(let number): return Value(number)
    case .string(let string): return Value(string)
    case .array(let elements): return Value(elements.map(\.value))
    case .object(let members): return Value(members.mapValues(\.value))
    }
  }
}

/// The extension libraries the tool can add, by their configuration alias.
enum LibraryCatalog {
  static let names = [
    "bindings", "encoders", "lists", "math", "network", "optional", "protos", "regex", "sets", "strings",
    "two-var-comprehensions",
  ]

  /// The library for `NAME` or `NAME:VERSION`.
  static func library(_ specification: String) throws -> Library {
    var name = specification
    var version = Library.latestVersion
    if let colon = specification.firstIndex(of: ":") {
      name = String(specification[..<colon])
      let text = specification[specification.index(after: colon)...]
      if text != "latest" {
        guard let number = UInt32(text) else {
          throw UsageError("invalid version in '\(specification)'")
        }
        version = number
      }
    }
    switch name {
    case "bindings": return .bindings(version: version)
    case "encoders": return .encoders(version: version)
    case "lists": return .lists(version: version)
    case "math": return .math(version: version)
    case "network": return .network(version: version == Library.latestVersion ? 1 : version)
    case "optional": return .optionalTypes(version: version)
    case "protos": return .protos(version: version)
    case "regex": return .regex(version: version)
    case "sets": return .sets(version: version)
    case "strings": return .strings(version: version)
    case "two-var-comprehensions": return .twoVarComprehensions(version: version)
    default:
      throw UsageError("unknown extension '\(name)'; available: \(names.joined(separator: ", "))")
    }
  }
}

/// Parses type names such as `int`, `list(string)`, `map(string, list(int))` or `list<int>`.
struct TypeParser {
  private var scalars: [Unicode.Scalar]
  private var position = 0
  private let text: String

  static func parse(_ text: String) throws(UsageError) -> CELType {
    var parser = TypeParser(text: text)
    let type = try parser.parseType()
    parser.skipSpaces()
    if parser.position != parser.scalars.count {
      throw UsageError("invalid type '\(text)'")
    }
    return type
  }

  private init(text: String) {
    self.text = text
    self.scalars = Array(text.unicodeScalars)
  }

  private mutating func skipSpaces() {
    while position < scalars.count, scalars[position].properties.isWhitespace {
      position += 1
    }
  }

  private mutating func consume(_ scalar: Unicode.Scalar) -> Bool {
    skipSpaces()
    if position < scalars.count, scalars[position] == scalar {
      position += 1
      return true
    }
    return false
  }

  private mutating func parseName() throws(UsageError) -> String {
    skipSpaces()
    var name = ""
    while position < scalars.count {
      let s = scalars[position]
      guard s.properties.isAlphabetic || s.properties.numericType != nil || s == "_" || s == "." else {
        break
      }
      name.unicodeScalars.append(s)
      position += 1
    }
    if name.isEmpty {
      throw UsageError("invalid type '\(text)'")
    }
    return name
  }

  private mutating func parseType() throws(UsageError) -> CELType {
    let name = try parseName()
    var parameters: [CELType] = []
    for (open, close) in [("(", ")"), ("<", ">")] as [(Unicode.Scalar, Unicode.Scalar)] where consume(open) {
      repeat {
        parameters.append(try parseType())
      } while consume(",")
      guard consume(close) else {
        throw UsageError("invalid type '\(text)'")
      }
      break
    }
    return try make(name, parameters)
  }

  private func make(_ name: String, _ parameters: [CELType]) throws(UsageError) -> CELType {
    let simple: [String: CELType] = [
      "bool": .bool, "bytes": .bytes, "double": .double, "duration": .duration, "dyn": .dyn, "int": .int,
      "null": .null, "null_type": .null, "string": .string, "timestamp": .timestamp, "uint": .uint, "any": .any,
      "google.protobuf.Timestamp": .timestamp, "google.protobuf.Duration": .duration,
    ]
    switch (name, parameters.count) {
    case ("list", 1): return .list(parameters[0])
    case ("map", 2): return .map(key: parameters[0], value: parameters[1])
    case ("optional", 1), ("optional_type", 1): return .optional(parameters[0])
    case ("type", 1): return .type(parameters[0])
    case ("type", 0): return .type(nil)
    case (_, 0):
      if let type = simple[name] {
        return type
      }
      if ["list", "map", "optional", "optional_type"].contains(name) {
        throw UsageError("type \(name) needs parameters")
      }
      return .objectType(name)
    default:
      return .opaque(name: name, parameters: parameters)
    }
  }
}
