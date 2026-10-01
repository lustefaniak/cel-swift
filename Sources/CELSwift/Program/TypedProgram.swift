// A compiled expression or policy with Swift types on both ends: facts in, output out, both
// checked when it is loaded. Not a ported file.

import CEL
import CELPolicy

/// An expression or a policy compiled against a Swift facts type, evaluating to a Swift output
/// type.
///
/// Creating one does all the checking a rules file needs at load time:
///
/// - every property of `Facts` is declared as a variable with its type (see
///   `Environment.Option.variables(from:options:)`), so a misspelt or missing fact, a fact
///   of the wrong type, or a fact from another stage is a compile error;
/// - the expression's or policy's result type must decode as `Output`, and map literal outputs
///   must name `Output`'s fields with values of the right types;
/// - every problem is reported as a ``ValidationError`` with its line and column.
///
/// ```swift
/// struct SelectFacts: Codable {
///   var pr: ChangeRequest
///   var trigger: String
/// }
/// struct Selection: Codable {
///   var rule: String
///   var action: String
/// }
/// let select = try TypedProgram<SelectFacts, Selection>(
///   policy: PolicyParser().parse(PolicySource(yaml, description: "select.yaml")),
///   environment: Environment())
/// let selection = try select.evaluate(SelectFacts(pr: pr, trigger: "review_requested"))
/// ```
///
/// A typed program is an immutable `Sendable` value: compile it once and evaluate it from any
/// task. The evaluation methods encode the facts with ``CELEncoder``, evaluate, and decode the
/// result with ``CELDecoder``, all with the program's ``options``.
public struct TypedProgram<Facts: Codable, Output: Decodable>: Sendable {
  /// The environment the program was compiled in: the given environment with the facts declared
  /// (and, for a policy, optional types and `cel.@block`).
  public let environment: Environment
  /// The checked expression; for a policy, the policy composed into one expression whose
  /// positions are in the policy file.
  public let expression: CheckedExpression
  /// The schema of `Facts`: the declared variables and object types.
  public let factsSchema: CELSchema
  /// How facts are encoded and outputs decoded.
  public let options: CELCodingOptions

  let program: Program
  let partialProgram: Program
  let explainProgram: Program
  let templates: [ConditionTemplate]

  /// Compiles an expression.
  ///
  /// ```swift
  /// let usesSplit = try TypedProgram<PlanFacts, Bool>(
  ///   expression: "pr.repo == 'acme/monorepo' && size(pr.files) > 20", environment: Environment())
  /// ```
  ///
  /// - Parameters:
  ///   - expression: The CEL expression.
  ///   - sourceName: The name of the source in error messages, such as the file and key the
  ///     expression came from.
  ///   - environment: The functions, libraries and other declarations besides the facts.
  ///   - options: How facts are encoded and the output decoded.
  ///   - programOptions: Evaluation options such as `Program.Option.costLimit(_:)`.
  /// - Throws: ``ValidationError`` with every syntax, type and output problem.
  public init(
    expression: String, sourceName: String = "<input>", environment: Environment,
    options: CELCodingOptions = CELCodingOptions(), programOptions: [Program.Option] = []
  ) throws(ValidationError) {
    let (factsSchema, outputSchema, env) = try Self.prepare(environment, options: options, sourceName: sourceName)
    let checked: CheckedExpression
    do throws(CompileError) {
      checked = try env.compile(expression, sourceName: sourceName)
    } catch {
      throw ValidationError(error)
    }
    var checker = OutputChecker(
      schema: outputSchema, outputIsOptional: Output.self is any OptionalMarker.Type, source: checked.source)
    let root = checked.ast.expr
    checker.checkResultType(
      checked.outputType, location: checked.ast.sourceInfo.startLocation(root.id), exprID: root.id, isPolicy: false)
    checker.checkLiteral(root, expected: outputSchema.type, in: checked.ast)
    if !checker.errors.isEmpty {
      throw ValidationError(checker.errors)
    }
    let builder = ExplanationBuilder(source: checked.sourceText, evaluated: checked.ast)
    try self.init(
      environment: env, expression: checked, factsSchema: factsSchema, options: options,
      programOptions: programOptions, templates: [builder.expressionTemplate()])
  }

