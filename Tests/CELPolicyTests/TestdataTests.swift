import Testing

@testable import CELPolicy

/// Every policy and environment config in cel-go's test data must load. Compile-time errors in
/// the `errors*`, `limits` and `aggregate_*` policies are the compiler's to report; parsing them
/// succeeds.
struct TestdataTests {
  @Test(arguments: Testdata.policyTestNames())
  func policyParses(name: String) throws {
    let parser = PolicyParser(tagVisitor: name == "k8s" ? K8sTagVisitor() : DefaultPolicyTagVisitor())
    let policy = try parser.parse(try Testdata.policySource(name))
    #expect(policy.rule != nil)
  }

  static let configFiles: [String] =
    Testdata.files(under: "policy/testdata", extensions: ["yaml"]).filter {
      $0.hasSuffix("config.yaml")
    } + Testdata.files(under: "common/env/testdata", extensions: ["yaml", "json"])
    + ["tools/celtest/testdata/config.yaml"]

  @Test(arguments: configFiles)
  func configLoads(path: String) throws {
    let config = try EnvironmentConfig(yaml: try Testdata.read(path))
    try config.validate()
    #expect(config.name.isEmpty == false)
  }

  @Test func configFileCount() {
    #expect(Self.configFiles.count == 26)
  }

  @Test func k8sPolicyTags() throws {
    let policy = try PolicyParser(tagVisitor: K8sTagVisitor()).parse(try Testdata.policySource("k8s"))
    #expect(policy.metadata(forKey: "kind") as? String == "ValidatingAdmissionPolicy")
    #expect(policy.metadata(forKey: "failurePolicy") as? String == "Fail")
    let rule = try #require(policy.rule)
    #expect(rule.variables.map(\.name.value) == ["env", "break_glass"])
    let match = try #require(rule.matches.first)
    #expect(match.condition.value.hasPrefix("!("))
    #expect(match.output?.value.contains("format") == true)
  }

  @Test func restrictedDestinationsStructure() throws {
    let policy = try PolicyParser().parse(try Testdata.policySource("restricted_destinations"))
    #expect(policy.name.value == "restricted_destinations")
    let rule = try #require(policy.rule)
    #expect(rule.variables.count == 6)
    #expect(rule.matches.count == 3)
    #expect(rule.semantic == .firstMatch)
  }

  @Test func aggregateSemanticPropagatesToPolicy() throws {
    let policy = try PolicyParser().parse(try Testdata.policySource("agent_tool_execution_governance"))
    #expect(policy.semantic == .aggregate)
    #expect(policy.rule?.semantic == .aggregate)
  }
}
