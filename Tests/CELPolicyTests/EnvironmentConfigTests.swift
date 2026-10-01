// Copyright 2024 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Ported from the model-only tests of cel-go common/env/env_test.go and common/env/io_test.go.
// Tests that resolve a config against an environment (AsCELVariable, AsCELFunction,
// SubsetFunction, AddVariableDecls, policy/config_test.go) need the core environment and come with
// the compiler wave.

import Testing

@testable import CELPolicy

typealias TD = EnvironmentConfig.TypeDescriptor

struct EnvironmentConfigTests {
  struct ConfigFileCase: Sendable, CustomTestStringConvertible {
    var file: String
    var want: EnvironmentConfig
    var testDescription: String { file }
  }

  static let configFiles: [ConfigFileCase] = {
    var context = EnvironmentConfig(name: "context-env")
    context.container = "google.expr"
    context.imports = [.init(name: "google.expr.proto3.test.TestAllTypes")]
    var contextLib = EnvironmentConfig.LibrarySubset()
    contextLib.includedMacros = ["has"]
    contextLib.includedFunctions = ["_==_", "_!=_", "!_", "_<_", "_<=_", "_>_", "_>=_"].map {
      EnvironmentConfig.Function(name: $0)
    }
    context.standardLibrary = contextLib
    context.extensions = [.init(name: "optional", versionNumber: UInt32.max), .init(name: "strings", versionNumber: 1)]
    context.contextVariable = .init(typeName: "google.expr.proto3.test.TestAllTypes")
    context.functions = [
      .init(
        name: "coalesce",
        description: "Converts a potentially null wrapper-type to a default value.",
        overloads: [
          .init(
            id: "coalesce_wrapped_int", arguments: [TD("google.protobuf.Int64Value"), TD("int")], resultType: TD("int"),
            examples: ["coalesce(null, 1) // 1", "coalesce(2, 1) // 2"]),
          .init(
            id: "coalesce_wrapped_double", arguments: [TD("google.protobuf.DoubleValue"), TD("double")],
            resultType: TD("double"), examples: ["coalesce(null, 1.3) // 1.3"]),
          .init(
            id: "coalesce_wrapped_uint", arguments: [TD("google.protobuf.UInt64Value"), TD("uint")],
            resultType: TD("uint"), examples: ["coalesce(null, 14u) // 14u"]),
        ])
    ]

    func extended(wrapperName: String, includeAlt: Bool) -> EnvironmentConfig {
      var c = EnvironmentConfig(name: "extended-env")
      c.container = "google.expr"
      c.extensions = [.init(name: "optional", versionNumber: 2), .init(name: "math", versionNumber: UInt32.max)]
      c.variables = [
        .init(
          name: "msg", type: TD("google.expr.proto3.test.TestAllTypes"),
          description: "msg represents all possible type permutation which CEL understands from a proto perspective"),
        .init(
          name: "opt_msg", type: TD("optional_type", parameters: [TD("google.expr.proto3.test.TestAllTypes")]),
          description: "opt_msg represents all possible type permutation which CEL understands from a proto perspective"),
      ]
      let isEmptyDescription = "determines whether a list is empty,\nor a string has no characters"
      c.functions = [
        .init(
          name: "isEmpty", description: isEmptyDescription,
          overloads: [
            .init(
              id: "wrapper_string_isEmpty", target: TD(wrapperName), resultType: TD("bool"),
              examples: ["''.isEmpty() // true"]),
            .init(
              id: "list_isEmpty", target: TD("list", parameters: [.typeParameter("T")]), resultType: TD("bool"),
              examples: ["[].isEmpty() // true", "[1].isEmpty() // false"]),
          ])
      ]
      if includeAlt {
        c.functions.append(
          .init(
            name: "isEmptyAlt", description: isEmptyDescription,
            overloads: [
              .init(
                id: "wrapper_string_isEmpty", target: TD("string_wrapper"), resultType: TD("bool"),
                examples: ["''.isEmptyAlt() // true"]),
              .init(
                id: "list_isEmpty", target: TD("list", parameters: [.typeParameter("T")]), resultType: TD("bool"),
                examples: ["[].isEmptyAlt() // true", "[1].isEmptyAlt() // false"]),
            ]))
      }
      c.functions.append(
        .init(
          name: "getOrDefault",
          description: "Returns the value of a key in a map or the provided\ndefault value.",
          overloads: [
            .init(
              id: "map_getOrDefault", target: TD("map", parameters: [.typeParameter("K"), .typeParameter("V")]),
              arguments: [.typeParameter("K"), .typeParameter("V")], resultType: .typeParameter("V"))
          ]))
      c.features = [.init(name: "cel.feature.macro_call_tracking", isEnabled: true)]
      c.limits = [.init(name: "cel.limit.parse_recursion_depth", value: 7)]
      c.validators = [
        .init(name: "cel.validator.duration"),
        .init(name: "cel.validator.matches"),
        .init(name: "cel.validator.timestamp"),
        .init(name: "cel.validator.comprehension_nesting_limit", config: ["limit": .int(2)]),
      ]
      return c
    }

    var subset = EnvironmentConfig(name: "subset-env")
    var subsetLib = EnvironmentConfig.LibrarySubset()
    subsetLib.excludedMacros = ["map", "filter"]
    subsetLib.excludedFunctions = [
      .init(
        name: "_+_",
        overloads: [
          .init(id: "add_bytes", resultType: nil), .init(id: "add_list", resultType: nil),
          .init(id: "add_string", resultType: nil),
        ]),
      .init(name: "matches"),
      .init(name: "timestamp", overloads: [.init(id: "string_to_timestamp", resultType: nil)]),
      .init(name: "duration", overloads: [.init(id: "string_to_duration", resultType: nil)]),
    ]
    subset.standardLibrary = subsetLib
    subset.variables = [.init(name: "x", type: TD("int")), .init(name: "y", type: TD("double")), .init(name: "z", type: TD("uint"))]

    return [
      ConfigFileCase(file: "context_env.yaml", want: context),
      ConfigFileCase(file: "extended_env.yaml", want: extended(wrapperName: "google.protobuf.StringValue", includeAlt: true)),
      ConfigFileCase(file: "json_env.json", want: extended(wrapperName: "wrapper_string", includeAlt: false)),
      ConfigFileCase(file: "subset_env.yaml", want: subset),
    ]
  }()

