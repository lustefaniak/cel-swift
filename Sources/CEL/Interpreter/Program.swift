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
// A minimal port of the program construction and evaluation in cel-go cel/program.go and the parts
// of cel/env.go it needs. The public `Environment` / `Program` API is designed separately and wraps
// these package types.

/// A planner decorator a library contributes to every program (cel-go `CustomDecoratorV2`).
package typealias ProgramDecorator = @Sendable (any Interpretable) throws -> any Interpretable

/// Program evaluation options (cel-go `EvalOption`).
package struct EvalOptions: OptionSet, Sendable, Hashable {
  package let rawValue: Int

  package init(rawValue: Int) {
    self.rawValue = rawValue
  }

  /// Record the value of every expression (cel-go `OptTrackState`).
  package static let trackState = EvalOptions(rawValue: 1 << 0)
  /// Evaluate every branch, no short-circuiting; implies state tracking (cel-go `OptExhaustiveEval`).
  package static let exhaustiveEval = EvalOptions(rawValue: 1 << 1)
  /// Precompute constant literals, conversions and set membership (cel-go `OptOptimize`).
  package static let optimize = EvalOptions(rawValue: 1 << 2)
  /// Enable unknown attribute patterns (cel-go `OptPartialEval`).
  package static let partialEval = EvalOptions(rawValue: 1 << 3)
  /// Track the runtime cost (cel-go `OptTrackCost`).
  package static let trackCost = EvalOptions(rawValue: 1 << 4)
}

/// Options for creating a program (cel-go `ProgramOption`s).
package struct ProgramOptions: Sendable {
  package var evalOptions: EvalOptions = []
  /// The runtime cost limit; implies cost tracking.
  package var costLimit: UInt64?
  package var costTracker = CostTrackerOptions()
  /// Check the interrupt every this many comprehension iterations; 0 disables interruption.
  package var interruptCheckFrequency: UInt = 0

  package init(
    evalOptions: EvalOptions = [], costLimit: UInt64? = nil, interruptCheckFrequency: UInt = 0
  ) {
    self.evalOptions = evalOptions
    self.costLimit = costLimit
    self.interruptCheckFrequency = interruptCheckFrequency
  }
}

/// The declarations, functions, types and container expressions are compiled against
/// (a small `cel.Env`).
package struct ProgramEnvironment: Sendable {
  package var container: Container
  package var functions: [FunctionDecl]
  package var variables: [VariableDecl]
  package var provider: any TypeProvider
  package var macros: [Macro]
  package var parserOptions: [ParserOption]
  /// A presence test or optional selection on a non-container value is an error
  /// (cel-go `EnableErrorOnBadPresenceTest`).
  package var errorOnBadPresenceTest: Bool
  /// Planner decorators contributed by libraries (cel-go `CustomDecorator` program options).
  package var decorators: [ProgramDecorator] = []

  /// The standard environment: standard library functions and type identifiers, standard macros,
  /// the root container and the standard types.
  package init(
    container: Container = .default,
    functions: [FunctionDecl] = StandardLibrary.functions,
    variables: [VariableDecl] = [],
    provider: any TypeProvider = TypeRegistry(),
    macros: [Macro] = Macro.allMacros,
    parserOptions: [ParserOption] = [],
    errorOnBadPresenceTest: Bool = false
  ) {
    self.container = container
    self.functions = functions
    self.variables = variables
    self.provider = provider
    self.macros = macros
    self.parserOptions = parserOptions
    self.errorOnBadPresenceTest = errorOnBadPresenceTest
  }

  /// Parses an expression; the errors are cel-go's caret-snippet display string.
  package func parse(_ text: String, description: String = "<input>") throws(PlanError) -> AST {
    let parser: Parser
    do {
      parser = try Parser(options: [.macros(macros)] + parserOptions)
    } catch {
      throw PlanError("\(error)")
    }
    let (ast, errors) = parser.parse(TextSource(text, description: description))
    if !errors.isEmpty {
      throw PlanError(errors.toDisplayString())
    }
    return ast
  }

  /// Adds variable declarations, or function declarations merged into an existing function of the
  /// same name (cel-go `Variable` / `Function` env options).
  package mutating func declare(_ variables: [VariableDecl] = [], functions: [FunctionDecl] = []) throws {
    self.variables += variables
    for function in functions {
      if let i = self.functions.firstIndex(where: { $0.name == function.name }) {
        self.functions[i] = try self.functions[i].merging(function)
      } else {
        self.functions.append(function)
      }
    }
  }

  /// The checker environment for these declarations.
  package func checkerEnv(options: [CheckerOption] = []) throws -> CheckerEnv {
    var env = CheckerEnv(container: container, provider: provider, options: options)
    try env.addIdents(StandardLibrary.types + variables)
    try env.addFunctions(functions)
    return env
  }

  /// Type-checks a parsed AST (cel-go `Env.Check`); the errors are cel-go's display string.
  package func check(_ ast: AST, source: any Source, options: [CheckerOption] = []) throws(PlanError) -> AST {
    let env: CheckerEnv
    do {
      env = try checkerEnv(options: options)
    } catch {
      throw PlanError("\(error)")
    }
    let (checked, errors) = Checker.check(ast, source: source, env: env)
    if !errors.isEmpty {
      throw PlanError(errors.toDisplayString())
    }
    return checked
  }

  /// Parses and type-checks an expression (cel-go `Env.Compile`).
  package func compile(_ text: String, description: String = "<input>") throws(PlanError) -> AST {
    let ast = try parse(text, description: description)
    return try check(ast, source: TextSource(text, description: description))
  }

  /// Plans a program for a checked or parse-only AST (cel-go `newProgram`).
  package func program(_ ast: AST, options: ProgramOptions = ProgramOptions()) throws -> Program {
    let dispatcher = try Dispatcher(functions: functions)
    var evalOptions = options.evalOptions
    if options.costLimit != nil {
      evalOptions.insert(.trackCost)
    }
    let attrFactory: any AttributeFactory =
      evalOptions.contains(.partialEval)
      ? PartialAttributeFactory(container: container, provider: provider, errorOnBadPresenceTest: errorOnBadPresenceTest)
      : DefaultAttributeFactory(container: container, provider: provider, errorOnBadPresenceTest: errorOnBadPresenceTest)
    var planner = Planner(
      dispatcher: dispatcher, provider: provider, attrFactory: attrFactory, container: container, ast: ast)
    for decorator in decorators {
      planner.decorators.append(decorator)
    }
    if options.interruptCheckFrequency > 0 {
      planner.decorators.append(decInterruptFolds())
    }
    if evalOptions.contains(.optimize) {
      planner.decorators.append(decOptimize())
      planner.decorators.append(decRegexOptimizer())
    }
    if !evalOptions.isDisjoint(with: [.exhaustiveEval, .trackState, .trackCost]) {
      var observers: [any StatefulObserver] = []
      if !evalOptions.isDisjoint(with: [.exhaustiveEval, .trackState]) {
        observers.append(EvalStateObserver())
      }
      if evalOptions.contains(.trackCost) {
        var costOptions = options.costTracker
        costOptions.limit = options.costLimit ?? costOptions.limit
        observers.append(CostObserver(costOptions))
      }
      if evalOptions.contains(.exhaustiveEval) {
        planner.decorators.append(decDisableShortcircuits())
      }
      planner.observers = observers
    }
    let depth = ast.expr.depth
    var planned: Result<any Interpretable, any Error> = .failure(PlanError("not planned"))
    withStack(depth: depth) {
      planned = Result { try planner.plan(ast.expr) }
    }
    return Program(
      interpretable: try planned.get(), depth: depth,
      interruptCheckFrequency: options.interruptCheckFrequency)
  }
}

