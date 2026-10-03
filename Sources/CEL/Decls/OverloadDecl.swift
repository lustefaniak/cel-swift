// Copyright 2023 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Ported from cel-go common/decls/decls.go (OverloadDecl and its options).

/// An error in a function or variable declaration, such as an overload collision.
public struct DeclarationError: Error, Sendable, Hashable, CustomStringConvertible {
  /// The error message, matching cel-go's.
  public var message: String

  /// Creates an error with a message.
  public init(_ message: String) {
    self.message = message
  }

  /// The error message.
  public var description: String { message }
}

/// One signature of a function: an overload id, argument and result types, and optionally its
/// runtime implementation.
///
/// Overload ids conventionally read `<function>_<argType>...` for global overloads and
/// `<receiverType>_<function>_<argType>...` for member (receiver-style) overloads.
public struct OverloadDecl: Sendable {
  /// The unique overload id, referenced by the type checker and the interpreter.
  public let id: String
  /// The argument types; for member overloads the first is the receiver type.
  public let argumentTypes: [CELType]
  /// The result type.
  public let resultType: CELType
  /// Whether the overload is called receiver-style, `target.function(args)`.
  public let isMemberFunction: Bool
  /// Usage examples, one per line.
  public internal(set) var examples: [String] = []
  /// Whether the implementation is supplied at evaluation time rather than with the declaration.
  /// `package` until a runtime way to supply it exists, see `Option.lateBinding`.
  package internal(set) var hasLateBinding = false
  /// Whether the overload accepts error and unknown arguments.
  public internal(set) var isNonStrict = false
  /// Traits the first argument must have.
  public internal(set) var operandTraits: TypeTraits = []

  var unaryOp: FunctionBinding.Unary?
  var binaryOp: FunctionBinding.Binary?
  var functionOp: FunctionBinding.Variadic?

  /// Creates an overload declaration.
  ///
  /// - Throws: ``DeclarationError`` when the options conflict, for example two bindings or a unary
  ///   binding on an overload that does not take one argument.
  public init(
    id: String,
    argumentTypes: [CELType],
    resultType: CELType,
    isMemberFunction: Bool = false,
    options: [Option] = []
  ) throws(DeclarationError) {
    self.id = id
    self.argumentTypes = argumentTypes
    self.resultType = resultType
    self.isMemberFunction = isMemberFunction
    self.storedTypeParameters = Self.collectTypeParameters(resultType: resultType, argumentTypes: argumentTypes)
    for option in options {
      try option.apply(&self)
    }
  }

  /// Whether the overload has a runtime implementation.
  public var hasBinding: Bool {
    unaryOp != nil || binaryOp != nil || functionOp != nil
  }

  /// The type parameter names used by the argument and result types, in first-use order
  /// (result type first).
  public var typeParameters: [String] {
    storedTypeParameters
  }

  /// `typeParameters`, collected once: the checker asks for every overload it considers.
  private let storedTypeParameters: [String]

  private static func collectTypeParameters(resultType: CELType, argumentTypes: [CELType]) -> [String] {
    var names: [String] = []
    func collect(_ t: CELType) {
      if case .typeParam(let name) = t, !names.contains(name) {
        names.append(name)
      }
      for p in t.parameters {
        collect(p)
      }
    }
    collect(resultType)
    argumentTypes.forEach(collect)
    return names
  }

  /// Whether `other` has the same id, receiver style and equivalent argument and result types.
  ///
  /// Operand traits and strictness are not part of the signature.
  public func signatureEquals(_ other: OverloadDecl) -> Bool {
    guard id == other.id, isMemberFunction == other.isMemberFunction,
      argumentTypes.count == other.argumentTypes.count
    else { return false }
    for (a, b) in zip(argumentTypes, other.argumentTypes) where !a.isEquivalentType(b) {
      return false
    }
    return resultType.isEquivalentType(other.resultType)
  }

  /// Whether two overloads have different but overlapping signatures, such as `list(dyn)` and
  /// `list(string)`.
  public func signatureOverlaps(_ other: OverloadDecl) -> Bool {
    guard isMemberFunction == other.isMemberFunction, argumentTypes.count == other.argumentTypes.count
    else { return false }
    return zip(argumentTypes, other.argumentTypes).allSatisfy { a, b in
      a.isAssignable(from: b) || b.isAssignable(from: a)
    }
  }

  // MARK: Runtime guards

  func guardedUnaryOp(functionName: String, disableTypeGuards: Bool) -> FunctionBinding.Unary? {
    guard let op = unaryOp else { return nil }
    let overload = self
    return { arg in
      if !overload.matchesRuntimeUnarySignature(disableTypeGuards, arg) {
        return maybeNoSuchOverload(functionName, [arg])
      }
      return op(arg)
    }
  }

  func guardedBinaryOp(functionName: String, disableTypeGuards: Bool) -> FunctionBinding.Binary? {
    guard let op = binaryOp else { return nil }
    let overload = self
    return { lhs, rhs in
      if !overload.matchesRuntimeBinarySignature(disableTypeGuards, lhs, rhs) {
        return maybeNoSuchOverload(functionName, [lhs, rhs])
      }
      return op(lhs, rhs)
    }
  }

  func guardedFunctionOp(functionName: String, disableTypeGuards: Bool) -> FunctionBinding.Variadic? {
    guard let op = functionOp else { return nil }
    let overload = self
    return { args in
      if !overload.matchesRuntimeSignature(disableTypeGuards, args) {
        return maybeNoSuchOverload(functionName, args)
      }
      return op(args)
    }
  }

