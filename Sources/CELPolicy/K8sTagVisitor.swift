// Copyright 2025 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Ported from cel-go policy/test_tag_handler_k8s.go.


/// A tag visitor for the custom policy tags used in Kubernetes admission policies; cel-go uses it
/// to test custom tags (`K8sTestTagHandler`), and so do the policy tests and `cel-swift policy test`.
package struct K8sTagVisitor: PolicyTagVisitor {
  package init() {}

  package func visitPolicyTag(
    _ tagName: String,
    id: Int64,
    node: YAMLNode,
    policy: inout Policy,
    context: inout PolicyParserContext
  ) {
    switch tagName {
    case "kind":
      policy.setMetadata(context.makeString(node).value, forKey: "kind")
    case "metadata":
      do {
        guard case .map = try node.decodeValue() else {
          context.reportError(atID: id, "invalid yaml metadata node: \(node.value)")
          return
        }
      } catch {
        context.reportError(atID: id, "invalid yaml metadata node: \(node.value), error: \(error)")
      }
    case "spec":
      let spec = context.parseRule(node, policy: &policy)
      policy.rule = spec
    default:
      context.reportError(atID: id, "unsupported policy tag: \(tagName)")
    }
  }

  package func visitRuleTag(
    _ tagName: String,
    id: Int64,
    node: YAMLNode,
    policy: inout Policy,
    rule: inout Policy.Rule,
    context: inout PolicyParserContext
  ) {
    switch tagName {
    case "failurePolicy":
      policy.setMetadata(context.makeString(node).value, forKey: tagName)
    case "matchConstraints":
      do {
        guard case .map = try node.decodeValue() else {
          context.reportError(atID: id, "invalid yaml matchConstraints node: \(node.value)")
          return
        }
      } catch {
        context.reportError(atID: id, "invalid yaml matchConstraints node: \(node.value), error: \(error)")
      }
    case "validations":
      let id = context.collectMetadata(node)
      if node.longTag != "tag:yaml.org,2002:seq" {
        context.reportError(atID: id, "invalid 'validations' type, expected list got: \(node.longTag)")
        return
      }
      for val in node.content {
        rule.matches.append(context.parseMatch(val, policy: &policy))
      }
    default:
      context.reportError(atID: id, "unsupported rule tag: \(tagName)")
    }
  }

  package func visitMatchTag(
    _ tagName: String,
    id: Int64,
    node: YAMLNode,
    policy: inout Policy,
    match: inout Policy.Match,
    context: inout PolicyParserContext
  ) {
    if (match.output?.value ?? "").isEmpty {
      match.output = Policy.ValueString(value: "'invalid admission request'")
    }
    switch tagName {
    case "expression":
      // The K8s expression to validate must return false in order to generate a violation message.
      var condition = context.makeString(node)
      condition.value = "!(" + condition.value + ")"
      match.condition = condition
    case "messageExpression":
      match.output = context.makeString(node)
    default:
      break
    }
  }
}
