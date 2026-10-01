// Copyright 2023 Google LLC
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
// Ported from cel-go common/decls/decls_test.go (excluding protobuf conversions, documentation
// rendering and async bindings).

import Testing

@testable import CEL

private func expectDeclarationError(
  containing text: String, sourceLocation: SourceLocation = #_sourceLocation,
  _ body: () throws -> Void
) {
  do {
    try body()
    Issue.record("expected an error containing '\(text)'", sourceLocation: sourceLocation)
  } catch let error as DeclarationError {
    #expect(error.message.contains(text), "\(error.message)", sourceLocation: sourceLocation)
  } catch {
    Issue.record("unexpected error \(error)", sourceLocation: sourceLocation)
  }
}

private let sizeOfSizer: FunctionBinding.Unary = { $0.size() }

struct DeclsTests {
  @Test func functionBindings() throws {
    let sizeFunc = try FunctionDecl(
      "size",
      .memberOverload("list_size", argTypes: [.list(.typeParam("T"))], resultType: .int))
    #expect(try sizeFunc.bindings().isEmpty)

    let sizeFuncDef = try FunctionDecl(
      "size",
      .memberOverload(
        "list_size", argTypes: [.list(.typeParam("T"))], resultType: .int,
        .unaryBinding(sizeOfSizer)))
    let sizeMerged = try sizeFunc.merging(sizeFuncDef)
    let bindings = try sizeMerged.bindings()
    #expect(bindings.count == 2)
    let empty: Value = []
    let input: Value = ["1", "2"]
    for binding in bindings {
      let unary = try #require(binding.unary, "binding missing unary implementation: \(binding.name)")
      #expect(unary(input) == .int(2))
      #expect(unary(empty) == .int(0))
    }
  }

  @Test func functionVariableArgBindings() throws {
    @Sendable func split(_ s: String, _ sep: String) -> Value {
      if sep.isEmpty {
        return .list(ArrayList(s.unicodeScalars.map { .string(String($0)) }))
      }
      return .list(ArrayList(s.split(separator: Character(sep)).map { .string(String($0)) }))
    }
    let splitFunc = try FunctionDecl(
      "split",
      .memberOverload(
        "string_split", argTypes: [.string], resultType: .list(.string),
        .unaryBinding { str in
          guard case .string(let s) = str else { return .noSuchOverload }
          return split(s, "")
        }),
      .memberOverload(
        "string_split_string", argTypes: [.string, .string], resultType: .list(.string),
        .binaryBinding { str, sep in
          guard case .string(let s) = str, case .string(let d) = sep else { return .noSuchOverload }
          return split(s, d)
        }),
      .memberOverload(
        "string_split_string_int", argTypes: [.string, .string, .int], resultType: .list(.string),
        .functionBinding { args in
          guard case .string(let s) = args[0], case .string(let d) = args[1] else {
            return .noSuchOverload
          }
          return split(s, d)
        }))
    let bindings = try splitFunc.bindings()
    #expect(bindings.count == 4)
    let input = Value.string("hi")
    let sep = Value.string("")
    let out: Value = ["h", "i"]
    for binding in bindings {
      if let unary = binding.unary {
        #expect(unary(input).celEquals(out) == .bool(true))
        let celErr = unary(.bytes(Array("hi".utf8)))
        #expect(celErr.isError && "\(celErr)".contains("no such overload"))
      }
      if let binary = binding.binary {
        #expect(binary(input, sep).celEquals(out) == .bool(true))
        let celErr = binary(.bytes(Array("hi".utf8)), sep)
        #expect(celErr.isError && "\(celErr)".contains("no such overload"))
        let celUnk = binary(
          .bytes(Array("hi".utf8)),
          .unknown(UnknownSet(exprID: 1, attribute: AttributeTrail(variable: "x"))))
        #expect(celUnk.isUnknown)
      }
      if let function = binding.function {
        #expect(function([input, sep, .int(-1)]).celEquals(out) == .bool(true))
        let celErr = function([.bytes(Array("hi".utf8)), sep, .int(1)])
        #expect(celErr.isError && "\(celErr)".contains("no such overload"))
        if binding.name == "split" {
          #expect(function([input]).celEquals(out) == .bool(true))
          #expect(function([input, sep]).celEquals(out) == .bool(true))
          #expect(function([]) == .error(EvalError("no such overload: split()")))
        }
      }
    }
  }

