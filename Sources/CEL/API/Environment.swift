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
// The public environment, re-designed from cel-go cel/env.go (Env, NewEnv, NewCustomEnv, Extend,
// Parse, Check, Compile, Program). cel-go's Env is a mutable object with lazily initialised,
// mutex-guarded checker and dispatcher; here it is an immutable value whose checker environment,
// parser and dispatcher are built eagerly when it is created, so declaration conflicts surface
// from the initializer and every later call is read-only.

/// The declarations, libraries and options CEL expressions are compiled against.
///
/// An environment is an immutable, `Sendable` value. Create one with the standard library and
/// your declarations, then compile expressions and create programs from it:
///
/// ```swift
/// let env = try Environment(
///   .variable("pr", .map(key: .string, value: .dyn)),
///   .container("prbar")
/// )
/// let expression = try env.compile("pr.additions <= 200")
/// let program = try env.program(expression)
/// let result = try program.evaluate(["pr": ["additions": 120]])
/// ```
///
/// Use ``extending(_:)`` to derive an environment with more declarations; the original is not
/// affected. Environments are cheap to share between threads and tasks.
///
/// Parsing gets faster as an environment is used: the parser's prediction cache, shared by the
/// environment, its copies and the environments extended from it, learns the grammar paths the
/// parsed expressions take. Keep a long-lived environment rather than creating one per expression.
public struct Environment: Sendable {
  package let configuration: Configuration
  package let checkerEnv: CheckerEnv
  package let parser: Parser
  package let dispatcher: Dispatcher

  /// Creates an environment with the CEL standard library and the given options.
  ///
  /// - Parameter options: Declarations, libraries and features, applied in order on top of the
  ///   standard library.
  /// - Throws: ``DeclarationError`` when a declaration conflicts with another one or an option
  ///   is invalid.
  public init(_ options: Option...) throws(DeclarationError) {
    try self.init(options: options)
  }

  /// Creates an environment with the CEL standard library and the given options.
  ///
  /// - Parameter options: Declarations, libraries and features, applied in order on top of the
  ///   standard library.
  /// - Throws: ``DeclarationError`` when a declaration conflicts with another one or an option
  ///   is invalid.
  public init(options: [Option]) throws(DeclarationError) {
    try self.init(configuration: Configuration(), options: [.standardLibrary] + options)
  }

  /// Creates an environment without the standard library (cel-go `NewCustomEnv`).
  ///
  /// Use this to expose a subset of CEL: only the functions, macros and types the options declare
  /// are available. Add ``Option/standardLibrary`` to start from the full standard library.
  ///
  /// - Parameter options: Declarations, libraries and features, applied in order.
  /// - Throws: ``DeclarationError`` when a declaration conflicts with another one or an option
  ///   is invalid.
  public static func custom(_ options: Option...) throws(DeclarationError) -> Environment {
    try Environment(configuration: Configuration(), options: options)
  }

  /// Creates an environment without the standard library (cel-go `NewCustomEnv`).
  ///
  /// - Parameter options: Declarations, libraries and features, applied in order.
  /// - Throws: ``DeclarationError`` when a declaration conflicts with another one or an option
  ///   is invalid.
  public static func custom(options: [Option]) throws(DeclarationError) -> Environment {
    try Environment(configuration: Configuration(), options: options)
  }

  /// Returns a new environment with the options of this one followed by `options`
  /// (cel-go `Env.Extend`).
  ///
  /// - Parameter options: Additional declarations, libraries and features.
  /// - Throws: ``DeclarationError`` when a new declaration conflicts with an existing one.
  public func extending(_ options: Option...) throws(DeclarationError) -> Environment {
    try extending(options: options)
  }

  /// Returns a new environment with the options of this one followed by `options`
  /// (cel-go `Env.Extend`).
  ///
  /// - Parameter options: Additional declarations, libraries and features.
  /// - Throws: ``DeclarationError`` when a new declaration conflicts with an existing one.
  public func extending(options: [Option]) throws(DeclarationError) -> Environment {
    try Environment(base: self, configuration: configuration, options: options)
  }

  package init(configuration: Configuration, options: [Option]) throws(DeclarationError) {
    try self.init(base: nil, configuration: configuration, options: options)
  }

