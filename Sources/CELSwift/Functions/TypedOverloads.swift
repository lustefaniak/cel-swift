// Function overloads implemented by Swift closures over typed arguments: the CEL signature is
// derived from the closure's parameter and result types, and arguments and results go through
// CELDecoder and CELEncoder. Not a ported file.

import CEL

extension FunctionDecl.Option {
  /// A global overload with no arguments, implemented by a Swift closure.
  ///
  /// The result type is derived from `R` with ``CELSchema``.
  ///
  /// - Parameters:
  ///   - id: The overload id, unique across the environment, such as `now_timestamp`.
  ///   - options: How struct arguments and results are encoded.
  ///   - implementation: The implementation; an error it throws becomes the call's error value.
  /// - Throws: `DeclarationError` when `R` cannot be described.
  public static func overload<R: Encodable>(
    _ id: String, options: CELCodingOptions = CELCodingOptions(),
    _ implementation: @escaping @Sendable () throws -> R
  ) throws(DeclarationError) -> FunctionDecl.Option {
    let resultType = try CELSchema.celType(of: R.self, options: options)
    let call: any TypedCall = NullaryCall(id: id, options: options, implementation: implementation)
    return .overload(id, argumentTypes: [], resultType: resultType, .functionBinding { call.call($0) })
  }

  /// A global overload with one argument, implemented by a Swift closure.
  ///
  /// ```swift
  /// let env = try Environment(
  ///   .function("isBot", .overload("is_bot_string") { (login: String) in login.hasSuffix("[bot]") }))
  /// ```
  ///
  /// The argument and result types are derived from `A` and `R` with ``CELSchema``; the closure's
  /// parameters need explicit types. Struct types must be registered with the environment, for
  /// example by `Environment.Option.variables(from:options:)` or
  /// `Environment.Option.types(_:options:)`.
  ///
  /// - Parameters:
  ///   - id: The overload id, unique across the environment, such as `is_bot_string`.
  ///   - options: How struct arguments and results are encoded.
  ///   - implementation: The implementation; an error it throws becomes the call's error value.
  /// - Throws: `DeclarationError` when `A` or `R` cannot be described.
  public static func overload<A: Decodable, R: Encodable>(
    _ id: String, options: CELCodingOptions = CELCodingOptions(),
    _ implementation: @escaping @Sendable (A) throws -> R
  ) throws(DeclarationError) -> FunctionDecl.Option {
    try unary(id, member: false, options: options, implementation)
  }

  /// A global overload with two arguments, implemented by a Swift closure.
  ///
  /// ```swift
  /// let env = try Environment(
  ///   .function("glob", .overload("glob_string_string") { (path: String, pattern: String) in
  ///     GlobMatcher.matches(path, pattern)
  ///   }))
  /// ```
  ///
  /// - Parameters:
  ///   - id: The overload id, unique across the environment.
  ///   - options: How struct arguments and results are encoded.
  ///   - implementation: The implementation; an error it throws becomes the call's error value.
  /// - Throws: `DeclarationError` when an argument or result type cannot be described.
  public static func overload<A: Decodable, B: Decodable, R: Encodable>(
    _ id: String, options: CELCodingOptions = CELCodingOptions(),
    _ implementation: @escaping @Sendable (A, B) throws -> R
  ) throws(DeclarationError) -> FunctionDecl.Option {
    try binary(id, member: false, options: options, implementation)
  }

  /// A global overload with three arguments, implemented by a Swift closure.
  ///
  /// - Parameters:
  ///   - id: The overload id, unique across the environment.
  ///   - options: How struct arguments and results are encoded.
  ///   - implementation: The implementation; an error it throws becomes the call's error value.
  /// - Throws: `DeclarationError` when an argument or result type cannot be described.
  public static func overload<A: Decodable, B: Decodable, C: Decodable, R: Encodable>(
    _ id: String, options: CELCodingOptions = CELCodingOptions(),
    _ implementation: @escaping @Sendable (A, B, C) throws -> R
  ) throws(DeclarationError) -> FunctionDecl.Option {
    try ternary(id, member: false, options: options, implementation)
  }