  /// Compiles a policy.
  ///
  /// The policy's outputs must decode as `Output`. A first-match policy whose matches all have
  /// conditions produces no output when none applies: decode it as an `Optional`. An aggregate
  /// policy produces a list: decode it as an array.
  ///
  /// - Parameters:
  ///   - policy: A parsed policy, from `PolicyParser`.
  ///   - environment: The functions, libraries and other declarations besides the facts.
  ///   - options: How facts are encoded and the output decoded.
  ///   - compiler: The policy compiler and its limits.
  ///   - programOptions: Evaluation options such as `Program.Option.costLimit(_:)`.
  /// - Throws: ``ValidationError`` with every compile and output problem, positioned in the
  ///   policy file.
  public init(
    policy: Policy, environment: Environment, options: CELCodingOptions = CELCodingOptions(),
    compiler: PolicyCompiler = PolicyCompiler(), programOptions: [Program.Option] = []
  ) throws(ValidationError) {
    let sourceName = policy.source.description
    let (factsSchema, outputSchema, env) = try Self.prepare(environment, options: options, sourceName: sourceName)
    let compiled: CompiledPolicy
    do throws(PolicyError) {
      compiled = try compiler.compile(policy, environment: env)
    } catch {
      throw ValidationError(error)
    }
    let checked = compiled.expression
    var checker = OutputChecker(
      schema: outputSchema, outputIsOptional: Output.self is any OptionalMarker.Type, source: checked.source)
    var templates: [ConditionTemplate] = []
    if let rule = compiled.rule {
      let anchor = firstOutput(rule)
      checker.checkResultType(
        checked.outputType, location: anchor.map { $0.sourceInfo.startLocation($0.expr.id) } ?? .none,
        exprID: anchor?.expr.id ?? 0, isPolicy: true)
      checker.checkPolicy(rule, expected: outputSchema.type)
      templates = ExplanationBuilder(source: checked.sourceText, evaluated: checked.ast).policyTemplates(rule)
    } else {
      checker.checkResultType(checked.outputType, location: .none, exprID: 0, isPolicy: true)
    }
    if !checker.errors.isEmpty {
      throw ValidationError(checker.errors)
    }
    try self.init(
      environment: compiled.environment, expression: checked, factsSchema: factsSchema, options: options,
      programOptions: programOptions, templates: templates)
  }

  /// Parses and compiles a policy file.
  ///
  /// ```swift
  /// let decide = try TypedProgram<DecideFacts, Decision>(
  ///   policy: PolicySource(yaml, description: "decide.yaml"), environment: base)
  /// ```
  ///
  /// - Parameters:
  ///   - source: The policy YAML and its name in error messages.
  ///   - environment: The functions, libraries and other declarations besides the facts.
  ///   - options: How facts are encoded and the output decoded.
  ///   - parser: The policy parser, with any custom tag visitor.
  ///   - compiler: The policy compiler and its limits.
  ///   - programOptions: Evaluation options such as `Program.Option.costLimit(_:)`.
  /// - Throws: ``ValidationError`` with every YAML, compile and output problem, positioned in the
  ///   policy file.
  public init(
    policy source: PolicySource, environment: Environment, options: CELCodingOptions = CELCodingOptions(),
    parser: PolicyParser = PolicyParser(), compiler: PolicyCompiler = PolicyCompiler(),
    programOptions: [Program.Option] = []
  ) throws(ValidationError) {
    let policy: Policy
    do throws(PolicyError) {
      policy = try parser.parse(source)
    } catch {
      throw ValidationError(error)
    }
    try self.init(
      policy: policy, environment: environment, options: options, compiler: compiler, programOptions: programOptions)
  }

  private init(
    environment: Environment, expression: CheckedExpression, factsSchema: CELSchema, options: CELCodingOptions,
    programOptions: [Program.Option], templates: [ConditionTemplate]
  ) throws(ValidationError) {
    self.environment = environment
    self.expression = expression
    self.factsSchema = factsSchema
    self.options = options
    self.templates = templates
    do throws(CompileError) {
      self.program = try environment.program(expression, options: programOptions)
      self.partialProgram = try environment.program(expression, options: programOptions + [.partialEvaluation])
      self.explainProgram = try environment.program(
        expression, options: programOptions + [.trackState, .exhaustiveEvaluation, .errorsAsValues])
    } catch {
      throw ValidationError(error)
    }
  }

