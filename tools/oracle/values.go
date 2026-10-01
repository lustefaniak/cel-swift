// Typed JSON encoding of CEL values; see README.md § Value encoding.

package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"sort"
	"strconv"
	"strings"
	"time"

	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/reflect/protoregistry"

	"cel.dev/cel-go/cel"
	"cel.dev/cel-go/common/types"
	"cel.dev/cel-go/common/types/ref"
	"cel.dev/cel-go/common/types/traits"
)

// jsonValue is the wire form of one CEL value: an object with exactly one key naming the kind.
type jsonValue = map[string]json.RawMessage

type mapEntry struct {
	Key   json.RawMessage `json:"key"`
	Value json.RawMessage `json:"value"`
}

type messageValue struct {
	Type  string          `json:"type"`
	Value json.RawMessage `json:"value"`
	// Binary is the deterministic wire format, base64: it keeps what proto JSON cannot carry into
	// another implementation, such as an undeclared number in a proto2 (closed) enum field.
	Binary string `json:"binary,omitempty"`
}

func marshal(v any) json.RawMessage {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		panic(err)
	}
	return json.RawMessage(bytes.TrimRight(buf.Bytes(), "\n"))
}

func one(kind string, payload any) json.RawMessage {
	return marshal(map[string]json.RawMessage{kind: marshal(payload)})
}

// encodeDouble writes finite non-negative-zero doubles as JSON numbers and everything else as strings.
func encodeDouble(f float64) any {
	switch {
	case math.IsNaN(f):
		return "NaN"
	case math.IsInf(f, 1):
		return "Infinity"
	case math.IsInf(f, -1):
		return "-Infinity"
	case f == 0 && math.Signbit(f):
		return "-0"
	}
	return json.Number(strconv.FormatFloat(f, 'g', -1, 64))
}

// formatDuration renders a duration as protobuf JSON does: seconds with 0, 3, 6 or 9 fractional digits and an "s".
func formatDuration(d time.Duration) string {
	sign := ""
	if d < 0 {
		sign = "-"
	}
	secs := int64(d / time.Second)
	nanos := int64(d % time.Second)
	if secs < 0 {
		secs = -secs
	}
	if nanos < 0 {
		nanos = -nanos
	}
	s := sign + strconv.FormatInt(secs, 10)
	switch {
	case nanos == 0:
	case nanos%1_000_000 == 0:
		s += fmt.Sprintf(".%03d", nanos/1_000_000)
	case nanos%1_000 == 0:
		s += fmt.Sprintf(".%06d", nanos/1_000)
	default:
		s += fmt.Sprintf(".%09d", nanos)
	}
	return s + "s"
}

func parseDuration(s string) (time.Duration, error) {
	if !strings.HasSuffix(s, "s") {
		return 0, fmt.Errorf("duration %q must end in 's'", s)
	}
	body := strings.TrimSuffix(s, "s")
	neg := strings.HasPrefix(body, "-")
	body = strings.TrimPrefix(body, "-")
	intPart, frac, _ := strings.Cut(body, ".")
	secs, err := strconv.ParseInt(intPart, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("invalid duration %q: %w", s, err)
	}
	var nanos int64
	if frac != "" {
		if len(frac) > 9 {
			return 0, fmt.Errorf("invalid duration %q: more than 9 fractional digits", s)
		}
		frac += strings.Repeat("0", 9-len(frac))
		nanos, err = strconv.ParseInt(frac, 10, 64)
		if err != nil {
			return 0, fmt.Errorf("invalid duration %q: %w", s, err)
		}
	}
	// cel-go durations are Go time.Durations: int64 nanoseconds.
	if secs > math.MaxInt64/int64(time.Second) {
		return 0, fmt.Errorf("duration %q out of range", s)
	}
	d := time.Duration(secs)*time.Second + time.Duration(nanos)
	if d < 0 {
		return 0, fmt.Errorf("duration %q out of range", s)
	}
	if neg {
		d = -d
	}
	return d, nil
}

