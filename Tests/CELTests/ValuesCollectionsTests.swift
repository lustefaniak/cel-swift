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
// Ported from cel-go common/types/list_test.go and map_test.go (the parts without Go/protobuf
// native conversions), plus host-adapter cases for the ListValue / MapValue protocols.

import Testing

@testable import CEL

/// A host list adapted lazily: elements are converted on access.
private struct LazyInts: ListValue {
  let storage: [Int32]
  var count: Int { storage.count }
  func element(at index: Int) -> Value { .int(Int64(storage[index])) }
}

/// A host map with string keys, adapted lazily.
private struct StringStringMap: MapValue {
  let storage: [String: String]
  var count: Int { storage.count }
  var keys: [MapKey] { storage.keys.sorted().map(MapKey.string) }
  func value(forKey key: MapKey) -> Value? {
    guard case .string(let s) = key, let v = storage[s] else { return nil }
    return .string(v)
  }
}

struct ListValueTests {
  @Test func addEmptyReturnsOperand() throws {
    let list = Value.list(ArrayList([true]))
    let empty = Value.list(ArrayList())
    #expect(list.add(empty) == list)
    #expect(empty.add(list) == list)
    #expect(empty.add(.string("error")).isError)
  }

  @Test func contains() {
    let list = Value.list(ArrayList([1.0, 2.0, 3.0]))
    let tests: [(Value, Bool)] = [
      (.double(.nan), false), (.double(5), false), (.double(3), true), (.uint(3), true),
      (.int(3), true), (.int(0), false), (.string("3"), false),
    ]
    for (input, out) in tests {
      #expect(list.contains(input) == .bool(out), "\(input)")
    }
  }

  @Test func convertToType() {
    let list: Value = [1, 2]
    #expect(list.convert(to: .listOfDyn) == list)
    #expect(list.convert(to: .type(nil)) == .type(.listOfDyn))
    #expect(list.convert(to: .mapOfDyn) == .error(EvalError("type conversion error from 'list(dyn)' to 'map(dyn, dyn)'")))
  }

  @Test func equal() {
    let listA: Value = ["h", "e", "l", "l", "o"]
    #expect(listA.celEquals(listA) == true)
    let listB: Value = ["h", "e", "l", "p", "!"]
    #expect(listA.celEquals(listB) == false)
    let listD: Value = ["h", "e", 1, "p", "!"]
    #expect(listA.celEquals(listD) == false)
    #expect(listB.celEquals(listD) == false)
    #expect(listA.celEquals(.null) == false)
  }

  @Test func get() {
    let list = Value.list(LazyInts(storage: [1, 2, 3]))
    #expect(list.get(.int(0)) == 1)
    #expect(list.get(.uint(1)) == 2)
    #expect(list.get(.double(2.0)) == 3)
    #expect(list.get(.int(-1)) == .error(EvalError("index '-1' out of range in list size '3'")))
    #expect(list.get(.int(3)) == .error(EvalError("index '3' out of range in list size '3'")))
    #expect(list.get(.double(1.5)) == .error(EvalError("unsupported index value 1.5 in list")))
    #expect(list.get(.uint(.max)) == .error(EvalError("unsupported index value 18446744073709551615 in list")))
    let unknown = Value.unknown(UnknownSet(exprID: 1))
    #expect(list.get(unknown) == unknown)
  }

  @Test func nestedListsCompareAcrossNumericTypes() {
    let nestedUint: Value = [.list(ArrayList([.uint(1), .uint(2)]))]
    let nestedInt: Value = [.list(LazyInts(storage: [1, 2]))]
    #expect(nestedUint.celEquals(nestedInt) == true)
    #expect(nestedUint.contains(.list(LazyInts(storage: [1, 2]))) == true)
    #expect(nestedUint.size() == 1)
  }

  @Test func concat() {
    let listA = Value.list(ArrayList([1.0, 2.0]))
    let listB: Value = ["3"]
    let list = listA.add(listB).add(listA)
    #expect(list == [1.0, 2.0, "3", 1.0, 2.0])
    #expect(listA.add(listB).contains("3") == true)
    #expect(listA.add(listB).contains(2.0) == true)
    #expect(listA.add(listB).contains("4") == false)
    let mixed = Value.list(ArrayList([1.0, 2.0])).add([3.0])
    #expect(mixed.celEquals([1, 2.0, 3.0]) == true)
    #expect(mixed.celEquals([1.0, 3.0, 2.0]) == false)
    #expect(mixed.celEquals(listA) == false)
    #expect(mixed.get(.int(0)) == 1.0)
    #expect(mixed.get(.uint(1)) == 2.0)
    #expect(mixed.get(.double(2)) == 3.0)
    #expect(mixed.get(.int(3)).isError)
  }

