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
// Ported from cel-go common/types/{bool,bytes,double,duration,int,list,map,null,optional,string,
// timestamp,uint}.go (the Adder, Subtractor, Multiplier, Divider, Modder, Negater, Comparer,
// Sizer, Container and Indexer trait methods), common/types/compare.go and common/types/util.go.

private func lift<T>(_ result: Result<T, EvalError>, _ wrap: (T) -> Value) -> Value {
  switch result {
  case .success(let v): return wrap(v)
  case .failure(let e): return .error(e)
  }
}

extension Value {
  // MARK: Arithmetic

  /// The `+` operator. Port of the cel-go `Add` trait methods.
  package func add(_ other: Value) -> Value {
    switch (self, other) {
    case (.int(let a), .int(let b)): return lift(addInt64Checked(a, b), Value.int)
    case (.uint(let a), .uint(let b)): return lift(addUint64Checked(a, b), Value.uint)
    case (.double(let a), .double(let b)): return .double(a + b)
    case (.string(let a), .string(let b)): return .string(a + b)
    case (.bytes(let a), .bytes(let b)): return .bytes(a + b)
    case (.list(let a), .list(let b)):
      // A comprehension accumulator appends in place (cel-go mutableList.Add).
      if let mutable = a as? MutableList {
        mutable.append(contentsOf: b)
        return .list(mutable)
      }
      return .list(concatLists(a, b))
    case (.duration(let a), .duration(let b)): return lift(addDurationChecked(a, b), Value.duration)
    case (.duration(let a), .timestamp(let b)):
      return lift(addTimeDurationChecked(b, a), Value.timestamp)
    case (.timestamp(let a), .duration(let b)):
      return lift(addTimeDurationChecked(a, b), Value.timestamp)
    case (.int, _), (.uint, _), (.double, _), (.string, _), (.bytes, _), (.list, _), (.duration, _),
      (.timestamp, _):
      return Value.maybeNoSuchOverload(other)
    default:
      return .noSuchOverload
    }
  }

  /// The binary `-` operator. Port of the cel-go `Subtract` trait methods.
  package func subtract(_ other: Value) -> Value {
    switch (self, other) {
    case (.int(let a), .int(let b)): return lift(subtractInt64Checked(a, b), Value.int)
    case (.uint(let a), .uint(let b)): return lift(subtractUint64Checked(a, b), Value.uint)
    case (.double(let a), .double(let b)): return .double(a - b)
    case (.duration(let a), .duration(let b)):
      return lift(subtractDurationChecked(a, b), Value.duration)
    case (.timestamp(let a), .duration(let b)):
      return lift(subtractTimeDurationChecked(a, b), Value.timestamp)
    case (.timestamp(let a), .timestamp(let b)):
      return lift(subtractTimeChecked(a, b), Value.duration)
    case (.int, _), (.uint, _), (.double, _), (.duration, _), (.timestamp, _):
      return Value.maybeNoSuchOverload(other)
    default:
      return .noSuchOverload
    }
  }

  /// The `*` operator. Port of the cel-go `Multiply` trait methods.
  package func multiply(_ other: Value) -> Value {
    switch (self, other) {
    case (.int(let a), .int(let b)): return lift(multiplyInt64Checked(a, b), Value.int)
    case (.uint(let a), .uint(let b)): return lift(multiplyUint64Checked(a, b), Value.uint)
    case (.double(let a), .double(let b)): return .double(a * b)
    case (.int, _), (.uint, _), (.double, _):
      return Value.maybeNoSuchOverload(other)
    default:
      return .noSuchOverload
    }
  }

  /// The `/` operator. Port of the cel-go `Divide` trait methods.
  package func divide(_ other: Value) -> Value {
    switch (self, other) {
    case (.int(let a), .int(let b)): return lift(divideInt64Checked(a, b), Value.int)
    case (.uint(let a), .uint(let b)): return lift(divideUint64Checked(a, b), Value.uint)
    case (.double(let a), .double(let b)): return .double(a / b)
    case (.int, _), (.uint, _), (.double, _):
      return Value.maybeNoSuchOverload(other)
    default:
      return .noSuchOverload
    }
  }

