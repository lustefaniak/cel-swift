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

// Ported from cel-go policy/parser.go (Policy, Import, Rule, Variable, Match, ValueString,
// SemanticType).
//
// cel-go models policies as mutable reference types; here they are value types and the parser
// and tag visitors mutate them through `inout`.

import CEL

/// A parsed CEL policy: a name, optional imports and a rule tree whose expressions are CEL source
/// strings tracked back to their position in the policy file.
///
/// Create policies with ``PolicyParser``.
public struct Policy: Sendable {
  /// The evaluation semantic of a rule's match blocks.
  public enum Semantic: Sendable, Hashable {
    /// The first matching output wins (`match:`).
    case firstMatch
    /// All matching outputs are combined (`aggregate:`).
    case aggregate
  }

  /// A string from the policy file, with the identifier of its recorded source position.
  public struct ValueString: Sendable, Hashable {
    /// The identifier of the source position recorded for this string, or 0 when it has none.
    public var id: Int64
    /// The string value.
    public var value: String

    /// Creates a value string.
    ///
    /// - Parameters:
    ///   - id: The identifier of the recorded source position, or 0 for none.
    ///   - value: The string value.
    public init(id: Int64 = 0, value: String) {
      self.id = id
      self.value = value
    }
  }

  /// An imported type name which is aliased within CEL expressions.
  public struct Import: Sendable, Hashable {
    /// The identifier of the source position of the import entry.
    public var sourceID: Int64
    /// The fully qualified type name.
    public var name: ValueString

    /// Creates an import.
    ///
    /// - Parameters:
    ///   - sourceID: The identifier of the source position of the import entry.
    ///   - name: The fully qualified type name.
    public init(sourceID: Int64, name: ValueString = ValueString(value: "")) {
      self.sourceID = sourceID
      self.name = name
    }
  }

  /// A named expression which may be referenced in subsequent expressions as `variables.<name>`.
  public struct Variable: Sendable, Hashable {
    /// The identifier of the source position of the variable entry.
    public var sourceID: Int64
    /// The variable name.
    public var name: ValueString
    /// The CEL expression computing the variable value.
    public var expression: ValueString

    /// Creates a variable.
    ///
    /// - Parameters:
    ///   - sourceID: The identifier of the source position of the variable entry.
    ///   - name: The variable name.
    ///   - expression: The CEL expression computing the variable value.
    public init(
      sourceID: Int64,
      name: ValueString = ValueString(value: ""),
      expression: ValueString = ValueString(value: "")
    ) {
      self.sourceID = sourceID
      self.name = name
      self.expression = expression
    }
  }

  /// A condition (`true` when omitted) with either an output expression or a nested rule.
  public struct Match: Sendable, Hashable {
    /// The identifier of the source position of the match entry.
    public var sourceID: Int64
    /// The CEL condition guarding the match.
    public var condition: ValueString
    /// The CEL output expression, or `nil` when the match holds a nested rule.
    public var output: ValueString?
    /// The CEL expression explaining the output, or `nil` when not set.
    public var explanation: ValueString?
    /// The nested rule, or `nil` when the match holds an output.
    public var rule: Rule?

    /// Creates a match with no condition, output or rule.
    ///
    /// - Parameter sourceID: The identifier of the source position of the match entry.
    public init(sourceID: Int64) {
      self.sourceID = sourceID
      self.condition = ValueString(value: "")
    }
  }

  /// A rule: an optional identifier and description, variables, and match blocks.
  public struct Rule: Sendable, Hashable {
    /// The identifier of the source position of the rule.
    public var sourceID: Int64
    /// The rule identifier, if set.
    public var id: ValueString?
    /// The rule description, if set.
    public var description: ValueString?
    /// The variables, in declaration order.
    public var variables: [Variable]
    /// The match blocks, in declaration order.
    public var matches: [Match]

    var semanticStorage: Semantic?

