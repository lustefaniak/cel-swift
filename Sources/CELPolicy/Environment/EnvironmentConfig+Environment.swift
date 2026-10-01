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
//
// Not ported: AST validators named in the config (they need cel-go's validator framework, which
// the core does not have yet; see docs/divergences.md), the `context_variable` declaration (no
// message descriptor walk without the public API), and the `max_ast_depth` /
// `regex_program_size` limits.

import CEL

extension PolicyEnvironment {
  /// Extends the environment with the declarations, libraries and options of a config (cel-go
  /// `cel.FromConfig` with `ext.ExtensionOptionFactory`, i.e. `policy.FromConfig`).
  ///
  /// - Throws: ``EnvironmentError`` with cel-go's message.
  package mutating func apply(_ config: EnvironmentConfig) throws {
    do {
      try config.validate()
    } catch {
      throw EnvironmentError(error.description)
    }
    var next = self
    if let subset = config.standardLibrary {
      if next.hasLibrary("cel.lib.std") {
        throw EnvironmentError("invalid subset of stdlib: create a custom env")
      }
      if !subset.isDisabled {
        try next.addLibrary(.standard(subset: subset))
      }
    } else {
      try next.addLibrary(.standard())
    }
    if !config.container.isEmpty {
      try next.wrapping { try $0.setContainer(config.container) }
    }
    for imp in config.imports {
      try next.wrapping { try $0.addAbbreviations([imp.name]) }
    }
    for feature in config.features {
      next.setFeature(feature.name, enabled: feature.isEnabled)
    }
    if let context = config.contextVariable {
      if next.provider.findStructType(context.typeName) == nil {
        throw EnvironmentError("invalid context proto type: \(goQuote(context.typeName))")
      }
      try next.declareContext(typeName: context.typeName)
    }
    if !config.variables.isEmpty {
      let provider = next.provider
      let vars = try config.variables.map { try $0.asVariableDecl(provider) }
      try next.wrapping { try $0.declare(variables: vars) }
    }
    if !config.functions.isEmpty {
      let provider = next.provider
      let fns = try config.functions.map { try $0.asFunctionDecl(provider) }
      try next.wrapping { try $0.declare(functions: fns) }
    }
    for limit in config.limits {
      next.setLimit(limit.name, value: limit.value)
    }
    for ext in config.extensions {
      let version = (try? ext.versionNumber()) ?? 0
      if ext.name == "optional" {
        try next.addLibrary(.optionalTypes(version: version))
        continue
      }
      guard let lib = next.resolveExtension(ext.name, version: version) else {
        throw EnvironmentError("unrecognized extension: \(ext.name)")
      }
      try next.addLibrary(lib)
    }
    self = next
  }

  /// Runs a mutation and rethrows declaration errors as environment errors.
  private mutating func wrapping(_ body: (inout PolicyEnvironment) throws -> Void) throws {
    do {
      try body(&self)
    } catch let error as EnvironmentError {
      throw error
    } catch let error as DeclarationError {
      throw EnvironmentError(error.description)
    } catch {
      throw EnvironmentError("\(error)")
    }
  }

  func resolveExtension(_ name: String, version: UInt32) -> Library? {
    if let lib = PolicyExtensions.resolve(name, version: version) {
      return lib
    }
    return extensionResolver?(name, version)
  }

  /// Declares the fields of a message type as variables (cel-go `DeclareContextProto`).
  mutating func declareContext(typeName: String) throws {
    guard let fields = provider.findStructFieldNames(typeName) else {
      throw EnvironmentError("invalid context proto type: \(goQuote(typeName))")
    }
    var vars: [VariableDecl] = []
    for field in fields {
      guard let fieldType = provider.findStructFieldType(typeName, fieldName: field) else {
        continue
      }
      vars.append(VariableDecl(name: field, type: fieldType.type))
    }
    try wrapping { try $0.declare(variables: vars) }
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

extension PolicyEnvironment {
  /// Applies a feature flag by name (cel-go `features`); unknown names are ignored.
  package mutating func setFeature(_ name: String, enabled: Bool) {
    switch name {
    case "cel.feature.macro_call_tracking":
      if enabled {
        enableMacroCallTracking()
      }
    case "cel.feature.cross_type_numeric_comparisons":
      addCheckerOption(.crossTypeNumericComparisons(enabled))
    case "cel.feature.backtick_escape_syntax":
      addParserOption(.enableIdentEscapeSyntax(enabled))
    case "cel.feature.json_field_names":
      addCheckerOption(.jsonFieldNames(enabled))
    default:
      break
    }
  }

  /// Applies a limit by name (cel-go `setLimit`); unknown names are ignored.
  package mutating func setLimit(_ name: String, value: Int) {
    switch name {
    case "cel.limit.expression_code_points":
      addParserOption(.expressionSizeCodePointLimit(value))
    case "cel.limit.parse_error_recovery":
      addParserOption(.errorRecoveryLimit(value))
    case "cel.limit.parse_recursion_depth":
      addParserOption(.maxRecursionDepth(value))
    case "cel.limit.expression_node_count":
      addParserOption(.maxExpressionNodeCount(value))
    default:
      break
    }
  }
}