  /// The `%` operator. Port of the cel-go `Modulo` trait methods.
  package func modulo(_ other: Value) -> Value {
    switch (self, other) {
    case (.int(let a), .int(let b)): return lift(moduloInt64Checked(a, b), Value.int)
    case (.uint(let a), .uint(let b)): return lift(moduloUint64Checked(a, b), Value.uint)
    case (.int, _), (.uint, _):
      return Value.maybeNoSuchOverload(other)
    default:
      return .noSuchOverload
    }
  }

  /// Unary `-` for numbers and durations, `!` for booleans. Port of the cel-go `Negate` methods.
  package func negate() -> Value {
    switch self {
    case .bool(let b): return .bool(!b)
    case .int(let i): return lift(negateInt64Checked(i), Value.int)
    case .double(let d): return .double(-d)
    case .duration(let d): return lift(negateDurationChecked(d), Value.duration)
    default: return .noSuchOverload
    }
  }

  // MARK: Comparison

  /// Three-way comparison returning `.int(-1)`, `.int(0)` or `.int(1)`, or an error.
  ///
  /// Numbers compare across `int`, `uint` and `double`; NaN cannot be ordered. Port of the cel-go
  /// `Compare` trait methods.
  package func compare(_ other: Value) -> Value {
    switch self {
    case .bool(let a):
      guard case .bool(let b) = other else { return Value.maybeNoSuchOverload(other) }
      return .int(a == b ? 0 : (!a && b ? -1 : 1))
    case .int(let a):
      switch other {
      case .double(let b):
        if b.isNaN { return .error(message: "NaN values cannot be ordered") }
        return .int(compareIntDouble(a, b))
      case .int(let b): return .int(compareOrdered(a, b))
      case .uint(let b): return .int(compareIntUint(a, b))
      default: return Value.maybeNoSuchOverload(other)
      }
    case .uint(let a):
      switch other {
      case .double(let b):
        if b.isNaN { return .error(message: "NaN values cannot be ordered") }
        return .int(compareUintDouble(a, b))
      case .int(let b): return .int(-compareIntUint(b, a))
      case .uint(let b): return .int(compareOrdered(a, b))
      default: return Value.maybeNoSuchOverload(other)
      }
    case .double(let a):
      if a.isNaN { return .error(message: "NaN values cannot be ordered") }
      switch other {
      case .double(let b):
        if b.isNaN { return .error(message: "NaN values cannot be ordered") }
        return .int(compareOrdered(a, b))
      case .int(let b): return .int(compareDoubleInt(a, b))
      case .uint(let b): return .int(compareDoubleUint(a, b))
      default: return Value.maybeNoSuchOverload(other)
      }
    case .string(let a):
      guard case .string(let b) = other else { return Value.maybeNoSuchOverload(other) }
      return .int(compareUTF8(a, b))
    case .bytes(let a):
      guard case .bytes(let b) = other else { return Value.valOrError(other, "no such overload") }
      return .int(compareBytes(a, b))
    case .duration(let a):
      guard case .duration(let b) = other else { return Value.maybeNoSuchOverload(other) }
      return .int(compareOrdered(a.nanoseconds, b.nanoseconds))
    case .timestamp(let a):
      guard case .timestamp(let b) = other else { return Value.maybeNoSuchOverload(other) }
      return .int(a < b ? -1 : (b < a ? 1 : 0))
    default:
      return .noSuchOverload
    }
  }

  // MARK: Equality

