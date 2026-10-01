// Copyright 2022 Google LLC
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
// The repl subcommand, re-designed from cel-go repl/commands.go, repl/evaluator.go and
// repl/main/main.go.
//
// Supported: expressions, %eval [--parse-only], %let and %declare for variables, %delete,
// %parse, %compile (both print the debug representation instead of cel-go's textproto),
// %option --container / --extension, %status, %reset, %help, %exit. Not supported: function
// lets, %load_descriptors, %configure.

import CEL

extension Command {
  static let repl = Command(
    name: "repl",
    summary: "Read expressions and commands interactively",
    usage: """
      Usage: cel-swift repl [options]

      Reads one expression or command per line and prints 'VALUE : TYPE'. Commands:
        %let NAME (: TYPE)? = EXPR   bind a variable to the value of EXPR
        %declare NAME : TYPE         declare a variable without a value
        %delete NAME                 remove a variable
        %eval [--parse-only] EXPR    evaluate (the default for lines without a command)
        %parse EXPR                  print the parsed expression's debug representation
        %compile EXPR                print the checked expression's debug representation
        %option --container NAME     set the container
        %option --extension NAME     add an extension library ('all' adds every one)
        %status                      print the session's options and variables
        %reset                       clear the session
        %help                        print this text
        %exit                        quit (or end of input)

      \(Session.optionsHelp)
      """,
    run: { args throws in
      let arguments = try Arguments(args, options: Session.options, flags: [])
      if !arguments.positional.isEmpty {
        throw UsageError("unexpected argument \(arguments.positional[0])")
      }
      var repl = REPL(session: try Session(arguments: arguments))
      let interactive = standardInputIsTerminal
      if interactive {
        print("CEL REPL\n%exit or EOF to quit.\n")
      }
      while true {
        if interactive {
          print("cel-swift> ", terminator: "")
        }
        guard let line = readLine() else {
          break
        }
        let (output, exit) = repl.process(line)
        if let output {
          print(output)
        }
        if exit {
          break
        }
      }
      return ExitStatus.success
    })
}

/// The REPL state machine: processes one line and returns the text to print.
struct REPL {
  var session: Session

  /// Processes a line; returns the output and whether to exit.
  mutating func process(_ line: String) -> (output: String?, exit: Bool) {
    let trimmed = line.trimmingSpaces
    if trimmed.isEmpty {
      return (nil, false)
    }
    guard trimmed.hasPrefix("%") else {
      return (evaluate(trimmed, parseOnly: false), false)
    }
    let (command, rest) = trimmed.dropFirst().splitFirstWord()
    do {
      switch command {
      case "exit":
        return (nil, true)
      case "help":
        return (Command.repl.usage, false)
      case "eval":
        let (flag, expression) = rest.splitFirstWord()
        if flag == "--parse-only" {
          return (evaluate(expression, parseOnly: true), false)
        }
        return (evaluate(rest, parseOnly: false), false)
      case "parse":
        let parsed = try session.environment().parse(rest)
        return (parsed.debugString(withIDs: false), false)
      case "compile":
        let (_, checked) = try session.compile(rest)
        return (checked.adornedDebugString, false)
      case "let":
        try let_(rest)
        return (nil, false)
      case "declare":
        let (name, type) = try declaration(rest)
        guard let type else {
          throw CommandFailure("%declare needs a type: %declare NAME : TYPE")
        }
        session.declare(name, type: type)
        return (nil, false)
      case "delete":
        if !session.remove(rest) {
          throw CommandFailure("no variable named '\(rest)'")
        }
        return (nil, false)
      case "option":
        try option(rest)
        return (nil, false)
      case "status":
        return (status, false)
      case "reset":
        session = Session()
        return (nil, false)
      default:
        throw CommandFailure("unsupported command: \(command)")
      }
    } catch {
      return ("\(error)", false)
    }
  }

