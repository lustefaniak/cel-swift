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
// Ported from cel-go common/decls/decls.go (FunctionDecl and its options).

/// A singleton implementation shared by all overloads of a function. A class so merges can tell
/// whether two declarations carry the same singleton, as cel-go compares pointers.
final class SingletonBinding: Sendable {
  let binding: FunctionBinding

  init(_ binding: FunctionBinding) {
    self.binding = binding
  }
}

/// A function declaration: a name, its overloads and optionally a singleton implementation shared
/// by all overloads.
///
/// ```swift
/// let shout = try FunctionDecl("shout",
///   .memberOverload("string_shout", argTypes: [.string], resultType: .string,
///     .unaryBinding { value in
///       guard case .string(let s) = value else { return .error(EvalError("no such overload")) }
///       return .string(s.uppercased())
///     }))
/// ```
public struct FunctionDecl: Sendable {
  enum DeclarationState: Sendable {
    case unset, disabled, enabled
  }

  /// The function name, such as `contains`, `math.least` or the operator name `_+_`.
  public let name: String
  /// The description of the function's purpose.
  public internal(set) var documentation: String = ""
  /// Whether runtime type guards on direct overload calls are disabled, a performance option
  /// for functions whose implementation checks its arguments anyway.
  public internal(set) var disableTypeGuards = false

  var overloadsByID: [String: OverloadDecl] = [:]
  /// The overload declarations in declaration order.
  public internal(set) var overloads: [OverloadDecl] = []
  var singleton: SingletonBinding?
  var state = DeclarationState.unset

  /// Creates a function declaration.
  ///
  /// - Throws: ``DeclarationError`` if the function has no overloads, if overloads collide, or if
  ///   bindings are defined twice.
  public init(_ name: String, _ options: Option...) throws {
    try self.init(name, options: options)
  }

  /// Creates a function declaration from an array of options.
  public init(_ name: String, options: [Option]) throws {
    self.name = name
    for option in options {
      try option.apply(&self)
    }
    if overloads.isEmpty {
      throw DeclarationError("function \(name) must have at least one overload")
    }
  }

  /// Whether the runtime implementation is provided but the declaration is hidden from
  /// expressions, the safe way to deprecate a function.
  public var isDeclarationDisabled: Bool {
    state == .disabled
  }

  /// Whether the function has a singleton implementation.
  public var hasSingletonBinding: Bool {
    singleton != nil
  }

  /// Whether any overload is bound at evaluation time.
  public var hasLateBinding: Bool {
    overloads.contains { $0.hasLateBinding }
  }

  /// Returns the overload with the given id.
  public func overload(withID id: String) -> OverloadDecl? {
    overloadsByID[id]
  }

  /// Adds an overload, rejecting collisions with existing signatures.
  ///
  /// Redeclaring an overload with an identical signature is allowed and may supply its binding.
  public mutating func addOverload(_ overload: OverloadDecl) throws {
    for existing in overloads {
      let oID = existing.id
      if oID != overload.id && existing.signatureOverlaps(overload) {
        throw DeclarationError(
          "overload signature collision in function \(name): \(oID) collides with \(overload.id)")
      }
      if oID == overload.id {
        if existing.signatureEquals(overload) && existing.isNonStrict == overload.isNonStrict {
          var replacement = existing
          if overload.hasBinding {
            replacement = overload
          }
          if !overload.examples.isEmpty && existing.examples != overload.examples {
            replacement.examples = overload.examples
          }
          replaceOverload(replacement)
          return
        }
        throw DeclarationError(
          "overload redefinition in function. \(name): \(oID) has multiple definitions")
      }
      if overload.hasLateBinding != existing.hasLateBinding {
        throw DeclarationError(
          "overload with late binding cannot be added to function \(name): cannot mix late and non-late bindings"
        )
      }
    }
    overloads.append(overload)
    overloadsByID[overload.id] = overload
  }

