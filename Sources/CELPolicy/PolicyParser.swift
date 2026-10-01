// Copyright 2024 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//	https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Ported from cel-go policy/parser.go (Parser, ParserOption, ParserContext, TagVisitor,
// parserImpl).

/// Handles policy fields the parser does not know, such as embedder-specific metadata.
///
/// The parser calls the visitor for every unrecognized key of a policy, rule, match or variable
/// mapping. A visitor may store the value as metadata, parse it as a nested element through the
/// ``PolicyParserContext``, or report an error. Every requirement has a default implementation
/// that reports the tag as unsupported, so a visitor implements only the elements it extends.
///
/// The `description` key of a policy is also passed to ``visitPolicyTag(_:id:node:policy:context:)``
/// after it has been parsed, since some embedders intercept it.
public protocol PolicyTagVisitor: Sendable {
  /// Handles an unrecognized key of the top-level policy mapping.
  ///
  /// - Parameters:
  ///   - tagName: The key.
  ///   - id: The identifier of the key's source position, for error reporting.
  ///   - node: The value node.
  ///   - policy: The policy being parsed.
  ///   - context: The parser context, for nested parsing and error reporting.
  func visitPolicyTag(
    _ tagName: String,
    id: Int64,
    node: YAMLNode,
    policy: inout Policy,
    context: inout PolicyParserContext
  )

  /// Handles an unrecognized key of a rule mapping.
  ///
  /// - Parameters:
  ///   - tagName: The key.
  ///   - id: The identifier of the key's source position, for error reporting.
  ///   - node: The value node.
  ///   - policy: The policy being parsed.
  ///   - rule: The rule being parsed.
  ///   - context: The parser context, for nested parsing and error reporting.
  func visitRuleTag(
    _ tagName: String,
    id: Int64,
    node: YAMLNode,
    policy: inout Policy,
    rule: inout Policy.Rule,
    context: inout PolicyParserContext
  )

  /// Handles an unrecognized key of a match mapping.
  ///
  /// - Parameters:
  ///   - tagName: The key.
  ///   - id: The identifier of the key's source position, for error reporting.
  ///   - node: The value node.
  ///   - policy: The policy being parsed.
  ///   - match: The match being parsed.
  ///   - context: The parser context, for nested parsing and error reporting.
  func visitMatchTag(
    _ tagName: String,
    id: Int64,
    node: YAMLNode,
    policy: inout Policy,
    match: inout Policy.Match,
    context: inout PolicyParserContext
  )

  /// Handles an unrecognized key of a variable mapping.
  ///
  /// - Parameters:
  ///   - tagName: The key.
  ///   - id: The identifier of the key's source position, for error reporting.
  ///   - node: The value node.
  ///   - policy: The policy being parsed.
  ///   - variable: The variable being parsed.
  ///   - context: The parser context, for nested parsing and error reporting.
  func visitVariableTag(
    _ tagName: String,
    id: Int64,
    node: YAMLNode,
    policy: inout Policy,
    variable: inout Policy.Variable,
    context: inout PolicyParserContext
  )
}

extension PolicyTagVisitor {
  /// Reports `unsupported policy tag: <name>`, except for `description`, which is accepted.
  public func visitPolicyTag(
    _ tagName: String,
    id: Int64,
    node: YAMLNode,
    policy: inout Policy,
    context: inout PolicyParserContext
  ) {
    if tagName == "description" {
      return
    }
    context.reportError(atID: id, "unsupported policy tag: \(tagName)")
  }

  /// Reports `unsupported rule tag: <name>`.
  public func visitRuleTag(
    _ tagName: String,
    id: Int64,
    node: YAMLNode,
    policy: inout Policy,
    rule: inout Policy.Rule,
    context: inout PolicyParserContext
  ) {
    context.reportError(atID: id, "unsupported rule tag: \(tagName)")
  }

