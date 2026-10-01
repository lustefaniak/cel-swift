// Tests of the TZif reader (port of Go time/zoneinfo_read.go and zoneinfo.go). Expected offsets match
// Go's time.LoadLocation on the same tz database.

import Testing

@testable import CEL

private let hasZoneInfo = TZifLocation.load(named: "America/New_York") != nil

struct StdlibTimeZoneTests {
  @Test(.enabled(if: hasZoneInfo, "requires the system tz database"))
  func newYorkOffsets() throws {
    let ny = try #require(TZifLocation.load(named: "America/New_York"))
    // 2023-07-01T12:00:00Z (EDT), 2023-01-01T12:00:00Z (EST).
    #expect(ny.offset(at: 1_688_212_800) == -4 * 3600)
    #expect(ny.offset(at: 1_672_574_400) == -5 * 3600)
    // 2100-07-01T12:00:00Z is past the last transition: the POSIX rule in the footer applies.
    #expect(ny.offset(at: 4_118_040_000) == -4 * 3600)
    #expect(ny.offset(at: 4_102_488_000) == -5 * 3600)
    // 1800-01-01: local mean time before the first transition, -4:56:02.
    #expect(ny.offset(at: -5_364_662_400) == -17_762)
  }

  @Test(.enabled(if: hasZoneInfo, "requires the system tz database"))
  func southernHemisphereRule() throws {
    let sydney = try #require(TZifLocation.load(named: "Australia/Sydney"))
    // 2100-01-15 is summer (AEDT, +11), 2100-07-15 winter (AEST, +10).
    #expect(sydney.offset(at: 4_103_222_400) == 11 * 3600)
    #expect(sydney.offset(at: 4_118_774_400) == 10 * 3600)
  }

  @Test func namesAndErrors() {
    let ts = CELTimestamp(secondsSinceEpoch: 0)
    #expect(timeZoneOffset("UTC", at: ts) == .success(0))
    #expect(timeZoneOffset("", at: ts) == .success(0))
    #expect(timeZoneOffset("+05:30", at: ts) == .success(19_800))
    #expect(timeZoneOffset("-0:30", at: ts) == .success(-1_800))
    #expect(timeZoneOffset("Nope/Zone", at: ts) == .failure(EvalError("unknown time zone Nope/Zone")))
    #expect(timeZoneOffset("../etc/passwd", at: ts) == .failure(EvalError("time: invalid location name")))
    #expect(timeZoneOffset("/etc/localtime", at: ts) == .failure(EvalError("time: invalid location name")))
    #expect(
      timeZoneOffset("x:00", at: ts)
        == .failure(EvalError(#"strconv.Atoi: parsing "x": invalid syntax"#)))
    #expect(
      timeZoneOffset("99999999999999999999:00", at: ts)
        == .failure(EvalError(#"strconv.Atoi: parsing "99999999999999999999": value out of range"#)))
  }

  @Test func rejectsMalformedData() {
    #expect(TZifLocation(data: []) == nil)
    #expect(TZifLocation(data: Array("TZif2".utf8)) == nil)
    #expect(TZifLocation(data: Array("NOPE".utf8) + [UInt8](repeating: 0, count: 60)) == nil)
  }
}
