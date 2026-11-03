package store

import (
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"slices"
	"strings"
	"testing"

	sdk "github.com/Kadxy/rendu/internal/schema"
)

func TestKindExamplesValidate(t *testing.T) {
	for _, k := range Kinds() {
		if !k.Write {
			// An object as read: every field of it is in the table.
			if k.Example == nil {
				continue
			}
			f, ok := objectOf(k.Example)
			if !ok {
				t.Errorf("%s: example is not an object", k.Kind)
				continue
			}
			if err := checkKnown(f, k.Fields, "example", k.Kind, true); err != nil {
				t.Errorf("%s: %v", k.Kind, err)
			}
			continue
		}
		if err := validateObject(k.Example, "example", topLevel); err != nil {
			t.Errorf("%s: %v", k.Kind, err)
		}
		for typ, ex := range k.typeExamples {
			if err := validateObject(ex, "example", topLevel); err != nil {
				t.Errorf("%s (%s): %v", k.Kind, typ, err)
			}
		}
	}

	// Examples for one type, as GET /v1/schema/types/{type} gives them.
	rem := int64(5)
	for _, c := range []struct {
		kind, typ string
		hints     ExampleHints
	}{
		{"quantity", "HKQuantityTypeIdentifierStepCount", ExampleHints{Unit: "count", Cumulative: true}},
		{"quantity", "HKQuantityTypeIdentifierBodyFatPercentage", ExampleHints{Unit: "%"}},
		{"category", "HKCategoryTypeIdentifierSleepAnalysis", ExampleHints{Value: &rem}},
		{"correlation", "HKCorrelationTypeIdentifierBloodPressure", ExampleHints{}},
		{"scoredAssessment", phq9Type, ExampleHints{}},
		{"workout", workoutType, ExampleHints{}},
	} {
		k, _ := LookupKind(c.kind)
		ex := k.ExampleFor(c.typ, c.hints)
		if err := validateObject(ex, "example", topLevel); err != nil {
			t.Errorf("%s: %v (%s)", c.typ, err, ex)
		}
		var o map[string]any
		_ = json.Unmarshal(ex, &o)
		if o["type"] != c.typ {
			t.Errorf("%s: example of type %v", c.typ, o["type"])
		}
		if c.hints.Unit != "" && o["quantity"].(map[string]any)["unit"] != c.hints.Unit {
			t.Errorf("%s: example %s", c.typ, ex)
		}
		if c.hints.Cumulative && o["startDate"] == o["endDate"] {
			t.Errorf("%s: a cumulative example covers an interval: %s", c.typ, ex)
		}
		if c.hints.Value != nil && o["value"] != 5.0 {
			t.Errorf("%s: example %s", c.typ, ex)
		}
	}
}

// fill builds an object with every field of the table, at every depth;
// only the writable ones when writable.
func fill(specs []Field, writable bool) obj {
	o := obj{}
	for _, f := range specs {
		if !writable || !f.ReadOnly {
			o[f.Name] = filler(f, writable)
		}
	}
	return o
}

func filler(f Field, writable bool) any {
	switch f.Type {
	case TypeTimestamp:
		return t0
	case TypeQuantity:
		return qty(1, "count")
	case TypeInteger:
		if f.Enum != "" {
			e, _ := sdk.LookupEnum(f.Enum)
			return e.Cases[0].Value
		}
		return 1
	case TypeNumber:
		return 0.5
	case TypeBoolean:
		return true
	case TypeObject:
		return fill(f.Fields, writable)
	case TypeArray:
		switch {
		case f.ItemKind != "":
			k, _ := LookupKind(f.ItemKind)
			member := fill(k.Fields, writable)
			member["kind"] = f.ItemKind
			return []any{member}
		case f.Items == TypeObject:
			return []any{fill(f.Fields, writable)}
		default:
			return []any{filler(Field{Type: f.Items, Enum: f.Enum}, writable)}
		}
	}
	return "x"
}

