// The cel-swift command line tool: subcommands and a small argument parser. Not a ported file.
//
// Each subcommand is a `Command` value registered in `Command.all`; adding one (for example
// `policy`) means writing its file and appending it to that list. Arguments are parsed with
// `Arguments`, a minimal `--flag` / `--option value` / positional parser built on the standard
// library only.

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

/// A subcommand of the `cel-swift` tool.
struct Command: Sendable {
  /// The name typed after `cel-swift`, such as `eval`.
  var name: String
  /// One line shown in the command list.
  var summary: String
  /// The full help text, shown by `cel-swift help <name>` and `<name> --help`.
  var usage: String
  /// Runs the command with the arguments after its name and returns the exit status.
  var run: @Sendable ([String]) throws -> Int32

  /// Every subcommand, in the order `cel-swift help` lists them.
  static let all: [Command] = [.eval, .check, .parse, .repl, .policy]
}

/// Exit statuses.
enum ExitStatus {
  static let success: Int32 = 0
  /// The expression did not compile or evaluate.
  static let failure: Int32 = 1
  /// The command line was invalid.
  static let usage: Int32 = 2
}

/// A command line error, printed with the command's usage.
struct UsageError: Error, CustomStringConvertible {
  var description: String

  init(_ description: String) {
    self.description = description
  }
}

/// A failure already described to the user; the tool exits with ``ExitStatus/failure``.
struct CommandFailure: Error, CustomStringConvertible {
  var description: String

  init(_ description: String) {
    self.description = description
  }
}

/// Parsed command line arguments: options with values, flags and positional arguments.
///
/// Options are declared up front so `--name value` and `--name=value` can be told apart from
/// flags; `--` ends option parsing.
struct Arguments {
  private(set) var values: [String: [String]] = [:]
  private(set) var flags: Set<String> = []
  private(set) var positional: [String] = []

  /// Parses `arguments`.
  ///
  /// - Parameters:
  ///   - arguments: The arguments after the subcommand name.
  ///   - options: Names (without `--`) of options that take a value; they may repeat.
  ///   - flags: Names of options without a value.
  /// - Throws: ``UsageError`` for an unknown option or a missing value.
  init(_ arguments: [String], options: Set<String>, flags knownFlags: Set<String>) throws(UsageError) {
    var index = 0
    var onlyPositional = false
    while index < arguments.count {
      let argument = arguments[index]
      index += 1
      if onlyPositional || !argument.hasPrefix("-") || argument == "-" {
        positional.append(argument)
        continue
      }
      if argument == "--" {
        onlyPositional = true
        continue
      }
      var name = String(argument.drop { $0 == "-" })
      var inlineValue: String?
      if let equals = name.firstIndex(of: "=") {
        inlineValue = String(name[name.index(after: equals)...])
        name = String(name[..<equals])
      }
      if knownFlags.contains(name) {
        if inlineValue != nil {
          throw UsageError("option --\(name) does not take a value")
        }
        flags.insert(name)
      } else if options.contains(name) {
        if let inlineValue {
          values[name, default: []].append(inlineValue)
        } else if index < arguments.count {
          values[name, default: []].append(arguments[index])
          index += 1
        } else {
          throw UsageError("option --\(name) needs a value")
        }
      } else {
        throw UsageError("unknown option \(argument)")
      }
    }
  }

  /// Whether the flag was given.
  func has(_ flag: String) -> Bool {
    flags.contains(flag)
  }

  /// Every value given for the option, in order.
  func all(_ option: String) -> [String] {
    values[option] ?? []
  }

  /// The last value given for the option.
  func last(_ option: String) -> String? {
    values[option]?.last
  }
}

/// Writes to standard error.
func printError(_ message: String) {
  var stream = StandardError()
  print(message, to: &stream)
}

struct StandardError: TextOutputStream {
  mutating func write(_ string: String) {
    var bytes = Array(string.utf8)
    bytes.withUnsafeMutableBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let written = writeBytes(2, buffer.baseAddress.map { $0 + offset }, buffer.count - offset)
        if written <= 0 {
          return
        }
        offset += written
      }
    }
  }
}

/// `write(2)`, named apart from `TextOutputStream.write`.
private func writeBytes(_ fd: Int32, _ pointer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
  write(fd, pointer, count)
}

/// Whether standard input is an interactive terminal.
var standardInputIsTerminal: Bool {
  isatty(0) != 0
}

/// Reads all of standard input.
func readStandardInput() -> String {
  var lines: [String] = []
  while let line = readLine(strippingNewline: false) {
    lines.append(line)
  }
  return lines.joined()
}

/// The expression given as positional arguments, or read from standard input when there are none
/// or the only one is `-`.
func expressionText(_ positional: [String]) throws(UsageError) -> String {
  if positional.isEmpty || positional == ["-"] {
    if standardInputIsTerminal {
      throw UsageError("missing expression")
    }
    return readStandardInput()
  }
  return positional.joined(separator: " ")
}
