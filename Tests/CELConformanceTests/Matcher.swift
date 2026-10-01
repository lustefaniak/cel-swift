// Result matching, following cel-go conformance/conformance_test.go (conformanceTest, diffValue, diffType) and
// the SimpleTest documentation in cel-spec simple.proto.

import CELSpecProtos
import SwiftProtobuf

/// The verdict for one test in one mode.
enum Verdict: Sendable, Equatable {
  case pass
  case fail(String)
  case notImplemented(String)

  var passed: Bool { self == .pass }
}

enum Matcher {
  static func verdict(for request: ConformanceRequest, outcome: ConformanceOutcome) -> Verdict {
    let test = request.test
    switch outcome {
    case .notImplemented(let reason):
      return .notImplemented(reason)
    case .parseError(let message):
      return .fail("parse error: \(message)")
    case .checkError(let message):
      return .fail("check error: \(message)")
    case .checked(let deducedType):
      guard request.checkOnly else {
        return .fail("runner stopped after checking a test that is not check_only")
      }
      guard case .typedResult(let typed)? = test.resultMatcher else {
        return .fail("unexpected matcher kind for check only test: \(matcherKind(test.resultMatcher))")
      }
      return compareType(want: typed.deducedType, got: deducedType)
    case .evaluated(let result, let deducedType):
      if request.checkOnly {
        return .fail("runner evaluated a check_only test")
      }
      return compareEvaluation(test: test, result: result, deducedType: deducedType)
    }
  }

  private static func compareEvaluation(
    test: Cel_Expr_Conformance_Test_SimpleTest,
    result: Cel_Expr_ExprValue,
    deducedType: Cel_Expr_Type?
  ) -> Verdict {
    switch test.resultMatcher {
    case .value(let want)?:
      return compareValue(want: want, got: result)
    case .typedResult(let typed)?:
      let valueVerdict = compareValue(want: typed.result, got: result)
      guard valueVerdict.passed else { return valueVerdict }
      // cel-go always compares the deduced type because it always checks; in parse-only mode (or with
      // disable_check) there is no deduced type, so only the value is compared.
      guard let deducedType else { return .pass }
      return compareType(want: typed.deducedType, got: deducedType)
    case .evalError?, .anyEvalErrors?:
      // cel-go only requires that evaluation failed; error contents are not compared. cel-go reports
      // any_eval_errors as an unexpected matcher kind; the simple.proto contract is an error match, so it is
      // treated like eval_error. No cel-spec v0.25.3 test uses it.
      if case .error? = result.kind { return .pass }
      return .fail("want an evaluation error, got \(describe(result))")
    case .unknown(let want)?:
      // Not used by any cel-spec v0.25.3 test; cel-go reports it as an unexpected matcher kind.
      return compareUnknown(wantAnyOf: [want], got: result)
    case .anyUnknowns(let want)?:
      return compareUnknown(wantAnyOf: want.unknowns, got: result)
    case nil:
      return .fail("missing result matcher")
    }
  }

  private static func compareUnknown(wantAnyOf: [Cel_Expr_UnknownSet], got: Cel_Expr_ExprValue) -> Verdict {
    guard case .unknown(let set)? = got.kind else {
      return .fail("want an unknown result, got \(describe(got))")
    }
    let gotIDs = Set(set.exprs)
    if wantAnyOf.contains(where: { Set($0.exprs) == gotIDs }) { return .pass }
    return .fail("unknown set \(set.exprs.sorted()) matches none of \(wantAnyOf.map { $0.exprs })")
  }

  private static func compareType(want: Cel_Expr_Type, got: Cel_Expr_Type) -> Verdict {
    if want == got { return .pass }
    return .fail("deduced type: want \(short(want)), got \(short(got))")
  }

  private static func compareValue(want: Cel_Expr_Value, got: Cel_Expr_ExprValue) -> Verdict {
    guard case .value(let value)? = got.kind else {
      return .fail("want value \(short(want)), got \(describe(got))")
    }
    if valuesEqual(want, value) { return .pass }
    return .fail("value: want \(short(want)), got \(short(value))")
  }

  /// Proto equality with the two relaxations simple.proto documents: map entries are unordered, and a NaN
  /// matches any NaN. `Any` payloads are compared after unpacking, like cel-go's protocmp.Transform().
  static func valuesEqual(_ a: Cel_Expr_Value, _ b: Cel_Expr_Value) -> Bool {
    switch (a.kind, b.kind) {
    case (.doubleValue(let x)?, .doubleValue(let y)?):
      return x == y || (x.isNaN && y.isNaN)
    case (.listValue(let x)?, .listValue(let y)?):
      return x.values.count == y.values.count && zip(x.values, y.values).allSatisfy(valuesEqual)
    case (.mapValue(let x)?, .mapValue(let y)?):
      guard x.entries.count == y.entries.count else { return false }
      var unmatched = y.entries
      for entry in x.entries {
        guard
          let index = unmatched.firstIndex(where: {
            valuesEqual(entry.key, $0.key) && valuesEqual(entry.value, $0.value)
          })
        else { return false }
        unmatched.remove(at: index)
      }
      return true
    case (.objectValue(let x)?, .objectValue(let y)?):
      return anyEqual(x, y)
    default:
      return a == b
    }
  }

  private static func anyEqual(_ a: Google_Protobuf_Any, _ b: Google_Protobuf_Any) -> Bool {
    if a == b { return true }
    guard a.typeURL == b.typeURL else { return false }
    // Serialized bytes can differ for equal messages (field order, map order); compare decoded messages.
    guard
      let type = Google_Protobuf_Any.messageType(forTypeURL: a.typeURL),
      let x = try? type.init(unpackingAny: a, extensions: CELSpecProtos.extensions),
      let y = try? type.init(unpackingAny: b, extensions: CELSpecProtos.extensions)
    else { return false }
    return x.isEqualTo(message: y)
  }

  static func matcherKind(_ matcher: Cel_Expr_Conformance_Test_SimpleTest.OneOf_ResultMatcher?) -> String {
    switch matcher {
    case .value?: "value"
    case .typedResult?: "typed_result"
    case .evalError?: "eval_error"
    case .anyEvalErrors?: "any_eval_errors"
    case .unknown?: "unknown"
    case .anyUnknowns?: "any_unknowns"
    case nil: "none"
    }
  }

  private static func describe(_ v: Cel_Expr_ExprValue) -> String {
    switch v.kind {
    case .value(let value)?: "value \(short(value))"
    case .error(let set)?: "error \(set.errors.map(\.message))"
    case .unknown(let set)?: "unknown \(set.exprs)"
    case nil: "nothing"
    }
  }

  private static func short(_ message: some SwiftProtobuf.Message) -> String {
    message.textFormatString().split(separator: "\n").joined(separator: " ")
  }
}
