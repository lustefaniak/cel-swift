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
import CELGoTestProtos
import CELProtobuf
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

/// A registry with cel-go's proto2 / proto3 test messages (cel-go
/// `types.NewRegistry(types.ProtoTypeDefs(&proto2pb.TestAllTypes{}, &proto3pb.TestAllTypes{}))`).
func testTypeRegistry(jsonFieldNames: Bool = false) -> TypeRegistry {
  let protos = ProtobufTypes(
    files: [
      Google_Expr_Proto3_Test_TestAllTypes_CELFile,
      Google_Expr_Proto2_Test_TestAllTypes_CELFile,
    ],
    jsonFieldNames: jsonFieldNames)
  return TypeRegistry(composing: protos, adapter: protos)
}

/// Compares ignoring spaces, tabs, carriage returns and newlines (cel-go `test.Compare`).
func compareIgnoringWhitespace(_ a: String, _ b: String) -> Bool {
  func strip(_ s: String) -> [Unicode.Scalar] {
    s.unicodeScalars.filter { $0 != " " && $0 != "\n" && $0 != "\t" && $0 != "\r" }
  }
  return strip(a) == strip(b)
}
