// The examples of Sources/CELExtensions/CELExtensions.docc, so the documentation keeps compiling and
// stays true. Keep them in sync when either side changes.

import CEL
import CELExtensions
import Testing

@Suite("CELExtensions documentation examples")
struct ExtensionsDocumentationTests {
  @Test func landingPage() throws {
    let env = try Environment(.library(.strings), .library(.lists), .library(.math))
    let program = try env.program(env.compile("'b,a,c'.split(',').sort().join('-')"))
    #expect(try program.evaluate().value == "a-b-c")
  }

  @Test func addLibraries() throws {
    let env = try Environment(
      .variable("path", .string),
      .library(.strings),
      .optionalTypes,
      .library(.regex)
    )
    let checked = try env.compile("regex.extract(path, '/users/([0-9]+)').orValue('none')")
    let result = try env.program(checked).evaluate(["path": "/users/42/posts"])
    #expect(result.value == "42")

    let net = try Environment(.library(.network))
    let inRange = try net.program(net.compile("cidr('10.0.0.0/8').containsIP(ip('10.1.2.3'))"))
    #expect(try inRange.evaluate().value == true)
  }

  @Test func pinVersions() throws {
    let pinned = try Environment(.library(.math(version: 0)))
    _ = try pinned.compile("math.least(3, 1, 2)")
    #expect {
      _ = try pinned.compile("math.sqrt(4.0)")
    } throws: { error in
      "\(error)".hasPrefix("""
        ERROR: <input>:1:1: undeclared reference to 'math' (in container '')
         | math.sqrt(4.0)
         | ^
        """)
    }
  }

  @Test func boundExpensiveFunctions() throws {
    let bounded = try Environment(.library(.lists(maxRangeSize: 1000)))
    let range = try bounded.program(bounded.compile("lists.range(5000).size()"))
    #expect {
      _ = try range.evaluate()
    } throws: { error in
      "\(error)" == "lists.range: size 5000 exceeds maximum allowed (1000)"
    }
  }
}
