// Command oracle answers CEL parse / check / eval requests with cel-go, one JSON object per line on stdin and
// stdout. It is the reference the cel-swift differential tests compare against; see README.md for the protocol.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"runtime/debug"
)

func main() {
	if err := serve(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "oracle:", err)
		os.Exit(1)
	}
}

// serve reads one request per line and writes one response per line, flushing after each so the oracle can be
// driven interactively over a pipe.
func serve(in io.Reader, out io.Writer) error {
	sc := bufio.NewScanner(in)
	sc.Buffer(make([]byte, 0, 1<<20), 64<<20)
	w := bufio.NewWriter(out)
	for sc.Scan() {
		line := sc.Bytes()
		if len(line) == 0 {
			continue
		}
		resp := handleLine(line)
		if _, err := w.Write(marshal(resp)); err != nil {
			return err
		}
		if err := w.WriteByte('\n'); err != nil {
			return err
		}
		if err := w.Flush(); err != nil {
			return err
		}
	}
	return sc.Err()
}

func handleLine(line []byte) (resp *response) {
	var req request
	if err := json.Unmarshal(line, &req); err != nil {
		return &response{OracleError: fmt.Sprintf("invalid request: %v", err)}
	}
	defer func() {
		if r := recover(); r != nil {
			resp = &response{ID: req.ID, Kind: req.Kind, OracleError: fmt.Sprintf("panic: %v\n%s", r, debug.Stack())}
		}
	}()
	return handle(&req)
}
