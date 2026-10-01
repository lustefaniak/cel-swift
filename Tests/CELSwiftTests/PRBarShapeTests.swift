// PRBar's fact types as they are today (PRBarCore/Models/InboxPR.swift, ReviewTypes.swift, Enums.swift and
// Services/Review/ResultAggregator.swift, trimmed of computed properties): a schema derives from them
// unchanged, including InboxPR's hand-written init(from:) and DiffAnnotation's snake_case CodingKeys.

import CEL
import CELPolicy
import CELSwift
import Foundation
import Testing

private enum PRRole: String, Codable, Sendable, Hashable, CaseIterable {
  case authored, reviewRequested, both, other
}

private enum PRState: String, Codable, Sendable, Hashable, CaseIterable {
  case open, closed, merged
}

private enum MergeMethod: String, Codable, Sendable, Hashable, CaseIterable {
  case squash, merge, rebase
}

private enum ReviewVerdict: String, Codable, Sendable, Hashable, CaseIterable {
  case approve
  case comment
  case requestChanges = "request_changes"
  case abstain
}

private enum AnnotationSeverity: String, Codable, Sendable, Hashable, CaseIterable {
  case info, suggestion, warning, blocker
}

private struct CheckSummary: Sendable, Hashable, Codable {
  let typename: String
  let name: String
  let conclusion: String?
  let status: String?
  let url: String?
}

private struct PRReviewSummary: Sendable, Hashable, Codable {
  let author: String
  let state: String
  let submittedAt: Date?
  let body: String
  let isFromViewer: Bool
}

private struct PRCommentSummary: Sendable, Hashable, Codable {
  let author: String
  let createdAt: Date?
  let body: String
  let isFromViewer: Bool
}

private struct InboxPR: Sendable, Hashable, Codable {
  let nodeId: String
  let owner: String
  let repo: String
  let number: Int
  let title: String
  let body: String
  let url: URL
  let author: String
  let headRef: String
  let baseRef: String
  let headSha: String
  var headCommittedAt: Date? = nil
  let isDraft: Bool
  let role: PRRole
  var state: PRState = .open
  let mergeable: String
  let mergeStateStatus: String
  let reviewDecision: String?
  let checkRollupState: String
  let totalAdditions: Int
  let totalDeletions: Int
  let changedFiles: Int
  let hasAutoMerge: Bool
  let autoMergeEnabledBy: String?
  var autoMergeMethod: MergeMethod? = nil
  let allCheckSummaries: [CheckSummary]
  var humanReviews: [PRReviewSummary] = []
  var issueComments: [PRCommentSummary] = []
  var hasPRBarVerdictAtHead: Bool = false
  var viewerLogin: String = ""
  let allowedMergeMethods: Set<MergeMethod>
  let autoMergeAllowed: Bool
  let deleteBranchOnMerge: Bool

