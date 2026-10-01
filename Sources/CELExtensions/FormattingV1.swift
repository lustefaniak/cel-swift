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
// Ported from cel-go ext/formatting.go (stringFormatter, FormatString, formatList, formatMap,
// quoteForCEL): the runtime clauses of `string.format` for strings versions 1 to 3.
//
// `%f` and `%e` go through golang.org/x/text/message, which formats numbers with the locale's
// CLDR symbols. Only the en-US symbols are ported (see docs/divergences.md); the quirks of the
// x/text printer are kept: `%e` ignores the precision for digits (cel-go builds `%<p>e`, a width,
// so there are always six fraction digits and the precision only pads), negative zero prints
// without its sign, and exponents use superscript digits.

import CEL

/// The `string.format` implementation of strings versions 1 to 3.
enum FormatterV1 {
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
    case .string: formatString(arg)
    case .decimal: decimal(arg)
    case .fixed(let precision): fixed(arg, precision: precision ?? 6)
    case .scientific(let precision): scientific(arg, width: precision ?? 6)
    case .binary: binary(arg)
    case .hex(let uppercase): hex(arg, uppercase: uppercase)
    case .octal: octal(arg)
    }
  }

  /// `%s`: port of `FormatString`.
  static func formatString(_ arg: Value) -> Result<String, FormatError> {
    switch arg {
    case .list:
      return formatList(arg)
    case .map:
      return formatMap(arg)
    case .int, .uint, .double, .bool, .string, .timestamp, .bytes, .duration, .type:
      let converted = arg.convert(to: .string)
      guard case .string(let s) = converted else {
        return .failure(FormatError("could not convert argument \(GoFormat.quote(converted.description)) to string"))
      }
      return .success(s)
    case .null:
      return .success("null")
    default:
      return .failure(FormatErrors.string(FormatError.runtimeID, arg.runtimeTypeName))
    }
  }

  /// Port of `clauseForType`: how list elements and map values are formatted.
  private static func formatMember(_ arg: Value) -> Result<String, FormatError> {
    switch arg {
    case .int, .uint:
      return decimal(arg)
    case .string, .bytes, .bool, .null, .type:
      return formatString(arg)
    case .timestamp:
      guard case .string(let s) = arg.convert(to: .string) else { return .success("") }
      return .success("timestamp(\(GoFormat.quote(s)))")
    case .duration:
      guard case .string(let s) = arg.convert(to: .string) else { return .success("") }
      return .success("duration(\(GoFormat.quote(s)))")
    case .list:
      return formatList(arg)
    case .map:
      return formatMap(arg)
    case .double(let d):
      // Plain Go `%.6f`, so the result is a valid CEL literal whatever the locale.
      return .success(goFixed(d, precision: 6))
    default:
      return .failure(FormatError("no formatting function for \(arg.runtimeTypeName)"))
    }
  }

  /// Go `fmt.Sprintf("%.Nf")`, including Go's names for the special values.
  private static func goFixed(_ d: Double, precision: Int) -> String {
    if d.isNaN {
      return "NaN"
    }
    if d.isInfinite {
      return d < 0 ? "-Inf" : "+Inf"
    }
    return GoFloat.fixed(d, precision: precision)
  }

  /// Port of `quoteForCEL`.
  private static func quoteForCEL(_ value: Value, _ unquoted: String) -> String {
    switch value {
    case .string:
      return GoFormat.quote(unquoted)
    case .bytes:
      return "b" + GoFormat.quote(unquoted)
    case .double(let d) where d.isNaN || d.isInfinite:
      return GoFormat.quote(unquoted)
    default:
      return unquoted
    }
  }

  private static func formatList(_ arg: Value) -> Result<String, FormatError> {
    guard case .list(let list) = arg else { return .success("") }
    var out = "["
    for i in 0..<list.count {
      let member = list.element(at: i)
      switch formatMember(member) {
      case .success(let s): out += quoteForCEL(member, s)
      case .failure(let err): return .failure(err)
      }
      if i + 1 < list.count {
        out += ", "
      }
    }
    out += "]"
    return .success(out)
  }

  private static func formatMap(_ arg: Value) -> Result<String, FormatError> {
    guard case .map(let map) = arg else { return .success("") }
    var pairs: [(key: String, value: String)] = []
    let failure = map.firstNonNil { key -> FormatError? in
      let keyValue = key.value
      let unquotedKey: Result<String, FormatError>
      switch keyValue {
      case .string, .bool: unquotedKey = formatString(keyValue)
      case .int, .uint: unquotedKey = decimal(keyValue)
      default:
        return FormatError("no formatting function for map key of type \(keyValue.runtimeTypeName)")
      }
      let keyStr: String
      switch unquotedKey {
      case .success(let s): keyStr = quoteForCEL(keyValue, s)
      case .failure(let err): return err
      }
      guard let value = map.value(forKey: key) else {
        return FormatError("could not find key: \(GoFormat.quote(key.description))")
      }
      switch formatMember(value) {
      case .success(let s): pairs.append((keyStr, quoteForCEL(value, s)))
      case .failure(let err): return err
      }
      return nil
    }
    if let failure {
      return .failure(failure)
    }
    let sorted = pairs.enumerated().sorted { a, b in
      let ka = Array(a.element.key.utf8)
      let kb = Array(b.element.key.utf8)
      return ka.lexicographicallyPrecedes(kb) || (ka == kb && a.offset < b.offset)
    }
    return .success(
      "{" + sorted.map { "\($0.element.key):\($0.element.value)" }.joined(separator: ", ") + "}")
  }

  static func decimal(_ arg: Value) -> Result<String, FormatError> {
    switch arg {
    case .int(let i): .success(String(i))
    case .uint(let u): .success(String(u))
    default: .failure(FormatErrors.decimal(FormatError.runtimeID, arg.runtimeTypeName, v2: false))
    }
  }

  /// The double for `%f` / `%e`: a double, or one of the strings `NaN`, `Infinity`, `-Infinity`.
  private static func floatArgument(_ arg: Value) -> Double? {
    switch arg {
    case .double(let d):
      return d
    case .string("NaN"):
      return .nan
    case .string("Infinity"):
      return .infinity
    case .string("-Infinity"):
      return -.infinity
    default:
      return nil
    }
  }

  static func fixed(_ arg: Value, precision: Int) -> Result<String, FormatError> {
    guard let d = floatArgument(arg) else {
      return .failure(FormatErrors.fixedPoint(FormatError.runtimeID, arg.runtimeTypeName, v2: false))
    }
    return .success(LocaleNumber.fixed(d, precision: precision))
  }

  static func scientific(_ arg: Value, width: Int) -> Result<String, FormatError> {
    guard let d = floatArgument(arg) else {
      return .failure(FormatErrors.scientific(FormatError.runtimeID, arg.runtimeTypeName, v2: false))
    }
    return .success(LocaleNumber.scientific(d, width: width))
  }

  static func binary(_ arg: Value) -> Result<String, FormatError> {
    switch arg {
    case .int(let i): .success(GoInt.format(i, radix: 2))
    case .uint(let u): .success(GoInt.format(u, radix: 2))
    case .bool(let b): .success(b ? "1" : "0")
    default: .failure(FormatErrors.binary(FormatError.runtimeID, arg.runtimeTypeName, v2: false))
    }
  }

  static func hex(_ arg: Value, uppercase: Bool) -> Result<String, FormatError> {
    switch arg {
    case .string(let s): .success(GoInt.hex(s.utf8, uppercase: uppercase))
    case .bytes(let b): .success(GoInt.hex(b, uppercase: uppercase))
    case .int(let i): .success(GoInt.format(i, radix: 16, uppercase: uppercase))
    case .uint(let u): .success(GoInt.format(u, radix: 16, uppercase: uppercase))
    default: .failure(FormatErrors.hex(FormatError.runtimeID, arg.runtimeTypeName, v2: false))
    }
  }

  static func octal(_ arg: Value) -> Result<String, FormatError> {
    switch arg {
    case .int(let i): .success(GoInt.format(i, radix: 8))
    case .uint(let u): .success(GoInt.format(u, radix: 8))
    default: .failure(FormatErrors.octal(FormatError.runtimeID, arg.runtimeTypeName, v2: false))
    }
  }
}

