#!/usr/bin/env bash
# Regenerates Sources/CELSpecProtos from the cel-spec protos in third_party/cel-spec, the CEL adapters
# (protoc-gen-cel-swift, *.cel.swift) for them, for the well-known types in Sources/CELProtobuf/WellKnownTypes,
# and cel-go's test protos (third_party/cel-go/test/proto{2,3}pb) into Sources/CELGoTestProtos.
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

swift build -c release --product protoc-gen-cel-swift
celplugin="$(swift build -c release --show-bin-path)/protoc-gen-cel-swift"

find "$out" -name '*.pb.swift' -delete
find "$out" -name '*.cel.swift' -delete
"$protoc" \
  --plugin="protoc-gen-swift=$plugin" \
  --proto_path="$spec" \
  --swift_opt=Visibility=Package \
  --swift_opt=FileNaming=PathToUnderscores \
  --swift_out="$out" \
  "${protos[@]}"
# CEL adapters only for the messages conformance tests evaluate.
"$protoc" \
  --plugin="protoc-gen-cel-swift=$celplugin" \
  --proto_path="$spec" \
  --cel-swift_opt=Visibility=Package \
  --cel-swift_opt=FileNaming=PathToUnderscores \
  --cel-swift_out="$out" \
  cel/expr/conformance/proto2/test_all_types.proto \
  cel/expr/conformance/proto2/test_all_types_extensions.proto \
  cel/expr/conformance/proto3/test_all_types.proto

# Well-known types: the messages live in SwiftProtobuf, the adapters in CELProtobuf. protoc finds these
# files on its built-in include path.
wkt_out="Sources/CELProtobuf/WellKnownTypes"
mkdir -p "$wkt_out"
find "$wkt_out" -name '*.cel.swift' -delete
"$protoc" \
  --plugin="protoc-gen-cel-swift=$celplugin" \
  --cel-swift_opt=RuntimeModule=None \
  --cel-swift_opt=FileNaming=DropPath \
  --cel-swift_out="$wkt_out" \
  google/protobuf/any.proto google/protobuf/duration.proto google/protobuf/empty.proto \
  google/protobuf/field_mask.proto google/protobuf/struct.proto google/protobuf/timestamp.proto \
  google/protobuf/wrappers.proto

# cel-go's own test protos, for porting cel-go tests that use them.
gotest="third_party/cel-go"
gotest_out="Sources/CELGoTestProtos"
find "$gotest_out" -name '*.pb.swift' -delete
find "$gotest_out" -name '*.cel.swift' -delete
"$protoc" \
  --plugin="protoc-gen-swift=$plugin" \
  --plugin="protoc-gen-cel-swift=$celplugin" \
  --proto_path="$gotest" \
  --swift_opt=Visibility=Package \
  --swift_opt=FileNaming=PathToUnderscores \
  --swift_out="$gotest_out" \
  --cel-swift_opt=Visibility=Package \
  --cel-swift_opt=FileNaming=PathToUnderscores \
  --cel-swift_out="$gotest_out" \
  test/proto2pb/test_all_types.proto test/proto2pb/test_extensions.proto \
  test/proto3pb/test_all_types.proto test/proto3pb/test_import.proto

echo "protoc: $("$protoc" --version)"
echo "protoc-gen-swift: $("$plugin" --version)"
