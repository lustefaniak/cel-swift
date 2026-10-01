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

// Ported from cel-go cel/options.go (FromConfig, configToEnvOptions), common/env/env.go
// (Variable.AsCELVariable, Function.AsCELFunction, Overload.AsFunctionOption, TypeDesc.AsCELType,
// SerializeTypeDesc) and policy/config.go.

import CEL

extension Environment.Option {
  /// Declares the container, imports, standard library subset, extensions, variables,
  /// functions, features, limits and validators of an environment config (cel-go
  /// `policy.FromConfig`, i.e. `cel.FromConfig` with `ext.ExtensionOptionFactory`).
  ///
  /// Extensions are resolved by their config names (`strings`, `lists`, `bindings`, ...) to the
  /// libraries of `CELExtensions`; `optional` enables optional types.
  ///
  /// - Parameter config: The environment config, typically decoded from a `config.yaml` file.
  /// - Returns: An option that fails environment creation with cel-go's message when the config
  ///   is invalid or names an unknown type or extension.
  public static func environmentConfig(_ config: EnvironmentConfig) -> Environment.Option {
    Environment.Option { configuration in
      try configuration.apply(config)
    }
  }
}

extension Environment.Configuration {
  /// Port of cel-go `configToEnvOptions` applied in order.
  mutating func apply(_ config: EnvironmentConfig) throws {
    do {
      try config.validate()
    } catch {
      throw EnvironmentError(error.description)
    }
    if let subset = config.standardLibrary {
      if libraryNames.contains("cel.lib.std") {
        throw EnvironmentError("invalid subset of stdlib: create a custom env")
      }
      if !subset.isDisabled {
        try apply(Library.standard(subset: subset))
      }
    } else {
      try apply(Library.standard)
    }
    if !config.container.isEmpty {
      container = try container.extended(.name(config.container))
    }
    for imp in config.imports {
      container = try container.extended(.abbreviations(imp.name))
    }
    for feature in config.features {
      setFeature(feature.name, enabled: feature.isEnabled)
    }
    if let context = config.contextVariable {
      guard registry.findStructType(context.typeName) != nil,
        let fields = registry.findStructFieldNames(context.typeName)
      else {
        throw EnvironmentError("invalid context proto type: \(goQuote(context.typeName))")
      }
      for field in fields {
        if let fieldType = registry.findStructFieldType(context.typeName, fieldName: field) {
          variables.append(VariableDecl(name: field, type: fieldType.type))
        }
      }
    }
    for v in config.variables {
      variables.append(try v.asVariableDecl(registry))
    }
    for f in config.functions {
      try declare(try f.asFunctionDecl(registry))
    }
    for limit in config.limits {
      setLimit(limit.name, value: limit.value)
    }
    for v in config.validators {
      var limit: Int?
      if case .int(let l)? = v.config["limit"] {
        limit = Int(l)
      }
      if let validator = ExpressionValidator.named(v.name, limit: limit),
        !validators.contains(where: { $0.name == validator.name })
      {
        validators.append(validator)
      }
    }
    for ext in config.extensions {
      guard let version = try? ext.versionNumber() else {
        throw EnvironmentError("invalid extension version: \(ext.name) - \(ext.version)")
      }
      if ext.name == "optional" {
        try apply(Library.optionalTypes(version: version))
        continue
      }
      guard let lib = PolicyExtensions.resolve(ext.name, version: version) else {
        throw EnvironmentError("unrecognized extension: \(ext.name)")
      }
      try apply(lib)
    }
  }

  /// Applies a feature flag by name (cel-go `features`); unknown names are ignored.
  mutating func setFeature(_ name: String, enabled: Bool) {
    switch name {
    case "cel.feature.macro_call_tracking": macroCallTracking = enabled
    case "cel.feature.cross_type_numeric_comparisons": crossTypeNumericComparisons = enabled
    case "cel.feature.backtick_escape_syntax": identifierEscapeSyntax = enabled
    case "cel.feature.json_field_names": jsonFieldNames = enabled
    default: break
    }
  }

  /// Applies a limit by name (cel-go `setLimit`); unknown names are ignored. A negative value
  /// removes the limit.
  ///
  /// `cel.limit.max_ast_depth` is accepted and ignored: cel-go only records it for configs that
  /// round-trip and for converting protobuf ASTs, neither of which applies here.
  mutating func setLimit(_ name: String, value: Int) {
    let value = value < 0 ? -1 : value
    switch name {
    case "cel.limit.regex_program_size": regexProgramSizeLimit = value
    case "cel.limit.expression_code_points": expressionSizeCodePointLimit = value
    case "cel.limit.parse_error_recovery": parserErrorRecoveryLimit = value
    case "cel.limit.parse_recursion_depth": parserRecursionLimit = value
    case "cel.limit.expression_node_count": expressionNodeCountLimit = value
    default: break
    }
  }
}

extension EnvironmentConfig.Variable {
  /// The variable declaration (cel-go `Variable.AsCELVariable`).
  package func asVariableDecl(_ provider: any TypeProvider) throws -> VariableDecl {
    let errs = validationErrors()
    if !errs.isEmpty {
      throw EnvironmentError(errs.joined(separator: "\n"))
    }
    guard let type else {
      throw EnvironmentError("invalid variable \(goQuote(name)): invalid type: nil")
    }
    do {
      return VariableDecl(name: name, type: try type.asCELType(provider), documentation: description)
    } catch {
      throw EnvironmentError("invalid variable \(goQuote(name)): \(error.description)")
    }
  }
}

