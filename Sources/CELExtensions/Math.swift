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
// Ported from cel-go ext/math.go: the `math.@min` / `math.@max` functions behind the
// `math.least` / `math.greatest` macros, rounding, floating point helpers, signedness, bitwise
// operations and `math.sqrt`. The macros are in MathMacros.swift. Cost estimators and trackers
// (version 3) are not ported yet.

import CEL

extension Library {
  /// The math extension library at its latest version: `math.least`, `math.greatest`,
  /// `math.ceil`, `math.floor`, `math.round`, `math.trunc`, `math.isInf`, `math.isNaN`,
  /// `math.isFinite`, `math.abs`, `math.sign`, the `math.bit*` functions and `math.sqrt`.
  public static var math: Library { math() }

  /// The math extension library at a given version.
  ///
  /// Version 0 has `math.least` and `math.greatest`, version 1 adds rounding, floating point
  /// helpers, signedness and bitwise functions, and version 2 adds `math.sqrt`.
  ///
  /// - Parameter version: the library version; ``Library/latestVersion`` enables everything.
  public static func math(version: UInt32 = Library.latestVersion) -> Library {
    MathLibrary(version: version).library
  }
}

/// Port of cel-go `mathLib`.
struct MathLibrary {
  static let minFunc = "math.@min"
  static let maxFunc = "math.@max"

  let version: UInt32

  var library: Library {
    Library(
      name: "cel.lib.ext.math", alias: "math", version: version,
      functions: makeDeclarations(try functions()), macros: MathMacros.macros)
  }

  private func minMax(_ name: String, prefix: String, pair: @escaping FunctionBinding.Binary,
    list: @escaping FunctionBinding.Unary
  ) throws -> FunctionDecl {
    let identity: FunctionBinding.Unary = { $0 }
    let scalars: [(String, CELType)] = [("double", .double), ("int", .int), ("uint", .uint)]
    var options: [FunctionDecl.Option] = []
    for (n, t) in scalars {
      options.append(.overload("\(prefix)_\(n)", argTypes: [t], resultType: t, .unaryBinding(identity)))
    }
    for (n, t) in scalars {
      options.append(
        .overload("\(prefix)_\(n)_\(n)", argTypes: [t, t], resultType: t, .binaryBinding(pair)))
    }
    let mixed: [(String, CELType, String, CELType)] = [
      ("int", .int, "uint", .uint), ("int", .int, "double", .double),
      ("double", .double, "int", .int), ("double", .double, "uint", .uint),
      ("uint", .uint, "int", .int), ("uint", .uint, "double", .double),
    ]
    for (a, at, b, bt) in mixed {
      options.append(
        .overload("\(prefix)_\(a)_\(b)", argTypes: [at, bt], resultType: .dyn, .binaryBinding(pair)))
    }
    for (n, t) in scalars {
      options.append(
        .overload("\(prefix)_list_\(n)", argTypes: [.list(t)], resultType: t, .unaryBinding(list)))
    }
    return try FunctionDecl(name, options: options)
  }

