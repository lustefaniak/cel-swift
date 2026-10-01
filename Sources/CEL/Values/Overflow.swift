// Copyright 2021 Google LLC
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
// Ported from cel-go common/types/overflow.go.

/// 2^64 as a double, the exclusive upper bound for double to uint conversion.
private let doubleTwoTo64: Double = 18_446_744_073_709_551_616.0

/// Addition with overflow detection of two int64 values.
func addInt64Checked(_ x: Int64, _ y: Int64) -> Result<Int64, EvalError> {
  let (r, o) = x.addingReportingOverflow(y)
  return o ? .failure(.intOverflow) : .success(r)
}

/// Subtraction with overflow detection of two int64 values.
func subtractInt64Checked(_ x: Int64, _ y: Int64) -> Result<Int64, EvalError> {
  let (r, o) = x.subtractingReportingOverflow(y)
  return o ? .failure(.intOverflow) : .success(r)
}

/// Negation with overflow detection of an int64.
func negateInt64Checked(_ x: Int64) -> Result<Int64, EvalError> {
  x == .min ? .failure(.intOverflow) : .success(-x)
}

/// Multiplication with overflow detection of two int64 values.
func multiplyInt64Checked(_ x: Int64, _ y: Int64) -> Result<Int64, EvalError> {
  let (r, o) = x.multipliedReportingOverflow(by: y)
  return o ? .failure(.intOverflow) : .success(r)
}

/// Division with overflow and division-by-zero detection of two int64 values.
func divideInt64Checked(_ x: Int64, _ y: Int64) -> Result<Int64, EvalError> {
  if y == 0 { return .failure(.divideByZero) }
  if x == .min && y == -1 { return .failure(.intOverflow) }
  return .success(x / y)
}

/// Modulo with overflow and modulus-by-zero detection of two int64 values.
func moduloInt64Checked(_ x: Int64, _ y: Int64) -> Result<Int64, EvalError> {
  if y == 0 { return .failure(.modulusByZero) }
  if x == .min && y == -1 { return .failure(.intOverflow) }
  return .success(x % y)
}

/// Addition with overflow detection of two uint64 values.
func addUint64Checked(_ x: UInt64, _ y: UInt64) -> Result<UInt64, EvalError> {
  let (r, o) = x.addingReportingOverflow(y)
  return o ? .failure(.uintOverflow) : .success(r)
}

/// Subtraction with overflow detection of two uint64 values.
func subtractUint64Checked(_ x: UInt64, _ y: UInt64) -> Result<UInt64, EvalError> {
  y > x ? .failure(.uintOverflow) : .success(x - y)
}

/// Multiplication with overflow detection of two uint64 values.
func multiplyUint64Checked(_ x: UInt64, _ y: UInt64) -> Result<UInt64, EvalError> {
  let (r, o) = x.multipliedReportingOverflow(by: y)
  return o ? .failure(.uintOverflow) : .success(r)
}

/// Division with a division-by-zero check of two uint64 values.
func divideUint64Checked(_ x: UInt64, _ y: UInt64) -> Result<UInt64, EvalError> {
  y == 0 ? .failure(.divideByZero) : .success(x / y)
}

/// Modulo with a modulus-by-zero check of two uint64 values.
func moduloUint64Checked(_ x: UInt64, _ y: UInt64) -> Result<UInt64, EvalError> {
  y == 0 ? .failure(.modulusByZero) : .success(x % y)
}

/// Addition with overflow detection of two durations.
func addDurationChecked(_ x: CELDuration, _ y: CELDuration) -> Result<CELDuration, EvalError> {
  addInt64Checked(x.nanoseconds, y.nanoseconds).map(CELDuration.init(nanoseconds:))
}

/// Subtraction with overflow detection of two durations.
func subtractDurationChecked(_ x: CELDuration, _ y: CELDuration) -> Result<CELDuration, EvalError> {
  subtractInt64Checked(x.nanoseconds, y.nanoseconds).map(CELDuration.init(nanoseconds:))
}

/// Negation with overflow detection of a duration.
func negateDurationChecked(_ x: CELDuration) -> Result<CELDuration, EvalError> {
  negateInt64Checked(x.nanoseconds).map(CELDuration.init(nanoseconds:))
}

