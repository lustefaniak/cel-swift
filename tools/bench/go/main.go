// Command bench times parse, check, plan and eval of the expressions in ../cases.json with cel-go, using the same
// method as the Swift driver (Benchmarks/CELBenchmarks): calibrate the iteration count to a round of about
// -round-ms, run -rounds rounds and report the time per operation of the fastest round. Output is one
// tab-separated line per case and phase: name, phase, ns/op, allocs/op (allocs only here; Swift has no portable
// counter).
//
//	go run . [-cases ../cases.json] [-rounds 5] [-round-ms 100] [-filter name]
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"runtime"
	"time"

	"cel.dev/cel-go/cel"
	"cel.dev/cel-go/ext"
	"cel.dev/cel-go/interpreter"
)

type benchCase struct {
	Name      string            `json:"name"`
	Expr      string            `json:"expr"`
	Variables map[string]string `json:"variables"`
	Bindings  map[string]string `json:"bindings"`
}

var (
	casesPath = flag.String("cases", "../cases.json", "benchmark cases")
	rounds    = flag.Int("rounds", 5, "measured rounds per phase")
	roundMs   = flag.Int("round-ms", 100, "target duration of one round in milliseconds")
	filter    = flag.String("filter", "", "run only the case with this name")
)

func celType(name string) *cel.Type {
	switch name {
	case "int":
		return cel.IntType
	case "string":
		return cel.StringType
	case "dyn":
		return cel.DynType
	case "list(int)":
		return cel.ListType(cel.IntType)
	case "map(string, dyn)":
		return cel.MapType(cel.StringType, cel.DynType)
	}
	panic("unknown type " + name)
}

// measure returns the nanoseconds and allocations per call of f in the fastest round, the one least disturbed by
// other load on the machine.
func measure(f func()) (float64, float64) {
	target := time.Duration(*roundMs) * time.Millisecond
	n := 1
	for {
		start := time.Now()
		for i := 0; i < n; i++ {
			f()
		}
		elapsed := time.Since(start)
		if elapsed >= target/10 {
			n = int(float64(n) * float64(target) / float64(elapsed))
			if n < 1 {
				n = 1
			}
			break
		}
		n *= 2
	}
	var nsPerOp, allocsPerOp []float64
	var ms runtime.MemStats
	for r := 0; r < *rounds; r++ {
		runtime.ReadMemStats(&ms)
		mallocs := ms.Mallocs
		start := time.Now()
		for i := 0; i < n; i++ {
			f()
		}
		elapsed := time.Since(start)
		runtime.ReadMemStats(&ms)
		nsPerOp = append(nsPerOp, float64(elapsed.Nanoseconds())/float64(n))
		allocsPerOp = append(allocsPerOp, float64(ms.Mallocs-mallocs)/float64(n))
	}
	best := 0
	for i := range nsPerOp {
		if nsPerOp[i] < nsPerOp[best] {
			best = i
		}
	}
	return nsPerOp[best], allocsPerOp[best]
}

func must[T any](v T, err error) T {
	if err != nil {
		fmt.Fprintln(os.Stderr, "bench:", err)
		os.Exit(1)
	}
	return v
}

func check(iss *cel.Issues) {
	if iss != nil && iss.Err() != nil {
		fmt.Fprintln(os.Stderr, "bench:", iss.Err())
		os.Exit(1)
	}
}

func main() {
	flag.Parse()
	var cases []benchCase
	if err := json.Unmarshal(must(os.ReadFile(*casesPath)), &cases); err != nil {
		fmt.Fprintln(os.Stderr, "bench:", err)
		os.Exit(1)
	}
	bindingEnv := must(cel.NewEnv(ext.Lists()))
	for _, c := range cases {
		if *filter != "" && c.Name != *filter {
			continue
		}
		opts := []cel.EnvOption{}
		for name, t := range c.Variables {
			opts = append(opts, cel.Variable(name, celType(t)))
		}
		env := must(cel.NewEnv(opts...))
		bindings := map[string]any{}
		for name, expr := range c.Bindings {
			ast, iss := bindingEnv.Compile(expr)
			check(iss)
			out, _, err := must(bindingEnv.Program(ast)).Eval(interpreter.EmptyActivation())
			if err != nil {
				fmt.Fprintln(os.Stderr, "bench:", c.Name, name, err)
				os.Exit(1)
			}
			bindings[name] = out
		}
		activation := must(interpreter.NewActivation(bindings))

		parsed, iss := env.Parse(c.Expr)
		check(iss)
		checked, iss := env.Check(parsed)
		check(iss)
		program := must(env.Program(checked))
		if out, _, err := program.Eval(activation); err != nil || out.Value() != true {
			fmt.Fprintln(os.Stderr, "bench:", c.Name, "unexpected result", out, err)
			os.Exit(1)
		}

		report := func(phase string, f func()) {
			ns, allocs := measure(f)
			fmt.Printf("%s\t%s\t%.1f\t%.1f\n", c.Name, phase, ns, allocs)
		}
		report("parse", func() { _, iss := env.Parse(c.Expr); check(iss) })
		report("check", func() { _, iss := env.Check(parsed); check(iss) })
		report("plan", func() { must(env.Program(checked)) })
		report("eval", func() { _, _, _ = program.Eval(activation) })
	}
}
