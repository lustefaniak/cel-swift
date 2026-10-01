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

// Ported from cel-go common/source_test.go.

import Testing

@testable import CEL

@Suite struct CommonSourceTests {
  @Test func description() {
    let contents = "example content\nsecond line"
    let source = TextSource(contents, description: "description-test")
    #expect(source.content == contents)
    #expect(source.description == "description-test")
    #expect(source.snippet(line: 2) == "second line")
    #expect(source.snippet(line: 1) == "example content")
  }

  @Test func locationOffset() throws {
    let contents = "c.d &&\n\t b.c.arg(10) &&\n\t test(10)"
    let source = TextSource(contents, description: "offset-test")
    #expect(source.lineOffsets == [7, 24, 35])
    let charStart = try #require(source.locationOffset(Location(line: 1, column: 2)))
    let charEnd = try #require(source.locationOffset(Location(line: 3, column: 2)))
    let scalars = Array(contents.unicodeScalars)
    #expect(TextSource.string(scalars[Int(charStart)..<Int(charEnd)]) == "d &&\n\t b.c.arg(10) &&\n\t ")
    #expect(source.locationOffset(Location(line: 4, column: 0)) == nil)
  }

  @Test func snippetMultiline() {
    let source = TextSource("hello\nworld\nmy\nbub\n", description: "four-line-test")
    #expect(source.snippet(line: 1) == "hello")
    #expect(source.snippet(line: 2) == "world")
    #expect(source.snippet(line: 3) == "my")
    #expect(source.snippet(line: 4) == "bub")
    #expect(source.snippet(line: 5) == "")
  }

  @Test func snippetSingleline() {
    let source = TextSource("hello, world", description: "one-line-test")
    #expect(source.snippet(line: 1) == "hello, world")
    #expect(source.snippet(line: 2) == nil)
  }

  @Test func infoSourceHasNoContent() {
    let source = TextSource(description: "", lineOffsets: [])
    #expect(source.content == "")
  }

  @Test func textSourceWithLimitExceeded() {
    #expect(throws: SizeLimitError.self) {
      _ = try TextSource("greetings", limit: 5)
    }
    do {
      _ = try TextSource("greetings", limit: 5)
    } catch {
      #expect(error.description.contains("size exceeds limit"))
    }
  }

  @Test func textSourceWithLimitMultibyteWithinLimit() throws {
    let data = "🙂🙂"
    let source = try TextSource(data, limit: 2)
    #expect(source.content == data)
  }

  @Test func offsetLocation() {
    let source = TextSource("ab\ncd")
    #expect(source.offsetLocation(0) == Location(line: 1, column: 0))
    #expect(source.offsetLocation(4) == Location(line: 2, column: 1))
  }
}