extension EnvironmentConfig.Function {
  /// The function declaration, without implementations (cel-go `Function.AsCELFunction`).
  package func asFunctionDecl(_ provider: any TypeProvider) throws -> FunctionDecl {
    let errs = validationErrors()
    if !errs.isEmpty {
      throw EnvironmentError(errs.joined(separator: "\n"))
    }
    var options: [FunctionDecl.Option] = []
    for o in overloads {
      do {
        options.append(try o.asFunctionOption(provider))
      } catch {
        throw EnvironmentError("invalid function \(goQuote(name)): \(error.description)")
      }
    }
    if !description.isEmpty {
      options.append(.documentation(description))
    }
    do {
      return try FunctionDecl(name, options: options)
    } catch {
      throw EnvironmentError("\(error)")
    }
  }
}

extension EnvironmentConfig.Overload {
  /// The overload as a function declaration option (cel-go `Overload.AsFunctionOption`).
  func asFunctionOption(_ provider: any TypeProvider) throws(EnvironmentError) -> FunctionDecl.Option {
    let errs = validationErrors()
    if !errs.isEmpty {
      throw EnvironmentError(errs.joined(separator: "\n"))
    }
    var messages: [String] = []
    var args: [CELType] = []
    for a in arguments {
      do {
        args.append(try a.asCELType(provider))
      } catch {
        messages.append(error.description)
      }
    }
    var result = CELType.dyn
    if let resultType {
      do {
        result = try resultType.asCELType(provider)
      } catch {
        messages.append(error.description)
      }
    }
    if let target {
      do {
        args.insert(try target.asCELType(provider), at: 0)
      } catch {
        messages.append(error.description)
        throw EnvironmentError(messages.joined(separator: "\n"))
      }
      if !messages.isEmpty {
        throw EnvironmentError(messages.joined(separator: "\n"))
      }
      return .memberOverload(id, argTypes: args, resultType: result)
    }
    if !messages.isEmpty {
      throw EnvironmentError(messages.joined(separator: "\n"))
    }
    // Examples are documentation only; `OverloadDecl.Option.examples` is variadic and cannot
    // take the decoded array, so they are not carried over.
    return .overload(id, argTypes: args, resultType: result)
  }
}

extension EnvironmentConfig.TypeDescriptor {
  /// The CEL type the descriptor names (cel-go `TypeDesc.AsCELType`).
  ///
  /// - Throws: ``EnvironmentError`` for malformed descriptors and undefined type names.
  package func asCELType(_ provider: any TypeProvider) throws(EnvironmentError) -> CELType {
    if let e = validationError() {
      throw EnvironmentError(e)
    }
    switch typeName {
    case "dyn": return .dyn
    case "duration": return .duration
    case "timestamp": return .timestamp
    case "any": return .any
    case "null", "null_type": return .null
    case "bool_wrapper": return .wrapper(.bool)
    case "bytes_wrapper": return .wrapper(.bytes)
    case "double_wrapper": return .wrapper(.double)
    case "int_wrapper": return .wrapper(.int)
    case "uint_wrapper": return .wrapper(.uint)
    case "string_wrapper": return .wrapper(.string)
    case "map":
      return .map(key: try parameters[0].asCELType(provider), value: try parameters[1].asCELType(provider))
    case "list":
      return .list(try parameters[0].asCELType(provider))
    case "optional_type":
      return .optional(try parameters[0].asCELType(provider))
    case "type":
      if parameters.isEmpty {
        return .type(nil)
      }
      return .type(try parameters[0].asCELType(provider))
    default:
      if isTypeParameter {
        return .typeParam(typeName)
      }
      if case .type(let msgType?)? = provider.findStructType(typeName) {
        return msgType
      }
      guard let ident = provider.findIdent(typeName) else {
        throw EnvironmentError("undefined type name: \(goQuote(typeName))")
      }
      if case .type(let t) = ident, parameters.isEmpty {
        return t
      }
      var params: [CELType] = []
      for p in parameters {
        params.append(try p.asCELType(provider))
      }
      return .opaque(name: typeName, parameters: params)
    }
  }

  /// The serializable form of a CEL type (cel-go `SerializeTypeDesc`).
  package init(_ type: CELType) {
    switch type {
    case .typeParam(let name):
      self = .typeParameter(name)
      return
    case .wrapper(let inner):
      let names: [CELType: String] = [
        .bool: "google.protobuf.BoolValue", .bytes: "google.protobuf.BytesValue",
        .double: "google.protobuf.DoubleValue", .int: "google.protobuf.Int64Value",
        .string: "google.protobuf.StringValue", .uint: "google.protobuf.UInt64Value",
      ]
      if let name = names[inner] {
        self.init(name)
        return
      }
    default:
      break
    }
    var name = type.runtimeTypeName
    switch type {
    case .error: name = "*error*"
    case .unknown: name = "*unknown*"
    default: break
    }
    self.init(name, parameters: type.parameters.map { EnvironmentConfig.TypeDescriptor($0) })
  }
}
