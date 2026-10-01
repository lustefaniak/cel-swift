// Runs a tests.yaml suite with cel-go's celtest, configured like `cel-swift policy test`, so
// compare.sh can check that both report the same tests passing and failing.
//
//	go test -run TestCEL -v -args --cel_expr=... --test_suite_path=... --config_path=... \
//	  [--base_config_path=...] [--cel_go_test_fixtures] [--k8s_tags]
//
// The celtest flags are cel-go's own (tools/celtest/test_runner.go); the fixtures are the
// functions of policy/test/cel_test_runner.go, policy/helper_test.go and
// tools/celtest/test_runner_test.go and the proto3 / proto2 test messages, the same set
// CELCommandLine/CELGoTestFixtures.swift adds.
package celtestgo

import (
	"flag"
	"testing"

	"cel.dev/cel-go/cel"
	"cel.dev/cel-go/common/types"
	"cel.dev/cel-go/common/types/ref"
	"cel.dev/cel-go/common/types/traits"
	"cel.dev/cel-go/policy"
	"cel.dev/cel-go/tools/celtest"
	"cel.dev/cel-go/tools/compiler"

	proto2pb "cel.dev/cel-go/test/proto2pb"
	proto3pb "cel.dev/cel-go/test/proto3pb"
)

var (
	fixtures = flag.Bool("cel_go_test_fixtures", false, "add the cel-go test functions and message types")
	k8sTags  = flag.Bool("k8s_tags", false, "parse policies with the K8s test tag handler")
)

// TestCEL builds the compiler the way `cel-swift policy test` does: the test message types, then
// the base config and the config, then the functions. (celtest's own flag handling applies the
// configs before any other option, so a config could not refer to the test messages.)
func TestCEL(t *testing.T) {
	var opts []any
	if *fixtures {
		opts = append(opts, cel.Types(&proto3pb.TestAllTypes{}, &proto2pb.TestAllTypes{}))
	}
	for _, name := range []string{"base_config_path", "config_path"} {
		if path := flag.Lookup(name).Value.String(); path != "" {
			opts = append(opts, compiler.EnvironmentFile(path))
		}
	}
	if *fixtures {
		opts = append(opts,
			cel.Function("locationCode",
				cel.Overload("locationCode_string", []*cel.Type{cel.StringType}, cel.StringType,
					cel.UnaryBinding(locationCode))),
			cel.Function("fn",
				cel.Overload("fn_int", []*cel.Type{cel.IntType}, cel.IntType,
					cel.UnaryBinding(func(in ref.Val) ref.Val { return in.(types.Int) / types.Int(2) }))),
			cel.Function("hasCreditCard",
				cel.Overload("hasCreditCard", []*cel.Type{cel.DynType}, cel.BoolType,
					cel.UnaryBinding(func(arg ref.Val) ref.Val { return mapContains(arg, "cc") }))),
			cel.Function("hasEmailOrPhone",
				cel.Overload("hasEmailOrPhone", []*cel.Type{cel.DynType}, cel.BoolType,
					cel.UnaryBinding(func(arg ref.Val) ref.Val { return mapContains(arg, "email", "phone") }))),
		)
	}
	if *k8sTags {
		opts = append(opts, policy.ParserOption(func(p *policy.Parser) (*policy.Parser, error) {
			p.TagVisitor = policy.K8sTestTagHandler()
			return p, nil
		}))
	}
	celtest.TriggerTests(t,
		celtest.TestCompiler(opts...),
		celtest.TestSuite(flag.Lookup("test_suite_path").Value.String()),
		celtest.TestExpression(flag.Lookup("cel_expr").Value.String()),
		celtest.PartialEvalProgramOption())
}

func locationCode(ip ref.Val) ref.Val {
	switch ip.(types.String) {
	case "10.0.0.1":
		return types.String("us")
	case "10.0.0.2":
		return types.String("de")
	default:
		return types.String("ir")
	}
}

func mapContains(arg ref.Val, keys ...string) ref.Val {
	m, ok := arg.(traits.Mapper)
	if !ok {
		return types.False
	}
	for _, k := range keys {
		if m.Contains(types.String(k)) == types.True {
			return types.True
		}
	}
	return types.False
}