/// Adds a duration to a timestamp with overflow detection, keeping the timestamp's offset.
func addTimeDurationChecked(_ x: CELTimestamp, _ y: CELDuration) -> Result<CELTimestamp, EvalError> {
  let sec1 = x.secondsSinceEpoch
  let nsec1 = Int64(x.nanoseconds)
  let sec2 = y.nanoseconds / CELDuration.nanosPerSecond
  let nsec2 = y.nanoseconds % CELDuration.nanosPerSecond
  guard case .success(var sec) = addInt64Checked(sec1, sec2) else {
    return .failure(.intOverflow)
  }
  var nsec = nsec1 + nsec2
  if nsec < 0 || nsec >= CELDuration.nanosPerSecond {
    guard case .success(let s) = addInt64Checked(sec, nsec / CELDuration.nanosPerSecond) else {
      return .failure(.intOverflow)
    }
    sec = s
    nsec -= (nsec / CELDuration.nanosPerSecond) * CELDuration.nanosPerSecond
    if nsec < 0 {
      guard case .success(let s) = addInt64Checked(sec, -1) else {
        return .failure(.intOverflow)
      }
      sec = s
      nsec += CELDuration.nanosPerSecond
    }
  }
  if sec < CELTimestamp.minSecondsSinceEpoch || sec > CELTimestamp.maxSecondsSinceEpoch {
    return .failure(.timestampOverflow)
  }
  return .success(
    CELTimestamp(secondsSinceEpoch: sec, nanoseconds: Int32(nsec), utcOffsetSeconds: x.utcOffsetSeconds))
}

/// Subtracts two timestamps with overflow detection.
func subtractTimeChecked(_ x: CELTimestamp, _ y: CELTimestamp) -> Result<CELDuration, EvalError> {
  guard case .success(let sec) = subtractInt64Checked(x.secondsSinceEpoch, y.secondsSinceEpoch)
  else { return .failure(.intOverflow) }
  let nsec = Int64(x.nanoseconds) - Int64(y.nanoseconds)
  guard case .success(let tsec) = multiplyInt64Checked(sec, CELDuration.nanosPerSecond) else {
    return .failure(.intOverflow)
  }
  return addInt64Checked(tsec, nsec).map(CELDuration.init(nanoseconds:))
}

/// Subtracts a duration from a timestamp with overflow detection.
func subtractTimeDurationChecked(_ x: CELTimestamp, _ y: CELDuration) -> Result<CELTimestamp, EvalError> {
  switch negateDurationChecked(y) {
  case .success(let neg): return addTimeDurationChecked(x, neg)
  case .failure(let err): return .failure(err)
  }
}

/// Converts a double to int64, failing on NaN, infinities and values outside the int64 range.
func doubleToInt64Checked(_ v: Double) -> Result<Int64, EvalError> {
  if v.isInfinite || v.isNaN || v <= Double(Int64.min) || v >= Double(Int64.max) {
    return .failure(.intOverflow)
  }
  return .success(Int64(v))
}

/// Converts a double to uint64, failing on NaN, infinities and values outside the uint64 range.
func doubleToUint64Checked(_ v: Double) -> Result<UInt64, EvalError> {
  if v.isInfinite || v.isNaN || v < 0 || v >= doubleTwoTo64 {
    return .failure(.uintOverflow)
  }
  return .success(UInt64(v))
}

/// Converts an int64 to uint64, failing on negative values.
func int64ToUint64Checked(_ v: Int64) -> Result<UInt64, EvalError> {
  v < 0 ? .failure(.uintOverflow) : .success(UInt64(v))
}

/// Converts a uint64 to int64, failing on values above `Int64.max`.
func uint64ToInt64Checked(_ v: UInt64) -> Result<Int64, EvalError> {
  v > UInt64(Int64.max) ? .failure(.intOverflow) : .success(Int64(v))
}

/// Converts a double to uint64 when the conversion is exact.
func doubleToUint64Lossless(_ v: Double) -> UInt64? {
  guard case .success(let u) = doubleToUint64Checked(v), Double(u) == v else { return nil }
  return u
}

/// Converts a double to int64 when the conversion is exact.
func doubleToInt64Lossless(_ v: Double) -> Int64? {
  guard case .success(let i) = doubleToInt64Checked(v), Double(i) == v else { return nil }
  return i
}

/// Converts an int64 to uint64 when it is non-negative.
func int64ToUint64Lossless(_ v: Int64) -> UInt64? {
  v < 0 ? nil : UInt64(v)
}

/// Converts a uint64 to int64 when it fits.
func uint64ToInt64Lossless(_ v: UInt64) -> Int64? {
  v > UInt64(Int64.max) ? nil : Int64(v)
}
