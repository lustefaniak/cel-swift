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
// Ported from cel-go common/types/string.go, duration.go and timestamp.go (the Receive methods
// and their overload tables).

extension Value {
  /// Receiver-style dispatch of a method on a string, duration or timestamp, the fallback the
  /// interpreter uses when a binding does not apply. Port of the cel-go `Receive` methods.
  package func receive(function: String, overload: String, args: [Value]) -> Value {
    switch self {
    case .string:
      if args.count == 1 {
        switch function {
        case Overloads.contains: return stringContains(self, args[0])
        case Overloads.endsWith: return stringEndsWith(self, args[0])
        case Overloads.startsWith: return stringStartsWith(self, args[0])
        default: break
        }
      }
    case .duration(let d):
      if args.isEmpty {
        switch function {
        case Overloads.timeGetHours: return .int(d.hours)
        case Overloads.timeGetMinutes: return .int(d.minutes)
        case Overloads.timeGetSeconds: return .int(d.seconds)
        case Overloads.timeGetMilliseconds: return .int(d.millisecondsOfSecond)
        default: break
        }
      }
    case .timestamp(let t):
      guard let field = Value.timestampFields[function], args.count <= 1 else { break }
      // Without a time zone argument cel-go's receiver uses the timestamp's own location.
      guard let tz = args.first else {
        return .int(field(t.civil(offsetSeconds: Int64(t.utcOffsetSeconds))))
      }
      guard case .string(let zone) = tz else {
        return Value.maybeNoSuchOverload(tz)
      }
      switch timeZoneOffset(zone, at: t) {
      case .success(let offset): return .int(field(t.civil(offsetSeconds: offset)))
      case .failure(let err): return .error(err)
      }
    default:
      break
    }
    return .noSuchOverload
  }

  private static let timestampFields: [String: @Sendable (CivilTime) -> Int64] = [
    Overloads.timeGetFullYear: { $0.year },
    Overloads.timeGetMonth: { $0.month - 1 },
    Overloads.timeGetDayOfYear: { $0.yearDay - 1 },
    Overloads.timeGetDate: { $0.day },
    Overloads.timeGetDayOfMonth: { $0.day - 1 },
    Overloads.timeGetDayOfWeek: { $0.weekday },
    Overloads.timeGetHours: { $0.hour },
    Overloads.timeGetMinutes: { $0.minute },
    Overloads.timeGetSeconds: { $0.second },
    Overloads.timeGetMilliseconds: { $0.nanosecond / 1_000_000 },
  ]
}