    /// Creates an empty rule.
    ///
    /// - Parameter sourceID: The identifier of the source position of the rule.
    public init(sourceID: Int64) {
      self.sourceID = sourceID
      self.variables = []
      self.matches = []
    }

    /// The evaluation semantic of the rule's match blocks; ``Semantic/firstMatch`` unless set.
    public var semantic: Semantic {
      semanticStorage ?? .firstMatch
    }

    /// Sets the evaluation semantic, unless a different one is already set.
    ///
    /// - Parameter semantic: The semantic to set.
    public mutating func setSemantic(_ semantic: Semantic) {
      if let current = semanticStorage, current != semantic {
        return
      }
      semanticStorage = semantic
    }

    func explanationOutputRule() -> Rule {
      var er = Rule(sourceID: 0)
      er.id = id
      er.description = description
      er.semanticStorage = semanticStorage
      er.variables = variables
      for match in matches {
        var em = Match(sourceID: 0)
        em.condition = match.condition
        em.output = match.explanation
        em.rule = match.rule?.explanationOutputRule()
        er.matches.append(em)
      }
      return er
    }
  }

  /// The policy name.
  public var name: ValueString
  /// The policy description.
  public var description: ValueString
  /// The imported type names.
  public var imports: [Import]
  /// The entry point rule, if set.
  public var rule: Rule?
  /// The policy file the policy was parsed from.
  public let source: PolicySource

  var sourceInfo: SourceInfo
  var semanticStorage: Semantic?
  private var metadata: [String: any Sendable]

  init(source: PolicySource, sourceInfo: SourceInfo) {
    self.name = ValueString(value: "")
    self.description = ValueString(value: "")
    self.imports = []
    self.source = source
    self.sourceInfo = sourceInfo
    self.metadata = [:]
  }

  /// The evaluation semantic of the policy; ``Semantic/firstMatch`` unless set.
  public var semantic: Semantic {
    semanticStorage ?? .firstMatch
  }

  /// Sets the evaluation semantic, unless a different one is already set.
  ///
  /// - Parameter semantic: The semantic to set.
  public mutating func setSemantic(_ semantic: Semantic) {
    if let current = semanticStorage, current != semantic {
      return
    }
    semanticStorage = semantic
  }

  /// Returns the 1-based line and 0-based column recorded for a policy element, or `nil` when no
  /// position is recorded for `id`.
  ///
  /// - Parameter id: A ``ValueString/id`` or a `sourceID` of a policy element.
  public func location(of id: Int64) -> (line: Int, column: Int)? {
    guard sourceInfo.offsetRange(id) != nil else { return nil }
    let loc = sourceInfo.startLocation(id)
    return (loc.line, loc.column)
  }

  /// Returns the metadata value stored under `key` by a custom tag visitor, if any.
  ///
  /// - Parameter key: The metadata key.
  public func metadata(forKey key: String) -> (any Sendable)? {
    metadata[key]
  }

  /// The keys of the metadata stored on the policy, in no particular order.
  public var metadataKeys: [String] {
    Array(metadata.keys)
  }

  /// Stores a metadata value under `key`, replacing any previous value.
  ///
  /// - Parameters:
  ///   - value: The value to store.
  ///   - key: The metadata key.
  public mutating func setMetadata(_ value: any Sendable, forKey key: String) {
    metadata[key] = value
  }

  /// Removes the metadata value stored under `key`.
  ///
  /// - Parameter key: The metadata key.
  public mutating func removeMetadata(forKey key: String) {
    metadata[key] = nil
  }

  /// Returns a copy of the policy in which the output of each match is replaced by its
  /// explanation expression.
  ///
  /// Matches without an explanation get no output. As in cel-go, the copy keeps the name,
  /// semantic, metadata and source, but not the description or imports.
  public func explanationOutputPolicy() -> Policy {
    var ep = Policy(source: source, sourceInfo: sourceInfo)
    ep.name = name
    ep.semanticStorage = semanticStorage
    ep.metadata = metadata
    ep.rule = rule?.explanationOutputRule()
    return ep
  }
}
