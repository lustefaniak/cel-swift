// Copyright 2020 Google LLC
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
// Ported from cel-go ext/strings.go. The cost estimators and trackers (version 5) are in
// StringsCosts.swift.

import CEL

extension Library {
  /// The strings extension library at its latest version: `charAt`, `indexOf`, `lastIndexOf`,
  /// `lowerAscii`, `upperAscii`, `replace`, `split`, `substring`, `trim`, `join`, `format`,
  /// `strings.quote` and `reverse`.
  ///
  /// All indices count Unicode code points and are zero-based.
  public static var strings: Library { strings() }

  /// The strings extension library at a given version.
  ///
  /// Version 1 adds `format` and `strings.quote`, version 2 lets `join` accept lists that are only
  /// known to hold strings at runtime, version 3 adds `reverse`, version 4 switches `format` to the
  /// cel-spec formatting rules, and version 5 limits the `format` precision to 100 by default.
  ///
  /// - Parameters:
  ///   - version: the library version; ``Library/latestVersion`` enables everything.
  ///   - locale: the locale for `%f` and `%e` before version 4, for example `en_US`. Ignored from
  ///     version 4.
  ///   - maxPrecision: the largest precision a `format` clause may use; `0` means 100 from version
  ///     5 and no limit before.
  public static func strings(
    version: UInt32 = Library.latestVersion, locale: String? = nil, maxPrecision: Int = 0
  ) -> Library {
    StringsLibrary(version: version, locale: locale, maxPrecision: maxPrecision).library
  }
}

/// Port of cel-go `stringLib`.
struct StringsLibrary {
  let version: UInt32
  let locale: String?
  let maxPrecision: Int

  var library: Library {
    var lib = Library(
      name: "cel.lib.ext.strings", alias: "strings", version: version,
      functions: makeDeclarations(try functions()),
      homogeneousLiteralExemptFunctions: version >= 1 ? ["format"] : [])
    if version >= 1 {
      lib.validators = [FormatValidator.make(maxPrecision: effectiveMaxPrecision, v2: version >= 4)]
    }
    if version >= 5 {
      lib = lib.withCosts(estimators: StringsCosts.estimators, trackers: StringsCosts.trackers)
    }
    return lib
  }

  /// Unbounded (0) before version 5; from version 5 the default is 100.
  var effectiveMaxPrecision: Int {
    maxPrecision == 0 && version >= 5 ? 100 : maxPrecision
  }

