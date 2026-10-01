// Copyright 2024 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Ported from cel-go policy/parser_test.go and the policyTests table of policy/helper_test.go.

import CEL
import Testing

@testable import CELPolicy

struct PolicyParserTests {
  /// The `policyTests` names of helper_test.go; `k8s` uses the Kubernetes tag visitor.
  static let policyTests = [
    "k8s",
    "unnest",
    "restricted_destinations",
    "limits",
    "nested_rules_unconditional_chaining",
    "nested_rules_unconditional_chaining_optional",
    "nested_rules_unwrap_rewrap",
    "agent_tool_execution_governance",
  ]

  @Test(arguments: policyTests)
  func parse(name: String) throws {
    let parser = PolicyParser(tagVisitor: name == "k8s" ? K8sTagVisitor() : DefaultPolicyTagVisitor())
    let policy = try parser.parse(try Testdata.policySource(name))
    #expect(policy.name.value == name)
  }

  struct ParseErrorCase: Sendable, CustomTestStringConvertible {
    var text: String
    var error: String
    var testDescription: String { text }
  }

  static let parseErrorCases: [ParseErrorCase] = [
    ParseErrorCase(
      text: """

        name:
          illegal: yaml-type
        """,
      error: """
        ERROR: <input>:3:3: got yaml node type tag:yaml.org,2002:map, wanted type(s) [tag:yaml.org,2002:str !txt]
         |   illegal: yaml-type
         | ..^
        """),
    ParseErrorCase(
      text: """

        rule:
          custom: yaml-type
        """,
      error: """
        ERROR: <input>:3:3: unsupported rule tag: custom
         |   custom: yaml-type
         | ..^
        """),
    ParseErrorCase(
      text: """

        inputs:
          - name: a
          - name: b
        """,
      error: """
        ERROR: <input>:2:1: unsupported policy tag: inputs
         | inputs:
         | ^
        """),
    ParseErrorCase(
      text: """

        rule:
          variables:
            - name: "true"
              alt_name: "bool_true"
        """,
      error: """
        ERROR: <input>:5:7: unsupported variable tag: alt_name
         |       alt_name: "bool_true"
         | ......^
        """),
    ParseErrorCase(
      text: """

        rule:
          match:
            - name: "true"
              alt_name: "bool_true"
        """,
      error: """
        ERROR: <input>:4:7: unsupported match tag: name
         |     - name: "true"
         | ......^
        ERROR: <input>:4:7: match does not specify a rule or output
         |     - name: "true"
         | ......^
        ERROR: <input>:5:7: unsupported match tag: alt_name
         |       alt_name: "bool_true"
         | ......^
        """),
    ParseErrorCase(
      text: """

        - rule:
            id: a
        """,
      error: """
        ERROR: <input>:2:1: got yaml node type tag:yaml.org,2002:seq, wanted type(s) [tag:yaml.org,2002:map]
         | - rule:
         | ^
        """),
    ParseErrorCase(
      text: """

        rule:
          match:
            - condition: "true"
              output: "world"
              rule:
                match:
                  - output: "hello"
        """,
      error: """
        ERROR: <input>:6:7: only the rule or the output may be set
         |       rule:
         | ......^
        """),
    ParseErrorCase(
      text: """

        rule:
          match:
            - condition: "true"
              rule:
                match:
                  - output: "hello"
              output: "world"
        """,
      error: """
        ERROR: <input>:8:7: only the rule or the output may be set
         |       output: "world"
         | ......^
        """),
    ParseErrorCase(
      text: """

        rule:
          match:
            - condition: "true"
              explanation: "hi"
              rule:
                match:
                  - output: "hello"
        """,
      error: """
        ERROR: <input>:6:7: explanation can only be set on output match cases, not nested rules
         |       rule:
         | ......^
        """),
    ParseErrorCase(
      text: """

        rule:
          match:
            - condition: "true"
              output: "'foo'"
          aggregate:
            - condition: "true"
              output: "'bar'"
        """,
      error: """
        ERROR: <input>:6:3: Only one of 'match' or 'aggregate' may be set in a rule
         |   aggregate:
         | ..^
        """),
    ParseErrorCase(
      text: """

        rule:
          match:
            - condition: "true"
              rule:
                match:
                  - output: "hello"
              explanation: "hi"
        """,
      error: """
        ERROR: <input>:8:7: explanation can only be set on output match cases, not nested rules
         |       explanation: "hi"
         | ......^
        """),
    ParseErrorCase(
      text: """

        imports:
          - first
        """,
      error: """
        ERROR: <input>:3:5: got yaml node type tag:yaml.org,2002:str, wanted type(s) [tag:yaml.org,2002:map]
         |   - first
         | ....^
        """),
    ParseErrorCase(
      text: """

        imports:
          first: name
        """,
      error: """
        ERROR: <input>:3:3: got yaml node type tag:yaml.org,2002:map, wanted type(s) [tag:yaml.org,2002:seq]
         |   first: name
         | ..^
        """),
    ParseErrorCase(
      text: """

        rule:
          - variables: name
        """,
      error: """
        ERROR: <input>:3:3: got yaml node type tag:yaml.org,2002:seq, wanted type(s) [tag:yaml.org,2002:map]
         |   - variables: name
         | ..^
        """),
    ParseErrorCase(
      text: """

        rule:
          variables: name
        """,
      error: """
        ERROR: <input>:3:14: got yaml node type tag:yaml.org,2002:str, wanted type(s) [tag:yaml.org,2002:seq]
         |   variables: name
         | .............^
        """),
    ParseErrorCase(
      text: "\nrule:\n  variables: \n    - name",
      error: """
        ERROR: <input>:4:7: got yaml node type tag:yaml.org,2002:str, wanted type(s) [tag:yaml.org,2002:map]
         |     - name
         | ......^
        """),
    ParseErrorCase(
      text: "\nrule:\n  match: \n    name: value",
      error: """
        ERROR: <input>:4:5: got yaml node type tag:yaml.org,2002:map, wanted type(s) [tag:yaml.org,2002:seq]
         |     name: value
         | ....^
        """),
    ParseErrorCase(
      text: "\nrule:\n  match: \n    - name",
      error: """
        ERROR: <input>:4:7: got yaml node type tag:yaml.org,2002:str, wanted type(s) [tag:yaml.org,2002:map]
         |     - name
         | ......^
        """),
    ParseErrorCase(
      text: """

        name: test
        rule:
          match:
            - output: 'true'
          aggregate:
            - output: 'true'
        """,
      error: """
        ERROR: <input>:6:3: Only one of 'match' or 'aggregate' may be set in a rule
         |   aggregate:
         | ..^
        """),
    ParseErrorCase(
      text: """

        name: test
        rule:
          aggregate:
            - output: 'true'
          match:
            - output: 'true'
        """,
      error: """
        ERROR: <input>:6:3: Only one of 'match' or 'aggregate' may be set in a rule
         |   match:
         | ..^
        """),
  ]

