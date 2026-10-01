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
// Ported from cel-go ext/bindings.go (the library declarations; the `cel.bind` macro is in
// Macros.swift), ext/comprehensions.go (`cel.@mapInsert`), ext/protos.go and the `cel.block` test
// library of cel-go conformance/conformance_test.go.
//
// `cel.@block` needs the interpreter to evaluate its slot expressions lazily (cel-go plans it with
// a `CustomDecoratorV2`); the declaration is here, the evaluation belongs to the interpreter, which
// recognizes calls to `Library.blockFunction`.

import CEL

extension Library {
  /// The name of the `cel.@block` function the interpreter evaluates specially: its first argument
  /// is a list of slot expressions, visible as `@index0`, `@index1`, ... in the second.
  package static let blockFunction = "cel.@block"

  /// The bindings extension library at its latest version: the `cel.bind(var, init, result)`
  /// macro and, from version 1, the `cel.@block` function used by optimized expressions.
  public static var bindings: Library { bindings() }

  /// The bindings extension library at a given version.
  ///
  /// - Parameter version: the library version; ``Library/latestVersion`` enables everything.
  public static func bindings(version: UInt32 = Library.latestVersion) -> Library {
    var functions: [FunctionDecl] = []
    if version >= 1 {
      let paramT = CELType.typeParam("T")
      functions = makeDeclarations([
        try FunctionDecl(
          blockFunction, .overload("cel_block_list", argumentTypes: [.list(.dyn), paramT], resultType: paramT))
      ])
    }
    var lib = Library(
      name: "cel.lib.ext.cel.bindings", alias: "bindings", version: version, functions: functions,
      macros: [BindingsMacros.bind],
      homogeneousLiteralExemptFunctions: version >= 1 ? [blockFunction] : [])
    if version >= 1 {
      lib.decorators = [BlockPlan.decorator]
    }
    return lib
  }

  /// The two-variable comprehension library: `all`, `exists`, `existsOne`, `transformList`,
  /// `transformMap` and `transformMapEntry` with an index or key variable and a value variable.
  public static var twoVarComprehensions: Library { twoVarComprehensions() }

  /// The two-variable comprehension library at a given version (only version 0 exists).
  ///
  /// - Parameter version: the library version.
  public static func twoVarComprehensions(version: UInt32 = Library.latestVersion) -> Library {
    let k = CELType.typeParam("K")
    let v = CELType.typeParam("V")
    let mapKV = CELType.map(key: k, value: v)
    let functions = makeDeclarations([
      try FunctionDecl(
        ComprehensionMacros.mapInsert,
        .overload(
          "@mapInsert_map_key_value", argumentTypes: [mapKV, k, v], resultType: mapKV,
          .functionBinding { args in
            guard args.count == 3, case .map(let m) = args[0] else { return .noSuchOverload }
            return insertMapKeyValue(m, args[1], args[2])
          }),
        .overload(
          "@mapInsert_map_map", argumentTypes: [mapKV, mapKV], resultType: mapKV,
          .binaryBinding { target, update in
            guard case .map(var tm) = target, case .map(let um) = update else {
              return noSuchOverload(target, update)
            }
            for key in um.keys {
              let updated = insertMapKeyValue(tm, key.value, um.value(forKey: key) ?? .null)
              guard case .map(let m) = updated else { return updated }
              tm = m
            }
            return .map(tm)
          }))
    ])
    return Library(
      name: "cel.lib.ext.comprev2", alias: "two-var-comprehensions", version: version,
      functions: functions, macros: ComprehensionMacros.macros)
  }

  /// The protobuf extension library: the `proto.getExt(msg, ext.name)` and
  /// `proto.hasExt(msg, ext.name)` macros for proto2 extension fields.
  public static var protos: Library { protos() }

  /// The protobuf extension library at a given version (only version 0 exists).
  ///
  /// - Parameter version: the library version.
  public static func protos(version: UInt32 = Library.latestVersion) -> Library {
    Library(name: "cel.lib.ext.protos", alias: "protos", version: version, macros: ProtosMacros.macros)
  }

  /// The `cel.block`, `cel.index`, `cel.iterVar` and `cel.accuVar` macros and the `@index0` ...
  /// `@index29` variables cel-go's conformance runner adds to test `cel.@block`.
  package static var celBlockConformance: Library {
    Library(
      name: "cel.lib.ext.cel.block.conformance", alias: "block",
      variables: (0..<30).map { VariableDecl(name: "@index\($0)", type: .dyn) },
      macros: BlockMacros.macros)
  }
}

/// Port of cel-go `types.InsertMapKeyValue`: a copy of the map with the entry added, or an error
/// when the key is already present.
func insertMapKeyValue(_ m: any MapValue, _ key: Value, _ value: Value) -> Value {
  if key.isUnknownOrError {
    return key
  }
  // A comprehension accumulator inserts in place (cel-go mutableMap.Insert).
  if let mutable = m as? MutableMap {
    return mutable.insert(key, value)
  }
  if m.find(key) != nil {
    return errorValue("insert failed: key \(formatGoValue(key)) already exists")
  }
  guard let mapKey = MapKey(key) else {
    return errorValue("unsupported key type: \(key.runtimeTypeName)")
  }
  var copy = OrderedMap(m.keys.map { ($0, m.value(forKey: $0) ?? .null) })
  _ = copy.insert(value, forKey: mapKey)
  return .map(copy)
}
