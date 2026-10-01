// Copyright 2018 Google LLC
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

// Ported from cel-go checker/env.go and checker/options.go.

/// A type-checker option (cel-go `checker.Option`).
package enum CheckerOption: Sendable {
  /// Enables the `double <-> int <-> uint` comparison overloads (`1 < 2.0`). Off by default, as in
  /// cel-go; see https://github.com/google/cel-spec/wiki/proposal-210.
  case crossTypeNumericComparisons(Bool)
  /// Reports mixed element types in list and map literals instead of joining them to `dyn`.
  ///
  /// cel-go keeps this switch in the checker but sets it nowhere; homogeneous literals are enforced
  /// by an AST validator in the `cel` package. Kept for parity with the checker's state.
  case homogeneousAggregateLiterals(Bool)
  /// Inherits the declarations of an already validated environment as a parent scope, without
  /// copying them (cel-go `ValidatedDeclarations`).
  case validatedDeclarations(CheckerEnv)
  /// Accepts only JSON field names for message fields; the provider must resolve them.
  case jsonFieldNames(Bool)
}

/// The environment for type checking: container, type provider, declarations and options
/// (cel-go `checker.Env`).
package struct CheckerEnv: Sendable {
  enum AggregateLiteralElementType: Sendable {
    case dyn
    case homogeneous
  }

  /// The overloads disabled unless cross-type numeric comparisons are enabled.
  static let crossTypeNumericComparisonOverloads: Set<String> = {
    typealias O = Overloads
    return [
      // double <-> int | uint
      O.lessDoubleInt64, O.lessDoubleUint64, O.lessEqualsDoubleInt64, O.lessEqualsDoubleUint64,
      O.greaterDoubleInt64, O.greaterDoubleUint64, O.greaterEqualsDoubleInt64,
      O.greaterEqualsDoubleUint64,
      // int <-> double | uint
      O.lessInt64Double, O.lessInt64Uint64, O.lessEqualsInt64Double, O.lessEqualsInt64Uint64,
      O.greaterInt64Double, O.greaterInt64Uint64, O.greaterEqualsInt64Double,
      O.greaterEqualsInt64Uint64,
      // uint <-> double | int
      O.lessUint64Double, O.lessUint64Int64, O.lessEqualsUint64Double, O.lessEqualsUint64Int64,
      O.greaterUint64Double, O.greaterUint64Int64, O.greaterEqualsUint64Double,
      O.greaterEqualsUint64Int64,
    ]
  }()

  /// The container names are resolved in.
  package let container: Container
  /// Resolves message types, fields, enum values and type identifiers.
  package let provider: any TypeProvider
  var declarations: Scopes
  let aggLitElemType: AggregateLiteralElementType
  let filteredOverloadIDs: Set<String>
  let jsonFieldNames: Bool

  /// Creates an environment (cel-go `NewEnv`).
  package init(container: Container = .default, provider: any TypeProvider, options: [CheckerOption] = []) {
    var crossTypeNumericComparisons = false
    var homogeneousAggregateLiterals = false
    var validatedDeclarations: Scopes?
    var jsonFieldNames = false
    for option in options {
      switch option {
      case .crossTypeNumericComparisons(let enabled): crossTypeNumericComparisons = enabled
      case .homogeneousAggregateLiterals(let enabled): homogeneousAggregateLiterals = enabled
      case .validatedDeclarations(let env): validatedDeclarations = env.declarations
      case .jsonFieldNames(let enabled): jsonFieldNames = enabled
      }
    }
    self.container = container
    self.provider = provider
    self.declarations = validatedDeclarations?.pushInherited() ?? Scopes()
    self.aggLitElemType = homogeneousAggregateLiterals ? .homogeneous : .dyn
    self.filteredOverloadIDs =
      crossTypeNumericComparisons ? [] : CheckerEnv.crossTypeNumericComparisonOverloads
    self.jsonFieldNames = jsonFieldNames
  }

  private init(
    container: Container, provider: any TypeProvider, declarations: Scopes,
    aggLitElemType: AggregateLiteralElementType
  ) {
    self.container = container
    self.provider = provider
    self.declarations = declarations
    self.aggLitElemType = aggLitElemType
    self.filteredOverloadIDs = []
    self.jsonFieldNames = false
  }

  /// Adds variable declarations.
  ///
  /// - Throws: ``DeclarationError`` listing every identifier that is already declared with a
  ///   different type, or constant with a different value.
  package mutating func addIdents(_ decls: [VariableDecl]) throws {
    var messages: [String] = []
    for decl in decls {
      if let message = addIdent(decl) {
        messages.append(message)
      }
    }
    try throwIfAny(messages)
  }

  /// Adds variable declarations.
  package mutating func addIdents(_ decls: VariableDecl...) throws {
    try addIdents(decls)
  }

  /// Adds function declarations, merging overloads into functions already declared.
  ///
  /// - Throws: ``DeclarationError`` for overlapping overloads or overloads a macro would shadow.
  package mutating func addFunctions(_ decls: [FunctionDecl]) throws {
    var messages: [String] = []
    for decl in decls {
      messages.append(contentsOf: setFunction(decl))
    }
    try throwIfAny(messages)
  }

  /// Adds function declarations.
  package mutating func addFunctions(_ decls: FunctionDecl...) throws {
    try addFunctions(decls)
  }

  private func throwIfAny(_ messages: [String]) throws {
    if !messages.isEmpty {
      throw DeclarationError(messages.joined(separator: "\n"))
    }
  }

  /// A variable a name resolved to, and whether the name must be written with a leading dot because
  /// a local variable shadows it.
  struct AttributeResolution {
    var decl: VariableDecl
    var requiresDisambiguation: Bool
  }

  /// Resolves a single identifier: locals first (unless the name has a leading dot), then globals
  /// in container order.
  func resolveSimpleIdent(_ name: String) -> AttributeResolution? {
    let local = lookupLocalIdent(name)
    if let local, name.utf8.first != UInt8(ascii: ".") {
      return AttributeResolution(decl: local, requiresDisambiguation: false)
    }
    for candidate in container.resolveCandidateNames(name) {
      if let ident = lookupGlobalIdent(candidate) {
        return AttributeResolution(decl: ident, requiresDisambiguation: local != nil)
      }
    }
    return nil
  }

  /// Resolves a qualified identifier `a.b.c` given as its parts.
  func resolveQualifiedIdent(_ qualifiers: [String]) -> AttributeResolution? {
    if qualifiers.count == 1 {
      return resolveSimpleIdent(qualifiers[0])
    }
    let local = lookupLocalIdent(qualifiers[0])
    if local != nil && qualifiers[0].utf8.first != UInt8(ascii: ".") {
      // This should resolve through a field selection rather than a qualified identifier.
      return nil
    }
    // The qualifiers are concatenated to the qualified name to search for as a global identifier.
    // Select expressions are resolved from leaf to root, so if the full name does not match, no
    // variable is found and the traversal continues to the next simpler name.
    let varName = qualifiers.joined(separator: ".")
    for candidate in container.resolveCandidateNames(varName) {
      if let ident = lookupGlobalIdent(candidate) {
        return AttributeResolution(decl: ident, requiresDisambiguation: local != nil)
      }
    }
    return nil
  }

  /// The declaration of a type name, as a variable of type `type(T)`, for message literals.
  func resolveTypeIdent(_ name: String) -> VariableDecl? {
    for candidate in container.resolveCandidateNames(name) {
      // Try to import the name as a reference to a message type.
      if case .type(let t)? = provider.findIdent(candidate) {
        return VariableDecl(name: candidate, type: .type(t))
      }
      // Next, try to find the struct type.
      if let t = provider.findStructType(candidate) {
        return VariableDecl(name: candidate, type: t)
      }
    }
    return nil
  }

  /// A variable declared in a local (comprehension) scope.
  func lookupLocalIdent(_ candidate: String) -> VariableDecl? {
    declarations.findLocalIdent(candidate)
  }

  /// A global variable, type name or enum constant with exactly this name.
  func lookupGlobalIdent(_ candidate: String) -> VariableDecl? {
    // Try to resolve the global identifier first.
    if let ident = declarations.findGlobalIdent(candidate) {
      return ident
    }
    // Next try to import the name as a reference to a message type.
    if case .type(let t)? = provider.findIdent(candidate) {
      return VariableDecl(name: candidate, type: .type(t))
    }
    if let t = provider.findStructType(candidate) {
      return VariableDecl(name: candidate, type: t)
    }
    // Next try to import this as an enum value by splitting the name in a type prefix and the
    // enum inside. With strong enums the value's type is its enum, otherwise `int`.
    let enumValue = provider.enumValue(candidate)
    if case .error = enumValue {
      return nil
    }
    return VariableDecl(constant: candidate, type: enumValue.celType, value: enumValue)
  }

  /// The function a name resolves to in container order.
  func lookupFunction(_ name: String) -> FunctionDecl? {
    for candidate in container.resolveCandidateNames(name) {
      if let fn = declarations.findFunction(candidate) {
        return fn
      }
    }
    return nil
  }

  /// Adds or merges a function declaration, returning error messages.
  private mutating func setFunction(_ fn: FunctionDecl) -> [String] {
    var messages: [String] = []
    var current = fn
    if let existing = declarations.findFunction(fn.name) {
      do {
        current = try existing.merging(fn)
      } catch let error as DeclarationError {
        return [error.message]
      } catch {
        return ["\(error)"]
      }
    }
    for overload in current.overloads {
      for macro in Macro.allMacros
      where macro.function == current.name && macro.isReceiverStyle == overload.isMemberFunction
        && macro.argCount == overload.argumentTypes.count
      {
        messages.append(
          "overlapping macro for name '\(current.name)' with \(macro.argCount) args")
      }
      if !messages.isEmpty {
        return messages
      }
    }
    declarations.setFunction(current)
    return messages
  }

  /// Adds a variable declaration, returning an error message if it conflicts.
  private mutating func addIdent(_ decl: VariableDecl) -> String? {
    if let current = declarations.findIdentInScope(decl.name) {
      if current.isEquivalent(to: decl) {
        switch maybeMergeConstant(current, decl) {
        case .success(let merged):
          declarations.addIdent(merged)
          return nil
        case .failure(let error):
          return error.message
        }
      }
      return "overlapping identifier for name '\(decl.name)'"
    }
    declarations.addIdent(decl)
    return nil
  }

  private func maybeMergeConstant(
    _ a: VariableDecl, _ b: VariableDecl
  ) -> Result<VariableDecl, DeclarationError> {
    guard let bValue = b.value else {
      return .success(a)
    }
    guard let aValue = a.value else {
      return .success(b)
    }
    if aValue.celEquals(bValue) == .bool(true) {
      return .success(a)
    }
    return .failure(DeclarationError("conflicting constant definitions for name '\(b.name)'"))
  }

  /// Whether the overload is disabled in this environment.
  func isOverloadDisabled(_ overloadID: String) -> Bool {
    filteredOverloadIDs.contains(overloadID)
  }

  /// The environment with a new innermost declaration scope.
  ///
  /// As in cel-go, the scoped environment does not carry over the filtered overloads or the JSON
  /// field name option, so cross-type numeric comparisons type-check inside comprehensions.
  func enterScope() -> CheckerEnv {
    CheckerEnv(
      container: container, provider: provider, declarations: declarations.push(),
      aggLitElemType: aggLitElemType)
  }

  /// The environment with the innermost declaration scope removed; see ``enterScope()``.
  func exitScope() -> CheckerEnv {
    CheckerEnv(
      container: container, provider: provider, declarations: declarations.pop(),
      aggLitElemType: aggLitElemType)
  }
}
