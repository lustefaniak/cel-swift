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
// Re-designed from cel-go cel/program.go (Program, EvalDetails, Eval, ContextEval) and the
// ProgramOption half of cel/options.go (EvalOptions, InterruptCheckFrequency, CostLimit,
// CostTracking, CustomDecorator). cel-go's `ContextEval` cancels through a Go context; here
// evaluation checks the current task's cancellation and an optional time limit.

/// An expression planned for evaluation (cel-go `Program`).
///
/// A program is an immutable `Sendable` value: evaluate it any number of times, from any thread
/// or task, with different variables.
///
/// ```swift
/// let program = try env.program(expression, options: [.costLimit(10_000), .trackState])
/// let result = try program.evaluate(["x": 3])
/// print(result.value, result.cost ?? 0)
/// ```
public struct Program: Sendable {
  package let planned: PlannedProgram
  package let settings: Settings

  package init(planned: PlannedProgram, settings: Settings) {
    self.planned = planned
    self.settings = settings
  }

  /// Evaluates the program with variable values.
  ///
  /// - Parameter variables: The values of the variables the expression uses, by name.
  /// - Returns: The value, with cost and state when the program tracks them.
  /// - Throws: ``EvalError`` when evaluation produces an error, unless the program was created
  ///   with ``Option/errorsAsValues``.
  public func evaluate(_ variables: [String: Value] = [:]) throws(EvalError) -> EvaluationResult {
    try evaluate(Variables(variables))
  }

  /// Evaluates the program with variables that may be computed on demand.
  ///
  /// Evaluation is synchronous. When the program checks for interrupts (see
  /// ``Option/interruptCheckFrequency(_:)`` and ``Option/timeLimit(_:)``), it also stops when the
  /// current task is cancelled, returning the `operation interrupted` error.
  ///
  /// - Parameter variables: The variable values and resolvers.
  /// - Returns: The value, with cost and state when the program tracks them.
  /// - Throws: ``EvalError`` when evaluation produces an error, unless the program was created
  ///   with ``Option/errorsAsValues``.
  public func evaluate(_ variables: Variables) throws(EvalError) -> EvaluationResult {
    var activation = variables.makeActivation()
    if !settings.globals.isEmpty {
      activation = HierarchicalActivation(parent: MapActivation(settings.globals), child: activation)
    }
    let result = run(activation)
    if !settings.errorsAsValues, case .error(let error) = result.value {
      throw error
    }
    return result
  }

  package func run(_ activation: any Activation) -> EvaluationResult {
    let raw: EvalResult
    if planned.interruptCheckFrequency > 0 {
      let deadline = settings.timeLimit.map { ContinuousClock.now.advanced(by: $0) }
      raw = withUnsafeCurrentTask { task in
        planned.eval(activation) {
          if let task, task.isCancelled {
            return true
          }
          if let deadline, ContinuousClock.now >= deadline {
            return true
          }
          return false
        }
      }
    } else {
      raw = planned.eval(activation)
    }
    return EvaluationResult(
      value: raw.value, cost: raw.actualCost, state: raw.state.map(EvaluationState.init))
  }
}

/// The outcome of evaluating a ``Program`` (cel-go's value and `EvalDetails`).
public struct EvaluationResult: Sendable {
  /// The value of the expression.
  ///
  /// An `.error` only when the program returns errors as values; `.unknown` when partial
  /// evaluation could not decide the result.
  public var value: Value
  /// The runtime cost of the evaluation, when the program tracks cost or has a cost limit.
  public var cost: UInt64?
  /// The value of every evaluated sub-expression, when the program tracks state.
  public var state: EvaluationState?

  /// Creates an evaluation result.
  public init(value: Value, cost: UInt64? = nil, state: EvaluationState? = nil) {
    self.value = value
    self.cost = cost
    self.state = state
  }
}

