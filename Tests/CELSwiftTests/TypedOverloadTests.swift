// Function overloads implemented by Swift closures over typed arguments.

import CEL
import CELSwift
import Foundation
import Testing

private struct GlobError: Error, CustomStringConvertible {
  var description: String { "invalid glob pattern" }
}

private func glob(_ path: String, _ pattern: String) throws -> Bool {
  guard !pattern.isEmpty else { throw GlobError() }
  if pattern.hasSuffix("/**") {
    return path.hasPrefix(String(pattern.dropLast(2)))
  }
  return path == pattern
}

struct TypedOverloadTests {
  private func environment() throws -> Environment {
    try Environment(
      .variables(from: SelectFacts.self),
      .function("glob", .overload("glob_string_string") { (path: String, pattern: String) in try glob(path, pattern) }),
      .function(
        "touches",
        .memberOverload("change_request_touches_string") { (pr: ChangeRequest, pattern: String) in
          try pr.files.contains { try glob($0, pattern) }
        }),
      .function("isBot", .overload("is_bot_string") { (login: String) in login.hasSuffix("[bot]") }),
      .function("ageDays", .memberOverload("change_request_age_days") { (pr: ChangeRequest) in
        Int(Date(timeIntervalSince1970: 1_790_864_000).timeIntervalSince(pr.createdAt) / 86_400)
      }),
      .function("between", .overload("between_int_int_int") { (value: Int, low: Int, high: Int) in
        (low...high).contains(value)
      }),
      .function(
        "within", .memberOverload("int_within_int_int") { (value: Int, low: Int, high: Int) in (low...high).contains(value) }),
      .function("answer", .overload("answer") { 42 }),
      .function("reviewerOf", .memberOverload("change_request_reviewer") { (pr: ChangeRequest) in pr.reviewer }),
      .function(
        "renamed",
        .memberOverload("change_request_renamed_string") { (pr: ChangeRequest, title: String) -> ChangeRequest in
          var copy = pr
          copy.title = title
          return copy
        })
    )
  }

  private func evaluate(_ expression: String, _ facts: SelectFacts = .sample) throws -> Value {
    let env = try environment()
    return try env.program(env.compile(expression)).evaluate(Variables(encoding: facts)).value
  }

  @Test(arguments: [
    ("glob('Sources/Retry.swift', 'Sources/**')", Value(true)),
    ("pr.touches('Tests/**')", Value(true)),
    ("pr.touches('Docs/**')", Value(false)),
    ("isBot('dependabot[bot]') && !isBot(pr.author)", Value(true)),
    ("pr.ageDays()", Value(10)),
    ("between(pr.additions, 100, 200) && pr.deletions.within(0, 50)", Value(true)),
    ("answer() == 42", Value(true)),
    ("pr.reviewerOf() == null", Value(true)),
    ("pr.renamed('x').title + pr.title", Value("xFix the retry loop")),
  ])
  func typedOverloads(expression: String, expected: Value) throws {
    #expect(try evaluate(expression) == expected)
  }

  @Test func signaturesAreDerivedFromTheClosure() throws {
    let env = try environment()
    let touches = try #require(env.functions.first { $0.name == "touches" }?.overloads.first)
    #expect(touches.argumentTypes == [.object("prbar.ChangeRequest"), .string])
    #expect(touches.resultType == .bool)
    #expect(touches.isMemberFunction)
    let reviewer = try #require(env.functions.first { $0.name == "reviewerOf" }?.overloads.first)
    #expect(reviewer.resultType == .wrapper(.string))
    #expect {
      _ = try env.compile("glob(1, 'x')")
    } throws: { error in
      "\(error)".contains("found no matching overload for 'glob' applied to '(int, string)'")
    }
  }

  @Test func thrownErrorsBecomeEvaluationErrors() throws {
    let env = try environment()
    let program = try env.program(env.compile("glob('a', '')"))
    #expect {
      _ = try program.evaluate()
    } throws: { error in
      (error as? EvalError)?.message == "invalid glob pattern"
    }
    // Errors are values: `||` absorbs them like any other error.
    #expect(try evaluate("glob('a', '') || true") == true)
  }

  @Test func undescribableTypesFailTheDeclaration() {
    enum Shape: Codable { case circle(radius: Double) }
    #expect(throws: DeclarationError.self) {
      _ = try Environment(.function("f", .overload("f_shape") { (value: Shape) in "\(value)" }))
    }
  }
}
