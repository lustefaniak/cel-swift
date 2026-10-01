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

// Ported from cel-go checker/printer.go.

extension Checker {
  /// The debug string of `expr`, a node of the checked `ast`, with each node adorned with its type
  /// (`~int`) and its resolved reference (`^name` or `^overload_a|overload_b`) (cel-go `Print`).
  package static func print(_ expr: Expr, checked ast: AST) -> String {
    ExprDebug.toAdornedDebugString(expr, adorner: SemanticAdorner(checked: ast))
  }
}

private struct SemanticAdorner: DebugAdorner {
  let checked: AST

  func metadata(for element: DebugElement) -> String {
    guard case .expr(let e) = element else {
      return ""
    }
    var result = ""
    if let t = checked.typeMap[e.id] {
      result += "~"
      result += t.checkerDescription
    }
    switch e.kind {
    case .ident, .call, .list, .struct, .select:
      if let ref = checked.referenceMap[e.id] {
        if ref.overloadIDs.isEmpty {
          result += "^" + ref.name
        } else {
          // Go sorts strings bytewise.
          let sorted = ref.overloadIDs.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
          result += "^" + sorted.joined(separator: "|")
        }
      }
    default:
      break
    }
    return result
  }
}
