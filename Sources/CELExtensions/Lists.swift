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
// Ported from cel-go ext/lists.go: `slice`, `flatten`, `sort`, `@sortByAssociatedKeys` (behind
// the `sortBy` macro), `lists.range`, `reverse` and `distinct`. The cost estimators and trackers
// (version 3) are in ListsCosts.swift.

import CEL

extension Library {
  /// The lists extension library at its latest version: `slice`, `flatten`, `sort`, `sortBy`,
  /// `lists.range`, `reverse` and `distinct`.
  public static var lists: Library { lists() }

  /// The lists extension library at a given version.
  ///
  /// Version 0 has `slice`, version 1 adds `flatten`, and version 2 adds `sort`, `sortBy`,
  /// `lists.range`, `reverse` and `distinct`.
  ///
  /// - Parameters:
  ///   - version: the library version; `Library.latestVersion` enables everything.
  ///   - maxRangeSize: the largest list `lists.range` creates; `0` disables the limit.
  public static func lists(
    version: UInt32 = Library.latestVersion, maxRangeSize: Int64 = 1_000_000
  ) -> Library {
    ListsLibrary(version: version, maxRangeSize: maxRangeSize).library
  }
}

/// Port of cel-go `listsLib`.
struct ListsLibrary {
  /// cel-go `comparableTypes`, in its order.
  static let comparableTypes: [CELType] = [
    .int, .uint, .double, .bool, .duration, .timestamp, .string, .bytes,
  ]

  let version: UInt32
  let maxRangeSize: Int64

  var library: Library {
    let lib = Library(
      name: "cel.lib.ext.lists", alias: "lists", version: version,
      functions: makeDeclarations(try functions()),
      macros: version >= 2 ? [ListsMacros.sortBy] : [])
    guard version >= 3 else { return lib }
    return lib.withCosts(
      estimators: ListsCosts.estimators(version: version), trackers: ListsCosts.trackers(version: version))
  }

  // swift-format-ignore: FunctionLength
  private func functions() throws -> [FunctionDecl] {
    let paramT = CELType.typeParam("T")
    let listType = CELType.list(paramT)
    var decls = [
      try FunctionDecl(
        "slice",
        .memberOverload(
          "list_slice", argumentTypes: [listType, .int, .int], resultType: listType,
          .functionBinding { args in
            guard args.count == 3, case .list(let list) = args[0], case .int(let start) = args[1],
              case .int(let end) = args[2]
            else { return .noSuchOverload }
            return slice(list, start, end)
          }))
    ]
    if version >= 1 {
      decls.append(
        try FunctionDecl(
          "flatten",
          .memberOverload(
            "list_flatten", argumentTypes: [.list(listType)], resultType: listType,
            .unaryBinding { arg in
              // Double-check as type guards are disabled.
              guard case .list(let list) = arg else {
                return Value.valOrError(arg, "no such overload: \(arg.celType.runtimeTypeName).flatten()")
              }
              return flatten(list, 1)
            }),
          .memberOverload(
            "list_flatten_int", argumentTypes: [.list(.dyn), .int], resultType: .list(.dyn),
            .binaryBinding { arg1, arg2 in
              guard case .list(let list) = arg1, case .int(let depth) = arg2 else {
                return Value.valOrError(
                  arg1,
                  "no such overload: \(arg1.celType.runtimeTypeName).flatten(\(arg2.celType.runtimeTypeName))")
              }
              return flatten(list, depth)
            }),
          // A variable of just `list(T)` may be flat at runtime; the implementation handles it.
          .disableTypeGuards(true)))
    }
    if version >= 2 {
      var sortOptions: [FunctionDecl.Option] = Self.comparableTypes.map { t in
        .memberOverload(
          "list_\(t.runtimeTypeName)_sort", argumentTypes: [.list(t)], resultType: .list(t))
      }
      sortOptions.append(
        .singletonUnaryBinding(
          { arg in
            guard case .list(let list) = arg else { return noSuchOverload(arg) }
            return sortByAssociatedKeys(list, list)
          }, traits: .lister))
      decls.append(try FunctionDecl("sort", options: sortOptions))

      var sortByOptions: [FunctionDecl.Option] = Self.comparableTypes.map { u in
        .memberOverload(
          "list_\(u.runtimeTypeName)_sortByAssociatedKeys", argumentTypes: [listType, .list(u)],
          resultType: listType)
      }
      sortByOptions.append(
        .singletonBinaryBinding(
          { arg1, arg2 in
            guard case .list(let list) = arg1, case .list(let keys) = arg2 else {
              return noSuchOverload(arg1, arg2)
            }
            return sortByAssociatedKeys(list, keys)
          }, traits: .lister))
      decls.append(try FunctionDecl("@sortByAssociatedKeys", options: sortByOptions))

      let maxRange = maxRangeSize
      decls.append(
        try FunctionDecl(
          "lists.range",
          .overload(
            "lists_range", argumentTypes: [.int], resultType: .list(.int),
            .unaryBinding { n in
              guard case .int(let count) = n else { return noSuchOverload(n) }
              return range(count, maxRange)
            })))
      decls.append(
        try FunctionDecl(
          "reverse",
          .memberOverload(
            "list_reverse", argumentTypes: [listType], resultType: listType,
            .unaryBinding { arg in
              guard case .list(let list) = arg else { return noSuchOverload(arg) }
              return .list(ArrayList(list.elements.reversed()))
            })))
      decls.append(
        try FunctionDecl(
          "distinct",
          .memberOverload(
            "list_distinct", argumentTypes: [listType], resultType: listType,
            .unaryBinding { arg in
              guard case .list(let list) = arg else { return noSuchOverload(arg) }
              return distinct(list)
            })))
    }
    return decls
  }
}

