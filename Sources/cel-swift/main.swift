// Entry point of the cel-swift command line tool: dispatches to the subcommands in Command.all. Not a ported file.

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

let toolUsage = """
  Usage: cel-swift <command> [options] [arguments]

  Commands:
  \(Command.all.map { "  " + $0.name.padding(to: 10) + $0.summary }.joined(separator: "\n"))
    help      Print help for a command

  Run 'cel-swift help <command>' for the options of a command.
  """

extension String {
  func padding(to width: Int) -> String {
    let count = unicodeScalars.count
    return count >= width ? self + " " : self + String(repeating: " ", count: width - count)
  }
}

func runTool(_ arguments: [String]) -> Int32 {
  guard let name = arguments.first else {
    printError(toolUsage)
    return ExitStatus.usage
  }
  if name == "help" || name == "--help" || name == "-h" {
    if arguments.count > 1, let command = Command.all.first(where: { $0.name == arguments[1] }) {
      print(command.usage)
    } else {
      print(toolUsage)
    }
    return ExitStatus.success
  }
  guard let command = Command.all.first(where: { $0.name == name }) else {
    printError("cel-swift: unknown command '\(name)'\n\n\(toolUsage)")
    return ExitStatus.usage
  }
  let rest = Array(arguments.dropFirst())
  if rest.contains("--help") || rest.contains("-h") {
    print(command.usage)
    return ExitStatus.success
  }
  do {
    return try command.run(rest)
  } catch let error as UsageError {
    printError("cel-swift \(command.name): \(error)\n\n\(command.usage)")
    return ExitStatus.usage
  } catch {
    printError("\(error)")
    return ExitStatus.failure
  }
}

exit(runTool(Array(CommandLine.arguments.dropFirst())))