/// The values sub-expressions evaluated to, keyed by expression id (cel-go `EvalState`).
///
/// Expression ids identify nodes of the ``CheckedExpression`` the program was created from; use
/// ``CheckedExpression/location(ofExpressionID:)`` to map them back to the source, for example to
/// explain why a rule matched.
public struct EvaluationState: Sendable {
  /// The recorded values by expression id.
  public let values: [Int64: Value]

  /// Creates a state from recorded values.
  public init(values: [Int64: Value]) {
    self.values = values
  }

  init(_ state: any EvalState) {
    var values: [Int64: Value] = [:]
    for id in state.ids {
      values[id] = state.value(id)
    }
    self.init(values: values)
  }

  /// The ids with a recorded value, in ascending order.
  public var expressionIDs: [Int64] { values.keys.sorted() }

  /// The value recorded for an expression id, or `nil` when it was not evaluated.
  public func value(ofExpressionID id: Int64) -> Value? {
    values[id]
  }
}

extension Program {
  /// The resolved program options.
  package struct Settings: Sendable {
    package var evalOptions: EvalOptions = []
    package var costLimit: UInt64?
    package var interruptCheckFrequency: UInt = 0
    package var timeLimit: Duration?
    package var errorsAsValues = false
    package var decorators: [ProgramDecorator] = []
    package var globals: [String: Value] = [:]

    package init() {}

    /// The options for the planner; a time limit without a check frequency checks every 100
    /// comprehension iterations.
    package var plannerOptions: ProgramOptions {
      var frequency = interruptCheckFrequency
      if frequency == 0 && timeLimit != nil {
        frequency = 100
      }
      return ProgramOptions(
        evalOptions: evalOptions, costLimit: costLimit, interruptCheckFrequency: frequency)
    }
  }

  /// A configuration step for a ``Program``.
  public struct Option: Sendable {
    let apply: @Sendable (inout Settings) -> Void

    package init(_ apply: @escaping @Sendable (inout Settings) -> Void) {
      self.apply = apply
    }

    /// Stops evaluation with an error once the runtime cost exceeds `limit` (cel-go
    /// `CostLimit`). Implies ``trackCost``.
    public static func costLimit(_ limit: UInt64) -> Option {
      Option { $0.costLimit = limit }
    }

    /// Reports the runtime cost in ``EvaluationResult/cost`` (cel-go `OptTrackCost`).
    public static var trackCost: Option {
      Option { $0.evalOptions.insert(.trackCost) }
    }

    /// Records the value of every sub-expression in ``EvaluationResult/state`` (cel-go
    /// `OptTrackState`).
    public static var trackState: Option {
      Option { $0.evalOptions.insert(.trackState) }
    }

    /// Evaluates every branch of `&&`, `||` and `?:` instead of short-circuiting, and records
    /// state (cel-go `OptExhaustiveEval`).
    public static var exhaustiveEvaluation: Option {
      Option { $0.evalOptions.insert(.exhaustiveEval) }
    }

    /// Precomputes constant sub-expressions and regular expressions when the program is created
    /// (cel-go `OptOptimize`).
    public static var optimize: Option {
      Option { $0.evalOptions.insert(.optimize) }
    }

    /// Checks for interruption every `iterations` comprehension iterations (cel-go
    /// `InterruptCheckFrequency`): evaluation stops when the current task is cancelled or the
    /// ``timeLimit(_:)`` has passed.
    public static func interruptCheckFrequency(_ iterations: UInt) -> Option {
      Option { $0.interruptCheckFrequency = iterations }
    }

    /// Stops evaluation with an `operation interrupted` error once it has run for `duration`.
    ///
    /// The clock is checked at the interrupt check frequency, every 100 comprehension iterations
    /// unless ``interruptCheckFrequency(_:)`` says otherwise; expressions without
    /// comprehensions are bounded by their size.
    public static func timeLimit(_ duration: Duration) -> Option {
      Option { $0.timeLimit = duration }
    }

