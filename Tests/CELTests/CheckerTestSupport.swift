// Copyright 2018 Google LLC
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
// Ported from cel-go checker/checker_test.go (testInfo, testEnv) and test/compare.go.
//
// The protobuf test messages come from Fixtures/TestTypeTables.swift (tools/test-types): a field table
// standing in for cel-go's protobuf registry until CELProtobuf supplies descriptors.

import Testing

@testable import CEL

/// One row of cel-go's checker test table; generated into Fixtures/CheckerCases.swift.
struct CheckerCase: Sendable, CustomTestStringConvertible {
  var index: Int
  var `in`: String
  var out: String = ""
  var outType: CELType? = nil
  var container: String = ""
  var err: String = ""
  var disableStdEnv = false
  var crossTypeNumericComparisons = true
  var optionalSyntax = false
  var variadicASTs = false
  var jsonFieldNames = false
  var idents: [VariableDecl] = []
  var functions: [FunctionDecl] = []

  var testDescription: String { "\(index) \(self.in)" }
}

/// A message type described by a generated field table.
struct TableStructType: StructTypeDescriptor {
  let typeName: String
  let fields: [TestTypeTables.Field]
  let jsonFieldNames: Bool

  var fieldNames: [String] { fields.map(\.name) }

  func fieldType(named name: String) -> FieldType? {
    // cel-go's TypeDescription.FieldByName: JSON names first when enabled, then proto names.
    let field =
      (jsonFieldNames ? fields.first { $0.jsonName == name } : nil) ?? fields.first { $0.name == name }
    guard let field else {
      return nil
    }
    return FieldType(
      name: field.name, type: field.type, isJSONField: jsonFieldNames && name == field.jsonName)
  }

  func newValue(fields: [String: Value]) -> Value {
    .error(message: "unsupported: constructing \(typeName) in checker tests")
  }
}

/// A registry with the protobuf test messages and enums (cel-go `types.NewRegistry(ProtoTypeDefs(...))`).
func testTypeRegistry(jsonFieldNames: Bool = false) -> TypeRegistry {
  var registry = TypeRegistry()
  for (name, fields) in TestTypeTables.messages.sorted(by: { $0.key < $1.key }) {
    try? registry.register(TableStructType(typeName: name, fields: fields, jsonFieldNames: jsonFieldNames))
  }
  for (name, number) in TestTypeTables.enumValues {
    registry.registerEnumValue(name, number: number)
  }
  return registry
}

/// Compares ignoring spaces, tabs, carriage returns and newlines (cel-go `test.Compare`).
func compareIgnoringWhitespace(_ a: String, _ b: String) -> Bool {
  func strip(_ s: String) -> [Unicode.Scalar] {
    s.unicodeScalars.filter { $0 != " " && $0 != "\n" && $0 != "\t" && $0 != "\r" }
  }
  return strip(a) == strip(b)
}
