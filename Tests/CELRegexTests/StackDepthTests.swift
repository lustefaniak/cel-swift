// Patterns at the limits of Go's parser (nesting depth 1000, 1000 repetitions) compile and match
// without overflowing the stack. Not a port of a Go test: Go's stacks grow, while Swift's
// secondary threads (including swift-testing's and the concurrency pool's) have 512 KB, so this
// runs every stage (parse, simplify, compile, onepass analysis, the matchers, tree release) on
// such a thread.

import Testing

@testable import CELRegex

struct StackDepthTests {
  static let deepPatterns: [String] = [
    #"^x{1,1000}y{1,1000}$"#,
    #"x{0,1000}"#,
    #"(?:x{1,1000}){1}"#,
    String(repeating: "(", count: 998) + "x{0,1000}" + String(repeating: ")", count: 998),
    String(repeating: "(?:", count: 998) + "x{0,1000}" + String(repeating: ")", count: 998),
    String(repeating: "(", count: 999) + String(repeating: ")", count: 999),
    String(repeating: "(?:", count: 999) + String(repeating: ")*", count: 999),
    "((((((((((x{2}){2}){2}){2}){2}){2}){2}){2}){2}))",
    "(" + String(repeating: "|", count: 12345) + ")",
    String(repeating: "(?:a|", count: 999) + "b" + String(repeating: ")", count: 999),
    String(repeating: "a|", count: 5000) + "b",
    // Alternation factoring recurses once per common leading item (parse.go factor/collapse).
    "(?:" + String(repeating: ".", count: 990) + "x|" + String(repeating: ".", count: 990) + "y)",
    "(?:" + String(repeating: "a.", count: 495) + "x|" + String(repeating: "a.", count: 495) + "y)",
    "(?:" + String(repeating: "[ab]", count: 990) + "x|" + String(repeating: "[ab]", count: 990) + "y)",
    // One-pass analysis walks the whole program (up to 1000 instructions).
    #"^(?:ab){0,240}$"#,
    #"^x?x?"# + String(repeating: "y?", count: 400) + "$",
  ]

  @Test(arguments: deepPatterns.indices)
  func deepPatternCompilesAndMatches(_ k: Int) throws {
    let pattern = Self.deepPatterns[k]
    let re = try Regexp.compile(pattern)
    let input = String(repeating: "x", count: 1500) + "y"
    _ = re.matchString(input)
    _ = re.findStringSubmatchIndex(input)
    _ = re.findStringSubmatchIndex("xxy")
    _ = re.description
    let tree = try Syntax.parse(pattern, .perl)
    _ = tree.description
    _ = tree.simplify().description
    _ = try Regexp.programSize(pattern)
  }
}
