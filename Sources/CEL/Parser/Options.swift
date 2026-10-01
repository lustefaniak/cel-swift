// Copyright 2021 Google LLC
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

// Ported from cel-go parser/options.go.

/// An invalid parser option value.
package struct ParserOptionError: Error, Equatable, CustomStringConvertible {
  package let description: String
}

/// A parser configuration option (cel-go `parser.Option`).
package enum ParserOption: Sendable {
  /// Limits the depth the parser will descend before giving up; -1 disables the limit.
  case maxRecursionDepth(Int)
  /// Limits the tokens considered by one error recovery attempt (must be at least 1).
  case errorRecoveryLookaheadTokenLimit(Int)
  /// Limits the number of error recovery attempts; -1 disables the limit.
  case errorRecoveryLimit(Int)
  /// Limits the number of syntax errors reported before parsing stops (must be at least 1).
  case errorReportingLimit(Int)
  /// Limits the expression size in code points; -1 disables the limit.
  case expressionSizeCodePointLimit(Int)
  /// Limits the expression nodes emitted, including by macro expansion; -1 disables the limit.
  case maxExpressionNodeCount(Int)
  /// Adds macros, replacing earlier macros with the same key.
  case macros([Macro])
  /// Records the original calls replaced by macro expansions in the source info.
  case populateMacroCalls(Bool)
  /// Enables `.?`, `[?` and `?` optional syntax.
  case enableOptionalSyntax(Bool)
  /// Enables backtick-quoted field names such as ``foo.`bar-baz` ``.
  case enableIdentEscapeSyntax(Bool)
  /// Uses `@result` instead of `__result__` as the comprehension accumulator name.
  case enableHiddenAccumulatorName(Bool)
  /// Represents chains of `&&` / `||` as one call with many arguments.
  case enableVariadicOperatorASTs(Bool)
}

/// The resolved parser configuration.
package struct ParserOptions: Sendable {
  package var maxRecursionDepth = 0
  package var errorReportingLimit = 0
  package var errorRecoveryTokenLookaheadLimit = 0
  package var errorRecoveryLimit = 0
  package var expressionSizeCodePointLimit = 0
  package var maxExpressionNodeCount = 0
  package var macros: [String: Macro] = [:]
  package var populateMacroCalls = false
  package var enableOptionalSyntax = false
  package var enableVariadicOperatorASTs = false
  package var enableIdentEscapeSyntax = true
  package var enableHiddenAccumulatorName = true

  /// Applies `options` in order on top of cel-go's defaults.
  package init(_ options: [ParserOption]) throws(ParserOptionError) {
    for option in options {
      try apply(option)
    }
    if errorReportingLimit == 0 {
      errorReportingLimit = 100
    }
    if maxRecursionDepth == 0 {
      maxRecursionDepth = 250
    }
    if maxRecursionDepth == -1 {
      maxRecursionDepth = Int.max
    }
    if errorRecoveryTokenLookaheadLimit == 0 {
      errorRecoveryTokenLookaheadLimit = 256
    }
    if errorRecoveryLimit == 0 {
      errorRecoveryLimit = 30
    }
    if errorRecoveryLimit == -1 {
      errorRecoveryLimit = Int.max
    }
    if expressionSizeCodePointLimit == 0 {
      expressionSizeCodePointLimit = 100_000
    }
    if expressionSizeCodePointLimit == -1 {
      expressionSizeCodePointLimit = Int.max
    }
    if maxExpressionNodeCount == 0 {
      maxExpressionNodeCount = 100_000
    }
    if maxExpressionNodeCount == -1 {
      maxExpressionNodeCount = Int.max
    }
  }

  private mutating func apply(_ option: ParserOption) throws(ParserOptionError) {
    switch option {
    case .maxRecursionDepth(let limit):
      if limit < -1 {
        throw ParserOptionError(
          description: "max recursion depth must be greater than or equal to -1: \(limit)")
      }
      maxRecursionDepth = limit
    case .errorRecoveryLookaheadTokenLimit(let limit):
      if limit < 1 {
        throw ParserOptionError(
          description: "error recovery lookahead token limit must be at least 1: \(limit)")
      }
      errorRecoveryTokenLookaheadLimit = limit
    case .errorRecoveryLimit(let limit):
      if limit < -1 {
        throw ParserOptionError(
          description: "error recovery limit must be greater than or equal to -1: \(limit)")
      }
      errorRecoveryLimit = limit
    case .errorReportingLimit(let limit):
      if limit < 1 {
        throw ParserOptionError(description: "error reporting limit must be at least 1: \(limit)")
      }
      errorReportingLimit = limit
    case .expressionSizeCodePointLimit(let limit):
      if limit < -1 {
        throw ParserOptionError(
          description:
            "expression size code point limit must be greater than or equal to -1: \(limit)")
      }
      expressionSizeCodePointLimit = limit
    case .maxExpressionNodeCount(let limit):
      if limit < -1 {
        throw ParserOptionError(
          description: "max expression node count must be greater than or equal to -1: \(limit)")
      }
      maxExpressionNodeCount = limit
    case .macros(let list):
      for m in list {
        macros[m.key] = m
      }
    case .populateMacroCalls(let v):
      populateMacroCalls = v
    case .enableOptionalSyntax(let v):
      enableOptionalSyntax = v
    case .enableIdentEscapeSyntax(let v):
      enableIdentEscapeSyntax = v
    case .enableHiddenAccumulatorName(let v):
      enableHiddenAccumulatorName = v
    case .enableVariadicOperatorASTs(let v):
      enableVariadicOperatorASTs = v
    }
  }
}
