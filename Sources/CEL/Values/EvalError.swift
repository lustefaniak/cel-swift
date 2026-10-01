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
// Ported from cel-go common/types/err.go.

/// A CEL evaluation error.
///
/// Errors are values in CEL: they flow through evaluation as ``Value/error(_:)`` so the
/// commutative `&&` / `||` absorption rules work. The message text matches cel-go's.
public struct EvalError: Error, Sendable, Hashable, CustomStringConvertible {
  /// The error message, for example `division by zero`.
  public var message: String

  /// The id of the expression node where the error occurred, or `0` when not yet known.
  public var exprID: Int64

  /// Creates an error with a message and an optional expression id.
  public init(_ message: String, exprID: Int64 = 0) {
    self.message = message
    self.exprID = exprID
  }

  /// The error message.
  public var description: String { message }

  /// Returns the error labelled with `id` unless it already carries an expression id.
  func labelled(with id: Int64) -> EvalError {
    if exprID != 0 { return self }
    var copy = self
    copy.exprID = id
    return copy
  }
}

extension EvalError {
  /// `no such overload`: the arguments did not match a supported signature.
  package static let noSuchOverload = EvalError("no such overload")
  /// `division by zero`.
  package static let divideByZero = EvalError("division by zero")
  /// `modulus by zero`.
  package static let modulusByZero = EvalError("modulus by zero")
  /// `integer overflow`.
  package static let intOverflow = EvalError("integer overflow")
  /// `unsigned integer overflow`.
  package static let uintOverflow = EvalError("unsigned integer overflow")
  /// `duration overflow`.
  package static let durationOverflow = EvalError("duration overflow")
  /// `timestamp overflow`.
  package static let timestampOverflow = EvalError("timestamp overflow")
}

extension Value {
  /// The `no such overload` error value.
  package static let noSuchOverload = Value.error(.noSuchOverload)

  /// Creates an error value with the given message.
  package static func error(message: String) -> Value {
    .error(EvalError(message))
  }

  /// Returns `value` itself when it is an error or unknown, otherwise a new error with `message`.
  ///
  /// Port of cel-go `types.ValOrErr`.
  package static func valOrError(_ value: Value?, _ message: @autoclosure () -> String) -> Value {
    if let value, value.isUnknownOrError {
      return value
    }
    return .error(EvalError(message()))
  }

  /// Returns `value` itself when it is an error or unknown, otherwise `no such overload`.
  ///
  /// Port of cel-go `types.MaybeNoSuchOverloadErr`.
  package static func maybeNoSuchOverload(_ value: Value) -> Value {
    valOrError(value, "no such overload")
  }

  /// Returns the value with its error labelled with the expression `id`, if it is an unlabelled error.
  ///
  /// Port of cel-go `types.LabelErrNode`.
  @inline(__always)
  package func labellingError(with id: Int64) -> Value {
    if case .error(let err) = self, err.exprID == 0 {
      return .error(err.labelled(with: id))
    }
    return self
  }
}
