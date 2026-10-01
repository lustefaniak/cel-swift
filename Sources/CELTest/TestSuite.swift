// Copyright 2025 Google LLC
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

// Ported from cel-go test/suite.go (Suite, Section, Case, InputContext, InputValue, Output) and the
// YAML loading of tools/celtest/test_runner.go (tsParser.ParseYAML).
//
// The runner (createTestsFromYAML, createTestInput, createResultMatcher, ExecuteTest) needs the
// CEL environment and evaluator and is added with the compiler wave.

import CELPolicy

/// A set of CEL tests divided into sections, as in the `tests.yaml` files `celtest` runs.
///
/// ```yaml
/// description: "simple expression tests"
/// section:
///   - name: "valid"
///     tests:
///       - name: "true"
///         input:
///           i:
///             value: 21
///         output:
///           value: true
/// ```
public struct TestSuite: Sendable, Hashable {
  /// The suite name.
  public var name: String
  /// A description of the suite.
  public var description: String
  /// The sections, in file order.
  public var sections: [TestSection]

  /// Creates a suite.
  ///
  /// - Parameters:
  ///   - name: The suite name.
  ///   - description: A description of the suite.
  ///   - sections: The sections.
  public init(name: String = "", description: String = "", sections: [TestSection] = []) {
    self.name = name
    self.description = description
    self.sections = sections
  }

  /// Decodes a suite from the YAML text of a `tests.yaml` file.
  ///
  /// - Parameter yaml: The suite text.
  /// - Throws: `YAMLError` when the text is not valid YAML or does not match the suite shape.
  public init(yaml: String) throws(YAMLError) {
    self.init()
    guard let doc = try YAMLNode.parseDocument(yaml) else {
      return
    }
    self = try withStack(depth: doc.decodeDepthBound) { () throws(YAMLError) -> TestSuite in
      var suite = TestSuite()
      var decoder = YAMLDecoder()
      try decoder.decodeSuite(doc, into: &suite)
      if let error = decoder.unmarshalError {
        throw error
      }
      return suite
    }
  }
}

/// A named group of related tests.
public struct TestSection: Sendable, Hashable {
  /// The section name.
  public var name: String
  /// The tests, in file order.
  public var tests: [TestCase]

  /// Creates a section.
  ///
  /// - Parameters:
  ///   - name: The section name.
  ///   - tests: The tests.
  public init(name: String, tests: [TestCase] = []) {
    self.name = name
    self.tests = tests
  }
}

/// A named test: inputs bound to variables and the expected output.
///
/// When a test needs additional functions to execute, the test harness supplies them.
public struct TestCase: Sendable, Hashable {
  /// The test name.
  public var name: String
  /// A description of the test.
  public var description: String
  /// The input values by variable name.
  public var input: [String: TestInputValue]
  /// A CEL expression producing a message whose fields are the inputs (`context_expr`), used
  /// instead of ``input``.
  public var contextExpression: String?
  /// The expected outcome, or `nil` when the file does not state one.
  public var output: TestOutput?

  /// Creates a test.
  ///
  /// - Parameters:
  ///   - name: The test name.
  ///   - description: A description of the test.
  ///   - input: The input values by variable name.
  ///   - contextExpression: A CEL expression producing the input message, used instead of `input`.
  ///   - output: The expected outcome.
  public init(
    name: String,
    description: String = "",
    input: [String: TestInputValue] = [:],
    contextExpression: String? = nil,
    output: TestOutput? = nil
  ) {
    self.name = name
    self.description = description
    self.input = input
    self.contextExpression = contextExpression
    self.output = output
  }
}

/// An input binding: a literal value or a CEL expression evaluated to produce the value.
public struct TestInputValue: Sendable, Hashable {
  /// The literal value, or `nil` when not set.
  public var value: YAMLValue?
  /// The CEL expression producing the value (`expr`), or `nil` when not set.
  public var expression: String?

  /// Creates an input binding.
  ///
  /// - Parameters:
  ///   - value: The literal value.
  ///   - expression: The CEL expression producing the value; it takes precedence when non-empty.
  public init(value: YAMLValue? = nil, expression: String? = nil) {
    self.value = value
    self.expression = expression
  }
}

