// Copyright 2025 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Ported from cel-go common/env/env.go (Config and its parts, Validate, SubsetMacro, TypeDesc
// String / SpecifierFormat).
//
// Only the model lives here. Turning a config into an environment (cel.FromConfig, AsCELType,
// SubsetFunction, AddVariableDecls) needs the core environment and declaration types and is left
// to the compiler wave.
//
// TODO(core): the model has no YAML dependency and belongs in `CEL` next to the environment once
// it exists; only the YAML decoding (EnvironmentConfig+YAML.swift) has to stay in this module.

/// A serializable description of a CEL environment: container, imports, standard library subset,
/// extensions, variables, functions, validators, features and limits.
///
/// This is the model of cel-go's `env.Config`, the `config.yaml` files that accompany policies.
public struct EnvironmentConfig: Sendable, Hashable {
  /// The name of the config.
  public var name: String
  /// A description of the environment.
  public var description: String
  /// The container used to resolve unqualified names.
  public var container: String
  /// Type names imported as short aliases.
  public var imports: [Import]
  /// The subset of the standard library to expose, or `nil` for the whole library.
  public var standardLibrary: LibrarySubset?
  /// The extension libraries to enable.
  public var extensions: [Extension]
  /// A message type whose fields become top-level variables, exclusive with ``variables``.
  public var contextVariable: ContextVariable?
  /// The variables in scope.
  public var variables: [Variable]
  /// Custom function declarations.
  public var functions: [Function]
  /// AST validators to run after type-checking.
  public var validators: [Validator]
  /// Feature flags.
  public var features: [Feature]
  /// Named limits.
  public var limits: [Limit]

  /// Creates an empty config.
  ///
  /// - Parameter name: The name of the config.
  public init(name: String = "") {
    self.name = name
    self.description = ""
    self.container = ""
    self.imports = []
    self.extensions = []
    self.variables = []
    self.functions = []
    self.validators = []
    self.features = []
    self.limits = []
  }

  /// Checks the config for missing names, malformed types and conflicting settings.
  ///
  /// - Throws: ``EnvironmentConfigError`` listing every problem found.
  public func validate() throws(EnvironmentConfigError) {
    var errs: [String] = []
    for imp in imports {
      errs.append(contentsOf: imp.validationErrors())
    }
    if let standardLibrary {
      errs.append(contentsOf: standardLibrary.validationErrors())
    }
    for ext in extensions {
      if case .failure(let e) = ext.versionNumberResult() {
        errs.append(e.message)
      }
    }
    if let contextVariable {
      errs.append(contentsOf: contextVariable.validationErrors())
    }
    if contextVariable != nil && !variables.isEmpty {
      errs.append("invalid config: either context variable or variables may be set, but not both")
    }
    for v in variables {
      errs.append(contentsOf: v.validationErrors())
    }
    for fn in functions {
      errs.append(contentsOf: fn.validationErrors())
    }
    for feat in features {
      errs.append(contentsOf: feat.validationErrors())
    }
    for limit in limits {
      errs.append(contentsOf: limit.validationErrors())
    }
    for val in validators {
      errs.append(contentsOf: val.validationErrors())
    }
    if !errs.isEmpty {
      throw EnvironmentConfigError(messages: errs)
    }
  }

  /// An imported type name.
  public struct Import: Sendable, Hashable {
    /// The fully qualified type name.
    public var name: String

    /// Creates an import of a fully qualified type name.
    public init(name: String) {
      self.name = name
    }

    func validationErrors() -> [String] {
      name.isEmpty ? ["invalid import: missing type name"] : []
    }
  }

  /// A variable declaration.
  public struct Variable: Sendable, Hashable {
    /// The variable name.
    public var name: String
    /// A description of the variable.
    public var description: String
    /// The variable type, or `nil` when not declared.
    ///
    /// In YAML the type is given either inline (`type_name`, `params`) or under `type`, as a
    /// structured description or a specifier string such as `map<string, int>`.
    public var type: TypeDescriptor?

    /// Creates a variable declaration.
    ///
    /// - Parameters:
    ///   - name: The variable name.
    ///   - type: The variable type.
    ///   - description: A description of the variable.
    public init(name: String, type: TypeDescriptor?, description: String = "") {
      self.name = name
      self.type = type
      self.description = description
    }