  @Test func functionZeroArityBinding() throws {
    let now = Value.timestamp(CELTimestamp(secondsSinceEpoch: 1))
    let nowFunc = try FunctionDecl(
      "now",
      .overload("now", argTypes: [], resultType: .timestamp, .functionBinding { _ in now }))
    for od in nowFunc.overloads {
      #expect(od.hasBinding)
    }
    let bindings = try nowFunc.bindings()
    #expect(bindings.count == 1)
    #expect(bindings[0].function?([]) == now)
  }

  @Test func functionSingletonBinding() throws {
    let size = try FunctionDecl(
      "size",
      .disableTypeGuards(true),
      .overload(
        "size_map", argTypes: [.map(key: .typeParam("K"), value: .typeParam("V"))],
        resultType: .int),
      .overload("size_list", argTypes: [.list(.typeParam("V"))], resultType: .int),
      .overload("size_string", argTypes: [.string], resultType: .int),
      .memberOverload(
        "map_size", argTypes: [.map(key: .typeParam("K"), value: .typeParam("V"))],
        resultType: .int),
      .memberOverload("list_size", argTypes: [.list(.typeParam("V"))], resultType: .int),
      .memberOverload("string_size", argTypes: [.string], resultType: .int),
      .singletonUnaryBinding(sizeOfSizer, traits: .sizer))
    #expect(size.hasSingletonBinding)
    let bindings = try size.bindings()
    #expect(bindings.count == 1)
    let unary = try #require(bindings[0].unary)
    #expect(unary(.string("hello")) == .int(5))
    // Invalid at type-check, but valid since type guard checks have been disabled.
    #expect(unary(.bytes(Array("hello".utf8))) == .int(5))
  }

  @Test func functionMerge() throws {
    let sizeFunc = try FunctionDecl(
      "size",
      .documentation("compute the number of entries in a list or map"),
      .memberOverload("list_size", argTypes: [.list(.typeParam("T"))], resultType: .int),
      .memberOverload(
        "map_size", argTypes: [.map(key: .typeParam("K"), value: .typeParam("V"))],
        resultType: .int))
    let same = try sizeFunc.merging(sizeFunc)
    #expect(same.overloads.map(\.id) == sizeFunc.overloads.map(\.id))
    let sizeVecFunc = try FunctionDecl(
      "size",
      .memberOverload(
        "vector_size", argTypes: [.opaque(name: "vector", parameters: [.typeParam("T")])],
        resultType: .int),
      .singletonUnaryBinding(sizeOfSizer, traits: .sizer))
    let sizeMerged = try sizeFunc.merging(sizeVecFunc)
    #expect(sizeMerged.name == "size")
    #expect(sizeMerged.overloads.count == 3)
    #expect(sizeMerged.documentation == "compute the number of entries in a list or map")
    #expect(Set(sizeMerged.overloads.map(\.id)) == ["list_size", "map_size", "vector_size"])
  }

  @Test func functionMergeWrongName() throws {
    let sizeFunc = try FunctionDecl(
      "size", .memberOverload("list_size", argTypes: [.list(.typeParam("T"))], resultType: .int))
    let sizeVecFunc = try FunctionDecl(
      "sizeN",
      .memberOverload(
        "vector_size", argTypes: [.opaque(name: "vector", parameters: [.typeParam("T")])],
        resultType: .int))
    expectDeclarationError(containing: "unrelated functions") {
      _ = try sizeFunc.merging(sizeVecFunc)
    }
  }

  @Test func functionMergeOverloadCollision() throws {
    let sizeFunc = try FunctionDecl(
      "size", .memberOverload("list_size", argTypes: [.list(.typeParam("T"))], resultType: .int))
    let sizeVecFunc = try FunctionDecl(
      "size", .memberOverload("list_size2", argTypes: [.list(.typeParam("K"))], resultType: .int))
    expectDeclarationError(containing: "declaration merge failed") {
      _ = try sizeFunc.merging(sizeVecFunc)
    }
  }