// encodeValue converts a CEL runtime value to its typed JSON form.
func encodeValue(v ref.Val) (json.RawMessage, error) {
	switch val := v.(type) {
	case types.Null:
		return marshal(map[string]any{"null": nil}), nil
	case types.Bool:
		return one("bool", bool(val)), nil
	case types.Int:
		return one("int", strconv.FormatInt(int64(val), 10)), nil
	case types.Uint:
		return one("uint", strconv.FormatUint(uint64(val), 10)), nil
	case types.Double:
		return one("double", encodeDouble(float64(val))), nil
	case types.String:
		return one("string", string(val)), nil
	case types.Bytes:
		return one("bytes", base64.StdEncoding.EncodeToString([]byte(val))), nil
	case types.Duration:
		return one("duration", formatDuration(val.Duration)), nil
	case types.Timestamp:
		return one("timestamp", val.Time.UTC().Format(time.RFC3339Nano)), nil
	case *types.Type:
		return one("type", val.TypeName()), nil
	case *types.Optional:
		if !val.HasValue() {
			return marshal(map[string]any{"optional": nil}), nil
		}
		inner, err := encodeValue(val.GetValue())
		if err != nil {
			return nil, err
		}
		return marshal(map[string]json.RawMessage{"optional": inner}), nil
	case *types.Err:
		return nil, fmt.Errorf("cannot encode error value: %v", val)
	case *types.Unknown:
		return nil, fmt.Errorf("cannot encode unknown value: %v", val)
	case traits.Mapper:
		entries := []mapEntry{}
		it := val.Iterator()
		for it.HasNext() == types.True {
			k := it.Next()
			ek, err := encodeValue(k)
			if err != nil {
				return nil, err
			}
			ev, err := encodeValue(val.Get(k))
			if err != nil {
				return nil, err
			}
			entries = append(entries, mapEntry{Key: ek, Value: ev})
		}
		sort.Slice(entries, func(i, j int) bool { return string(entries[i].Key) < string(entries[j].Key) })
		return marshal(map[string]any{"map": entries}), nil
	case traits.Lister:
		elems := []json.RawMessage{}
		it := val.Iterator()
		for it.HasNext() == types.True {
			e, err := encodeValue(it.Next())
			if err != nil {
				return nil, err
			}
			elems = append(elems, e)
		}
		return marshal(map[string]any{"list": elems}), nil
	}
	if msg, ok := v.Value().(proto.Message); ok {
		b, err := protojson.MarshalOptions{UseProtoNames: true}.Marshal(msg)
		if err != nil {
			return nil, err
		}
		wire, err := proto.MarshalOptions{Deterministic: true, AllowPartial: true}.Marshal(msg)
		if err != nil {
			return nil, err
		}
		return marshal(map[string]any{"message": messageValue{
			Type:   string(msg.ProtoReflect().Descriptor().FullName()),
			Value:  compactJSON(b),
			Binary: base64.StdEncoding.EncodeToString(wire),
		}}), nil
	}
	return nil, fmt.Errorf("unsupported value type %T (%v)", v, v.Type())
}

func compactJSON(b []byte) json.RawMessage {
	var buf bytes.Buffer
	if err := json.Compact(&buf, b); err != nil {
		return json.RawMessage(b)
	}
	return json.RawMessage(buf.Bytes())
}