  @Test(arguments: configFiles)
  func config(_ tc: ConfigFileCase) throws {
    var got = try EnvironmentConfig(yaml: try Testdata.read("common/env/testdata/\(tc.file)"))
    try got.validate()
    // As in cel-go, the name and description are not compared.
    got.name = tc.want.name
    got.description = tc.want.description
    #expect(got.container == tc.want.container)
    #expect(got.imports == tc.want.imports)
    #expect(got.standardLibrary == tc.want.standardLibrary)
    #expect(got.contextVariable == tc.want.contextVariable)
    #expect(got.variables == tc.want.variables)
    #expect(got.functions == tc.want.functions)
    #expect(got.features == tc.want.features)
    #expect(got.limits == tc.want.limits)
    #expect(got.validators == tc.want.validators)
    #expect(got == tc.want)
  }

  struct ValidateCase: Sendable, CustomTestStringConvertible {
    var name: String
    var config: EnvironmentConfig
    var want: String?
    var testDescription: String { name }
  }

  static let validateCases: [ValidateCase] = {
    func with(_ name: String, _ f: (inout EnvironmentConfig) -> Void) -> EnvironmentConfig {
      var c = EnvironmentConfig(name: name)
      f(&c)
      return c
    }
    var badSubset = EnvironmentConfig.LibrarySubset()
    badSubset.excludedMacros = ["has"]
    badSubset.includedMacros = ["exists"]
    return [
      ValidateCase(name: "empty config valid", config: EnvironmentConfig(), want: nil),
      ValidateCase(name: "invalid import", config: with("i") { $0.imports = [.init(name: "")] }, want: "invalid import"),
      ValidateCase(name: "invalid subset", config: with("s") { $0.standardLibrary = badSubset }, want: "invalid subset"),
      ValidateCase(
        name: "invalid extension", config: with("e") { $0.extensions = [.init(name: "", versionNumber: 0)] },
        want: "invalid extension"),
      ValidateCase(
        name: "invalid context variable", config: with("c") { $0.contextVariable = .init(typeName: "") },
        want: "invalid context variable"),
      ValidateCase(
        name: "invalid variable", config: with("v") { $0.variables = [.init(name: "", type: nil)] },
        want: "invalid variable"),
      ValidateCase(
        name: "type parameter variable", config: with("v") { $0.variables = [.init(name: "foo", type: .typeParameter("X"))] },
        want: "variables cannot be type parameters"),
      ValidateCase(
        name: "colliding context variable",
        config: with("c") {
          $0.contextVariable = .init(typeName: "msg.type.Name")
          $0.variables = [.init(name: "local", type: TD("string"))]
        },
        want: "invalid config"),
      ValidateCase(
        name: "invalid function", config: with("f") { $0.functions = [.init(name: "")] }, want: "invalid function"),
      ValidateCase(
        name: "invalid feature", config: with("f") { $0.features = [.init(name: "", isEnabled: false)] },
        want: "invalid feature"),
      ValidateCase(
        name: "invalid validator", config: with("v") { $0.validators = [.init(name: "")] }, want: "invalid validator"),
    ]
  }()

