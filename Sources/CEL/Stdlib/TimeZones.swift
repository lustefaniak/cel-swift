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
// Ported from cel-go common/stdlib/standard.go (inTimeZone).
//
// This is the only file in `CEL` that uses Foundation: IANA time zone rules come from
// `TimeZone(identifier:)`. Everything else about timestamps is integer civil-calendar arithmetic.

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// Resolves the UTC offset, in seconds, of the time zone `name` at the instant `ts`.
///
/// Port of cel-go `inTimeZone`: a name without `:` is an IANA time zone (as Go
/// `time.LoadLocation`: `""` and `UTC` are UTC); otherwise it is a fixed `[+-]hh:mm` offset parsed
/// with Go `strconv.Atoi` semantics. Errors carry Go's messages.
func timeZoneOffset(_ name: String, at ts: CELTimestamp) -> Result<Int64, EvalError> {
  let bytes = Array(name.utf8)
  guard let colon = bytes.firstIndex(of: UInt8(ascii: ":")) else {
    return ianaOffset(name, at: ts)
  }
  let hourText = String(decoding: bytes[..<colon], as: UTF8.self)
  let minuteText = String(decoding: bytes[(colon + 1)...], as: UTF8.self)
  let hr: Int64
  switch goAtoi(hourText) {
  case .success(let v): hr = v
  case .failure(let e): return .failure(e)
  }
  let min: Int64
  switch goAtoi(minuteText) {
  case .success(let v): min = v
  case .failure(let e): return .failure(e)
  }
  if hr < -23 || hr > 23 {
    return .failure(EvalError("timezone offset hours out of range [-23, 23]: \(name)"))
  }
  if min < 0 || min > 59 {
    return .failure(EvalError("timezone offset minutes out of range [0, 59]: \(name)"))
  }
  let offsetMinutes = bytes.first == UInt8(ascii: "-") ? hr * 60 - min : hr * 60 + min
  return .success(offsetMinutes * 60)
}

/// Go `strconv.Atoi` with its error messages.
private func goAtoi(_ s: String) -> Result<Int64, EvalError> {
  if let v = parseGoInt(s) {
    return .success(v)
  }
  // Distinguish syntax from range errors the way Go does.
  var digits = Substring(s)
  if let first = digits.utf8.first, first == UInt8(ascii: "+") || first == UInt8(ascii: "-") {
    digits = digits.dropFirst()
  }
  let isSyntaxValid =
    !digits.isEmpty && digits.utf8.allSatisfy { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }
  let reason = isSyntaxValid ? "value out of range" : "invalid syntax"
  return .failure(EvalError("strconv.Atoi: parsing \(goQuote(s)): \(reason)"))
}

/// Go `time.LoadLocation(name)` followed by the offset lookup for `ts`.
private func ianaOffset(_ name: String, at ts: CELTimestamp) -> Result<Int64, EvalError> {
  if name.isEmpty || name == "UTC" {
    return .success(0)
  }
  let bytes = Array(name.utf8)
  // Go rejects names that could escape the zoneinfo directory.
  let hasDotDot = bytes.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
    .contains { $0.elementsEqual("..".utf8) }
  if bytes.first == UInt8(ascii: "/") || bytes.contains(UInt8(ascii: "\\")) || hasDotDot {
    return .failure(EvalError("time: invalid location name"))
  }
  let zone: TimeZone?
  if name == "Local" {
    zone = TimeZone.current
  } else {
    zone = TimeZone(identifier: name)
  }
  guard let zone else {
    return .failure(EvalError("unknown time zone \(name)"))
  }
  let date = Date(timeIntervalSince1970: Double(ts.secondsSinceEpoch))
  return .success(Int64(zone.secondsFromGMT(for: date)))
}
