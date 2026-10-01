// The example of Sources/CELPolicy/CELPolicy.docc, so the documentation keeps compiling and stays
// true. Keep the two in sync. Not a ported file.

import CEL
import CELPolicy
import Testing

@Suite("Policy documentation examples")
struct PolicyDocumentationTests {
  @Test func landingPage() throws {
    let policyYAML = """
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
    let configYAML = """
      name: pr_size
      variables:
        - name: pr
          type:
            type_name: map
            params:
              - type_name: string
              - type_name: int
      """

    let policy = try PolicyParser().parse(PolicySource(policyYAML, description: "pr_size.yaml"))
    let env = try Environment(.environmentConfig(try EnvironmentConfig(yaml: configYAML)))
    let compiled = try PolicyCompiler().compile(policy, environment: env)
    let result = try compiled.program().evaluate(["pr": ["additions": 150, "deletions": 90]])
    #expect(result.value == "medium")
    #expect(try compiled.program().evaluate(["pr": ["additions": 900, "deletions": 200]]).value == "large")
    #expect(try compiled.program().evaluate(["pr": ["additions": 1, "deletions": 0]]).value == "small")
  }
}
