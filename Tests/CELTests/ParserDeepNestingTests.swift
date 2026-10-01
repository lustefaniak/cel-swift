import Foundation
import Testing

@testable import CEL

/// Runs `body` on a thread with the given stack size and waits for it.
func runOnThread(stackSize: Int, _ body: @escaping @Sendable () -> Void) {
  let done = DispatchSemaphore(value: 0)
  let thread = Thread {
    body()
    done.signal()
  }
  thread.stackSize = stackSize
  thread.start()
  done.wait()
}

/// Deeply nested input at cel-go's default recursion limit must parse without overflowing the stack,
/// also when the caller runs on a secondary thread with a 512 KiB stack.
@Suite struct ParserDeepNestingTests {
  static let depth = 240

  static let inputs: [String] = [
    String(repeating: "[", count: depth) + "1" + String(repeating: "]", count: depth),
    String(repeating: "(", count: depth) + "1" + String(repeating: ")", count: depth),
    String(repeating: "{1: ", count: depth) + "1" + String(repeating: "}", count: depth),
    String(repeating: "f(", count: depth) + "1" + String(repeating: ")", count: depth),
    (0..<depth).map { "a\($0) ? b : " }.joined() + "c",
    (0..<depth).map { "a\($0)" }.joined(separator: " + "),
    "a" + String(repeating: ".b", count: depth),
    "a" + String(repeating: "[0]", count: depth),
    String(repeating: "[x, ", count: depth / 2) + "1" + String(repeating: "].map(x, x)", count: depth / 2),
  ]

  @Test(arguments: inputs)
  func parsesOnSmallStack(_ input: String) {
    let result = ResultBox()
    runOnThread(stackSize: 512 << 10) {
      do {
        let p = try Parser(.macros(Macro.allMacros))
        let (_, errors) = p.parse(TextSource(input))
        result.set(errors.isEmpty ? "" : errors.toDisplayString())
      } catch {
        result.set("\(error)")
      }
    }
    #expect(result.value == "")
  }

  @Test func recursionLimitIsReported() {
    let input = String(repeating: "[", count: 300) + "1" + String(repeating: "]", count: 300)
    let result = ResultBox()
    runOnThread(stackSize: 512 << 10) {
      let p = try? Parser(.macros(Macro.allMacros))
      let errors = p?.parse(TextSource(input)).errors
      result.set(errors?.toDisplayString() ?? "no parser")
    }
    #expect(result.value == "ERROR: <input>:-1:0: expression recursion limit exceeded: 250")
  }
}

final class ResultBox: @unchecked Sendable {
  private let lock = NSLock()
  private var stored = "unset"

  func set(_ v: String) {
    lock.lock()
    stored = v
    lock.unlock()
  }

  var value: String {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }
}
