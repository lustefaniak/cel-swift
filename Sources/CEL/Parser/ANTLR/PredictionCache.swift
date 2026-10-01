// Copyright (c) 2012-2022 The ANTLR Project. All rights reserved.
// Use of this file is governed by the BSD 3-clause license that
// can be found in the LICENSE.txt file in the project root.

// Ported from antlr4-go v4.13.1: the generated parser's static `DecisionToDFA` (with the simulator's
// shared `ATNSimulatorError` state), the `stateMu` / `edgeMu` locks of atn.go and the RWMutex of
// mutex.go.

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#elseif canImport(Android)
  import Android
#endif

/// The prediction DFAs of the CEL grammar, shared by every parse that uses this cache.
///
/// antlr4-go keeps them in a process-wide static and guards them with two read-write locks; here a
/// `Parser` owns one cache and copies of the parser (and environments extended from its environment)
/// share it. The DFAs depend only on the grammar's ATN, never on parser options or input, so any
/// parses may share one.
///
/// Invariants, which are what make the `@unchecked Sendable` conformance sound:
/// - `decisionToDFA` and `errorState` are fixed at init.
/// - `stateLock` guards each `DFA`'s state set (`get` / `put` / `count`), the `s0` of a non-precedence
///   DFA and the `configs` of a precedence DFA's `s0`.
/// - `edgeLock` guards every `DFAState.edges`, including the precedence start states held in the
///   edges of a precedence DFA's `s0`. A thread that needs both takes `stateLock` first.
/// - A `DFAState` is filled in completely (configs, accept flags, prediction, predicates) by one
///   thread before it is published through `DFA.put` under `stateLock`; after that only its `edges`
///   change. Its `ATNConfigSet` is read-only from then on and its `ATNConfig`s are never mutated:
///   prediction only mutates configs it has just created.
/// - Target states are computed outside the locks; two parses may compute the same state, and the
///   second `put` finds the first one's state and uses it (antlr `addDFAState`).
final class PredictionCache: @unchecked Sendable {
  /// The prediction DFA of each decision of the grammar.
  let decisionToDFA: [DFA]
  /// The DFA state that marks a failed prediction (antlr `ATNSimulatorError`). DFA edges point at it
  /// and prediction compares with it by identity, so it belongs to the cache.
  let errorState = DFAState(stateNumber: Int.max, configs: ATNConfigSet(fullCtx: false))
  /// antlr `ATN.stateMu`.
  let stateLock = ReadWriteLock()
  /// antlr `ATN.edgeMu`.
  let edgeLock = ReadWriteLock()

  init(atn: ATN) {
    decisionToDFA = atn.decisionToState.indices.map { DFA(atn: atn, decision: $0) }
  }
}

/// A pthread read-write lock (antlr4-go `RWMutex`). `Synchronization` needs macOS 15 / iOS 18, above
/// the package's floor.
final class ReadWriteLock {
  private let lock: UnsafeMutablePointer<pthread_rwlock_t>

  init() {
    lock = UnsafeMutablePointer<pthread_rwlock_t>.allocate(capacity: 1)
    lock.initialize(to: pthread_rwlock_t())
    let status = pthread_rwlock_init(lock, nil)
    precondition(status == 0, "pthread_rwlock_init failed: \(status)")
  }

  deinit {
    pthread_rwlock_destroy(lock)
    lock.deinitialize(count: 1)
    lock.deallocate()
  }

  /// Runs `body` holding the lock shared.
  func withReadLock<R>(_ body: () throws -> R) rethrows -> R {
    let status = pthread_rwlock_rdlock(lock)
    precondition(status == 0, "pthread_rwlock_rdlock failed: \(status)")
    defer { pthread_rwlock_unlock(lock) }
    return try body()
  }

  /// Runs `body` holding the lock exclusively.
  func withWriteLock<R>(_ body: () throws -> R) rethrows -> R {
    let status = pthread_rwlock_wrlock(lock)
    precondition(status == 0, "pthread_rwlock_wrlock failed: \(status)")
    defer { pthread_rwlock_unlock(lock) }
    return try body()
  }
}
