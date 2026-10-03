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

// Ported from cel-go checker/mapping.go.

/// Type parameter substitutions, keyed by the formatted type parameter (cel-go `mapping`).
///
/// A value type: cel-go's `copy()` is plain assignment here.
///
/// The checker only adds type parameters, so keys are type parameter names. `find` answers as the
/// formatted lookup would, mostly without formatting: a type parameter is looked up by its name, and a
/// type whose formatted name has parentheses can only match a key with parentheses, which there
/// usually is none of.
struct TypeMapping: Sendable {
  private var mapping: [String: CELType] = [:]
  /// Whether a key contains `(`, so that a parameterized type's formatted name could match it.
  private var hasParenthesizedKey = false

  mutating func add(_ from: CELType, _ to: CELType) {
    let key = from.checkerDescription
    if !hasParenthesizedKey && key.utf8.contains(UInt8(ascii: "(")) {
      hasParenthesizedKey = true
    }
    mapping[key] = to
  }

  func find(_ from: CELType) -> CELType? {
    if mapping.isEmpty {
      return nil
    }
    if case .typeParam(let name) = from {
      return mapping[name]
    }
    if !hasParenthesizedKey && from.formatsWithParentheses {
      return nil
    }
    return mapping[from.checkerDescription]
  }
}

extension CELType {
  /// Whether ``checkerDescription`` contains `(` whatever the type's names: list, map, wrapper and
  /// parameterized types, and function types.
  fileprivate var formatsWithParentheses: Bool {
    switch self {
    case .list, .map, .wrapper: return true
    case .opaque(_, let params): return !params.isEmpty
    case .type(let param): return param != nil
    default: return false
    }
  }
}
