// Copyright 2020 Google LLC
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
// Ported from cel-go common/containers/container_test.go (ToQualifiedName is tested with the AST).

import Testing

@testable import CEL

struct ContainersTests {
  @Test func resolveCandidateNames() throws {
    let c = try Container(.name("a.b.c.M.N"))
    #expect(
      c.resolveCandidateNames("R.s") == [
        "a.b.c.M.N.R.s", "a.b.c.M.R.s", "a.b.c.R.s", "a.b.R.s", "a.R.s", "R.s",
      ])
  }

  @Test func resolveCandidateNamesFullyQualifiedName() throws {
    let c = try Container(.name("a.b.c.M.N"))
    // The leading '.' indicates the name is already fully-qualified.
    #expect(c.resolveCandidateNames(".R.s") == ["R.s"])
  }

  @Test func resolveCandidateNamesEmptyContainer() {
    #expect(Container.default.resolveCandidateNames("R.s") == ["R.s"])
  }

  @Test func alias() throws {
    var cont = try Container.default.extended(.alias("my.example.pkg.verbose", as: "bigex"))
    #expect(cont.resolveCandidateNames("bigex.Execute") == ["my.example.pkg.verbose.Execute"])
    cont = try Container.default.extended(.alias("really_long_package_name", as: "short"))
    #expect(cont.resolveCandidateNames("short") == ["really_long_package_name"])
    #expect(cont.resolveCandidateNames("short.field") == ["really_long_package_name.field"])
  }

  @Test func abbreviations() throws {
    let abbr = try Container.default.extended(.abbreviations("my.alias.R"))
    #expect(abbr.resolveCandidateNames("R") == ["my.alias.R"])
    let c = try Container(.name("a.b.c"), .abbreviations("my.alias.R"))
    #expect(c.resolveCandidateNames("R") == ["my.alias.R"])
    #expect(c.resolveCandidateNames("R.S.T") == ["my.alias.R.S.T"])
    #expect(c.resolveCandidateNames("S") == ["a.b.c.S", "a.b.S", "a.S", "S"])
  }

  struct AliasingErrorCase: Sendable, CustomTestStringConvertible {
    var container = ""
    var abbrevs: [String] = []
    var aliases: [(name: String, alias: String)] = []
    var err: String
    var testDescription: String { err }
  }

  @Test(arguments: [
    AliasingErrorCase(
      abbrevs: ["my.alias.R", "yer.other.R"],
      err:
        "abbreviation collides with existing reference: name=yer.other.R, abbreviation=R, existing=my.alias.R"
    ),
    AliasingErrorCase(
      container: "a.b.c.M.N", abbrevs: ["my.alias.a", "yer.other.b"],
      err:
        "abbreviation collides with container name: name=my.alias.a, abbreviation=a, container=a.b.c.M.N"
    ),
    AliasingErrorCase(
      abbrevs: [".bad"], err: "invalid qualified name: .bad, wanted name of the form 'qualified.name'"),
    AliasingErrorCase(
      abbrevs: ["bad.alias."],
      err: "invalid qualified name: bad.alias., wanted name of the form 'qualified.name'"),
    AliasingErrorCase(
      abbrevs: ["   bad_alias1"],
      err: "invalid qualified name: bad_alias1, wanted name of the form 'qualified.name'"),
    AliasingErrorCase(
      abbrevs: ["   bad.alias!  "],
      err: "invalid qualified name: bad.alias!, wanted name of the form 'qualified.name'"),
    AliasingErrorCase(
      aliases: [("my.alias", "b.c")], err: "alias must be non-empty and simple (not qualified): alias=b.c"),
    AliasingErrorCase(
      aliases: [(".my.qual.name", "a'")],
      err: "qualified name must not begin with a leading '.': .my.qual.name"),
  ])
  func aliasingErrors(tc: AliasingErrorCase) {
    var options: [Container.Option] = []
    if !tc.container.isEmpty {
      options.append(.name(tc.container))
    }
    if !tc.abbrevs.isEmpty {
      options.append(.abbreviations(tc.abbrevs))
    }
    for a in tc.aliases {
      options.append(.alias(a.name, as: a.alias))
    }
    #expect(throws: DeclarationError(tc.err)) {
      _ = try Container(options: options)
    }
  }

  @Test func extendAlias() throws {
    var c = try Container.default.extended(.alias("test.alias", as: "alias"))
    #expect(c.aliases["alias"] == "test.alias")
    c = try c.extended(.name("with.container"))
    #expect(c.name == "with.container")
    #expect(c.aliases["alias"] == "test.alias")
  }

  @Test func extendName() throws {
    var c = try Container.default.extended(.name(""))
    #expect(c.name == "")
    c = try Container.default.extended(.name("hello.container"))
    #expect(c.name == "hello.container")
    c = try c.extended(.name("goodbye.container"))
    #expect(c.name == "goodbye.container")
    #expect(throws: DeclarationError.self) {
      _ = try c.extended(.name(".bad.container"))
    }
  }
}
