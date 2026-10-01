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
// Ported from cel-go common/types/{bool,bytes,double,duration,int,list,map,null,optional,string,
// timestamp,types,uint}.go (the ConvertToType methods).

extension Value {
  /// Converts the value to another CEL type, as the conversion functions `int(x)`, `string(x)`,
  /// `type(x)` and friends do. Port of the cel-go `ConvertToType` methods.
  ///
  /// Only the runtime type name of `type` matters: converting to `list(int)` is the same as
  /// converting to `list(dyn)`.
  package func convert(to type: CELType) -> Value {
    if isUnknownOrError {
      return self
    }
    if case .type = type {
      return .type(celType)
    }
    switch self {
    case .error, .unknown:
      return self
    case .null:
      switch type {
      case .string: return .string("null")
      case .null: return self
      default: break
      }
    case .bool(let b):
      switch type {
      case .string: return .string(b ? "true" : "false")
      case .bool: return self
      default: break
      }
    case .int(let i):
      switch type {
      case .int: return self
      case .uint:
        switch int64ToUint64Checked(i) {
        case .success(let u): return .uint(u)
        case .failure(let e): return .error(e)
        }
      case .double: return .double(Double(i))
      case .string: return .string(String(i))
      case .timestamp:
        if i < CELTimestamp.minSecondsSinceEpoch || i > CELTimestamp.maxSecondsSinceEpoch {
          return .error(.timestampOverflow)
        }
        return .timestamp(CELTimestamp(secondsSinceEpoch: i))
      default: break
      }
    case .uint(let u):
      switch type {
      case .int:
        switch uint64ToInt64Checked(u) {
        case .success(let i): return .int(i)
        case .failure(let e): return .error(e)
        }
      case .uint: return self
      case .double: return .double(Double(u))
      case .string: return .string(String(u))
      default: break
      }
    case .double(let d):
      switch type {
      case .int:
        switch doubleToInt64Checked(d) {
        case .success(let i): return .int(i)
        case .failure(let e): return .error(e)
        }
      case .uint:
        switch doubleToUint64Checked(d) {
        case .success(let u): return .uint(u)
        case .failure(let e): return .error(e)
        }
      case .double: return self
      case .string: return .string(formatGoFloat(d, format: .general))
      default: break
      }
    case .string(let s):
      if let converted = Value.convertString(s, to: type) {
        return converted
      }
    case .bytes(let b):
      switch type {
      case .string:
        guard let s = decodeValidUTF8(b) else {
          return .error(message: "invalid UTF-8 in bytes, cannot convert to string")
        }
        return .string(s)
      case .bytes: return self
      default: break
      }
    case .duration(let d):
      switch type {
      case .string: return .string(d.celString)
      case .int: return .int(d.nanoseconds)
      case .duration: return self
      default: break
      }
    case .timestamp(let t):
      switch type {
      case .string: return .string(t.celString)
      case .int: return .int(t.secondsSinceEpoch)
      case .timestamp: return self
      default: break
      }
    case .list:
      if case .list = type { return self }
    case .map:
      if case .map = type { return self }
    case .type(let t):
      if case .string = type { return .string(t.runtimeTypeName) }
    case .optional:
      if type.runtimeTypeName == "optional_type" { return self }
    case .object(let o):
      if o.celType.runtimeTypeName == type.runtimeTypeName { return self }
      return .error(message: "type conversion error from '\(o.celType.runtimeTypeName)' to '\(type)'")
    }
    return .error(message: "type conversion error from '\(celType)' to '\(type)'")
  }

  /// String conversions. Port of cel-go `String.ConvertToType`; returns `nil` for the generic
  /// `type conversion error`.
  private static func convertString(_ s: String, to type: CELType) -> Value? {
    switch type {
    case .int:
      return parseGoInt(s).map(Value.int)
    case .uint:
      return parseGoUint(s).map(Value.uint)
    case .double:
      return parseGoFloat(s).map(Value.double)
    case .bool:
      return parseGoBool(s).map(Value.bool)
    case .bytes:
      return .bytes(Array(s.utf8))
    case .duration:
      return parseGoDuration(s).map { .duration(CELDuration(nanoseconds: $0)) }
    case .timestamp:
      if !isStrictRFC3339(Array(s.utf8)) {
        return .error(message: "invalid RFC 3339 timestamp \(goQuote(s))")
      }
      guard let t = parseRFC3339(s) else { return nil }
      if !t.isInRange {
        return .error(.timestampOverflow)
      }
      return .timestamp(t)
    case .string:
      return .string(s)
    default:
      return nil
    }
  }
}

/// Decodes UTF-8 bytes, or returns `nil` if they are not valid UTF-8 (Go `utf8.Valid`).
func decodeValidUTF8(_ bytes: [UInt8]) -> String? {
  var scalars = String.UnicodeScalarView()
  var decoder = UTF8()
  var iterator = bytes.makeIterator()
  loop: while true {
    switch decoder.decode(&iterator) {
    case .scalarValue(let scalar): scalars.append(scalar)
    case .emptyInput: break loop
    case .error: return nil
    }
  }
  return String(scalars)
}
