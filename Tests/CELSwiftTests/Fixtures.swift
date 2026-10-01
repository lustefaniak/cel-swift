// PRBar-shaped facts and outputs shared by the CELSwift tests: a forge-neutral change request,
// AI review results with severities, and per-stage facts and decisions.

import CEL
import CELSwift
import Foundation

enum Verdict: String, Codable, CaseIterable, Sendable {
  case approve
  case comment
  case requestChanges = "request_changes"
  case abstain
}

/// Compared by rank in rules (`f.severity >= severity.warning`), so an `int`.
enum Severity: String, Codable, CaseIterable, Sendable, CELValueRepresentable {
  case info, suggestion, warning, blocker

  static var celType: CELType { .int }

  var celValue: Value { .int(Int64(Self.allCases.firstIndex(of: self) ?? 0)) }

  init(celValue: Value) throws {
    guard let rank = celValue.asInt, let index = Int(exactly: rank), Self.allCases.indices.contains(index) else {
      throw EvalError("not a severity: \(celValue)")
    }
    self = Self.allCases[index]
  }
}

struct ChangeRequest: Codable, Sendable, Equatable, CELNamedType {
  static let celTypeName = "prbar.ChangeRequest"

  var repo: String
  var number: Int
  var title: String
  var author: String
  var draft: Bool
  var labels: [String]
  var additions: Int
  var deletions: Int
  var files: [String]
  var baseRef: String
  var createdAt: Date
  var reviewer: String?
}

struct Finding: Codable, Sendable, Equatable {
  var path: String
  var lineStart: Int
  var severity: Severity
  var title: String?
}

struct Review: Codable, Sendable, Equatable, CELNamedType {
  static let celTypeName = "prbar.Review"

  var verdict: Verdict
  var confidence: Double
  var findings: [Finding]
  var costUSD: Double
  var duration: Duration
}

struct Signals: Codable, Sendable, Equatable {
  var mechanical: Double?
  var risk: Double?
}

struct SelectFacts: Codable, Sendable {
  var pr: ChangeRequest
  var trigger: String
  var lists: [String: [String]]
  var signals: Signals
}

struct DecideFacts: Codable, Sendable {
  var pr: ChangeRequest
  var review: Review
  var lists: [String: [String]]
}

struct Selection: Codable, Sendable, Equatable {
  var rule: String
  var action: String
}

struct Decision: Codable, Sendable, Equatable, CELNamedType {
  static let celTypeName = "prbar.Decision"

  var rule: String
  var verdict: String
  var flag: Bool?
}

extension ChangeRequest {
  static let sample = ChangeRequest(
    repo: "acme/api", number: 42, title: "Fix the retry loop", author: "alice", draft: false,
    labels: ["bug"], additions: 120, deletions: 30, files: ["Sources/Retry.swift", "Tests/RetryTests.swift"],
    baseRef: "main", createdAt: Date(timeIntervalSince1970: 1_790_000_000), reviewer: nil)
}

extension Review {
  static let sample = Review(
    verdict: .approve, confidence: 0.92,
    findings: [Finding(path: "Sources/Retry.swift", lineStart: 10, severity: .suggestion, title: "Name the constant")],
    costUSD: 0.42, duration: .seconds(95))
}

extension SelectFacts {
  static let sample = SelectFacts(
    pr: .sample, trigger: "review_requested", lists: ["trusted": ["alice", "bob"]], signals: Signals())
}

extension DecideFacts {
  static let sample = DecideFacts(pr: .sample, review: .sample, lists: ["trusted": ["alice", "bob"]])
}