// spots are the paths to every object (and quantity) a writer fills in.
func spots(specs []Field, prefix []any) [][]any {
	var out [][]any
	for _, f := range specs {
		if f.ReadOnly {
			continue
		}
		path := append(append([]any{}, prefix...), f.Name)
		switch {
		case f.Type == TypeQuantity:
			out = append(out, path)
		case f.Type == TypeObject && f.Fields != nil:
			out = append(out, path)
			out = append(out, spots(f.Fields, path)...)
		case f.Type == TypeArray && f.ItemKind != "":
			k, _ := LookupKind(f.ItemKind)
			item := append(slices.Clone(path), 0)
			out = append(out, item)
			out = append(out, spots(k.Fields, item)...)
		case f.Type == TypeArray && f.Items == TypeObject:
			item := append(slices.Clone(path), 0)
			out = append(out, item)
			out = append(out, spots(f.Fields, item)...)
		}
	}
	return out
}

func pathString(path []any) string {
	s := "object"
	for _, p := range path {
		switch p := p.(type) {
		case string:
			s += "." + p
		case int:
			s += fmt.Sprintf("[%d]", p)
		}
	}
	return s
}

// The table's fields are exactly what validation accepts: an object with
// every one of them has no unknown field, and anything else is refused
// wherever it is.
func TestFieldsAreWhatValidationAccepts(t *testing.T) {
	typos := 0
	for _, k := range Kinds() {
		if k.Fields == nil {
			continue
		}
		// Every field, read-only ones included, is known.
		full := fill(k.Fields, false)
		raw, _ := json.Marshal(full)
		f, _ := objectOf(raw)
		if err := checkKnown(f, k.Fields, "object", k.Kind, true); err != nil {
			t.Errorf("%s with every field: %v", k.Kind, err)
		}
		if !k.Write {
			continue
		}
		writable := func() obj {
			o := fill(k.Fields, true)
			o["kind"] = k.Kind
			var ex obj
			_ = json.Unmarshal(k.Example, &ex)
			o["type"] = ex["type"]
			return o
		}
		raw, _ = json.Marshal(writable())
		if err := validateObject(raw, "object", topLevel); err != nil && strings.Contains(err.Error(), "is not a field") {
			t.Errorf("%s with every writable field: %v", k.Kind, err)
		}

		// A typo is refused at the top and inside.
		for _, path := range append([][]any{nil}, spots(k.Fields, nil)...) {
			o := writable()
			var node any = o
			for _, p := range path {
				switch p := p.(type) {
				case string:
					node = node.(obj)[p]
				case int:
					node = node.([]any)[p]
				}
			}
			node.(obj)["quantiy"] = 1
			raw, _ := json.Marshal(o)
			want := pathString(path) + ".quantiy is not a field of kind "
			typos++
			if err := validateObject(raw, "object", topLevel); err == nil || !strings.Contains(err.Error(), want) {
				t.Errorf("%s: typo at %s: %v, want %q", k.Kind, pathString(path), err, want)
			}
		}
	}
	if typos < 50 {
		t.Errorf("only %d places tried", typos)
	}
}

