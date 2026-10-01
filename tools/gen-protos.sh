#!/usr/bin/env bash
# Regenerates Sources/CELSpecProtos from the cel-spec protos in third_party/cel-spec.
#
# Versions used for the checked-in code (update when regenerating):
#   protoc            libprotoc 35.1 (Homebrew)
#   protoc-gen-swift  1.37.0, built from the swift-protobuf checkout SwiftPM resolved for this package
#                     (Package.swift pins swift-protobuf to 1.37.x: 1.38 needs Swift 6.1)
#   cel-spec          v0.25.3 (third_party/cel-spec submodule)
#
# The generated types are `package`-visible: shared by the conformance tests and, later, CELProtobuf, but never
# part of the public API. FileNaming=PathToUnderscores keeps proto2/ and proto3/ test_all_types apart.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

protoc="${PROTOC:-protoc}"
spec="third_party/cel-spec/proto"
out="Sources/CELSpecProtos"

swift package resolve
checkout=".build/checkouts/swift-protobuf"
build=(swift build -c release --package-path "$checkout" --scratch-path .build/protoc-gen-swift)
"${build[@]}" --product protoc-gen-swift
plugin="$("${build[@]}" --show-bin-path)/protoc-gen-swift"

protos=(
  cel/expr/syntax.proto
  cel/expr/checked.proto
  cel/expr/value.proto
  cel/expr/eval.proto
  cel/expr/explain.proto
  cel/expr/conformance/env_config.proto
  cel/expr/conformance/test/simple.proto
  cel/expr/conformance/test/suite.proto
  cel/expr/conformance/proto2/test_all_types.proto
  cel/expr/conformance/proto2/test_all_types_extensions.proto
  cel/expr/conformance/proto3/test_all_types.proto
)

find "$out" -name '*.pb.swift' -delete
"$protoc" \
  --plugin="protoc-gen-swift=$plugin" \
  --proto_path="$spec" \
  --swift_opt=Visibility=Package \
  --swift_opt=FileNaming=PathToUnderscores \
  --swift_out="$out" \
  "${protos[@]}"

echo "protoc: $("$protoc" --version)"
echo "protoc-gen-swift: $("$plugin" --version)"