  @Test(arguments: validateCases)
  func validateErrors(_ tc: ValidateCase) {
    do {
      try tc.config.validate()
      #expect(tc.want == nil)
    } catch {
      #expect(tc.want != nil, "unexpected error: \(error)")
      if let want = tc.want {
        #expect(error.description.contains(want))
      }
    }
  }

  @Test(arguments: [
    ("int", TD("int")),
    ("foo", TD("foo")),
    (".com.example.Message", TD(".com.example.Message")),
    ("list<int>", TD("list", parameters: [TD("int")])),
    (" list < int > ", TD("list", parameters: [TD("int")])),
    ("map<int, list<string>>", TD("map", parameters: [TD("int"), TD("list", parameters: [TD("string")])])),
    ("list<\n\tint\n>", TD("list", parameters: [TD("int")])),
    ("map<\r\n  string,\r\n  list<string>\r\n>", TD("map", parameters: [TD("string"), TD("list", parameters: [TD("string")])])),
    ("map<string,\tint>", TD("map", parameters: [TD("string"), TD("int")])),
  ])
  func parseTypeDescriptor(text: String, want: TD) throws {
    #expect(try TD(parsing: text) == want)
  }

  @Test(arguments: [
    ("", "missing identifier at position 0"),
    ("int int", "nexpected character 'i'"),
    ("int>", "unexpected character '>'"),
    (".foo.", "unexpected end of input"),
    ("..foo", "identifier is expected, but '.' was found at position 1"),
    ("~", "unexpected end of input"),
    ("~1", "invalid type parameter identifier '1' at position 1"),
    ("~elem", "invalid type param, must have a single alphabetic character at position 2"),
    ("list<", "missing identifier at position 5"),
  ])
  func parseTypeDescriptorErrors(text: String, wantError: String) {
    do {
      _ = try TD(parsing: text)
      Issue.record("TD(parsing: \(text)) succeeded, wanted error \(wantError)")
    } catch {
      #expect(error.description.contains(wantError))
    }
  }

  @Test func typeDescriptorDescription() {
    #expect(TD("string").description == "string")
    #expect(TD("list", parameters: [.typeParameter("T")]).description == "list(T)")
    #expect(TD("type", parameters: [.typeParameter("T")]).description == "type(T)")
    #expect(TD("map", parameters: [TD("string"), .typeParameter("T")]).description == "map(string,T)")
    #expect(TD("map", parameters: [TD("string"), .typeParameter("T")]).specifier == "map<string, ~T>")
  }

