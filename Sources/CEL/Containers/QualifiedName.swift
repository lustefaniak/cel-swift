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

// Ported from cel-go common/containers/container.go (ToQualifiedName).

extension Container {
  /// The dotted name an identifier or a chain of field selections spells, such as `a.b.c`, or `nil`
  /// when the expression is anything else (cel-go `ToQualifiedName`).
  ///
  /// Presence tests (`has(a.b)`) are not qualified names.
  package static func qualifiedName(of expr: Expr) -> String? {
    switch expr.kind {
    case .ident(let name):
      return name
    case .select(let sel):
      if sel.testOnly {
        return nil
      }
      if let qualifier = qualifiedName(of: sel.operand) {
        return qualifier + "." + sel.field
      }
      return nil
    default:
      return nil
    }
  }
}