  /// CEL heterogeneous equality, the `==` operator. Port of cel-go `types.Equal` and the `Equal`
  /// methods: numbers compare by value across `int`, `uint` and `double`, `null` equals only
  /// `null`, errors and unknowns return themselves.
  package func celEquals(_ other: Value) -> Value {
    if case .null = self {
      return .bool(other.isNull)
    }
    if case .null = other {
      return .bool(false)
    }
    switch self {
    case .error, .unknown:
      return self
    case .bool(let a):
      if case .bool(let b) = other { return .bool(a == b) }
    case .int(let a):
      switch other {
      case .double(let b): return .bool(!b.isNaN && compareIntDouble(a, b) == 0)
      case .int(let b): return .bool(a == b)
      case .uint(let b): return .bool(compareIntUint(a, b) == 0)
      default: break
      }
    case .uint(let a):
      switch other {
      case .double(let b): return .bool(!b.isNaN && compareUintDouble(a, b) == 0)
      case .int(let b): return .bool(compareIntUint(b, a) == 0)
      case .uint(let b): return .bool(a == b)
      default: break
      }
    case .double(let a):
      if a.isNaN { return .bool(false) }
      switch other {
      case .double(let b): return .bool(a == b)
      case .int(let b): return .bool(compareDoubleInt(a, b) == 0)
      case .uint(let b): return .bool(compareDoubleUint(a, b) == 0)
      default: break
      }
    case .string(let a):
      if case .string(let b) = other { return .bool(utf8Equal(a, b)) }
    case .bytes(let a):
      if case .bytes(let b) = other { return .bool(a == b) }
    case .list(let a):
      if case .list(let b) = other { return a.celEquals(b) }
    case .map(let a):
      if case .map(let b) = other { return a.celEquals(b) }
    case .type(let a):
      if case .type(let b) = other { return .bool(a.runtimeTypeName == b.runtimeTypeName) }
    case .duration(let a):
      if case .duration(let b) = other { return .bool(a == b) }
    case .timestamp(let a):
      if case .timestamp(let b) = other { return .bool(a == b) }
    case .optional(let a):
      guard case .optional(let b) = other else { break }
      switch (a, b) {
      case (nil, nil): return .bool(true)
      case (.some(let x), .some(let y)): return x.celEquals(y)
      default: return .bool(false)
      }
    case .object(let a):
      if case .object(let b) = other { return .bool(a.isEqual(to: b)) }
    case .null:
      break
    }
    return .bool(false)
  }

  /// Whether the value is `null`.
  public var isNull: Bool {
    if case .null = self { return true }
    return false
  }

  // MARK: Size, containment and indexing

  /// The `size` function: code points of a string, bytes, list elements or map entries.
  package func size() -> Value {
    switch self {
    case .string(let s): return .int(Int64(s.unicodeScalars.count))
    case .bytes(let b): return .int(Int64(b.count))
    case .list(let l): return .int(Int64(l.count))
    case .map(let m): return .int(Int64(m.count))
    default: return .noSuchOverload
    }
  }

  /// The `in` operator with `self` as the container. Port of cel-go `inAggregate`.
  package func contains(_ element: Value) -> Value {
    switch self {
    case .list(let l): return l.containsValue(element)
    case .map(let m): return m.containsKey(element)
    default: return Value.valOrError(self, "no such overload")
    }
  }

  /// Index access `self[index]` on lists and maps, and field access on objects with a string index.
  package func get(_ index: Value) -> Value {
    switch self {
    case .list(let l): return l.get(index)
    case .map(let m): return m.get(index)
    case .object(let o):
      guard case .string(let name) = index else { return Value.maybeNoSuchOverload(index) }
      return o.field(name)
    default: return .noSuchOverload
    }
  }
}

// MARK: - Numeric comparison helpers (compare.go)

private func compareOrdered<T: Comparable>(_ a: T, _ b: T) -> Int64 {
  a < b ? -1 : (a > b ? 1 : 0)
}

func compareDoubleInt(_ d: Double, _ i: Int64) -> Int64 {
  if d < -9_223_372_036_854_775_808.0 { return -1 }
  if d > 9_223_372_036_854_775_807.0 { return 1 }
  return compareOrdered(d, Double(i))
}

func compareIntDouble(_ i: Int64, _ d: Double) -> Int64 {
  -compareDoubleInt(d, i)
}

func compareDoubleUint(_ d: Double, _ u: UInt64) -> Int64 {
  if d < 0 { return -1 }
  if d > 18_446_744_073_709_551_615.0 { return 1 }
  return compareOrdered(d, Double(u))
}

func compareUintDouble(_ u: UInt64, _ d: Double) -> Int64 {
  -compareDoubleUint(d, u)
}

func compareIntUint(_ i: Int64, _ u: UInt64) -> Int64 {
  if i < 0 || u > UInt64(Int64.max) { return -1 }
  return compareOrdered(i, Int64(u))
}

/// Byte-wise comparison of the UTF-8 encodings, as Go `strings.Compare`.
func compareUTF8(_ a: String, _ b: String) -> Int64 {
  withUTF8Bytes(a) { x in
    withUTF8Bytes(b) { y in
      compareByteBuffers(x, y)
    }
  }
}

/// Lexicographic byte comparison, as Go `bytes.Compare`.
func compareBytes(_ a: [UInt8], _ b: [UInt8]) -> Int64 {
  for (x, y) in zip(a, b) where x != y {
    return x < y ? -1 : 1
  }
  return compareOrdered(a.count, b.count)
}