/// golang.org/x/text/message number formatting with the en-US symbols.
enum LocaleNumber {
  private static let superscripts: [Character] = ["⁰", "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹"]

  /// `message.Printer.Sprintf("%.<precision>f", d)`.
  static func fixed(_ d: Double, precision: Int) -> String {
    if d.isNaN {
      return "NaN"
    }
    if d.isInfinite {
      return d < 0 ? "-∞" : "∞"
    }
    var dec = ExactDecimal(Swift.abs(d))
    dec.round(toDigits: dec.decimalPoint + precision)
    var integer: [UInt8] = []
    if dec.decimalPoint > 0 {
      for i in 0..<dec.decimalPoint {
        integer.append(dec.digit(i))
      }
    } else {
      integer.append(UInt8(ascii: "0"))
    }
    var out = d < 0 ? "-" : ""
    out += grouped(integer)
    if precision > 0 {
      var fraction: [UInt8] = []
      for i in 0..<precision {
        fraction.append(dec.digit(dec.decimalPoint + i))
      }
      out += "." + String(decoding: fraction, as: UTF8.self)
    }
    return out
  }

  /// Groups integer digits in threes with `,`.
  private static func grouped(_ digits: [UInt8]) -> String {
    var out: [UInt8] = []
    for (i, digit) in digits.enumerated() {
      if i > 0 && (digits.count - i) % 3 == 0 {
        out.append(UInt8(ascii: ","))
      }
      out.append(digit)
    }
    return String(decoding: out, as: UTF8.self)
  }

  /// `message.Printer.Sprintf("%<width>e", d)`: six fraction digits, `× 10` and a superscript
  /// exponent of at least two digits, padded on the left with spaces to `width` characters.
  static func scientific(_ d: Double, width: Int) -> String {
    let body: String
    if d.isNaN {
      body = "NaN"
    } else if d.isInfinite {
      body = d < 0 ? "-∞" : "∞"
    } else {
      var dec = ExactDecimal(Swift.abs(d))
      dec.round(toDigits: 7)
      var mantissa: [UInt8] = [dec.digits.isEmpty ? UInt8(ascii: "0") : dec.digits[0]]
      mantissa.append(UInt8(ascii: "."))
      for i in 1...6 {
        mantissa.append(dec.digit(i))
      }
      var exp = dec.digits.isEmpty ? 0 : dec.decimalPoint - 1
      var exponent = ""
      if exp < 0 {
        exponent = "⁻"
        exp = -exp
      }
      let expDigits = exp < 10 ? "0\(exp)" : String(exp)
      exponent += String(expDigits.unicodeScalars.map { superscripts[Int($0.value) - 48] })
      body = (d < 0 ? "-" : "") + String(decoding: mantissa, as: UTF8.self)
        + "\u{202F}×\u{202F}10" + exponent
    }
    let length = body.unicodeScalars.count
    return length < width ? String(repeating: " ", count: width - length) + body : body
  }
}
