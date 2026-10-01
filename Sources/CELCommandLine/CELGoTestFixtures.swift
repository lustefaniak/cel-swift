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

// The function bindings and types cel-go's policy and celtest test runners add: `locationCode`
// (policy/test/cel_test_runner.go), `hasCreditCard` / `hasEmailOrPhone` (policy/helper_test.go),
// `fn` (tools/celtest/test_runner_test.go) and the proto3 / proto2 test messages
// (`//policy:test_all_types_fds`).

import CEL
import CELGoTestProtos
import CELProtobuf

/// The environment options cel-go's test runners use for the suites under `policy/testdata` and
/// `tools/celtest/testdata`, so those suites run unchanged.
package enum CELGoTestFixtures {
  /// `locationCode(string) -> string`: `us` for 10.0.0.1, `de` for 10.0.0.2, `ir` otherwise.
  package static let locationCode = Environment.Option.function(
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

  /// `hasCreditCard(dyn) -> bool` and `hasEmailOrPhone(dyn) -> bool`: whether a map has the
  /// `cc` key, or an `email` or `phone` key.
  package static let agentFunctions: [Environment.Option] = [
    .function(
      "hasCreditCard",
      .overload("hasCreditCard", argTypes: [.dyn], resultType: .bool, .unaryBinding { mapContains($0, ["cc"]) })),
    .function(
      "hasEmailOrPhone",
      .overload(
        "hasEmailOrPhone", argTypes: [.dyn], resultType: .bool,
        .unaryBinding { mapContains($0, ["email", "phone"]) })),
  ]

  /// `fn(int) -> int`: halves its argument.
  package static let fn = Environment.Option.function(
    "fn",
    .overload(
      "fn_int", argTypes: [.int], resultType: .int,
      .unaryBinding { value in
        guard case .int(let i) = value else {
          return value
        }
        return .int(i / 2)
      }))

  /// The proto3 and proto2 `TestAllTypes` messages and their imports.
  package static var types: Environment.Option {
    .typeProvider(
      ProtobufTypes(files: [
        Google_Expr_Proto3_Test_TestAllTypes_CELFile,
        Google_Expr_Proto2_Test_TestAllTypes_CELFile,
      ]))
  }

  /// Every fixture: the test types first, so configs can refer to them, then the functions.
  package static var all: [Environment.Option] {
    [types, locationCode, fn] + agentFunctions
  }

  static func mapContains(_ value: Value, _ keys: [String]) -> Value {
    guard case .map(let m) = value else {
      return .bool(false)
    }
    return .bool(keys.contains { m.value(forKey: .string($0)) != nil })
  }
}
