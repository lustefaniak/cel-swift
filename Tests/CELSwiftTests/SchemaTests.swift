// CELSchema: CEL types derived from Decodable Swift types, and the environment options that
// declare them.

import CEL
import CELSwift
import Foundation
import Testing

private struct Node: Codable {
  var name: String
  var children: [Node]
  var parent: Box?
}

private final class Box: Codable {
  var node: Node?
}

private final class Recursive: Codable {
  var value: Int
  var next: Recursive?
}

private enum Kind: String, Codable {
  case bug, feature
}

private struct WithPlainEnum: Codable {
  var kind: Kind
}

private struct WithOptionalPlainEnum: Codable {
  var kind: Kind?
}

private struct Generic<T: Codable>: Codable {
  var value: T
}

private struct Validating: Codable {
  var count: Int
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    count = try container.decode(Int.self, forKey: .count)
    guard count > 0 else {
      throw DecodingError.dataCorruptedError(forKey: .count, in: container, debugDescription: "count must be positive")
    }
  }
}

private struct Wrapper: Codable {
  var id: String
  init(from decoder: any Decoder) throws {
    id = try decoder.singleValueContainer().decode(String.self)
  }
  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(id)
  }
}

struct SchemaTests {
  @Test func fieldsAndTypes() throws {
    let schema = try CELSchema(for: ChangeRequest.self)
    #expect(schema.type == .object("prbar.ChangeRequest"))
    let fields = try #require(schema.fields)
    #expect(fields.map(\.name) == [
      "repo", "number", "title", "author", "draft", "labels", "additions", "deletions", "files", "baseRef",
      "createdAt", "reviewer",
    ])
    #expect(fields.map(\.type) == [
      .string, .int, .string, .string, .bool, .list(.string), .int, .int, .list(.string), .string, .timestamp,
      .wrapper(.string),
    ])
    #expect(fields.map(\.isOptional) == Array(repeating: false, count: 11) + [true])
  }

  @Test func nestedStructsAreObjectTypesRootFirst() throws {
    let schema = try CELSchema(for: DecideFacts.self)
    #expect(schema.structTypes.map(\.typeName) == [
      "CELSwiftTests.DecideFacts", "prbar.ChangeRequest", "prbar.Review", "CELSwiftTests.Finding",
    ])
    let review = try #require(schema.structType(named: "prbar.Review"))
    #expect(review.fields.map(\.type) == [.string, .double, .list(.object("CELSwiftTests.Finding")), .double, .duration])
    let finding = try #require(schema.structType(named: "CELSwiftTests.Finding"))
    #expect(finding.field(named: "severity")?.type == .int)
    #expect(finding.field(named: "title")?.type == .wrapper(.string))
    #expect(schema.fields?.first { $0.name == "lists" }?.type == .map(key: .string, value: .list(.string)))
  }

  @Test func recursionThroughCollectionsAndOptionals() throws {
    let schema = try CELSchema(for: Node.self)
    let node = try #require(schema.structType(named: "CELSwiftTests.Node"))
    #expect(node.field(named: "children")?.type == .list(.object("CELSwiftTests.Node")))
    #expect(node.field(named: "parent")?.type == .object("CELSwiftTests.Box"))
    #expect(schema.structType(named: "CELSwiftTests.Box")?.field(named: "node")?.type == .object("CELSwiftTests.Node"))

    let recursive = try CELSchema(for: Recursive.self)
    #expect(recursive.fields?.last?.type == .object("CELSwiftTests.Recursive"))
  }

  @Test func enumsNeedCaseIterable() throws {
    #expect {
      _ = try CELSchema(for: WithPlainEnum.self)
    } throws: { error in
      guard let error = error as? DeclarationError else { return false }
      return error.message.hasPrefix("CELSwiftTests.WithPlainEnum.kind: Kind.init(from:) fails on placeholder values")
        && error.message.hasSuffix("enums need CaseIterable or CELValueRepresentable")
    }
    // Optional fields need no placeholder instance, but a type: raw enums have their raw type.
    #expect(try CELSchema(for: WithOptionalPlainEnum.self).fields?.first?.type == .wrapper(.string))
    #expect(try CELSchema(for: Verdict.self).type == .string)
    #expect(try CELSchema(for: Severity.self).type == .int)
  }

  @Test func validatingDecodersMustAcceptPlaceholders() {
    #expect(throws: DeclarationError.self) {
      _ = try CELSchema(for: Validating.self)
    }
  }

  @Test func singleValueTypesTakeTheirValueType() throws {
    #expect(try CELSchema(for: Wrapper.self).type == .string)
    #expect(try CELSchema(for: UUID.self).type == .string)
    #expect(try CELSchema(for: [Wrapper].self).type == .list(.string))
  }

  @Test func genericTypeNamesAreSanitised() throws {
    let schema = try CELSchema(for: Generic<Int>.self)
    #expect(schema.type == .object("CELSwiftTests.Generic_Swift_Int_"))
  }

  @Test func mapsRepresentation() throws {
    let options = CELCodingOptions(structRepresentation: .maps)
    #expect(try CELSchema(for: Selection.self, options: options).type == .map(key: .string, value: .string))
    #expect(try CELSchema(for: ChangeRequest.self, options: options).type == .map(key: .string, value: .dyn))
    #expect(try CELSchema(for: ChangeRequest.self, options: options).structTypes.isEmpty)
  }

  @Test func snakeCaseFieldNames() throws {
    let schema = try CELSchema(for: ChangeRequest.self, options: CELCodingOptions(keyStrategy: .convertToSnakeCase))
    #expect(schema.fields?.map(\.name).contains("base_ref") == true)
    #expect(schema.fields?.map(\.name).contains("created_at") == true)
  }

  @Test func structLiteralsCreateTheEncodedObjects() throws {
    let env = try Environment(.types(Decision.self))
    let value = try env.program(env.compile("prbar.Decision{rule: 'r', verdict: 'approve'}")).evaluate().value
    #expect(try value.decoded(as: Decision.self) == Decision(rule: "r", verdict: "approve", flag: nil))
    #expect(value.asObject?.isFieldSet("flag") == false)
    #expect(
      try env.program(env.compile("prbar.Decision{rule: 'r', verdict: 'v'} == prbar.Decision{rule: 'r', verdict: 'v'}"))
        .evaluate().value == true)
  }
}

