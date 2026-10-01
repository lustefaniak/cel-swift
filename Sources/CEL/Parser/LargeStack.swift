// Running deeply recursive work on a thread with a large stack.
//
// cel-go's recursive-descent parser relies on Go's growable goroutine stacks; Swift threads have fixed
// stacks (512 KiB for secondary threads on Darwin, often less in debug builds than the recursion needs).
// The parser estimates how deep an input can make it recurse and, when that could exceed a small
// budget, parses on a dedicated thread whose stack is sized for the input, then joins it.

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#elseif canImport(Android)
  import Android
#endif

enum LargeStack {
  #if DEBUG
    /// Conservative stack use per nesting unit in unoptimized builds.
    static let bytesPerUnit = 16 << 10
  #else
    /// Conservative stack use per nesting unit in optimized builds.
    static let bytesPerUnit = 4 << 10
  #endif

  /// Stack the parser may use on the calling thread.
  static let inlineBudget = 192 << 10

  /// An upper bound on the recursion units an input can cause: every bracket, `?`, operator and
  /// `.` can add one level of parser or visitor recursion.
  static func nestingUnits(_ scalars: [Unicode.Scalar]) -> Int {
    var units = 0
    for s in scalars {
      switch s {
      case "(", "[", "{", "?", ".", "+", "-", "*", "/", "%", "<", ">", "=", "!", "&", "|":
        units += 1
      default:
        break
      }
    }
    return units
  }

  /// The stack size needed for `units` nesting units, or nil when the calling thread suffices.
  static func requiredStackSize(units: Int) -> Int? {
    let needed = 64 << 10 + units * bytesPerUnit
    if needed <= inlineBudget {
      return nil
    }
    let size = max(needed * 2, 1 << 20)
    let page = 16 << 10
    return min((size + page - 1) / page * page, 1 << 30)
  }

  private final class Work {
    let body: () -> Void
    init(_ body: @escaping () -> Void) {
      self.body = body
    }
  }

  /// Runs `body` on a new thread with the given stack size and waits for it; runs it on the calling
  /// thread if a thread cannot be created.
  static func run(stackSize: Int, _ body: () -> Void) {
    withoutActuallyEscaping(body) { escapable in
      let work = Work(escapable)
      let arg = Unmanaged.passRetained(work).toOpaque()
      var attr = pthread_attr_t()
      guard pthread_attr_init(&attr) == 0 else {
        Unmanaged<Work>.fromOpaque(arg).release()
        escapable()
        return
      }
      defer { pthread_attr_destroy(&attr) }
      pthread_attr_setstacksize(&attr, stackSize)
      #if canImport(Darwin)
        var thread: pthread_t? = nil
        let rc = pthread_create(
          &thread, &attr,
          { raw in
            let work = Unmanaged<Work>.fromOpaque(raw).takeRetainedValue()
            work.body()
            return nil
          }, arg)
        if rc == 0, let thread {
          pthread_join(thread, nil)
          return
        }
      #else
        var thread = pthread_t()
        let rc = pthread_create(
          &thread, &attr,
          { raw in
            guard let raw else { return nil }
            let work = Unmanaged<Work>.fromOpaque(raw).takeRetainedValue()
            work.body()
            return nil
          }, arg)
        if rc == 0 {
          pthread_join(thread, nil)
          return
        }
      #endif
      Unmanaged<Work>.fromOpaque(arg).release()
      escapable()
    }
  }
}
