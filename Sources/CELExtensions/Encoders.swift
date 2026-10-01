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
// Ported from cel-go ext/encoders.go: `base64.decode`, `base64.encode` and `json.encode`. The cost
// estimators and trackers (version 1) are in EncodersCosts.swift.
//
// `json.encode` converts the value to a protobuf `google.protobuf.Value` the way cel-go's
// `ConvertToNative(JSONValueType)` does, then prints it as Go's `encoding/json` would (cel-go
// round-trips the protojson output through `json.Unmarshal` / `json.Marshal`): object keys sorted,
// numbers as Go float64s, HTML-safe string escapes.

import CEL

extension Library {
  /// The encoders extension library at its latest version: `base64.decode`, `base64.encode` and
  /// `json.encode`.
  public static var encoders: Library { encoders() }

  /// The encoders extension library at a given version.
  ///
  /// Version 0 has the base64 functions and version 1 adds `json.encode`.
  ///
  /// - Parameter version: the library version; ``Library/latestVersion`` enables everything.
  public static func encoders(version: UInt32 = Library.latestVersion) -> Library {
    var decls = makeDeclarations([
      try FunctionDecl(
        "base64.decode",
        .overload(
          "base64_decode_string", argTypes: [.string], resultType: .bytes,
          .unaryBinding { str in
            guard case .string(let s) = str else { return noSuchOverload(str) }
            return bytesOrError(Base64.decodeLenient(Array(s.utf8)))
          })),
      try FunctionDecl(
        "base64.encode",
        .overload(
          "base64_encode_bytes", argTypes: [.bytes], resultType: .string,
          .unaryBinding { bytes in
            guard case .bytes(let b) = bytes else { return noSuchOverload(bytes) }
            return .string(Base64.encode(b))
          })),
    ])
    if version >= 1 {
      decls += makeDeclarations([
        try FunctionDecl(
          "json.encode",
          .overload(
            "json_encode_dyn", argTypes: [.dyn], resultType: .string,
            .unaryBinding { val in
              switch CELJSONEncoder.encode(val) {
              case .success(let s): return .string(s)
              case .failure(let e): return .error(EvalError(e.message))
              }
            }))
      ])
    }
    let lib = Library(name: "cel.lib.ext.encoders", alias: "encoders", version: version, functions: decls)
    guard version >= 1 else { return lib }
    return lib.withCosts(estimators: EncodersCosts.estimators, trackers: EncodersCosts.trackers)
  }
}

/// Go `base64.CorruptInputError`.
struct CorruptInput: Error {
  let offset: Int
}

/// Go `encoding/base64` with the standard alphabet.
enum Base64 {
  private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
  private static let decodeMap: [UInt8] = {
    var map = [UInt8](repeating: 0xFF, count: 256)
    for (i, c) in alphabet.enumerated() {
      map[Int(c)] = UInt8(i)
    }
    return map
  }()

  /// `base64.StdEncoding.EncodeToString`.
  static func encode(_ src: [UInt8]) -> String {
    var out: [UInt8] = []
    out.reserveCapacity((src.count + 2) / 3 * 4)
    var i = 0
    while i + 3 <= src.count {
      let v = UInt32(src[i]) << 16 | UInt32(src[i + 1]) << 8 | UInt32(src[i + 2])
      out += [alphabet[Int(v >> 18 & 0x3F)], alphabet[Int(v >> 12 & 0x3F)],
              alphabet[Int(v >> 6 & 0x3F)], alphabet[Int(v & 0x3F)]]
      i += 3
    }
    let remain = src.count - i
    if remain > 0 {
      var v = UInt32(src[i]) << 16
      if remain == 2 {
        v |= UInt32(src[i + 1]) << 8
      }
      out += [alphabet[Int(v >> 18 & 0x3F)], alphabet[Int(v >> 12 & 0x3F)]]
      out += remain == 2 ? [alphabet[Int(v >> 6 & 0x3F)], UInt8(ascii: "=")] : [UInt8(ascii: "="), UInt8(ascii: "=")]
    }
    return String(decoding: out, as: UTF8.self)
  }

  /// cel-go `base64DecodeString`: standard padded decoding, retried without padding when the input
  /// is corrupt.
  static func decodeLenient(_ src: [UInt8]) -> Result<[UInt8], ExtError> {
    switch decode(src, padded: true) {
    case .success(let b): return .success(b)
    case .failure:
      return decode(src, padded: false).mapError { ExtError("illegal base64 data at input byte \($0.offset)") }
    }
  }

