// Copyright 2018 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Ported from cel-go common/debug/debug.go.

/// An element the debug printer can adorn: an expression or a map / struct entry.
package enum DebugElement {
  case expr(Expr)
  case entry(EntryExpr)

  /// The id of the element.
  package var id: Int64 {
    switch self {
    case .expr(let e): return e.id
    case .entry(let e): return e.id
    }
  }
}

/// Supplies metadata appended after each element in a debug string.
package protocol DebugAdorner {
  /// The metadata for `element`, appended verbatim.
  func metadata(for element: DebugElement) -> String
}

/// The cel-go debug string format, used to compare parser output byte for byte.
package enum ExprDebug {
  private struct EmptyAdorner: DebugAdorner {
    func metadata(for element: DebugElement) -> String { "" }
  }

  private struct IDAdorner: DebugAdorner {
    func metadata(for element: DebugElement) -> String {
      if case .expr(let e) = element {
        return "@id:\(e.id) "
      }
      return ""
    }
  }

  /// The unadorned debug string of `expr`.
  package static func toDebugString(_ expr: Expr) -> String {
    toAdornedDebugString(expr, adorner: EmptyAdorner())
  }

  /// The debug string of `expr` with every expression adorned with `@id:<id> `.
  package static func toDebugStringWithIDs(_ expr: Expr) -> String {
    toAdornedDebugString(expr, adorner: IDAdorner())
  }

  /// The debug string of `expr` with metadata from `adorner` after every element.
  package static func toAdornedDebugString(_ expr: Expr, adorner: some DebugAdorner) -> String {
    var w = Writer(adorner: adorner)
    w.buffer(expr)
    return w.output
  }

  /// Formats a literal the way cel-go's debug printer does.
  package static func formatLiteral(_ c: Constant) -> String {
    switch c {
    case .bool(let v): return v ? "true" : "false"
    case .bytes(let v): return "b" + GoFormat.quote(bytes: v)
    case .double(let v): return GoFormat.formatFloat(v)
    case .int(let v): return String(v)
    case .string(let v): return GoFormat.quote(v)
    case .uint(let v): return "\(v)u"
    case .null: return "null"
    }
  }

  private struct Writer<A: DebugAdorner> {
    let adorner: A
    var output = ""
    var indent = 0
    var lineStart = true

    init(adorner: A) {
      self.adorner = adorner
    }

    mutating func buffer(_ e: Expr) {
      switch e.kind {
      case .literal(let c):
        append(ExprDebug.formatLiteral(c))
      case .ident(let name):
        append(name)
      case .select(let s):
        buffer(s.operand)
        append(".")
        append(s.field)
        if s.testOnly {
          append("~test-only~")
        }
      case .call(let c):
        appendCall(c)
      case .list(let l):
        append("[")
        if !l.elements.isEmpty {
          appendLine()
          addIndent()
          for (i, elem) in l.elements.enumerated() {
            if i > 0 {
              append(",")
              appendLine()
            }
            buffer(elem)
          }
          removeIndent()
          appendLine()
        }
        append("]")
      case .map(let m):
        append("{")
        if !m.entries.isEmpty {
          appendLine()
          addIndent()
          for (i, entry) in m.entries.enumerated() {
            if i > 0 {
              append(",")
              appendLine()
            }
            if entry.isOptional {
              append("?")
            }
            buffer(entry.key)
            append(":")
            buffer(entry.value)
            adorn(.entry(.mapEntry(entry)))
          }
          removeIndent()
          appendLine()
        }
        append("}")
      case .struct(let s):
        append(s.typeName)
        append("{")
        if !s.fields.isEmpty {
          appendLine()
          addIndent()
          for (i, field) in s.fields.enumerated() {
            if i > 0 {
              append(",")
              appendLine()
            }
            if field.isOptional {
              append("?")
            }
            append(field.name)
            append(":")
            buffer(field.value)
            adorn(.entry(.structField(field)))
          }
          removeIndent()
          appendLine()
        }
        append("}")
      case .comprehension(let c):
        appendComprehension(c)
      case .unspecified:
        break
      }
      adorn(.expr(e))
    }

    mutating func appendCall(_ call: Expr.Call) {
      if let target = call.target {
        buffer(target)
        append(".")
      }
      append(call.function)
      append("(")
      if !call.args.isEmpty {
        addIndent()
        appendLine()
        for (i, arg) in call.args.enumerated() {
          if i > 0 {
            append(",")
            appendLine()
          }
          buffer(arg)
        }
        removeIndent()
        appendLine()
      }
      append(")")
    }

    mutating func appendComprehension(_ c: Expr.Comprehension) {
      append("__comprehension__(")
      addIndent()
      appendLine()
      append("// Variable")
      appendLine()
      append(c.iterVar)
      append(",")
      appendLine()
      if c.hasIterVar2 {
        append(c.iterVar2)
        append(",")
        appendLine()
      }
      append("// Target")
      appendLine()
      buffer(c.iterRange)
      append(",")
      appendLine()
      append("// Accumulator")
      appendLine()
      append(c.accuVar)
      append(",")
      appendLine()
      append("// Init")
      appendLine()
      buffer(c.accuInit)
      append(",")
      appendLine()
      append("// LoopCondition")
      appendLine()
      buffer(c.loopCondition)
      append(",")
      appendLine()
      append("// LoopStep")
      appendLine()
      buffer(c.loopStep)
      append(",")
      appendLine()
      append("// Result")
      appendLine()
      buffer(c.result)
      append(")")
      removeIndent()
    }

    mutating func append(_ s: String) {
      doIndent()
      output += s
    }

    mutating func doIndent() {
      if lineStart {
        lineStart = false
        output += String(repeating: "  ", count: indent)
      }
    }

    mutating func adorn(_ element: DebugElement) {
      append(adorner.metadata(for: element))
    }

    mutating func appendLine() {
      output += "\n"
      lineStart = true
    }

    mutating func addIndent() {
      indent += 1
    }

    mutating func removeIndent() {
      indent -= 1
      precondition(indent >= 0, "negative indent")
    }
  }
}