  /// Applies `options` to `configuration`. When `base` is the environment `configuration` came
  /// from and the options leave its functions alone, the new checker environment inherits the
  /// base's validated declarations and the dispatcher is shared, as cel-go `Extend` does with
  /// `checker.ValidatedDeclarations`: declaring the functions again is the expensive part of
  /// building an environment.
  package init(base: Environment?, configuration: Configuration, options: [Option]) throws(DeclarationError) {
    var configuration = configuration
    let functionsGeneration = configuration.functionsGeneration
    for option in options {
      do {
        try option.apply(&configuration)
      } catch let error as DeclarationError {
        throw error
      } catch {
        throw DeclarationError("\(error)")
      }
    }
    do {
      try configuration.applyStrongEnums()
    } catch let error as DeclarationError {
      throw error
    } catch {
      throw DeclarationError("\(error)")
    }
    self.configuration = configuration
    do {
      // The prediction cache depends only on the grammar: extended environments keep warming the
      // base's.
      self.parser = try Parser(options: configuration.parserOptions, sharingPredictionCacheWith: base?.parser)
    } catch {
      throw DeclarationError(error.description)
    }
    let inherited = configuration.functionsGeneration == functionsGeneration ? base : nil
    do {
      var checkerOptions = configuration.checkerOptions
      if let inherited {
        checkerOptions.append(.validatedDeclarations(inherited.checkerEnv))
      }
      var env = CheckerEnv(
        container: configuration.container, provider: configuration.registry, options: checkerOptions)
      try env.addIdents(configuration.variables)
      if let inherited {
        self.dispatcher = inherited.dispatcher
      } else {
        try env.addFunctions(configuration.functions.filter { !$0.isDeclarationDisabled })
        self.dispatcher = try Dispatcher(functions: configuration.functions)
      }
      self.checkerEnv = env
    } catch let error as DeclarationError {
      throw error
    } catch {
      throw DeclarationError("\(error)")
    }
  }

  // MARK: - Introspection

  /// The container unqualified names are resolved in.
  public var container: Container { configuration.container }

  /// The declared variables, including the standard type identifiers such as `int`.
  public var variables: [VariableDecl] { configuration.variables }

  /// The declared functions, in declaration order.
  public var functions: [FunctionDecl] { configuration.functions }

  /// The names of the libraries configured in the environment, such as `cel.lib.std`.
  public var libraryNames: [String] { configuration.libraryNames }

  /// Whether the environment declares a function with the given name.
  public func hasFunction(named name: String) -> Bool {
    configuration.functions.contains { $0.name == name }
  }

  /// Whether a library with the given name is configured.
  public func hasLibrary(named name: String) -> Bool {
    configuration.libraryNames.contains(name)
  }

  /// The type provider expressions are checked and evaluated with.
  public var typeProvider: any TypeProvider { configuration.registry }

  // MARK: - Compilation

  /// Parses an expression without type-checking it (cel-go `Env.Parse`).
  ///
  /// Parse-only expressions can be evaluated, but without type information functions are
  /// resolved at runtime by name, and declared variables are not validated.
  ///
  /// - Parameters:
  ///   - text: The CEL expression.
  ///   - sourceName: The name used for the source in error messages.
  /// - Returns: The parsed expression.
  /// - Throws: ``CompileError`` with the syntax errors.
  public func parse(_ text: String, sourceName: String = "<input>") throws(CompileError) -> ParsedExpression {
    let source = try makeSource(text, sourceName: sourceName)
    return try parse(source: source)
  }

  package func parse(source: any Source) throws(CompileError) -> ParsedExpression {
    let (ast, errors) = parser.parse(source)
    if !errors.isEmpty {
      throw CompileError(errors)
    }
    return ParsedExpression(ast: ast, source: source)
  }

