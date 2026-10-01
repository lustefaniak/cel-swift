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
// Ported from cel-go common/types/int_test.go and uint_test.go (non-native parts).

import Testing

@testable import CEL

struct IntValueTests {
  @Test func add() {
    #expect(Value.int(4).add(.int(-3)) == .int(1))
    #expect(Value.int(-1).add(.string("-1")).isError)
    #expect(Value.int(.max).add(.int(1)) == .error(EvalError("integer overflow")))
    #expect(Value.int(.min).add(.int(-1)).isError)
    #expect(Value.int(.max - 1).add(.int(1)) == .int(.max))
    #expect(Value.int(.min + 1).add(.int(-1)) == .int(.min))
  }

  @Test(arguments: [
    (Value.int(42), Value.int(42), Value.int(0)),
    (.int(42), .uint(42), .int(0)),
    (.int(42), .double(42), .int(0)),
    (.int(-1300), .int(204), .int(-1)),
    (.int(-1300), .uint(204), .int(-1)),
    (.int(204), .double(204.1), .int(-1)),
    (.int(1300), .uint(UInt64(Int64.max) + 1), .int(-1)),
    (.int(204), .uint(205), .int(-1)),
    (.int(204), .double(Double(Int64.max) + 1025.0), .int(-1)),
    (.int(204), .double(.nan), .error(EvalError("NaN values cannot be ordered"))),
    (.int(204), .int(-1300), .int(1)),
    (.int(204), .uint(10), .int(1)),
    (.int(204), .double(203.9), .int(1)),
    (.int(204), .double(Double(Int64.min) - 1025.0), .int(1)),
    (.int(1), .string("1"), .error(EvalError("no such overload"))),
  ])
  func compare(a: Value, b: Value, out: Value) {
    #expect(a.compare(b) == out)
  }

  @Test(arguments: [
    (Int64(4), CELType.type(nil), Value.type(.int)),
    (4, .int, .int(4)),
    (4, .uint, .uint(4)),
    (-1, .uint, .error(EvalError("unsigned integer overflow"))),
    (4, .double, .double(4)),
    (-4, .string, .string("-4")),
    (946_684_800, .timestamp, .timestamp(CELTimestamp(secondsSinceEpoch: 946_684_800))),
    (CELTimestamp.maxSecondsSinceEpoch + 1, .timestamp, .error(EvalError("timestamp overflow"))),
    (CELTimestamp.minSecondsSinceEpoch - 1, .timestamp, .error(EvalError("timestamp overflow"))),
    (
      4, .duration,
      .error(EvalError("type conversion error from 'int' to 'google.protobuf.Duration'"))
    ),
  ])
  func convertToType(input: Int64, type: CELType, out: Value) {
    #expect(Value.int(input).convert(to: type) == out)
  }

  @Test func divide() {
    #expect(Value.int(3).divide(.int(2)) == .int(1))
    #expect(Value.int(0).divide(.int(0)) == .error(EvalError("division by zero")))
    #expect(Value.int(1).divide(.double(-1)).isError)
    #expect(Value.int(.min).divide(.int(-1)) == .error(EvalError("integer overflow")))
  }

  @Test(arguments: [
    (Value.int(-10), Value.int(-10), true),
    (.int(-10), .int(10), false),
    (.int(10), .uint(10), true),
    (.int(9), .uint(10), false),
    (.int(10), .double(10), true),
    (.int(10), .double(-10.5), false),
    (.int(10), .double(.nan), false),
    (.int(1), .string("1"), false),
  ])
  func equal(a: Value, b: Value, out: Bool) {
    #expect(a.celEquals(b) == .bool(out))
  }

  @Test func isZeroValue() {
    #expect(Value.int(1).isZeroValue == false)
    #expect(Value.int(0).isZeroValue)
  }

  @Test func modulo() {
    #expect(Value.int(21).modulo(.int(2)) == .int(1))
    #expect(Value.int(21).modulo(.int(0)) == .error(EvalError("modulus by zero")))
    #expect(Value.int(21).modulo(.uint(0)).isError)
    #expect(Value.int(.min).modulo(.int(-1)) == .error(EvalError("integer overflow")))
  }

  @Test func multiply() {
    #expect(Value.int(2).multiply(.int(-2)) == .int(-4))
    #expect(Value.int(1).multiply(.double(-4)).isError)
    #expect(Value.int(.max / 2).multiply(.int(3)).isError)
    #expect(Value.int(.min / 2).multiply(.int(3)).isError)
    #expect(Value.int(.max / 2).multiply(.int(2)) == .int(.max - 1))
    #expect(Value.int(.min / 2).multiply(.int(2)) == .int(.min))
    #expect(Value.int(.max / 2).multiply(.int(-2)) == .int(.min + 2))
    #expect(Value.int((.min + 2) / 2).multiply(.int(-2)) == .int(.max - 1))
    #expect(Value.int(.min).multiply(.int(-1)).isError)
  }

