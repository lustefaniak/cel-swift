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
// Ported from cel-go ext/formatting.go and ext/formatting_v2.go: the format string parser shared by
// both versions (parseFormatString, parseAndFormatClause, parseFormattingClause, parsePrecision)
// and the error types. The clause implementations are in FormattingV1.swift and FormattingV2.swift.
//
// cel-go drives the parser with an interpolator interface implemented twice, once to format values
// at runtime and once to type-check literal arguments in an AST validator. Here the parser hands
// each clause to a closure, which either formats the argument or checks it.

import CEL

/// A formatting clause of `string.format`, with its precision when one was given.
enum FormatClause: Equatable {
  /// `%s`.
  case string
  /// `%d`.
  case decimal
  /// `%f` / `%.Nf`.
  case fixed(precision: Int?)
  /// `%e` / `%.Ne`.
  case scientific(precision: Int?)
  /// `%b`.
  case binary
  /// `%x` / `%X`.
  case hex(uppercase: Bool)
  /// `%o`.
  case octal
}

/// A formatting error. `exprID` points at the offending argument when the AST validator knows it,
/// and is `runtimeID` (-1) at runtime (cel-go `formatError` and `parseFormatError`).
struct FormatError: Error {
  /// cel-go's `runtimeID`.
  static let runtimeID: Int64 = -1

  var exprID: Int64?
  var message: String

  init(_ message: String, exprID: Int64? = nil) {
    self.message = message
    self.exprID = exprID
  }

  /// Wraps the error with a prefix, keeping its expression id (cel-go `newParseFormatError`).
  func wrapped(_ prefix: String) -> FormatError {
    FormatError("\(prefix): \(message)", exprID: exprID)
  }
}

/// Parses a format string and builds the result, asking `formatArgument` for each clause.
///
/// - Parameters:
///   - format: the format string.
///   - argumentCount: the number of arguments in the list.
///   - maxPrecision: the precision limit, 0 for none.
///   - requestArgument: called with each argument index before the clause is parsed (cel-go
///     `formatListArgs.Arg`); returns an error for indexes the runtime list does not have.
///   - formatArgument: formats (or checks) the argument at an index with a clause.
/// - Returns: the formatted string.
func parseFormatString(
  _ format: String,
  argumentCount: Int,
  maxPrecision: Int,
  requestArgument: (Int) -> FormatError?,
  formatArgument: (Int, FormatClause) -> Result<String, FormatError>
) -> Result<String, FormatError> {
  let bytes = Array(format.utf8)
  var i = 0
  var argIndex = 0
  var built: [UInt8] = []
  built.reserveCapacity(bytes.count)
  while i < bytes.count {
    if bytes[i] != UInt8(ascii: "%") {
      built.append(bytes[i])
      i += 1
      continue
    }
    if i + 1 < bytes.count && bytes[i + 1] == UInt8(ascii: "%") {
      built.append(UInt8(ascii: "%"))
      i += 2
      continue
    }
    if let err = requestArgument(argIndex) {
      return .failure(err)
    }
    if i + 1 >= bytes.count {
      return .failure(FormatError("unexpected end of string"))
    }
    if argIndex >= argumentCount {
      return .failure(FormatError("index \(argIndex) out of range"))
    }
    // parseAndFormatClause
    let clause: (read: Int, clause: FormatClause)
    switch parseFormattingClause(bytes[(i + 1)...], maxPrecision: maxPrecision) {
    case .success(let parsed): clause = parsed
    case .failure(let err): return .failure(err.wrapped("could not parse formatting clause"))
    }
    switch formatArgument(argIndex, clause.clause) {
    case .success(let s): built += Array(s.utf8)
    case .failure(let err): return .failure(err.wrapped("error during formatting"))
    }
    i += 1 + clause.read
    argIndex += 1
  }
  return .success(String(decoding: built, as: UTF8.self))
}

/// Port of `parseFormattingClause`: the precision, then the verb.
private func parseFormattingClause(
  _ format: ArraySlice<UInt8>, maxPrecision: Int
) -> Result<(read: Int, clause: FormatClause), FormatError> {
  let precision: (read: Int, value: Int?)
  switch parsePrecision(format, maxPrecision: maxPrecision) {
  case .success(let p): precision = p
  case .failure(let err): return .failure(err.wrapped("error while parsing precision"))
  }
  let index = format.startIndex + precision.read
  guard index < format.endIndex else {
    // Unreachable in cel-go: parsePrecision fails first when the string ends inside it.
    return .failure(FormatError("unexpected end of string"))
  }
  // cel-go reads a single byte and converts it to a rune, so a multi-byte character reports its
  // first byte as a Latin-1 character.
  let verb = format[index]
  let read = precision.read + 1
  switch verb {
  case UInt8(ascii: "s"): return .success((read, .string))
  case UInt8(ascii: "d"): return .success((read, .decimal))
  case UInt8(ascii: "f"): return .success((read, .fixed(precision: precision.value)))
  case UInt8(ascii: "e"): return .success((read, .scientific(precision: precision.value)))
  case UInt8(ascii: "b"): return .success((read, .binary))
  case UInt8(ascii: "x"): return .success((read, .hex(uppercase: false)))
  case UInt8(ascii: "X"): return .success((read, .hex(uppercase: true)))
  case UInt8(ascii: "o"): return .success((read, .octal))
  default:
    let char = String(Character(Unicode.Scalar(verb)))
    return .failure(FormatError("unrecognized formatting clause \"\(char)\""))
  }
}

