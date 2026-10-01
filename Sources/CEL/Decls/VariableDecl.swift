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
// Ported from cel-go common/decls/decls.go (VariableDecl).

/// A variable declaration: a name, a type and optionally a constant value.
public struct VariableDecl: Sendable {
  /// The fully qualified variable name.
  public let name: String
  /// The declared type.
  public let type: CELType
  /// Usage documentation: valid formats, ranges, sizes.
  public var documentation: String
  /// The constant value, for constant declarations.
  public let value: Value?

  /// Creates a variable declaration.
  public init(name: String, type: CELType, documentation: String = "") {
    self.name = name
    self.type = type
    self.documentation = documentation
    self.value = nil
  }

  /// Creates a constant declaration with a value.
  public init(constant name: String, type: CELType, value: Value) {
    self.name = name
    self.type = type
    self.documentation = ""
    self.value = value
  }

  /// Declares the identifier of a type, such as `int` with type `type(int)`, so the type name can
  /// be used as a value.
  public static func typeIdentifier(_ type: CELType) -> VariableDecl {
    VariableDecl(name: type.runtimeTypeName, type: .type(type))
  }

  /// Whether the declarations have the same name and equivalent types.
  public func isEquivalent(to other: VariableDecl) -> Bool {
    name == other.name && type.isEquivalentType(other.type)
  }
}
