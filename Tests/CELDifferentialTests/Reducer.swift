// Delta reduction of a failing case: replace subtrees with same-typed descendants or minimal literals, and
// bindings with minimal values, keeping every step that still shows the same mismatch category.

/// Runs requests on both sides and returns the mismatches of each.
struct Checker {
  var swift = SwiftSide()

  mutating func check(_ cases: [DiffCase]) throws -> [[Mismatch]] {
    try checkWithOutcomes(cases).map(\.mismatches)
  }

  /// The oracle's outcome and the mismatches of each case.
  mutating func checkWithOutcomes(_ cases: [DiffCase]) throws -> [(
    oracle: Outcome, mismatches: [Mismatch], diverged: Bool
  )] {
    let requests = cases.map(\.request)
    let answers = try Oracle.evaluate(requests)
    var results = zip(requests, answers).map { request, answer in
      let oracle = Outcome(oracle: answer)
      let observed = swift.run(request)
      let mismatches = Mismatch.compare(
        oracle: oracle, swift: observed, usesExtensions: request["uses_extensions"]?.boolValue ?? false)
      return (
        oracle: oracle, mismatches: mismatches, diverged: Mismatch.divergence(oracle, observed) != nil,
        observed: observed
      )
    }
    // cel-go iterates maps in Go's random map order, so results and costs that depend on it vary between runs.
    // A mismatch only counts if no rerun of cel-go agrees with cel-swift.
    var pending = results.indices.filter { !results[$0].mismatches.isEmpty }
    for _ in 0..<Self.reruns where !pending.isEmpty {
      let again = try Oracle.evaluate(pending.map { requests[$0] })
      pending = zip(pending, again).compactMap { i, answer in
        let usesExtensions = requests[i]["uses_extensions"]?.boolValue ?? false
        if Mismatch.compare(oracle: Outcome(oracle: answer), swift: results[i].observed, usesExtensions: usesExtensions)
          .isEmpty
        {
          results[i].mismatches = []
          return nil
        }
        return i
      }
    }
    return results.map { ($0.oracle, $0.mismatches, $0.diverged) }
  }

  /// How often a mismatching case is rerun on cel-go.
  static let reruns = 8
}

enum Reducer {
  /// Every tree obtained by replacing one node: with a descendant of the same static type, or a minimal
  /// literal of its type.
  static func candidates(_ node: Node) -> [Node] {
    var out: [Node] = []
    var descendants: [Node] = []
    func collect(_ n: Node) {
      for c in n.children {
        if c.type == node.type { descendants.append(c) }
        collect(c)
      }
    }
    collect(node)
    out += descendants
    let rendered = node.rendered
    out += Generator.minimalLiterals(node.type).filter { $0.rendered != rendered }
    for (i, child) in node.children.enumerated() {
      for replacement in candidates(child) {
        var copy = node
        copy.children[i] = replacement
        out.append(copy)
      }
    }
    return out
  }

  static func minimalValue(_ v: GValue) -> GValue? {
    switch v {
    case .int(let i): return i == 0 ? nil : .int(0)
    case .uint(let u): return u == 0 ? nil : .uint(0)
    case .double(let d): return d == 0 && d.sign == .plus ? nil : .double(0)
    case .string(let s): return s.isEmpty ? nil : .string("")
    case .bytes(let b): return b.isEmpty ? nil : .bytes([])
    case .bool(let b): return b ? .bool(false) : nil
    case .duration(let n): return n == 0 ? nil : .duration(0)
    case .timestamp(let s, let n): return s == 0 && n == 0 ? nil : .timestamp(seconds: 0, nanos: 0)
    case .list(let l): return l.isEmpty ? nil : .list([])
    case .map(let m): return m.isEmpty ? nil : .map([])
    case .optional(let o): return o == nil ? nil : .optional(nil)
    case .null: return nil
    case .message(let name, let fields): return fields.isEmpty ? nil : .message(name, [])
    }
  }

  /// Bindings with one value simplified, for every binding the expression mentions.
  static func bindingCandidates(_ c: DiffCase) -> [DiffCase] {
    var out: [DiffCase] = []
    let text = c.expr
    for (i, (name, value)) in c.bindings.enumerated() {
      guard mentions(text, name) else { continue }
      var variants: [GValue] = []
      if let m = minimalValue(value) { variants.append(m) }
      if case .list(let items) = value, items.count > 1 {
        variants += items.indices.map { j in .list(items.enumerated().filter { $0.offset != j }.map(\.element)) }
      }
      if case .map(let entries) = value, entries.count > 1 {
        variants += entries.indices.map { j in .map(entries.enumerated().filter { $0.offset != j }.map(\.element)) }
      }
      for v in variants {
        var copy = c
        copy.bindings[i] = (name, v)
        out.append(copy)
      }
    }
    return out
  }

  static func mentions(_ text: String, _ name: String) -> Bool {
    let scalars = Array(text.unicodeScalars)
    let target = Array(name.unicodeScalars)
    func isIdent(_ s: Unicode.Scalar) -> Bool {
      s == "_" || ("a"..."z").contains(s) || ("A"..."Z").contains(s) || ("0"..."9").contains(s)
    }
    var i = 0
    while i + target.count <= scalars.count {
      if Array(scalars[i..<i + target.count]) == target,
        i == 0 || (!isIdent(scalars[i - 1]) && scalars[i - 1] != "."),
        i + target.count == scalars.count || !isIdent(scalars[i + target.count])
      {
        return true
      }
      i += 1
    }
    return false
  }

  /// Reduces `c` while it keeps a mismatch of `category`.
  static func reduce(_ c: DiffCase, category: Mismatch.Category, checker: inout Checker, maxRounds: Int = 200)
    throws -> DiffCase
  {
    var current = c
    var rounds = 0
    while rounds < maxRounds {
      rounds += 1
      var variants: [DiffCase]
      if let text = current.textOverride {
        // A mutated text has no tree: delete runs of characters instead.
        let scalars = Array(text.unicodeScalars)
        variants = []
        for length in [8, 4, 2, 1] where length <= scalars.count {
          for start in stride(from: 0, to: scalars.count - length + 1, by: length) {
            var copy = current
            var rest = scalars
            rest.removeSubrange(start..<start + length)
            var s = ""
            s.unicodeScalars.append(contentsOf: rest)
            copy.textOverride = s
            variants.append(copy)
          }
        }
      } else {
        variants = candidates(current.root).map { root -> DiffCase in
          var copy = current
          copy.root = root
          return copy
        }
      }
      variants.sort { $0.expr.unicodeScalars.count < $1.expr.unicodeScalars.count }
      variants += bindingCandidates(current)
      var improved = false
      var start = 0
      while start < variants.count && !improved {
        let batch = Array(variants[start..<min(start + 64, variants.count)])
        start += 64
        let results = try checker.check(batch)
        if let hit = results.firstIndex(where: { $0.contains { $0.category == category } }) {
          current = batch[hit]
          improved = true
        }
      }
      if !improved { break }
    }
    return current
  }
}
