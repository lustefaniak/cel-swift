// Copyright (c) 2012-2022 The ANTLR Project. All rights reserved.
// Use of this file is governed by the BSD 3-clause license that
// can be found in the LICENSE.txt file in the project root.

// The process-wide prediction DFA cache of antlr4-go (the generated parser's static
// `DecisionToDFA`, guarded by the simulator's `stateMu` / `edgeMu`), shared by every parse.
//
// PROTOTYPE (branch perf/shared-parser-cache, needs a maintainer decision): this is the one piece of
// global mutable state in CEL. It is an `@unchecked Sendable` class guarded by a pthread mutex because
// `Synchronization.Mutex` needs macOS 15 / iOS 18. The whole of `adaptivePredict` runs under the
// lock, which serializes prediction between concurrent parses (antlr-go locks per DFA operation).

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#elseif canImport(Android)
  import Android
#endif

final class PredictionCache: @unchecked Sendable {
  /// The cache shared by all parses.
  static let shared = PredictionCache(decisions: celParserATN.decisionToState.count)

  /// The prediction DFA of each decision, created on first use. Guarded by `mutex`.
  var decisionToDFA: [DFA?]
  /// The DFA state that marks a failed prediction; edges to it are cached, so it is shared too.
  let errorState = DFAState(stateNumber: Int.max, configs: ATNConfigSet(fullCtx: false))

  private let mutex: UnsafeMutablePointer<pthread_mutex_t>

  private init(decisions: Int) {
    decisionToDFA = Array(repeating: nil, count: decisions)
    mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
    mutex.initialize(to: pthread_mutex_t())
    pthread_mutex_init(mutex, nil)
  }

  deinit {
    pthread_mutex_destroy(mutex)
    mutex.deallocate()
  }

  /// Runs `body` holding the cache lock.
  func withLock<R>(_ body: () throws -> R) rethrows -> R {
    pthread_mutex_lock(mutex)
    defer { pthread_mutex_unlock(mutex) }
    return try body()
  }
}