    func validationErrors() -> [String] {
      if name.isEmpty {
        return ["invalid variable: missing variable name"]
      }
      guard let type else {
        return ["invalid variable \(goQuote(name)): invalid type: nil"]
      }
      if let e = type.validationError() {
        return ["invalid variable \(goQuote(name)): \(e)"]
      }
      if type.isTypeParameter {
        return ["invalid variable \(goQuote(name)): variables cannot be type parameters"]
      }
      return []
    }
  }

  /// The message type whose fields are exposed as top-level variables.
  public struct ContextVariable: Sendable, Hashable {
    /// The fully qualified message type name.
    public var typeName: String

    /// Creates a context variable declaration.
    public init(typeName: String) {
      self.typeName = typeName
    }

    func validationErrors() -> [String] {
      typeName.isEmpty ? ["invalid context variable: missing type name"] : []
    }
  }

  /// A function declaration with one or more overloads.
  public struct Function: Sendable, Hashable {
    /// The function name.
    public var name: String
    /// A description of the function.
    public var description: String
    /// The overloads.
    public var overloads: [Overload]

    /// Creates a function declaration.
    ///
    /// - Parameters:
    ///   - name: The function name.
    ///   - description: A description of the function.
    ///   - overloads: The overloads.
    public init(name: String, description: String = "", overloads: [Overload] = []) {
      self.name = name
      self.description = description
      self.overloads = overloads
    }

    func validationErrors() -> [String] {
      if name.isEmpty {
        return ["invalid function: missing function name"]
      }
      if overloads.isEmpty {
        return ["invalid function \(goQuote(name)): missing overloads"]
      }
      return overloads.flatMap { o in
        o.validationErrors().map { "invalid function \(goQuote(name)): \($0)" }
      }
    }
  }

  /// A function overload signature.
  public struct Overload: Sendable, Hashable {
    /// The overload identifier.
    public var id: String
    /// Example expressions using the overload.
    public var examples: [String]
    /// The receiver type of a member overload, or `nil` for a global overload.
    public var target: TypeDescriptor?
    /// The argument types, excluding the receiver.
    public var arguments: [TypeDescriptor]
    /// The result type.
    public var resultType: TypeDescriptor?

    /// Creates an overload.
    ///
    /// - Parameters:
    ///   - id: The overload identifier.
    ///   - target: The receiver type of a member overload, or `nil` for a global overload.
    ///   - arguments: The argument types, excluding the receiver.
    ///   - resultType: The result type.
    ///   - examples: Example expressions using the overload.
    public init(
      id: String,
      target: TypeDescriptor? = nil,
      arguments: [TypeDescriptor] = [],
      resultType: TypeDescriptor?,
      examples: [String] = []
    ) {
      self.id = id
      self.target = target
      self.arguments = arguments
      self.resultType = resultType
      self.examples = examples
    }

    func validationErrors() -> [String] {
      if id.isEmpty {
        return ["invalid overload: missing overload id"]
      }
      var errs: [String] = []
      if let target, let e = target.validationError() {
        errs.append("invalid overload \(goQuote(id)) target: \(e)")
      }
      for (i, arg) in arguments.enumerated() {
        if let e = arg.validationError() {
          errs.append("invalid overload \(goQuote(id)) arg[\(i)]: \(e)")
        }
      }
      let returnError = resultType.map { $0.validationError() } ?? "invalid type: nil"
      if let e = returnError {
        errs.append("invalid overload \(goQuote(id)) return: \(e)")
      }
      return errs
    }
  }

  /// An extension library reference.
  public struct Extension: Sendable, Hashable {
    /// The library name or a short identifier understood by the environment, such as `strings`.
    public var name: String
    /// The version: an unsigned integer, `latest`, or empty for version 0.
    public var version: String

    /// Creates an extension reference with a version string.
    ///
    /// - Parameters:
    ///   - name: The library name.
    ///   - version: An unsigned integer, `latest`, or empty for version 0.
    public init(name: String, version: String = "") {
      self.name = name
      self.version = version
    }

    /// Creates an extension reference with a numeric version; `UInt32.max` means `latest`.
    ///
    /// - Parameters:
    ///   - name: The library name.
    ///   - versionNumber: The version, or `UInt32.max` for the latest version.
    public init(name: String, versionNumber: UInt32) {
      self.name = name
      self.version = versionNumber == UInt32.max ? "latest" : String(versionNumber)
    }

    /// The numeric version: 0 when unset and `UInt32.max` for `latest`.
    ///
    /// - Throws: ``EnvironmentConfigError`` when the name is missing or the version is not a
    ///   32-bit unsigned integer.
    public func versionNumber() throws(EnvironmentConfigError) -> UInt32 {
      try versionNumberResult().get()
    }

