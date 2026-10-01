// Copyright 2019 Google LLC
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
// Re-designed from cel-go cel/env.go `Ast` and cel/io.go `AstToString`. cel-go has one `Ast` type
// with an `IsChecked` flag; here parsed and checked expressions are separate types, so APIs that
// need type information (output type, cost estimation) take only checked ones.

/// An expression that has been parsed but not type-checked.
///
/// Create one with ``Environment/parse(_:sourceName:)``. It can be checked with
/// ``Environment/check(_:)`` or evaluated directly, without type information, through
/// ``Environment/program(_:options:)-(ParsedExpression,_)``.
public struct ParsedExpression: Sendable, CustomStringConvertible {
  package var ast: AST
  package let source: any Source

  package init(ast: AST, source: any Source) {
    self.ast = ast
    self.source = source
  }

  /// The source text the expression was parsed from.
  public var sourceText: String { source.content }

  /// The name of the source in error messages, `<input>` by default.
  public var sourceName: String { source.description }

  /// The expression printed back as CEL text (cel-go `AstToString`).
  ///
  /// Macros are printed in their original form when the environment tracks macro calls.
  public var description: String { unparse(ast) }
}

/// A type-checked expression: every identifier and function call is resolved and every
/// sub-expression has a type.
///
/// Create one with ``Environment/compile(_:sourceName:)`` or ``Environment/check(_:)``, and
/// evaluate it with a ``Program`` from ``Environment/program(_:options:)-(CheckedExpression,_)``.
public struct CheckedExpression: Sendable, CustomStringConvertible {
  package var ast: AST
  package let source: any Source

  package init(ast: AST, source: any Source) {
    self.ast = ast
    self.source = source
  }

  /// The type the expression evaluates to (cel-go `Ast.OutputType`).
  public var outputType: CELType { ast.type(of: ast.expr.id) }

  /// The source text the expression was parsed from.
  public var sourceText: String { source.content }

  /// The name of the source in error messages, `<input>` by default.
  public var sourceName: String { source.description }

  /// The expression printed back as CEL text (cel-go `AstToString`).
  ///
  /// Identifiers appear with the fully qualified names the checker resolved.
  public var description: String { unparse(ast) }

  /// The type the checker deduced for a sub-expression, or `nil` for an unknown id.
  ///
  /// Expression ids appear in ``EvaluationState`` and ``CompileError/Issue/expressionID``.
  public func type(ofExpressionID id: Int64) -> CELType? {
    ast.typeMap[id]
  }

  /// The 1-based line and column (counted in Unicode scalars) where a sub-expression starts,
  /// or `nil` when the id has no recorded position.
  public func location(ofExpressionID id: Int64) -> (line: Int, column: Int)? {
    let location = ast.sourceInfo.startLocation(id)
    guard location.line >= 1, location.column >= 0 else {
      return nil
    }
    return (location.line, location.column + 1)
  }
}

private func unparse(_ ast: AST) -> String {
  (try? Unparser.unparse(ast.expr, sourceInfo: ast.sourceInfo)) ?? "<unprintable>"
}
