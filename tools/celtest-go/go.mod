module github.com/lustefaniak/cel-swift/tools/celtest-go

go 1.23.0

require (
	cel.dev/cel-go v0.32.0
	cel.dev/cel-go/policy v0.0.0
	cel.dev/cel-go/tools v0.0.0
)

require (
	cel.dev/expr v0.25.1 // indirect
	github.com/antlr4-go/antlr/v4 v4.13.1 // indirect
	github.com/google/go-cmp v0.7.0 // indirect
	go.yaml.in/yaml/v3 v3.0.4 // indirect
	golang.org/x/exp v0.0.0-20240823005443-9b4947da3948 // indirect
	golang.org/x/text v0.22.0 // indirect
	google.golang.org/genproto/googleapis/api v0.0.0-20250311190419-81fb87f6b8bf // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20250311190419-81fb87f6b8bf // indirect
	google.golang.org/protobuf v1.36.10 // indirect
)

replace (
	cel.dev/cel-go => ../../third_party/cel-go
	cel.dev/cel-go/policy => ../../third_party/cel-go/policy
	cel.dev/cel-go/tools => ../../third_party/cel-go/tools
)
