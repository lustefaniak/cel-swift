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
//
// Ported from cel-go interpreter/activation.go (and the input activation of interpreter/frame.go).
//
// cel-go discovers optional activation capabilities (`activationWrapper`, `localVariableHolder`,
// `partialActivationConverter`) with type assertions. Here they are protocol requirements with
// defaults, so the interpreter never needs a dynamic cast to find them.

/// Resolves identifiers by name: the primary way a caller supplies input to a program
/// (cel-go `interpreter.Activation`).
package protocol Activation {
  /// The value bound to a qualified variable name, or `nil` if the name is not bound.
  func resolveName(_ name: String) -> Value?

  /// The parent activation, searched by some resolution helpers; `nil` for a root activation.
  var parent: (any Activation)? { get }

  /// The activation without the local (comprehension) variables of this scope, or `nil` if this
  /// activation holds no local state (cel-go `activationWrapper.Unwrap`).
  var unwrapped: (any Activation)? { get }

  /// Whether `name` is bound as a local variable in this scope (cel-go `localVariableHolder`).
  func isLocalVariable(_ name: String) -> Bool

  /// The first partial activation in the hierarchy, if any (cel-go `AsPartialActivation`).
  func asPartialActivation() -> (any PartialActivation)?
}

extension Activation {
  package var parent: (any Activation)? { nil }

  package var unwrapped: (any Activation)? { nil }

  package func isLocalVariable(_ name: String) -> Bool { false }

  /// Walks the parent chain looking for a partial activation.
  package func asPartialActivation() -> (any PartialActivation)? {
    parent?.asPartialActivation()
  }
}

/// An activation that also names the attribute patterns whose values are unknown
/// (cel-go `interpreter.PartialActivation`).
package protocol PartialActivation: Activation {
  /// The patterns of attributes whose values are not known yet.
  var unknownAttributePatterns: [AttributePattern] { get }
}

/// An activation without variables (cel-go `EmptyActivation`).
package struct EmptyActivation: Activation {
  package init() {}

  package func resolveName(_ name: String) -> Value? { nil }
}

/// An activation backed by a dictionary of values (cel-go `mapActivation`).
package struct MapActivation: Activation {
  package var bindings: [String: Value]

  package init(_ bindings: [String: Value] = [:]) {
    self.bindings = bindings
  }

  package func resolveName(_ name: String) -> Value? {
    bindings[name]
  }
}

/// An activation whose bindings are computed on first use and then memoised for the rest of the
/// evaluation (the lazy `func() ref.Val` bindings of cel-go `mapActivation` / `inputActivation`).
package final class LazyActivation: Activation {
  private let values: [String: Value]
  private let lazyValues: [String: () -> Value]
  private var resolved: [String: Value] = [:]

  package init(values: [String: Value] = [:], lazy: [String: () -> Value]) {
    self.values = values
    self.lazyValues = lazy
  }

  package func resolveName(_ name: String) -> Value? {
    if let value = values[name] {
      return value
    }
    if let value = resolved[name] {
      return value
    }
    guard let make = lazyValues[name] else {
      return nil
    }
    let value = make()
    resolved[name] = value
    return value
  }
}

/// An activation that resolves names in a child first and its parent second
/// (cel-go `hierarchicalActivation`).
package struct HierarchicalActivation: Activation {
  package let parentActivation: any Activation
  package let child: any Activation

  package init(parent: any Activation, child: any Activation) {
    self.parentActivation = parent
    self.child = child
  }

  package func resolveName(_ name: String) -> Value? {
    if let value = child.resolveName(name) {
      return value
    }
    return parentActivation.resolveName(name)
  }

  package var parent: (any Activation)? { parentActivation }

  /// The parent activation, stripping the child scope.
  package var unwrapped: (any Activation)? { parentActivation }

  package func isLocalVariable(_ name: String) -> Bool {
    child.isLocalVariable(name) || parentActivation.isLocalVariable(name)
  }

  package func asPartialActivation() -> (any PartialActivation)? {
    child.asPartialActivation() ?? parentActivation.asPartialActivation()
  }
}

/// An activation with a set of unknown attribute patterns (cel-go `partActivation`).
package struct PartialActivationWrapper: PartialActivation {
  package let activation: any Activation
  package let unknownAttributePatterns: [AttributePattern]

  package init(_ activation: any Activation, unknowns: [AttributePattern]) {
    self.activation = activation
    self.unknownAttributePatterns = unknowns
  }

  package func resolveName(_ name: String) -> Value? {
    activation.resolveName(name)
  }

  package var parent: (any Activation)? { activation.parent }

  package func asPartialActivation() -> (any PartialActivation)? { self }
}
