// Cost tests of cel-go's ext/*_test.go that are not plain tables: network_test.go (TestNetworkCost,
// TestIPCost, TestCIDRCost), strings_test.go (TestQuoteUnquote's costs, TestStringCostLimitEnforced),
// encoders_test.go (TestJSONEncodeCostUnbounded, TestDecodeNonBase64Error). The table tests are in
// CostTableTests.swift.

import Testing

@testable import CEL
@testable import CELExtensions

/// Compiles, estimates and evaluates with cost tracking, as cel-go's network `testCost` does.
private func checkCost(
  _ env: Environment, _ expr: String, estimate: ClosedRange<UInt64>, runtime: UInt64,
  sourceLocation: SourceLocation = #_sourceLocation
) throws {
  let checked = try env.compile(expr)
  #expect(env.estimateCost(checked) == estimate, "estimate of \(expr)", sourceLocation: sourceLocation)
  let result = try env.program(checked, options: [.trackCost]).evaluate()
  #expect(result.cost == runtime, "runtime cost of \(expr)", sourceLocation: sourceLocation)
}

private func adding(_ range: ClosedRange<UInt64>, _ min: UInt64, _ max: UInt64) -> ClosedRange<UInt64> {
  (range.lowerBound + min)...(range.upperBound + max)
}

struct NetworkCostTests {
  let env: Environment

  init() throws {
    env = try Environment(.library(.network))
  }

  static let networkCases: [(String, ClosedRange<UInt64>, UInt64)] = [
    ("ip('192.168.0.1')", 2...2, 2),
    ("isIP('192.168.0.1')", 2...2, 2),
    ("cidr('192.168.0.0/16')", 2...2, 2),
    ("isCIDR('192.168.0.0/16')", 2...2, 2),
    ("ip.isCanonical('192.168.0.1')", 3...3, 3),
    ("cidr('192.168.0.0/16').containsIP(ip('192.169.0.1'))", 5...8, 5),
    ("cidr('192.168.0.0/16').containsIP('192.0.0.1')", 4...7, 4),
    ("cidr('192.168.0.0/16').containsCIDR(cidr('192.0.0.0/30'))", 7...11, 7),
    ("cidr('192.168.0.0/16').containsCIDR('192.0.0.0/30')", 7...11, 7),
    ("ip('192.168.0.1').family()", 3...3, 3),
    ("ip('192.168.0.1').isUnspecified()", 3...3, 3),
    ("ip('192.168.0.1').isLoopback()", 3...3, 3),
    ("ip('192.168.0.1').isLinkLocalMulticast()", 3...3, 3),
    ("ip('192.168.0.1').isLinkLocalUnicast()", 3...3, 3),
    ("ip('192.168.0.1').isGlobalUnicast()", 3...3, 3),
    ("ip('2001:db8:3333:4444:5555:6666:7777:8888').family()", 5...5, 5),
    ("ip('2001:db8:3333:4444:5555:6666:7777:8888').isUnspecified()", 5...5, 5),
    ("ip('2001:db8:3333:4444:5555:6666:7777:8888').isLoopback()", 5...5, 5),
    ("ip('2001:db8:3333:4444:5555:6666:7777:8888').isLinkLocalMulticast()", 5...5, 5),
    ("ip('2001:db8:3333:4444:5555:6666:7777:8888').isLinkLocalUnicast()", 5...5, 5),
    ("ip('2001:db8:3333:4444:5555:6666:7777:8888').isGlobalUnicast()", 5...5, 5),
    ("cidr('2001:db8::/32').ip()", 3...3, 3),
    ("cidr('2001:db8::/32').prefixLength()", 3...3, 3),
    ("cidr('2001:db8::/32').masked()", 3...3, 3),
  ]

  /// cel-go `TestNetworkCost`.
  @Test(arguments: networkCases)
  func networkCost(_ expr: String, _ estimate: ClosedRange<UInt64>, _ runtime: UInt64) throws {
    try checkCost(env, expr, estimate: estimate, runtime: runtime)
  }