  @Test func librarySubsetValidate() {
    var lib = EnvironmentConfig.LibrarySubset()
    #expect(throws: Never.self) { try lib.validate() }
    lib.excludedFunctions = [.init(name: "size")]
    #expect(throws: Never.self) { try lib.validate() }
    lib.includedFunctions = [.init(name: "size")]
    #expect(throws: EnvironmentConfigError(messages: ["invalid subset: cannot both include and exclude functions"])) {
      try lib.validate()
    }
    var macros = EnvironmentConfig.LibrarySubset()
    macros.includedMacros = ["has"]
    #expect(throws: Never.self) { try macros.validate() }
    macros.excludedMacros = ["exists"]
    #expect(throws: EnvironmentConfigError(messages: ["invalid subset: cannot both include and exclude macros"])) {
      try macros.validate()
    }
  }

  @Test func subsetMacro() {
    let empty = EnvironmentConfig.LibrarySubset()
    #expect(empty.includesMacro("has"))
    var disabled = EnvironmentConfig.LibrarySubset()
    disabled.isDisabled = true
    #expect(disabled.includesMacro("has") == false)
    var noMacros = EnvironmentConfig.LibrarySubset()
    noMacros.disablesMacros = true
    #expect(noMacros.includesMacro("has") == false)
    var allow = EnvironmentConfig.LibrarySubset()
    allow.includedMacros = ["exists"]
    #expect(allow.includesMacro("has") == false)
    #expect(allow.includesMacro("exists"))
    var deny = EnvironmentConfig.LibrarySubset()
    deny.excludedMacros = ["exists"]
    #expect(deny.includesMacro("exists") == false)
    #expect(deny.includesMacro("has"))
  }

  @Test func newExtension() {
    #expect(EnvironmentConfig.Extension(name: "strings", versionNumber: UInt32.max) == .init(name: "strings", version: "latest"))
    #expect(EnvironmentConfig.Extension(name: "bindings", versionNumber: 1) == .init(name: "bindings", version: "1"))
  }

  @Test(arguments: [
    (EnvironmentConfig.Extension(name: ""), "missing name"),
    (EnvironmentConfig.Extension(name: "test", version: "1.0"), "invalid syntax"),
    (EnvironmentConfig.Extension(name: "test", version: "4294967296"), "value out of range"),
  ])
  func extensionVersionErrors(ext: EnvironmentConfig.Extension, wantError: String) {
    #expect {
      try ext.versionNumber()
    } throws: { error in
      (error as? EnvironmentConfigError)?.description.contains(wantError) ?? false
    }
  }

  @Test func extensionVersions() throws {
    #expect(try EnvironmentConfig.Extension(name: "test").versionNumber() == 0)
    #expect(try EnvironmentConfig.Extension(name: "test", version: "1").versionNumber() == 1)
    #expect(try EnvironmentConfig.Extension(name: "test", version: "latest").versionNumber() == UInt32.max)
    #expect(
      EnvironmentConfig.Extension(name: "test", version: "1.0").versionNumberResult()
        == .failure(
          EnvironmentConfigError(messages: [
            "invalid extension \"test\" version: strconv.ParseUint: parsing \"1.0\": invalid syntax"
          ])))
  }

  @Test func elementValidation() {
    #expect(EnvironmentConfig.Import(name: "").validationErrors() == ["invalid import: missing type name"])
    #expect(EnvironmentConfig.ContextVariable(typeName: "").validationErrors() == ["invalid context variable: missing type name"])
    #expect(EnvironmentConfig.Validator(name: "").validationErrors() == ["invalid validator: missing name"])
    #expect(EnvironmentConfig.Feature(name: "", isEnabled: true).validationErrors() == ["invalid feature: missing name"])
    #expect(EnvironmentConfig.Limit(name: "", value: 1).validationErrors() == ["invalid limit: missing name"])
    let validator = EnvironmentConfig.Validator(name: "validator", config: ["limit": .int(2)])
    #expect(validator.config["absent"] == nil)
    #expect(validator.config["limit"] == .int(2))
  }

  /// Inline `type_name` fields take precedence over `type` (Variable.UnmarshalYAML), and `type`
  /// accepts both a specifier string and a structured type.
  @Test func variableTypeForms() throws {
    let config = try EnvironmentConfig(
      yaml: """
        variables:
          - name: inline
            type_name: type.name.EmbeddedType
            type: type.name.FieldType
          - name: field
            type:
              type_name: map
              params:
                - type_name: string
                - type_name: V
                  is_type_param: true
          - name: specifier
            type: map<int, string>
          - name: untyped
        """)
    #expect(config.variables.map(\.type) == [
      TD("type.name.EmbeddedType"),
      TD("map", parameters: [TD("string"), .typeParameter("V")]),
      TD("map", parameters: [TD("int"), TD("string")]),
      nil,
    ])
  }

  /// Decode errors, compared with go-yaml's output for the same input.
  @Test(arguments: [
    ("name: [a]\n", "yaml: unmarshal errors:\n  line 1: cannot unmarshal !!seq into string"),
    ("variables: foo\n", "yaml: unmarshal errors:\n  line 1: cannot unmarshal !!str `foo` into []*env.Variable"),
    ("variables:\n  - name: x\n    type: 'list<'\n", "failed to parse type \"list<\": missing identifier at position 5"),
    ("name: a\nname: b\n", "yaml: unmarshal errors:\n  line 2: mapping key \"name\" already defined at line 1"),
    (
      "limits:\n  - name: l\n    value: abc\n  - name: m\n    value: 1.5\n",
      "yaml: unmarshal errors:\n  line 3: cannot unmarshal !!str `abc` into int"
    ),
    (
      "features:\n  - name: f\n    enabled: yes\n  - name: g\n    enabled: maybe\n",
      "yaml: unmarshal errors:\n  line 5: cannot unmarshal !!str `maybe` into bool"
    ),
    (
      "extensions:\n  - name: strings\n    version: 2\n  - name: math\n    version: [1]\n",
      "yaml: unmarshal errors:\n  line 5: cannot unmarshal !!seq into string"
    ),
    ("variables:\n  - name: x\n    type:\n      - int\n", "unsupported yaml for TypeDesc"),
    (
      "validators:\n  - name: v\n    config:\n      limit: 2\n      limit: 3\n",
      "yaml: unmarshal errors:\n  line 5: mapping key \"limit\" already defined at line 4"
    ),
    ("name: !!int abc\n", "yaml: cannot decode !!str `abc` as a !!int"),
    ("- a\n- b\n", "yaml: unmarshal errors:\n  line 1: cannot unmarshal !!seq into env.Config"),
    (
      "description: a very long string value\nname: {x: 1}\ncontainer: 12345678901234\n",
      "yaml: unmarshal errors:\n  line 2: cannot unmarshal !!map into string"
    ),
  ])
  func decodeErrors(yaml: String, wantError: String) {
    #expect(throws: YAMLError(message: wantError)) {
      try EnvironmentConfig(yaml: yaml)
    }
  }

  @Test func decodeLenientScalars() throws {
    let config = try EnvironmentConfig(
      yaml: """
        extensions:
          - name: strings
            version: 2
        features:
          - name: f
            enabled: yes
        limits:
          - name: m
            value: 1.5
        functions:
          - name: f
            overloads:
              - id: o
                args: [int, 'map<string,~V>']
                return: ~V
        """)
    #expect(config.extensions == [.init(name: "strings", version: "2")])
    #expect(config.features == [.init(name: "f", isEnabled: true)])
    #expect(config.limits == [.init(name: "m", value: 1)])
    #expect(
      config.functions[0].overloads[0]
        == .init(
          id: "o", arguments: [TD("int"), TD("map", parameters: [TD("string"), .typeParameter("V")])],
          resultType: .typeParameter("V")))
  }

  @Test func validateMessagesMatchCelGo() throws {
    let config = try EnvironmentConfig(
      yaml: "variables:\n  - name: x\n    type_name: list\n  - name: ''\n    type: int\n  - name: y\n")
    #expect(throws: EnvironmentConfigError(messages: [
      "invalid variable \"x\": invalid type: list expects 1 parameter, got 0",
      "invalid variable: missing variable name",
      "invalid variable \"y\": invalid type: nil",
    ])) {
      try config.validate()
    }
  }
}
