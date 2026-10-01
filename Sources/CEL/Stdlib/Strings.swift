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

import CELRegex

/// `contains`: whether the string contains the substring. Port of cel-go `StringContains`.
func stringContains(_ s: Value, _ sub: Value) -> Value {
  guard case .string(let str) = s else { return Value.maybeNoSuchOverload(s) }
  guard case .string(let subStr) = sub else { return Value.maybeNoSuchOverload(sub) }
  return .bool(
    withUTF8Bytes(str) { haystack in
      withUTF8Bytes(subStr) { needle in bytesIndex(haystack, needle) != nil }
    })
}

/// `endsWith`: whether the string ends with the suffix. Port of cel-go `StringEndsWith`.
func stringEndsWith(_ s: Value, _ suffix: Value) -> Value {
  guard case .string(let str) = s else { return Value.maybeNoSuchOverload(s) }
  guard case .string(let suf) = suffix else { return Value.maybeNoSuchOverload(suffix) }
  return .bool(
    withUTF8Bytes(str) { a in
      withUTF8Bytes(suf) { b in
        a.count >= b.count && bytesEqual(UnsafeBufferPointer(rebasing: a[(a.count - b.count)...]), b)
      }
    })
}

/// `startsWith`: whether the string starts with the prefix. Port of cel-go `StringStartsWith`.
func stringStartsWith(_ s: Value, _ prefix: Value) -> Value {
  guard case .string(let str) = s else { return Value.maybeNoSuchOverload(s) }
  guard case .string(let pre) = prefix else { return Value.maybeNoSuchOverload(prefix) }
  return .bool(
    withUTF8Bytes(str) { a in
      withUTF8Bytes(pre) { b in
        a.count >= b.count && bytesEqual(UnsafeBufferPointer(rebasing: a[..<b.count]), b)
      }
    })
}

extension Value {
  /// `matches`: whether the string contains a match of an RE2 pattern, as Go
  /// `regexp.MatchString` (via `CELRegex`). Port of cel-go `String.Match`.
  ///
  /// An invalid pattern is an error value with Go's message, starting `error parsing regexp:`.
  package func match(_ pattern: Value) -> Value {
    guard case .string(let str) = self else { return .noSuchOverload }
    guard case .string(let pat) = pattern else { return Value.maybeNoSuchOverload(pattern) }
    do {
      return .bool(try Regexp.matchString(pat, str))
    } catch {
      return .error(EvalError(error.description))
    }
  }
}
