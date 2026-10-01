// Environment options that declare variables, object types and constants from Swift types.
// Not a ported file.

import CEL

extension Environment.Option {
  /// Declares one variable per stored property of a facts struct, typed by ``CELSchema``, and
  /// registers the object types the properties use.
  ///
  /// The facts struct is the fact schema of a stage: expressions can read exactly its properties,
  /// with their types, and nothing else.
  ///
  /// ```swift
  /// struct SelectFacts: Codable {
  ///   var pr: ChangeRequest
  ///   var trigger: String
  /// }
  /// let env = try Environment(.variables(from: SelectFacts.self))
  /// try env.compile("pr.draft || trigger == 'manual'")    // checks
  /// try env.compile("review.confidence > 0.5")            // undeclared reference to 'review'
  /// ```
  ///
  /// Evaluate with variables from ``CELEncoder/encodeVariables(_:)`` or
  /// `Variables.init(encoding:options:)`, created with the same options. Apply this option
  /// after `Environment.Option.typeProvider(_:)`, which replaces the registered types.
  ///
  /// - Parameters:
  ///   - facts: A `Decodable` struct.
  ///   - options: The key strategy and struct representation the facts are encoded with.
  /// - Returns: An option that throws `DeclarationError` when applied if the type cannot be
  ///   described (see ``CELSchema/init(for:options:)``) or does not decode as keyed values.
  public static func variables<Facts: Decodable>(
    from facts: Facts.Type, options: CELCodingOptions = CELCodingOptions()
  ) -> Environment.Option {
    // Derived here rather than when the option is applied, so the closure captures only values.
    let schema = deriveSchema(Facts.self, options: options)
    let typeName = "\(Facts.self)"
    return Environment.Option { config in
      let schema = try schema.get()
      guard let fields = schema.fields else {
        throw DeclarationError("\(typeName) does not decode as keyed values: variables(from:) needs a struct")
      }
      try register(schema, in: &config)
      config.variables += fields.map { VariableDecl(name: $0.name, type: $0.type) }
    }
  }

  /// Declares a variable whose type is derived from a Swift type, registering the object types
  /// it uses.
  ///
  /// ```swift
  /// let env = try Environment(.variable("pr", ChangeRequest.self))
  /// ```
  ///
  /// - Parameters:
  ///   - name: The variable name.
  ///   - type: A `Decodable` Swift type.
  ///   - options: The key strategy and struct representation the value is encoded with.
  /// - Returns: An option that throws `DeclarationError` when applied if the type cannot be
  ///   described.
  public static func variable<T: Decodable>(
    _ name: String, _ type: T.Type, options: CELCodingOptions = CELCodingOptions()
  ) -> Environment.Option {
    let schema = deriveSchema(T.self, options: options)
    return Environment.Option { config in
      let schema = try schema.get()
      try register(schema, in: &config)
      config.variables.append(VariableDecl(name: name, type: schema.type))
    }
  }

  /// Registers the object types of Swift structs without declaring variables, for function
  /// signatures and struct literals such as `prbar.Decision{verdict: "approve"}`.
  ///
  /// - Parameters:
  ///   - types: `Decodable` Swift types; the object types they use are registered too.
  ///   - options: The key strategy and struct representation the values are encoded with.
  /// - Returns: An option that throws `DeclarationError` when applied if a type cannot be
  ///   described.
  public static func types(
    _ types: any Decodable.Type..., options: CELCodingOptions = CELCodingOptions()
  ) -> Environment.Option {
    let schemas = types.map { deriveSchema($0, options: options) }
    return Environment.Option { config in
      for schema in schemas {
        try register(schema.get(), in: &config)
      }
    }
  }

  /// Declares a constant for each case of an enum, named `namespace.caseName` and valued as the
  /// case encodes (its raw value, or its ``CELValueRepresentable/celValue``).
  ///
  /// ```swift
  /// enum Severity: Int, Codable, CaseIterable { case info, suggestion, warning, blocker }
  /// let env = try Environment(
  ///   .variables(from: DecideFacts.self), .enumConstants(Severity.self, namespace: "severity"))
  /// try env.compile("review.max_severity <= severity.suggestion")
  /// ```
  ///
  /// - Parameters:
  ///   - type: A `CaseIterable` enum that encodes as a scalar.
  ///   - namespace: The qualifier of the constant names, such as `severity`.
  ///   - options: The options the enum's values are encoded with.
  /// - Returns: An option that throws `DeclarationError` when applied if a case does not
  ///   encode as a scalar.
  public static func enumConstants<E: CaseIterable & Encodable>(
    _ type: E.Type, namespace: String, options: CELCodingOptions = CELCodingOptions()
  ) -> Environment.Option {
    let constants = enumConstantDeclarations(E.self, namespace: namespace, options: options)
    return Environment.Option { config in
      config.variables += try constants.get()
    }
  }
}

private func deriveSchema<T: Decodable>(_ type: T.Type, options: CELCodingOptions) -> Result<CELSchema, DeclarationError> {
  do throws(DeclarationError) {
    return .success(try CELSchema(for: T.self, options: options))
  } catch {
    return .failure(error)
  }
}

private func enumConstantDeclarations<E: CaseIterable & Encodable>(
  _ type: E.Type, namespace: String, options: CELCodingOptions
) -> Result<[VariableDecl], DeclarationError> {
  var declarations: [VariableDecl] = []
  for value in E.allCases {
    let encoded: Value
    do {
      encoded = try encodeValue(value, options: options, codingPath: [])
    } catch {
      return .failure(DeclarationError("cannot encode \(E.self).\(value): \(error)"))
    }
    guard let celType = (E.self as? any CELValueRepresentable.Type)?.celType ?? scalarType(of: encoded) else {
      return .failure(DeclarationError("\(E.self).\(value) does not encode as a scalar"))
    }
    let name = namespace.isEmpty ? "\(value)" : "\(namespace).\(value)"
    declarations.append(VariableDecl(constant: name, type: celType, value: encoded))
  }
  return .success(declarations)
}

private func register(_ schema: CELSchema, in config: inout Environment.Configuration) throws {
  for structType in schema.structTypes {
    try config.registry.register(structType)
  }
}