    func versionNumberResult() -> Result<UInt32, EnvironmentConfigError> {
      if name.isEmpty {
        return .failure(EnvironmentConfigError(messages: ["invalid extension: missing name"]))
      }
      if version == "latest" {
        return .success(UInt32.max)
      }
      if version.isEmpty {
        return .success(0)
      }
      let digitsOnly = version.unicodeScalars.allSatisfy { $0 >= "0" && $0 <= "9" }
      if digitsOnly, let v = UInt32(version) {
        return .success(v)
      }
      let reason = digitsOnly ? "value out of range" : "invalid syntax"
      return .failure(
        EnvironmentConfigError(messages: [
          "invalid extension \(goQuote(name)) version: strconv.ParseUint: parsing \(goQuote(version)): \(reason)"
        ]))
    }
  }

  /// A subset of a library, typically the standard library: macros and functions to include or
  /// exclude.
  public struct LibrarySubset: Sendable, Hashable {
    /// Whether the library is disabled entirely.
    public var isDisabled: Bool
    /// Whether the library's macros are disabled.
    public var disablesMacros: Bool
    /// Macros to include; when non-empty, ``excludedMacros`` is ignored.
    public var includedMacros: [String]
    /// Macros to exclude.
    public var excludedMacros: [String]
    /// Functions to include; overloads need only their identifier. When non-empty,
    /// ``excludedFunctions`` is ignored.
    public var includedFunctions: [Function]
    /// Functions to exclude; overloads need only their identifier.
    public var excludedFunctions: [Function]

    /// Creates a subset that includes everything.
    public init() {
      isDisabled = false
      disablesMacros = false
      includedMacros = []
      excludedMacros = []
      includedFunctions = []
      excludedFunctions = []
    }

    func validationErrors() -> [String] {
      var errs: [String] = []
      if !includedMacros.isEmpty && !excludedMacros.isEmpty {
        errs.append("invalid subset: cannot both include and exclude macros")
      }
      if !includedFunctions.isEmpty && !excludedFunctions.isEmpty {
        errs.append("invalid subset: cannot both include and exclude functions")
      }
      return errs
    }

    /// Checks the subset for conflicting include and exclude lists.
    ///
    /// - Throws: ``EnvironmentConfigError`` when both lists of macros or of functions are set.
    public func validate() throws(EnvironmentConfigError) {
      let errs = validationErrors()
      if !errs.isEmpty {
        throw EnvironmentConfigError(messages: errs)
      }
    }

    /// Returns whether the subset includes the macro with the given function name.
    ///
    /// - Parameter macroFunction: The macro's function name, such as `has` or `exists`.
    public func includesMacro(_ macroFunction: String) -> Bool {
      if isDisabled || disablesMacros {
        return false
      }
      if !includedMacros.isEmpty {
        return includedMacros.contains(macroFunction)
      }
      if !excludedMacros.isEmpty {
        return !excludedMacros.contains(macroFunction)
      }
      return true
    }
  }

  /// An AST validator reference with optional configuration.
  public struct Validator: Sendable, Hashable {
    /// The validator name, such as `cel.validator.duration`.
    public var name: String
    /// Validator-specific configuration values.
    public var config: [String: YAMLValue]

    /// Creates a validator reference.
    ///
    /// - Parameters:
    ///   - name: The validator name.
    ///   - config: Validator-specific configuration values.
    public init(name: String, config: [String: YAMLValue] = [:]) {
      self.name = name
      self.config = config
    }

    func validationErrors() -> [String] {
      name.isEmpty ? ["invalid validator: missing name"] : []
    }
  }

  /// A feature flag.
  public struct Feature: Sendable, Hashable {
    /// The feature name, such as `cel.feature.macro_call_tracking`.
    public var name: String
    /// Whether the feature is enabled.
    public var isEnabled: Bool

    /// Creates a feature flag.
    public init(name: String, isEnabled: Bool) {
      self.name = name
      self.isEnabled = isEnabled
    }

    func validationErrors() -> [String] {
      name.isEmpty ? ["invalid feature: missing name"] : []
    }
  }

  /// A named limit.
  public struct Limit: Sendable, Hashable {
    /// The limit name, such as `cel.limit.parse_recursion_depth`.
    public var name: String
    /// The limit value.
    public var value: Int

    /// Creates a named limit.
    public init(name: String, value: Int) {
      self.name = name
      self.value = value
    }

    func validationErrors() -> [String] {
      name.isEmpty ? ["invalid limit: missing name"] : []
    }
  }