  @Test(arguments: parseErrorCases)
  func parseError(_ tc: ParseErrorCase) {
    #expect(throws: PolicyError.self) {
      try PolicyParser().parse(PolicySource(tc.text, description: "<input>"))
    }
    do {
      _ = try PolicyParser().parse(PolicySource(tc.text, description: "<input>"))
    } catch {
      #expect(error.description == tc.error)
    }
  }

  @Test func explanationOutputPolicy() throws {
    let text = """

      rule:
        match:
          - condition: "false"
            rule:
              match:
                - condition: "1 > 2"
                  output: "false"
                  explanation: "'bad_inner'"
                - output: "true"
                  explanation: "'good_inner'"
          - output: "true"
            explanation: "'good_outer'"

      """
    let policy = try PolicyParser().parse(PolicySource(text, description: "<input>"))
    let explanation = policy.explanationOutputPolicy()
    let outer = try #require(explanation.rule)
    let inner = try #require(outer.matches[0].rule)
    #expect(inner.matches[0].output?.value == "'bad_inner'")
    #expect(inner.matches[0].condition.value == "1 > 2")
    #expect(inner.matches[1].output?.value == "'good_inner'")
    #expect(outer.matches[1].output?.value == "'good_outer'")
  }

  /// testTagHandler of parser_test.go: records the description and keeps the previous value of a
  /// repeated tag under `prev.<tag>`.
  struct RecordingTagVisitor: PolicyTagVisitor {
    let descriptions = DescriptionBox()

    final class DescriptionBox: @unchecked Sendable {
      var value = ""
    }

    func visitPolicyTag(
      _ tagName: String,
      id: Int64,
      node: YAMLNode,
      policy: inout Policy,
      context: inout PolicyParserContext
    ) {
      if tagName == "description" {
        descriptions.value = node.value
        return
      }
      // Store the last value for a repeated tag
      if let meta = policy.metadata(forKey: tagName) {
        policy.setMetadata(meta, forKey: "prev." + tagName)
        policy.setMetadata(node.value, forKey: tagName)
      } else {
        policy.setMetadata(node.value, forKey: tagName)
      }
    }
  }

  @Test func customTagVisitor() throws {
    let text = """
      name: "test"
      description: |-2
         A test description.
      version: 1
      version: 2
      last-modified: 2026-02-09
      rule:
        match:
          - condition: "true"
            output: "true"

      """
    let visitor = RecordingTagVisitor()
    let policy = try PolicyParser(tagVisitor: visitor).parse(PolicySource(text, description: "<input>"))
    #expect(visitor.descriptions.value == " A test description.")
    #expect(policy.description.value == " A test description.")
    #expect(policy.metadataKeys.count == 3)
    let prevVersion = try #require(policy.metadata(forKey: "prev.version"))
    #expect(prevVersion as? String == "1")
    #expect(policy.metadata(forKey: "version") as? String == "2")
  }

  /// The parsing half of TestSimpleVariables; compiling and evaluating the policy (expected result
  /// 4.0) needs the policy compiler.
  @Test func simpleVariables() throws {
    let text = """
      name: "test"
      rule:
        variables:
          - first: "1.5"
          - second: "2.5"
        match:
          - output: >
              variables.first + variables.second


      """
    let policy = try PolicyParser(simpleVariables: true).parse(PolicySource(text, description: "<input>"))
    let rule = try #require(policy.rule)
    #expect(rule.variables.map(\.name.value) == ["first", "second"])
    #expect(rule.variables.map(\.expression.value) == ["1.5", "2.5"])
    #expect(rule.matches.first?.output?.value == "        variables.first + variables.second")
  }

  @Test func simpleVariablesRejectsSecondEntry() {
    let text = """
      rule:
        variables:
          - first: "1"
            second: "2"
        match:
          - output: "1"
      """
    do {
      _ = try PolicyParser(simpleVariables: true).parse(PolicySource(text, description: "<input>"))
      Issue.record("expected an error")
    } catch {
      #expect(
        error.description == """
          ERROR: <input>:4:7: only one variable may be defined inline
           |       second: "2"
           | ......^
          """)
    }
  }

  @Test func policyAndRuleSemanticMethods() {
    let source = PolicySource("")
    var p = Policy(source: source, sourceInfo: SourceInfo(source: source))
    #expect(p.semantic == .firstMatch)
    p.setSemantic(.aggregate)
    #expect(p.semantic == .aggregate)
    // Attempt to set conflicting semantic
    p.setSemantic(.firstMatch)
    #expect(p.semantic == .aggregate)

    var r = Policy.Rule(sourceID: 123)
    #expect(r.sourceID == 123)
    #expect(r.semantic == .firstMatch)
    r.setSemantic(.aggregate)
    #expect(r.semantic == .aggregate)
    // Attempt to set conflicting semantic
    r.setSemantic(.firstMatch)
    #expect(r.semantic == .aggregate)
  }

  @Test func yamlSyntaxErrorHasNoLocation() {
    do {
      _ = try PolicyParser().parse(PolicySource("a: [1, 2\n", description: "<input>"))
      Issue.record("expected an error")
    } catch {
      #expect(error.description == "ERROR: <input>:-1:0: yaml: line 1: did not find expected ',' or ']'")
    }
  }

  @Test func emptyInputReportsDocumentKind() {
    do {
      _ = try PolicyParser().parse(PolicySource("", description: "<input>"))
      Issue.record("expected an error")
    } catch {
      #expect(error.description == "ERROR: <input>:-1:0: got yaml node of kind 0, wanted mapping node")
    }
  }

  @Test func unsupportedYAMLTag() {
    do {
      _ = try PolicyParser().parse(PolicySource("name: !custom foo\n", description: "<input>"))
      Issue.record("expected an error")
    } catch {
      #expect(
        error.description == """
          ERROR: <input>:1:7: unsupported yaml tag type: !custom
           | name: !custom foo
           | ......^
          """)
    }
  }
}
