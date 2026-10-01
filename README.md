# cel-swift

A pure-Swift implementation of the [Common Expression Language](https://github.com/google/cel-spec),
ported from [cel-go](https://github.com/cel-expr/cel-go) and measured against the cel-spec conformance suite.

Status: pre-release. The parser, checker, interpreter, cost model, standard library, cel-go's extension
libraries, protobuf support and the CEL policy parser are ported; 2461 of 2508 cel-spec conformance
tests pass in checked mode. [docs/status.md](docs/status.md) has the current state,
[docs/plan.md](docs/plan.md) the milestones, [docs/divergences.md](docs/divergences.md) every deliberate
difference from cel-go.

## Usage

Add the package and depend on the `CEL` product (and `CELExtensions`, `CELProtobuf`, `CELPolicy` as
needed):

```swift
.package(url: "https://github.com/lustefaniak/cel-swift.git", branch: "main"),
```

Declare what expressions may use, compile once, evaluate many times:

```swift
import CEL

let env = try Environment(.variable("user", .map(key: .string, value: .dyn)))
let checked = try env.compile("user.age >= 18 && user.country in ['PL', 'DK']")
let program = try env.program(checked)
let result = try program.evaluate(["user": ["age": 30, "country": "PL"]])
print(result.value)   // true
```

Compile errors are thrown as `CompileError`, rendered like cel-go's:

```
ERROR: <input>:1:16: undeclared reference to 'limt' (in container '')
 | request.size > limt
 | ...............^
```

The rest of the API covers custom functions with Swift implementations (`.function(...)`), cel-go's
extension libraries (`import CELExtensions`, `.library(.strings)`), standard library subsets
(`Library.standard(subset:)`), cost estimation and limits (`env.estimateCost`, `.costLimit`), partial
evaluation with unknowns, and constant folding and inlining (`env.optimize`). The DocC catalog in
`Sources/CEL/CEL.docc` has a getting-started article; build it with
`swift package generate-documentation` (needs the swift-docc plugin) or open the package in Xcode and
choose Product > Build Documentation.

### Command line

The `cel-swift` executable evaluates, checks and parses expressions and has a REPL:

```sh
$ swift run cel-swift eval --declare 'x:int' --let 'x=20' 'x * 2 + 2'
42
$ swift run cel-swift eval --ext strings "'hello'.upperAscii()"
"HELLO"
$ swift run cel-swift check --debug --declare 'm:map(string, int)' 'm.a + 1'
_+_(
  m~map(string, int)^m.a~int,
  1~int
)~int^add_int64
$ swift run cel-swift repl
cel-swift> %let x = 10
cel-swift> [1, 2, 3].filter(i, i < x)
[1, 2, 3] : list(int)
```

`cel-swift help <command>` lists the options: `--container`, `--ext NAME[:VERSION]`,
`--declare NAME:TYPE`, `--let NAME=EXPR`, `--json FILE` (bind the members of a JSON object), and per
command `--parse-only`, `--show-type`, `--cost-limit`, `--debug`.

## Building

```sh
git clone --recurse-submodules git@github.com:lustefaniak/cel-swift.git
swift build
swift test
```

Requires Swift 6.0 or newer. macOS 13+, iOS 16+, Linux.

## License

Apache-2.0, see [LICENSE](LICENSE) and [NOTICE](NOTICE).
