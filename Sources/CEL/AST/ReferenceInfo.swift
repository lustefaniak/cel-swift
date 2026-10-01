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

// Ported from cel-go common/ast/ast.go (ReferenceInfo and the checked parts of AST).

/// What the type checker resolved an expression to (cel-go `ast.ReferenceInfo`).
///
/// For an identifier or a qualified name (`a.b.c` rewritten to an identifier), `name` is the fully
/// qualified name of the variable, type or enum constant, and `value` is set for constants such as
/// enum values. For a function call, `overloadIDs` lists every overload whose signature matched;
/// the interpreter dispatches on them.
package struct ReferenceInfo: Sendable {
  /// The fully qualified name of the referenced identifier; empty for function references.
  package var name: String
  /// The ids of the matching overloads, in declaration order, without duplicates.
  package private(set) var overloadIDs: [String]
  /// The value of a constant identifier, such as an enum value.
  package var value: Value?

  /// A reference to an identifier with an optional constant value (cel-go `NewIdentReference`).
  package init(name: String, value: Value? = nil) {
    self.name = name
    self.overloadIDs = []
    self.value = value
  }

  /// A reference to a set of function overloads (cel-go `NewFunctionReference`).
  package init(overloadIDs: [String]) {
    self.name = ""
    self.overloadIDs = []
    self.value = nil
    for id in overloadIDs {
      addOverload(id)
    }
  }

  /// Appends an overload id unless it is already present.
  package mutating func addOverload(_ overloadID: String) {
    if !overloadIDs.contains(overloadID) {
      overloadIDs.append(overloadID)
    }
  }

  /// Whether two references are identical: same name, same overload set, equal values.
  package func isEqual(to other: ReferenceInfo) -> Bool {
    if name != other.name || overloadIDs.count != other.overloadIDs.count {
      return false
    }
    let ids = Set(overloadIDs)
    for id in other.overloadIDs where !ids.contains(id) {
      return false
    }
    switch (value, other.value) {
    case (nil, nil):
      return true
    case (let lhs?, let rhs?):
      return lhs.celEquals(rhs) == .bool(true)
    default:
      return false
    }
  }
}

extension ReferenceInfo: CustomStringConvertible {
  /// A debug rendering in the shape of Go's `%v` of the struct.
  package var description: String {
    let value = self.value.map { "\($0)" } ?? "<nil>"
    return "&{\(name) [\(overloadIDs.joined(separator: " "))] \(value)}"
  }
}

// MARK: - Checked AST accessors

extension AST {
  /// The checked type of the expression `id`, or `dyn` when it has none (cel-go `GetType`).
  package func type(of id: Int64) -> CELType {
    typeMap[id] ?? .dyn
  }

  /// The overload ids resolved for the call `id`, or an empty list (cel-go `GetOverloadIDs`).
  package func overloadIDs(of id: Int64) -> [String] {
    referenceMap[id]?.overloadIDs ?? []
  }

  /// The reference resolved for the expression `id`, if any.
  package func reference(of id: Int64) -> ReferenceInfo? {
    referenceMap[id]
  }

  /// Whether the AST has been type-checked (cel-go `IsChecked`): its type map is not empty.
  package var isChecked: Bool {
    !typeMap.isEmpty
  }
}