  /// Port of Go `Encoding.Decode` (`decodeQuantum`): `\r` and `\n` are ignored; the failure is the
  /// offset Go reports in `CorruptInputError`.
  static func decode(_ src: [UInt8], padded: Bool) -> Result<[UInt8], CorruptInput> {
    var dst: [UInt8] = []
    var si = 0
    while si < src.count {
      var dbuf = [UInt8](repeating: 0, count: 4)
      var dlen = 4
      var j = 0
      while j < 4 {
        if si == src.count {
          if j == 0 {
            return .success(dst)
          }
          if j == 1 || padded {
            return .failure(CorruptInput(offset: si - j))
          }
          dlen = j
          break
        }
        let input = src[si]
        si += 1
        let out = decodeMap[Int(input)]
        if out != 0xFF {
          dbuf[j] = out
          j += 1
          continue
        }
        if input == UInt8(ascii: "\n") || input == UInt8(ascii: "\r") {
          continue
        }
        if input != UInt8(ascii: "=") || !padded {
          return .failure(CorruptInput(offset: si - 1))
        }
        // We've reached the end and there's padding.
        switch j {
        case 0, 1:
          // Incorrect padding.
          return .failure(CorruptInput(offset: si - 1))
        case 2:
          // "==" is expected; skip over newlines.
          while si < src.count && (src[si] == UInt8(ascii: "\n") || src[si] == UInt8(ascii: "\r")) {
            si += 1
          }
          if si == src.count {
            return .failure(CorruptInput(offset: src.count))
          }
          if src[si] != UInt8(ascii: "=") {
            return .failure(CorruptInput(offset: si - 1))
          }
          si += 1
        default:
          break
        }
        // Skip over newlines.
        while si < src.count && (src[si] == UInt8(ascii: "\n") || src[si] == UInt8(ascii: "\r")) {
          si += 1
        }
        if si < src.count {
          // Trailing garbage.
          return .failure(CorruptInput(offset: si))
        }
        dlen = j
        break
      }
      let val = UInt32(dbuf[0]) << 18 | UInt32(dbuf[1]) << 12 | UInt32(dbuf[2]) << 6 | UInt32(dbuf[3])
      let bytes = [UInt8(val >> 16 & 0xFF), UInt8(val >> 8 & 0xFF), UInt8(val & 0xFF)]
      switch dlen {
      case 4:
        dst += bytes
      case 3:
        dst += bytes[0..<2]
      case 2:
        dst += bytes[0..<1]
      default:
        break
      }
      if dlen < 4 {
        // Go: strict mode would check the unused bits; StdEncoding is not strict.
        return si < src.count ? .failure(CorruptInput(offset: si)) : .success(dst)
      }
    }
    return .success(dst)
  }
}

/// `json.encode`: cel-go `jsonEncodeValue`.
enum CELJSONEncoder {
  /// A JSON value (`google.protobuf.Value`).
  indirect enum JSON {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case list([JSON])
    case object([(String, JSON)])
  }

  static func encode(_ value: Value) -> Result<String, ExtError> {
    switch toJSON(value) {
    case .failure(let e):
      return .failure(e)
    case .success(let json):
      var out = ""
      if let err = write(json, to: &out) {
        return .failure(err)
      }
      return .success(out)
    }
  }

