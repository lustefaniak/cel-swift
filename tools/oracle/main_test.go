package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"os"
	"strings"
	"testing"
)

var update = flag.Bool("update", false, "rewrite testdata/smoke.golden.jsonl")

// TestSmoke runs every request in testdata/smoke.jsonl and compares the responses with the golden file.
func TestSmoke(t *testing.T) {
	in, err := os.ReadFile("testdata/smoke.jsonl")
	if err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	if err := serve(bytes.NewReader(in), &out); err != nil {
		t.Fatal(err)
	}
	const golden = "testdata/smoke.golden.jsonl"
	if *update {
		if err := os.WriteFile(golden, out.Bytes(), 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	want, err := os.ReadFile(golden)
	if err != nil {
		t.Fatal(err)
	}
	gotLines := strings.Split(strings.TrimSpace(out.String()), "\n")
	wantLines := strings.Split(strings.TrimSpace(string(want)), "\n")
	if len(gotLines) != len(wantLines) {
		t.Fatalf("got %d responses, want %d", len(gotLines), len(wantLines))
	}
	for i := range gotLines {
		if gotLines[i] != wantLines[i] {
			t.Errorf("response %d differs (run go test -update to accept)\n got: %s\nwant: %s", i, gotLines[i], wantLines[i])
		}
	}
}

func run(t *testing.T, req string) map[string]any {
	t.Helper()
	var out bytes.Buffer
	if err := serve(strings.NewReader(req+"\n"), &out); err != nil {
		t.Fatal(err)
	}
	var resp map[string]any
	if err := json.Unmarshal(out.Bytes(), &resp); err != nil {
		t.Fatalf("invalid response %q: %v", out.String(), err)
	}
	return resp
}

// TestValueRoundTrip feeds encoded values back in as bindings and checks they come out unchanged.
func TestValueRoundTrip(t *testing.T) {
	values := []string{
		`{"null":null}`,
		`{"bool":true}`,
		`{"int":"-9223372036854775808"}`,
		`{"uint":"18446744073709551615"}`,
		`{"double":1.5}`,
		`{"double":"NaN"}`,
		`{"double":"-Infinity"}`,
		`{"double":"-0"}`,
		`{"double":1e+300}`,
		`{"string":"a\"b\u0000é"}`,
		`{"bytes":"AP8="}`,
		`{"duration":"-1.000000001s"}`,
		`{"duration":"9223372036.854775807s"}`,
		`{"timestamp":"0001-01-01T00:00:00Z"}`,
		`{"timestamp":"9999-12-31T23:59:59.999999999Z"}`,
		`{"type":"list"}`,
		`{"type":"google.protobuf.Timestamp"}`,
		`{"optional":null}`,
		`{"optional":{"list":[]}}`,
		`{"list":[{"int":"1"},{"string":"x"}]}`,
		`{"map":[{"key":{"bool":false},"value":{"int":"1"}},{"key":{"int":"1"},"value":{"uint":"2"}},{"key":{"string":"k"},"value":{"null":null}},{"key":{"uint":"3"},"value":{"double":2}}]}`,
		`{"message":{"binary":"CAU=","type":"cel.expr.conformance.proto3.TestAllTypes","value":{"single_int32":5}}}`,
	}
	for _, v := range values {
		resp := run(t, `{"kind":"eval","expr":"x","check":false,"test_types":true,"config":{"extensions":[{"name":"optional"}]},"bindings":{"x":`+v+`}}`)
		result, _ := resp["result"].(map[string]any)
		if result == nil {
			t.Errorf("%s: no result: %v", v, resp)
			continue
		}
		got, _ := json.Marshal(result["value"])
		var wantNorm any
		_ = json.Unmarshal([]byte(v), &wantNorm)
		want, _ := json.Marshal(wantNorm)
		if string(got) != string(want) {
			t.Errorf("round trip of %s: got %s", v, got)
		}
	}
}
