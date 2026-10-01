// Explaining an evaluation condition by condition: each policy match condition (or the whole
// expression) with its value, the value of each predicate it combines, and the inputs those
// predicates read. Built from state tracking and the source positions the parser and the policy
// compiler record. Not a ported file.

import CEL
import CELPolicy

/// Why a typed program produced its output: every condition with its value, down to the
/// predicates it combines and the facts they read.
///
/// For a policy there is one ``Condition`` per `match` condition, in file order, with the `id` of
/// the rule it belongs to; for an expression there is one, the whole expression. The program is
/// evaluated exhaustively, so every condition and predicate has a value, also those that
/// short-circuiting would skip: the trace says why a rule did not match even when an earlier
/// predicate already decided it.
///
/// ```swift
/// let explanation = try decide.explain(facts)
/// print(explanation)
/// // decide.yaml:8:9 [verdict] pr.author in lists.trusted && variables.size <= 200 -> false
/// //   true   pr.author in lists.trusted   (pr.author = "alice", lists.trusted = ["alice", "bob"])
/// //   false  variables.size <= 200   (variables.size = 442)
/// // result: Decision(rule: "nothing", verdict: "none")
/// ```
public struct Explanation<Output>: CustomStringConvertible {
  /// A condition: a policy `match` condition, or the whole expression.
  public struct Condition: Sendable {
    /// The `id` of the policy rule the condition belongs to, `nil` for a rule without an id and
    /// for an expression.
    public var ruleID: String?
    /// The condition as written, with line breaks folded into spaces.
    public var text: String
    /// The 1-based line where the condition starts, or `nil` when unknown.
    public var line: Int?
    /// The 1-based column where the condition starts, counted in Unicode scalars, or `nil`.
    public var column: Int?
    /// The source of the match's output, `nil` for a nested rule or an expression.
    public var output: String?
    /// The value of the condition, `nil` when it was not evaluated.
    public var value: Value?
    /// The predicates the condition combines with `&&`, `||`, `!` and `?:`, in source order; the
    /// condition itself when it combines nothing.
    public var terms: [Term]
  }

  /// A predicate: a comparison, a function call, a membership test or a boolean fact.
  public struct Term: Sendable {
    /// The predicate as written.
    public var text: String
    /// The 1-based line where the predicate starts, or `nil` when unknown.
    public var line: Int?
    /// The 1-based column where the predicate starts, counted in Unicode scalars, or `nil`.
    public var column: Int?
    /// The value of the predicate, `nil` when it was not evaluated.
    public var value: Value?
    /// The facts the predicate reads, such as `pr.additions`, with their values.
    public var inputs: [Input]
  }

  /// A fact read by a predicate.
  public struct Input: Sendable {
    /// The attribute as written, such as `pr.additions`.
    public var text: String
    /// Its value, `nil` when it was not evaluated.
    public var value: Value?
  }

  /// The output, or why the program could not produce it.
  public var result: Result<Output, EvaluationError>
  /// The conditions, in source order.
  public var conditions: [Condition]

  /// Every condition on one line, `source:line:column [rule] text -> value`, followed by its terms
  /// and their inputs, then the result.
  public var description: String {
    var lines: [String] = []
    for condition in conditions {
      var head = ""
      if let line = condition.line, let column = condition.column {
        head += "\(sourceName):\(line):\(column) "
      }
      if let ruleID = condition.ruleID {
        head += "[\(ruleID)] "
      }
      head += "\(condition.text) -> \(Self.format(condition.value))"
      lines.append(head)
      if condition.terms.count == 1, condition.terms[0].text == condition.text {
        if !condition.terms[0].inputs.isEmpty {
          lines.append("  " + Self.inputs(condition.terms[0]))
        }
        continue
      }
      let width = condition.terms.map { Self.format($0.value).unicodeScalars.count }.max() ?? 0
      for term in condition.terms {
        let value = Self.format(term.value)
        let padding = String(repeating: " ", count: width - value.unicodeScalars.count)
        var line = "  \(value)\(padding)  \(term.text)"
        if !term.inputs.isEmpty {
          line += "   " + Self.inputs(term)
        }
        lines.append(line)
      }
    }
    switch result {
    case .success(let output): lines.append("result: \(output)")
    case .failure(let error): lines.append("error: \(error.message)")
    }
    return lines.joined(separator: "\n")
  }