  /// Reports `unsupported match tag: <name>`.
  public func visitMatchTag(
    _ tagName: String,
    id: Int64,
    node: YAMLNode,
    policy: inout Policy,
    match: inout Policy.Match,
    context: inout PolicyParserContext
  ) {
    context.reportError(atID: id, "unsupported match tag: \(tagName)")
  }

  /// Reports `unsupported variable tag: <name>`.
  public func visitVariableTag(
    _ tagName: String,
    id: Int64,
    node: YAMLNode,
    policy: inout Policy,
    variable: inout Policy.Variable,
    context: inout PolicyParserContext
  ) {
    context.reportError(atID: id, "unsupported variable tag: \(tagName)")
  }
}

/// The tag visitor that reports every non-canonical policy field as an error.
public struct DefaultPolicyTagVisitor: PolicyTagVisitor {
  /// Creates the default tag visitor.
  public init() {}
}

/// Parses policy YAML into a ``Policy``.
///
/// ```swift
/// let parser = PolicyParser()
/// let policy = try parser.parse(PolicySource(yaml, description: "policy.yaml"))
/// ```
public struct PolicyParser: Sendable {
  /// The visitor for fields the parser does not know.
  public var tagVisitor: any PolicyTagVisitor
  /// Whether variables are declared as single-entry maps (`- name: expression`) rather than
  /// `name` / `expression` objects.
  public var simpleVariables: Bool

  /// Creates a parser.
  ///
  /// - Parameters:
  ///   - tagVisitor: The visitor for fields the parser does not know.
  ///   - simpleVariables: Whether variables are declared as single-entry maps, for example
  ///     `- first: "1.5"`, instead of `- name: first` / `expression: "1.5"` objects.
  public init(tagVisitor: any PolicyTagVisitor = DefaultPolicyTagVisitor(), simpleVariables: Bool = false) {
    self.tagVisitor = tagVisitor
    self.simpleVariables = simpleVariables
  }

  /// Parses a policy file.
  ///
  /// CEL expressions in the policy are kept as text, with positions relative to the whole file so
  /// that compile errors point into the policy.
  ///
  /// - Parameter source: The policy file.
  /// - Returns: The parsed policy.
  /// - Throws: ``PolicyError`` listing every problem found, in cel-go's message format.
  public func parse(_ source: PolicySource) throws(PolicyError) -> Policy {
    var context = PolicyParserContext(
      visitor: tagVisitor,
      source: source,
      inlineStyleVariables: simpleVariables
    )
    let policy = context.parseYAML()
    if !context.errors.issues.isEmpty || context.errors.reportedCount > 0 {
      throw context.errors
    }
    guard var policy else {
      throw context.errors
    }
    policy.sourceInfo = context.sourceInfo
    return policy
  }
}

/// The state of a policy parse: identifiers, source positions and errors.
///
/// Tag visitors receive the context to parse nested policy elements, record source positions and
/// report errors.
public struct PolicyParserContext {
  let visitor: any PolicyTagVisitor
  let source: PolicySource
  let inlineStyleVariables: Bool
  var sourceInfo: PolicySourceInfo
  var errors: PolicyError
  private var id: Int64 = 0

  init(visitor: any PolicyTagVisitor, source: PolicySource, inlineStyleVariables: Bool) {
    self.visitor = visitor
    self.source = source
    self.inlineStyleVariables = inlineStyleVariables
    self.sourceInfo = PolicySourceInfo(source: source)
    self.errors = PolicyError(source: source)
  }

  // MARK: - ParserContext

  /// Returns a new, monotonically increasing identifier for a source fragment.
  public mutating func nextID() -> Int64 {
    id += 1
    return id
  }

  /// Records the source position of `node` and returns the identifier it is stored under.
  ///
  /// Quoted scalars are recorded one column past the opening quote, so the position points at the
  /// first character of the string.
  @discardableResult
  public mutating func collectMetadata(_ node: YAMLNode) -> Int64 {
    let id = nextID()
    let line = node.line
    var col = Int32(node.column)
    if node.style == .doubleQuoted || node.style == .singleQuoted {
      col += 1
    }
    var offsetStart: Int32 = 0
    if line > 1 {
      offsetStart = sourceInfo.lineOffsets[line - 2]
    }
    sourceInfo.offsetRanges[id] = .init(start: offsetStart + col - 1, stop: offsetStart + col - 1)
    return id
  }