  private enum CodingKeys: String, CodingKey {
    case nodeId, owner, repo, number, title, body, url, author
    case headRef, baseRef, headSha, headCommittedAt, isDraft, role, state
    case mergeable, mergeStateStatus, reviewDecision, checkRollupState
    case totalAdditions, totalDeletions, changedFiles
    case hasAutoMerge, autoMergeEnabledBy, autoMergeMethod, allCheckSummaries
    case allowedMergeMethods, autoMergeAllowed, deleteBranchOnMerge
    case humanReviews, issueComments, viewerLogin
    case hasPRBarVerdictAtHead
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.nodeId = try c.decode(String.self, forKey: .nodeId)
    self.owner = try c.decode(String.self, forKey: .owner)
    self.repo = try c.decode(String.self, forKey: .repo)
    self.number = try c.decode(Int.self, forKey: .number)
    self.title = try c.decode(String.self, forKey: .title)
    self.body = try c.decode(String.self, forKey: .body)
    self.url = try c.decode(URL.self, forKey: .url)
    self.author = try c.decode(String.self, forKey: .author)
    self.headRef = try c.decode(String.self, forKey: .headRef)
    self.baseRef = try c.decode(String.self, forKey: .baseRef)
    self.headSha = try c.decode(String.self, forKey: .headSha)
    self.headCommittedAt = try c.decodeIfPresent(Date.self, forKey: .headCommittedAt)
    self.isDraft = try c.decode(Bool.self, forKey: .isDraft)
    self.role = try c.decode(PRRole.self, forKey: .role)
    self.state = (try? c.decodeIfPresent(PRState.self, forKey: .state)) ?? .open
    self.mergeable = try c.decode(String.self, forKey: .mergeable)
    self.mergeStateStatus = try c.decode(String.self, forKey: .mergeStateStatus)
    self.reviewDecision = try c.decodeIfPresent(String.self, forKey: .reviewDecision)
    self.checkRollupState = try c.decode(String.self, forKey: .checkRollupState)
    self.totalAdditions = try c.decode(Int.self, forKey: .totalAdditions)
    self.totalDeletions = try c.decode(Int.self, forKey: .totalDeletions)
    self.changedFiles = try c.decode(Int.self, forKey: .changedFiles)
    self.hasAutoMerge = try c.decode(Bool.self, forKey: .hasAutoMerge)
    self.autoMergeEnabledBy = try c.decodeIfPresent(String.self, forKey: .autoMergeEnabledBy)
    self.autoMergeMethod = try c.decodeIfPresent(MergeMethod.self, forKey: .autoMergeMethod)
    self.allCheckSummaries = try c.decode([CheckSummary].self, forKey: .allCheckSummaries)
    self.allowedMergeMethods = try c.decode(Set<MergeMethod>.self, forKey: .allowedMergeMethods)
    self.autoMergeAllowed = try c.decode(Bool.self, forKey: .autoMergeAllowed)
    self.deleteBranchOnMerge = try c.decode(Bool.self, forKey: .deleteBranchOnMerge)
    self.humanReviews = try c.decodeIfPresent([PRReviewSummary].self, forKey: .humanReviews) ?? []
    self.issueComments = try c.decodeIfPresent([PRCommentSummary].self, forKey: .issueComments) ?? []
    self.viewerLogin = try c.decodeIfPresent(String.self, forKey: .viewerLogin) ?? ""
    self.hasPRBarVerdictAtHead = try c.decodeIfPresent(Bool.self, forKey: .hasPRBarVerdictAtHead) ?? false
  }

  init(title: String, author: String, additions: Int, role: PRRole) throws {
    nodeId = "PR_1"
    owner = "acme"
    repo = "api"
    number = 7
    self.title = title
    body = ""
    url = try #require(URL(string: "https://github.com/acme/api/pull/7"))
    self.author = author
    headRef = "fix"
    baseRef = "main"
    headSha = "abc123"
    isDraft = false
    self.role = role
    mergeable = "MERGEABLE"
    mergeStateStatus = "CLEAN"
    reviewDecision = nil
    checkRollupState = "SUCCESS"
    totalAdditions = additions
    totalDeletions = 3
    changedFiles = 2
    hasAutoMerge = false
    autoMergeEnabledBy = nil
    allCheckSummaries = [CheckSummary(typename: "CheckRun", name: "build", conclusion: "SUCCESS", status: "COMPLETED", url: nil)]
    humanReviews = [PRReviewSummary(author: "bob", state: "APPROVED", submittedAt: nil, body: "", isFromViewer: false)]
    allowedMergeMethods = [.squash]
    autoMergeAllowed = true
    deleteBranchOnMerge = true
  }
}

private struct DiffAnnotation: Codable, Sendable, Hashable {
  let path: String
  let lineStart: Int
  let lineEnd: Int
  let severity: AnnotationSeverity
  let title: String?
  let body: String

