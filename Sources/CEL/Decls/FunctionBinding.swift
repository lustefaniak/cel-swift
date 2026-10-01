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
// Ported from cel-go common/functions/functions.go.

/// A runtime implementation of a function or of one of its overloads, as the interpreter's
/// dispatcher sees it.
///
/// A binding offers a ``unary``, ``binary`` or variadic ``function`` implementation; the
/// interpreter calls the one matching the argument count and falls back to ``function``.
/// Errors are returned as ``Value/error(_:)``, never thrown.
public struct FunctionBinding: Sendable {
  /// An implementation taking one argument.
  public typealias Unary = @Sendable (Value) -> Value
  /// An implementation taking two arguments.
  public typealias Binary = @Sendable (Value, Value) -> Value
  /// An implementation taking any number of arguments.
  public typealias Variadic = @Sendable ([Value]) -> Value

  /// The name the binding is registered under: an overload id, or the function name for the
  /// dynamically dispatched entry.
  public var name: String
  /// Traits the first argument must have for the binding to apply; empty when unrestricted.
  public var operandTraits: TypeTraits
  /// The one-argument implementation, if any.
  public var unary: Unary?
  /// The two-argument implementation, if any.
  public var binary: Binary?
  /// The variadic implementation, if any.
  public var function: Variadic?
  /// Whether the implementation accepts error and unknown arguments.
  public var isNonStrict: Bool

  /// Creates a binding.
  public init(
    name: String,
    operandTraits: TypeTraits = [],
    unary: Unary? = nil,
    binary: Binary? = nil,
    function: Variadic? = nil,
    isNonStrict: Bool = false
  ) {
    self.name = name
    self.operandTraits = operandTraits
    self.unary = unary
    self.binary = binary
    self.function = function
    self.isNonStrict = isNonStrict
  }

  /// Calls the binding as cel-go's interpreter does once the arguments are evaluated.
  ///
  /// Port of the tail of cel-go `evalUnary`, `evalBinary` and `evalVarArgs`.Exec: for a strict
  /// binding an error argument (the first one) is returned as is, then unknown arguments are merged
  /// and returned; the implementation runs when the first argument has ``operandTraits``;
  /// otherwise a receiver-style call on the first argument is attempted (strings, durations and
  /// timestamps), else `no such overload: <function>`. Errors are labelled with `exprID`.
  ///
  /// - Parameters:
  ///   - args: The evaluated arguments; for member calls the receiver comes first.
  ///   - functionName: The function name, used for receiver dispatch and error messages.
  ///   - overload: The resolved overload id, or the empty string in parse-only evaluation.
  ///   - exprID: The id of the call expression.
  package func call(_ args: [Value], functionName: String, overload: String, exprID: Int64) -> Value {
    let strict = !isNonStrict
    if strict {
      var unknown: UnknownSet?
      for arg in args {
        if case .error = arg {
          return arg
        }
        (unknown, _) = Value.maybeMergeUnknowns(arg, unknown)
      }
      if let unknown {
        return .unknown(unknown)
      }
    }
    guard let arg0 = args.first else {
      return invoke(args).labellingError(with: exprID)
    }
    let hasImpl: Bool
    switch args.count {
    case 1: hasImpl = unary != nil || function != nil
    case 2: hasImpl = binary != nil || function != nil
    default: hasImpl = function != nil
    }
    if hasImpl
      && (operandTraits.isEmpty || (!strict && arg0.isUnknownOrError)
        || arg0.traits.isSuperset(of: operandTraits))
    {
      return invoke(args).labellingError(with: exprID)
    }
    if arg0.traits.contains(.receiver) {
      return arg0.receive(function: functionName, overload: overload, args: Array(args.dropFirst()))
        .labellingError(with: exprID)
    }
    if args.count > 2 {
      return .error(EvalError("no such overload: \(functionName) \(exprID)", exprID: exprID))
    }
    return .error(EvalError("no such overload: \(functionName)", exprID: exprID))
  }

  /// Calls the implementation matching the argument count, or returns a `no such overload` error.
  public func invoke(_ args: [Value]) -> Value {
    switch args.count {
    case 1:
      if let unary { return unary(args[0]) }
    case 2:
      if let binary { return binary(args[0], args[1]) }
    default:
      break
    }
    if let function {
      return function(args)
    }
    return .noSuchOverload
  }
}