  private func evaluate(_ text: String, parseOnly: Bool) -> String {
    do {
      let env = try session.environment()
      if parseOnly {
        let value = try env.program(env.parse(text)).evaluate(session.values).value
        return "\(value)"
      }
      let checked = try env.compile(text)
      let value = try env.program(checked).evaluate(session.values).value
      return "\(value) : \(checked.outputType)"
    } catch {
      return "Expr failed:\n\(error)"
    }
  }

  /// `NAME (: TYPE)? = EXPR`.
  private mutating func let_(_ text: String) throws {
    guard let equals = text.firstIndex(of: "=") else {
      throw CommandFailure("%let needs a value: %let NAME (: TYPE)? = EXPR")
    }
    let (name, type) = try declaration(String(text[..<equals]))
    try session.bind(name, to: String(text[text.index(after: equals)...]), type: type)
  }

  /// `NAME (: TYPE)?`.
  private func declaration(_ text: String) throws -> (String, CELType?) {
    guard let colon = text.firstIndex(of: ":") else {
      return (try identifier(text), nil)
    }
    return (try identifier(String(text[..<colon])), try TypeParser.parse(String(text[text.index(after: colon)...])))
  }

  private func identifier(_ text: String) throws -> String {
    let name = text.trimmingSpaces
    guard !name.isEmpty, name.unicodeScalars.allSatisfy({ $0.properties.isAlphabetic || $0 == "_" || $0 == "." || ("0"..."9").contains($0) })
    else {
      throw CommandFailure("invalid identifier '\(name)'")
    }
    return name
  }

  private mutating func option(_ text: String) throws {
    var words = text.split(separator: " ").map { $0.trimmingCharacters(quotes: true) }
    while !words.isEmpty {
      let flag = words.removeFirst()
      guard !words.isEmpty else {
        throw CommandFailure("option \(flag) needs a value")
      }
      let value = words.removeFirst()
      switch flag {
      case "--container":
        session.container = value
      case "--extension":
        for name in value == "all" ? LibraryCatalog.names : [value] {
          try session.addLibrary(name)
        }
      default:
        throw CommandFailure("unknown option: \(flag). Available options are: --container, --extension")
      }
    }
  }

  private var status: String {
    var lines: [String] = []
    if !session.container.isEmpty {
      lines.append("%option --container '\(session.container)'")
    }
    for library in session.libraries {
      lines.append("%option --extension '\(library)'")
    }
    for binding in session.bindings {
      if let source = binding.source {
        lines.append("%let \(binding.name) : \(binding.type) = \(source.trimmingSpaces)")
      } else {
        lines.append("%declare \(binding.name) : \(binding.type)")
      }
    }
    return lines.joined(separator: "\n")
  }
}

extension StringProtocol {
  /// The text without leading and trailing spaces and tabs.
  var trimmingSpaces: String {
    let scalars = String(self).unicodeScalars
    guard let first = scalars.firstIndex(where: { !$0.properties.isWhitespace }),
      let last = scalars.lastIndex(where: { !$0.properties.isWhitespace })
    else {
      return ""
    }
    return String(String.UnicodeScalarView(scalars[first...last]))
  }

  /// The first space-separated word and the trimmed rest.
  func splitFirstWord() -> (String, String) {
    let text = trimmingSpaces
    guard let space = text.unicodeScalars.firstIndex(where: { $0.properties.isWhitespace }) else {
      return (text, "")
    }
    let scalars = text.unicodeScalars
    return (
      String(String.UnicodeScalarView(scalars[..<space])), String(String.UnicodeScalarView(scalars[space...])).trimmingSpaces
    )
  }

  /// The text without surrounding single or double quotes.
  func trimmingCharacters(quotes: Bool) -> String {
    let text = String(self)
    for quote in ["'", "\""] where text.count >= 2 && text.hasPrefix(quote) && text.hasSuffix(quote) {
      return String(text.dropFirst().dropLast())
    }
    return text
  }
}
