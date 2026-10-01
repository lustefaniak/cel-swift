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

// Ported from cel-go policy/compiler_test.go and policy/helper_test.go (the runner, compile and
// readPolicyConfig helpers).

import CEL
import Testing

@testable import CELPolicy

/// The functions cel-go's policy tests bind (`locationCode`, `hasCreditCard`, `hasEmailOrPhone`).
enum TestFunctions {
  static let locationCode = Environment.Option.function(
    "locationCode",
    .overload(
      "locationCode_string", argTypes: [.string], resultType: .string,
      .unaryBinding { ip in
        switch ip {
        case .string("10.0.0.1"): return .string("us")
        case .string("10.0.0.2"): return .string("de")
        default: return .string("ir")
        }
      }))

  static func mapContains(_ value: Value, _ keys: [String]) -> Value {
    guard case .map(let m) = value else {
      return .bool(false)
    }
    return .bool(keys.contains { m.value(forKey: .string($0)) != nil })
  }

  static let agentFunctions: [Environment.Option] = [
    .function(
      "hasCreditCard",
      .overload("hasCreditCard", argTypes: [.dyn], resultType: .bool, .unaryBinding { mapContains($0, ["cc"]) })),
    .function(
      "hasEmailOrPhone",
      .overload(
        "hasEmailOrPhone", argTypes: [.dyn], resultType: .bool,
        .unaryBinding { mapContains($0, ["email", "phone"]) })),
  ]
}

/// cel-go's `normalize`: removes spaces, newlines and tabs.
func normalize(_ s: String) -> String {
  String(String.UnicodeScalarView(s.unicodeScalars.filter { $0 != " " && $0 != "\n" && $0 != "\t" }))
}

/// Parses `policy/testdata/<name>/policy.yaml` (cel-go `parsePolicy`).
func parseTestPolicy(_ name: String) throws -> Policy {
  let parser = PolicyParser(tagVisitor: name == "k8s" ? K8sTagVisitor() : DefaultPolicyTagVisitor())
  let policy = try parser.parse(try Testdata.policySource(name))
  #expect(policy.name.value == name)
  return policy
}

/// The environment of cel-go's `compile` helper: a custom environment with optional types, macro
/// call tracking, the extended validators and bindings, then the test options and the config.
func testEnvironment(_ name: String, options: [Environment.Option] = []) throws -> Environment {
  let config = try EnvironmentConfig(yaml: try Testdata.read("policy/testdata/\(name)/config.yaml"))
  var all: [Environment.Option] = [
    .optionalTypes, .macroCallTracking, .validators(ExpressionValidator.extended),
  ]
  if let bindings = PolicyExtensions.resolve("bindings", version: Library.latestVersion) {
    all.append(.library(bindings))
  }
  all += options
  all.append(.environmentConfig(config))
  return try Environment.custom(options: all)
}

/// Runs `policy/testdata/<name>/tests.yaml` against a compiled policy (cel-go `runner.run`):
/// inputs are values or expressions, the program is optimized, and an optional result matches
/// the expected value it holds.
func runPolicyTests(_ name: String, _ compiled: CompiledPolicy, sourceLocation: SourceLocation = #_sourceLocation)
  throws
{
  let suite = try TestSuiteFile.read(name)
  let program = try compiled.program(options: [.optimize, .errorsAsValues])
  let env = compiled.environment
  func eval(_ expr: String) throws -> Value {
    try env.program(try env.compile(expr)).evaluate().value
  }
  for section in suite.sections {
    for test in section.tests {
      var input: [String: Value] = [:]
      for (key, value) in test.input {
        if let expr = value.expression, !expr.isEmpty {
          input[key] = try eval(expr)
        } else if let literal = value.value {
          input[key] = Value(policyTestYAML: literal)
        }
      }
      let out = program.run(MapActivation(input)).value
      if case .error(let e) = out {
        Issue.record("\(name)/\(section.name)/\(test.name): eval failed: \(e)", sourceLocation: sourceLocation)
        continue
      }
      var want: Value = .null
      if let expr = test.expected.expression, !expr.isEmpty {
        want = try eval(expr)
      } else if let value = test.expected.value {
        want = Value(policyTestYAML: value)
      }
      if case .bool(true) = want.celEquals(out) {
        continue
      }
      if case .optional(let inner) = out {
        if let inner {
          if case .bool(true) = want.celEquals(inner) {
            continue
          }
        } else if case .optional(nil) = want {
          continue
        }
      }
      Issue.record(
        "\(name)/\(section.name)/\(test.name): policy eval got \(out), wanted \(want)", sourceLocation: sourceLocation)
    }
  }
}

/// A minimal reader for the `tests.yaml` files, enough for the compiler tests; the CELTest
/// target has the full suite model and runner.
struct TestSuiteFile {
  struct Section {
    var name: String
    var tests: [Case]
  }

  struct Case {
    var name: String
    var input: [String: (value: YAMLValue?, expression: String?)]
    var expected: (value: YAMLValue?, expression: String?)
  }

  var sections: [Section]

  static func read(_ name: String) throws -> TestSuiteFile {
    let text = try Testdata.read("policy/testdata/\(name)/tests.yaml")
    guard let doc = try YAMLNode.parseDocument(text), case .map(let root) = try doc.decodeValue() else {
      return TestSuiteFile(sections: [])
    }
    var sections: [Section] = []
    for entry in root where entry.key == .string("section") {
      guard case .list(let items) = entry.value else { continue }
      for item in items {
        sections.append(section(item))
      }
    }
    return TestSuiteFile(sections: sections)
  }

  static func field(_ v: YAMLValue, _ key: String) -> YAMLValue? {
    guard case .map(let entries) = v else { return nil }
    return entries.first { $0.key == .string(key) }?.value
  }

  static func string(_ v: YAMLValue?) -> String? {
    if case .string(let s)? = v { return s }
    return nil
  }

  static func section(_ v: YAMLValue) -> Section {
    var tests: [Case] = []
    if case .list(let items)? = field(v, "tests") {
      for item in items {
        var input: [String: (value: YAMLValue?, expression: String?)] = [:]
        if case .map(let entries)? = field(item, "input") {
          for entry in entries {
            if case .string(let key) = entry.key {
              input[key] = (field(entry.value, "value"), string(field(entry.value, "expr")))
            }
          }
        }
        let output = field(item, "output") ?? .null
        tests.append(
          Case(
            name: string(field(item, "name")) ?? "", input: input,
            expected: (field(output, "value"), string(field(output, "expr")))))
      }
    }
    return Section(name: string(field(v, "name")) ?? "", tests: tests)
  }
}

extension Value {
  init(policyTestYAML yaml: YAMLValue) {
    switch yaml {
    case .null: self = .null
    case .bool(let b): self = .bool(b)
    case .int(let i): self = .int(i)
    case .uint(let u): self = .uint(u)
    case .double(let d): self = .double(d)
    case .string(let s): self = .string(s)
    case .list(let items): self = .list(ArrayList(items.map(Value.init(policyTestYAML:))))
    case .map(let entries):
      var pairs: [(MapKey, Value)] = []
      for entry in entries {
        if let key = MapKey(Value(policyTestYAML: entry.key)) {
          pairs.append((key, Value(policyTestYAML: entry.value)))
        }
      }
      self = .map(OrderedMap(pairs))
    }
  }
}