struct EnvironmentSchemaTests {
  @Test func variablesFromAFactsStruct() throws {
    let env = try Environment(.variables(from: SelectFacts.self))
    #expect(env.variables.contains { $0.name == "pr" && $0.type == .object("prbar.ChangeRequest") })
    #expect(env.variables.contains { $0.name == "trigger" && $0.type == .string })
    #expect(try env.compile("pr.labels.exists(l, l == 'bug') && trigger == 'manual'").outputType == .bool)
    #expect {
      _ = try env.compile("pr.labels + pr.additions")
    } throws: { error in
      "\(error)".contains("found no matching overload for '_+_' applied to '(list(string), int)'")
    }
  }

  @Test func factsMustBeAStruct() {
    #expect(throws: DeclarationError.self) {
      _ = try Environment(.variables(from: [String].self))
    }
  }

  @Test func singleVariable() throws {
    let env = try Environment(.variable("review", Review.self))
    #expect(try env.compile("review.findings.all(f, f.severity < 3)").outputType == .bool)
  }

  @Test func enumConstants() throws {
    let env = try Environment(
      .variable("review", Review.self), .enumConstants(Severity.self, namespace: "severity"),
      .enumConstants(Verdict.self, namespace: "verdict"))
    let program = try env.program(
      env.compile("review.findings.exists(f, f.severity >= severity.suggestion) && review.verdict == verdict.approve"))
    #expect(try program.evaluate(["review": Value(encoding: Review.sample)]).value == true)
  }
}