  @Test func zeroValue() {
    #expect(Value.list(ArrayList()).isZeroValue)
    #expect(Value.list(LazyInts(storage: [1])).isZeroValue == false)
    #expect(LazyInts(storage: [1, 2]).elements == [1, 2])
  }
}

struct MapValueTests {
  @Test func containsCrossNumeric() {
    let map: Value = [.int(1): "hello", .uint(2): "world"]
    let tests: [(Value, Bool)] = [
      (.int(1), true), (.double(1.0), true), (.uint(1), true), (.int(2), true),
      (.double(2.0), true), (.uint(2), true), (.int(3), false), (.double(1.1), false),
      (.double(1.1 + Double(Int64.max)), false), (.double(1.1 + Double(UInt64.max)), false),
      (.string("3"), false),
    ]
    for (input, out) in tests {
      #expect(map.contains(input) == .bool(out), "\(input)")
    }
  }

  @Test func equal() {
    let nested: Value = ["nested": [1: -1.0, 2: 2.0], "empty": .map(OrderedMap())]
    #expect(nested.celEquals(nested) == true)
    #expect(nested.celEquals(nested.get("nested")) == false)
    #expect(nested.get("nested").celEquals(nested) == false)
    let other: Value = ["nested": [1: -1.0, 2: 2.0, 3: 3.14], "empty": .map(OrderedMap())]
    #expect(nested.celEquals(other) == false)
    let absent: Value = ["nested": [1: -1.0, 2: 2.0, 3: 3.14], "absent": .map(OrderedMap())]
    #expect(nested.celEquals(absent) == false)
    #expect(nested.celEquals(.null) == false)
    // Values compare with heterogeneous numeric equality; key order does not matter.
    let uintKeys: Value = ["empty": .map(OrderedMap()), "nested": [.uint(2): 2, .uint(1): -1]]
    #expect(nested.celEquals(uintKeys) == true)
  }

  @Test func stringMapEqual() {
    let mapVal = Value.map(StringStringMap(storage: ["first": "hello", "second": "world"]))
    #expect(mapVal.celEquals(mapVal) == true)
    #expect(mapVal.celEquals(["second": "world", "first": "hello"]) == true)
    #expect(mapVal.celEquals(.map(StringStringMap(storage: ["second": "world", "first": "goodbye"]))) == false)
    #expect(mapVal.celEquals(.map(StringStringMap(storage: ["first": "hello"]))) == false)
    #expect(mapVal.celEquals(.map(StringStringMap(storage: ["first": "hello", "third": "goodbye"]))) == false)
    #expect(mapVal.celEquals(["first": "hello", "second": 1]) == false)
  }

  @Test func get() {
    let mapVal: Value = ["nested": [1: -1.0, 2: 2.0], "empty": .map(OrderedMap())]
    let nested = mapVal.get("nested")
    #expect(nested.get(.int(1)) == -1.0)
    #expect(mapVal.get("absent") == .error(EvalError("no such key: absent")))
    #expect(nested.get("bad_key") == .error(EvalError("no such key: bad_key")))
    let empty = mapVal.get("empty")
    #expect(empty.get("hello") == .error(EvalError("no such key: hello")))
    #expect(empty.get(.double(-1.0)) == .error(EvalError("no such key: -1")))
    let err = Value.error(EvalError("boom"))
    #expect(mapVal.get(err) == err)
  }

  @Test func sizeAndZero() {
    #expect(Value.map(OrderedMap()).isZeroValue)
    #expect(Value.map(StringStringMap(storage: ["a": "b"])).size() == 1)
    #expect(Value.map(StringStringMap(storage: [:])).isZeroValue)
  }

  @Test func insertionOrderAndKeys() {
    var map = OrderedMap()
    let first = map.insert(1, forKey: "b")
    let second = map.insert(2, forKey: "a")
    let duplicate = map.insert(3, forKey: "b")
    #expect(first && second)
    #expect(duplicate == false)
    #expect(map.keys == ["b", "a"])
    map["b"] = nil
    #expect(map.keys == ["a"])
    // Keys compare by Unicode scalars: precomposed and decomposed é are different keys.
    map[.string("\u{E9}")] = 1
    map[.string("e\u{301}")] = 2
    #expect(map.count == 3)
    #expect(Value.map(map).get(.string("\u{E9}")) == 1)
  }

  @Test func convertToType() {
    let map: Value = ["a": 1]
    #expect(map.convert(to: .mapOfDyn) == map)
    #expect(map.convert(to: .map(key: .string, value: .int)) == map)
    #expect(map.convert(to: .type(nil)) == .type(.mapOfDyn))
    #expect(map.convert(to: .listOfDyn).isError)
  }
}
