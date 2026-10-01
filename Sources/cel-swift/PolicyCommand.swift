// The policy subcommand; `policy test` is implemented in CELCommandLine (PolicyTestCommand). Not a ported file.

import CELCommandLine

extension Command {
  static let policy = Command(
    name: "policy",
    summary: "Test CEL policies (policy test)",
    usage: PolicyTestCommand.usage,
    run: { args throws in
      guard args.first == "test" else {
        throw UsageError("expected 'policy test', got '\(args.joined(separator: " "))'")
      }
      let command: PolicyTestCommand
      do {
        command = try PolicyTestCommand(arguments: Array(args.dropFirst()))
      } catch {
        throw UsageError("\(error)")
      }
      return command.run { print($0) }
    })
}
