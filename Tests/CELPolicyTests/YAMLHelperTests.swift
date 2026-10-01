// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//	https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Ported from cel-go policy/yaml_test.go.

import Testing

@testable import CELPolicy

struct YAMLHelperTests {
  private func root(_ text: String) throws -> YAMLNode {
    let doc = try #require(try YAMLNode.parseDocument(text))
    return try #require(doc.content.first)
  }

  @Test func list() throws {
    let node = try root("\n- first\n- second\n- third")
    #expect(node.isList)
    let elements = node.listElements
    #expect(elements.map(\.value) == ["first", "second", "third"])
    let allStrings = elements.allSatisfy { $0.isString }
    #expect(allStrings)
  }

  @Test func map() throws {
    let node = try root("\nfirst: 1\nsecond: 2\nthird: 3")
    #expect(node.isMap)
    let entries = node.mapEntries
    #expect(entries.map(\.key.value) == ["first", "second", "third"])
    #expect(entries.map(\.value.value) == ["1", "2", "3"])
    let allIntegers = entries.allSatisfy { $0.value.isInteger }
    #expect(allIntegers)
  }

  @Test func mapWithEmptyValue() throws {
    let node = try root("\nfirst: 1\nsecond:\nthird: 3")
    #expect(node.isMap)
    let second = try #require(node.mapEntries.first { $0.key.value == "second" })
    #expect(second.value.isNull)
  }

  @Test func listWithMixedValues() throws {
    let node = try root("\n- 1\n- 'hello'\n- 1.5\n- true\n- null\n- 2006-01-02T15:04:05Z")
    #expect(node.isList)
    let e = node.listElements
    try #require(e.count == 6)
    #expect(e[0].isInteger && e[0].isNumber)
    #expect(e[1].isString)
    #expect(e[2].isDouble && e[2].isNumber)
    #expect(e[3].isBool)
    #expect(e[4].isNull)
    #expect(e[5].isTimestamp)
  }

  @Test func listStringFailure() throws {
    let node = try root("- 1")
    #expect(node.isMap == false)
    #expect(node.isBool == false)
    #expect(node.isDouble == false)
    #expect(node.isInteger == false)
    #expect(node.isNull == false)
    #expect(node.isNumber == false)
    #expect(node.isString == false)
    #expect(node.isTimestamp == false)
    let hasString = node.listElements.contains { $0.isString }
    #expect(hasString == false)
  }

  @Test func blockScalarEntriesAreNormalized() throws {
    let node = try root("key: |\n  text\nother: plain\n")
    let entries = node.mapEntries
    #expect(entries[0].value.line == 2)
    #expect(entries[0].value.column == 2)
    #expect(entries[1].value.line == 3)
    #expect(entries[1].value.column == 8)
  }

  @Test func decodeValue() throws {
    let node = try root("a: [1, 2.5, true, null, '3', 9223372036854775808]\nb: {c: d}\n")
    let value = try node.decodeValue()
    #expect(
      value
        == .map([
          .init(
            key: .string("a"),
            value: .list([.int(1), .double(2.5), .bool(true), .null, .string("3"), .uint(9_223_372_036_854_775_808)])),
          .init(key: .string("b"), value: .map([.init(key: .string("c"), value: .string("d"))])),
        ]))
  }

  @Test func decodeValueRejectsDuplicateKeys() throws {
    let node = try root("a: 1\na: 2\n")
    #expect(throws: YAMLError(message: "yaml: unmarshal errors:\n  line 2: mapping key \"a\" already defined at line 1")) {
      try node.decodeValue()
    }
  }
}
