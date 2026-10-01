import Foundation
import Testing

@testable import CELPolicy

/// Compares the YAML node trees and parsed policies with dumps produced by go-yaml and cel-go
/// (`Goldens/generate/gen.sh`) for every YAML file in cel-go's policy, celtest and env test data
/// plus the edge cases in `Goldens/cases`: tags, styles, positions, scalar resolution, syntax
/// error messages and policy source positions must be identical.
struct DifferentialTests {
  static let goldens = Testdata.repositoryRoot.appendingPathComponent("Tests/CELPolicyTests/Goldens")

  /// Splits a golden dump into `(path, expected dump)` sections.
  static func sections(_ golden: String) -> [(path: String, dump: String)] {
    var result: [(String, String)] = []
    var current: String?
    var body = ""
    for line in golden.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.hasPrefix("=== ") {
        if let current {
          result.append((current, body))
        }
        current = String(line.dropFirst(4))
        body = ""
      } else if current != nil {
        body += line + "\n"
      }
    }
    if let current {
      result.append((current, String(body.dropLast())))
    }
    return result.map { (path: $0.0, dump: $0.1) }
  }

  static func read(_ relativePath: String) throws -> String {
    let data = try Data(contentsOf: Testdata.repositoryRoot.appendingPathComponent(relativePath))
    return String(decoding: data, as: UTF8.self)
  }

  @Test func yamlNodes() throws {
    let golden = try String(contentsOf: Self.goldens.appendingPathComponent("yaml_nodes.txt"), encoding: .utf8)
    let sections = Self.sections(golden)
    #expect(sections.count > 50)
    for (path, expected) in sections {
      var out = ""
      let text = try Self.read(path)
      do {
        if let node = try YAMLNode.parseDocument(text) {
          dumpNode(node, 0, &out)
        } else {
          out += "kind=0 tag=tag:yaml.org,2002:null style=0 line=0 col=0 value=\"\"\n"
        }
      } catch {
        out += "error: \(error.message)\n"
      }
      #expect(out == expected, "\(path)")
    }
  }

  @Test func policies() throws {
    let golden = try String(contentsOf: Self.goldens.appendingPathComponent("policies.txt"), encoding: .utf8)
    let sections = Self.sections(golden)
    #expect(sections.count > 50)
    for (path, expected) in sections {
      var out = ""
      let visitor: any PolicyTagVisitor = path.contains("/k8s/") ? K8sTagVisitor() : DefaultPolicyTagVisitor()
      let source = PolicySource(try Self.read(path), description: path)
      do {
        let p = try PolicyParser(tagVisitor: visitor).parse(source)
        dumpValueString(p, "name", p.name, &out)
        dumpValueString(p, "description", p.description, &out)
        for i in p.imports {
          dumpValueString(p, "import", i.name, &out)
        }
        dumpRule(p, "", p.rule, &out)
      } catch {
        out += error.description + "\n"
      }
      #expect(out == expected, "\(path)")
    }
  }

  private func dumpNode(_ n: YAMLNode, _ depth: Int, _ out: inout String) {
    let indent = String(repeating: "  ", count: depth)
    out += "\(indent)kind=\(n.goKindValue) tag=\(n.longTag) style=\(n.style.rawValue)"
    out += " line=\(n.line) col=\(n.column) value=\(goQuote(n.value))\n"
    for child in n.content {
      dumpNode(child, depth + 1, &out)
    }
  }

  private func dumpValueString(_ p: Policy, _ label: String, _ v: Policy.ValueString, _ out: inout String) {
    let loc = p.sourceInfo.startLocation(of: v.id)
    let off = p.sourceInfo.offsetRanges[v.id]?.start ?? 0
    out += "\(label) id=\(v.id) loc=\(loc.line):\(loc.column) off=\(off) value=\(goQuote(v.value))\n"
  }

  private func dumpRule(_ p: Policy, _ prefix: String, _ r: Policy.Rule?, _ out: inout String) {
    guard let r else { return }
    let loc = p.sourceInfo.startLocation(of: r.sourceID)
    out += "\(prefix)rule id=\(r.sourceID) loc=\(loc.line):\(loc.column)\n"
    dumpValueString(p, prefix + "rule.id", r.id ?? .init(value: ""), &out)
    dumpValueString(p, prefix + "rule.description", r.description ?? .init(value: ""), &out)
    for v in r.variables {
      dumpValueString(p, prefix + "var.name", v.name, &out)
      dumpValueString(p, prefix + "var.expr", v.expression, &out)
    }
    for m in r.matches {
      let loc = p.sourceInfo.startLocation(of: m.sourceID)
      out += "\(prefix)match id=\(m.sourceID) loc=\(loc.line):\(loc.column)\n"
      dumpValueString(p, prefix + "match.cond", m.condition, &out)
      if let o = m.output { dumpValueString(p, prefix + "match.output", o, &out) }
      if let e = m.explanation { dumpValueString(p, prefix + "match.explanation", e, &out) }
      if let nested = m.rule { dumpRule(p, prefix + "  ", nested, &out) }
    }
  }
}
