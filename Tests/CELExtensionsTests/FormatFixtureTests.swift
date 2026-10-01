// Differential tests of `string.format` number formatting against fixtures generated with cel-go
// (see tools/ext-fixtures/gen_format_fixtures.py). The fixtures are JSON lines under Resources, read at
// test time: as a Swift array literal they made the type checker grow past 30 GB.

import Foundation
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
    let rows = FormatFixtures.doubles()
    #expect(rows.count == 6739)
    for (version, clause, bits, out, err) in rows {
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
    let rows = FormatFixtures.integers()
    #expect(rows.count == 288)
    for (version, clause, isUint, bits, out, err) in rows {
      let arg: Value = isUint ? .uint(bits) : .int(Int64(bitPattern: bits))
      check(version, clause, arg, out, err, &mismatches, version == nil ? latest : v3)
    }
    #expect(mismatches.isEmpty, "\(mismatches.count) mismatches: \(mismatches.prefix(20))")
  }
}

/// Rows of `Resources/format-*.jsonl`: `[version (null = latest), clause, (is uint,) bits as hex, result, error]`.
enum FormatFixtures {
  private static func rows(_ name: String) -> [[Any]] {
    guard let url = Bundle.module.url(forResource: "format-\(name)", withExtension: "jsonl", subdirectory: "Resources"),
      let text = try? String(contentsOf: url, encoding: .utf8)
    else {
      Issue.record("missing fixture format-\(name).jsonl")
      return []
    }
    return text.split(separator: "\n").compactMap { line in
      (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [Any]
    }
  }

  private static func version(_ field: Any) -> UInt32? { (field as? NSNumber).map { $0.uint32Value } }
  private static func bits(_ field: Any) -> UInt64 { UInt64(field as? String ?? "", radix: 16) ?? 0 }

  static func doubles() -> [(UInt32?, String, UInt64, String?, String?)] {
    rows("doubles").map { r in
      (version(r[0]), r[1] as? String ?? "", bits(r[2]), r[3] as? String, r[4] as? String)
    }
  }

  static func integers() -> [(UInt32?, String, Bool, UInt64, String?, String?)] {
    rows("integers").map { r in
      (version(r[0]), r[1] as? String ?? "", r[2] as? Bool ?? false, bits(r[3]), r[4] as? String, r[5] as? String)
    }
  }
}