  /// Port of the `ConvertToNative(JSONValueType)` methods of cel-go's value types.
  static func toJSON(_ value: Value) -> Result<JSON, ExtError> {
    switch value {
    case .null:
      return .success(.null)
    case .bool(let b):
      return .success(.bool(b))
    case .int(let i):
      // Integers beyond EcmaScript's safe range become strings.
      if i >= -(1 << 53 - 1) && i <= 1 << 53 - 1 {
        return .success(.number(Double(i)))
      }
      return .success(.string(String(i)))
    case .uint(let u):
      if u <= 1 << 53 - 1 {
        return .success(.number(Double(u)))
      }
      return .success(.string(String(u)))
    case .double(let d):
      return .success(.number(d))
    case .string(let s):
      return .success(.string(s))
    case .bytes(let b):
      return .success(.string(Base64.encode(b)))
    case .duration, .timestamp:
      guard case .string(let s) = value.convert(to: .string) else {
        return .failure(ExtError("type conversion error"))
      }
      return .success(.string(s))
    case .list(let list):
      var items: [JSON] = []
      for i in 0..<list.count {
        switch toJSON(list.element(at: i)) {
        case .success(let j): items.append(j)
        case .failure(let e): return .failure(e)
        }
      }
      return .success(.list(items))
    case .map(let map):
      var fields: [(String, JSON)] = []
      for key in map.keys {
        guard case .string(let k) = key.value else {
          return .failure(
            ExtError("unsupported type conversion from '\(key.value.runtimeTypeName)' to string"))
        }
        guard let v = map.value(forKey: key) else { continue }
        switch toJSON(v) {
        case .success(let j): fields.append((k, j))
        case .failure(let e): return .failure(e)
        }
      }
      return .success(.object(fields))
    case .optional(let inner):
      guard let inner else { return .failure(ExtError("optional.none() dereference")) }
      return toJSON(inner)
    case .error(let e):
      return .failure(ExtError(e.message))
    default:
      return .failure(ExtError("type conversion not supported for '\(value.runtimeTypeName)'"))
    }
  }

  /// Go `encoding/json` output; protojson's rejection of non-finite numbers comes first.
  private static func write(_ json: JSON, to out: inout String) -> ExtError? {
    switch json {
    case .null:
      out += "null"
    case .bool(let b):
      out += b ? "true" : "false"
    case .number(let d):
      if d.isNaN {
        return ExtError("proto: google.protobuf.Value.number_value: invalid NaN value")
      }
      if d.isInfinite {
        return ExtError("proto: google.protobuf.Value.number_value: invalid \(d < 0 ? "-" : "+")Inf value")
      }
      out += number(d)
    case .string(let s):
      writeString(s, to: &out)
    case .list(let items):
      out += "["
      for (i, item) in items.enumerated() {
        if i > 0 {
          out += ","
        }
        if let err = write(item, to: &out) {
          return err
        }
      }
      out += "]"
    case .object(let fields):
      // Go marshals map[string]any with keys sorted as byte strings.
      let sorted = fields.sorted { Array($0.0.utf8).lexicographicallyPrecedes(Array($1.0.utf8)) }
      out += "{"
      for (i, (k, v)) in sorted.enumerated() {
        if i > 0 {
          out += ","
        }
        writeString(k, to: &out)
        out += ":"
        if let err = write(v, to: &out) {
          return err
        }
      }
      out += "}"
    }
    return nil
  }

  /// Go `encoding/json` `floatEncoder` for float64: `'f'` format, or `'e'` for very small or large
  /// magnitudes with the exponent's leading zero removed (`1e-07` -> `1e-7`).
  static func number(_ d: Double) -> String {
    let abs = Swift.abs(d)
    if abs != 0 && (abs < 1e-6 || abs >= 1e21) {
      // formatFloat is 'g' -1, which uses 'e' for these magnitudes; Go then trims a leading zero
      // from a two-digit negative exponent.
      var b = Array(GoFormat.formatFloat(d).utf8)
      let n = b.count
      if n >= 4 && b[n - 4] == UInt8(ascii: "e") && b[n - 3] == UInt8(ascii: "-")
        && b[n - 2] == UInt8(ascii: "0")
      {
        b.remove(at: n - 2)
      }
      return String(decoding: b, as: UTF8.self)
    }
    return GoFloat.shortestFixed(d)
  }

  /// Go `encoding/json` string encoding with HTML escaping.
  private static func writeString(_ s: String, to out: inout String) {
    let hex = Array("0123456789abcdef")
    out += "\""
    for c in s.unicodeScalars {
      switch c {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      case "\u{08}": out += "\\b"
      case "\u{0C}": out += "\\f"
      case "<", ">", "&", "\u{2028}", "\u{2029}":
        let v = c.value
        out += "\\u"
        out.append(hex[Int(v >> 12 & 0xF)])
        out.append(hex[Int(v >> 8 & 0xF)])
        out.append(hex[Int(v >> 4 & 0xF)])
        out.append(hex[Int(v & 0xF)])
      default:
        if c.value < 0x20 {
          out += "\\u00"
          out.append(hex[Int(c.value >> 4)])
          out.append(hex[Int(c.value & 0xF)])
        } else {
          out.unicodeScalars.append(c)
        }
      }
    }
    out += "\""
  }
}
