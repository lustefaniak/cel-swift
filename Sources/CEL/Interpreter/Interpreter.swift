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
//
// Ported from cel-go interpreter/interpreter.go (planner options, stateful observers) and the
// ObservableInterpretable of interpreter/interpretable.go.

/// An observer that keeps per-evaluation state in the frame's evaluation context
/// (cel-go `StatefulObserver`).
package protocol StatefulObserver: Sendable {
  /// Creates (or returns the existing) state for an evaluation.
  func initState(_ frame: ExecutionFrame) throws -> AnyObject
  /// The state of the evaluation, if initialised.
  func getState(_ frame: ExecutionFrame) -> AnyObject?
  /// Reports a node's value.
  func observe(_ frame: ExecutionFrame, _ id: Int64, _ step: Any, _ value: Value)
}

/// Records the value of every node in an ``EvalState`` (cel-go `evalStateFactory`).
package struct EvalStateObserver: StatefulObserver {
  let factory: @Sendable () -> any EvalState

  package init(factory: @escaping @Sendable () -> any EvalState = { EvalStateRecorder() }) {
    self.factory = factory
  }

  package func initState(_ frame: ExecutionFrame) throws -> AnyObject {
    let ctx = frame.ensureContext()
    if let state = ctx.state {
      return state
    }
    let state = factory()
    ctx.state = state
    return state
  }

  package func getState(_ frame: ExecutionFrame) -> AnyObject? {
    frame.context?.state
  }

  package func observe(_ frame: ExecutionFrame, _ id: Int64, _ step: Any, _ value: Value) {
    frame.context?.state?.setValue(id, value)
  }
}

/// The root of a program with observers: initialises their state before evaluation and reports it
/// afterwards (cel-go `ObservableInterpretable`).
package final class ObservableInterpretable: InterpretableNode, @unchecked Sendable, Interpretable {
  package let inner: any Interpretable
  package let observers: [any StatefulObserver]

  init(_ inner: any Interpretable, observers: [any StatefulObserver]) {
    self.inner = inner
    self.observers = observers
  }

  package var id: Int64 { inner.id }

  package func eval(_ frame: ExecutionFrame) -> Value {
    observeEval(frame) { _ in }
  }

  /// Evaluates, passing each observer's state to `report` before and after evaluation, so state is
  /// available even when evaluation is cancelled (cel-go `ObserveExec`).
  package func observeEval(_ frame: ExecutionFrame, _ report: (AnyObject) -> Void) -> Value {
    for obs in observers {
      do {
        report(try obs.initState(frame))
      } catch {
        return .error(EvalError("\(error)"))
      }
    }
    let result = inner.eval(frame)
    for obs in observers {
      if let state = obs.getState(frame) {
        report(state)
      }
    }
    return result
  }
}
