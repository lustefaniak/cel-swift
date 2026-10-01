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
  @Test
  func deepNestingDecodes() throws {
    let depth = 900
    for text in [Self.flowSequences(depth), Self.blockMappings(depth)] {
      let document = try #require(try YAMLNode.parseDocument(text))
      let value = try #require(try document.decodeValue())
      #expect(Self.nesting(value) == depth)
    }
  }

  /// Deeper documents are an error, as in go-yaml (whose limit is 10000 levels).
  @Test
  func deeperNestingIsAnError() throws {
    for text in [Self.flowSequences(10_001), Self.blockMappings(10_001)] {
      #expect(throws: YAMLError.self) { try YAMLNode.parseDocument(text) }
      #expect(throws: YAMLError.self) { try EnvironmentConfig(yaml: text) }
    }
  }

  /// Anchors whose content nests 100 levels, the others aliasing the previous one 99 levels down:
  /// decoding the last nests `1 + 99 * links` levels.
  static func aliasChain(links: Int, indent: String = "") -> String {
    var text = indent + "a0: &a0 " + flowSequences(100)
    for link in 1..<links {
      text += indent + "a\(link): &a\(link) " + String(repeating: "[", count: 99) + "*a\(link - 1)"
        + String(repeating: "]", count: 99) + "\n"
    }
    return text
  }

  /// Aliases splice anchored trees into each other, so a decoded value can nest deeper than its
  /// document. go-yaml decodes any depth; here decoding stops at `YAMLDecoder.maxDepth` (1000),
  /// so that decoded values can be compared and released on any thread.
  @Test func aliasNestingIsBounded() throws {
    let document = try #require(try YAMLNode.parseDocument(Self.aliasChain(links: 9)))
    guard case .map(let entries)? = try document.decodeValue() else {
      Issue.record("not a map")
      return
    }
    #expect(Self.nesting(entries[8].value) == 892)
    // Equality and release recurse once per level on the calling thread.
    #expect(entries[8].value == entries[8].value)

    let deeper = try #require(try YAMLNode.parseDocument(Self.aliasChain(links: 11)))
    #expect(throws: YAMLError(message: "yaml: exceeded max depth of 1000")) { try deeper.decodeValue() }
    #expect(throws: YAMLError(message: "yaml: exceeded max depth of 1000")) {
      try EnvironmentConfig(
        yaml: "anchors:\n" + Self.aliasChain(links: 11, indent: "  ")
          + "validators:\n- name: v\n  config:\n    deep: *a10\n")
    }
  }

  // MARK: Type nesting in environment configs

  /// A list type nested `depth` levels as a type specifier: `list<list<...<int>...>>`.
  static func nestedListSpecifier(_ depth: Int) -> String {
    String(repeating: "list<", count: depth) + "int" + String(repeating: ">", count: depth)
  }

  /// A config declaring `x` as a list type nested `depth` levels through `params`, in flow style:
  /// each level is a mapping and a sequence, so the YAML nests `2 * depth` levels.
  static func nestedParamsConfig(_ depth: Int) -> String {
    "variables:\n- name: x\n  type: "
      + String(repeating: "{type_name: list, params: [", count: depth) + "{type_name: int}"
      + String(repeating: "]}", count: depth) + "\n"
  }

  /// A list type descriptor nested `depth` levels, built without parsing.
  static func nestedList(_ depth: Int) -> EnvironmentConfig.TypeDescriptor {
    var type = EnvironmentConfig.TypeDescriptor("int")
    for _ in 0..<depth {
      type = EnvironmentConfig.TypeDescriptor("list", parameters: [type])
    }
    return type
  }

  /// Types nesting 100 levels, the limit, are declared and checked on the calling thread.
  @Test func typesAtTheNestingLimitCompile() throws {
    let parsed = try EnvironmentConfig.TypeDescriptor(parsing: Self.nestedListSpecifier(99))
    #expect(parsed == Self.nestedList(99))
    for yaml in [
      "variables:\n- name: x\n  type: '\(Self.nestedListSpecifier(99))'\n", Self.nestedParamsConfig(99),
    ] {
      let config = try EnvironmentConfig(yaml: yaml)
      #expect(config.variables.first?.type == Self.nestedList(99))
      var withFunction = config
      withFunction.functions = [
        .init(name: "f", overloads: [.init(id: "f_list", arguments: [Self.nestedList(99)], resultType: .init("int"))])
      ]
      let environment = try Environment(.environmentConfig(withFunction))
      for expression in ["x == x", "[x, x][0] == x", "f(x) == 1", "x.exists(y, size(y) == 0)"] {
        #expect(try environment.compile(expression).outputType == .bool)
      }
      // The error message formats the type.
      #expect(throws: CompileError.self) { try environment.compile("x + 1") }
    }
  }

  /// cel-go parses a type specifier of any depth (its parser recurses on a growable stack); here
  /// the parser stops past 100 levels.
  @Test func deepTypeSpecifierIsAnError() throws {
    let specifier = Self.nestedListSpecifier(1_000)
    let suffix = "exceeded max nesting depth of 100 at position 500"
    do {
      _ = try EnvironmentConfig(yaml: "variables:\n- name: x\n  type: '\(specifier)'\n")
      Issue.record("a type nested 1000 levels decoded")
    } catch {
      #expect(error.message.hasPrefix("failed to parse type \"list<list<"))
      #expect(error.message.hasSuffix(suffix))
    }
    do {
      _ = try EnvironmentConfig.TypeDescriptor(parsing: Self.nestedListSpecifier(100))
      Issue.record("a type nested 101 levels parsed")
    } catch {
      #expect(error.messages.count == 1)
      #expect(error.messages.first?.hasSuffix(suffix) == true)
    }
  }

  /// Types nested through `params` within the YAML depth limit but past 100 levels are a decoding
  /// error; cel-go builds an environment from them at any depth.
  @Test func deepTypeParamsAreAnError() throws {
    #expect(throws: YAMLError(message: "invalid type: exceeded max nesting depth of 100")) {
      try EnvironmentConfig(yaml: Self.nestedParamsConfig(300))
    }
    #expect(throws: YAMLError(message: "invalid type: exceeded max nesting depth of 100")) {
      try EnvironmentConfig(yaml: Self.nestedParamsConfig(100))
    }
  }

  /// Descriptors built in code are checked when the environment is created.
  @Test func deepTypeDescriptorsAreAnError() throws {
    let deep = Self.nestedList(1_000)
    #expect(throws: EnvironmentConfigError(messages: ["invalid type: exceeded max nesting depth of 100"])) {
      try deep.validate()
    }
    var withVariable = EnvironmentConfig()
    withVariable.variables = [.init(name: "x", type: deep)]
    var withFunction = EnvironmentConfig()
    withFunction.functions = [.init(name: "f", overloads: [.init(id: "f_deep", arguments: [deep], resultType: deep)])]
    for configured in [withVariable, withFunction] {
      do {
        _ = try Environment(.environmentConfig(configured))
        Issue.record("a type nested 1001 levels was declared")
      } catch {
        #expect("\(error)".contains("invalid type: exceeded max nesting depth of 100"))
      }
    }
  }

  // MARK: Alias expansion

  /// The billion laughs document: `levels` anchors, each a list of `fanout` aliases of the
  /// previous one, so the last one expands to `fanout^levels` scalars.
  static func laughs(levels: Int, fanout: Int, indent: String = "") -> String {
    var text = indent + "a0: &a0 [" + Array(repeating: "lol", count: fanout).joined(separator: ", ") + "]\n"
    for level in 1..<levels {
      text += indent + "a\(level): &a\(level) ["
        + Array(repeating: "*a\(level - 1)", count: fanout).joined(separator: ", ") + "]\n"
    }
    return text
  }

  /// The message of the error decoding `node` throws, or `nil` when it decodes.
  static func decodeError(_ node: YAMLNode) -> String? {
    do {
      _ = try node.decodeValue()
      return nil
    } catch {
      return error.message
    }
  }

  /// go-yaml stops a decode when alias expansion does most of its work (`allowedAliasRatio`:
  /// more than 99% of the nodes decoded for documents under 400000 decodes, scaling down to 10%
  /// at 4000000). Expected results from go-yaml v3.0.4 on the same documents.
  @Test func aliasExpansionIsBounded() throws {
    let accepted = try #require(try YAMLNode.parseDocument(Self.laughs(levels: 3, fanout: 10)))
    #expect(try accepted.decodeValue() != nil)
    let excessive = try #require(try YAMLNode.parseDocument(Self.laughs(levels: 4, fanout: 10)))
    #expect(Self.decodeError(excessive) == "yaml: document contains excessive aliasing")
    // A billion scalars (387 million here) fail as soon as the ratio is exceeded.
    let laughs = Self.laughs(levels: 9, fanout: 9)
    let billion = try #require(try YAMLNode.parseDocument(laughs))
    #expect(Self.decodeError(billion) == "yaml: document contains excessive aliasing")
    #expect(throws: YAMLError(message: "yaml: document contains excessive aliasing")) {
      try EnvironmentConfig(
        yaml: "anchors:\n" + Self.laughs(levels: 9, fanout: 9, indent: "  ")
          + "validators:\n- name: v\n  config:\n    laughs: *a8\n")
    }
  }

  // MARK: Duplicate keys

  /// go-yaml compares every pair of keys of a mapping (`checkUniqueKeys` is quadratic). Decoding a
  /// mapping 8 times as large should take about 8 times as long, not 64.
  @Test func duplicateKeyCheckIsLinear() throws {
    let clock = ContinuousClock()
    func time(_ n: Int) throws -> Duration {
      let text = (0..<n).map { "key\($0): \($0)\n" }.joined()
      let document = try #require(try YAMLNode.parseDocument(text))
      let start = clock.now
      _ = try document.decodeValue()
      return clock.now - start
    }
    _ = try time(100)  // warm up
    let small = try time(1_000)
    let large = try time(8_000)
    #expect(large < small * 20 + .milliseconds(50), "1000 keys: \(small), 8000 keys: \(large)")
  }

  /// A key repeated n times is n(n-1)/2 pairs, each an error in go-yaml's message; the first
  /// 1000 of them are reported here, in go-yaml's order.
  @Test func duplicateKeyErrorsAreBounded() throws {
    let text = String(repeating: "a: 1\n", count: 1_000)
    let document = try #require(try YAMLNode.parseDocument(text))
    let message = Self.decodeError(document) ?? ""
    let lines = message.split(separator: "\n")
    #expect(lines.count == 1_001)
    #expect(lines.first == "yaml: unmarshal errors:")
    #expect(lines.dropFirst().first == "  line 2: mapping key \"a\" already defined at line 1")
    #expect(lines.last == "  line 3: mapping key \"a\" already defined at line 2")
  }

  /// go-yaml's order: for each key, every later equal key (go-yaml v3.0.4 output).
  @Test func duplicateKeyErrorsInGoYAMLOrder() throws {
    let text = "a: 1\nb: 2\na: 3\nb: 4\na: 5\n'a': 6\n[x]: 7\n[y]: 8\n"
    let document = try #require(try YAMLNode.parseDocument(text))
    #expect(
      Self.decodeError(document) == """
        yaml: unmarshal errors:
          line 3: mapping key "a" already defined at line 1
          line 5: mapping key "a" already defined at line 1
          line 6: mapping key "a" already defined at line 1
          line 4: mapping key "b" already defined at line 2
          line 5: mapping key "a" already defined at line 3
          line 6: mapping key "a" already defined at line 3
          line 6: mapping key "a" already defined at line 5
          line 8: mapping key "" already defined at line 7
        """)
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
  @Test
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
