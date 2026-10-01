# ``CELExtensions``

cel-go's extension libraries: strings, lists, math, sets, encoders, network, regex, bindings,
two-variable comprehensions and protobuf extensions.

## Overview

The CEL standard library covers operators, conversions, `size`, `contains`, `matches`, timestamps and
durations. The extension libraries add functions and macros on top, with the same names, versions,
behaviour and runtime cost as cel-go's [`ext` package](https://github.com/cel-expr/cel-go/tree/master/ext),
so expressions written for cel-go work unchanged.

Each library is a `Library` value. Add it to an environment with `Environment.Option.library(_:)`:

```swift
import CEL
import CELExtensions

let env = try Environment(.library(.strings), .library(.lists), .library(.math))
let program = try env.program(env.compile("'b,a,c'.split(',').sort().join('-')"))
print(try program.evaluate().value)   // "a-b-c"
```

The static properties, such as ``CEL/Library/strings``, select a library at its latest version; the
static functions, such as ``CEL/Library/strings(version:locale:maxPrecision:)``, take a version and the
library's options. <doc:EnablingExtensions> explains when to pin a version.

Environment configs in YAML (`CELPolicy`) name these libraries too, as cel-go's do: `strings`,
`lists`, `math`, `sets`, `encoders`, `regex`, `bindings`, `protos` and `two-var-comprehensions`.

## Topics

### Essentials

- <doc:EnablingExtensions>

### Libraries

- ``CEL/Library/strings``
- ``CEL/Library/strings(version:locale:maxPrecision:)``
- ``CEL/Library/lists``
- ``CEL/Library/lists(version:maxRangeSize:)``
- ``CEL/Library/math``
- ``CEL/Library/math(version:)``
- ``CEL/Library/sets``
- ``CEL/Library/sets(version:)``
- ``CEL/Library/encoders``
- ``CEL/Library/encoders(version:)``
- ``CEL/Library/network``
- ``CEL/Library/network(version:)``
- ``CEL/Library/regex``
- ``CEL/Library/regex(version:)``

### Macros and comprehensions

- ``CEL/Library/bindings``
- ``CEL/Library/bindings(version:)``
- ``CEL/Library/twoVarComprehensions``
- ``CEL/Library/twoVarComprehensions(version:)``
- ``CEL/Library/protos``
- ``CEL/Library/protos(version:)``
