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

// Ported from cel-go checker/scopes.go.
//
// cel-go links `Scopes` values through `parent` pointers; here a `Scopes` value holds its whole stack
// of groups, the first being the root (global) scope. `push()` / `pop()` return new values, so a
// checker can enter and leave comprehension scopes without affecting the environment it started
// from. The inherited scopes of `ValidatedDeclarations` are shared, immutable, through a class box.

/// Nested declaration groups: identifiers and functions in inner scopes shadow outer ones.
package struct Scopes: Sendable {
  /// A set of declarations pushed on or popped off the stack as a unit.
  struct Group: Sendable {
    var idents: [String: VariableDecl] = [:]
    var functions: [String: FunctionDecl] = [:]
  }

  /// The parent declarations of another environment, shared without copying.
  final class Inherited: Sendable {
    let scopes: Scopes

    init(_ scopes: Scopes) {
      self.scopes = scopes
    }
  }

  /// The groups, root first. Never empty.
  private var groups: [Group]
  private let inherited: Inherited?

  /// An empty root scope.
  init() {
    groups = [Group()]
    inherited = nil
  }

  private init(inheriting scopes: Scopes) {
    groups = [Group()]
    inherited = Inherited(scopes)
  }

  /// A scope stack with one more, empty, innermost scope.
  func push() -> Scopes {
    var copy = self
    copy.groups.append(Group())
    return copy
  }

  /// A new root scope that falls back to these scopes' globals and functions (cel-go `PushInherited`).
  func pushInherited() -> Scopes {
    Scopes(inheriting: self)
  }

  /// The stack without its innermost scope, or the same stack if only the root is left.
  func pop() -> Scopes {
    var copy = self
    if copy.groups.count > 1 {
      copy.groups.removeLast()
    }
    return copy
  }

  /// Adds an identifier to the innermost scope, replacing one with the same name.
  mutating func addIdent(_ decl: VariableDecl) {
    groups[groups.count - 1].idents[decl.name] = decl
  }

  /// The identifier with the given name in the innermost scope only.
  func findIdentInScope(_ name: String) -> VariableDecl? {
    groups[groups.count - 1].idents[trimLeadingDot(name)]
  }

  /// A locally scoped identifier (any scope but the root).
  func findLocalIdent(_ name: String) -> VariableDecl? {
    let trimmed = trimLeadingDot(name)
    for group in groups.dropFirst().reversed() {
      if let ident = group.idents[trimmed] {
        return ident
      }
    }
    return nil
  }

  /// An identifier in the root scope, or in the inherited scopes.
  func findGlobalIdent(_ name: String) -> VariableDecl? {
    if let ident = groups[0].idents[trimLeadingDot(name)] {
      return ident
    }
    return inherited?.scopes.findGlobalIdent(name)
  }

  /// Adds a function to the innermost scope, replacing one with the same name.
  mutating func setFunction(_ fn: FunctionDecl) {
    groups[groups.count - 1].functions[fn.name] = fn
  }

  /// The function with the given name, searched from the innermost scope outwards, then in the
  /// inherited scopes.
  func findFunction(_ name: String) -> FunctionDecl? {
    let trimmed = trimLeadingDot(name)
    for group in groups.reversed() {
      if let fn = group.functions[trimmed] {
        return fn
      }
    }
    return inherited?.scopes.findFunction(trimmed)
  }
}

/// `name` without one leading dot (Go `strings.TrimPrefix(name, ".")`).
func trimLeadingDot(_ name: String) -> String {
  if name.utf8.first == UInt8(ascii: ".") {
    return String(decoding: name.utf8.dropFirst(), as: UTF8.self)
  }
  return name
}
