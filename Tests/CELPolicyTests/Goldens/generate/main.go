// Command generate dumps what go-yaml and cel-go's policy parser produce for a set of YAML files,
// in the text format DifferentialTests.swift reproduces with the Swift port.
//
// Usage: generate <yaml|policy> <file>...
//
// Run gen.sh from any directory to refresh the golden files.
package main

import (
	"fmt"
	"os"
	"strings"

	"cel.dev/cel-go/policy"
	"go.yaml.in/yaml/v3"
)

func dumpNode(n *yaml.Node, depth int) {
	ind := strings.Repeat("  ", depth)
	fmt.Printf("%skind=%d tag=%s style=%d line=%d col=%d value=%q\n", ind, n.Kind, n.LongTag(), n.Style, n.Line, n.Column, n.Value)
	for _, c := range n.Content {
		dumpNode(c, depth+1)
	}
}

type dumper struct{ p *policy.Policy }

func (d dumper) vs(label string, v policy.ValueString) {
	loc := d.p.SourceInfo().GetStartLocation(v.ID)
	off, _ := d.p.SourceInfo().GetOffsetRange(v.ID)
	fmt.Printf("%s id=%d loc=%d:%d off=%d value=%q\n", label, v.ID, loc.Line(), loc.Column(), off.Start, v.Value)
}

func (d dumper) rule(prefix string, r *policy.Rule) {
	if r == nil {
		return
	}
	loc := d.p.SourceInfo().GetStartLocation(r.SourceID())
	fmt.Printf("%srule id=%d loc=%d:%d\n", prefix, r.SourceID(), loc.Line(), loc.Column())
	d.vs(prefix+"rule.id", r.ID())
	d.vs(prefix+"rule.description", r.Description())
	for _, v := range r.Variables() {
		d.vs(prefix+"var.name", v.Name())
		d.vs(prefix+"var.expr", v.Expression())
	}
	for _, m := range r.Matches() {
		loc := d.p.SourceInfo().GetStartLocation(m.SourceID())
		fmt.Printf("%smatch id=%d loc=%d:%d\n", prefix, m.SourceID(), loc.Line(), loc.Column())
		d.vs(prefix+"match.cond", m.Condition())
		if m.HasOutput() {
			d.vs(prefix+"match.output", m.Output())
		}
		if m.HasExplanation() {
			d.vs(prefix+"match.explanation", m.Explanation())
		}
		if m.HasRule() {
			d.rule(prefix+"  ", m.Rule())
		}
	}
}

func main() {
	mode := os.Args[1]
	for _, f := range os.Args[2:] {
		b, err := os.ReadFile(f)
		if err != nil {
			panic(err)
		}
		fmt.Printf("=== %s\n", f)
		switch mode {
		case "yaml":
			var n yaml.Node
			if err := yaml.Unmarshal(b, &n); err != nil {
				fmt.Printf("error: %v\n", err)
				continue
			}
			dumpNode(&n, 0)
		case "policy":
			var opts []policy.ParserOption
			if strings.Contains(f, "/k8s/") {
				opts = append(opts, policy.CustomTagVisitor(policy.K8sTestTagHandler()))
			}
			parser, _ := policy.NewParser(opts...)
			p, iss := parser.Parse(policy.ByteSource(b, f))
			if iss != nil && iss.Err() != nil {
				fmt.Println(iss.Err().Error())
				continue
			}
			d := dumper{p}
			d.vs("name", p.Name())
			d.vs("description", p.Description())
			for _, imp := range p.Imports() {
				d.vs("import", imp.Name())
			}
			d.rule("", p.Rule())
		}
	}
}
