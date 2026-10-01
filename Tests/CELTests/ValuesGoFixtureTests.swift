// Differential tests of the Go formatting and parsing ports against fixtures generated with
// cel-go (see tools/value-fixtures/gen_fixtures.py).

import Testing

@testable import CEL

struct FixtureError: Error, Equatable {
  let message: String
  init(_ message: String) {
    self.message = message
  }
}

struct ValuesGoFixtureTests {
  @Test func stringOfDoubleMatchesGo() {
    var mismatches: [String] = []
    for (bits, expected) in GoValueFixtures.doubleToString {
      let d = Double(bitPattern: bits)
      let got = Value.double(d).convert(to: .string)
      if got != .string(expected) {
        mismatches.append("\(d.debugDescription): got \(got), want \(expected)")
      }
    }
    #expect(mismatches.isEmpty, "\(mismatches.prefix(20))")
  }

  @Test func doubleOfStringMatchesGo() {
    for (input, bits) in GoValueFixtures.stringToDouble {
      let got = Value.string(input).convert(to: .double)
      guard let bits else {
        #expect(
          got == .error(EvalError("type conversion error from 'string' to 'double'")),
          "double(\(input))")
        continue
      }
      let want = Double(bitPattern: bits)
      guard case .double(let d) = got else {
        Issue.record("double(\(input)) = \(got), want \(want)")
        continue
      }
      if want.isNaN {
        #expect(d.isNaN, "double(\(input))")
      } else {
        #expect(d.bitPattern == want.bitPattern, "double(\(input)) = \(d), want \(want)")
      }
    }
  }

  @Test func durationOfStringMatchesGo() {
    for (input, nanos) in GoValueFixtures.stringToDuration {
      let got = Value.string(input).convert(to: .duration)
      if let nanos {
        #expect(got == .duration(CELDuration(nanoseconds: nanos)), "duration(\(input))")
      } else {
        #expect(
          got
            == .error(
              EvalError("type conversion error from 'string' to 'google.protobuf.Duration'")),
          "duration(\(input))")
      }
    }
  }

  @Test func stringOfDurationMatchesGo() {
    for (nanos, expected) in GoValueFixtures.durationToString {
      #expect(
        Value.duration(CELDuration(nanoseconds: nanos)).convert(to: .string) == .string(expected))
    }
  }

  @Test func timestampOfStringMatchesGo() {
    for (input, expected) in GoValueFixtures.stringToTimestamp {
      let got = Value.string(input).convert(to: .timestamp)
      switch expected {
      case .success(let (seconds, millis, text)):
        guard case .timestamp(let ts) = got else {
          Issue.record("timestamp(\(input)) = \(got)")
          continue
        }
        #expect(ts.secondsSinceEpoch == seconds, "timestamp(\(input))")
        #expect(Int64(ts.nanoseconds) / 1_000_000 == millis, "timestamp(\(input))")
        #expect(ts.celString == text, "string(timestamp(\(input)))")
      case .failure(let err):
        #expect(got == .error(EvalError(err.message)), "timestamp(\(input))")
      }
    }
  }

  @Test func timestampAccessorsMatchGo() throws {
    let accessors = try Dictionary(
      uniqueKeysWithValues: StandardLibrary.functions.map { ($0.name, try $0.bindings()) })
    for (ts, accessor, tz, expected) in GoValueFixtures.timestampAccessors {
      let bindings = try #require(accessors[accessor])
      let dispatch = try #require(bindings.first { $0.name == accessor })
      let timestamp = Value.string(ts).convert(to: .timestamp)
      let args: [Value] = tz.map { [timestamp, .string($0)] } ?? [timestamp]
      let got = dispatch.invoke(args)
      switch expected {
      case .success(let v):
        #expect(got == .int(v), "timestamp(\(ts)).\(accessor)(\(tz ?? ""))")
      case .failure(let err):
        #expect(got == .error(EvalError(err.message)), "timestamp(\(ts)).\(accessor)(\(tz ?? ""))")
      }
    }
  }
}
