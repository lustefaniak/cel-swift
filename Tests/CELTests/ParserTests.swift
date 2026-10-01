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

// Ported from cel-go parser/parser_test.go. The testCases table is extracted verbatim from the Go
// source by tools/parsedump into ParserFixtures/parser_test_cases.json.

import Testing

@testable import CEL

struct ParserTestCase: Decodable, Sendable, CustomTestStringConvertible {
  let i: String
  let p: String?
  let e: String?
  let l: String?
  let m: String?
  let opts: [String]?

  var testDescription: String { i }

  /// Maps the Go source of a parser option in the table to its Swift equivalent.
  func options() -> [ParserOption] {
    (opts ?? []).map { source in
      switch source {
      case "EnableHiddenAccumulatorName(false)": return .enableHiddenAccumulatorName(false)
      case "ErrorRecoveryLimit(10)": return .errorRecoveryLimit(10)
      case "ErrorReportingLimit(2)": return .errorReportingLimit(2)
      case "EnableIdentEscapeSyntax(true)": return .enableIdentEscapeSyntax(true)
      case "EnableIdentEscapeSyntax(false)": return .enableIdentEscapeSyntax(false)
      case "ErrorRecoveryLookaheadTokenLimit(10)": return .errorRecoveryLookaheadTokenLimit(10)
      case "EnableOptionalSyntax(true)": return .enableOptionalSyntax(true)
      default:
        if source.hasPrefix("Macros(NewGlobalVarArgMacro(\"noop_macro\"") {
          return .macros([
            Macro.globalVarArg("noop_macro") {
              (_: ExprHelper, _: Expr?, _: [Expr]) throws(CELError) -> Expr? in nil
            }
          ])
        }
        fatalError("unmapped parser option: \(source)")
      }
    }
  }
}

struct ParserTestTables: Decodable {
  let parser: [ParserTestCase]
  let unparser: [UnparserTestCase]

  static let shared = ParserFixtures.load("parser_test_cases.json", as: ParserTestTables.self)
}

func newTestParser(_ options: [ParserOption] = []) throws -> Parser {
  try Parser(
    options: [
      .macros(Macro.allMacros), .maxRecursionDepth(32), .errorRecoveryLimit(4),
      .errorRecoveryLookaheadTokenLimit(4), .populateMacroCalls(true),
    ] + options)
}

@Suite struct ParserTests {
  @Test(arguments: ParserTestTables.shared.parser)
  func parse(_ tc: ParserTestCase) throws {
    let p = try newTestParser(tc.options())
    let src = TextSource(tc.i)
    let (parsed, errors) = p.parse(src)
    if !errors.isEmpty {
      let actualErr = errors.toDisplayString()
      let expected = try #require(tc.e, "Unexpected errors: \(actualErr)")
      #expect(stripWhitespace(actualErr) == stripWhitespace(expected), "\(actualErr)")
      return
    }
    #expect(tc.e == nil, "Expected error not thrown: \(tc.e ?? "")")
    let actualWithKind = ExprDebug.toAdornedDebugString(parsed.expr, adorner: KindAndIDAdorner())
    #expect(stripWhitespace(actualWithKind) == stripWhitespace(tc.p ?? ""), "\(actualWithKind)")

    if let l = tc.l {
      let actualWithLocation = ExprDebug.toAdornedDebugString(
        parsed.expr, adorner: LocationAdorner(sourceInfo: parsed.sourceInfo))
      #expect(stripWhitespace(actualWithLocation) == stripWhitespace(l), "\(actualWithLocation)")
    }

    if let m = tc.m {
      let actualMacroCalls = macroCallsString(parsed.sourceInfo)
      #expect(stripWhitespace(actualMacroCalls) == stripWhitespace(m), "\(actualMacroCalls)")
    }

    // Verify there are no unused IDs in the source info.
    let astIDs = parsed.ids
    let unusedIDs = parsed.sourceInfo.offsetRanges.keys.filter { !astIDs.contains($0) }.sorted()
    #expect(unusedIDs.isEmpty, "SourceInfo has offset ranges for unused ids \(unusedIDs)")

    // Verify that source info offset ranges are shifted when the source is prepended with whitespace.
    let padding = String(repeating: "         \n", count: 10)
    let padSrc = RelativeSource(
      source: TextSource(padding + src.content), localSource: src,
      absoluteLocation: Location(line: 11, column: 0))
    let (padded, padErrs) = p.parse(padSrc)
    #expect(padErrs.isEmpty, "Unexpected errors with padded source: \(padErrs.toDisplayString())")
    for (id, origRange) in parsed.sourceInfo.offsetRanges {
      let padRange = padded.sourceInfo.offsetRange(id)
      #expect(
        padRange == OffsetRange(start: origRange.start + 100, stop: origRange.stop + 100),
        "ID \(id) offset range mismatch")
    }
  }

  @Test func expressionSizeCodePointLimit() throws {
    let p = try Parser(.macros(Macro.allMacros), .expressionSizeCodePointLimit(2))
    let (_, errs) = p.parse(TextSource("foo"))
    #expect(errs.errors.count == 1)
    #expect(errs.errors.first?.message == "expression code point size exceeds limit: size: 3, limit 2")
  }

  @Test func maxExpressionNodeCount() throws {
    let p = try Parser(.macros(Macro.allMacros), .maxExpressionNodeCount(10))
    let (_, errs) = p.parse(TextSource("a.exists(x, x.exists(y, y == 1))"))
    let first = try #require(errs.errors.first)
    #expect(first.message.contains("expression count exceeds limit of 10 while expanding macro 'exists'"))
  }

  @Test func parserOptionErrors() {
    #expect(throws: ParserOptionError.self) { try Parser(.macros(Macro.allMacros), .maxRecursionDepth(-2)) }
    #expect(throws: ParserOptionError.self) { try Parser(.errorRecoveryLimit(-2)) }
    #expect(throws: ParserOptionError.self) { try Parser(.errorRecoveryLookaheadTokenLimit(0)) }
    #expect(throws: ParserOptionError.self) { try Parser(.errorReportingLimit(0)) }
    #expect(throws: ParserOptionError.self) { try Parser(.expressionSizeCodePointLimit(-2)) }
    #expect(throws: ParserOptionError.self) { try Parser(.maxExpressionNodeCount(-2)) }
    do {
      _ = try Parser(.maxRecursionDepth(-2))
    } catch {
      #expect(error.description == "max recursion depth must be greater than or equal to -1: -2")
    }
  }

  @Test func parseErrorData() throws {
    let p = try newTestParser()
    let (_, iss) = p.parse(TextSource("a.?b"))
    #expect(iss.errors.count == 1)
    let celErr = try #require(iss.errors.first)
    #expect(celErr.exprID == 2)
    #expect(celErr.message.contains("unsupported syntax"))
  }
}
