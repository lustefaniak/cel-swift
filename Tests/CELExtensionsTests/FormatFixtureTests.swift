// Differential tests of `string.format` number formatting against fixtures generated with cel-go
// (see tools/ext-fixtures/gen_format_fixtures.py).

import Testing

@testable import CEL
@testable import CELExtensions

struct FormatFixtureTests {
  private func dispatcher(_ version: UInt32?) -> Dispatcher {
    Dispatcher(.strings(version: version ?? Library.latestVersion))
  }

  private func check(
    _ version: UInt32?, _ clause: String, _ arg: Value, _ out: String?, _ err: String?,
    _ mismatches: inout [String], _ d: Dispatcher
  ) {
    let got = d.call("format", .string(clause), list(arg))
    let want: Value = out.map(Value.string) ?? .error(EvalError(err ?? ""))
    if let message = errorMessage(got), message == err {
      return
    }
    if got != want {
      mismatches.append("v\(version.map(String.init) ?? "latest") \(clause) \(arg): got \(got), want \(want)")
    }
  }

  @Test func doublesMatchGo() {
    let latest = dispatcher(nil)
    let v3 = dispatcher(3)
    var mismatches: [String] = []
    for (version, clause, bits, out, err) in FormatFixtures.doubles {
      check(
        version, clause, .double(Double(bitPattern: bits)), out, err, &mismatches,
        version == nil ? latest : v3)
    }
    #expect(mismatches.isEmpty, "\(mismatches.count) mismatches: \(mismatches.prefix(20))")
  }

  @Test func integersMatchGo() {
    let latest = dispatcher(nil)
    let v3 = dispatcher(3)
    var mismatches: [String] = []
    for (version, clause, isUint, bits, out, err) in FormatFixtures.integers {
      let arg: Value = isUint ? .uint(bits) : .int(Int64(bitPattern: bits))
      check(version, clause, arg, out, err, &mismatches, version == nil ? latest : v3)
    }
    #expect(mismatches.isEmpty, "\(mismatches.count) mismatches: \(mismatches.prefix(20))")
  }
}