  @Test func functionMergeOverloadArgCountRedefinition() throws {
    let sizeFunc = try FunctionDecl(
      "size", .memberOverload("list_size", argTypes: [.list(.typeParam("T"))], resultType: .int))
    let sizeVecFunc = try FunctionDecl(
      "size",
      .memberOverload("list_size", argTypes: [.list(.typeParam("T")), .int], resultType: .int))
    expectDeclarationError(containing: "redefinition") {
      _ = try sizeFunc.merging(sizeVecFunc)
    }
  }

  @Test func functionMergeOverloadArgTypeRedefinition() throws {
    let sizeFunc = try FunctionDecl(
      "size", .memberOverload("arg_size", argTypes: [.list(.typeParam("T"))], resultType: .int))
    let sizeVecFunc = try FunctionDecl(
      "size",
      .memberOverload("arg_size", argTypes: [.map(key: .int, value: .string)], resultType: .int))
    expectDeclarationError(containing: "redefinition") {
      _ = try sizeFunc.merging(sizeVecFunc)
    }
  }

  @Test func functionMergeSingletonRedefinition() throws {
    let sizeFunc = try FunctionDecl(
      "size", .memberOverload("list_size", argTypes: [.list(.typeParam("T"))], resultType: .int),
      .singletonUnaryBinding { _ in .int(0) })
    let sizeVecFunc = try FunctionDecl(
      "size", .memberOverload("string_size", argTypes: [.string], resultType: .int),
      .singletonUnaryBinding { _ in .int(0) })
    expectDeclarationError(containing: "already has a singleton") {
      _ = try sizeFunc.merging(sizeVecFunc)
    }
  }

  @Test func functionAddDuplicateOverloads() throws {
    _ = try FunctionDecl(
      "max",
      .overload("max_int", argTypes: [.int], resultType: .int),
      .overload("max_int", argTypes: [.int], resultType: .int))
  }

  @Test func functionAddDuplicateOverloadsPreservesBinding() throws {
    let f = try FunctionDecl(
      "max",
      .overload("max_int", argTypes: [.int], resultType: .int),
      .overload("max_int", argTypes: [.int], resultType: .int, .unaryBinding { $0 }),
      .overload("max_int", argTypes: [.int], resultType: .int))
    #expect(f.overloads.count == 1)
    #expect(f.overload(withID: "max_int")?.unaryOp != nil)
  }

  @Test func functionAddCollidingOverloads() {
    expectDeclarationError(containing: "max_int collides with max_int2") {
      _ = try FunctionDecl(
        "max",
        .overload("max_int", argTypes: [.int], resultType: .int),
        .overload("max_int2", argTypes: [.int], resultType: .int))
    }
  }

  @Test func functionNoOverloads() {
    expectDeclarationError(containing: "must have at least one overload") {
      _ = try FunctionDecl("right", .singletonBinaryBinding { _, rhs in rhs })
    }
  }

  @Test func singletonOverloadCollision() throws {
    let fn = try FunctionDecl(
      "id",
      .overload("id_any", argTypes: [.any], resultType: .any, .unaryBinding { $0 }),
      .singletonUnaryBinding { $0 })
    expectDeclarationError(containing: "incompatible with specialized overloads") {
      _ = try fn.bindings()
    }
  }

  @Test func singletonOverloadLateBindingCollision() throws {
    let fn = try FunctionDecl(
      "id",
      .overload("id_any", argTypes: [.any], resultType: .any, .lateBinding),
      .singletonUnaryBinding { $0 })
    expectDeclarationError(containing: "incompatible with late bindings") {
      _ = try fn.bindings()
    }
  }

  @Test func singletonBindingRedefinition() {
    expectDeclarationError(containing: "already has a singleton binding") {
      _ = try FunctionDecl(
        "id", .overload("id_any", argTypes: [.any], resultType: .any),
        .singletonUnaryBinding { $0 }, .singletonUnaryBinding { $0 })
    }
    expectDeclarationError(containing: "already has a singleton binding") {
      _ = try FunctionDecl(
        "right",
        .overload("right_double_double", argTypes: [.double, .double], resultType: .double),
        .singletonBinaryBinding({ _, rhs in rhs }, traits: .comparer),
        .singletonBinaryBinding { _, rhs in rhs })
    }
    expectDeclarationError(containing: "already has a singleton binding") {
      _ = try FunctionDecl(
        "id", .overload("id_any", argTypes: [.any], resultType: .any),
        .singletonFunctionBinding({ $0[0] }, traits: .comparer),
        .singletonFunctionBinding({ $0[0] }, traits: .comparer))
    }
  }