/// The result of an evaluation (cel-go's `(ref.Val, *EvalDetails, error)`).
package struct EvalResult {
  /// The value, or an error value when evaluation failed or was cancelled.
  package var value: Value
  /// The recorded expression values, with state tracking.
  package var state: (any EvalState)?
  /// The runtime cost, with cost tracking.
  package var actualCost: UInt64?
}

/// A planned expression, ready to evaluate any number of times, from any thread (a small
/// `cel.Program`).
package struct Program: Sendable {
  package let interpretable: any Interpretable
  /// The expression depth, used to size the evaluation stack.
  package let depth: Int
  package let interruptCheckFrequency: UInt

  /// Evaluates with an activation (cel-go `Eval` / `ContextEval`). `interrupt` is consulted every
  /// `interruptCheckFrequency` comprehension iterations.
  package func eval(_ activation: any Activation, interrupt: (() -> Bool)? = nil) -> EvalResult {
    let frame = ExecutionFrame(activation)
    if let interrupt, interruptCheckFrequency > 0 {
      frame.setInterrupt(interrupt, frequency: interruptCheckFrequency)
    }
    var result = EvalResult(value: .null)
    withStack(depth: depth) {
      if let observable = interpretable as? ObservableInterpretable {
        result.value = observable.observeEval(frame) { state in
          switch state {
          case let s as any EvalState: result.state = s
          case let c as CostTracker: result.actualCost = c.actualCost
          default: break
          }
        }
      } else {
        result.value = interpretable.eval(frame)
      }
    }
    if let costs = frame.context?.costs {
      result.actualCost = costs.actualCost
    }
    switch frame.context?.cancellation {
    case .costLimitExceeded?:
      result.value = .error(EvalError(costLimitExceededMessage))
    case .interrupted?:
      result.value = .error(EvalError(interruptErrorMessage))
    case nil:
      break
    }
    return result
  }

  /// Evaluates with variable bindings.
  package func eval(_ bindings: [String: Value]) -> EvalResult {
    eval(MapActivation(bindings))
  }
}

/// Runs `body` on a thread with a stack large enough for an expression of the given depth when the
/// calling thread's stack may not be.
func withStack(depth: Int, _ body: () -> Void) {
  // Planning and evaluation recurse a few frames per expression level; LargeStack's units are sized
  // for the parser, whose frames are comparable.
  if let stackSize = LargeStack.requiredStackSize(units: depth * 2) {
    LargeStack.run(stackSize: stackSize, body)
  } else {
    body()
  }
}

extension Expr {
  /// The height of the expression tree (a leaf is 1), computed without recursion.
  package var depth: Int {
    var maxDepth = 0
    var stack: [(Expr, Int)] = [(self, 1)]
    while let (e, d) = stack.popLast() {
      maxDepth = Swift.max(maxDepth, d)
      switch e.kind {
      case .unspecified, .literal, .ident:
        break
      case .select(let s):
        stack.append((s.operand, d + 1))
      case .call(let c):
        if let t = c.target { stack.append((t, d + 1)) }
        for a in c.args { stack.append((a, d + 1)) }
      case .list(let l):
        for a in l.elements { stack.append((a, d + 1)) }
      case .map(let m):
        for entry in m.entries {
          stack.append((entry.key, d + 1))
          stack.append((entry.value, d + 1))
        }
      case .struct(let s):
        for f in s.fields { stack.append((f.value, d + 1)) }
      case .comprehension(let c):
        for x in [c.iterRange, c.accuInit, c.loopCondition, c.loopStep, c.result] {
          stack.append((x, d + 1))
        }
      }
    }
    return maxDepth
  }
}