  // swift-format-ignore: FunctionLength
  private func functions() throws -> [FunctionDecl] {
    var decls: [FunctionDecl] = [
      try FunctionDecl(
        "charAt",
        .memberOverload(
          "string_char_at_int", argTypes: [.string, .int], resultType: .string,
          .binaryBinding { str, ind in
            guard case .string(let s) = str, case .int(let i) = ind else {
              return noSuchOverload(str, ind)
            }
            return stringOrError(charAt(s, i))
          })),
      try FunctionDecl(
        "indexOf",
        .memberOverload(
          "string_index_of_string", argTypes: [.string, .string], resultType: .int,
          .binaryBinding { str, sub in
            guard case .string(let s) = str, case .string(let sub) = sub else {
              return noSuchOverload(str, sub)
            }
            return intOrError(indexOf(s, sub, 0))
          }),
        .memberOverload(
          "string_index_of_string_int", argTypes: [.string, .string, .int], resultType: .int,
          .functionBinding { args in
            guard args.count == 3, case .string(let s) = args[0], case .string(let sub) = args[1],
              case .int(let offset) = args[2]
            else { return .noSuchOverload }
            return intOrError(indexOf(s, sub, offset))
          })),
      try FunctionDecl(
        "lastIndexOf",
        .memberOverload(
          "string_last_index_of_string", argTypes: [.string, .string], resultType: .int,
          .binaryBinding { str, sub in
            guard case .string(let s) = str, case .string(let sub) = sub else {
              return noSuchOverload(str, sub)
            }
            return intOrError(lastIndexOf(s, sub))
          }),
        .memberOverload(
          "string_last_index_of_string_int", argTypes: [.string, .string, .int], resultType: .int,
          .functionBinding { args in
            guard args.count == 3, case .string(let s) = args[0], case .string(let sub) = args[1],
              case .int(let offset) = args[2]
            else { return .noSuchOverload }
            return intOrError(lastIndexOf(s, sub, offset))
          })),
      try FunctionDecl(
        "lowerAscii",
        .memberOverload(
          "string_lower_ascii", argTypes: [.string], resultType: .string,
          .unaryBinding { str in
            guard case .string(let s) = str else { return noSuchOverload(str) }
            return .string(mapASCII(s, lower: true))
          })),
      try FunctionDecl(
        "replace",
        .memberOverload(
          "string_replace_string_string", argTypes: [.string, .string, .string],
          resultType: .string,
          .functionBinding { args in
            guard args.count == 3, case .string(let s) = args[0], case .string(let old) = args[1],
              case .string(let new) = args[2]
            else { return .noSuchOverload }
            return .string(GoStrings.replace(s, old, new, -1))
          }),
        .memberOverload(
          "string_replace_string_string_int", argTypes: [.string, .string, .string, .int],
          resultType: .string,
          .functionBinding { args in
            guard args.count == 4, case .string(let s) = args[0], case .string(let old) = args[1],
              case .string(let new) = args[2], case .int(let n) = args[3]
            else { return .noSuchOverload }
            return .string(GoStrings.replace(s, old, new, clampToInt(n)))
          })),
      try FunctionDecl(
        "split",
        .memberOverload(
          "string_split_string", argTypes: [.string, .string], resultType: .list(.string),
          .binaryBinding { str, sep in
            guard case .string(let s) = str, case .string(let sep) = sep else {
              return noSuchOverload(str, sep)
            }
            return listStringOrError(.success(GoStrings.split(s, sep, -1)))
          }),
        .memberOverload(
          "string_split_string_int", argTypes: [.string, .string, .int],
          resultType: .list(.string),
          .functionBinding { args in
            guard args.count == 3, case .string(let s) = args[0], case .string(let sep) = args[1],
              case .int(let n) = args[2]
            else { return .noSuchOverload }
            return listStringOrError(.success(GoStrings.split(s, sep, clampToInt(n))))
          })),
      try FunctionDecl(
        "substring",
        .memberOverload(
          "string_substring_int", argTypes: [.string, .int], resultType: .string,
          .binaryBinding { str, offset in
            guard case .string(let s) = str, case .int(let start) = offset else {
              return noSuchOverload(str, offset)
            }
            return stringOrError(substring(s, start))
          }),
        .memberOverload(
          "string_substring_int_int", argTypes: [.string, .int, .int], resultType: .string,
          .functionBinding { args in
            guard args.count == 3, case .string(let s) = args[0], case .int(let start) = args[1],
              case .int(let end) = args[2]
            else { return .noSuchOverload }
            return stringOrError(substring(s, start, end))
          })),
      try FunctionDecl(
        "trim",
        .memberOverload(
          "string_trim", argTypes: [.string], resultType: .string,
          .unaryBinding { str in
            guard case .string(let s) = str else { return noSuchOverload(str) }
            return .string(GoStrings.trimSpace(s))
          })),
      try FunctionDecl(
        "upperAscii",
        .memberOverload(
          "string_upper_ascii", argTypes: [.string], resultType: .string,
          .unaryBinding { str in
            guard case .string(let s) = str else { return noSuchOverload(str) }
            return .string(mapASCII(s, lower: false))
          })),
    ]
    // maxPrecision is unbounded (0) before version 5; from version 5 the default is 100.
    var maxPrecision = self.maxPrecision
    if maxPrecision == 0 && version >= 5 {
      maxPrecision = 100
    }
    if version >= 1 {
      let precision = maxPrecision
      let v2 = version >= 4
      decls.append(
        try FunctionDecl(
          "format",
          .memberOverload(
            "string_format", argTypes: [.string, .list(.dyn)], resultType: .string,
            .functionBinding { args in
              guard args.count == 2, case .string(let s) = args[0], case .list(let list) = args[1]
              else { return .noSuchOverload }
              return v2
                ? FormatterV2.format(s, list, maxPrecision: precision)
                : FormatterV1.format(s, list, maxPrecision: precision)
            })))
      decls.append(
        try FunctionDecl(
          "strings.quote",
          .overload(
            "strings_quote", argTypes: [.string], resultType: .string,
            .unaryBinding { str in
              guard case .string(let s) = str else { return noSuchOverload(str) }
              return .string(quote(s))
            })))
    }
    // From version 2 `join` checks each element at runtime; before, it converts the whole list to
    // a native []string first. Both fail on non-string elements, with different messages.
    let joinChecksElements = version >= 2
    decls.append(
      try FunctionDecl(
        "join",
        .memberOverload(
          "list_join", argTypes: [.list(.string)], resultType: .string,
          .unaryBinding { list in
            guard case .list(let l) = list else { return noSuchOverload(list) }
            return join(l, "", checkElements: joinChecksElements)
          }),
        .memberOverload(
          "list_join_string", argTypes: [.list(.string), .string], resultType: .string,
          .binaryBinding { list, delim in
            guard case .list(let l) = list, case .string(let d) = delim else {
              return noSuchOverload(list, delim)
            }
            return join(l, d, checkElements: joinChecksElements)
          })))
    if version >= 3 {
      decls.append(
        try FunctionDecl(
          "reverse",
          .memberOverload(
            "string_reverse", argTypes: [.string], resultType: .string,
            .unaryBinding { str in
              guard case .string(let s) = str else { return noSuchOverload(str) }
              return .string(String(scalars: s.unicodeScalars.reversed()))
            })))
    }
    return decls
  }
}

