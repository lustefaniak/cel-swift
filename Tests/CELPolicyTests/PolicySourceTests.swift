import Testing

@testable import CELPolicy

/// Source positions of policy strings and their mapping back into the policy file, which the
/// compiler relies on to report CEL errors at the right line and column.
struct PolicySourceTests {
  @Test func snippets() {
    let source = PolicySource("a\nbc\n", description: "<input>")
    #expect(source.snippet(line: 1) == "a")
    #expect(source.snippet(line: 2) == "bc")
    #expect(source.snippet(line: 3) == "")
    #expect(source.snippet(line: 4) == nil)
    #expect(source.snippet(line: 0) == nil)
    #expect(PolicySource("").snippet(line: 1) == nil)
  }

  @Test func offsetsCountUnicodeScalars() {
    let source = PolicySource("ž: 1\nb: 2\n")
    #expect(source.lineOffsets == [5, 10, 11])
    #expect(source.offsetLocation(6) == PolicyLocation(line: 2, column: 1))
    #expect(source.locationOffset(PolicyLocation(line: 2, column: 1)) == 6)
  }

  /// The block scalar outputs of `yaml_parsing_cel_error` start at column 0 of their first line;
  /// the `+` of `("bar" + 1)` must map to the positions cel-go reports
  /// (TestWhitespaceHandlingErrorPresentation).
  @Test func blockScalarRelativePositions() throws {
    let source = try Testdata.policySource("yaml_parsing_cel_error")
    let policy = try PolicyParser().parse(source)
    let rule = try #require(policy.rule)
    let expected = [(11, 15), (15, 17), (19, 15), (23, 17)]
    for (match, (line, column)) in zip(rule.matches, expected) {
      let output = try #require(match.output)
      let start = try #require(policy.location(of: output.id))
      #expect(start.column == 0)
      let relative = source.relative(output.value, line: start.line, column: start.column)
      let lines = output.value.split(separator: "\n", omittingEmptySubsequences: false)
      let secondLine = lines[1]
      let plusColumn = try #require(secondLine.unicodeScalars.firstIndex(of: "+"))
      let offset =
        lines[0].unicodeScalars.count + 1 + secondLine.unicodeScalars.distance(
          from: secondLine.unicodeScalars.startIndex, to: plusColumn)
      let absolute = try #require(relative.absoluteLocation(ofOffset: offset))
      #expect(absolute.line == line)
      #expect(absolute.column == column)
    }
  }

  @Test func quotedScalarsStartInsideTheQuotes() throws {
    let text = "name: \"quoted\"\nrule:\n  match:\n    - output: 'x'\n"
    let policy = try PolicyParser().parse(PolicySource(text))
    let name = try #require(policy.location(of: policy.name.id))
    #expect(name.line == 1)
    #expect(name.column == 7)
    let output = try #require(policy.rule?.matches.first?.output)
    let loc = try #require(policy.location(of: output.id))
    #expect(loc.line == 4)
    #expect(loc.column == 15)
  }

  @Test func blockScalarValuesKeepIndentation() throws {
    let source = try Testdata.policySource("yaml_parsing")
    let policy = try PolicyParser().parse(source)
    let outputs = try #require(policy.rule).matches.compactMap(\.output?.value)
    #expect(
      outputs == [
        "        \"a string expression that \" +\n        \"is folded\"",
        "        '''a string expression that\n        is folded'''",
        "          '''a string expression that\n          is folded'''",
        "          \"a string expression that \" +\n          \"is a literal block\"",
        "        '''a string expression that\n        is a literal block'''",
        "          '''a string expression that\n          is a literal block'''",
        "'no match encountered'",
      ])
    #expect(policy.description.value == "A block literal description with mutliple lines.\n - line 2\n - line 3\n")
  }

  @Test func errorDisplayUsesWideMarkersForMultibyteCharacters() {
    var errors = PolicyError(source: PolicySource("ažíb\n", description: "<input>"))
    errors.report(id: 0, location: PolicyLocation(line: 1, column: 2), message: "bad")
    #expect(errors.description == "ERROR: <input>:1:3: bad\n | ažíb\n | .\u{ff0e}\u{ff3e}")
  }

  @Test func errorDisplaySortsByLocationAndTruncates() {
    var errors = PolicyError(source: PolicySource("a\nb\n", description: "f"))
    errors.report(id: 0, location: PolicyLocation(line: 2, column: 0), message: "second")
    errors.report(id: 0, location: PolicyLocation(line: 1, column: 0), message: "first")
    #expect(errors.description == "ERROR: f:1:1: first\n | a\n | ^\nERROR: f:2:1: second\n | b\n | ^")

    var many = PolicyError(source: PolicySource("", description: "f"))
    for _ in 0..<102 {
      many.report(id: 0, location: .none, message: "x")
    }
    let lines = many.description.split(separator: "\n")
    #expect(lines.count == 101)
    #expect(lines.last == "2 more errors were truncated")
  }
}