  /// cel-go `TestIPCost`: the IPv4 base costs 2 and the IPv6 base 4.
  @Test(arguments: [("ip('192.168.0.1')", UInt64(2)), ("ip('2001:db8:3333:4444:5555:6666:7777:8888')", 4)])
  func ipCost(_ base: String, _ baseCost: UInt64) throws {
    let fixed = baseCost...baseCost
    try checkCost(env, base, estimate: fixed, runtime: baseCost)
    for op in [
      ".family()", ".isUnspecified()", ".isLoopback()", ".isLinkLocalMulticast()", ".isLinkLocalUnicast()",
      ".isGlobalUnicast()",
    ] {
      try checkCost(env, base + op, estimate: adding(fixed, 1, 1), runtime: baseCost + 1)
    }
    // Plus the IPv4 operand (2) and the comparison of one to two traversal units.
    try checkCost(env, base + " == ip('192.168.0.1')", estimate: adding(fixed, 2 + 1, 2 + 2), runtime: baseCost + 3)
  }

  /// cel-go `TestCIDRCost`: both bases cost 2.
  @Test(arguments: ["cidr('192.168.0.0/16')", "cidr('2001:db8::/32')"])
  func cidrCost(_ base: String) throws {
    let fixed: ClosedRange<UInt64> = 2...2
    var cases: [(String, UInt64, UInt64, UInt64)] = [
      ("", 0, 0, 0), (".ip()", 1, 1, 1), (".prefixLength()", 1, 1, 1), (".masked()", 1, 1, 1),
      (" == cidr('2001:db8::/32')", 3, 4, 3),
    ]
    if base.contains("192.") {
      cases += [
        (".containsCIDR(cidr('192.0.0.0/30'))", 5, 9, 5), (".containsCIDR(cidr('192.168.0.0/16'))", 5, 9, 5),
        (".containsCIDR('192.0.0.0/30')", 5, 9, 5), (".containsCIDR('192.168.0.0/16')", 5, 9, 5),
        (".containsIP(ip('192.0.0.1'))", 2, 5, 2), (".containsIP(ip('192.169.0.1'))", 3, 6, 3),
        (".containsIP(ip('192.169.169.250'))", 3, 6, 3), (".containsIP('192.0.0.1')", 2, 5, 2),
        (".containsIP('192.169.0.1')", 3, 6, 3),
      ]
    } else {
      cases += [
        (".containsCIDR(cidr('2001:db8::/126'))", 5, 9, 5), (".containsCIDR(cidr('2001:db8::/32'))", 5, 9, 5),
        (".containsCIDR('2001:db8::/126')", 5, 9, 5), (".containsCIDR('2001:db8::/32')", 5, 9, 5),
        (".containsIP(ip('2001:db8:3333:4444:5555:6666:7777:8888'))", 5, 8, 5),
        (".containsIP(ip('2001:db8::1'))", 3, 6, 3),
        (".containsIP('2001:db8:3333:4444:5555:6666:7777:8888')", 5, 8, 5), (".containsIP('2001:db8::1')", 3, 6, 3),
      ]
    }
    for (op, min, max, runtime) in cases {
      try checkCost(env, base + op, estimate: adding(fixed, min, max), runtime: 2 + runtime)
    }
  }

  /// The runtime cost sizes IP and CIDR values in bytes, as cel-go's `IP.Size` and `CIDR.Size` do:
  /// comparing two IPv6 addresses traverses 16 bytes. Numbers from tools/oracle.
  @Test func ipAndCIDRAreSized() throws {
    try checkCost(env, "ip('::1') == ip('::1')", estimate: 3...4, runtime: 4)
    try checkCost(env, "cidr('2001:db8::/126') == cidr('2001:db8::/126')", estimate: 5...6, runtime: 6)
    try checkCost(env, "[ip('::1')] == [ip('::1')]", estimate: 23...23, runtime: 23)
  }
}