/// The expected outcome of a test: a value, a CEL expression to compare against, a set of error
/// substrings, or a set of unknown expression identifiers.
public struct TestOutput: Sendable, Hashable {
  /// The expected literal value, or `nil` when not set.
  public var value: YAMLValue?
  /// A CEL expression whose result is the expected value (`expr`), or `nil` when not set.
  public var expression: String?
  /// Substrings, one of which the evaluation error must contain (`error_set`).
  public var errorSet: [String]?
  /// The expression identifiers the result must be unknown for (`unknown_set`).
  public var unknownSet: [Int64]?

  /// Creates an expected outcome.
  ///
  /// - Parameters:
  ///   - value: The expected literal value.
  ///   - expression: A CEL expression whose result is the expected value.
  ///   - errorSet: Substrings, one of which the evaluation error must contain.
  ///   - unknownSet: The expression identifiers the result must be unknown for.
  public init(
    value: YAMLValue? = nil,
    expression: String? = nil,
    errorSet: [String]? = nil,
    unknownSet: [Int64]? = nil
  ) {
    self.value = value
    self.expression = expression
    self.errorSet = errorSet
    self.unknownSet = unknownSet
  }
}

// MARK: - Decoding

extension YAMLDecoder {
  fileprivate mutating func decodeSuite(_ node: YAMLNode, into suite: inout TestSuite) throws(YAMLError) {
    try decodeObject(node, typeName: "test.Suite", fields: ["name", "description", "section"]) {
      (d, key, v) throws(YAMLError) in
      switch key {
      case "name": suite.name = try d.decodeString(v) ?? ""
      case "description": suite.description = try d.decodeString(v) ?? ""
      default:
        suite.sections =
          try d.decodeList(v, typeName: "[]*test.Section") { (d, n) throws(YAMLError) in
            try d.decodeSection(n)
          } ?? []
      }
    }
  }

  private mutating func decodeSection(_ node: YAMLNode) throws(YAMLError) -> TestSection {
    var section = TestSection(name: "")
    try decodeObject(node, typeName: "test.Section", fields: ["name", "tests"]) { (d, key, v) throws(YAMLError) in
      switch key {
      case "name": section.name = try d.decodeString(v) ?? ""
      default:
        section.tests =
          try d.decodeList(v, typeName: "[]*test.Case") { (d, n) throws(YAMLError) in
            try d.decodeCase(n)
          } ?? []
      }
    }
    return section
  }

  private mutating func decodeCase(_ node: YAMLNode) throws(YAMLError) -> TestCase {
    var tc = TestCase(name: "")
    let fields: Set<String> = ["name", "description", "input", "context_expr", "output"]
    try decodeObject(node, typeName: "test.Case", fields: fields) { (d, key, v) throws(YAMLError) in
      switch key {
      case "name": tc.name = try d.decodeString(v) ?? ""
      case "description": tc.description = try d.decodeString(v) ?? ""
      case "input":
        tc.input =
          try d.decodeStringMap(v, typeName: "map[string]*test.InputValue") { (d, n) throws(YAMLError) in
            try d.decodeInputValue(n)
          } ?? [:]
      case "context_expr": tc.contextExpression = try d.decodeString(v)
      default:
        tc.output = try d.decodeOutput(v)
      }
    }
    return tc
  }

  private mutating func decodeInputValue(_ node: YAMLNode) throws(YAMLError) -> TestInputValue {
    var input = TestInputValue()
    try decodeObject(node, typeName: "test.InputValue", fields: ["value", "expr"]) { (d, key, v) throws(YAMLError) in
      switch key {
      case "value": input.value = try d.decodeValue(v)
      default: input.expression = try d.decodeString(v)
      }
    }
    return input
  }

  private mutating func decodeOutput(_ node: YAMLNode) throws(YAMLError) -> TestOutput? {
    if YAMLDecoder.isNull(node) {
      return nil
    }
    var output = TestOutput()
    try decodeObject(node, typeName: "test.Output", fields: ["value", "expr", "error_set", "unknown_set"]) {
      (d, key, v) throws(YAMLError) in
      switch key {
      case "value": output.value = try d.decodeValue(v)
      case "expr": output.expression = try d.decodeString(v)
      case "error_set":
        output.errorSet = try d.decodeList(v, typeName: "[]string") { (d, n) throws(YAMLError) in
          try d.decodeString(n)
        }
      default:
        output.unknownSet = try d.decodeList(v, typeName: "[]int64") { (d, n) throws(YAMLError) in
          try d.decodeInt64(n)
        }
      }
    }
    return output
  }
}
