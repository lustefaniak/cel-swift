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
// Ported from cel-go common/types/string.go (StringContains, StringEndsWith, StringStartsWith,
// Match).
//
// Go compares strings as UTF-8 bytes; Swift's `String.contains` / `hasPrefix` use canonical
// equivalence on `Character`s, so every operation here works on the UTF-8 view.

/// `contains`: whether the string contains the substring. Port of cel-go `StringContains`.
func stringContains(_ s: Value, _ sub: Value) -> Value {
  guard case .string(let str) = s else { return Value.maybeNoSuchOverload(s) }
  guard case .string(let subStr) = sub else { return Value.maybeNoSuchOverload(sub) }
  return .bool(utf8Contains(Array(str.utf8), Array(subStr.utf8)))
}

/// `endsWith`: whether the string ends with the suffix. Port of cel-go `StringEndsWith`.
func stringEndsWith(_ s: Value, _ suffix: Value) -> Value {
  guard case .string(let str) = s else { return Value.maybeNoSuchOverload(s) }
  guard case .string(let suf) = suffix else { return Value.maybeNoSuchOverload(suffix) }
  let a = Array(str.utf8)
  let b = Array(suf.utf8)
  return .bool(a.count >= b.count && a[(a.count - b.count)...].elementsEqual(b))
}

/// `startsWith`: whether the string starts with the prefix. Port of cel-go `StringStartsWith`.
func stringStartsWith(_ s: Value, _ prefix: Value) -> Value {
  guard case .string(let str) = s else { return Value.maybeNoSuchOverload(s) }
  guard case .string(let pre) = prefix else { return Value.maybeNoSuchOverload(prefix) }
  return .bool(str.utf8.starts(with: pre.utf8))
}

/// Byte-wise substring search, as Go `strings.Contains`.
func utf8Contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
  utf8Index(haystack, needle) != nil
}

/// The byte offset of the first occurrence of `needle` in `haystack`, as Go `strings.Index`.
func utf8Index(_ haystack: [UInt8], _ needle: [UInt8]) -> Int? {
  if needle.isEmpty {
    return 0
  }
  if needle.count > haystack.count {
    return nil
  }
  let first = needle[0]
  var i = 0
  let last = haystack.count - needle.count
  while i <= last {
    if haystack[i] == first && haystack[i..<(i + needle.count)].elementsEqual(needle) {
      return i
    }
    i += 1
  }
  return nil
}

extension Value {
  /// `matches`: whether the string matches an RE2 pattern. Port of cel-go `String.Match`.
  ///
  /// - Note: Regular expressions come from `CELRegex`, a port of Go's `regexp`. Until that target
  ///   is wired in, this returns an error value for every call; see ``RegexHook``.
  package func match(_ pattern: Value) -> Value {
    guard case .string(let str) = self else { return .noSuchOverload }
    guard case .string(let pat) = pattern else { return Value.maybeNoSuchOverload(pattern) }
    return RegexHook.matchString(pattern: pat, in: str)
  }
}

/// HOOK: the single place where `matches` reaches a regular expression engine.
///
/// TODO(CELRegex): replace the body with `CELRegex` (`Regexp.compile(pattern)` +
/// `matchString`), returning `.error(EvalError(<Go regexp compile error message>))` on a compile
/// error, once the `CELRegex` target is on `main` and `CEL` depends on it.
enum RegexHook {
  static func matchString(pattern: String, in text: String) -> Value {
    .error(EvalError("matches is not supported: regular expressions require CELRegex"))
  }
}
