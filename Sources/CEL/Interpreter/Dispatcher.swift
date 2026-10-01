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
// Ported from cel-go interpreter/dispatcher.go. A value type: `extended()` gives the isolation
// layer of cel-go's `ExtendDispatcher` by copying.

/// Resolves function calls to their runtime bindings by overload id or function name
/// (cel-go `Dispatcher`).
package struct Dispatcher: Sendable {
  private var overloads: [String: FunctionBinding] = [:]

  /// An empty dispatcher.
  package init() {}

  /// A dispatcher with the bindings of the given function declarations.
  package init(functions: [FunctionDecl]) throws {
    for function in functions {
      try add(function.bindings())
    }
  }

  /// Adds bindings, failing if one with the same name already exists.
  package mutating func add(_ bindings: [FunctionBinding]) throws {
    for binding in bindings {
      if overloads[binding.name] != nil {
        throw DeclarationError("overload already exists '\(binding.name)'")
      }
      overloads[binding.name] = binding
    }
  }

  /// Adds one binding, failing if one with the same name already exists.
  package mutating func add(_ binding: FunctionBinding) throws {
    try add([binding])
  }

  /// The binding registered under an overload id or function name.
  package func findOverload(_ name: String) -> FunctionBinding? {
    overloads[name]
  }

  /// Every registered overload id and function name.
  package var overloadIDs: [String] {
    Array(overloads.keys)
  }
}