/// Port of `genRange`.
private func range(_ n: Int64, _ maxSize: Int64) -> Value {
  if n < 0 {
    return errorValue("lists.range: size must be non-negative, got \(n)")
  }
  if maxSize > 0 && n > maxSize {
    return errorValue("lists.range: size \(n) exceeds maximum allowed (\(maxSize))")
  }
  return .list(ArrayList((0..<n).map(Value.int)))
}

/// Port of `slice`.
private func slice(_ list: any ListValue, _ start: Int64, _ end: Int64) -> Value {
  let length = Int64(list.count)
  if start < 0 || end < 0 {
    return errorValue("cannot slice(\(start), \(end)), negative indexes not supported")
  }
  if start > end {
    return errorValue(
      "cannot slice(\(start), \(end)), start index must be less than or equal to end index")
  }
  if length < end {
    return errorValue("cannot slice(\(start), \(end)), list is length \(length)")
  }
  return .list(ArrayList((start..<end).map { list.element(at: Int($0)) }))
}

/// Port of `flatten`.
private func flatten(_ list: any ListValue, _ depth: Int64) -> Value {
  if depth < 0 {
    return errorValue("level must be non-negative")
  }
  var out: [Value] = []
  flatten(list, depth, into: &out)
  return .list(ArrayList(out))
}

private func flatten(_ list: any ListValue, _ depth: Int64, into out: inout [Value]) {
  for i in 0..<list.count {
    let val = list.element(at: i)
    if case .list(let nested) = val, depth > 0 {
      flatten(nested, depth - 1, into: &out)
    } else {
      out.append(val)
    }
  }
}

/// Port of `sortListByAssociatedKeys`: sorts `list` by the order of `keys`, which must hold
/// comparable values of one type.
func sortByAssociatedKeys(_ list: any ListValue, _ keys: any ListValue) -> Value {
  let length = list.count
  if length != keys.count {
    return errorValue(
      "@sortByAssociatedKeys() expected a list of the same size as the associated keys list, "
        + "but got \(length) and \(keys.count) elements respectively")
  }
  if length == 0 {
    return .list(list)
  }
  let first = keys.element(at: 0)
  guard first.traits.contains(.comparer) else {
    return errorValue("list elements must be comparable")
  }
  let firstType = first.runtimeTypeName
  let keyValues = keys.elements
  for k in keyValues where k.runtimeTypeName != firstType {
    // cel-go reports this from inside the sort comparator; any mismatch is seen when sorting
    // more than one element.
    if length > 1 {
      return errorValue("list elements must have the same type")
    }
  }
  // Go's sort.Slice is not stable, but keys that compare equal are indistinguishable only when
  // the elements are too; a stable sort gives the deterministic answer cel-go's tests expect.
  let order = (0..<length).sorted { i, j in
    if case .int(-1) = keyValues[i].compare(keyValues[j]) {
      return true
    }
    return false
  }
  return .list(ArrayList(order.map { list.element(at: $0) }))
}

/// Port of `distinctList`.
private func distinct(_ list: any ListValue) -> Value {
  if list.count == 0 {
    return .list(list)
  }
  var unique: [Value] = []
  for i in 0..<list.count {
    let val = list.element(at: i)
    let seen = unique.contains { other in
      if case .bool(true) = val.celEquals(other) {
        return true
      }
      return false
    }
    if !seen {
      unique.append(val)
    }
  }
  return .list(ArrayList(unique))
}
