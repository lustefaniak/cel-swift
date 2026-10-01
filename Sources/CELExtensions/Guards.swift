// Copyright 2020 Google LLC
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
// Ported from cel-go ext/guards.go.
//
// cel-go's bindings type-assert their arguments (`args[0].(types.String)`) because the runtime type
// guards of the declaration have already checked them. Swift has no unchecked casts, so the
// helpers here destructure arguments and fall back to `no such overload` (the guard's result) when
// a binding is called directly with the wrong types.

import CEL

/// A Go `error` carried as a message, turned into a CEL error value by the `...OrError` guards.
struct ExtError: Error, Sendable {
  let message: String

  init(_ message: String) {
    self.message = message
  }
}

/// Port of `stringOrError`.
func stringOrError(_ result: Result<String, ExtError>) -> Value {
  switch result {
  case .success(let s): .string(s)
  case .failure(let e): .error(EvalError(e.message))
  }
}

/// Port of `intOrError`.
func intOrError(_ result: Result<Int64, ExtError>) -> Value {
  switch result {
  case .success(let i): .int(i)
  case .failure(let e): .error(EvalError(e.message))
  }
}

/// Port of `bytesOrError`.
func bytesOrError(_ result: Result<[UInt8], ExtError>) -> Value {
  switch result {
  case .success(let b): .bytes(b)
  case .failure(let e): .error(EvalError(e.message))
  }
}

/// Port of `listStringOrError`.
func listStringOrError(_ result: Result<[String], ExtError>) -> Value {
  switch result {
  case .success(let strs): .list(ArrayList(strs.map(Value.string)))
  case .failure(let e): .error(EvalError(e.message))
  }
}

/// Wraps a Go-style error as a CEL error value (cel-go `types.WrapErr`).
func errorValue(_ message: String) -> Value {
  .error(EvalError(message))
}

/// The result of a binding called with arguments its declaration does not accept.
func noSuchOverload(_ args: Value...) -> Value {
  for arg in args where arg.isUnknownOrError {
    return arg
  }
  return .noSuchOverload
}

