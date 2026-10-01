import CELPolicy
import CELTest
import Foundation
import Testing

/// Loading of `tests.yaml` suites (cel-go `test.Suite`), checked against what go-yaml decodes for
/// the same files.
struct TestSuiteTests {
  static let celGo = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("third_party/cel-go")

  static func read(_ path: String) throws -> String {
    try String(contentsOf: celGo.appendingPathComponent(path), encoding: .utf8)
  }

  static let suiteFiles: [String] = {
    let fm = FileManager.default
    let policyDir = celGo.appendingPathComponent("policy/testdata")
    let names = (try? fm.contentsOfDirectory(atPath: policyDir.path)) ?? []
    let policySuites = names.sorted().map { "policy/testdata/\($0)/tests.yaml" }.filter {
      fm.fileExists(atPath: celGo.appendingPathComponent($0).path)
    }
    return policySuites + [
      "tools/celtest/testdata/custom_policy_tests.yaml",
      "tools/celtest/testdata/raw_expr_tests.yaml",
    ]
  }()

  @Test(arguments: suiteFiles)
  func suiteLoads(path: String) throws {
    let suite = try TestSuite(yaml: try Self.read(path))
    #expect(suite.sections.isEmpty == false)
    for section in suite.sections {
      #expect(section.tests.isEmpty == false)
      for test in section.tests {
        #expect(test.output != nil, "\(section.name)/\(test.name)")
      }
    }
  }

  @Test func suiteFileCount() {
    #expect(Self.suiteFiles.count == 13)
  }

  @Test func k8sValues() throws {
    let suite = try TestSuite(yaml: try Self.read("policy/testdata/k8s/tests.yaml"))
    #expect(suite.description == "K8s admission control tests")
    let test = try #require(suite.sections.first?.tests.first)
    #expect(test.name == "restricted_container")
    #expect(test.input["resource.namespace"] == TestInputValue(value: .string("dev.cel")))
    #expect(
      test.input["resource.labels"]
        == TestInputValue(value: .map([.init(key: .string("environment"), value: .string("staging"))])))
    #expect(
      test.input["resource.containers"]
        == TestInputValue(
          value: .list([
            .string("staging.dev.cel.container1"), .string("staging.dev.cel.container2"),
            .string("preprod.dev.cel.container3"),
          ])))
    #expect(test.output == TestOutput(value: .string("only staging containers are allowed in namespace dev.cel")))
  }

  /// `expr: 2` is an integer scalar decoded into a string field, which go-yaml accepts.
  @Test func integerExpressionDecodesAsString() throws {
    let suite = try TestSuite(yaml: try Self.read("policy/testdata/nested_rules_variable_shadowing/tests.yaml"))
    let tests = try #require(suite.sections.first?.tests)
    #expect(tests[1].input["x"] == TestInputValue(expression: "2"))
    #expect(tests[1].output == TestOutput(value: .int(3)))
    #expect(tests[2].input["x"] == TestInputValue(value: .int(3)))
  }

  @Test func inputsAndOutputs() throws {
    let suite = try TestSuite(
      yaml: """
        section:
          - name: s
            tests:
              - name: t
                input:
                  x:
                    value: 1
                  y:
                    expr: 2
                  z:
                    value: {a: [1, 2.5, true, null, '3']}
                output:
                  error_set: ['a', 'b']
              - name: u
                context_expr: 'msg'
                output:
                  unknown_set: [1, 2]
        """)
    let tests = try #require(suite.sections.first?.tests)
    #expect(tests[0].input["x"] == TestInputValue(value: .int(1)))
    #expect(tests[0].input["y"] == TestInputValue(expression: "2"))
    #expect(
      tests[0].input["z"]
        == TestInputValue(
          value: .map([.init(key: .string("a"), value: .list([.int(1), .double(2.5), .bool(true), .null, .string("3")]))])
        ))
    #expect(tests[0].output == TestOutput(errorSet: ["a", "b"]))
    #expect(tests[1].contextExpression == "msg")
    #expect(tests[1].input.isEmpty)
    #expect(tests[1].output == TestOutput(unknownSet: [1, 2]))
  }

  /// Error messages compared with go-yaml's output for the same input.
  @Test(arguments: [
    (
      "section:\n  - name: s\n    tests:\n      - name: t\n        output:\n          unknown_set: [a]\n          value: 18446744073709551615\n",
      "yaml: unmarshal errors:\n  line 6: cannot unmarshal !!str `a` into int64"
    ),
    ("section: foo\n", "yaml: unmarshal errors:\n  line 1: cannot unmarshal !!str `foo` into []*test.Section"),
    (
      "section:\n  - name: s\n    tests:\n      - name: t\n        input:\n          x:\n            value: 1\n          x:\n            value: 2\n",
      "yaml: unmarshal errors:\n  line 8: mapping key \"x\" already defined at line 6"
    ),
  ])
  func decodeErrors(yaml: String, wantError: String) {
    #expect(throws: YAMLError(message: wantError)) {
      try TestSuite(yaml: yaml)
    }
  }

  /// The celtest custom policy declares variable types with an embedder-specific tag
  /// (customTagHandler in tools/celtest/test_runner_test.go).
  @Test func customPolicyTag() throws {
    struct VariableTypesVisitor: PolicyTagVisitor {
      func visitPolicyTag(
        _ tagName: String,
        id: Int64,
        node: YAMLNode,
        policy: inout Policy,
        context: inout PolicyParserContext
      ) {
        guard tagName == "variable_types" else {
          context.reportError(atID: id, "unsupported policy tag: \(tagName)")
          return
        }
        do {
          guard case .list(let items)? = try node.decodeValue() else { return }
          for case .map(let entries) in items {
            var name = ""
            var type = ""
            for entry in entries {
              if case .string(let key) = entry.key, case .string(let value) = entry.value {
                if key == "variable_name" { name = value }
                if key == "variable_type" { type = value }
              }
            }
            policy.setMetadata(type, forKey: name)
          }
        } catch {
          context.reportError(atID: id, "invalid yaml variable_types node: \(error)")
        }
      }
    }
    let path = "tools/celtest/testdata/custom_policy.celpolicy"
    let policy = try PolicyParser(tagVisitor: VariableTypesVisitor()).parse(
      PolicySource(try Self.read(path), description: path))
    #expect(policy.name.value == "custom_policy")
    #expect(policy.metadata(forKey: "variable1") as? String == "int")
    #expect(policy.metadata(forKey: "variable2") as? String == "string")
    #expect(policy.rule?.matches.count == 2)
  }
}