/// Builds declarations, turning a declaration error (a bug in the library) into a crash at
/// library construction time, as cel-go reports it from `NewEnv`.
func makeDeclarations(_ make: @autoclosure () throws -> [FunctionDecl]) -> [FunctionDecl] {
  do {
    return try make()
  } catch {
    preconditionFailure("invalid extension declaration: \(error)")
  }
}

/// Converts a CEL int to a Go `int` (64 bits on every supported platform).
func clampToInt(_ value: Int64) -> Int {
  Int(truncatingIfNeeded: value)
}

func charAt(_ str: String, _ ind: Int64) -> Result<String, ExtError> {
  let runes = Array(str.unicodeScalars)
  if ind < 0 || ind > Int64(runes.count) {
    return .failure(ExtError("index out of range: \(ind)"))
  }
  if ind == Int64(runes.count) {
    return .success("")
  }
  return .success(String(Character(runes[Int(ind)])))
}

/// Port of `indexOfOffset`.
func indexOf(_ str: String, _ substr: String, _ offset: Int64) -> Result<Int64, ExtError> {
  if offset < 0 {
    return .failure(ExtError("index out of range: \(offset)"))
  }
  let runes = Array(str.unicodeScalars)
  if substr.isEmpty {
    // The empty string matches at the search offset, clamped to the end of the string.
    return .success(offset > Int64(runes.count) ? Int64(runes.count) : offset)
  }
  let subrunes = Array(substr.unicodeScalars)
  // If the offset exceeds the length, return -1 rather than error.
  if offset >= Int64(runes.count) {
    return .success(-1)
  }
  var i = Int(offset)
  while i < runes.count - (subrunes.count - 1) {
    if runes[i..<(i + subrunes.count)].elementsEqual(subrunes) {
      return .success(Int64(i))
    }
    i += 1
  }
  return .success(-1)
}

/// Port of `lastIndexOf`.
func lastIndexOf(_ str: String, _ substr: String) -> Result<Int64, ExtError> {
  let runeCount = Int64(str.unicodeScalars.count)
  if substr.isEmpty {
    return .success(runeCount)
  }
  // cel-go compares byte lengths here.
  if str.utf8.count < substr.utf8.count {
    return .success(-1)
  }
  return lastIndexOf(str, substr, runeCount - 1)
}