  /// Type-checks a parsed expression (cel-go `Env.Check`).
  ///
  /// - Parameter expression: An expression parsed by an environment with the same macros.
  /// - Returns: The checked expression, with resolved references and types.
  /// - Throws: ``CompileError`` with the type errors, or the issues found by validators.
  public func check(_ expression: ParsedExpression) throws(CompileError) -> CheckedExpression {
    let source = expression.source
    let nodeLimit = configuration.expressionNodeLimit
    if nodeLimit > 0 {
      let count = expression.ast.nodeCount
      if count > nodeLimit {
        throw CompileError(
          message: "expression node count exceeds limit: count \(count), limit \(nodeLimit)",
          source: source)
      }
    }
    let (checked, errors) = Checker.check(expression.ast, source: source, env: checkerEnv)
    if !errors.isEmpty {
      throw CompileError(errors)
    }
    let result = CheckedExpression(ast: checked, source: source)
    try validate(result)
    return result
  }

  /// Parses and type-checks an expression (cel-go `Env.Compile`).
  ///
  /// - Parameters:
  ///   - text: The CEL expression.
  ///   - sourceName: The name used for the source in error messages.
  /// - Returns: The checked expression.
  /// - Throws: ``CompileError`` with the syntax or type errors.
  public func compile(_ text: String, sourceName: String = "<input>") throws(CompileError) -> CheckedExpression {
    try check(parse(text, sourceName: sourceName))
  }

  func makeSource(_ text: String, sourceName: String) throws(CompileError) -> TextSource {
    do {
      return try TextSource(text, description: sourceName, limit: configuration.expressionSizeLimit)
    } catch {
      throw CompileError(message: error.description, source: TextSource("", description: sourceName))
    }
  }

  // MARK: - Programs

  /// Creates a program evaluating a checked expression (cel-go `Env.Program`).
  ///
  /// - Parameters:
  ///   - expression: An expression checked by this environment or one it extends.
  ///   - options: Evaluation options such as cost limits and state tracking.
  /// - Returns: A program that can be evaluated any number of times, concurrently.
  /// - Throws: ``CompileError`` when the expression cannot be planned, for example because a
  ///   function has no runtime binding.
  public func program(_ expression: CheckedExpression, options: [Program.Option] = []) throws(CompileError) -> Program {
    try makeProgram(expression.ast, source: expression.source, options: options)
  }

  /// Creates a program evaluating a parse-only expression (cel-go `Env.Program` with an
  /// unchecked AST).
  ///
  /// - Parameters:
  ///   - expression: An expression parsed by this environment.
  ///   - options: Evaluation options such as cost limits and state tracking.
  /// - Returns: A program that can be evaluated any number of times, concurrently.
  /// - Throws: ``CompileError`` when the expression cannot be planned.
  public func program(_ expression: ParsedExpression, options: [Program.Option] = []) throws(CompileError) -> Program {
    try makeProgram(expression.ast, source: expression.source, options: options)
  }

  /// Estimates the cost of a checked expression with the environment's library cost estimators
  /// (cel-go `Env.EstimateCost`).
  package func estimateCostDetails(
    _ expression: CheckedExpression, estimator: any CostEstimator = DefaultCostEstimator(),
    presenceTestHasCost: Bool = true
  ) -> CostEstimate {
    var options = configuration.costEstimateOptions
    options.presenceTestHasCost = presenceTestHasCost
    return Checker.estimateCost(expression.ast, estimator: estimator, options: options)
  }

  package func makeProgram(_ ast: AST, source: any Source, options: [Program.Option]) throws(CompileError) -> Program {
    var settings = Program.Settings()
    for option in configuration.programOptions + options {
      option.apply(&settings)
    }
    // Only planning reads this environment: the parser settings are left out, building them costs
    // more than planning a small expression.
    var base = ProgramEnvironment(
      container: configuration.container,
      functions: configuration.functions,
      variables: configuration.variables,
      provider: configuration.registry,
      macros: [],
      parserOptions: [],
      errorOnBadPresenceTest: configuration.errorOnBadPresenceTest)
    base.decorators = configuration.decorators + settings.decorators
    base.costEstimateOptions = configuration.costEstimateOptions
    base.costTrackers = configuration.costTrackers
    do {
      var plannerOptions = settings.plannerOptions
      plannerOptions.regexProgramSizeLimit = configuration.regexProgramSizeLimit
      let planned = try base.program(ast, options: plannerOptions, dispatcher: dispatcher)
      return Program(planned: planned, settings: settings)
    } catch {
      throw CompileError(message: "\(error)", source: source)
    }
  }
}
