# Enabling extension libraries

Add the libraries expressions need, pin their versions when expressions are stored, and bound the
work the expensive functions may do.

## Overview

An environment only offers the functions it declares. Expressions that call an extension function
without its library fail to compile with an `undeclared reference`, so the libraries you add define
the language your users write in: add the ones they need and nothing more.

### Add libraries

Pass each library as an environment option. Some libraries depend on core features: `regex.extract`
returns an optional value, so the regex library needs optional types, enabled before it:

```swift
import CEL
import CELExtensions

let env = try Environment(
  .variable("path", .string),
  .library(.strings),
  .optionalTypes,
  .library(.regex)
)
let checked = try env.compile("regex.extract(path, '/users/([0-9]+)').orValue('none')")
let result = try env.program(checked).evaluate(["path": "/users/42/posts"])
print(result.value)   // "42"
```

The network library adds the `ip` and `cidr` types, compatible with the Kubernetes CEL library:

```swift
let net = try Environment(.library(.network))
let inRange = try net.program(net.compile("cidr('10.0.0.0/8').containsIP(ip('10.1.2.3'))"))
print(try inRange.evaluate().value)   // true
```

### Pin versions for stored expressions

A library without a version, such as ``CEL/Library/math``, is at its latest version, which grows as
cel-go adds functions. When expressions are stored and must keep compiling the same way, pin the
version they were written against. A pinned library declares only what its version had:

```swift
let pinned = try Environment(.library(.math(version: 0)))
_ = try pinned.compile("math.least(3, 1, 2)")   // version 0 has math.least
do {
  _ = try pinned.compile("math.sqrt(4.0)")       // added in version 2
} catch {
  print(error)
  // ERROR: <input>:1:1: undeclared reference to 'math' (in container '')
  //  | math.sqrt(4.0)
  //  | ^
  // ...
}
```

The documentation of each versioned factory, such as ``CEL/Library/math(version:)``, lists what its
versions add.

### Bound expensive functions

Most extension functions cost what their arguments' sizes say, and the estimated and runtime costs
(`Environment.estimateCost`, `Program.Option.costLimit`) account for them as cel-go does. Two
libraries take explicit limits as well: ``CEL/Library/lists(version:maxRangeSize:)`` caps the size of
`lists.range(n)`, and ``CEL/Library/strings(version:locale:maxPrecision:)`` caps the precision of a
`format` clause:

```swift
let bounded = try Environment(.library(.lists(maxRangeSize: 1000)))
let range = try bounded.program(bounded.compile("lists.range(5000).size()"))
do {
  _ = try range.evaluate()
} catch {
  print(error)   // lists.range: size 5000 exceeds maximum allowed (1000)
}
```
