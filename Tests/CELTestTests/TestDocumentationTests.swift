// The examples of Sources/CELTest/CELTest.docc, so the documentation keeps compiling and stays
// true. Keep them in sync when either side changes.

import CEL
import CELPolicy
import CELTest
import Testing

@Suite("CELTest documentation examples")
struct TestDocumentationTests {
  @Test func landingPage() throws {
    let config = try EnvironmentConfig(
      yaml: """
        name: doubling
        variables:
          - name: i
            type:
              type_name: int
        """)
    let compiler = try TestCompiler(options: [.environmentConfig(config)])
    let runner = try TestRunner(compiler: compiler, expressions: [compiler.compile(expression: "i * 2 == 42")])
    let suite = try TestSuite(
      yaml: """
        description: doubling
        section:
          - name: valid
            tests:
              - name: twenty-one
                input:
                  i:
                    value: 21
                output:
                  value: true
              - name: ten
                input:
                  i:
                    value: 10
                output:
                  value: true
        """)
    let results = runner.run(suite)
    #expect(results.map(\.name) == ["valid/twenty-one", "valid/ten"])
    #expect(results.map(\.passed) == [true, false])
    #expect(results[1].outcome == .failed(wanted: "simple value true", failure: "policy eval got false"))
  }

  /// The policy and environment config of the CELPolicy overview (Sources/CELPolicy/CELPolicy.docc).
  static let policyYAML = """
    name: pr_size
    rule:
      variables:
        - name: lines
          expression: pr.additions + pr.deletions
      match:
        - condition: variables.lines > 1000
          output: "'large'"
        - condition: variables.lines > 200
          output: "'medium'"
        - output: "'small'"
    """
  static let configYAML = """
    name: pr_size
    variables:
      - name: pr
        type:
          type_name: map
          params:
            - type_name: string
            - type_name: int
    """
  static let testsYAML = """
    description: pull request size
    section:
      - name: sizes
        tests:
          - name: medium
            input:
              pr:
                value:
                  additions: 150
                  deletions: 90
            output:
              value: medium
          - name: large
            input:
              pr:
                expr: "{'additions': 900, 'deletions': 200}"
            output:
              expr: "'lar' + 'ge'"
    """

  @Test func prSizePolicy() throws {
    let compiler = try TestCompiler(options: [.environmentConfig(try EnvironmentConfig(yaml: Self.configYAML))])
    let policy = try compiler.compile(policyFile: Self.policyYAML, path: "pr_size.yaml")
    let runner = try TestRunner(compiler: compiler, policies: [policy])
    let results = runner.run(try TestSuite(yaml: Self.testsYAML))
    #expect(results.count == 2)
    for result in results {
      #expect(result.passed, "\(result.failureDescription ?? "")")
    }
  }
}