  /// A member overload called on its first argument, `a.function()`, implemented by a Swift
  /// closure.
  ///
  /// ```swift
  /// let env = try Environment(
  ///   .variables(from: SelectFacts.self),
  ///   .function("touches", .memberOverload("change_touches_string") { (pr: ChangeRequest, path: String) in
  ///     pr.files.contains { $0.hasPrefix(path) }
  ///   }))
  /// try env.compile("pr.touches('migrations/')")
  /// ```
  ///
  /// - Parameters:
  ///   - id: The overload id, unique across the environment.
  ///   - options: How struct arguments and results are encoded.
  ///   - implementation: The implementation; its first parameter is the receiver.
  /// - Throws: `DeclarationError` when an argument or result type cannot be described.
  public static func memberOverload<A: Decodable, R: Encodable>(
    _ id: String, options: CELCodingOptions = CELCodingOptions(),
    _ implementation: @escaping @Sendable (A) throws -> R
  ) throws(DeclarationError) -> FunctionDecl.Option {
    try unary(id, member: true, options: options, implementation)
  }

  /// A member overload with one argument besides the receiver, `a.function(b)`, implemented by a
  /// Swift closure.
  ///
  /// - Parameters:
  ///   - id: The overload id, unique across the environment.
  ///   - options: How struct arguments and results are encoded.
  ///   - implementation: The implementation; its first parameter is the receiver.
  /// - Throws: `DeclarationError` when an argument or result type cannot be described.
  public static func memberOverload<A: Decodable, B: Decodable, R: Encodable>(
    _ id: String, options: CELCodingOptions = CELCodingOptions(),
    _ implementation: @escaping @Sendable (A, B) throws -> R
  ) throws(DeclarationError) -> FunctionDecl.Option {
    try binary(id, member: true, options: options, implementation)
  }

  /// A member overload with two arguments besides the receiver, `a.function(b, c)`, implemented
  /// by a Swift closure.
  ///
  /// - Parameters:
  ///   - id: The overload id, unique across the environment.
  ///   - options: How struct arguments and results are encoded.
  ///   - implementation: The implementation; its first parameter is the receiver.
  /// - Throws: `DeclarationError` when an argument or result type cannot be described.
  public static func memberOverload<A: Decodable, B: Decodable, C: Decodable, R: Encodable>(
    _ id: String, options: CELCodingOptions = CELCodingOptions(),
    _ implementation: @escaping @Sendable (A, B, C) throws -> R
  ) throws(DeclarationError) -> FunctionDecl.Option {
    try ternary(id, member: true, options: options, implementation)
  }

  private static func unary<A: Decodable, R: Encodable>(
    _ id: String, member: Bool, options: CELCodingOptions, _ implementation: @escaping @Sendable (A) throws -> R
  ) throws(DeclarationError) -> FunctionDecl.Option {
    let argumentTypes = [try CELSchema.celType(of: A.self, options: options)]
    let resultType = try CELSchema.celType(of: R.self, options: options)
    let call: any TypedCall = UnaryCall(id: id, options: options, implementation: implementation)
    let binding = OverloadDecl.Option.unaryBinding { call.call([$0]) }
    return member
      ? .memberOverload(id, argumentTypes: argumentTypes, resultType: resultType, binding)
      : .overload(id, argumentTypes: argumentTypes, resultType: resultType, binding)
  }

  private static func binary<A: Decodable, B: Decodable, R: Encodable>(
    _ id: String, member: Bool, options: CELCodingOptions, _ implementation: @escaping @Sendable (A, B) throws -> R
  ) throws(DeclarationError) -> FunctionDecl.Option {
    let argumentTypes = [
      try CELSchema.celType(of: A.self, options: options), try CELSchema.celType(of: B.self, options: options),
    ]
    let resultType = try CELSchema.celType(of: R.self, options: options)
    let call: any TypedCall = BinaryCall(id: id, options: options, implementation: implementation)
    let binding = OverloadDecl.Option.binaryBinding { call.call([$0, $1]) }
    return member
      ? .memberOverload(id, argumentTypes: argumentTypes, resultType: resultType, binding)
      : .overload(id, argumentTypes: argumentTypes, resultType: resultType, binding)
  }

  private static func ternary<A: Decodable, B: Decodable, C: Decodable, R: Encodable>(
    _ id: String, member: Bool, options: CELCodingOptions,
    _ implementation: @escaping @Sendable (A, B, C) throws -> R
  ) throws(DeclarationError) -> FunctionDecl.Option {
    let argumentTypes = [
      try CELSchema.celType(of: A.self, options: options), try CELSchema.celType(of: B.self, options: options),
      try CELSchema.celType(of: C.self, options: options),
    ]
    let resultType = try CELSchema.celType(of: R.self, options: options)
    let call: any TypedCall = TernaryCall(id: id, options: options, implementation: implementation)
    let binding = OverloadDecl.Option.functionBinding { call.call($0) }
    return member
      ? .memberOverload(id, argumentTypes: argumentTypes, resultType: resultType, binding)
      : .overload(id, argumentTypes: argumentTypes, resultType: resultType, binding)
  }
}