  private mutating func replaceOverload(_ overload: OverloadDecl) {
    overloadsByID[overload.id] = overload
    if let index = overloads.firstIndex(where: { $0.id == overload.id }) {
      overloads[index] = overload
    }
  }

  /// Combines this declaration with another declaration of the same function.
  ///
  /// Overloads of `other` are added after this declaration's; they must not collide, and the two
  /// declarations must not carry different singleton implementations.
  public func merging(_ other: FunctionDecl) throws -> FunctionDecl {
    guard name == other.name else {
      throw DeclarationError("cannot merge unrelated functions. \(goQuote(name)) and \(goQuote(other.name))")
    }
    var merged = self
    merged.disableTypeGuards = disableTypeGuards && other.disableTypeGuards
    if other.state != .unset {
      merged.state = other.state
    }
    if !other.documentation.isEmpty && documentation != other.documentation {
      merged.documentation = other.documentation
    }
    for overload in other.overloads {
      do {
        try merged.addOverload(overload)
      } catch let error as DeclarationError {
        throw DeclarationError("function declaration merge failed: \(error.message)")
      }
    }
    if let otherSingleton = other.singleton {
      if let existing = merged.singleton, existing !== otherSingleton {
        throw DeclarationError("function already has a singleton binding: \(name)")
      }
      merged.singleton = otherSingleton
    }
    return merged
  }

  /// Returns a declaration with only the overloads `selector` accepts, or `nil` if none remain.
  public func subset(_ selector: (OverloadDecl) -> Bool) -> FunctionDecl? {
    var copy = self
    copy.overloads = overloads.filter(selector)
    if copy.overloads.isEmpty {
      return nil
    }
    copy.overloadsByID = Dictionary(uniqueKeysWithValues: copy.overloads.map { ($0.id, $0) })
    return copy
  }

  /// Returns a declaration with only the overloads whose ids are listed, or `nil` if none remain.
  public func including(overloadIDs ids: [String]) -> FunctionDecl? {
    subset { ids.contains($0.id) }
  }

  /// Returns a declaration without the overloads whose ids are listed, or `nil` if none remain.
  public func excluding(overloadIDs ids: [String]) -> FunctionDecl? {
    subset { !ids.contains($0.id) }
  }

  /// The runtime bindings of the function, keyed by overload id and function name.
  ///
  /// - One overload binding is also registered under the function name.
  /// - Several overload bindings get an extra entry under the function name that dispatches on the
  ///   runtime argument types, as parse-only evaluation needs.
  /// - A singleton binding is registered under the function name only.
  ///
  /// - Throws: ``DeclarationError`` if a singleton is combined with overload or late bindings.
  public func bindings() throws -> [FunctionBinding] {
    var result: [FunctionBinding] = []
    var nonStrict = false
    var hasLateBinding = false
    for o in overloads {
      hasLateBinding = hasLateBinding || o.hasLateBinding
      if o.hasBinding {
        result.append(
          FunctionBinding(
            name: o.id,
            operandTraits: o.operandTraits,
            unary: o.guardedUnaryOp(functionName: name, disableTypeGuards: disableTypeGuards),
            binary: o.guardedBinaryOp(functionName: name, disableTypeGuards: disableTypeGuards),
            function: o.guardedFunctionOp(functionName: name, disableTypeGuards: disableTypeGuards),
            isNonStrict: o.isNonStrict))
        nonStrict = nonStrict || o.isNonStrict
      }
    }
    if let singleton {
      if !result.isEmpty {
        throw DeclarationError("singleton function incompatible with specialized overloads: \(name)")
      }
      if hasLateBinding {
        throw DeclarationError("singleton function incompatible with late bindings: \(name)")
      }
      var binding = singleton.binding
      binding.name = name
      binding.isNonStrict = false
      return [binding]
    }
    if result.isEmpty {
      return result
    }
    if result.count == 1 {
      if result[0].name == name {
        return result
      }
      var byName = result[0]
      byName.name = name
      return result + [byName]
    }
    let functionName = name
    let ordered = overloads
    let disableGuards = disableTypeGuards
    let dispatch: FunctionBinding.Variadic = { args in
      for o in ordered {
        switch args.count {
        case 1:
          if let op = o.unaryOp, o.matchesRuntimeSignature(disableGuards, args) {
            return op(args[0])
          }
        case 2:
          if let op = o.binaryOp, o.matchesRuntimeSignature(disableGuards, args) {
            return op(args[0], args[1])
          }
        default:
          break
        }
        if let op = o.functionOp, o.matchesRuntimeSignature(disableGuards, args) {
          return op(args)
        }
      }
      return maybeNoSuchOverload(functionName, args)
    }
    return result + [FunctionBinding(name: name, function: dispatch, isNonStrict: nonStrict)]
  }
}