  func matchesRuntimeUnarySignature(_ disableTypeGuards: Bool, _ arg: Value) -> Bool {
    matchRuntimeArgType(isNonStrict, disableTypeGuards, argumentTypes[0], arg)
      && matchOperandTrait(operandTraits, arg)
  }

  func matchesRuntimeBinarySignature(_ disableTypeGuards: Bool, _ lhs: Value, _ rhs: Value) -> Bool {
    matchRuntimeArgType(isNonStrict, disableTypeGuards, argumentTypes[0], lhs)
      && matchRuntimeArgType(isNonStrict, disableTypeGuards, argumentTypes[1], rhs)
      && matchOperandTrait(operandTraits, lhs)
  }

  func matchesRuntimeSignature(_ disableTypeGuards: Bool, _ args: [Value]) -> Bool {
    if args.count != argumentTypes.count {
      return false
    }
    if args.isEmpty {
      return true
    }
    for (argType, arg) in zip(argumentTypes, args)
    where !matchRuntimeArgType(isNonStrict, disableTypeGuards, argType, arg) {
      return false
    }
    return matchOperandTrait(operandTraits, args[0])
  }
}

private func matchRuntimeArgType(
  _ nonStrict: Bool, _ disableTypeGuards: Bool, _ argType: CELType, _ arg: Value
) -> Bool {
  if nonStrict && (disableTypeGuards || arg.isUnknownOrError) {
    return true
  }
  if arg.isUnknownOrError {
    return false
  }
  return disableTypeGuards || argType.isAssignableRuntime(arg)
}

private func matchOperandTrait(_ trait: TypeTraits, _ arg: Value) -> Bool {
  trait.isEmpty || arg.traits.isSuperset(of: trait) || arg.isUnknownOrError
}

/// Propagates an error or unknown argument, or produces `no such overload: name(argumentTypes)`.
///
/// Port of cel-go `decls.MaybeNoSuchOverload`.
package func maybeNoSuchOverload(_ functionName: String, _ args: [Value]) -> Value {
  var unknown: UnknownSet?
  var typeNames: [String] = []
  for arg in args {
    switch arg {
    case .error:
      return arg
    case .unknown(let u):
      unknown = UnknownSet.merge(u, unknown)
    default:
      break
    }
    typeNames.append(arg.runtimeTypeName)
  }
  if let unknown {
    return .unknown(unknown)
  }
  return .error(message: "no such overload: \(functionName)(\(typeNames.joined(separator: ", ")))")
}

extension OverloadDecl {
  /// A configuration step applied when an ``OverloadDecl`` is created.
  public struct Option: Sendable {
    let apply: @Sendable (inout OverloadDecl) throws(DeclarationError) -> Void

    /// Documents the overload with usage examples.
    public static func examples(_ examples: String...) -> Option {
      Option { $0.examples = examples }
    }

    /// Provides a one-argument implementation, guarded at runtime by the declared signature.
    public static func unaryBinding(_ binding: @escaping FunctionBinding.Unary) -> Option {
      Option { (o: inout OverloadDecl) throws(DeclarationError) in
        if o.hasBinding {
          throw DeclarationError("overload already has a binding: \(o.id)")
        }
        if o.argumentTypes.count != 1 {
          throw DeclarationError("unary function bound to non-unary overload: \(o.id)")
        }
        if o.hasLateBinding {
          throw DeclarationError("overload already has a late binding: \(o.id)")
        }
        o.unaryOp = binding
      }
    }

    /// Provides a two-argument implementation, guarded at runtime by the declared signature.
    public static func binaryBinding(_ binding: @escaping FunctionBinding.Binary) -> Option {
      Option { (o: inout OverloadDecl) throws(DeclarationError) in
        if o.hasBinding {
          throw DeclarationError("overload already has a binding: \(o.id)")
        }
        if o.argumentTypes.count != 2 {
          throw DeclarationError("binary function bound to non-binary overload: \(o.id)")
        }
        if o.hasLateBinding {
          throw DeclarationError("overload already has a late binding: \(o.id)")
        }
        o.binaryOp = binding
      }
    }

    /// Provides a variadic implementation, guarded at runtime by the declared signature.
    public static func functionBinding(_ binding: @escaping FunctionBinding.Variadic) -> Option {
      Option { (o: inout OverloadDecl) throws(DeclarationError) in
        if o.hasBinding {
          throw DeclarationError("overload already has a binding: \(o.id)")
        }
        if o.hasLateBinding {
          throw DeclarationError("overload already has a late binding: \(o.id)")
        }
        o.functionOp = binding
      }
    }

    /// Marks the implementation as supplied at evaluation time, for functions with side effects
    /// or results that cannot be computed ahead of time; constant folding leaves their calls alone.
    ///
    /// `package`: cel-go v0.32 supplies the implementation only through the deprecated
    /// `cel.Functions` program option, which has no counterpart here, so a public marker would
    /// promise a runtime half that does not exist (`docs/decisions.md` § 11).
    package static var lateBinding: Option {
      Option { (o: inout OverloadDecl) throws(DeclarationError) in
        if o.hasBinding {
          throw DeclarationError("overload already has a binding: \(o.id)")
        }
        o.hasLateBinding = true
      }
    }

    /// Lets the overload receive error and unknown arguments. Rarely needed.
    public static var nonStrict: Option {
      Option { $0.isNonStrict = true }
    }

    /// Requires the first argument to have the given traits.
    public static func operandTraits(_ traits: TypeTraits) -> Option {
      Option { $0.operandTraits = traits }
    }
  }
}