/// Port of `parsePrecision`: `nil` when the clause has no `.N`.
private func parsePrecision(
  _ format: ArraySlice<UInt8>, maxPrecision: Int
) -> Result<(read: Int, value: Int?), FormatError> {
  var i = format.startIndex
  if format[i] != UInt8(ascii: ".") {
    return .success((0, nil))
  }
  i += 1
  var digits: [UInt8] = []
  while true {
    if i >= format.endIndex {
      return .failure(FormatError("could not find end of precision specifier"))
    }
    if !(UInt8(ascii: "0")...UInt8(ascii: "9")).contains(format[i]) {
      break
    }
    digits.append(format[i])
    i += 1
  }
  let text = String(decoding: digits, as: UTF8.self)
  guard let precision = Int(text) else {
    let reason = digits.isEmpty ? "invalid syntax" : "value out of range"
    return .failure(
      FormatError(
        "error while converting precision to integer: strconv.Atoi: parsing \"\(text)\": \(reason)"))
  }
  if maxPrecision > 0 && precision > maxPrecision {
    return .failure(
      FormatError("precision \(precision) exceeds maximum allowed precision \(maxPrecision)"))
  }
  return .success((i - format.startIndex, precision))
}

// MARK: - Error messages shared by the runtime and the validator

enum FormatErrors {
  static func binary(_ id: Int64, _ badType: String, v2: Bool) -> FormatError {
    FormatError(
      v2
        ? "only ints, uints, and bools can be formatted as binary, was given \(badType)"
        : "only integers and bools can be formatted as binary, was given \(badType)", exprID: id)
  }

  static func decimal(_ id: Int64, _ badType: String, v2: Bool) -> FormatError {
    FormatError(
      v2
        ? "decimal clause can only be used on ints, uints, and doubles, was given \(badType)"
        : "decimal clause can only be used on integers, was given \(badType)", exprID: id)
  }

  static func fixedPoint(_ id: Int64, _ badType: String, v2: Bool) -> FormatError {
    FormatError(
      v2
        ? "fixed-point clause can only be used on ints, uints, and doubles, was given \(badType)"
        : "fixed-point clause can only be used on doubles, was given \(badType)", exprID: id)
  }

  static func hex(_ id: Int64, _ badType: String, v2: Bool) -> FormatError {
    FormatError(
      v2
        ? "only ints, uints, bytes, and strings can be formatted as hex, was given \(badType)"
        : "only integers, byte buffers, and strings can be formatted as hex, was given \(badType)",
      exprID: id)
  }

  static func octal(_ id: Int64, _ badType: String, v2: Bool) -> FormatError {
    FormatError(
      v2
        ? "octal clause can only be used on ints and uints, was given \(badType)"
        : "octal clause can only be used on integers, was given \(badType)", exprID: id)
  }

  static func scientific(_ id: Int64, _ badType: String, v2: Bool) -> FormatError {
    FormatError(
      v2
        ? "scientific clause can only be used on ints, uints, and doubles, was given \(badType)"
        : "scientific clause can only be used on doubles, was given \(badType)", exprID: id)
  }

  static func string(_ id: Int64, _ badType: String) -> FormatError {
    FormatError(
      "string clause can only be used on strings, bools, bytes, ints, doubles, maps, lists, types, "
        + "durations, and timestamps, was given \(badType)", exprID: id)
  }
}

// MARK: - Integer formatting shared by both versions

enum GoInt {
  /// Go `strconv.FormatInt` / `%x` / `%o` / `%b` of a signed integer: a `-` sign and the magnitude.
  static func format(_ value: Int64, radix: Int, uppercase: Bool = false) -> String {
    String(value, radix: radix, uppercase: uppercase)
  }

  static func format(_ value: UInt64, radix: Int, uppercase: Bool = false) -> String {
    String(value, radix: radix, uppercase: uppercase)
  }

  /// Go `%x` / `%X` of a string or byte slice: two hex digits per byte.
  static func hex(_ bytes: some Sequence<UInt8>, uppercase: Bool) -> String {
    let table = Array((uppercase ? "0123456789ABCDEF" : "0123456789abcdef").utf8)
    var out: [UInt8] = []
    for b in bytes {
      out.append(table[Int(b >> 4)])
      out.append(table[Int(b & 0xF)])
    }
    return String(decoding: out, as: UTF8.self)
  }
}

/// The formatted runtime arguments of `string.format`, the port of `stringArgList`.
struct FormatArguments {
  let list: any ListValue

  func requestArgument(_ index: Int) -> FormatError? {
    index >= list.count ? FormatError("index \(index) out of range") : nil
  }
}