  /// Reports an error at the source position recorded under `id`.
  ///
  /// - Parameters:
  ///   - id: The identifier of a recorded source position.
  ///   - message: The error message.
  public mutating func reportError(atID id: Int64, _ message: String) {
    errors.report(id: id, location: sourceInfo.startLocation(of: id), message: message)
  }

  /// Creates a string value from a scalar node and records its position.
  ///
  /// Block scalars (`|`, `>`) keep their raw source lines, including indentation, and are
  /// positioned at the start of their first line, so CEL errors in them point at the right
  /// column. Non-string nodes report an error and yield `*error*`.
  public mutating func makeString(_ node: YAMLNode) -> Policy.ValueString {
    let id = collectMetadata(node)
    guard let nodeType = assertYAMLType(id, node, [.string, .text]) else {
      return Policy.ValueString(id: id, value: "*error*")
    }
    if nodeType == .text {
      return Policy.ValueString(id: id, value: node.value)
    }
    if node.style == .folded || node.style == .literal {
      let col = node.column
      var line = node.line
      var txt = source.snippet(line: line)
      let indent = String(repeating: " ", count: max(0, col - 1))
      var raw = ""
      while let t = txt, t.unicodeScalars.starts(with: indent.unicodeScalars) {
        line += 1
        raw += t
        txt = source.snippet(line: line)
        if let next = txt, next.unicodeScalars.starts(with: indent.unicodeScalars) {
          raw += "\n"
        }
      }
      let offset = sourceInfo.offsetRanges[self.id] ?? .init(start: 0, stop: 0)
      let offsetStart = offset.start - (Int32(node.column) - 1)
      sourceInfo.offsetRanges[self.id] = .init(start: offsetStart, stop: offsetStart)
      return Policy.ValueString(id: id, value: raw)
    }
    return Policy.ValueString(id: id, value: node.value)
  }

  /// Creates a string value with no special source position handling, for human-readable text
  /// such as descriptions.
  mutating func makeStrictString(_ node: YAMLNode) -> Policy.ValueString {
    let id = collectMetadata(node)
    guard assertYAMLType(id, node, [.string, .text]) != nil else {
      return Policy.ValueString(id: id, value: "*error*")
    }
    return Policy.ValueString(id: id, value: node.value)
  }

  mutating func makePolicy(_ node: YAMLNode) -> (Policy, Int64) {
    let policy = Policy(source: source, sourceInfo: sourceInfo)
    let id = collectMetadata(node)
    return (policy, id)
  }

  mutating func makeRule(_ node: YAMLNode) -> (Policy.Rule, Int64) {
    let id = collectMetadata(node)
    return (Policy.Rule(sourceID: id), id)
  }

  mutating func makeVariable(_ node: YAMLNode) -> (Policy.Variable, Int64) {
    let id = collectMetadata(node)
    return (Policy.Variable(sourceID: id), id)
  }

  mutating func makeMatch(_ node: YAMLNode) -> (Policy.Match, Int64) {
    let id = collectMetadata(node)
    return (Policy.Match(sourceID: id), id)
  }

  // MARK: - Parsing

  mutating func parseYAML() -> Policy? {
    let docNode: YAMLNode?
    do {
      docNode = try YAMLNode.parseDocument(source.content)
    } catch {
      reportError(atID: 0, error.message)
      return nil
    }
    guard let docNode, docNode.kind == .document, let root = docNode.content.first else {
      reportError(atID: 0, "got yaml node of kind \(docNode?.goKindValue ?? 0), wanted mapping node")
      return nil
    }
    return parsePolicy(root)
  }