  let sourceName: String

  init(result: Result<Output, EvaluationError>, conditions: [Condition], sourceName: String) {
    self.result = result
    self.conditions = conditions
    self.sourceName = sourceName
  }

  private static func format(_ value: Value?) -> String {
    value.map { "\($0)" } ?? "not evaluated"
  }

  private static func inputs(_ term: Term) -> String {
    "(" + term.inputs.map { "\($0.text) = \(format($0.value))" }.joined(separator: ", ") + ")"
  }
}

extension Explanation: Sendable where Output: Sendable {}

// MARK: - Templates

/// Where to find the values of a condition in the evaluation state: computed once per program.
struct ConditionTemplate: Sendable {
  var ruleID: String?
  var text: String
  var line: Int?
  var column: Int?
  var output: String?
  var ids: [Int64]
  var terms: [TermTemplate]
}

struct TermTemplate: Sendable {
  var text: String
  var line: Int?
  var column: Int?
  var ids: [Int64]
  var inputs: [(text: String, ids: [Int64])]
}

extension ConditionTemplate {
  func condition<Output>(_ state: EvaluationState?) -> Explanation<Output>.Condition {
    func value(_ ids: [Int64]) -> Value? {
      ids.lazy.compactMap { state?.value(ofExpressionID: $0) }.first
    }
    return Explanation<Output>.Condition(
      ruleID: ruleID, text: text, line: line, column: column, output: output, value: value(ids),
      terms: terms.map { term in
        Explanation<Output>.Term(
          text: term.text, line: term.line, column: term.column, value: value(term.ids),
          inputs: term.inputs.map { Explanation<Output>.Input(text: $0.text, value: value($0.ids)) })
      })
  }
}

/// Builds condition templates: finds the conditions and their predicates in the ASTs the
/// conditions were checked as, and the nodes holding their values in the evaluated AST.
struct ExplanationBuilder {
  /// The source the offsets index, as Unicode scalars.
  let scalars: [Unicode.Scalar]
  /// The AST the program evaluates; its node ids key the evaluation state.
  let evaluated: AST
  /// Evaluated node ids by offset range and node kind.
  private var index: [NodeKey: [Int64]] = [:]

  init(source: String, evaluated: AST) {
    self.scalars = Array(source.unicodeScalars)
    self.evaluated = evaluated
    walk(evaluated.expr) { expr in
      if let range = evaluated.sourceInfo.offsetRange(expr.id) {
        index[NodeKey(range: range, kind: kindSignature(expr)), default: []].append(expr.id)
      }
    }
  }

  /// The template for the whole evaluated expression.
  func expressionTemplate() -> ConditionTemplate {
    template(evaluated.expr, in: evaluated, ruleID: nil, output: nil, sameAST: true)
  }

  /// Templates for every match condition of a compiled policy rule, in file order.
  func policyTemplates(_ rule: CompiledRule) -> [ConditionTemplate] {
    var templates: [ConditionTemplate] = []
    collect(rule, into: &templates)
    return templates.sorted { ($0.line ?? .max, $0.column ?? .max) < ($1.line ?? .max, $1.column ?? .max) }
  }

  private func collect(_ rule: CompiledRule, into templates: inout [ConditionTemplate]) {
    for match in rule.matches {
      if let condition = match.condition, !match.conditionIsLiteral(true) {
        let output = match.output?.expr.map { span($0.expr, in: $0).text }
        templates.append(template(condition.expr, in: condition, ruleID: rule.id?.value, output: output, sameAST: false))
      }
      if let nested = match.nestedRule {
        collect(nested, into: &templates)
      }
    }
  }

  private func template(_ expr: Expr, in ast: AST, ruleID: String?, output: String?, sameAST: Bool) -> ConditionTemplate {
    let whole = span(expr, in: ast)
    var leaves: [Expr] = []
    predicates(expr, into: &leaves)
    let terms = leaves.map { leaf in
      let leafSpan = span(leaf, in: ast)
      var inputs: [(text: String, ids: [Int64])] = []
      var seen: Set<String> = []
      attributes(leaf) { attribute in
        let text = span(attribute, in: ast).text
        if !text.isEmpty, seen.insert(text).inserted {
          inputs.append((text, ids(of: attribute, in: ast, sameAST: sameAST)))
        }
      }
      return TermTemplate(
        text: leafSpan.text, line: leafSpan.line, column: leafSpan.column,
        ids: ids(of: leaf, in: ast, sameAST: sameAST), inputs: inputs)
    }
    return ConditionTemplate(
      ruleID: ruleID, text: whole.text, line: whole.line, column: whole.column, output: output,
      ids: ids(of: expr, in: ast, sameAST: sameAST), terms: terms)
  }

