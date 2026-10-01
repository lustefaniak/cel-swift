// Copyright 2019 Google LLC
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
// Re-designed from cel-go cel/program.go (AttributePattern, PartialVars, PartialActivation) and
// cel/env.go (UnknownVars, PartialVars).

/// A pattern naming variables, or parts of variables, whose values are not known yet
/// (cel-go `AttributePattern`).
///
/// A program created with ``Program/Option/partialEvaluation`` treats every attribute matching
/// one of the ``Variables/unknowns`` patterns as unknown: instead of failing, expressions that
/// need it evaluate to an `.unknown` value listing the attributes they are missing, while
/// expressions that can be decided without it (`false && unknownThing`) still evaluate.
///
/// ```swift
/// // request.auth.claims["email"] is unknown; request.auth.principal is known
/// let pattern = UnknownPattern("request").qualified(by: "auth").qualified(by: "claims").wildcard()
/// ```
///
/// The variable must be the fully qualified name the checker resolves: with the container `a.b`,
/// the variable `c` is matched by the pattern `a.b.c`.
public struct UnknownPattern: Sendable, Hashable, CustomStringConvertible {
  package private(set) var pattern: AttributePattern
  private var qualifiers: [AttributeQualifier?] = []

  /// Creates a pattern matching a whole variable.
  ///
  /// - Parameter variable: The fully qualified variable name.
  public init(_ variable: String) {
    self.pattern = AttributePattern(variable)
  }

  /// The variable name the pattern matches.
  public var variable: String { pattern.variable }

  /// Returns the pattern with a qualifier appended: a field name or string map key, an integer
  /// list index or map key, an unsigned or boolean map key.
  public func qualified(by qualifier: AttributeQualifier) -> UnknownPattern {
    var copy = self
    switch qualifier {
    case .string(let s): copy.pattern = pattern.qualString(s)
    case .int(let i): copy.pattern = pattern.qualInt(i)
    case .uint(let u): copy.pattern = pattern.qualUint(u)
    case .bool(let b): copy.pattern = pattern.qualBool(b)
    }
    copy.qualifiers.append(qualifier)
    return copy
  }

  /// Returns the pattern with a field name or string map key appended.
  public func qualified(by field: String) -> UnknownPattern {
    qualified(by: .string(field))
  }

  /// Returns the pattern with a wildcard appended, matching any single qualifier.
  public func wildcard() -> UnknownPattern {
    var copy = self
    copy.pattern = pattern.wildcard()
    copy.qualifiers.append(nil)
    return copy
  }

  /// The pattern written like a CEL attribute, with `*` for wildcards, such as `a.b[1].*`.
  public var description: String {
    var result = variable
    for qualifier in qualifiers {
      switch qualifier {
      case .string(let s)?: result += ".\(s)"
      case .int(let i)?: result += "[\(i)]"
      case .uint(let u)?: result += "[\(u)u]"
      case .bool(let b)?: result += "[\(b)]"
      case nil: result += ".*"
      }
    }
    return result
  }
}

extension Variables {
  /// Creates variables with values and patterns of attributes whose values are unknown
  /// (cel-go `PartialVars`).
  public init(_ values: [String: Value] = [:], unknowns: [UnknownPattern]) {
    self.init(values)
    self.unknowns = unknowns
  }
}

extension Environment {
  /// Variables with the given values that mark every declared variable without a value as
  /// unknown (cel-go `Env.PartialVars`; with no values, `Env.UnknownVars`).
  ///
  /// Evaluate with a program created with ``Program/Option/partialEvaluation``.
  public func partialVariables(_ values: [String: Value] = [:]) -> Variables {
    var unknowns: [UnknownPattern] = []
    for variable in configuration.variables where variable.value == nil {
      // Type identifiers such as `int` are declared as variables of type `type`; they are
      // never unknown.
      if case .type = variable.type, variable.value == nil, isTypeIdentifier(variable.name) {
        continue
      }
      if values[variable.name] == nil {
        unknowns.append(UnknownPattern(variable.name))
      }
    }
    return Variables(values, unknowns: unknowns)
  }

  private func isTypeIdentifier(_ name: String) -> Bool {
    if case .type? = configuration.registry.findIdent(name) {
      return true
    }
    return false
  }
}