  /// Parses `node` as though it is the top-level policy.
  mutating func parsePolicy(_ node: YAMLNode) -> Policy {
    collectMetadata(node)
    var (policy, id) = makePolicy(node)
    if assertYAMLType(id, node, [.map]) == nil || !checkMapValid(id, node) {
      return policy
    }
    for (key, val) in node.mapEntries {
      let keyID = collectMetadata(key)
      let fieldName = key.value
      switch fieldName {
      case "imports":
        parseImports(val, policy: &policy)
      case "name":
        policy.name = makeString(val)
      case "description":
        policy.description = makeStrictString(val)
        // Since the description field was not supported initially, some
        // clients rely on the ability to intercept it.
        visitor.visitPolicyTag(fieldName, id: keyID, node: val, policy: &policy, context: &self)
      case "rule":
        let rule = parseRule(val, policy: &policy)
        policy.rule = rule
      default:
        visitor.visitPolicyTag(fieldName, id: keyID, node: val, policy: &policy, context: &self)
      }
    }
    return policy
  }

  private mutating func parseImports(_ node: YAMLNode, policy: inout Policy) {
    let id = collectMetadata(node)
    if assertYAMLType(id, node, [.list]) == nil {
      return
    }
    for val in node.content {
      policy.imports.append(parseImport(val))
    }
  }

  private mutating func parseImport(_ node: YAMLNode) -> Policy.Import {
    let id = collectMetadata(node)
    var imp = Policy.Import(sourceID: id)
    if assertYAMLType(id, node, [.map]) == nil || !checkMapValid(id, node) {
      return imp
    }
    for (key, val) in node.mapEntries {
      collectMetadata(key)
      switch key.value {
      case "name":
        imp.name = makeString(val)
      default:
        break
      }
    }
    return imp
  }

  /// Parses `node` as though it is the entry point to a rule.
  ///
  /// - Parameters:
  ///   - node: The rule mapping.
  ///   - policy: The policy being parsed; its semantic is updated from the rule.
  /// - Returns: The parsed rule.
  public mutating func parseRule(_ node: YAMLNode, policy: inout Policy) -> Policy.Rule {
    var (r, id) = makeRule(node)
    if assertYAMLType(id, node, [.map]) == nil || !checkMapValid(id, node) {
      return r
    }
    for (key, val) in node.mapEntries {
      let tagID = collectMetadata(key)
      let fieldName = key.value
      switch fieldName {
      case "id":
        r.id = makeString(val)
      case "description":
        r.description = makeString(val)
      case "variables":
        parseVariables(val, policy: &policy, rule: &r)
      case "match", "aggregate":
        let sem: Policy.Semantic = fieldName == "aggregate" ? .aggregate : .firstMatch
        if let current = r.semanticStorage, current != sem {
          reportError(atID: tagID, "Only one of 'match' or 'aggregate' may be set in a rule")
        } else {
          r.setSemantic(sem)
          policy.setSemantic(sem)
          parseMatches(val, policy: &policy, rule: &r)
        }
      default:
        visitor.visitRuleTag(fieldName, id: tagID, node: val, policy: &policy, rule: &r, context: &self)
      }
    }
    return r
  }

  private mutating func parseVariables(_ node: YAMLNode, policy: inout Policy, rule: inout Policy.Rule) {
    let id = collectMetadata(node)
    if assertYAMLType(id, node, [.list]) == nil {
      return
    }
    for val in node.listElements {
      rule.variables.append(parseVariable(val, policy: &policy))
    }
  }

  /// Parses `node` as though it is the entry point to a variable.
  ///
  /// - Parameters:
  ///   - node: The variable mapping.
  ///   - policy: The policy being parsed.
  /// - Returns: The parsed variable.
  public mutating func parseVariable(_ node: YAMLNode, policy: inout Policy) -> Policy.Variable {
    var (v, id) = makeVariable(node)
    if assertYAMLType(id, node, [.map]) == nil || !checkMapValid(id, node) {
      return v
    }
    if inlineStyleVariables {
      parseVariableInline(node, variable: &v)
    } else {
      parseVariableObject(node, policy: &policy, variable: &v)
    }
    return v
  }

