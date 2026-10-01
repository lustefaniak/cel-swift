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

// Ported from cel-go common/operators/operators.go.

/// Function names of CEL operators and standard macros, and their display metadata.
package enum Operators {
  // Symbolic operators.
  package static let conditional = "_?_:_"
  package static let logicalAnd = "_&&_"
  package static let logicalOr = "_||_"
  package static let logicalNot = "!_"
  package static let equals = "_==_"
  package static let notEquals = "_!=_"
  package static let less = "_<_"
  package static let lessEquals = "_<=_"
  package static let greater = "_>_"
  package static let greaterEquals = "_>=_"
  package static let add = "_+_"
  package static let subtract = "_-_"
  package static let multiply = "_*_"
  package static let divide = "_/_"
  package static let modulo = "_%_"
  package static let negate = "-_"
  package static let index = "_[_]"
  package static let optIndex = "_[?_]"
  package static let optSelect = "_?._"

  // Macros, must have a valid identifier.
  package static let has = "has"
  package static let all = "all"
  package static let exists = "exists"
  package static let existsOne = "exists_one"
  package static let map = "map"
  package static let filter = "filter"

  // Named operators, must not be valid identifiers.
  package static let notStrictlyFalse = "@not_strictly_false"
  package static let `in` = "@in"

  // Deprecated: named operators with valid identifiers.
  package static let oldNotStrictlyFalse = "__not_strictly_false__"
  package static let oldIn = "_in_"

  private static let operators: [String: String] = [
    "+": add,
    "/": divide,
    "==": equals,
    ">": greater,
    ">=": greaterEquals,
    "in": `in`,
    "<": less,
    "<=": lessEquals,
    "%": modulo,
    "*": multiply,
    "!=": notEquals,
    "-": subtract,
  ]

  private struct Info {
    let displayName: String
    let precedence: Int
    let arity: Int
  }

  private static let operatorMap: [String: Info] = [
    conditional: Info(displayName: "", precedence: 8, arity: 3),
    logicalOr: Info(displayName: "||", precedence: 7, arity: 2),
    logicalAnd: Info(displayName: "&&", precedence: 6, arity: 2),
    equals: Info(displayName: "==", precedence: 5, arity: 2),
    greater: Info(displayName: ">", precedence: 5, arity: 2),
    greaterEquals: Info(displayName: ">=", precedence: 5, arity: 2),
    `in`: Info(displayName: "in", precedence: 5, arity: 2),
    less: Info(displayName: "<", precedence: 5, arity: 2),
    lessEquals: Info(displayName: "<=", precedence: 5, arity: 2),
    notEquals: Info(displayName: "!=", precedence: 5, arity: 2),
    oldIn: Info(displayName: "in", precedence: 5, arity: 2),
    add: Info(displayName: "+", precedence: 4, arity: 2),
    subtract: Info(displayName: "-", precedence: 4, arity: 2),
    divide: Info(displayName: "/", precedence: 3, arity: 2),
    modulo: Info(displayName: "%", precedence: 3, arity: 2),
    multiply: Info(displayName: "*", precedence: 3, arity: 2),
    logicalNot: Info(displayName: "!", precedence: 2, arity: 1),
    negate: Info(displayName: "-", precedence: 2, arity: 1),
    index: Info(displayName: "", precedence: 1, arity: 2),
    optIndex: Info(displayName: "", precedence: 1, arity: 2),
    optSelect: Info(displayName: "", precedence: 1, arity: 2),
  ]

  /// Returns the operator function name for a source text operator such as `+`.
  package static func find(_ text: String) -> String? {
    operators[text]
  }

  /// Returns the display name of an operator function, or `nil` if it is not an operator.
  ///
  /// Operators that need special rendering (conditional, index) have an empty display name.
  package static func findReverse(_ symbol: String) -> String? {
    operatorMap[symbol]?.displayName
  }

  /// Returns the display name of a binary operator function, or `nil` when it is not one.
  package static func findReverseBinaryOperator(_ symbol: String) -> String? {
    guard let op = operatorMap[symbol], op.arity == 2, !op.displayName.isEmpty else {
      return nil
    }
    return op.displayName
  }

  /// Returns the precedence of an operator function (lower binds tighter), or 0 if unknown.
  package static func precedence(_ symbol: String) -> Int {
    operatorMap[symbol]?.precedence ?? 0
  }

  /// Returns the arity of an operator function, or -1 if unknown.
  package static func arity(_ symbol: String) -> Int {
    operatorMap[symbol]?.arity ?? -1
  }
}
