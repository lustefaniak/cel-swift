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
// Ported from cel-go cel/env.go (Env.ResidualAst).

extension Environment {
  /// The part of an expression still to be decided after a partial evaluation (cel-go
  /// `Env.ResidualAst`).
  ///
  /// Evaluate with ``Program/Option/partialEvaluation`` and ``Program/Option/trackState`` (or
  /// ``Program/Option/exhaustiveEvaluation``), then pass the recorded state: sub-expressions with a
  /// known value become literals and logical operators, conditionals and `in` with known operands
  /// are simplified, leaving only what depends on the unknown attributes.
  ///
  /// ```swift
  /// let checked = try env.compile("x < 10 && (y == 0 || 'hello' != 'goodbye')")
  /// let program = try env.program(checked, options: [.partialEvaluation, .trackState])
  /// let result = try program.evaluate(env.partialVariables())
  /// try env.residual(of: checked, state: result.state!).description   // x < 10
  /// ```
  ///
  /// - Parameters:
  ///   - expression: The checked expression the program was created from.
  ///   - state: The evaluation state of a partial evaluation.
  /// - Returns: The residual expression, checked by this environment.
  /// - Throws: ``CompileError`` when the residual expression cannot be printed or does not check.
  public func residual(of expression: CheckedExpression, state: EvaluationState) throws(CompileError) -> CheckedExpression {
    try check(residualParse(expression.ast, source: expression.source, state: state))
  }

  /// The part of a parse-only expression still to be decided after a partial evaluation (cel-go
  /// `Env.ResidualAst`).
  ///
  /// - Parameters:
  ///   - expression: The parsed expression the program was created from.
  ///   - state: The evaluation state of a partial evaluation.
  /// - Returns: The residual expression, parsed by this environment.
  /// - Throws: ``CompileError`` when the residual expression cannot be printed or parsed.
  public func residual(of expression: ParsedExpression, state: EvaluationState) throws(CompileError) -> ParsedExpression {
    try residualParse(expression.ast, source: expression.source, state: state)
  }

  /// Prunes the AST with the state, prints it and parses the text again, as cel-go does.
  private func residualParse(_ ast: AST, source: any Source, state: EvaluationState) throws(CompileError) -> ParsedExpression {
    let recorder = EvalStateRecorder()
    for (id, value) in state.values {
      recorder.setValue(id, value)
    }
    let pruned = pruneAST(ast.expr, macroCalls: ast.sourceInfo.macroCalls, state: recorder)
    let text: String
    do {
      text = try Unparser.unparse(pruned.expr, sourceInfo: pruned.sourceInfo)
    } catch {
      throw CompileError(message: error.description, source: source)
    }
    return try parse(text, sourceName: source.description)
  }
}
