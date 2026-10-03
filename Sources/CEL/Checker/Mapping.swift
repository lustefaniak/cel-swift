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

// Ported from cel-go checker/mapping.go.

/// Type parameter substitutions, keyed by the formatted type parameter (cel-go `mapping`).
///
/// A value type: cel-go's `copy()` is plain assignment here.
///
/// The checker only adds type parameters, so keys are type parameter names. `find` answers as the
/// formatted lookup would, mostly without formatting or hashing: a type parameter is looked up by its
/// name, a type whose formatted name has parentheses can only match a key with parentheses, which
/// there usually is none of, and other types are looked up only when a key starts with the same byte
/// as their formatted name (keys are names like `_var0` or `T`, concrete types `int` or `bool`).
struct TypeMapping: Sendable {
  private var mapping: [String: CELType] = [:]
  /// Whether a key contains `(`, so that a parameterized type's formatted name could match it.
  private var hasParenthesizedKey = false
  /// The first UTF-8 bytes of the keys, one bit each; bit 0 also stands for the empty key.
  private var keyFirstBytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)

  /// The keys added during `trying`, with their previous values, to undo a failed trial.
  private var undoLog: [(key: String, previous: CELType?)] = []
  private var isTrying = false

  private static func firstByteBit(_ key: String) -> (word: Int, bit: UInt64) {
    let byte = Int(key.utf8.first ?? 0)
    return (byte >> 6, 1 << UInt64(byte & 63))
  }

  private func mayHaveKey(startingLike key: String) -> Bool {
    let (word, bit) = Self.firstByteBit(key)
    switch word {
    case 0: return keyFirstBytes.0 & bit != 0
    case 1: return keyFirstBytes.1 & bit != 0
    case 2: return keyFirstBytes.2 & bit != 0
    default: return keyFirstBytes.3 & bit != 0
    }
  }

  mutating func add(_ from: CELType, _ to: CELType) {
    let key = from.checkerDescription
    if !hasParenthesizedKey && key.utf8.contains(UInt8(ascii: "(")) {
      hasParenthesizedKey = true
    }
    let (word, bit) = Self.firstByteBit(key)
    switch word {
    case 0: keyFirstBytes.0 |= bit
    case 1: keyFirstBytes.1 |= bit
    case 2: keyFirstBytes.2 |= bit
    default: keyFirstBytes.3 |= bit
    }
    let previous = mapping.updateValue(to, forKey: key)
    if isTrying {
      undoLog.append((key, previous))
    }
  }

  /// Runs `body` on the mapping and undoes its additions when it returns false. cel-go copies the
  /// mapping and keeps the copy on success; copying here costs a dictionary copy per unification.
  mutating func trying(_ body: (inout TypeMapping) -> Bool) -> Bool {
    let start = undoLog.count
    let wasTrying = isTrying
    isTrying = true
    let succeeded = body(&self)
    isTrying = wasTrying
    if !succeeded {
      while undoLog.count > start, let (key, previous) = undoLog.popLast() {
        mapping[key] = previous
      }
    } else if !wasTrying {
      undoLog.removeAll(keepingCapacity: true)
    }
    return succeeded
  }

  func find(_ from: CELType) -> CELType? {
    if mapping.isEmpty {
      return nil
    }
    if case .typeParam(let name) = from {
      return mapping[name]
    }
    if !hasParenthesizedKey && from.formatsWithParentheses {
      return nil
    }
    let key = from.checkerDescription
    if !mayHaveKey(startingLike: key) {
      return nil
    }
    return mapping[key]
  }
}

extension CELType {
  /// Whether ``checkerDescription`` contains `(` whatever the type's names: list, map, wrapper and
  /// parameterized types, and function types.
  fileprivate var formatsWithParentheses: Bool {
    switch self {
    case .list, .map, .wrapper: return true
    case .opaque(_, let params): return !params.isEmpty
    case .type(let param): return param != nil
    default: return false
    }
  }
}