  // swift-format-ignore: FunctionLength
  private func functions() throws -> [FunctionDecl] {
    var decls = [
      try minMax(Self.minFunc, prefix: "math_@min", pair: minPair, list: minList),
      try minMax(Self.maxFunc, prefix: "math_@max", pair: maxPair, list: maxList),
    ]
    if version >= 1 {
      func doubleFn(_ name: String, _ id: String, _ result: CELType, _ f: @escaping @Sendable (Double) -> Value)
        throws -> FunctionDecl
      {
        try FunctionDecl(
          name,
          .overload(
            id, argTypes: [.double], resultType: result,
            .unaryBinding { v in
              guard case .double(let d) = v else { return noSuchOverload(v) }
              return f(d)
            }))
      }
      decls += [
        try doubleFn("math.ceil", "math_ceil_double", .double) { .double($0.rounded(.up)) },
        try doubleFn("math.floor", "math_floor_double", .double) { .double($0.rounded(.down)) },
        // Go math.Round: half away from zero.
        try doubleFn("math.round", "math_round_double", .double) {
          .double($0.rounded(.toNearestOrAwayFromZero))
        },
        try doubleFn("math.trunc", "math_trunc_double", .double) { .double($0.rounded(.towardZero)) },
        try doubleFn("math.isInf", "math_isInf_double", .bool) { .bool($0.isInfinite) },
        try doubleFn("math.isNaN", "math_isNaN_double", .bool) { .bool($0.isNaN) },
        try doubleFn("math.isFinite", "math_isFinite_double", .bool) { .bool($0.isFinite) },
        try FunctionDecl(
          "math.abs",
          .overload(
            "math_abs_double", argTypes: [.double], resultType: .double,
            .unaryBinding { v in
              guard case .double(let d) = v else { return noSuchOverload(v) }
              return .double(Swift.abs(d))
            }),
          .overload(
            "math_abs_int", argTypes: [.int], resultType: .int,
            .unaryBinding { v in
              guard case .int(let i) = v else { return noSuchOverload(v) }
              if i == .min {
                return .error(.intOverflow)
              }
              return .int(i >= 0 ? i : -i)
            }),
          .overload("math_abs_uint", argTypes: [.uint], resultType: .uint, .unaryBinding { $0 })),
        try FunctionDecl(
          "math.sign",
          .overload("math_sign_double", argTypes: [.double], resultType: .double, .unaryBinding(sign)),
          .overload("math_sign_int", argTypes: [.int], resultType: .int, .unaryBinding(sign)),
          .overload("math_sign_uint", argTypes: [.uint], resultType: .uint, .unaryBinding(sign))),
        try bitwise("math.bitAnd", "math_bitAnd", &, &),
        try bitwise("math.bitOr", "math_bitOr", |, |),
        try bitwise("math.bitXor", "math_bitXor", ^, ^),
        try FunctionDecl(
          "math.bitNot",
          .overload(
            "math_bitNot_int_int", argTypes: [.int], resultType: .int,
            .unaryBinding { v in
              guard case .int(let i) = v else { return noSuchOverload(v) }
              return .int(~i)
            }),
          .overload(
            "math_bitNot_uint_uint", argTypes: [.uint], resultType: .uint,
            .unaryBinding { v in
              guard case .uint(let u) = v else { return noSuchOverload(v) }
              return .uint(~u)
            })),
        try shift("math.bitShiftLeft", "math_bitShiftLeft", left: true),
        try shift("math.bitShiftRight", "math_bitShiftRight", left: false),
      ]
    }
    if version >= 2 {
      decls.append(
        try FunctionDecl(
          "math.sqrt",
          .overload("math_sqrt_double", argTypes: [.double], resultType: .double, .unaryBinding(sqrt)),
          .overload("math_sqrt_int", argTypes: [.int], resultType: .double, .unaryBinding(sqrt)),
          .overload("math_sqrt_uint", argTypes: [.uint], resultType: .double, .unaryBinding(sqrt))))
    }
    return decls
  }

  private func bitwise(
    _ name: String, _ prefix: String, _ intOp: @escaping @Sendable (Int64, Int64) -> Int64,
    _ uintOp: @escaping @Sendable (UInt64, UInt64) -> UInt64
  ) throws -> FunctionDecl {
    try FunctionDecl(
      name,
      .overload(
        "\(prefix)_int_int", argTypes: [.int, .int], resultType: .int,
        .binaryBinding { a, b in
          guard case .int(let l) = a, case .int(let r) = b else { return noSuchOverload(a, b) }
          return .int(intOp(l, r))
        }),
      .overload(
        "\(prefix)_uint_uint", argTypes: [.uint, .uint], resultType: .uint,
        .binaryBinding { a, b in
          guard case .uint(let l) = a, case .uint(let r) = b else { return noSuchOverload(a, b) }
          return .uint(uintOp(l, r))
        }))
  }