// decodeValue converts a typed JSON value into a CEL runtime value.
func decodeValue(env *cel.Env, raw json.RawMessage) (ref.Val, error) {
	var obj jsonValue
	if err := json.Unmarshal(raw, &obj); err != nil {
		return nil, fmt.Errorf("value must be a JSON object: %w", err)
	}
	if len(obj) != 1 {
		return nil, fmt.Errorf("value must have exactly one key, got %d: %s", len(obj), raw)
	}
	adapter := env.CELTypeAdapter()
	for kind, payload := range obj {
		switch kind {
		case "null":
			return types.NullValue, nil
		case "bool":
			var b bool
			if err := json.Unmarshal(payload, &b); err != nil {
				return nil, err
			}
			return types.Bool(b), nil
		case "int":
			s, err := numberString(payload)
			if err != nil {
				return nil, err
			}
			i, err := strconv.ParseInt(s, 10, 64)
			if err != nil {
				return nil, err
			}
			return types.Int(i), nil
		case "uint":
			s, err := numberString(payload)
			if err != nil {
				return nil, err
			}
			u, err := strconv.ParseUint(s, 10, 64)
			if err != nil {
				return nil, err
			}
			return types.Uint(u), nil
		case "double":
			s, err := numberString(payload)
			if err != nil {
				return nil, err
			}
			switch s {
			case "NaN":
				return types.Double(math.NaN()), nil
			case "Infinity":
				return types.Double(math.Inf(1)), nil
			case "-Infinity":
				return types.Double(math.Inf(-1)), nil
			}
			f, err := strconv.ParseFloat(s, 64)
			if err != nil {
				return nil, err
			}
			return types.Double(f), nil
		case "string":
			var s string
			if err := json.Unmarshal(payload, &s); err != nil {
				return nil, err
			}
			return types.String(s), nil
		case "bytes":
			var s string
			if err := json.Unmarshal(payload, &s); err != nil {
				return nil, err
			}
			b, err := base64.StdEncoding.DecodeString(s)
			if err != nil {
				return nil, err
			}
			return types.Bytes(b), nil
		case "duration":
			var s string
			if err := json.Unmarshal(payload, &s); err != nil {
				return nil, err
			}
			d, err := parseDuration(s)
			if err != nil {
				return nil, err
			}
			return types.Duration{Duration: d}, nil
		case "timestamp":
			var s string
			if err := json.Unmarshal(payload, &s); err != nil {
				return nil, err
			}
			t, err := time.Parse(time.RFC3339Nano, s)
			if err != nil {
				return nil, err
			}
			return types.Timestamp{Time: t.UTC()}, nil
		case "type":
			var s string
			if err := json.Unmarshal(payload, &s); err != nil {
				return nil, err
			}
			if t, found := env.CELTypeProvider().FindIdent(s); found {
				if tv, ok := t.(*types.Type); ok {
					return tv, nil
				}
			}
			return nil, fmt.Errorf("unknown type name %q", s)
		case "optional":
			if string(payload) == "null" {
				return types.OptionalNone, nil
			}
			inner, err := decodeValue(env, payload)
			if err != nil {
				return nil, err
			}
			return types.OptionalOf(inner), nil
		case "list":
			var elems []json.RawMessage
			if err := json.Unmarshal(payload, &elems); err != nil {
				return nil, err
			}
			out := make([]ref.Val, 0, len(elems))
			for _, e := range elems {
				v, err := decodeValue(env, e)
				if err != nil {
					return nil, err
				}
				out = append(out, v)
			}
			return types.NewRefValList(adapter, out), nil
		case "map":
			var entries []mapEntry
			if err := json.Unmarshal(payload, &entries); err != nil {
				return nil, err
			}
			out := make(map[ref.Val]ref.Val, len(entries))
			for _, e := range entries {
				k, err := decodeValue(env, e.Key)
				if err != nil {
					return nil, err
				}
				v, err := decodeValue(env, e.Value)
				if err != nil {
					return nil, err
				}
				out[k] = v
			}
			return types.NewRefValMap(adapter, out), nil
		case "message":
			var m messageValue
			if err := json.Unmarshal(payload, &m); err != nil {
				return nil, err
			}
			mt, err := protoregistry.GlobalTypes.FindMessageByName(protoreflect.FullName(m.Type))
			if err != nil {
				return nil, fmt.Errorf("unknown message type %q: %w", m.Type, err)
			}
			msg := mt.New().Interface()
			body := m.Value
			if len(body) == 0 {
				body = json.RawMessage("{}")
			}
			if err := protojson.Unmarshal(body, msg); err != nil {
				return nil, err
			}
			return adapter.NativeToValue(msg), nil
		default:
			return nil, fmt.Errorf("unknown value kind %q", kind)
		}
	}
	return nil, errors.New("unreachable")
}

// numberString accepts either a JSON string or a JSON number and returns its text.
func numberString(payload json.RawMessage) (string, error) {
	var s string
	if err := json.Unmarshal(payload, &s); err == nil {
		return s, nil
	}
	var n json.Number
	dec := json.NewDecoder(bytes.NewReader(payload))
	dec.UseNumber()
	if err := dec.Decode(&n); err != nil {
		return "", fmt.Errorf("expected a number or a string, got %s", payload)
	}
	return n.String(), nil
}