func TestUnknownFields(t *testing.T) {
	for _, c := range []struct {
		name, want string
		o          obj
	}{
		{"typo", "object.quantiy is not a field of kind quantity",
			obj{"kind": "quantity", "type": "HKQuantityTypeIdentifierBodyMass", "startDate": t0, "endDate": t0, "quantiy": qty(70, "kg")}},
		{"another kind's field", "object.value is not a field of kind quantity (it is a field of kind category)",
			obj{"kind": "quantity", "type": "HKQuantityTypeIdentifierBodyMass", "startDate": t0, "endDate": t0, "value": 70}},
		{"in a quantity", "object.quantity.units is not a field of kind quantity",
			obj{"kind": "quantity", "type": "HKQuantityTypeIdentifierBodyMass", "startDate": t0, "endDate": t0,
				"quantity": obj{"value": 70, "unit": "kg", "units": "kg"}}},
		{"in a member", "object.objects[0].unit is not a field of kind quantity",
			obj{"kind": "correlation", "type": "HKCorrelationTypeIdentifierFood", "startDate": t0, "endDate": t0,
				"objects": []any{obj{"kind": "quantity", "type": "HKQuantityTypeIdentifierDietaryProtein", "quantity": qty(30, "g"), "unit": "g"}}}},
		{"in a configuration", "object.workoutActivities[0].workoutConfiguration.indoor is not a field of kind workout",
			with(run, func(o obj) { at(o, "workoutActivities", 0, "workoutConfiguration")["indoor"] = true })},
		{"in a route", "object.route[1].lat is not a field of kind workout", with(run, func(o obj) { at(o, "route", 1)["lat"] = 31.2 })},
		{"read-only still says so", "object.valueName is read-only; omit it",
			obj{"kind": "category", "type": "HKCategoryTypeIdentifierSleepAnalysis", "startDate": t0, "endDate": t1, "value": 5, "valueName": "asleepREM"}},
		{"uuid keeps its message", "object.uuid is assigned by HealthKit; omit it", with(gad7, func(o obj) { o["uuid"] = "A" })},
		{"device keeps its message", "object.device is read-only; omit it", with(gad7, func(o obj) { o["device"] = obj{} })},
		{"metadata values", "object.metadata.HKFoodType must be a string, a number or a boolean",
			with(gad7, func(o obj) { o["metadata"] = obj{"HKFoodType": obj{"name": "x"}} })},
		{"label not in the SDK", "object.labels[1] must be an HKStateOfMind.Label raw value",
			obj{"kind": "stateOfMind", "type": "HKDataTypeStateOfMind", "startDate": t0, "stateOfMindKind": 1, "valence": 0, "labels": []any{29, 99}}},
		{"activity name not in the SDK", "workoutActivityTypeName must be a name such as \"running\"",
			with(run, func(o obj) { o["workoutActivityTypeName"] = "jogging" })},
	} {
		err := validate(c.o)
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: %v, want %q", c.name, err, c.want)
		}
	}
	// A deprecated activity type goes by activity_<n>, as the app reads it.
	if err := validate(with(run, func(o obj) { o["workoutActivityTypeName"] = "activity_14" })); err != nil {
		t.Errorf("activity_14: %v", err)
	}
}

// Every SDK type belongs to the kind the table gives it, and every enum
// the table names is in the SDK.
func TestKindsMatchTheSDK(t *testing.T) {
	for _, id := range sdk.TypeIDs() {
		_, typ, _ := sdk.LookupType(id)
		if got := KindOfType(id); got != typ.Kind {
			t.Errorf("%s: kind %q in the table, %q in the SDK", id, got, typ.Kind)
		}
	}
	var walk func(kind string, specs []Field)
	walk = func(kind string, specs []Field) {
		for _, f := range specs {
			if _, ok := sdk.LookupEnum(f.Enum); f.Enum != "" && !ok {
				t.Errorf("%s.%s: no SDK enum %s", kind, f.Name, f.Enum)
			}
			if f.Description == "" {
				t.Errorf("%s.%s: no description", kind, f.Name)
			}
			walk(kind, f.Fields)
		}
	}
	for _, k := range Kinds() {
		walk(k.Kind, k.Fields)
		if k.How == "" || (k.Write && k.Example == nil) || (!k.Write && k.refusal == "") {
			t.Errorf("%s: incomplete", k.Kind)
		}
	}
}

// docs/PROTOCOL.md's capability table says what the table says.
func TestCapabilityTableInProtocol(t *testing.T) {
	doc, err := os.ReadFile("../../docs/PROTOCOL.md")
	if err != nil {
		t.Fatal(err)
	}
	row := regexp.MustCompile("(?m)^\\| `(\\w+)` \\| [^|]+ \\| [^|]+ \\| ([^|]+) \\| ([^|]+) \\|")
	seen := map[string]bool{}
	for _, m := range row.FindAllStringSubmatch(string(doc), -1) {
		k, ok := LookupKind(m[1])
		if !ok {
			continue
		}
		seen[k.Kind] = true
		read, write := strings.HasPrefix(strings.TrimSpace(m[2]), "✓"), strings.HasPrefix(strings.TrimSpace(m[3]), "✓")
		if read != k.Read || write != k.Write {
			t.Errorf("%s: PROTOCOL.md says read %v write %v, the table %v %v", k.Kind, read, write, k.Read, k.Write)
		}
	}
	for _, k := range Kinds() {
		if !seen[k.Kind] {
			t.Errorf("%s is missing from PROTOCOL.md's capability table", k.Kind)
		}
	}
}