  @Test func negate() {
    #expect(Value.int(1).negate() == .int(-1))
    #expect(Value.int(.min).negate().isError)
    #expect(Value.int(.max).negate() == .int(.min + 1))
  }

  @Test func subtract() {
    #expect(Value.int(4).subtract(.int(-3)) == .int(7))
    #expect(Value.int(1).subtract(.uint(1)).isError)
    #expect(Value.int(.max).subtract(.int(-1)).isError)
    #expect(Value.int(.min).subtract(.int(1)).isError)
    #expect(Value.int(.max - 1).subtract(.int(-1)) == .int(.max))
    #expect(Value.int(.min + 1).subtract(.int(1)) == .int(.min))
  }
}

struct UintValueTests {
  @Test func add() {
    #expect(Value.uint(4).add(.uint(3)) == .uint(7))
    #expect(Value.uint(1).add(.string("-1")).isError)
    #expect(Value.uint(.max).add(.uint(1)) == .error(EvalError("unsigned integer overflow")))
    #expect(Value.uint(.max - 1).add(.uint(1)) == .uint(.max))
  }

  @Test(arguments: [
    (Value.uint(42), Value.uint(42), Value.int(0)),
    (.uint(42), .int(42), .int(0)),
    (.uint(42), .double(42), .int(0)),
    (.uint(13), .int(204), .int(-1)),
    (.uint(13), .uint(204), .int(-1)),
    (.uint(204), .double(204.1), .int(-1)),
    (.uint(204), .int(205), .int(-1)),
    (.uint(204), .double(Double(UInt64.max) + 2049.0), .int(-1)),
    (.uint(204), .double(.nan), .error(EvalError("NaN values cannot be ordered"))),
    (.uint(1300), .int(-1), .int(1)),
    (.uint(204), .uint(13), .int(1)),
    (.uint(204), .double(203.9), .int(1)),
    (.uint(204), .double(-1.0), .int(1)),
    (.uint(1), .string("1"), .error(EvalError("no such overload"))),
  ])
  func compare(a: Value, b: Value, out: Value) {
    #expect(a.compare(b) == out)
  }

  @Test(arguments: [
    (UInt64(4), CELType.uint, Value.uint(4)),
    (4, .type(nil), .type(.uint)),
    (4, .int, .int(4)),
    (UInt64(Int64.max) + 1, .int, .error(EvalError("integer overflow"))),
    (4, .double, .double(4)),
    (4, .string, .string("4")),
    (4, .mapOfDyn, .error(EvalError("type conversion error from 'uint' to 'map(dyn, dyn)'"))),
  ])
  func convertToType(input: UInt64, type: CELType, out: Value) {
    #expect(Value.uint(input).convert(to: type) == out)
  }

  @Test func divide() {
    #expect(Value.uint(3).divide(.uint(2)) == .uint(1))
    #expect(Value.uint(0).divide(.uint(0)) == .error(EvalError("division by zero")))
    #expect(Value.uint(1).divide(.double(-1)).isError)
  }

  @Test(arguments: [
    (Value.uint(10), Value.uint(10), true),
    (.uint(10), .int(-10), false),
    (.uint(10), .int(10), true),
    (.uint(9), .int(10), false),
    (.uint(10), .double(10), true),
    (.uint(10), .double(-10.5), false),
    (.uint(10), .double(.nan), false),
  ])
  func equal(a: Value, b: Value, out: Bool) {
    #expect(a.celEquals(b) == .bool(out))
  }

  @Test func isZeroValue() {
    #expect(Value.uint(1).isZeroValue == false)
    #expect(Value.uint(0).isZeroValue)
  }

  @Test func modulo() {
    #expect(Value.uint(21).modulo(.uint(2)) == .uint(1))
    #expect(Value.uint(21).modulo(.uint(0)) == .error(EvalError("modulus by zero")))
    #expect(Value.uint(21).modulo(.int(1)).isError)
  }

  @Test func multiply() {
    #expect(Value.uint(2).multiply(.uint(2)) == .uint(4))
    #expect(Value.uint(1).multiply(.double(-4)).isError)
    #expect(Value.uint(.max / 2).multiply(.uint(3)).isError)
    #expect(Value.uint(.max / 2).multiply(.uint(2)) == .uint(.max - 1))
  }

  @Test func subtract() {
    #expect(Value.uint(4).subtract(.uint(3)) == .uint(1))
    #expect(Value.uint(1).subtract(.int(1)).isError)
    #expect(Value.uint(.max - 1).subtract(.uint(.max)).isError)
    #expect(Value.uint(.max).subtract(.uint(.max)) == .uint(0))
  }
}
