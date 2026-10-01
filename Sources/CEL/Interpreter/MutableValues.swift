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
// Ported from cel-go common/types/list.go (mutableList) and common/types/map.go (mutableMap).
//
// A comprehension whose accumulator starts as an empty list or map accumulates into one of these,
// so `map` / `filter` append in place instead of copying the accumulator on every step. They are
// reference types and therefore `@unchecked Sendable`: an instance is created by one comprehension
// evaluation, only reachable through that comprehension's accumulator variable, and converted to an
// immutable `ArrayList` / `OrderedMap` before the comprehension's result is returned, so it is never
// shared between threads.

/// A list appended to in place by a comprehension accumulator (cel-go `mutableList`).
package final class MutableList: ListValue, @unchecked Sendable {
  package private(set) var values: [Value] = []

  package init() {}

  package var count: Int { values.count }

  package func element(at index: Int) -> Value {
    values[index]
  }

  /// Appends the elements of another list (cel-go `mutableList.Add`).
  package func append(contentsOf other: any ListValue) {
    if let array = other as? ArrayList {
      values.append(contentsOf: array.values)
    } else if let mutable = other as? MutableList {
      values.append(contentsOf: mutable.values)
    } else {
      values.reserveCapacity(values.count + other.count)
      for i in 0..<other.count {
        values.append(other.element(at: i))
      }
    }
  }

  /// The accumulated elements as an immutable list.
  package func toImmutableList() -> ArrayList {
    ArrayList(values)
  }
}

/// A map inserted into in place by a comprehension accumulator (cel-go `mutableMap`).
package final class MutableMap: MapValue, @unchecked Sendable {
  package private(set) var map = OrderedMap()

  package init() {}

  package var count: Int { map.count }

  package var keys: [MapKey] { map.keys }

  package func value(forKey key: MapKey) -> Value? {
    map.value(forKey: key)
  }

  /// Inserts an entry, or returns an error if the key exists (cel-go `mutableMap.Insert`).
  package func insert(_ key: Value, _ value: Value) -> Value {
    if find(key) != nil {
      return .error(message: "insert failed: key \(formatGoValue(key)) already exists")
    }
    guard let mapKey = MapKey(key) else {
      return .error(message: "unsupported key type")
    }
    map[mapKey] = value
    return .map(self)
  }

  /// The accumulated entries as an immutable map.
  package func toImmutableMap() -> OrderedMap {
    map
  }
}