  @Test func overloadBindingRedefinitionAndArity() {
    expectDeclarationError(containing: "already has a binding") {
      _ = try FunctionDecl(
        "id",
        .overload("id_any", argTypes: [.any], resultType: .any, .unaryBinding { $0 }, .unaryBinding { $0 }))
    }
    expectDeclarationError(containing: "non-unary overload") {
      _ = try FunctionDecl("id", .overload("id_any", argTypes: [], resultType: .any, .unaryBinding { $0 }))
    }
    expectDeclarationError(containing: "non-binary overload") {
      _ = try FunctionDecl(
        "id", .overload("id_any", argTypes: [], resultType: .any, .binaryBinding { lhs, _ in lhs }))
    }
    expectDeclarationError(containing: "already has a binding") {
      _ = try FunctionDecl(
        "right",
        .overload(
          "right_double_double", argTypes: [.double, .double], resultType: .double,
          .binaryBinding { _, rhs in rhs }, .binaryBinding { _, rhs in rhs }))
    }
    expectDeclarationError(containing: "already has a binding") {
      _ = try FunctionDecl(
        "id",
        .overload(
          "id_any", argTypes: [.any], resultType: .any, .functionBinding { $0[0] },
          .functionBinding { $0[0] }))
    }
  }

  @Test func overloadLateBinding() throws {
    let function = try FunctionDecl(
      "id", .overload("id_bool", argTypes: [.bool], resultType: .any, .lateBinding, .lateBinding))
    #expect(function.overloads.count == 1)
    #expect(function.overloads[0].hasLateBinding)
    #expect(function.hasLateBinding)

    expectDeclarationError(containing: "cannot mix late and non-late bindings") {
      _ = try FunctionDecl(
        "id",
        .overload("id_bool", argTypes: [.bool], resultType: .any, .lateBinding),
        .overload("id_int", argTypes: [.int], resultType: .any))
    }
    expectDeclarationError(containing: "already has a binding") {
      _ = try FunctionDecl(
        "id",
        .overload("id_bool", argTypes: [.bool], resultType: .any, .functionBinding { $0[0] }, .lateBinding))
    }
    expectDeclarationError(containing: "already has a late binding") {
      _ = try FunctionDecl(
        "id",
        .overload("id_bool", argTypes: [.bool], resultType: .any, .lateBinding, .functionBinding { $0[0] }))
    }
    expectDeclarationError(containing: "already has a late binding") {
      _ = try FunctionDecl(
        "id", .overload("id_bool", argTypes: [.bool], resultType: .any, .lateBinding, .unaryBinding { $0 }))
    }
    expectDeclarationError(containing: "already has a late binding") {
      _ = try FunctionDecl(
        "id",
        .overload(
          "id_bool", argTypes: [.bool, .bool], resultType: .any, .lateBinding,
          .binaryBinding { lhs, _ in lhs }))
    }
  }

  private static func getOrDefault(_ args: [Value]) -> Value {
    let container = args[0]
    let key = args[1]
    let orValue = args[2]
    if key.isUnknownOrError {
      return orValue
    }
    if container.contains(key) == .bool(true) {
      return container.get(key)
    }
    return orValue
  }

  @Test func overloadIsNonStrict() throws {
    let fn = try FunctionDecl(
      "getOrDefault",
      .memberOverload(
        "get",
        argTypes: [.map(key: .typeParam("K"), value: .typeParam("V")), .typeParam("K"), .typeParam("V")],
        resultType: .typeParam("V"),
        .operandTraits([.container, .indexer]), .nonStrict,
        .functionBinding(DeclsTests.getOrDefault)))
    let bindings = try fn.bindings()
    let function = try #require(bindings[0].function)
    let m: Value = ["hello": "world"]
    #expect(function([m, "hello", "goodbye"]) == "world")
    #expect(function([m, "missing", "goodbye"]) == "goodbye")
    #expect(function([m, .error(EvalError("no such key")), "goodbye"]) == "goodbye")
  }

