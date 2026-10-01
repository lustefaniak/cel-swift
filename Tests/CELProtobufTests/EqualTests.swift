// Copyright 2022 Google LLC
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
// Ported from cel-go common/types/pb/equal_test.go.

import CEL
import CELGoTestProtos
import CELProtobuf
import Foundation
import SwiftProtobuf
import Testing

struct EqualTests {
  struct Case: Sendable, CustomTestStringConvertible {
    var name: String
    var a: any SwiftProtobuf.Message
    var b: any SwiftProtobuf.Message
    var equal: Bool
    var testDescription: String { name }
  }

  static func cases() throws -> [Case] {
    let scalars = Proto3.with {
      $0.singleBool = true
      $0.singleBytes = Data("world".utf8)
      $0.singleDouble = 3.0
      $0.singleFloat = 1.5
      $0.singleInt32 = 1
      $0.singleUint64 = 1
      $0.singleString = "hello"
    }
    let nestedMap: (Bool) -> Proto3 = { withSecond in
      Proto3.with {
        $0.mapInt64NestedType[1] = Proto3Nested.with {
          $0.child = Proto3Nested.with { $0.payload = Proto3.with { $0.standaloneEnum = .bar } }
        }
        if withSecond {
          $0.mapInt64NestedType[2] = Proto3Nested.with { $0.payload = Proto3() }
        }
      }
    }
    let payload = Proto3.with {
      $0.singleInt32 = 1
      $0.singleUint32 = 2
      $0.singleString = "three"
      $0.repeatedInt32 = [1, 2, 3]
    }
    let payloadNoString = Proto3.with {
      $0.singleInt32 = 1
      $0.singleUint32 = 2
      $0.repeatedInt32 = [1, 2, 3]
    }
    var payload4 = payload
    payload4.repeatedInt32.append(4)
    func any(_ m: any SwiftProtobuf.Message) throws -> Proto3 {
      let packed = try serializedAny(m)
      return Proto3.with { $0.singleAny = packed }
    }
    func doubleAny(_ m: any SwiftProtobuf.Message) throws -> Proto3 {
      let packed = try serializedAny(try serializedAny(m))
      return Proto3.with { $0.singleAny = packed }
    }
    func badAny(_ m: any SwiftProtobuf.Message) throws -> Proto3 {
      let packed = try serializedAny(m, typeURL: "type.googleapis.com/BadType")
      return Proto3.with { $0.singleAny = packed }
    }
    func misAny(_ m: any SwiftProtobuf.Message) throws -> Proto3 {
      let packed = try serializedAny(
        m, typeURL: "type.googleapis.com/google.expr.proto3.test.TestAllTypes")
      return Proto3.with { $0.singleAny = packed }
    }
    func misPayload(_ inner: Proto3) -> Proto3Nested {
      Proto3Nested.with { $0.child = Proto3Nested.with { $0.payload = inner } }
    }
    return [
      Case(name: "EqualEmptyInstances", a: Proto3(), b: Proto3(), equal: true),
      Case(name: "NotEqualEmptyInstances", a: Proto3(), b: Proto3Nested(), equal: false),
      Case(name: "EqualScalarFields", a: scalars, b: scalars, equal: true),
      Case(
        name: "NotEqualFloatNan", a: Proto3.with { $0.singleFloat = .nan },
        b: Proto3.with { $0.singleFloat = .nan }, equal: false),
      Case(
        name: "NotEqualDifferentFieldsSet", a: Proto3.with { $0.singleInt32 = 1 }, b: Proto3(),
        equal: false),
      Case(
        name: "NotEqualDifferentFieldsSetReverse", a: Proto3(),
        b: Proto3.with { $0.singleInt32 = 1 }, equal: false),
      Case(
        name: "EqualListField", a: Proto3.with { $0.repeatedInt32 = [1, 2, 3, 4] },
        b: Proto3.with { $0.repeatedInt32 = [1, 2, 3, 4] }, equal: true),
      Case(
        name: "NotEqualListFieldDifferentLength", a: Proto3.with { $0.repeatedInt32 = [1, 2, 3] },
        b: Proto3.with { $0.repeatedInt32 = [1, 2, 3, 4] }, equal: false),
      Case(
        name: "NotEqualListFieldDifferentContent", a: Proto3.with { $0.repeatedInt32 = [2, 1] },
        b: Proto3.with { $0.repeatedInt32 = [1, 2] }, equal: false),
      Case(name: "EqualMapField", a: nestedMap(true), b: nestedMap(true), equal: true),
      Case(name: "NotEqualMapFieldDifferentLength", a: nestedMap(true), b: nestedMap(false), equal: false),
      Case(name: "EqualAnyBytes", a: try any(payload), b: try any(payload), equal: true),
      Case(
        name: "NotEqualDoublePackedAny", a: try doubleAny(payload), b: try doubleAny(payload4),
        equal: false),
      Case(
        name: "NotEqualAnyTypeURL", a: try any(Proto3Nested()), b: try any(Proto3()), equal: false),
      Case(name: "NotEqualAnyFields", a: try any(payloadNoString), b: try any(payload), equal: false),
      Case(
        name: "NotEqualAnyDeserializeA", a: try badAny(payloadNoString), b: try badAny(payload),
        equal: false),
      Case(
        name: "EqualUnknownFields", a: try misAny(misPayload(Proto3.with { $0.singleInt32 = 1 })),
        b: try misAny(misPayload(Proto3.with { $0.singleInt32 = 1 })), equal: true),
      Case(
        name: "NotEqualUnknownFieldsCount",
        a: try misAny(
          misPayload(Proto3.with {
            $0.singleInt32 = 1
            $0.singleFloat = 2.0
          })),
        b: try misAny(misPayload(Proto3.with { $0.singleInt32 = 1 })), equal: false),
      Case(
        name: "NotEqualUnknownFields", a: try misAny(misPayload(Proto3.with { $0.singleInt64 = 2 })),
        b: try misAny(misPayload(Proto3.with { $0.singleInt32 = 1 })), equal: false),
    ]
  }

  @Test(arguments: try cases())
  func equal(_ test: Case) throws {
    let types = testTypes()
    let a = try #require(types.value(of: test.a).protobufObject)
    let b = try #require(types.value(of: test.b).protobufObject)
    #expect(a.isEqual(to: b) == test.equal)
    #expect(b.isEqual(to: a) == test.equal)
  }

  @Test func anyInMemoryAndSerializedAreEqual() throws {
    let types = testTypes()
    let payload = Proto3.with { $0.singleString = "x" }
    let inMemory = Proto3.with { $0.singleAny = try! packAny(payload) }
    let serialized = Proto3.with { $0.singleAny = try! serializedAny(payload) }
    let a = try #require(types.value(of: inMemory).protobufObject)
    let b = try #require(types.value(of: serialized).protobufObject)
    #expect(a.isEqual(to: b))
  }

  @Test func negativeZeroIsSetInProto3() throws {
    // Go's protoreflect treats -0.0 as present, so it differs from an unset field.
    let types = testTypes()
    let a = try #require(types.value(of: Proto3.with { $0.singleDouble = -0.0 }).protobufObject)
    let b = try #require(types.value(of: Proto3()).protobufObject)
    #expect(!a.isEqual(to: b))
    #expect(a.isFieldSet("single_double") == .bool(true))
  }
}
