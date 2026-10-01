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
// Ported from cel-go common/types/format.go and the `format` methods of the value types.

extension Value: CustomStringConvertible {
  /// The value formatted like a CEL literal, as cel-go `types.Format`: `1u`, `2.0`, `"text"`,
  /// `b"\150\151"`, `[1, 2]`, `{"a": 1}` (keys sorted), `duration("1.5s")`,
  /// `timestamp("2009-02-13T23:31:30Z")`, `optional.of(1)`.
  ///
  /// The output is meant for humans and tests; it is not a stable serialization.
  public var description: String {
    var out = ""
    format(into: &out)
    return out
  }

  private func format(into out: inout String) {
    switch self {
    case .null:
      out += "null"
    case .bool(let b):
      out += b ? "true" : "false"
    case .int(let i):
      out += String(i)
    case .uint(let u):
      out += String(u) + "u"
    case .double(let d):
      if d.isNaN {
        out += "double(\"NaN\")"
      } else if d.isInfinite {
        out += d < 0 ? "double(\"-Infinity\")" : "double(\"Infinity\")"
      } else {
        let s = formatGoFloat(d, format: .fixed)
        out += s
        if !s.utf8.contains(UInt8(ascii: ".")) {
          out += ".0"
        }
      }
    case .string(let s):
      out += goQuote(s)
    case .bytes(let b):
      out += "b\""
      for byte in b {
        let octal = String(byte, radix: 8)
        out += "\\" + String(repeating: "0", count: 3 - octal.utf8.count) + octal
      }
      out += "\""
    case .list(let l):
      out += "["
      for i in 0..<l.count {
        if i > 0 {
          out += ", "
        }
        l.element(at: i).format(into: &out)
      }
      out += "]"
    case .map(let m):
      var entries: [(key: String, value: String)] = []
      entries.reserveCapacity(m.count)
      m.forEachKey { key in
        entries.append((key.value.description, (m.value(forKey: key) ?? .null).description))
        return true
      }
      entries.sort { compareUTF8($0.key, $1.key) < 0 }
      out += "{"
      for (i, entry) in entries.enumerated() {
        if i > 0 {
          out += ", "
        }
        out += entry.key + ": " + entry.value
      }
      out += "}"
    case .type(let t):
      out += t.runtimeTypeName
    case .duration(let d):
      out += "duration(\"" + formatGoFloat(d.secondsAsDouble, format: .fixed) + "s\")"
    case .timestamp(let t):
      out += "timestamp(\"" + t.utcString + "\")"
    case .optional(let inner):
      if let inner {
        out += "optional.of("
        inner.format(into: &out)
        out += ")"
      } else {
        out += "optional.none()"
      }
    case .object(let o):
      if let printable = o as? any CustomStringConvertible {
        out += printable.description
      } else {
        out += o.celType.runtimeTypeName + "{}"
      }
    case .error(let e):
      out += e.message
    case .unknown(let u):
      out += u.description
    }
  }
}