struct StringsCostTests {
  /// cel-go `TestQuoteUnquote`: the cost of `strings.quote` over each input (estimate and runtime).
  @Test(arguments: [
    ("this is a test", UInt64(2)),
    ("first\nsecond", 2),
    ("bell\u{07}", 1),
    ("\u{08}backspace", 1),
    ("\u{0C}form feed", 1),
    ("carriage \r return", 2),
    ("horizontal \ttab", 2),
    ("vertical \u{0B} tab", 2),
    ("double \\\\ slash", 2),
    ("two escape sequences \u{07}\n", 3),
    ("ends with \\", 2),
    ("\\ starts with", 2),
    ("printable unicode😀", 2),
    ("mid-string \" quote", 2),
    ("single-quote with \"double quote\"", 4),
    ("\\? and \\`", 1),
    ("this is a very very very long string used to ensure that cost tracking works", 8),
  ])
  func quoteCost(_ input: String, _ cost: UInt64) throws {
    let env = try Environment(.library(.strings))
    try checkCost(env, "strings.quote(\(GoFormat.quote(input)))", estimate: cost...cost, runtime: cost)
  }

  /// cel-go `TestStringCostLimitEnforced`: chained replaces grow the output exponentially, and the
  /// runtime cost follows the output size.
  @Test func costLimitEnforced() throws {
    let env = try Environment(.library(.strings))
    let replace = #".replace("", "AAAAAAAAAA")"#
    let program = try env.program(
      try env.compile(#""A""# + String(repeating: replace, count: 6)), options: [.costLimit(1000)])
    #expect(throws: EvalError.self) { try program.evaluate() }
  }
}

/// Edge cases of the size arithmetic (wrapping subtractions, negative and empty arguments), with
/// the estimate and the runtime cost (also of evaluations that fail) taken from tools/oracle.
struct CostEdgeCaseTests {
  @Test(arguments: [
    // end - start wraps when start > end.
    ("strings", "'hello'.substring(4, 2)", UInt64.max...UInt64.max, UInt64(3)),
    ("lists", "[1, 2, 3].slice(2, 1)", UInt64.max...UInt64.max, 22),
    // Negative literals count as 0.
    ("lists", "lists.range(-1)", 11...11, 12),
    ("lists", "[[1,2],[3]].flatten(-1)", 43...43, 42),
    ("lists", "[1,2,3].slice(-1, 2)", 23...23, 22),
    ("regex", "regex.replace('abc', 'b', '')", 1...4, 3),
    ("regex", "regex.extractAll('', '')", 11...11, 13),
    ("strings", "'abc'.split('')", 12...15, 15),
    ("strings", "'abc'.replace('', 'xy')", 5...14, 13),
    ("strings", "''.charAt(0)", 2...2, 2),
  ])
  func edgeCase(_ library: String, _ expr: String, _ estimate: ClosedRange<UInt64>, _ runtime: UInt64) throws {
    let env: Environment
    switch library {
    case "strings": env = try Environment(.library(.strings))
    case "lists": env = try Environment(.library(.lists))
    default: env = try Environment(.optionalTypes, .library(.regex))
    }
    let checked = try env.compile(expr)
    #expect(env.estimateCost(checked) == estimate)
    #expect(try env.program(checked, options: [.trackCost, .errorsAsValues]).evaluate().cost == runtime)
  }
}

struct EncodersCostTests {
  /// cel-go `TestJSONEncodeCostUnbounded`.
  @Test func jsonEncodeCostUnbounded() throws {
    let env = try Environment(.library(.encoders(version: 1)))
    let checked = try env.compile("json.encode('hello')")
    #expect(env.estimateCost(checked) == 0...UInt64.max)
    #expect(try env.program(checked, options: [.trackCost]).evaluate().cost == .max)
  }

  /// cel-go `TestDecodeNonBase64Error`.
  @Test func decodeNonBase64Error() throws {
    let env = try Environment(.library(.encoders(version: 1)), .macroCallTracking)
    let checked = try env.compile("base64.decode('abc-') == b''")
    #expect(env.estimateCost(checked) == 2...2)
    #expect(throws: EvalError.self) { try env.program(checked, options: [.trackCost]).evaluate() }
  }
}