  /// The evaluated node ids holding the value of `expr`: itself when it is part of the evaluated
  /// AST, otherwise the nodes the policy composer copied it to (same source range and kind).
  private func ids(of expr: Expr, in ast: AST, sameAST: Bool) -> [Int64] {
    if sameAST {
      return [expr.id]
    }
    guard let range = ast.sourceInfo.offsetRange(expr.id) else { return [] }
    return index[NodeKey(range: range, kind: kindSignature(expr))] ?? []
  }

  /// The source text of a sub-expression, from the first offset of its nodes to the end of the
  /// last, with line breaks and the indentation after them folded into one space.
  private func span(_ expr: Expr, in ast: AST) -> (text: String, line: Int?, column: Int?) {
    var start = Int.max
    var end = Int.min
    walk(expr) { node in
      guard let range = ast.sourceInfo.offsetRange(node.id), range.start >= 0 else { return }
      let nodeStart = Int(range.start)
      start = min(start, nodeStart)
      end = max(end, scalarEnd(start: nodeStart, utf8Length: Int(range.stop) - nodeStart))
      switch node.kind {
      case .select(let select) where !select.testOnly:
        // A selection is recorded at its dot; the field name follows.
        end = max(end, fieldEnd(dot: nodeStart, field: select.field))
      case .ident(let name):
        // The checker resolves `a.b.c` to one identifier recorded at the last dot.
        guard let qualified = qualifiedNameSpan(dot: nodeStart, name: name) else { break }
        start = min(start, qualified.lowerBound)
        end = max(end, qualified.upperBound)
      default:
        break
      }
    }
    guard start < end, start < scalars.count else { return ("", nil, nil) }
    end = balancedEnd(start: start, end: min(end, scalars.count))
    var text = String.UnicodeScalarView()
    var pendingSpace = false
    for scalar in scalars[start..<min(end, scalars.count)] {
      if scalar == "\n" || scalar == "\r" {
        pendingSpace = true
        continue
      }
      if pendingSpace {
        if scalar == " " || scalar == "\t" { continue }
        if let last = text.last, last != " " { text.append(" ") }
        pendingSpace = false
      }
      text.append(scalar)
    }
    let location = ast.sourceInfo.location(ofOffset: Int32(start))
    let located = location.line >= 1 && location.column >= 0
    return (String(text), located ? location.line : nil, located ? location.column + 1 : nil)
  }

  /// The source range of a qualified identifier the checker recorded at its last dot, `nil` when
  /// the source does not spell it there.
  private func qualifiedNameSpan(dot: Int, name: String) -> Range<Int>? {
    let components = name.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count > 1, let last = components.last, dot < scalars.count, scalars[dot] == "." else {
      return nil
    }
    let prefix = Array(components.dropLast().joined(separator: ".").unicodeScalars)
    let start = dot - prefix.count
    guard start >= 0, Array(scalars[start..<dot]) == prefix else { return nil }
    return start..<fieldEnd(dot: dot, field: String(last))
  }

  /// The end of the field name selected at `dot`, or `dot` when the source does not spell it there.
  private func fieldEnd(dot: Int, field: String) -> Int {
    guard dot < scalars.count, scalars[dot] == "." else { return dot }
    var offset = dot + 1
    while offset < scalars.count, scalars[offset] == " " || scalars[offset] == "\n" || scalars[offset] == "\t" {
      offset += 1
    }
    if offset < scalars.count, scalars[offset] == "`" {
      // An escaped field name: `a.`b-c``.
      var close = offset + 1
      while close < scalars.count, scalars[close] != "`" { close += 1 }
      return min(close + 1, scalars.count)
    }
    let name = Array(field.unicodeScalars)
    guard offset + name.count <= scalars.count, Array(scalars[offset..<(offset + name.count)]) == name else {
      return dot
    }
    return offset + name.count
  }

