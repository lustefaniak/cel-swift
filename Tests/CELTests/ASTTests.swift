// Copyright 2023 Google LLC
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

// Ported from cel-go common/ast/ast_test.go, expr_test.go and navigable_test.go (non-proto parts).
// cel-go type-checks the inputs first; the checker does not change ids or shapes for these inputs, so
// parsed ASTs are used here.

import Testing

@testable import CEL

private func mustParse(_ expr: String) throws -> AST {
  let (ast, errs) = try Parser(.macros(Macro.allMacros)).parse(TextSource(expr))
  #expect(errs.isEmpty, "\(errs.toDisplayString())")
  return ast
}

@Suite struct ASTTests {
  @Test func sourceInfo() {
    var info = SourceInfo(source: TextSource("a\n? b\n: c", description: "custom description"))
    #expect(info.description == "custom description")
    #expect(info.lineOffsets.count == 3)
    info.setOffsetRange(1, OffsetRange(start: 0, stop: 1))
    info.setOffsetRange(2, OffsetRange(start: 4, stop: 5))
    info.setOffsetRange(3, OffsetRange(start: 8, stop: 9))
    #expect(info.startLocation(1) == Location(line: 1, column: 0))
    #expect(info.stopLocation(1) == Location(line: 1, column: 1))
    #expect(info.startLocation(2) == Location(line: 2, column: 2))
    #expect(info.stopLocation(2) == Location(line: 2, column: 3))
    #expect(info.startLocation(3) == Location(line: 3, column: 2))
    #expect(info.stopLocation(3) == Location(line: 3, column: 3))
    #expect(info.computeOffset(line: 3, column: 2) == 8)
  }

  struct MockRelativeSource: Source {
    let base: TextSource
    let lineOffsets: [Int32]
    let baseLocation: Location
    var content: String { base.content }
    var scalars: [Unicode.Scalar] { base.scalars }
    var description: String { base.description }
    func locationOffset(_ location: Location) -> Int32? { base.locationOffset(location) }
    func offsetLocation(_ offset: Int32) -> Location? {
      offset == 0 ? baseLocation : base.offsetLocation(offset)
    }
    func newLocation(line: Int, column: Int) -> Location { base.newLocation(line: line, column: column) }
    func snippet(line: Int) -> String? { base.snippet(line: line) }
  }

  @Test func newSourceInfoRelative() {
    let info = SourceInfo(
      source: MockRelativeSource(
        base: TextSource("\n \n a || b ?\n cond1 :\n cond2"), lineOffsets: [1, 2, 13, 25],
        baseLocation: Location(line: 2, column: 1)))
    #expect(info.computeOffset(line: 1, column: 0) == 2)
    #expect(info.computeOffset(line: 2, column: 3) == 6)
    #expect(info.computeOffset(line: 3, column: 1) == 15)
  }

  @Test func maxID() throws {
    var ast = try mustParse("has({'a':'key'}.key)")
    let maxID = ast.maxID
    ast.sourceInfo.setMacroCall(maxID + 2, .ident(id: maxID + 1, "dummy"))
    #expect(ast.maxID == maxID + 4)
  }

  @Test func nodeCount() throws {
    #expect(try mustParse("1 + 2").nodeCount == 3)
  }

  @Test(arguments: [
    ("'a' == 'b'", 1), ("'a'.size()", 1), ("[1, 2].size()", 2), ("size('a')", 1),
    ("has({'a': 1}.a)", 2), ("{'a': 1}", 1), ("{'a': 1}['a']", 2),
    ("[1, 2, 3].exists(i, i % 2 == 1)", 4), ("google.expr.proto3.test.TestAllTypes{}", 1),
    ("google.expr.proto3.test.TestAllTypes{repeated_int32: [1, 2]}", 2),
  ])
  func heights(expr: String, height: Int) throws {
    let ast = try mustParse(expr)
    #expect(ast.heights[ast.expr.id] == height)
  }

  @Test func hasExtension() {
    var info = SourceInfo(source: TextSource("true", description: "test-only"))
    info.addExtension(
      SourceExtension(id: "json_name", version: .init(major: 1, minor: 1), components: [.runtime]))
    #expect(info.hasExtension(id: "json_name", minVersion: .init(major: 1, minor: 0)))
    #expect(!info.hasExtension(id: "json_name", minVersion: .init(major: 2, minor: 1)))
    #expect(!info.hasExtension(id: "unrelated", minVersion: .init(major: 0, minor: 0)))
  }

