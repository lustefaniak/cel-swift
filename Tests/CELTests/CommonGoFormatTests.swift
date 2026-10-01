import Testing

@testable import CEL

/// Expected values were produced by Go 1.26 (`strconv.FormatFloat(f, 'g', -1, 64)` / `strconv.Quote`).
@Suite struct CommonGoFormatTests {
  @Test(arguments: [
    (0.0, "0"), (1.0, "1"), (-1.0, "-1"), (1e6, "1e+06"), (123456.0, "123456"),
    (1234567.0, "1.234567e+06"), (1e20, "1e+20"), (1e21, "1e+21"), (1e-4, "0.0001"),
    (1e-5, "1e-05"), (0.1, "0.1"), (23.39, "23.39"), (1.5e300, "1.5e+300"), (5e-324, "5e-324"),
    (100.0, "100"), (1e15, "1e+15"), (12345678901234567890.0, "1.2345678901234567e+19"),
    (-0.0, "-0"), (Double.infinity, "+Inf"), (-Double.infinity, "-Inf"), (Double.nan, "NaN"),
  ])
  func formatFloat(value: Double, expected: String) {
    #expect(GoFormat.formatFloat(value) == expected)
  }

  @Test func quote() {
    #expect(
      GoFormat.quote("a\u{00}\u{7f}\u{ad}\u{2764}\u{1F600}\t\"'\\")
        == "\"a\\x00\\x7f\\u00ad❤😀\\t\\\"'\\\\\"")
    #expect(GoFormat.quote(bytes: [0xff, 0x61]) == "\"\\xffa\"")
  }
}