  enum CodingKeys: String, CodingKey {
    case path
    case lineStart = "line_start"
    case lineEnd = "line_end"
    case severity
    case title
    case body
  }
}

private struct ProviderResult: Sendable, Codable {
  let verdict: ReviewVerdict
  let confidence: Double
  let summaryMarkdown: String
  let annotations: [DiffAnnotation]
  let costUsd: Double?
  let toolCallCount: Int
  let toolNamesUsed: [String]
  let rawJson: Data
  var isSubscriptionAuth: Bool = false
}

private struct SubreviewOutcome: Sendable, Hashable, Codable {
  let subpath: String
  let result: ProviderResult

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.subpath == rhs.subpath }
  func hash(into hasher: inout Hasher) { hasher.combine(subpath) }
}

private struct AggregatedReview: Sendable, Codable {
  let verdict: ReviewVerdict
  let confidence: Double
  let summaryMarkdown: String
  let annotations: [DiffAnnotation]
  let costUsd: Double
  let toolCallCount: Int
  let toolNamesUsed: [String]
  let perSubreview: [SubreviewOutcome]
  let isSubscriptionAuth: Bool
}

private struct InboxDecideFacts: Codable, Sendable {
  var pr: InboxPR
  var review: AggregatedReview
  var lists: [String: [String]]
}

private struct InboxDecision: Codable, Sendable, Equatable {
  var rule: String
  var verdict: String
}

struct PRBarShapeTests {
  @Test func inboxPRDerivesASchema() throws {
    let schema = try CELSchema(for: InboxPR.self)
    let fields = Dictionary(uniqueKeysWithValues: try #require(schema.fields).map { ($0.name, $0) })
    #expect(fields["url"]?.type == .string)
    #expect(fields["headCommittedAt"]?.type == .timestamp)
    #expect(fields["headCommittedAt"]?.isOptional == true)
    #expect(fields["role"]?.type == .string)
    #expect(fields["allowedMergeMethods"]?.type == .list(.string))
    #expect(fields["allCheckSummaries"]?.type == .list(.object("CELSwiftTests.CheckSummary")))
    #expect(fields["humanReviews"]?.type == .list(.object("CELSwiftTests.PRReviewSummary")))
    #expect(fields["reviewDecision"]?.type == .wrapper(.string))
  }

  @Test func decideStageOverPRBarTypes() throws {
    let yaml = """
      name: decide
      rule:
        match:
          - condition: >-
              pr.author in lists.trusted && review.verdict == "approve" && review.confidence >= 0.85
              && pr.totalAdditions <= 200
              && !review.annotations.exists(a, a.severity in ["warning", "blocker"])
            output: '{"rule": "trusted-approve", "verdict": "approve"}'
          - condition: review.annotations.exists(a, a.line_start > 0 && a.severity == "blocker")
            output: '{"rule": "flag-blockers", "verdict": "none"}'
          - output: '{"rule": "nothing", "verdict": "none"}'
      """
    let decide = try TypedProgram<InboxDecideFacts, InboxDecision>(
      policy: PolicySource(yaml, description: "decide.yaml"), environment: Environment(),
      programOptions: [.costLimit(10_000)])
    let review = AggregatedReview(
      verdict: .approve, confidence: 0.9, summaryMarkdown: "LGTM",
      annotations: [
        DiffAnnotation(path: "a.swift", lineStart: 3, lineEnd: 4, severity: .suggestion, title: nil, body: "nit")
      ],
      costUsd: 0.3, toolCallCount: 4, toolNamesUsed: ["Read"], perSubreview: [], isSubscriptionAuth: true)
    let facts = InboxDecideFacts(
      pr: try InboxPR(title: "Fix", author: "alice", additions: 40, role: .reviewRequested), review: review,
      lists: ["trusted": ["alice"]])
    #expect(try decide.evaluate(facts) == InboxDecision(rule: "trusted-approve", verdict: "approve"))
  }
}
