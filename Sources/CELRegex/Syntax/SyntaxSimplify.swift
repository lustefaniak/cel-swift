// Copyright 2011 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// Port of Go's regexp/syntax/simplify.go.

extension Syntax.Regexp {
  /// Simplify returns a regexp equivalent to re but without counted repetitions
  /// and with various other simplifications, such as rewriting /(?:a+)+/ to /a+/.
  /// The resulting regexp will execute correctly but its string representation
  /// will not produce the same parse tree, because capturing parentheses
  /// may have been duplicated or removed. For example, the simplified form
  /// for /(x){1,2}/ is /(x)(x)?/ but both parentheses capture as $1.
  /// The returned regexp may share structure with or be the original.
  ///
  /// Go's Simplify recurses over the tree; this visits the same nodes in the same order with an
  /// explicit stack, so trees up to the parser's height limit fit any thread's stack.
  package func simplify() -> Syntax.Regexp {
    var stack: [(re: Syntax.Regexp, simplified: [Syntax.Regexp])] = [(self, [])]
    while true {
      let top = stack.count - 1
      let re = stack[top].re
      let done = stack[top].simplified.count
      if done < re.simplifyChildren {
        stack.append((re.sub[done], []))
        continue
      }
      let result = re.simplifyStep(stack[top].simplified)
      stack.removeLast()
      if stack.isEmpty {
        return result
      }
      stack[stack.count - 1].simplified.append(result)
    }
  }

  /// The number of children Go's Simplify simplifies before combining.
  private var simplifyChildren: Int {
    switch op {
    case .capture, .concat, .alternate:
      return sub.count
    case .star, .plus, .quest:
      return 1
    case .repeat:
      return min == 0 && max == 0 ? 0 : 1
    default:
      return 0
    }
  }

  /// One step of Go's Simplify, given the simplified children (subs[i] = Simplify(re.Sub[i])).
  private func simplifyStep(_ subs: [Syntax.Regexp]) -> Syntax.Regexp {
    let re = self
    switch re.op {
    case .capture, .concat, .alternate:
      // Simplify children, building new Regexp if children change.
      var nre = re
      for (i, sub) in re.sub.enumerated() {
        let nsub = subs[i]
        if nre === re && nsub !== sub {
          // Start a copy.
          nre = re.copy()
          nre.rune = []
          nre.sub = Array(re.sub[..<i])
        }
        if nre !== re {
          nre.sub.append(nsub)
        }
      }
      return nre

    case .star, .plus, .quest:
      let sub = subs[0]
      return simplify1(re.op, re.flags, sub, re)

    case .repeat:
      // Special special case: x{0} matches the empty string
      // and doesn't even need to consider x.
      if re.min == 0 && re.max == 0 {
        return Syntax.Regexp(op: .emptyMatch)
      }

      // The fun begins.
      let sub = subs[0]

      // x{n,} means at least n matches of x.
      if re.max == -1 {
        // Special case: x{0,} is x*.
        if re.min == 0 {
          return simplify1(.star, re.flags, sub, nil)
        }

        // Special case: x{1,} is x+.
        if re.min == 1 {
          return simplify1(.plus, re.flags, sub, nil)
        }

        // General case: x{4,} is xxxx+.
        let nre = Syntax.Regexp(op: .concat)
        for _ in 0..<(re.min - 1) {
          nre.sub.append(sub)
        }
        nre.sub.append(simplify1(.plus, re.flags, sub, nil))
        return nre
      }

      // Special case x{0} handled above.

      // Special case: x{1} is just x.
      if re.min == 1 && re.max == 1 {
        return sub
      }

      // General case: x{n,m} means n copies of x and m copies of x?
      // The machine will do less work if we nest the final m copies,
      // so that x{2,5} = xx(x(x(x)?)?)?

      // Build leading prefix: xx.
      var prefix: Syntax.Regexp? = nil
      if re.min > 0 {
        let p = Syntax.Regexp(op: .concat)
        for _ in 0..<re.min {
          p.sub.append(sub)
        }
        prefix = p
      }

      // Build and attach suffix: (x(x(x)?)?)?
      if re.max > re.min {
        var suffix = simplify1(.quest, re.flags, sub, nil)
        var i = re.min + 1
        while i < re.max {
          let nre2 = Syntax.Regexp(op: .concat)
          nre2.sub = [sub, suffix]
          suffix = simplify1(.quest, re.flags, nre2, nil)
          i += 1
        }
        guard let prefix else {
          return suffix
        }
        prefix.sub.append(suffix)
      }
      if let prefix {
        return prefix
      }

      // Some degenerate case like min > max or min < max < 0.
      // Handle as impossible match.
      return Syntax.Regexp(op: .noMatch)

    default:
      return re
    }
  }
}

extension Syntax.Regexp {
  /// Reports whether the tree contains an OpRepeat node, which only Simplify removes.
  func containsRepeat() -> Bool {
    var found = false
    forEachPreOrder { re in
      if re.op == .repeat {
        found = true
      }
    }
    return found
  }
}

/// simplify1 implements Simplify for the unary OpStar,
/// OpPlus, and OpQuest operators. It returns the simple regexp
/// equivalent to
///
///     Regexp{Op: op, Flags: flags, Sub: {sub}}
///
/// under the assumption that sub is already simple, and
/// without first allocating that structure. If the regexp
/// to be returned turns out to be equivalent to re, simplify1
/// returns re instead.
///
/// simplify1 is factored out of Simplify because the implementation
/// for other operators generates these unary expressions.
/// Letting them call simplify1 makes sure the expressions they
/// generate are simple.
private func simplify1(_ op: Syntax.Op, _ flags: Syntax.Flags, _ sub: Syntax.Regexp, _ re: Syntax.Regexp?)
  -> Syntax.Regexp
{
  // Special case: repeat the empty string as much as
  // you want, but it's still the empty string.
  if sub.op == .emptyMatch {
    return sub
  }
  // The operators are idempotent if the flags match.
  if op == sub.op && flags.intersection(.nonGreedy) == sub.flags.intersection(.nonGreedy) {
    return sub
  }
  if let re, re.op == op, re.flags.intersection(.nonGreedy) == flags.intersection(.nonGreedy),
    sub === re.sub[0]
  {
    return re
  }

  let nre = Syntax.Regexp(op: op, flags: flags)
  nre.sub = [sub]
  return nre
}
