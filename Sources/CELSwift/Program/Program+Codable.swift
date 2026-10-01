// Evaluating a core Program with Encodable facts and a Decodable result. Not a ported file.

import CEL

extension Program {
  /// Evaluates the program with the properties of a facts struct as variables and decodes the
  /// result.
  ///
  /// ```swift
  /// let env = try Environment(.variables(from: SelectFacts.self))
  /// let program = try env.program(env.compile("pr.additions + pr.deletions"))
  /// let size: Int = try program.evaluate(facts)
  /// ```
  ///
  /// ``TypedProgram`` does the same and also checks at compile time that the result decodes.
  ///
  /// - Parameters:
  ///   - facts: A value whose encoding is keyed, such as a struct; each property is a variable.
  ///   - type: The type to decode the result as.
  ///   - options: How facts are encoded and the result decoded.
  /// - Returns: The decoded result.
  /// - Throws: `EncodingError` when the facts cannot be encoded, `EvalError` when evaluation
  ///   fails, `DecodingError` when the result does not decode as `Output`.
  public func evaluate<Output: Decodable>(
    _ facts: some Encodable, as type: Output.Type = Output.self, options: CELCodingOptions = CELCodingOptions()
  ) throws -> Output {
    let result = try evaluate(Variables(encoding: facts, options: options))
    return try decodeValue(Output.self, from: result.value, options: options, codingPath: [])
  }
}
