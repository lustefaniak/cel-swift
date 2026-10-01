// Copyright 2025 Google LLC
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
// Ported from cel-go ext/regex.go: `regex.extract`, `regex.extractAll` and `regex.replace`, on
// CELRegex (the port of Go's regexp). Cost estimators and trackers are not ported yet.

import CEL
import CELRegex

extension Library {
  /// The regex extension library: `regex.extract`, `regex.extractAll` and `regex.replace`, with
  /// RE2 syntax and linear-time matching.
  ///
  /// `regex.extract` returns an optional, so an environment using this library must also enable
  /// optional types.
  public static var regex: Library { regex() }

  /// The regex extension library at a given version (only version 0 exists).
  ///
  /// - Parameter version: the library version.
  public static func regex(version: UInt32 = Library.latestVersion) -> Library {
    let decls = makeDeclarations([
      try FunctionDecl(
        "regex.extract",
        .overload(
          "regex_extract_string_string", argTypes: [.string, .string],
          resultType: .optional(.string),
          .binaryBinding { target, pattern in
            guard case .string(let t) = target, case .string(let p) = pattern else {
              return noSuchOverload(target, pattern)
            }
            return regexExtract(t, p)
          })),
      try FunctionDecl(
        "regex.extractAll",
        .overload(
          "regex_extractAll_string_string", argTypes: [.string, .string],
          resultType: .list(.string),
          .binaryBinding { target, pattern in
            guard case .string(let t) = target, case .string(let p) = pattern else {
              return noSuchOverload(target, pattern)
            }
            return regexExtractAll(t, p)
          })),
      try FunctionDecl(
        "regex.replace",
        .overload(
          "regex_replace_string_string_string", argTypes: [.string, .string, .string],
          resultType: .string,
          .functionBinding { args in
            guard args.count == 3, case .string(let t) = args[0], case .string(let p) = args[1],
              case .string(let r) = args[2]
            else { return .noSuchOverload }
            return regexReplace(t, p, r, -1)
          }),
        .overload(
          "regex_replace_string_string_string_int", argTypes: [.string, .string, .string, .int],
          resultType: .string,
          .functionBinding { args in
            guard args.count == 4, case .string(let t) = args[0], case .string(let p) = args[1],
              case .string(let r) = args[2], case .int(let n) = args[3]
            else { return .noSuchOverload }
            return regexReplace(t, p, r, n)
          })),
    ])
    return Library(
      name: "cel.lib.ext.regex", alias: "regex", version: version, functions: decls,
      requiredLibraries: [
        (name: "cel.lib.optional", error: "regex library requires the optional library")
      ])
  }
}

private func compile(_ pattern: String) -> Result<Regexp, EvalError> {
  do {
    return .success(try Regexp.compile(pattern))
  } catch {
    return .failure(EvalError(error.description))
  }
}

/// Port of `regReplaceN`.
func regexReplace(_ target: String, _ pattern: String, _ replacement: String, _ count: Int64) -> Value {
  if count == 0 {
    return .string(target)
  }
  let limit = count < 0 ? -1 : count
  let re: Regexp
  switch compile(pattern) {
  case .success(let r): re = r
  case .failure(let e): return .error(e)
  }
  let bytes = Array(target.utf8)
  var out: [UInt8] = []
  var lastIndex = 0
  var counter: Int64 = 0
  for match in re.findAllStringSubmatchIndex(target, -1) {
    if limit != -1 && counter >= limit {
      break
    }
    let processed: [UInt8]
    switch expandReplacement(bytes, re, match, replacement) {
    case .success(let p): processed = p
    case .failure(let e): return .error(e)
    }
    out += bytes[lastIndex..<match[0]]
    out += processed
    lastIndex = match[1]
    counter += 1
  }
  out += bytes[lastIndex...]
  return .string(String(decoding: out, as: UTF8.self))
}

/// Port of `replaceStrValidator`: `\N` inserts group N, `\\` a backslash.
private func expandReplacement(
  _ target: [UInt8], _ re: Regexp, _ match: [Int], _ replacement: String
) -> Result<[UInt8], EvalError> {
  let groupCount = re.numSubexp
  let runes = Array(replacement.unicodeScalars)
  var out = String.UnicodeScalarView()
  var bytes: [UInt8] = []
  func flush() {
    bytes += Array(String(out).utf8)
    out = String.UnicodeScalarView()
  }
  var i = 0
  while i < runes.count {
    let c = runes[i]
    if c != "\\" {
      out.append(c)
      i += 1
      continue
    }
    if i + 1 >= runes.count {
      return .failure(EvalError("invalid replacement string: '\(replacement)' \\ not allowed at end"))
    }
    i += 1
    let next = runes[i]
    i += 1
    if next == "\\" {
      out.append("\\")
      continue
    }
    guard next.value >= 0x30 && next.value <= 0x39 else {
      return .failure(
        EvalError("invalid replacement string: '\(replacement)' \\ must be followed by a digit or \\"))
    }
    let group = Int(next.value - 0x30)
    if group > groupCount {
      return .failure(
        EvalError(
          "replacement string references group \(group) but regex has only \(groupCount) group(s)"))
    }
    if match[2 * group] != -1 {
      flush()
      bytes += target[match[2 * group]..<match[2 * group + 1]]
    }
  }
  flush()
  return .success(bytes)
}

/// Port of `extract`.
func regexExtract(_ target: String, _ pattern: String) -> Value {
  let re: Regexp
  switch compile(pattern) {
  case .success(let r): re = r
  case .failure(let e): return .error(e)
  }
  if re.subexpNames.count - 1 > 1 {
    return errorValue("regular expression has more than one capturing group: \(GoFormat.quote(pattern))")
  }
  guard let matches = re.findStringSubmatch(target), !matches.isEmpty else {
    return .optional(nil)
  }
  // With a capturing group, return the group; an empty group is no match.
  if matches.count > 1 {
    return matches[1].isEmpty ? .optional(nil) : .optional(.string(matches[1]))
  }
  return .optional(.string(matches[0]))
}

/// Port of `extractAll`.
func regexExtractAll(_ target: String, _ pattern: String) -> Value {
  let re: Regexp
  switch compile(pattern) {
  case .success(let r): re = r
  case .failure(let e): return .error(e)
  }
  let groupCount = re.subexpNames.count - 1
  if groupCount > 1 {
    return errorValue("regular expression has more than one capturing group: \(GoFormat.quote(pattern))")
  }
  let matches = re.findAllStringSubmatch(target, -1)
  if groupCount != 1 {
    return .list(ArrayList(matches.map { .string($0[0]) }))
  }
  return .list(ArrayList(matches.compactMap { $0[1].isEmpty ? nil : .string($0[1]) }))
}