  /// Derives the facts and output schemas and declares the facts.
  private static func prepare(
    _ environment: Environment, options: CELCodingOptions, sourceName: String
  ) throws(ValidationError) -> (facts: CELSchema, output: CELSchema, environment: Environment) {
    do throws(DeclarationError) {
      let factsSchema = try CELSchema(for: Facts.self, options: options)
      let outputSchema = try CELSchema(for: Output.self, options: options)
      // The output's object types are registered too, so policies can build outputs with struct
      // literals the checker verifies.
      let env = try environment.extending(
        .variables(from: Facts.self, options: options), .types(Output.self, options: options))
      return (factsSchema, outputSchema, env)
    } catch {
      throw ValidationError(error, sourceName: sourceName)
    }
  }

  // MARK: - Evaluation

  /// Evaluates the program with facts.
  ///
  /// - Parameter facts: The facts, encoded with ``options``.
  /// - Returns: The decoded output.
  /// - Throws: ``EvaluationError`` when the facts cannot be encoded, evaluation fails (with the
  ///   position of the failing sub-expression), or the result does not decode as `Output`.
  public func evaluate(_ facts: Facts) throws(EvaluationError) -> Output {
    let result = run(program, try variables(facts))
    return try decode(result.value)
  }

  /// Evaluates the program with some facts not known yet, deciding without them when it can.
  ///
  /// Attributes matching `unknowns` are treated as unknown: when the output does not depend on
  /// them (`false && signals.mechanical > 0.9`) it is decided; otherwise the outcome lists the
  /// attributes it needs.
  ///
  /// ```swift
  /// switch try select.evaluate(facts, unknowns: [UnknownPattern("signals").wildcard()]) {
  /// case .value(let selection): use(selection)
  /// case .unknown(let missing): fetch(missing)   // e.g. [signals.mechanical]
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - facts: The known facts; the values under unknown attributes are ignored.
  ///   - unknowns: Patterns of the attributes that are not known yet.
  /// - Returns: The output, or the unknown attributes it depends on.
  /// - Throws: ``EvaluationError`` as ``evaluate(_:)`` does.
  public func evaluate(_ facts: Facts, unknowns: [UnknownPattern]) throws(EvaluationError) -> EvaluationOutcome<Output> {
    var variables = try variables(facts)
    variables.unknowns = unknowns
    let result = run(partialProgram, variables)
    if case .unknown(let unknown) = result.value {
      return .unknown(missing: unknown.attributes)
    }
    return .value(try decode(result.value))
  }

  /// Evaluates the program, fetching facts that are expensive to get only when the output
  /// depends on them.
  ///
  /// The program first runs with every attribute matching `unknowns` unknown. While the output
  /// depends on unknown attributes, `resolve` is called with them to fill them into the facts,
  /// and the program runs again with those attributes known. A resolver that cannot get a value
  /// leaves it `nil`, so rules can test it with `has()`.
  ///
  /// ```swift
  /// let selection = try await select.evaluate(
  ///   facts, unknowns: [UnknownPattern("signals").wildcard()]
  /// ) { missing, facts in
  ///   // missing: [signals.mechanical]; one request for everything still needed
  ///   facts.signals = try await signalService.fetch(missing.map(\.description), for: facts.pr)
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - facts: The facts known up front.
  ///   - unknowns: Patterns of the attributes to fetch lazily.
  ///   - isolation: The actor `resolve` runs on; the caller's by default.
  ///   - resolve: Called with the attributes the output depends on; fills them into the facts.
  /// - Returns: The decoded output.
  /// - Throws: ``EvaluationError`` as ``evaluate(_:)`` does, or what `resolve` throws.
  public func evaluate(
    _ facts: Facts, unknowns: [UnknownPattern], isolation: isolated (any Actor)? = #isolation,
    resolve: (_ missing: [AttributeTrail], _ facts: inout Facts) async throws -> Void
  ) async throws -> Output where Facts: Sendable {
    var facts = facts
    var pending = unknowns
    while true {
      switch try evaluate(facts, unknowns: pending) {
      case .value(let output):
        return output
      case .unknown(let missing):
        let resolved = pending.filter { pattern in missing.contains { pattern.covers($0) } }
        guard !resolved.isEmpty else {
          throw EvaluationError(
            message: "the output depends on unknown attributes no pattern names: "
              + missing.map(\.description).joined(separator: ", "),
            sourceName: expression.sourceName)
        }
        try await resolve(missing, &facts)
        pending.removeAll { pattern in resolved.contains(pattern) }
      }
    }
  }

