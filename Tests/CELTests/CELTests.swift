import Testing

@testable import CEL

@Test func specVersionIsPinned() {
  #expect(CEL.specVersion == "v0.25.3")
}