  /// Go shifts: counts of 64 or more give 0 (or -1 for a negative int shifted right, but cel-go
  /// shifts ints right as unsigned).
  private func shift(_ name: String, _ prefix: String, left: Bool) throws -> FunctionDecl {
    let fn = left ? "math.bitShiftLeft()" : "math.bitShiftRight()"
    return try FunctionDecl(
      name,
      .overload(
        "\(prefix)_int_int", argTypes: [.int, .int], resultType: .int,
        .binaryBinding { a, b in
          guard case .int(let v) = a, case .int(let bits) = b else { return noSuchOverload(a, b) }
          if bits < 0 {
            return errorValue("\(fn) negative offset: \(bits)")
          }
          if bits >= 64 {
            return .int(0)
          }
          return left ? .int(v << bits) : .int(Int64(bitPattern: UInt64(bitPattern: v) >> UInt64(bits)))
        }),
      .overload(
        "\(prefix)_uint_int", argTypes: [.uint, .int], resultType: .uint,
        .binaryBinding { a, b in
          guard case .uint(let v) = a, case .int(let bits) = b else { return noSuchOverload(a, b) }
          if bits < 0 {
            return errorValue("\(fn) negative offset: \(bits)")
          }
          if bits >= 64 {
            return .uint(0)
          }
          return .uint(left ? v << UInt64(bits) : v >> UInt64(bits))
        }))
  }
}

private func sign(_ val: Value) -> Value {
  switch val {
  case .double(let d):
    if d.isNaN {
      return val
    }
    return .double(d > 0 ? 1 : d < 0 ? -1 : 0)
  case .int(let i):
    return .int(i > 0 ? 1 : i < 0 ? -1 : 0)
  case .uint(let u):
    return .uint(u == 0 ? 0 : 1)
  default:
    return maybeSuffixError(val, "math.sign")
  }
}

private func sqrt(_ val: Value) -> Value {
  switch val {
  case .double(let d): .double(d.squareRoot())
  case .int(let i): .double(Double(i).squareRoot())
  case .uint(let u): .double(Double(u).squareRoot())
  default: errorValue("no such overload: sqrt")
  }
}

private func isNumeric(_ v: Value) -> Bool {
  switch v {
  case .int, .uint, .double, .unknown: true
  default: false
  }
}

private func minPair(_ first: Value, _ second: Value) -> Value {
  guard first.traits.contains(.comparer) else { return Value.maybeNoSuchOverload(first) }
  let out = first.compare(second)
  if out.isUnknownOrError {
    return maybeSuffixError(out, "math.@min")
  }
  if case .int(1) = out {
    return second
  }
  return first
}

private func maxPair(_ first: Value, _ second: Value) -> Value {
  guard first.traits.contains(.comparer) else { return Value.maybeNoSuchOverload(first) }
  let out = first.compare(second)
  if out.isUnknownOrError {
    return maybeSuffixError(out, "math.@max")
  }
  if case .int(-1) = out {
    return second
  }
  return first
}

private func foldList(_ val: Value, _ name: String, _ pair: (Value, Value) -> Value) -> Value {
  guard case .list(let l) = val else { return noSuchOverload(val) }
  if l.count == 0 {
    return errorValue("\(name)(list) argument must not be empty")
  }
  var result = l.element(at: 0)
  for i in 1..<l.count {
    result = pair(result, l.element(at: i))
  }
  return isNumeric(result) ? result : errorValue("no such overload: \(name)")
}

private func minList(_ val: Value) -> Value {
  foldList(val, "math.@min", minPair)
}

private func maxList(_ val: Value) -> Value {
  foldList(val, "math.@max", maxPair)
}

/// Port of `maybeSuffixError`: appends `: <suffix>` to an error message not already mentioning it.
private func maybeSuffixError(_ val: Value, _ suffix: String) -> Value {
  if case .error(let e) = val, !e.message.contains(suffix) {
    return errorValue("\(e.message): \(suffix)")
  }
  return val
}
