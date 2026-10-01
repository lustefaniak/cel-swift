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
// Ported from cel-go common/types/list.go and common/types/traits/lister.go.

/// A CEL list.
///
/// Implement this protocol to expose host collections to CEL without copying them; elements are
/// converted to ``Value`` on access. ``ArrayList`` is the implementation backed by `[Value]`.
public protocol ListValue: Sendable {
  /// The number of elements.
  var count: Int { get }

  /// Returns the element at `index`.
  ///
  /// - Precondition: `0 <= index < count`.
  func element(at index: Int) -> Value
}

extension ListValue {
  /// The elements in order.
  ///
  /// - Complexity: O(n), converting every element.
  public var elements: [Value] {
    if let array = self as? ArrayList {
      return array.values
    }
    return (0..<count).map { element(at: $0) }
  }
}

/// A list backed by an array of values, used for list literals and function results.
public struct ArrayList: ListValue {
  /// The elements.
  public var values: [Value]

  /// Creates a list with the given elements.
  public init(_ values: [Value] = []) {
    self.values = values
  }

  /// The number of elements.
  public var count: Int { values.count }

  /// Returns the element at `index`.
  public func element(at index: Int) -> Value {
    values[index]
  }
}

// MARK: - CEL list operations (cel-go baseList)

extension Value {
  /// Converts an index value to a lossless integer index. Port of cel-go `types.IndexOrError`.
  package static func indexOrError(_ index: Value) -> Result<Int, EvalError> {
    switch index {
    case .int(let i):
      return .success(Int(truncatingIfNeeded: i))
    case .double(let d):
      if let i = doubleToInt64Lossless(d) {
        return .success(Int(truncatingIfNeeded: i))
      }
      return .failure(EvalError("unsupported index value \(formatGoValue(index)) in list"))
    case .uint(let u):
      if let i = uint64ToInt64Lossless(u) {
        return .success(Int(truncatingIfNeeded: i))
      }
      return .failure(EvalError("unsupported index value \(formatGoValue(index)) in list"))
    default:
      return .failure(EvalError("unsupported index type '\(index.celType)' in list"))
    }
  }
}

extension ListValue {
  /// Returns the element for a CEL index value (`int`, or a lossless `uint` / `double`), or an
  /// error. Port of cel-go `baseList.Get`.
  package func get(_ index: Value) -> Value {
    let ind: Int
    switch Value.indexOrError(index) {
    case .success(let i): ind = i
    case .failure(let err): return Value.valOrError(index, err.message)
    }
    if ind < 0 || ind >= count {
      return .error(message: "index '\(ind)' out of range in list size '\(count)'")
    }
    return element(at: ind)
  }

  /// Whether the list contains a value equal to `elem` under CEL equality.
  /// Port of cel-go `baseList.Contains`.
  package func containsValue(_ elem: Value) -> Value {
    for i in 0..<count {
      if case .bool(true) = elem.celEquals(element(at: i)) {
        return .bool(true)
      }
    }
    return .bool(false)
  }

  /// CEL equality with another list. Port of cel-go `baseList.Equal`.
  package func celEquals(_ other: any ListValue) -> Value {
    if count != other.count {
      return .bool(false)
    }
    for i in 0..<count {
      if case .bool(false) = element(at: i).celEquals(other.element(at: i)) {
        return .bool(false)
      }
    }
    return .bool(true)
  }
}

/// Concatenates two lists. Port of cel-go `newConcatList`, materialized into an ``ArrayList``.
package func concatLists(_ lhs: any ListValue, _ rhs: any ListValue) -> any ListValue {
  if lhs.count == 0 { return rhs }
  if rhs.count == 0 { return lhs }
  var values = lhs.elements
  values.reserveCapacity(lhs.count + rhs.count)
  if let array = rhs as? ArrayList {
    values.append(contentsOf: array.values)
  } else {
    for i in 0..<rhs.count {
      values.append(rhs.element(at: i))
    }
  }
  return ArrayList(values)
}
