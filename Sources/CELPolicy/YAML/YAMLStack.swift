// Running the recursive YAML and policy passes on a large stack. Not a ported file.
//
// go-yaml's decoder and cel-go's policy parser and compiler recurse once per nesting level and rely on
// Go's growable stacks. Swift threads have fixed stacks (512 KiB for secondary threads on Darwin), so the
// ported passes run on a thread sized for the document's depth when the calling thread's may not
// suffice, as the CEL parser and checker do for deep expressions.

import CEL

/// Runs `body` on a thread whose stack fits `depth` levels of recursion when the calling thread's
/// stack may not, and returns its result.
package func withStack<T, E: Error>(depth: Int, _ body: () throws(E) -> T) throws(E) -> T {
  guard let size = LargeStack.requiredStackSize(units: depth) else {
    return try body()
  }
  var result: Result<T, E>?
  LargeStack.run(stackSize: size) {
    do throws(E) {
      result = .success(try body())
    } catch {
      result = .failure(error)
    }
  }
  switch result {
  case .success(let value)?:
    return value
  case .failure(let error)?:
    throw error
  case nil:
    return try body()
  }
}

extension YAMLNode {
  /// The height of the node tree (a scalar is 1), and whether it holds aliases, computed without
  /// recursion. Aliases count as leaves: their targets are not visited.
  var shape: (height: Int, hasAliases: Bool) {
    var height = 0
    var hasAliases = false
    var stack: [(YAMLNode, Int)] = [(self, 1)]
    while let (node, depth) = stack.popLast() {
      height = Swift.max(height, depth)
      if node.kind == .alias {
        hasAliases = true
      }
      for child in node.content {
        stack.append((child, depth + 1))
      }
    }
    return (height, hasAliases)
  }

  /// An upper bound on how deep decoding the node can recurse: its height, or the decoder's depth
  /// limit when aliases can splice other trees in.
  package var decodeDepthBound: Int {
    let shape = shape
    return shape.hasAliases ? Swift.max(shape.height, YAMLDecoder.maxDepth) : shape.height
  }
}