/// A typed implementation behind an existential, so the bindings' `@Sendable` closures capture a
/// value rather than the generic argument and result types.
private protocol TypedCall: Sendable {
  func call(_ args: [Value]) -> Value
}

private struct NullaryCall<R: Encodable>: TypedCall {
  let id: String
  let options: CELCodingOptions
  let implementation: @Sendable () throws -> R

  func call(_ args: [Value]) -> Value {
    invoke(id, options) { try implementation() }
  }
}

private struct UnaryCall<A: Decodable, R: Encodable>: TypedCall {
  let id: String
  let options: CELCodingOptions
  let implementation: @Sendable (A) throws -> R

  func call(_ args: [Value]) -> Value {
    guard args.count == 1 else { return arityError(id, expected: 1, args.count) }
    return invoke(id, options) { try implementation(argument(A.self, args[0], 0, id, options)) }
  }
}

private struct BinaryCall<A: Decodable, B: Decodable, R: Encodable>: TypedCall {
  let id: String
  let options: CELCodingOptions
  let implementation: @Sendable (A, B) throws -> R

  func call(_ args: [Value]) -> Value {
    guard args.count == 2 else { return arityError(id, expected: 2, args.count) }
    return invoke(id, options) {
      try implementation(argument(A.self, args[0], 0, id, options), argument(B.self, args[1], 1, id, options))
    }
  }
}

private struct TernaryCall<A: Decodable, B: Decodable, C: Decodable, R: Encodable>: TypedCall {
  let id: String
  let options: CELCodingOptions
  let implementation: @Sendable (A, B, C) throws -> R

  func call(_ args: [Value]) -> Value {
    guard args.count == 3 else { return arityError(id, expected: 3, args.count) }
    return invoke(id, options) {
      try implementation(
        argument(A.self, args[0], 0, id, options), argument(B.self, args[1], 1, id, options),
        argument(C.self, args[2], 2, id, options))
    }
  }
}

private func arityError(_ id: String, expected: Int, _ count: Int) -> Value {
  .error(EvalError("no such overload: \(id) takes \(expected) arguments, got \(count)"))
}

/// Decodes argument `index` of overload `id`, reporting a failure as an ``EvalError``.
private func argument<T: Decodable>(
  _ type: T.Type, _ value: Value, _ index: Int, _ id: String, _ options: CELCodingOptions
) throws -> T {
  do {
    return try decodeValue(T.self, from: value, options: options, codingPath: [])
  } catch let error as DecodingError {
    throw EvalError("\(id): argument \(index + 1): \(error.message)")
  }
}

/// Runs an implementation and encodes its result; thrown errors become error values.
private func invoke<R: Encodable>(_ id: String, _ options: CELCodingOptions, _ body: () throws -> R) -> Value {
  do {
    return try encodeValue(try body(), options: options, codingPath: [])
  } catch let error as EvalError {
    return .error(error)
  } catch let error as EncodingError {
    return .error(EvalError("\(id): cannot encode the result: \(error.message)"))
  } catch {
    return .error(EvalError("\(error)"))
  }
}

extension DecodingError {
  /// The debug description of the error's context, with its coding path.
  var message: String {
    let context: DecodingError.Context
    switch self {
    case .typeMismatch(_, let c), .valueNotFound(_, let c), .keyNotFound(_, let c), .dataCorrupted(let c):
      context = c
    @unknown default:
      return "\(self)"
    }
    return codingPathPrefix(context.codingPath) + context.debugDescription
  }
}

extension EncodingError {
  /// The debug description of the error's context, with its coding path.
  var message: String {
    switch self {
    case .invalidValue(_, let context):
      return codingPathPrefix(context.codingPath) + context.debugDescription
    @unknown default:
      return "\(self)"
    }
  }
}

/// `a.b[0]: ` for a coding path, empty for the top level.
func codingPathPrefix(_ path: [any CodingKey]) -> String {
  guard !path.isEmpty else { return "" }
  var result = ""
  for key in path {
    if let index = key.intValue, key is IndexKey {
      result += "[\(index)]"
    } else {
      result += result.isEmpty ? key.stringValue : ".\(key.stringValue)"
    }
  }
  return result + ": "
}
