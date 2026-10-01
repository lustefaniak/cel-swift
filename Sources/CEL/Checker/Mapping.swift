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
struct TypeMapping: Sendable {
  private var mapping: [String: CELType] = [:]

  mutating func add(_ from: CELType, _ to: CELType) {
    mapping[from.checkerDescription] = to
  }

  func find(_ from: CELType) -> CELType? {
    mapping[from.checkerDescription]
  }
}
