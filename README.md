# cel-swift

A pure-Swift implementation of the [Common Expression Language](https://github.com/google/cel-spec),
ported from [cel-go](https://github.com/cel-expr/cel-go) and measured against the cel-spec conformance suite.

Status: scaffolding (milestone M0). The plan, milestones and conformance targets are in
[docs/plan.md](docs/plan.md).

## Building

```sh
git clone --recurse-submodules git@github.com:lustefaniak/cel-swift.git
swift build
swift test
```

Requires Swift 6.0 or newer. macOS 13+, iOS 16+, Linux.

## License

Apache-2.0, see [LICENSE](LICENSE) and [NOTICE](NOTICE).