  @Test func sourceInfoRenumberIDs() {
    var info = SourceInfo(source: nil)
    for old in Int64(1)...5 {
      info.setOffsetRange(old, OffsetRange(start: Int32(old), stop: Int32(old) + 1))
    }
    let original = info.offsetRanges
    var next: Int64 = 101
    var idMap: [Int64: Int64] = [:]
    info.renumberIDs { old in
      if let id = idMap[old] { return id }
      idMap[old] = next
      next += 1
      return next - 1
    }
    #expect(info.offsetRanges.count == 5)
    for old in Int64(1)...5 {
      #expect(info.offsetRange(old + 100) == original[old])
    }
  }

  @Test func renumberIDs() {
    var e = Expr.unspecified(id: 10)
    e.renumberIDs { _ in 101 }
    #expect(e.id == 101)
    var call = Expr.call(id: 1, function: "f", args: [.ident(id: 2, "a"), .literal(id: 3, .int(1))])
    call.renumberIDs { $0 + 100 }
    #expect(call.id == 101)
    #expect(call.asCall?.args.map(\.id) == [102, 103])
  }

  @Test(arguments: [
    ("'a' == 'b'", 3, 1, 1, Int64(4)), ("'a'.size()", 2, 1, 1, 3), ("[1, 2, 3]", 4, 0, 1, 5),
    ("[1, 2, 3][0]", 6, 1, 2, 7), ("{1u: 'hello'}", 3, 0, 1, 5),
    ("{'hello': 'world'}.hello", 4, 0, 2, 6), ("type(1) == int", 4, 2, 2, 5),
    ("google.expr.proto3.test.TestAllTypes{single_int32: 1}", 2, 0, 1, 4),
    ("[true].exists(i, i)", 11, 3, 3, 14),
  ])
  func navigateAST(expr: String, descendantCount: Int, callCount: Int, maxDepth: Int, maxID: Int64)
    throws
  {
    let ast = try mustParse(expr)
    let nav = NavigableExpr(root: ast.expr)
    let descendants = nav.matchDescendants { _ in true }
    #expect(descendants.count == descendantCount)
    #expect(descendants.map(\.depth).max() == maxDepth)
    #expect(ast.maxID == maxID)
    let calls = NavigableExpr.matchSubset(descendants) { $0.expr.asCall != nil }
    #expect(calls.count == callCount)
  }

  @Test(arguments: [
    ("'a' == 'b'", 2, false), ("'a' == 'b'", 1, true), ("[1, 2, 3][0]", 3, false),
    ("[1, 2, 3][0]", 2, true), ("[1, 2, 3][0]", 1, true), ("[true].exists(i, i)", 250, false),
    ("[true].exists(i, i)", 3, true), ("[true].exists(i, i)", 4, false),
    ("[true].exists(i, i)", 0, false), ("[true].exists(i, i)", -1, false),
  ])
  func exceedsDepth(expr: String, maxDepth: Int, want: Bool) throws {
    #expect(try mustParse(expr).exceedsDepth(maxDepth) == want)
  }

  @Test func exceedsDepthBoundedTraversal() {
    let depth = 300
    var expr = Expr.literal(id: 1, .bool(true))
    for i in 0..<depth {
      expr = .call(id: Int64(i + 2), function: Operators.logicalNot, args: [expr])
    }
    let deep = AST(expr: expr, sourceInfo: SourceInfo(source: nil))
    #expect(deep.exceedsDepth(250))
    #expect(deep.exceedsDepth(depth))
    #expect(!deep.exceedsDepth(depth + 1))
    #expect(!deep.exceedsDepth(0))
  }

  @Test func debugStringWithIDs() throws {
    let ast = try mustParse("a.b(1, [2])")
    #expect(
      ExprDebug.toDebugStringWithIDs(ast.expr)
        == "a@id:1 .b(\n  1@id:3 ,\n  [\n    2@id:5 \n  ]@id:4 \n)@id:2 ")
  }
}
