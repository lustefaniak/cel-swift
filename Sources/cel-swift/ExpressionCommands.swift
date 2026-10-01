// The eval, check and parse subcommands. Not a ported file.

import CEL

extension Command {
  static let eval = Command(
    name: "eval",
    summary: "Compile and evaluate an expression",
    usage: """
      Usage: cel-swift eval [options] [--] EXPR...
             echo EXPR | cel-swift eval [options]

      Type-checks EXPR and prints its value formatted as a CEL literal. Exits with status 1
      when the expression does not compile or evaluates to an error.

      Options:
        --parse-only            evaluate without type-checking
        --show-type             print the value followed by ' : TYPE'
        --cost-limit N          stop evaluation once its cost exceeds N
        --show-cost             print the evaluation cost on a second line

      \(Session.optionsHelp)
      """,
    run: { args throws in
      let arguments = try Arguments(
        args, options: Session.options.union(["cost-limit"]), flags: ["parse-only", "show-type", "show-cost"])
      let session = try Session(arguments: arguments)
      let text = try expressionText(arguments.positional)
      var options: [Program.Option] = []
      if let limit = arguments.last("cost-limit") {
        guard let value = UInt64(limit) else {
          throw UsageError("--cost-limit expects a number, got '\(limit)'")
        }
        options.append(.costLimit(value))
      }
      if arguments.has("show-cost") {
        options.append(.trackCost)
      }
      let env = try session.environment()
      let program: Program
      var type: CELType?
      if arguments.has("parse-only") {
        program = try env.program(env.parse(text), options: options)
      } else {
        let checked = try env.compile(text)
        type = checked.outputType
        program = try env.program(checked, options: options)
      }
      let result = try program.evaluate(session.values)
      if arguments.has("show-type") {
        print("\(result.value) : \(type.map { "\($0)" } ?? "dyn")")
      } else {
        print(result.value)
      }
      if arguments.has("show-cost"), let cost = result.cost {
        print("cost: \(cost)")
      }
      return ExitStatus.success
    })

  static let check = Command(
    name: "check",
    summary: "Type-check an expression and print its type",
    usage: """
      Usage: cel-swift check [options] [--] EXPR...

      Type-checks EXPR and prints its output type. Exits with status 1 on errors.

      Options:
        --debug                 print the checked expression with each node's type and reference
        --cost                  print the estimated cost range on a second line

      \(Session.optionsHelp)
      """,
    run: { args throws in
      let arguments = try Arguments(args, options: Session.options, flags: ["debug", "cost"])
      let session = try Session(arguments: arguments)
      let (env, checked) = try session.compile(try expressionText(arguments.positional))
      if arguments.has("debug") {
        print(checked.adornedDebugString)
      } else {
        print(checked.outputType)
      }
      if arguments.has("cost") {
        let cost = env.estimateCost(checked)
        print("cost: [\(cost.lowerBound), \(cost.upperBound)]")
      }
      return ExitStatus.success
    })

  static let parse = Command(
    name: "parse",
    summary: "Parse an expression and print it back",
    usage: """
      Usage: cel-swift parse [options] [--] EXPR...

      Parses EXPR without type-checking it and prints it back as CEL text. Exits with status 1 on
      syntax errors.

      Options:
        --debug                 print cel-go's debug representation of the syntax tree
        --ids                   with --debug, adorn each node with its id

      \(Session.optionsHelp)
      """,
    run: { args throws in
      let arguments = try Arguments(args, options: Session.options, flags: ["debug", "ids"])
      let session = try Session(arguments: arguments)
      let parsed = try session.environment().parse(try expressionText(arguments.positional))
      if arguments.has("debug") {
        print(parsed.debugString(withIDs: arguments.has("ids")))
      } else {
        print(parsed)
      }
      return ExitStatus.success
    })
}

extension ParsedExpression {
  /// cel-go's `debug.ToDebugString` of the syntax tree.
  func debugString(withIDs: Bool) -> String {
    withIDs ? ExprDebug.toDebugStringWithIDs(ast.expr) : ExprDebug.toDebugString(ast.expr)
  }
}

extension CheckedExpression {
  /// cel-go's `checker.Print`: the debug representation with types and references.
  var adornedDebugString: String {
    Checker.print(ast.expr, checked: ast)
  }
}
