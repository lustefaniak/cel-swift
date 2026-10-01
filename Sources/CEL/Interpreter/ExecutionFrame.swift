// Copyright 2026 Google LLC
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
//
// Ported from cel-go interpreter/frame.go, without the object pools and the asynchronous call
// machinery (async functions are not ported, see docs/divergences.md).

/// Why an evaluation was cancelled (cel-go `CancellationCause`).
package enum CancellationCause: Sendable, Equatable {
  /// The interrupt check reported an interruption (cel-go: the context was cancelled).
  case interrupted
  /// The runtime cost limit was exceeded.
  case costLimitExceeded
}

/// The state shared by all frames of one evaluation (cel-go `evalContext`).
package final class EvalContext {
  /// Reports whether the evaluation should stop; consulted every `interruptCheckFrequency`
  /// comprehension iterations (cel-go's context `Done` channel).
  package var interrupt: (() -> Bool)?
  package var interruptCheckFrequency: UInt = 0
  package var interruptCheckCount: UInt64 = 0
  package var interrupted = false

  /// The evaluation state recorder, when state tracking is enabled.
  package var state: (any EvalState)?
  /// The cost tracker, when cost tracking is enabled.
  package var costs: CostTracker?

  /// Set when the evaluation was cancelled. cel-go panics to unwind; here evaluation stops at the
  /// next comprehension iteration and the program reports the cancellation (docs/divergences.md).
  package var cancellation: CancellationCause?

  package init() {}
}

/// The context of a single evaluation: the activation plus the shared evaluation state
/// (cel-go `ExecutionFrame`). Comprehensions push child frames whose activation is the folder
/// holding the iteration and accumulator variables.
///
/// A frame belongs to one evaluation on one thread and must not be stored.
package final class ExecutionFrame: Activation {
  /// The activation variables are resolved in.
  package let activation: any Activation
  /// The frame of the enclosing scope, for comprehension frames.
  package let parentFrame: ExecutionFrame?
  /// The shared evaluation state; created on demand by observers.
  package var context: EvalContext?

  /// Creates a root frame for an activation.
  package init(_ activation: any Activation, context: EvalContext? = nil) {
    self.activation = activation
    self.parentFrame = nil
    self.context = context
  }

  private init(activation: any Activation, parentFrame: ExecutionFrame) {
    self.activation = activation
    self.parentFrame = parentFrame
    self.context = parentFrame.context
  }

  /// A child frame for a comprehension scope sharing this frame's evaluation context
  /// (cel-go `ExecutionFrame.Push`).
  package func push(_ activation: any Activation) -> ExecutionFrame {
    ExecutionFrame(activation: activation, parentFrame: self)
  }

  /// Configures interruption checks (cel-go `SetContext`).
  package func setInterrupt(_ check: @escaping () -> Bool, frequency: UInt) {
    let ctx = ensureContext()
    ctx.interrupt = check
    ctx.interruptCheckFrequency = frequency
    ctx.interruptCheckCount = 0
    ctx.interrupted = false
  }

  /// The evaluation context, created if the frame has none yet.
  package func ensureContext() -> EvalContext {
    if let context {
      return context
    }
    let ctx = EvalContext()
    context = ctx
    return ctx
  }

  package func resolveName(_ name: String) -> Value? {
    activation.resolveName(name)
  }

  package var parent: (any Activation)? {
    activation.parent
  }

  /// The frame's activation: for a comprehension frame the folder, which unwraps further to the
  /// enclosing frames and finally to the input activation.
  package var unwrapped: (any Activation)? {
    activation
  }

  package func isLocalVariable(_ name: String) -> Bool {
    if activation.isLocalVariable(name) {
      return true
    }
    return parentFrame?.isLocalVariable(name) ?? false
  }

  package func asPartialActivation() -> (any PartialActivation)? {
    activation.asPartialActivation()
  }

  /// Whether the evaluation has been interrupted (cel-go `CheckInterrupt`).
  package func checkInterrupt() -> Bool {
    guard let ctx = context else {
      return false
    }
    if ctx.interrupted {
      return true
    }
    ctx.interruptCheckCount &+= 1
    if ctx.interruptCheckFrequency > 0,
      ctx.interruptCheckCount % UInt64(ctx.interruptCheckFrequency) == 0,
      let interrupt = ctx.interrupt, interrupt()
    {
      ctx.interrupted = true
      ctx.cancellation = ctx.cancellation ?? .interrupted
      return true
    }
    return false
  }

  /// Whether the evaluation was cancelled by the cost limit or an interrupt.
  package var isCancelled: Bool {
    context?.cancellation != nil
  }
}

/// Returned by a comprehension stopped by an interrupt (cel-go `InterruptError`).
package let interruptErrorMessage = "operation interrupted"
