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
// Ported from cel-go ext/formatting_v2.go (appendingFormatterV2, stringFormatterV2): the runtime
// clauses of `string.format` from strings version 4, which follow the cel-spec strings extension.

import CEL

/// The `string.format` implementation of strings version 4 and later.
enum FormatterV2 {
  static func format(_ format: String, _ args: any ListValue, maxPrecision: Int) -> Value {
    let list = FormatArguments(list: args)
    let result = parseFormatString(
      format, argumentCount: args.count, maxPrecision: maxPrecision,
      requestArgument: list.requestArgument
    ) { index, clause in
      apply(clause, to: args.element(at: index))
    }
    switch result {
    case .success(let s): return .string(s)
    case .failure(let err): return .error(EvalError(err.message))
    }
  }

  static func apply(_ clause: FormatClause, to arg: Value) -> Result<String, FormatError> {
    switch clause {
    case .string: string(arg)
    case .decimal: decimal(arg)
    case .fixed(let precision): fixed(arg, precision: precision ?? 6)
    case .scientific(let precision): scientific(arg, precision: precision ?? 6)
    case .binary: binary(arg)
    case .hex(let uppercase): hex(arg, uppercase: uppercase)
    case .octal: octal(arg)
    }
  }

  /// `%s`: port of `appendingFormatterV2.format`.
  static func string(_ arg: Value) -> Result<String, FormatError> {
    var out: [UInt8] = []
    if let err = append(&out, arg) {
      return .failure(err)
    }
    return .success(String(decoding: out, as: UTF8.self))
  }

  private static func append(_ out: inout [UInt8], _ arg: Value) -> FormatError? {
    switch arg {
    case .bool(let b):
      out += Array((b ? "true" : "false").utf8)
    case .int(let i):
      out += Array(String(i).utf8)
    case .uint(let u):
      out += Array(String(u).utf8)
    case .double(let d):
      out += Array(shortestDouble(d).utf8)
    case .bytes(let b):
      out += b
    case .string(let s):
      out += Array(s.utf8)
    case .duration(let d):
      // Go Duration.Seconds(): whole seconds plus the fraction, as one float.
      let seconds = Double(d.nanoseconds / 1_000_000_000) + Double(d.nanoseconds % 1_000_000_000) / 1e9
      out += Array(GoFloat.shortestFixed(seconds).utf8)
      out.append(UInt8(ascii: "s"))
    case .timestamp(let t):
      let utc = CELTimestamp(secondsSinceEpoch: t.secondsSinceEpoch, nanoseconds: t.nanoseconds)
      out += Array(utc.celString.utf8)
    case .null:
      out += Array("null".utf8)
    case .type(let t):
      out += Array(t.runtimeTypeName.utf8)
    case .list(let list):
      out.append(UInt8(ascii: "["))
      for i in 0..<list.count {
        if i > 0 {
          out += Array(", ".utf8)
        }
        if let err = append(&out, list.element(at: i)) {
          return err
        }
      }
      out.append(UInt8(ascii: "]"))
    case .map(let map):
      var entries: [(key: [UInt8], value: [UInt8])] = []
      let failure = map.firstNonNil { key -> FormatError? in
        guard let value = map.value(forKey: key) else {
          return FormatError("key missing from map: '\(key)'")
        }
        var k: [UInt8] = []
        var v: [UInt8] = []
        if let err = append(&k, key.value) {
          return err
        }
        if let err = append(&v, value) {
          return err
        }
        entries.append((k, v))
        return nil
      }
      if let failure {
        return failure
      }
      // sort.SliceStable by the formatted key, compared as Go strings (bytes).
      let sorted = entries.enumerated().sorted { a, b in
        a.element.key.lexicographicallyPrecedes(b.element.key)
          || (a.element.key == b.element.key && a.offset < b.offset)
      }
      out.append(UInt8(ascii: "{"))
      for (i, entry) in sorted.enumerated() {
        if i > 0 {
          out += Array(", ".utf8)
        }
        out += entry.element.key
        out += Array(": ".utf8)
        out += entry.element.value
      }
      out.append(UInt8(ascii: "}"))
    default:
      return FormatErrors.string(FormatError.runtimeID, arg.runtimeTypeName)
    }
    return nil
  }

  /// `strconv.FormatFloat(d, 'f', -1, 64)` with cel-spec names for the special values.
  static func shortestDouble(_ d: Double) -> String {
    if d.isNaN {
      return "NaN"
    }
    if d.isInfinite {
      return d < 0 ? "-Infinity" : "Infinity"
    }
    return GoFloat.shortestFixed(d)
  }

  private static func special(_ d: Double) -> String? {
    if d.isNaN {
      return "NaN"
    }
    if d.isInfinite {
      return d < 0 ? "-Infinity" : "Infinity"
    }
    return nil
  }

  static func decimal(_ arg: Value) -> Result<String, FormatError> {
    switch arg {
    case .int(let i): .success(String(i))
    case .uint(let u): .success(String(u))
    case .double(let d): .success(shortestDouble(d))
    default: .failure(FormatErrors.decimal(FormatError.runtimeID, arg.runtimeTypeName, v2: true))
    }
  }

  static func fixed(_ arg: Value, precision: Int) -> Result<String, FormatError> {
    switch arg {
    case .int(let i): .success(GoFloat.fixed(Double(i), precision: precision))
    case .uint(let u): .success(GoFloat.fixed(Double(u), precision: precision))
    case .double(let d): .success(special(d) ?? GoFloat.fixed(d, precision: precision))
    default: .failure(FormatErrors.fixedPoint(FormatError.runtimeID, arg.runtimeTypeName, v2: true))
    }
  }

  static func scientific(_ arg: Value, precision: Int) -> Result<String, FormatError> {
    switch arg {
    case .int(let i): .success(GoFloat.scientific(Double(i), precision: precision))
    case .uint(let u): .success(GoFloat.scientific(Double(u), precision: precision))
    case .double(let d): .success(special(d) ?? GoFloat.scientific(d, precision: precision))
    default: .failure(FormatErrors.scientific(FormatError.runtimeID, arg.runtimeTypeName, v2: true))
    }
  }

  static func binary(_ arg: Value) -> Result<String, FormatError> {
    switch arg {
    case .bool(let b): .success(b ? "1" : "0")
    case .int(let i): .success(GoInt.format(i, radix: 2))
    case .uint(let u): .success(GoInt.format(u, radix: 2))
    default: .failure(FormatErrors.binary(FormatError.runtimeID, arg.runtimeTypeName, v2: true))
    }
  }

  static func hex(_ arg: Value, uppercase: Bool) -> Result<String, FormatError> {
    switch arg {
    case .int(let i): .success(GoInt.format(i, radix: 16, uppercase: uppercase))
    case .uint(let u): .success(GoInt.format(u, radix: 16, uppercase: uppercase))
    case .string(let s): .success(GoInt.hex(s.utf8, uppercase: uppercase))
    case .bytes(let b): .success(GoInt.hex(b, uppercase: uppercase))
    default: .failure(FormatErrors.hex(FormatError.runtimeID, arg.runtimeTypeName, v2: true))
    }
  }

  static func octal(_ arg: Value) -> Result<String, FormatError> {
    switch arg {
    case .int(let i): .success(GoInt.format(i, radix: 8))
    case .uint(let u): .success(GoInt.format(u, radix: 8))
    default: .failure(FormatErrors.octal(FormatError.runtimeID, arg.runtimeTypeName, v2: true))
    }
  }
}