extension FunctionDecl {
  /// A configuration step applied when a ``FunctionDecl`` is created.
  public struct Option: Sendable {
    let apply: @Sendable (inout FunctionDecl) throws -> Void

    /// Describes the function's purpose; the lines are joined with newlines.
    public static func documentation(_ lines: String...) -> Option {
      Option { $0.documentation = lines.joined(separator: "\n") }
    }

    /// Disables the runtime type guards on direct overload calls; argument checks during dynamic
    /// dispatch remain.
    public static func disableTypeGuards(_ value: Bool) -> Option {
      Option { $0.disableTypeGuards = value }
    }

    /// Hides the declaration from expressions while keeping its runtime implementation (`true`),
    /// or explicitly re-enables it when merged over a disabled declaration (`false`).
    public static func disableDeclaration(_ value: Bool) -> Option {
      Option { $0.state = value ? .disabled : .enabled }
    }

    /// Adds a global overload, called as `function(args)`.
    public static func overload(
      _ id: String, argTypes: [CELType], resultType: CELType, _ options: OverloadDecl.Option...
    ) -> Option {
      Option { f in
        try f.addOverload(
          OverloadDecl(id: id, argTypes: argTypes, resultType: resultType, options: options))
      }
    }

    /// Adds a member (receiver-style) overload, called as `args[0].function(args[1...])`.
    public static func memberOverload(
      _ id: String, argTypes: [CELType], resultType: CELType, _ options: OverloadDecl.Option...
    ) -> Option {
      Option { f in
        try f.addOverload(
          OverloadDecl(
            id: id, argTypes: argTypes, resultType: resultType, isMemberFunction: true,
            options: options))
      }
    }

    /// Adds an already constructed overload.
    public static func overload(_ overload: OverloadDecl) -> Option {
      Option { try $0.addOverload(overload) }
    }

    /// Sets a one-argument implementation shared by every overload, dispatched on `traits`.
    public static func singletonUnaryBinding(
      _ binding: @escaping FunctionBinding.Unary, traits: TypeTraits = []
    ) -> Option {
      singleton { name in FunctionBinding(name: name, operandTraits: traits, unary: binding) }
    }

    /// Sets a two-argument implementation shared by every overload, dispatched on `traits`.
    public static func singletonBinaryBinding(
      _ binding: @escaping FunctionBinding.Binary, traits: TypeTraits = []
    ) -> Option {
      singleton { name in FunctionBinding(name: name, operandTraits: traits, binary: binding) }
    }

    /// Sets a variadic implementation shared by every overload, dispatched on `traits`.
    public static func singletonFunctionBinding(
      _ binding: @escaping FunctionBinding.Variadic, traits: TypeTraits = []
    ) -> Option {
      singleton { name in FunctionBinding(name: name, operandTraits: traits, function: binding) }
    }

    private static func singleton(_ make: @escaping @Sendable (String) -> FunctionBinding) -> Option {
      Option { f in
        if f.singleton != nil {
          throw DeclarationError("function already has a singleton binding: \(f.name)")
        }
        f.singleton = SingletonBinding(make(f.name))
      }
    }
  }
}