/// Port of `lastIndexOfOffset`.
func lastIndexOf(_ str: String, _ substr: String, _ offset: Int64) -> Result<Int64, ExtError> {
  if offset < 0 {
    return .failure(ExtError("index out of range: \(offset)"))
  }
  let runes = Array(str.unicodeScalars)
  if substr.isEmpty {
    return .success(offset > Int64(runes.count) ? Int64(runes.count) : offset)
  }
  let subrunes = Array(substr.unicodeScalars)
  // If the offset is far greater than the length return -1.
  if offset >= Int64(runes.count) {
    return .success(-1)
  }
  var off = Int(offset)
  if off > runes.count - subrunes.count {
    off = runes.count - subrunes.count
  }
  var i = off
  while i >= 0 {
    if runes[i..<(i + subrunes.count)].elementsEqual(subrunes) {
      return .success(Int64(i))
    }
    i -= 1
  }
  return .success(-1)
}

/// Port of `lowerASCII` / `upperASCII`: maps only the ASCII letters.
func mapASCII(_ str: String, lower: Bool) -> String {
  var out = String.UnicodeScalarView()
  for r in str.unicodeScalars {
    switch r.value {
    case 0x41...0x5A where lower:
      out.append(Unicode.Scalar(r.value + 32) ?? r)
    case 0x61...0x7A where !lower:
      out.append(Unicode.Scalar(r.value - 32) ?? r)
    default:
      out.append(r)
    }
  }
  return String(out)
}

/// Port of `substr` and `substrRange`.
func substring(_ str: String, _ start: Int64, _ end: Int64? = nil) -> Result<String, ExtError> {
  let runes = Array(str.unicodeScalars)
  let l = Int64(runes.count)
  guard let end else {
    if start < 0 || start > l {
      return .failure(ExtError("index out of range: \(start)"))
    }
    return .success(String(scalars: runes[Int(start)...]))
  }
  if start > end {
    return .failure(ExtError("invalid substring range. start: \(start), end: \(end)"))
  }
  if start < 0 || start > l {
    return .failure(ExtError("index out of range: \(start)"))
  }
  if end < 0 || end > l {
    return .failure(ExtError("index out of range: \(end)"))
  }
  return .success(String(scalars: runes[Int(start)..<Int(end)]))
}

/// Port of `joinValSeparator` (version 2 and later) and of the native `[]string` conversion plus
/// `strings.Join` used before.
func join(_ list: any ListValue, _ separator: String, checkElements: Bool) -> Value {
  var out = ""
  for i in 0..<list.count {
    let elem = list.element(at: i)
    guard case .string(let s) = elem else {
      if checkElements {
        return errorValue("join: invalid input: \(formatGoValue(elem))")
      }
      return errorValue(nativeStringConversionError(elem))
    }
    if i != 0 {
      out += separator
    }
    out += s
  }
  return .string(out)
}

/// Port of `quote`: wraps the string in double quotes and escapes the CEL escape sequences.
/// Swift strings hold no invalid UTF-8, so cel-go's `sanitize` step has nothing to replace.
func quote(_ s: String) -> String {
  var out = "\""
  for c in s.unicodeScalars {
    switch c {
    case "\u{07}": out += "\\a"
    case "\u{08}": out += "\\b"
    case "\u{0C}": out += "\\f"
    case "\n": out += "\\n"
    case "\r": out += "\\r"
    case "\t": out += "\\t"
    case "\u{0B}": out += "\\v"
    case "\\": out += "\\\\"
    case "\"": out += "\\\""
    default: out.unicodeScalars.append(c)
    }
  }
  return out + "\""
}

/// The error of cel-go's `ConvertToNative(string)` for a non-string value, as `join` reports it
/// before version 2.
private func nativeStringConversionError(_ value: Value) -> String {
  switch value {
  case .int: "unsupported type conversion from 'int' to string"
  case .uint: "unsupported type conversion from 'uint' to string"
  case .bool: "type conversion error from bool to 'string'"
  case .bytes: "type conversion error from Bytes to 'string'"
  case .double: "type conversion error from Double to 'string'"
  case .duration: "type conversion error from 'Duration' to 'string'"
  case .timestamp: "type conversion error from 'Timestamp' to 'string'"
  case .list: "type conversion error from list to 'string'"
  case .map: "type conversion error from map to 'string'"
  case .null: "type conversion error from 'null_type' to 'string'"
  case .type: "type conversion not supported for 'type'"
  case .error(let e): e.message
  default: "type conversion error from '\(value.runtimeTypeName)' to 'string'"
  }
}
