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
// Ported from cel-go ext/sets.go: `sets.contains`, `sets.equivalent` and `sets.intersects`. The
// set membership optimizer and the cost estimators and trackers are not ported yet.

import CEL

extension Library {
  /// The sets extension library: `sets.contains`, `sets.equivalent` and `sets.intersects`, which
  /// treat lists as sets under CEL equality.
  public static var sets: Library { sets() }

  /// The sets extension library at a given version (only version 0 exists).
  ///
  /// - Parameter version: the library version.
  public static func sets(version: UInt32 = Library.latestVersion) -> Library {
    let listType = CELType.list(.typeParam("T"))
    func decl(_ name: String, _ id: String, _ f: @escaping @Sendable (any ListValue, any ListValue) -> Value)
      throws -> FunctionDecl
    {
      try FunctionDecl(
        name,
        .overload(
          id, argTypes: [listType, listType], resultType: .bool,
          .binaryBinding { a, b in
            guard case .list(let l) = a, case .list(let r) = b else { return noSuchOverload(a, b) }
            return f(l, r)
          }))
    }
    return Library(
      name: "cel.lib.ext.sets", alias: "sets", version: version,
      functions: makeDeclarations([
        try decl("sets.contains", "list_sets_contains_list", setsContains),
        try decl("sets.equivalent", "list_sets_equivalent_list", setsEquivalent),
        try decl("sets.intersects", "list_sets_intersects_list", setsIntersects),
      ]))
  }
}

/// Port of `setsIntersects`.
func setsIntersects(_ a: any ListValue, _ b: any ListValue) -> Value {
  for i in 0..<a.count {
    if case .bool(true) = b.containsValue(a.element(at: i)) {
      return .bool(true)
    }
  }
  return .bool(false)
}

/// Port of `setsContains`: whether every element of `sub` is in `list`.
func setsContains(_ list: any ListValue, _ sub: any ListValue) -> Value {
  for i in 0..<sub.count {
    let exists = list.containsValue(sub.element(at: i))
    if case .bool(true) = exists {
      continue
    }
    return exists
  }
  return .bool(true)
}

/// Port of `setsEquivalent`.
func setsEquivalent(_ a: any ListValue, _ b: any ListValue) -> Value {
  let aContainsB = setsContains(a, b)
  guard case .bool(true) = aContainsB else { return aContainsB }
  return setsContains(b, a)
}