  /// Evaluates the program and explains the result condition by condition.
  ///
  /// The program runs exhaustively with state tracking, so every condition and predicate has a
  /// value. Evaluation errors do not throw: they are the explanation's
  /// ``Explanation/result``, and the conditions show which predicate failed.
  ///
  /// - Parameter facts: The facts.
  /// - Returns: The explanation, with the output or the error.
  /// - Throws: ``EvaluationError`` only when the facts cannot be encoded.
  public func explain(_ facts: Facts) throws(EvaluationError) -> Explanation<Output> {
    let result = run(explainProgram, try variables(facts))
    let output: Result<Output, EvaluationError>
    do throws(EvaluationError) {
      output = .success(try decode(result.value))
    } catch {
      output = .failure(error)
    }
    return Explanation(
      result: output, conditions: templates.map { $0.condition(result.state) }, sourceName: expression.sourceName)
  }

  // MARK: - Helpers

  private func variables(_ facts: Facts) throws(EvaluationError) -> Variables {
    do {
      return try Variables(encoding: facts, options: options)
    } catch let error as EncodingError {
      throw EvaluationError(message: "cannot encode the facts: \(error.message)", sourceName: expression.sourceName)
    } catch {
      throw EvaluationError(message: "cannot encode the facts: \(error)", sourceName: expression.sourceName)
    }
  }

  private func run(_ program: Program, _ variables: Variables) -> EvaluationResult {
    do {
      return try program.evaluate(variables)
    } catch {
      return EvaluationResult(value: .error(error))
    }
  }

  private func decode(_ value: Value) throws(EvaluationError) -> Output {
    if case .error(let error) = value {
      throw EvaluationError(evalError: error, expression: expression)
    }
    do {
      return try decodeValue(Output.self, from: value, options: options, codingPath: [])
    } catch let error as DecodingError {
      throw EvaluationError(
        message: "cannot decode the result as \(Output.self): \(error.message)", sourceName: expression.sourceName)
    } catch {
      throw EvaluationError(
        message: "cannot decode the result as \(Output.self): \(error)", sourceName: expression.sourceName)
    }
  }
}

/// The output of a partial evaluation: decided, or waiting for unknown attributes.
public enum EvaluationOutcome<Output> {
  /// The output, decided without the unknown attributes.
  case value(Output)
  /// The output depends on these unknown attributes, such as `signals.mechanical`.
  case unknown(missing: [AttributeTrail])

  /// The output when decided, `nil` when it depends on unknown attributes.
  public var value: Output? {
    if case .value(let output) = self {
      return output
    }
    return nil
  }
}

extension EvaluationOutcome: Sendable where Output: Sendable {}

extension UnknownSet {
  /// The distinct attributes of the set, in the order of their expression ids.
  var attributes: [AttributeTrail] {
    var result: [AttributeTrail] = []
    for id in expressionIDs {
      for trail in attributeTrails(forExpressionID: id) ?? [] where !result.contains(trail) {
        result.append(trail)
      }
    }
    return result
  }
}

extension UnknownPattern {
  /// Whether the pattern made the attribute unknown: same variable, and the qualifiers agree as
  /// far as both go (a wildcard matches any qualifier).
  func covers(_ trail: AttributeTrail) -> Bool {
    guard pattern.variable == trail.variable else { return false }
    for (qualifier, pattern) in zip(trail.qualifierPath, pattern.qualifierPatterns) {
      if let value = pattern.value, !qualifiersMatch(value, qualifier) {
        return false
      }
    }
    return true
  }
}

/// Whether two qualifiers select the same element: equal, or numerically equal integers.
private func qualifiersMatch(_ lhs: AttributeQualifier, _ rhs: AttributeQualifier) -> Bool {
  switch (lhs, rhs) {
  case (.int(let i), .uint(let u)), (.uint(let u), .int(let i)): return i >= 0 && UInt64(i) == u
  default: return lhs == rhs
  }
}

/// The first output of a compiled rule, where problems with the policy's output type are
/// reported.
private func firstOutput(_ rule: CompiledRule) -> AST? {
  for match in rule.matches {
    if let output = match.output?.expr {
      return output
    }
    if let nested = match.nestedRule, let output = firstOutput(nested) {
      return output
    }
  }
  return nil
}
