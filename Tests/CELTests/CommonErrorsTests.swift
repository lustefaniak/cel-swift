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

// Ported from cel-go common/errors_test.go.

import Testing

@testable import CEL

@Suite struct CommonErrorsTests {
  @Test func errors() {
    let source = TextSource("a.b\n&&arg(missing, paren", description: "errors-test")
    var errors = CELErrors(source: source)
    errors.reportError(at: Location(line: 1, column: 1), "No such field")
    #expect(errors.errors.count == 1)
    errors.reportError(at: Location(line: 2, column: 20), "Syntax error, missing paren")
    #expect(errors.errors.count == 2)
    let want =
      "ERROR: errors-test:1:2: No such field\n" + " | a.b\n" + " | .^\n"
      + "ERROR: errors-test:2:21: Syntax error, missing paren\n" + " | &&arg(missing, paren\n"
      + " | ....................^"
    #expect(errors.toDisplayString() == want)
  }

  @Test func reportingLimit() {
    var errors = CELErrors(source: TextSource("hello world"))
    for i in 0..<(2 * errors.maxErrorsToReport) {
      errors.reportError(at: .none, "error \(i)")
    }
    #expect(errors.toDisplayString().hasSuffix("100 more errors were truncated"))
  }

  @Test func appendReportingLimit() {
    var errors = CELErrors(source: TextSource("hello world"))
    for i in 0..<75 {
      errors.reportError(at: .none, "error \(i)")
    }
    var errors2 = CELErrors(source: TextSource("hello world"))
    for i in 0..<75 {
      errors2.reportError(at: .none, "error \(i + 75)")
    }
    errors = errors.appending(errors2.errors)
    #expect(errors.toDisplayString().hasSuffix("50 more errors were truncated"))
  }

  @Test func wideAndNarrowCharacters() {
    let source = TextSource("你好吗\n我a很好\n", description: "errors-test")
    var errors = CELErrors(source: source)
    errors.reportError(at: Location(line: 2, column: 3), "Unexpected character '好'")
    let want =
      "ERROR: errors-test:2:4: Unexpected character '好'\n" + " | 我a很好\n" + " | ．.．＾"
    #expect(errors.toDisplayString() == want)
  }

  @Test func wideAndNarrowCharactersWithEmojis() {
    let source = TextSource("      '😁' in ['😁', '😑', '😦'] && in.😁", description: "errors-test")
    var errors = CELErrors(source: source)
    errors.reportError(
      at: Location(line: 1, column: 32),
      "Syntax error: extraneous input 'in' expecting {'[', '{', '(', '.', '-', '!', 'true', 'false', 'null', NUM_FLOAT, NUM_INT, NUM_UINT, STRING, BYTES, IDENTIFIER}"
    )
    errors.reportError(
      at: Location(line: 1, column: 35), "Syntax error: token recognition error at: '😁'")
    errors.reportError(
      at: Location(line: 1, column: 36), "Syntax error: missing IDENTIFIER at '<EOF>'")
    let want =
      "ERROR: errors-test:1:33: Syntax error: extraneous input 'in' expecting {'[', '{', '(', '.', '-', '!', 'true', 'false', 'null', NUM_FLOAT, NUM_INT, NUM_UINT, STRING, BYTES, IDENTIFIER}\n"
      + " |       '😁' in ['😁', '😑', '😦'] && in.😁\n"
      + " | .......．.......．....．....．......^\n"
      + "ERROR: errors-test:1:36: Syntax error: token recognition error at: '😁'\n"
      + " |       '😁' in ['😁', '😑', '😦'] && in.😁\n"
      + " | .......．.......．....．....．.........＾\n"
      + "ERROR: errors-test:1:37: Syntax error: missing IDENTIFIER at '<EOF>'\n"
      + " |       '😁' in ['😁', '😑', '😦'] && in.😁\n"
      + " | .......．.......．....．....．.........．^"
    #expect(errors.toDisplayString() == want)
  }
}