    /// Evaluates with the attributes matching ``Variables/unknowns`` treated as unknown
    /// (cel-go `OptPartialEval`): the result is `.unknown` when it depends on them.
    public static var partialEvaluation: Option {
      Option { $0.evalOptions.insert(.partialEval) }
    }

    /// Returns evaluation errors as `.error` values in ``EvaluationResult/value`` instead of
    /// throwing them, so cost and state stay available.
    public static var errorsAsValues: Option {
      Option { $0.errorsAsValues = true }
    }

    /// Default values for variables, used when the variables passed to `evaluate` do not bind
    /// them (cel-go `Globals`). Later globals options override earlier ones by name.
    public static func globals(_ values: [String: Value]) -> Option {
      Option { $0.globals.merge(values) { _, new in new } }
    }
  }
}

/// The values of the variables an expression is evaluated with (cel-go `Activation`).
///
/// Values can be given directly, computed on first use, or resolved by a closure for names not
/// bound otherwise:
///
/// ```swift
/// var variables: Variables = ["user": "ana"]
/// variables.bind("signals") { expensiveSignals() }   // computed only if the expression reads it
/// ```
public struct Variables: Sendable, ExpressibleByDictionaryLiteral {
  private var values: [String: Value]
  private var lazyValues: [String: @Sendable () -> Value] = [:]
  private var resolver: (@Sendable (String) -> Value?)?

  /// Patterns of attributes whose values are not known yet; they take effect in programs created
  /// with ``Program/Option/partialEvaluation``.
  public var unknowns: [UnknownPattern] = []

  /// Creates variables from values by name.
  public init(_ values: [String: Value] = [:]) {
    self.values = values
  }

  /// Creates variables resolved by a closure, called with the name of each variable the
  /// expression reads (including candidate qualified names such as `a.b` for `a.b.c`); it returns
  /// `nil` for names it does not bind.
  public init(resolver: @escaping @Sendable (String) -> Value?) {
    self.values = [:]
    self.resolver = resolver
  }

  /// Creates variables from a dictionary literal.
  public init(dictionaryLiteral elements: (String, Value)...) {
    self.values = Dictionary(elements, uniquingKeysWith: { _, last in last })
  }

  /// The value bound to a name, if it is bound to a value rather than a closure.
  public subscript(name: String) -> Value? {
    get { values[name] }
    set { values[name] = newValue }
  }

  /// Binds a name to a value.
  public mutating func bind(_ name: String, to value: Value) {
    values[name] = value
    lazyValues[name] = nil
  }

  /// Binds a name to a value computed on first use; each evaluation computes it at most once.
  public mutating func bind(_ name: String, lazily compute: @escaping @Sendable () -> Value) {
    lazyValues[name] = compute
    values[name] = nil
  }

  package func makeActivation() -> any Activation {
    let activation: any Activation =
      lazyValues.isEmpty && resolver == nil
      ? MapActivation(values)
      : ResolvingActivation(values: values, lazyValues: lazyValues, resolver: resolver)
    if unknowns.isEmpty {
      return activation
    }
    return PartialActivationWrapper(activation, unknowns: unknowns.map(\.pattern))
  }
}

/// An activation over ``Variables`` with memoised lazy values and a fallback resolver.
final class ResolvingActivation: Activation {
  private let values: [String: Value]
  private let lazyValues: [String: @Sendable () -> Value]
  private let resolver: (@Sendable (String) -> Value?)?
  private var resolved: [String: Value] = [:]

  init(
    values: [String: Value], lazyValues: [String: @Sendable () -> Value],
    resolver: (@Sendable (String) -> Value?)?
  ) {
    self.values = values
    self.lazyValues = lazyValues
    self.resolver = resolver
  }

  func resolveName(_ name: String) -> Value? {
    if let value = values[name] ?? resolved[name] {
      return value
    }
    if let compute = lazyValues[name] {
      let value = compute()
      resolved[name] = value
      return value
    }
    return resolver?(name)
  }
}
