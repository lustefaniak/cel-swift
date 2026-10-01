// Ported from cel-go cel/cel_test.go (TestSubsetStdLib, TestSubsetStdLibError, TestSubsetStdLibMerge,
// TestSubsetStdLibMergeError, TestMacroSubset) against the public API.

import CEL
import Testing

@Suite("Standard library subsets")
struct APILibrarySubsetTests {
  static let subset = Library.Subset(
    includedMacros: ["has"],
    includedFunctions: [
      .init("_==_"), .init("_!=_"), .init("_&&_"), .init("_||_"), .init("!_"),
      .init("size", overloadIDs: ["list_size"]),
    ])

  struct Case: Sendable, CustomTestStringConvertible {
    var name: String
    var expression: String
    var expected: Value?
    var testDescription: String { name }
  }

  static let cases: [Case] = [
    Case(name: "has macro", expression: "!has({}.a)", expected: true),
    Case(name: "not equals", expression: "has({}.a) != true", expected: true),
    Case(
      name: "logical operators", expression: "has({}.a) != true && has({'b': 1}.b) == true", expected: true),
    Case(name: "list size - allowed", expression: "[1, 2, 3].size()", expected: 3),
    Case(name: "excluded macro", expression: "[1, 2, 3].exists(i, i != 0)", expected: nil),
    Case(name: "string size - not allowed", expression: "'hello'.size()", expected: nil),
  ]

  @Test(arguments: cases)
  func subsetStdLib(_ testCase: Case) throws {
    let env = try Environment.custom(.library(.standard(subset: Self.subset)))
    guard let expected = testCase.expected else {
      #expect(throws: CompileError.self) { try env.compile(testCase.expression) }
      return
    }
    let result = try env.program(env.compile(testCase.expression)).evaluate()
    #expect(result.value == expected)
  }

  @Test func invalidSubset() {
    #expect {
      _ = try Library.standard(subset: .init(includedMacros: ["has"], excludedMacros: ["exists"]))
    } throws: { error in
      "\(error)".contains("invalid subset")
    }
  }

  @Test func mergesWithExistingDeclaration() throws {
    _ = try Environment.custom(
      .function("size", .memberOverload("string_size", argTypes: [.string], resultType: .int)),
      .library(.standard(subset: .init(includedFunctions: [.init("size", overloadIDs: ["string_size"])]))))
  }

  @Test func mergeConflictFails() {
    #expect {
      _ = try Environment.custom(
        .function("size", .memberOverload("string_size", argTypes: [.string], resultType: .uint)),
        .library(.standard(subset: .init(includedFunctions: [.init("size", overloadIDs: ["string_size"])]))))
    } throws: { error in
      "\(error)".contains("merge failed")
    }
  }

  @Test func macroSubset() throws {
    let env = try Environment.custom(
      .library(.standard(subset: .init(includedMacros: ["has"]))),
      .variable("name", .map(key: .string, value: .string)))
    let result = try env.program(env.compile("has(name.first)")).evaluate(["name": ["first": "Jim"]])
    #expect(result.value == true)
    #expect(throws: CompileError.self) { try env.compile("[1, 2].all(i, i > 0)") }
  }

  @Test func excludedOverloads() throws {
    let env = try Environment.custom(
      .library(.standard(subset: .init(excludedFunctions: [.init("size", overloadIDs: ["string_size"])]))))
    #expect(try env.program(env.compile("size([1])")).evaluate().value == 1)
    #expect(throws: CompileError.self) { try env.compile("'abc'.size()") }
    #expect(env.hasFunction(named: "size"))
  }

  @Test func disabledSubsetHasNoFunctions() throws {
    let library = try Library.standard(subset: .init(isDisabled: true))
    let env = try Environment.custom(.library(library))
    #expect(!env.hasFunction(named: "_+_"))
    #expect(env.hasLibrary(named: "cel.lib.std"))
  }
}
