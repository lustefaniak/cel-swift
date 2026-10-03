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
// Ported from cel-go interpreter/decorators.go (decRegexProgramSizeLimit, isRegexFunction,
// regexLimitCall) and common/types/regex.go (the error message of CompileRegexWithLimit).

import CELRegex

/// Rejects regex patterns whose compiled program exceeds `limit` instructions: constant patterns
/// when the program is planned, others when the call is evaluated (cel-go
/// `decRegexProgramSizeLimit`). A limit of zero or less disables the check.
func decRegexProgramSizeLimit(_ limit: Int) -> InterpretableDecorator {
  { i in
    guard limit > 0, let call = i as? any InterpretableCall,
      isRegexFunction(call.function, call.overloadID), call.args.count >= 2
    else {
      return i
    }
    let regexArg = call.args[1]
    if let constant = regexArg as? any InterpretableConst {
      if case .string(let pattern) = constant.value, let size = try? Regexp.programSize(pattern),
        size > limit
      {
        throw PlanError(regexProgramSizeMessage(size, limit))
      }
      return i
    }
    return RegexLimitCall(call, limit: limit)
  }
}

/// The functions whose second argument is a regex pattern (cel-go `isRegexFunction`).
private func isRegexFunction(_ function: String, _ overload: String) -> Bool {
  switch function {
  case Overloads.matches, "regex.extract", "regex.extractAll", "regex.replace":
    return true
  default:
    break
  }
  switch overload {
  case Overloads.matches, Overloads.matchesString, "regex_extract_string_string",
    "regex_extractAll_string_string", "regex_replace_string_string_string",
    "regex_replace_string_string_string_int":
    return true
  default:
    return false
  }
}

private func regexProgramSizeMessage(_ size: Int, _ limit: Int) -> String {
  "regex program size \(size) exceeds limit of \(limit)"
}

/// A regex call whose pattern is checked against the size limit before the call (cel-go
/// `regexLimitCall`). As in cel-go the pattern argument is evaluated twice.
final class RegexLimitCall: InterpretableNode, InterpretableCall {
  let call: any InterpretableCall
  let limit: Int

  init(_ call: any InterpretableCall, limit: Int) {
    self.call = call
    self.limit = limit
  }

  var id: Int64 { call.id }
  var function: String { call.function }
  var overloadID: String { call.overloadID }
  var args: [any Interpretable] { call.args }

  func eval(_ frame: ExecutionFrame) -> Value {
    let args = call.args
    if args.count >= 2 {
      let patternVal = args[1].eval(frame)
      if patternVal.isUnknownOrError {
        return patternVal
      }
      if case .string(let pattern) = patternVal {
        do {
          let size = try Regexp.programSize(pattern)
          if size > limit {
            return .error(EvalError(regexProgramSizeMessage(size, limit)))
          }
        } catch {
          return .error(EvalError("\(error)"))
        }
      }
    }
    return call.eval(frame)
  }
}
