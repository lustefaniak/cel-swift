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
// Ported from cel-go common/types/duration.go.

/// A CEL `google.protobuf.Duration` value: a signed number of nanoseconds.
///
/// As in cel-go, durations are 64-bit nanosecond counts (Go `time.Duration`), so the range is
/// about ±292 years; arithmetic that leaves it is an `integer overflow` error.
public struct CELDuration: Sendable, Hashable, Comparable {
  /// The duration in nanoseconds.
  public var nanoseconds: Int64

  /// Creates a duration from a nanosecond count.
  public init(nanoseconds: Int64) {
    self.nanoseconds = nanoseconds
  }

  /// Creates a duration from whole seconds and a nanosecond adjustment, or `nil` if the result
  /// does not fit in 64-bit nanoseconds.
  public init?(seconds: Int64, nanoseconds: Int64 = 0) {
    let (scaled, mulOverflow) = seconds.multipliedReportingOverflow(by: CELDuration.nanosPerSecond)
    let (total, addOverflow) = scaled.addingReportingOverflow(nanoseconds)
    if mulOverflow || addOverflow {
      return nil
    }
    self.nanoseconds = total
  }

  /// Orders durations by length.
  public static func < (lhs: CELDuration, rhs: CELDuration) -> Bool {
    lhs.nanoseconds < rhs.nanoseconds
  }

  static let nanosPerSecond: Int64 = 1_000_000_000
  static let nanosPerMillisecond: Int64 = 1_000_000
  static let nanosPerMinute: Int64 = 60 * nanosPerSecond
  static let nanosPerHour: Int64 = 60 * nanosPerMinute

  /// The whole hours, truncated toward zero. Port of Go `Duration.Hours` converted to `int`.
  var hours: Int64 { nanoseconds / CELDuration.nanosPerHour }
  /// The whole minutes, truncated toward zero.
  var minutes: Int64 { nanoseconds / CELDuration.nanosPerMinute }
  /// The whole seconds, truncated toward zero.
  var seconds: Int64 { nanoseconds / CELDuration.nanosPerSecond }
  /// The whole milliseconds, truncated toward zero.
  var milliseconds: Int64 { nanoseconds / CELDuration.nanosPerMillisecond }
  /// The milliseconds within the current second, truncated toward zero (`duration('1.234s')` has 234):
  /// what the spec's `getMilliseconds` returns. cel-go returns ``milliseconds`` (docs/divergences.md).
  var millisecondsOfSecond: Int64 {
    (nanoseconds % CELDuration.nanosPerSecond) / CELDuration.nanosPerMillisecond
  }

  /// The duration in seconds as a double, computed as Go `Duration.Seconds` does.
  var secondsAsDouble: Double {
    let sec = nanoseconds / CELDuration.nanosPerSecond
    let nsec = nanoseconds % CELDuration.nanosPerSecond
    return Double(sec) + Double(nsec) / 1e9
  }

  /// The CEL string form: seconds with the shortest decimal fraction and an `s` suffix, `1.5s`.
  ///
  /// Port of cel-go `Duration.ConvertToType(StringType)`:
  /// `strconv.FormatFloat(d.Seconds(), 'f', -1, 64) + "s"`.
  public var celString: String {
    formatGoFloat(secondsAsDouble, format: .fixed) + "s"
  }
}