  /// Extends `end` past the brackets left open between `start` and `end`: calls are recorded at
  /// their opening parenthesis, so the closing one belongs to no node.
  private func balancedEnd(start: Int, end: Int) -> Int {
    var open: [Unicode.Scalar] = []
    var quote: Unicode.Scalar?
    var escaped = false
    var offset = start
    while offset < scalars.count, offset < end || !open.isEmpty {
      let scalar = scalars[offset]
      offset += 1
      if let q = quote {
        if escaped {
          escaped = false
        } else if scalar == "\\" {
          escaped = true
        } else if scalar == q {
          quote = nil
        }
        continue
      }
      switch scalar {
      case "\"", "'": quote = scalar
      case "(": open.append(")")
      case "[": open.append("]")
      case "{": open.append("}")
      case ")", "]", "}":
        if open.last == scalar {
          open.removeLast()
        } else if offset > end {
          return end  // unbalanced source: keep what the nodes cover
        }
      default: break
      }
    }
    return max(end, offset)
  }

  /// The scalar offset where a token of `utf8Length` bytes starting at scalar `start` ends: the
  /// parser records token ends as start plus the token's UTF-8 length.
  private func scalarEnd(start: Int, utf8Length: Int) -> Int {
    var offset = start
    var remaining = utf8Length
    while remaining > 0, offset < scalars.count {
      remaining -= UTF8.width(scalars[offset])
      offset += 1
    }
    return offset
  }
}

private struct NodeKey: Hashable {
  let range: OffsetRange
  let kind: String
}

/// A coarse node kind for matching a node with its copies: the policy composer replaces rule
/// variables by block slots, so attributes match attributes whatever their spelling.
private func kindSignature(_ expr: Expr) -> String {
  switch expr.kind {
  case .call(let call): return "call:\(call.function)"
  case .ident, .select: return "attribute"
  case .literal: return "literal"
  case .list: return "list"
  case .map: return "map"
  case .struct: return "struct"
  case .comprehension: return "comprehension"
  case .unspecified: return "unspecified"
  }
}

/// The predicates a condition combines: operands of the logical operators and the conditional,
/// recursively.
private func predicates(_ expr: Expr, into leaves: inout [Expr]) {
  if case .call(let call) = expr.kind, call.target == nil,
    [Operators.logicalAnd, Operators.logicalOr, Operators.logicalNot, Operators.conditional].contains(call.function)
  {
    for arg in call.args {
      predicates(arg, into: &leaves)
    }
    return
  }
  leaves.append(expr)
}

/// The outermost attributes (`pr.additions`, `lists.trusted`) a predicate reads, outside
/// comprehensions and presence tests.
private func attributes(_ expr: Expr, _ visit: (Expr) -> Void) {
  switch expr.kind {
  case .ident:
    visit(expr)
  case .select(let select):
    if select.testOnly { return }
    visit(expr)
  case .call(let call):
    if let target = call.target { attributes(target, visit) }
    for arg in call.args { attributes(arg, visit) }
  case .list(let list):
    for element in list.elements { attributes(element, visit) }
  case .map(let map):
    for entry in map.entries {
      attributes(entry.key, visit)
      attributes(entry.value, visit)
    }
  case .struct(let structure):
    for field in structure.fields { attributes(field.value, visit) }
  case .literal, .comprehension, .unspecified:
    return
  }
}

/// Visits every node of an expression, pre-order.
func walk(_ expr: Expr, _ visit: (Expr) -> Void) {
  visit(expr)
  switch expr.kind {
  case .select(let select):
    walk(select.operand, visit)
  case .call(let call):
    if let target = call.target { walk(target, visit) }
    for arg in call.args { walk(arg, visit) }
  case .list(let list):
    for element in list.elements { walk(element, visit) }
  case .map(let map):
    for entry in map.entries {
      walk(entry.key, visit)
      walk(entry.value, visit)
    }
  case .struct(let structure):
    for field in structure.fields { walk(field.value, visit) }
  case .comprehension(let c):
    for part in [c.iterRange, c.accuInit, c.loopCondition, c.loopStep, c.result] {
      walk(part, visit)
    }
  case .ident, .literal, .unspecified:
    return
  }
}