  /// A serializable type: a type name with optional type parameters, or a type parameter.
  public struct TypeDescriptor: Sendable, Hashable, CustomStringConvertible {
    /// The type name, such as `int`, `list`, `google.protobuf.Timestamp`, or a type parameter name.
    public var typeName: String
    /// The type parameters, such as the element type of a list.
    public var parameters: [TypeDescriptor]
    /// Whether the descriptor names a type parameter (`~T`).
    public var isTypeParameter: Bool

    /// Creates a type descriptor.
    ///
    /// - Parameters:
    ///   - typeName: The type name.
    ///   - parameters: The type parameters.
    public init(_ typeName: String, parameters: [TypeDescriptor] = []) {
      self.typeName = typeName
      self.parameters = parameters
      self.isTypeParameter = false
    }

    /// Creates a type parameter descriptor.
    ///
    /// - Parameter name: The type parameter name, such as `T`.
    public static func typeParameter(_ name: String) -> TypeDescriptor {
      var d = TypeDescriptor(name)
      d.isTypeParameter = true
      return d
    }

    /// The descriptor in cel-go's debug form, such as `map(string,T)`.
    public var description: String {
      if parameters.isEmpty {
        return typeName
      }
      return "\(typeName)(\(parameters.map(\.description).joined(separator: ",")))"
    }

    /// The descriptor in type specifier syntax, such as `map<string, ~T>`, which
    /// ``init(parsing:)`` reads back.
    public var specifier: String {
      if isTypeParameter {
        return "~" + typeName
      }
      if parameters.isEmpty {
        return typeName
      }
      return typeName + "<" + parameters.map(\.specifier).joined(separator: ", ") + ">"
    }

    /// Checks the descriptor's name, parameter count and nesting depth (at most 100 levels).
    ///
    /// - Throws: ``EnvironmentConfigError`` describing the first problem found.
    public func validate() throws(EnvironmentConfigError) {
      if let e = validationError() {
        throw EnvironmentConfigError(messages: [e])
      }
    }

    /// The deepest nesting accepted, counting the descriptor itself: `list<int>` nests 2 levels.
    /// Validation, CEL type conversion and the checker recurse once per level on the calling
    /// thread, so untrusted configs are bounded. cel-go has no limit; see docs/divergences.md.
    static let maxNestingDepth = 100

    static let nestingError = "exceeded max nesting depth of \(maxNestingDepth)"

    /// The number of nested levels, `int` being 1, computed without recursion.
    var nestingDepth: Int {
      var result = 0
      var stack: [(TypeDescriptor, Int)] = [(self, 1)]
      while let (descriptor, depth) = stack.popLast() {
        result = Swift.max(result, depth)
        for parameter in descriptor.parameters {
          stack.append((parameter, depth + 1))
        }
      }
      return result
    }

    func validationError() -> String? {
      if nestingDepth > Self.maxNestingDepth {
        return "invalid type: " + Self.nestingError
      }
      return shapeError()
    }

    private func shapeError() -> String? {
      if typeName.isEmpty {
        return "invalid type: missing type name"
      }
      if isTypeParameter && !parameters.isEmpty {
        return "invalid type: param type cannot have parameters"
      }
      switch typeName {
      case "list":
        if parameters.count != 1 {
          return "invalid type: list expects 1 parameter, got \(parameters.count)"
        }
        return parameters[0].shapeError()
      case "map":
        if parameters.count != 2 {
          return "invalid type: map expects 2 parameters, got \(parameters.count)"
        }
        return parameters[0].shapeError() ?? parameters[1].shapeError()
      case "optional_type":
        if parameters.count != 1 {
          return "invalid type: optional_type expects 1 parameter, got \(parameters.count)"
        }
        return parameters[0].shapeError()
      case "type":
        if parameters.isEmpty {
          return nil
        }
        if parameters.count != 1 {
          return "invalid type: type expects 0 or 1 parameters, got \(parameters.count)"
        }
        return parameters[0].shapeError()
      default:
        return nil
      }
    }
  }
}

/// Problems found in an ``EnvironmentConfig``.
public struct EnvironmentConfigError: Error, Sendable, Hashable, CustomStringConvertible {
  /// The problems, one message each.
  public var messages: [String]

  /// Creates an error from problem messages.
  public init(messages: [String]) {
    self.messages = messages
  }

  /// The messages joined by newlines, as Go's `errors.Join` renders them.
  public var description: String {
    messages.joined(separator: "\n")
  }

  var message: String { description }
}
