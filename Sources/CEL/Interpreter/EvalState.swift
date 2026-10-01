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
// Ported from cel-go interpreter/evalstate.go.

/// Records the values of expression ids during evaluation (cel-go `EvalState`).
package protocol EvalState: AnyObject {
  /// The ids with a recorded value.
  var ids: [Int64] { get }
  /// The value recorded for an expression id.
  func value(_ id: Int64) -> Value?
  /// Records the value of an expression id; `nil` removes it.
  func setValue(_ id: Int64, _ value: Value?)
  /// Clears every recorded value.
  func reset()
}

/// The default ``EvalState``, a dictionary from expression id to value (cel-go `evalState`).
package final class EvalStateRecorder: EvalState {
  private var values: [Int64: Value] = [:]

  package init() {}

  package var ids: [Int64] { Array(values.keys) }

  package func value(_ id: Int64) -> Value? {
    values[id]
  }

  package func setValue(_ id: Int64, _ value: Value?) {
    values[id] = value
  }

  package func reset() {
    values = [:]
  }
}
