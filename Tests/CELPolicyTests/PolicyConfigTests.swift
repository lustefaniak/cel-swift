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

// Ported from cel-go policy/config_test.go.

import CEL
import CELGoTestProtos
import CELPolicy
import CELProtobuf
import Testing

struct PolicyConfigTests {
  static let configs: [String] = [
    """
    name: hello
    """,
    """
    description: empty
    """,
    """
    container: pb.pkg
    """,
    """
    extensions:
      - name: "bindings"
      - name: "encoders"
      - name: "lists"
      - name: "math"
      - name: "optional"
      - name: "protos"
      - name: "sets"
      - name: "strings"
        version: 1
    """,
    """
    functions:
      - name: "coalesce"
        overloads:
          - id: "null_coalesce_int"
            target:
              type_name: "null_type"
            args:
              - type_name: "int"
            return:
              type_name: "int"
          - id: "coalesce_null_int"
            args:
              - type_name: "null_type"
              - type_name: "int"
            return:
              type_name: "int"
          - id: "int_coalesce_int"
            target:
              type_name: "int"
            args:
              - type_name: "int"
            return:
              type_name: "int"
          - id: "optional_T_coalesce_T"
            target:
              type_name: "optional_type"
              params:
                - type_name: "T"
                  is_type_param: true
            args:
              - type_name: "T"
                is_type_param: true
            return:
              type_name: "T"
              is_type_param: true
    """,
    """
    variables:
    - name: "request"
      type:
        type_name: "map"
        params:
          - type_name: "string"
          - type_name: "dyn"
    """,
    """
    variables:
    - name: "request"
      type:
        type_name: "google.expr.proto3.test.TestAllTypes"
    """,
  ]

  /// Every config extends an environment with optional types and proto3 `TestAllTypes`
  /// (cel-go `TestConfig`).
  @Test(arguments: configs)
  func config(_ yaml: String) throws {
    let base = try Environment(
      .optionalTypes,
      .typeProvider(ProtobufTypes(files: [Google_Expr_Proto3_Test_TestAllTypes_CELFile])))
    let config = try EnvironmentConfig(yaml: yaml)
    _ = try base.extending(.environmentConfig(config))
  }

  struct ErrorCase: Sendable, CustomTestStringConvertible {
    var config: String
    var err: String
    var testDescription: String { err }
  }

  static let errorCases: [ErrorCase] = [
    ErrorCase(
      config: """
        extensions:
          - name: "bad_name"
        """,
      err: "unrecognized extension: bad_name"),
    ErrorCase(
      config: """
        variables:
          - name: "bad_type"
            type:
              type_name: "strings"
        """,
      err: #"invalid variable "bad_type": undefined type name: "strings""#),
    ErrorCase(
      config: """
        variables:
          - name: "bad_list"
            type:
              type_name: "list"
        """,
      err: #"invalid variable "bad_list": invalid type: list expects 1 parameter, got 0"#),
    ErrorCase(
      config: """
        variables:
          - name: "bad_map"
            type:
              type_name: "map"
              params:
                - type_name: "string"
        """,
      err: #"invalid variable "bad_map": invalid type: map expects 2 parameters, got 1"#),
    ErrorCase(
      config: """
        variables:
          - name: "bad_list_type_param"
            type:
              type_name: "list"
              params:
                - type_name: "number"
        """,
      err: #"invalid variable "bad_list_type_param": undefined type name: "number""#),
    ErrorCase(
      config: """
        variables:
          - name: "bad_map_type_param"
            type:
              type_name: "map"
              params:
                - type_name: "string"
                - type_name: "invalid_opaque_type"
        """,
      err: #"invalid variable "bad_map_type_param": undefined type name: "invalid_opaque_type""#),
    ErrorCase(
      config: """
        context_variable:
          type_name: "bad.proto.MessageType"
        """,
      err: #"invalid context proto type: "bad.proto.MessageType""#),
    ErrorCase(
      config: """
        variables:
          - type:
              type_name: "no variable name"
        """,
      err: "invalid variable: missing variable name"),
    ErrorCase(
      config: """
        functions:
          - name: "bad_return"
            overloads:
              - id: "zero_arity"
                return:
                  type_name: "mystery"
        """,
      err: #"invalid function "bad_return": undefined type name: "mystery""#),
    ErrorCase(
      config: """
        functions:
          - name: "bad_target"
            overloads:
              - id: "unary_member"
                target:
                  type_name: "unknown"
                return:
                  type_name: "null_type"
        """,
      err: #"invalid function "bad_target": undefined type name: "unknown""#),
    ErrorCase(
      config: """
        functions:
          - name: "bad_arg"
            overloads:
              - id: "unary_global"
                args:
                  - type_name: "unknown"
                return:
                  type_name: "null_type"
        """,
      err: #"invalid function "bad_arg": undefined type name: "unknown""#),
    ErrorCase(
      config: """
        functions:
          - name: "missing_return"
            overloads:
              - id: "unary_global"
                args:
                  - type_name: "null_type"
        """,
      err: #"invalid function "missing_return": invalid overload "unary_global" return: invalid type: nil"#),
  ]

  /// Invalid configs fail to extend the environment with cel-go's message (cel-go
  /// `TestConfigErrors`).
  @Test(arguments: errorCases)
  func configError(_ tc: ErrorCase) throws {
    let base = try Environment(.optionalTypes)
    let config = try EnvironmentConfig(yaml: tc.config)
    #expect(throws: (any Error).self) {
      _ = try base.extending(.environmentConfig(config))
    }
    do {
      _ = try base.extending(.environmentConfig(config))
    } catch {
      #expect(error.description == tc.err)
    }
  }
}