  private mutating func parseVariableInline(_ node: YAMLNode, variable v: inout Policy.Variable) {
    var iterations = 0
    for (key, val) in node.mapEntries {
      let keyVal = makeString(key)
      v.name = keyVal
      v.expression = makeString(val)
      iterations += 1
      if iterations > 1 {
        reportError(atID: keyVal.id, "only one variable may be defined inline")
        return
      }
    }
  }

  private mutating func parseVariableObject(
    _ node: YAMLNode,
    policy: inout Policy,
    variable v: inout Policy.Variable
  ) {
    for (key, val) in node.mapEntries {
      let keyID = collectMetadata(key)
      let fieldName = key.value
      switch fieldName {
      case "name":
        v.name = makeString(val)
      case "expression":
        v.expression = makeString(val)
      default:
        visitor.visitVariableTag(fieldName, id: keyID, node: val, policy: &policy, variable: &v, context: &self)
      }
    }
  }

  private mutating func parseMatches(_ node: YAMLNode, policy: inout Policy, rule: inout Policy.Rule) {
    let id = collectMetadata(node)
    if assertYAMLType(id, node, [.list]) == nil {
      return
    }
    for val in node.content {
      rule.matches.append(parseMatch(val, policy: &policy))
    }
  }

  /// Parses `node` as though it is the entry point to a match.
  ///
  /// - Parameters:
  ///   - node: The match mapping.
  ///   - policy: The policy being parsed.
  /// - Returns: The parsed match.
  public mutating func parseMatch(_ node: YAMLNode, policy: inout Policy) -> Policy.Match {
    var (m, id) = makeMatch(node)
    if assertYAMLType(id, node, [.map]) == nil || !checkMapValid(id, node) {
      return m
    }
    m.condition = Policy.ValueString(id: nextID(), value: "true")
    for (key, val) in node.mapEntries {
      let keyID = collectMetadata(key)
      let fieldName = key.value
      switch fieldName {
      case "condition":
        m.condition = makeString(val)
      case "output":
        if m.rule != nil {
          reportError(atID: keyID, "only the rule or the output may be set")
        }
        m.output = makeString(val)
      case "explanation":
        if m.rule != nil {
          reportError(atID: keyID, "explanation can only be set on output match cases, not nested rules")
        }
        m.explanation = makeString(val)
      case "rule", "match", "aggregate":
        if m.output != nil {
          reportError(atID: keyID, "only the rule or the output may be set")
        }
        if m.explanation != nil {
          reportError(atID: keyID, "explanation can only be set on output match cases, not nested rules")
        }
        let rule = parseRule(val, policy: &policy)
        m.rule = rule
      default:
        visitor.visitMatchTag(fieldName, id: keyID, node: val, policy: &policy, match: &m, context: &self)
      }
    }
    if m.output == nil && m.rule == nil {
      reportError(atID: id, "match does not specify a rule or output")
    }
    return m
  }

  private mutating func assertYAMLType(_ id: Int64, _ node: YAMLNode, _ nodeTypes: [YAMLNodeType]) -> YAMLNodeType? {
    let longTag = node.longTag
    guard let nt = YAMLNodeType.forLongTag(longTag) else {
      reportError(atID: id, "unsupported yaml tag type: \(longTag)")
      return nil
    }
    if nodeTypes.contains(nt) {
      return nt
    }
    let wanted = nodeTypes.map(\.description).joined(separator: " ")
    reportError(atID: id, "got yaml node type \(longTag), wanted type(s) [\(wanted)]")
    return nil
  }

  private mutating func checkMapValid(_ id: Int64, _ node: YAMLNode) -> Bool {
    let valid = node.content.count % 2 == 0
    if !valid {
      reportError(atID: id, "mismatched key-value pairs in map")
    }
    return valid
  }
}
