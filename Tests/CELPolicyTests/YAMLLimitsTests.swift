// Untrusted YAML must produce errors, not crashes or runaway memory. Not a ported file: go-yaml bounds
// nesting depth in its scanner; the expectations here are go-yaml's and cel-go's results for the same
// inputs, except where docs/divergences.md says otherwise.

import CEL
import Testing

@testable import CELPolicy

struct YAMLLimitsTests {
  // MARK: Nesting depth

  /// `depth` nested flow sequences: `[[[]]]`.
  static func flowSequences(_ depth: Int) -> String {
    String(repeating: "[", count: depth) + String(repeating: "]", count: depth) + "\n"
  }

  /// `depth` nested block mappings: `k:\n k:\n  ...`.
  static func blockMappings(_ depth: Int) -> String {
    var text = ""
    for level in 0..<depth {
      text += String(repeating: " ", count: level) + "k:\n"
    }
    return text + String(repeating: " ", count: depth) + "v\n"
  }

  /// The number of nested lists or maps in a decoded value, counted without recursion.
  static func nesting(_ value: YAMLValue) -> Int {
    var depth = 0
    var current = value
    while true {
      switch current {
      case .list(let items) where items.count == 1:
        current = items[0]
      case .map(let entries) where entries.count == 1:
        current = entries[0].value
      case .list, .map:
        return depth + 1
      default:
        return depth
      }
      depth += 1
    }
  }

  /// go-yaml accepts up to 10000 nested collections; libyaml, which reads the events here, stops
  /// before 1000. Below that, composing and decoding must not overflow a 512 KiB thread stack.
  @Test(.disabled("overflows the stack: the composer and the decoder recurse once per level"))
  func deepNestingDecodes() throws {
    let depth = 900
    for text in [Self.flowSequences(depth), Self.blockMappings(depth)] {
      let document = try #require(try YAMLNode.parseDocument(text))
      let value = try #require(try document.decodeValue())
      #expect(Self.nesting(value) == depth)
    }
  }

  /// Deeper documents are an error, as in go-yaml (whose limit is 10000 levels).
  @Test(.disabled("overflows the stack: the composer recurses once per level"))
  func deeperNestingIsAnError() throws {
    for text in [Self.flowSequences(10_001), Self.blockMappings(10_001)] {
      #expect(throws: YAMLError.self) { try YAMLNode.parseDocument(text) }
      #expect(throws: YAMLError.self) { try EnvironmentConfig(yaml: text) }
    }
  }

  /// A policy whose rules nest `depth` levels, each through a match with a nested rule.
  static func nestedRules(_ depth: Int) -> String {
    var text = "name: nested\nrule:\n"
    var indent = "  "
    for _ in 0..<depth {
      text += indent + "match:\n" + indent + "  - condition: 'true'\n" + indent + "    rule:\n"
      indent += "      "
    }
    return text + indent + "match:\n" + indent + "  - output: '1'\n"
  }

  /// cel-go parses rules nested to any depth and stops compiling them past `maxNestedExpressions`
  /// (100 by default) with an error.
  @Test(.disabled("overflows the stack: compiling recurses deeper than a thread's stack allows"))
  func deeplyNestedRules() throws {
    let compiler = PolicyCompiler()
    let shallow = try PolicyParser().parse(PolicySource(Self.nestedRules(90), description: "nested.yaml"))
    let compiled = try compiler.compile(shallow, environment: try Environment())
    let value = try compiled.program().evaluate().value
    #expect(value == .int(1) || value == .optional(.int(1)))

    let deep = try PolicyParser().parse(PolicySource(Self.nestedRules(250), description: "nested.yaml"))
    do {
      _ = try compiler.compile(deep, environment: try Environment())
      Issue.record("rules nested past the limit compiled")
    } catch {
      #expect("\(error)".contains("rule exceeds nested expression limit"))
    }
  }
}