  @Test func overloadOperandTrait() throws {
    let fn = try FunctionDecl(
      "getOrDefault",
      .memberOverload(
        "get",
        argTypes: [.map(key: .typeParam("K"), value: .typeParam("V")), .typeParam("K"), .typeParam("V")],
        resultType: .typeParam("V"),
        .operandTraits([.container, .indexer]),
        .functionBinding { args in
          if args[0].contains(args[1]) == .bool(true) {
            return args[0].get(args[1])
          }
          return args[2]
        }))
    let bindings = try fn.bindings()
    let function = try #require(bindings[0].function)
    let m: Value = ["hello": "world"]
    #expect(function([m, "hello", "goodbye"]) == "world")
    #expect(function([m, "missing", "goodbye"]) == "goodbye")
    let noSuchKey = Value.error(EvalError("no such key"))
    #expect(function([m, noSuchKey, "goodbye"]) == noSuchKey)
  }

  @Test func functionGetTypeParams() throws {
    let fn = try FunctionDecl(
      "deep_type_params",
      .overload("no_type_params", argTypes: [], resultType: .dyn),
      .overload("one_type_param", argTypes: [.bool], resultType: .typeParam("K")),
      .overload(
        "deep_type_params",
        argTypes: [.typeParam("E1"), .map(key: .typeParam("K"), value: .typeParam("V"))],
        resultType: .typeParam("V")))
    #expect(fn.overloads.count == 3)
    #expect(fn.overloads[0].typeParams.isEmpty)
    #expect(fn.overloads[1].typeParams == ["K"])
    #expect(Set(fn.overloads[2].typeParams) == ["E1", "K", "V"])
  }

  @Test func functionDisableAndEnableDeclaration() throws {
    let disabled = try FunctionDecl(
      "in", .disableDeclaration(true),
      .overload("in_list", argTypes: [.list(.typeParam("K")), .typeParam("K")], resultType: .bool))
    #expect(disabled.isDeclarationDisabled)
    let enabled = try FunctionDecl(
      "in", .disableDeclaration(false),
      .overload("in_list", argTypes: [.list(.typeParam("K")), .typeParam("K")], resultType: .bool))
    #expect(enabled.isDeclarationDisabled == false)
    #expect(try enabled.merging(disabled).isDeclarationDisabled)
    #expect(try disabled.merging(enabled).isDeclarationDisabled == false)
  }

  @Test func subset() throws {
    let fn = try FunctionDecl(
      "size",
      .overload("size_string", argTypes: [.string], resultType: .int),
      .overload("size_bytes", argTypes: [.bytes], resultType: .int))
    #expect(fn.including(overloadIDs: ["size_bytes"])?.overloads.map(\.id) == ["size_bytes"])
    #expect(fn.excluding(overloadIDs: ["size_bytes"])?.overloads.map(\.id) == ["size_string"])
    #expect(fn.including(overloadIDs: ["nope"]) == nil)
  }

  @Test func newVariable() {
    let a = VariableDecl(name: "a", type: .bool)
    #expect(a.name == "a")
    #expect(a.type == .bool)
    #expect(a.value == nil)
    #expect(a.isEquivalent(to: VariableDecl(name: "a", type: .bool)))
    #expect(a.isEquivalent(to: VariableDecl(name: "a", type: .int)) == false)
  }

  @Test func newConstant() {
    let a = VariableDecl(constant: "a", type: .int, value: .int(42))
    #expect(a.name == "a")
    #expect(a.type == .int)
    #expect(a.value == .int(42))
  }

  @Test func typeVariable() {
    let tests: [(CELType, String)] = [
      (.dyn, "dyn"),
      (.objectType("google.protobuf.Int32Value"), "int"),
      (.objectType("google.protobuf.Int64Value"), "int"),
      (.objectType("google.protobuf.Struct"), "map"),
    ]
    for (type, name) in tests {
      let v = VariableDecl.typeIdentifier(type)
      #expect(v.name == name)
      #expect(v.type == .type(type))
    }
  }
}
