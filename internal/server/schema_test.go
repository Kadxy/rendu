package server

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"strings"
	"testing"
)

// catalog is what the phone uploads (PUT /v1/catalog).
func catalog() map[string]any {
	return map[string]any{"os": "27.1", "types": []any{
		map[string]any{"type": "HKQuantityTypeIdentifierBodyMass", "kind": "quantity",
			"name": map[string]any{"en": "Weight", "zh-Hans": "体重"}, "unit": "kg", "preferredUnit": "lb",
			"aggregation": "discreteArithmetic"},
		map[string]any{"type": "HKCategoryTypeIdentifierSleepAnalysis", "kind": "category",
			"name":   map[string]any{"en": "Sleep"},
			"values": []any{map[string]any{"value": 2, "name": "awake"}, map[string]any{"value": 5, "name": "asleepREM"}}},
		map[string]any{"type": "HKVisionPrescriptionTypeIdentifier", "kind": "visionPrescription", "perObject": true},
		// A type newer than the server's SDK.
		map[string]any{"type": "HKQuantityTypeIdentifierFutureThing", "kind": "quantity", "unit": "ms",
			"aggregation": "cumulative", "minimumDuration": 60},
	}}
}

func TestSchemaScopes(t *testing.T) {
	e := newEnv(t)
	paths := []string{"/v1/schema", "/v1/schema/types/HKQuantityTypeIdentifierBodyMass", "/v1/schema/kinds/workout",
		"/v1/schema/enums/HKWorkoutActivityType", "/v1/schema/metadata/HKFoodType"}
	for _, key := range []string{e.device, e.agent, e.reader} {
		for _, p := range paths {
			e.must(200, "GET", p, key, nil)
		}
	}
	for _, p := range paths {
		e.must(401, "GET", p, "", nil)
	}
	for _, key := range []string{e.agent, e.reader} {
		e.must(403, "PUT", "/v1/catalog", key, catalog())
	}
	e.must(401, "PUT", "/v1/catalog", "", catalog())
	for _, p := range []string{"/v1/schema/types/HKQuantityTypeIdentifierNope", "/v1/schema/kinds/nope",
		"/v1/schema/enums/HKNope", "/v1/schema/metadata/HKNope", "/v1/schema/nope/x"} {
		e.must(404, "GET", p, e.reader, nil)
	}
}

func TestCatalogStoredReplacedAndCleared(t *testing.T) {
	e := newEnv(t)
	overview := e.must(200, "GET", "/v1/schema", e.reader, nil)
	if overview["os"] != nil || overview["catalogUpdatedAt"] != nil {
		t.Fatalf("before upload = %v %v", overview["os"], overview["catalogUpdatedAt"])
	}
	// Until the phone uploads its catalog, the types are the SDK's.
	sdkTypes := overview["types"].([]any)
	if len(sdkTypes) < 200 {
		t.Fatalf("%d SDK types", len(sdkTypes))
	}

	for _, bad := range []any{
		[]any{}, map[string]any{}, map[string]any{"os": "27.1"}, map[string]any{"os": "27.1", "types": []any{}},
		map[string]any{"os": "27.1", "types": []any{42}},
		map[string]any{"os": "27.1", "types": []any{map[string]any{"type": "X"}}},
		map[string]any{"os": "27.1", "types": []any{map[string]any{"type": "X", "kind": 1}}},
		map[string]any{"os": 27, "types": []any{map[string]any{"type": "X", "kind": "quantity"}}},
		"{not json",
	} {
		e.must(400, "PUT", "/v1/catalog", e.device, bad)
	}
	if got := e.must(200, "PUT", "/v1/catalog", e.device, catalog()); got["stored"] != 4.0 {
		t.Fatalf("put = %v", got)
	}
	e.must(200, "PUT", "/v1/authorization", e.device, map[string]any{"share": map[string]string{
		"HKQuantityTypeIdentifierBodyMass": "sharingAuthorized"}})

	overview = e.must(200, "GET", "/v1/schema", e.reader, nil)
	if overview["os"] != "27.1" || overview["catalogUpdatedAt"] == nil {
		t.Fatalf("after upload = %v %v", overview["os"], overview["catalogUpdatedAt"])
	}
	b, _ := json.Marshal(overview["types"])
	want := `[{"aggregation":"discreteArithmetic","kind":"quantity","name":{"en":"Weight","zh-Hans":"体重"},"share":"sharingAuthorized",` +
		`"type":"HKQuantityTypeIdentifierBodyMass","unit":"kg"},` +
		`{"kind":"category","name":{"en":"Sleep"},"type":"HKCategoryTypeIdentifierSleepAnalysis"},` +
		`{"kind":"visionPrescription","perObject":true,"type":"HKVisionPrescriptionTypeIdentifier"},` +
		`{"aggregation":"cumulative","kind":"quantity","type":"HKQuantityTypeIdentifierFutureThing","unit":"ms"}]`
	if string(b) != want {
		t.Fatalf("types = %s\nwant    %s", b, want)
	}

	// Replaced wholesale.
	one := catalog()
	one["os"], one["types"] = "27.2", one["types"].([]any)[:1]
	e.must(200, "PUT", "/v1/catalog", e.device, one)
	overview = e.must(200, "GET", "/v1/schema", e.reader, nil)
	if overview["os"] != "27.2" || len(overview["types"].([]any)) != 1 {
		t.Fatalf("after replace = %v %v", overview["os"], overview["types"])
	}

	// Wiping the data keeps it; a newly paired iPhone starts without.
	e.must(200, "DELETE", "/v1/data", e.device, nil)
	if overview = e.must(200, "GET", "/v1/schema", e.reader, nil); overview["os"] != "27.2" {
		t.Fatalf("after wipe = %v", overview["os"])
	}
	if err := e.store.StartPairing(context.Background(), "444444"); err != nil {
		t.Fatal(err)
	}
	e.must(200, "POST", "/v1/pair", "", map[string]string{"code": "444444", "key": "Zx9Yw8Vu7Ts6Rq5Po4Nm3Lk2Jh1Gf0EdCbA9z8y7x6w"})
	if overview = e.must(200, "GET", "/v1/schema", e.reader, nil); overview["os"] != nil || overview["catalogUpdatedAt"] != nil ||
		len(overview["types"].([]any)) != len(sdkTypes) {
		t.Fatalf("after pairing = %v %v, %d types", overview["os"], overview["catalogUpdatedAt"], len(overview["types"].([]any)))
	}
}

func TestSchemaOverview(t *testing.T) {
	e := newEnv(t)
	o := e.must(200, "GET", "/v1/schema", e.reader, nil)
	if o["sdk"].(map[string]any)["version"] == "" {
		t.Errorf("sdk = %v", o["sdk"])
	}
	kinds := map[string]map[string]any{}
	for _, k := range o["kinds"].([]any) {
		k := k.(map[string]any)
		kinds[k["kind"].(string)] = k
		if len(k) != 4 {
			t.Errorf("kind %v: want kind, read, write, how", k)
		}
	}
	if k := kinds["cdaDocument"]; k["read"] != false || k["write"] != false {
		t.Errorf("cdaDocument = %v", k)
	}
	if k := kinds["electrocardiogram"]; k["read"] != true || k["write"] != false {
		t.Errorf("electrocardiogram = %v", k)
	}
	found := false
	for _, ti := range o["types"].([]any) {
		ti := ti.(map[string]any)
		if ti["type"] == "HKQuantityTypeIdentifierStepCount" {
			found = ti["kind"] == "quantity" && ti["aggregation"] == "cumulative"
		}
		if ti["type"] == "HKCategoryTypeIdentifierAudioExposureEvent" && ti["kind"] != "category" {
			t.Errorf("audio exposure event = %v", ti)
		}
	}
	if !found {
		t.Error("no step count among the SDK's types")
	}
	if !contains(o["enums"], "HKStateOfMindLabel") || !contains(o["metadataKeys"], "HKFoodType") {
		t.Error("enums or metadata keys missing")
	}
}

func contains(list any, v string) bool {
	for _, x := range list.([]any) {
		if x == v {
			return true
		}
	}
	return false
}

func TestSchemaType(t *testing.T) {
	e := newEnv(t)
	get := func(typ string) map[string]any {
		t.Helper()
		return e.must(200, "GET", "/v1/schema/types/"+url.PathEscape(typ), e.reader, nil)
	}
	// Before the phone's catalog: the SDK's entry, with the values' enum.
	sleep := get("HKCategoryTypeIdentifierSleepAnalysis")
	if sleep["kind"] != "category" || sleep["read"] != true || sleep["write"] != true || sleep["catalog"] != nil || sleep["share"] != nil {
		t.Fatalf("sleep = %v", sleep)
	}
	values := sleep["sdk"].(map[string]any)["values"].(map[string]any)
	if values["name"] != "HKCategoryValueSleepAnalysis" || len(values["cases"].([]any)) < 6 {
		t.Fatalf("sleep values = %v", values)
	}
	if ex := sleep["example"].(map[string]any); ex["type"] != "HKCategoryTypeIdentifierSleepAnalysis" || ex["value"] != 0.0 {
		t.Fatalf("sleep example = %v", ex)
	}
	if !hasField(sleep["fields"], "valueName") {
		t.Fatal("sleep: no valueName field")
	}

	steps := get("HKQuantityTypeIdentifierStepCount")
	ex := steps["example"].(map[string]any)
	if ex["type"] != "HKQuantityTypeIdentifierStepCount" || ex["quantity"].(map[string]any)["unit"] != "count" || ex["startDate"] == ex["endDate"] {
		t.Fatalf("steps example = %v", ex)
	}
	if note := steps["sdk"].(map[string]any)["note"]; note != "count, Cumulative" {
		t.Fatalf("steps note = %v", note)
	}

	// The constant's name finds the type by its value.
	if mind := get("HKDataTypeIdentifierStateOfMind"); mind["type"] != "HKDataTypeStateOfMind" || mind["kind"] != "stateOfMind" ||
		mind["example"].(map[string]any)["type"] != "HKDataTypeStateOfMind" {
		t.Fatalf("state of mind = %v", mind)
	}
	if bp := get("HKCorrelationTypeIdentifierBloodPressure"); !strings.Contains(fmt.Sprint(bp["example"]), "BloodPressureSystolic") {
		t.Fatalf("blood pressure example = %v", bp["example"])
	}
	if cda := get("HKDocumentTypeIdentifierCDA"); cda["read"] != false || cda["write"] != false {
		t.Fatalf("cda = %v", cda)
	}
	// Types Rendu has no object format for still have their SDK entry.
	if sex := get("HKCharacteristicTypeIdentifierBiologicalSex"); sex["kind"] != "characteristic" || sex["fields"] != nil ||
		sex["sdk"].(map[string]any)["values"].(map[string]any)["name"] != "HKBiologicalSex" {
		t.Fatalf("biological sex = %v", sex)
	}

	// With the phone's catalog: its entry, its unit and values in the example.
	e.must(200, "PUT", "/v1/catalog", e.device, catalog())
	e.must(200, "PUT", "/v1/authorization", e.device, map[string]any{"share": map[string]string{
		"HKCategoryTypeIdentifierSleepAnalysis": "sharingDenied"}})
	sleep = get("HKCategoryTypeIdentifierSleepAnalysis")
	if sleep["share"] != "sharingDenied" || sleep["catalog"].(map[string]any)["name"].(map[string]any)["en"] != "Sleep" ||
		sleep["example"].(map[string]any)["value"] != 2.0 {
		t.Fatalf("sleep with catalog = %v", sleep)
	}
	future := get("HKQuantityTypeIdentifierFutureThing")
	if future["sdk"] != nil || future["kind"] != "quantity" || future["catalog"].(map[string]any)["minimumDuration"] != 60.0 {
		t.Fatalf("future = %v", future)
	}
	if ex := future["example"].(map[string]any); ex["quantity"].(map[string]any)["unit"] != "ms" || ex["startDate"] == ex["endDate"] {
		t.Fatalf("future example = %v", ex)
	}
	if mass := get("HKQuantityTypeIdentifierBodyMass"); mass["example"].(map[string]any)["quantity"].(map[string]any)["unit"] != "kg" {
		t.Fatalf("body mass = %v", mass)
	}
}

// Every type's example can be submitted as is, where the kind is writable.
func TestSchemaTypeExamplesAreAccepted(t *testing.T) {
	e := newEnv(t)
	for _, ti := range e.must(200, "GET", "/v1/schema", e.reader, nil)["types"].([]any) {
		typ := ti.(map[string]any)["type"].(string)
		got := e.must(200, "GET", "/v1/schema/types/"+typ, e.reader, nil)
		if got["write"] != true {
			continue
		}
		if status, out := e.call("POST", "/v1/writes", e.agent, map[string]any{"op": "save", "object": got["example"]}, false); status != 201 {
			t.Errorf("%s: %d %v", typ, status, out)
		}
	}
}

func hasField(fields any, name string) bool {
	for _, f := range fields.([]any) {
		if f.(map[string]any)["name"] == name {
			return true
		}
	}
	return false
}

func TestSchemaKindsEnumsAndMetadata(t *testing.T) {
	e := newEnv(t)
	k := e.must(200, "GET", "/v1/schema/kinds/stateOfMind", e.reader, nil)
	if k["read"] != true || k["write"] != true || k["example"] == nil || !hasField(k["fields"], "valence") {
		t.Fatalf("kind = %v", k)
	}
	for _, f := range k["fields"].([]any) {
		f := f.(map[string]any)
		switch f["name"] {
		case "labels":
			if f["enum"] != "HKStateOfMind.Label" || f["items"] != "integer" {
				t.Errorf("labels = %v", f)
			}
		case "valenceClassification":
			if f["readOnly"] != true {
				t.Errorf("valenceClassification = %v", f)
			}
		case "startDate":
			if f["required"] != true {
				t.Errorf("startDate = %v", f)
			}
		}
	}
	if q := e.must(200, "GET", "/v1/schema/kinds/quantity", e.reader, nil); !strings.Contains(fmt.Sprint(q["fields"]), "required:unless series is given") {
		t.Errorf("a condition is described in words: %v", q["fields"])
	}

	for _, name := range []string{"HKStateOfMind.Label", "HKStateOfMindLabel"} {
		en := e.must(200, "GET", "/v1/schema/enums/"+name, e.reader, nil)
		if en["name"] != "HKStateOfMindLabel" || en["swiftName"] != "HKStateOfMind.Label" {
			t.Fatalf("%s = %v", name, en)
		}
		stressed := en["cases"].([]any)[28].(map[string]any)
		if stressed["short"] != "stressed" || stressed["value"] != 29.0 || stressed["name"] != "HKStateOfMindLabelStressed" {
			t.Fatalf("%s: 29 = %v", name, stressed)
		}
	}
	for _, name := range []string{"HKFoodType", "HKMetadataKeyFoodType"} {
		if m := e.must(200, "GET", "/v1/schema/metadata/"+name, e.reader, nil); m["key"] != "HKFoodType" || m["valueType"] != "NSString" {
			t.Fatalf("%s = %v", name, m)
		}
	}
	if m := e.must(200, "GET", "/v1/schema/metadata/HKMetadataKeyHeartRateMotionContext", e.reader, nil); m["values"].(map[string]any)["name"] != "HKHeartRateMotionContext" {
		t.Fatalf("motion context = %v", m)
	}
}

func TestSchemaActivity(t *testing.T) {
	e := newEnv(t)
	e.must(200, "GET", "/v1/schema", e.agent, nil)
	e.must(200, "GET", "/v1/schema/types/HKQuantityTypeIdentifierBodyMass", e.agent, nil)
	e.must(404, "GET", "/v1/schema/types/HKNope", e.agent, nil)
	e.must(200, "GET", "/v1/schema/enums/HKStateOfMind.Label", e.agent, nil)
	got, _ := activity(t, e, e.keyID("agent"), "")
	var lines []string
	for _, a := range got {
		delete(a, "at")
		b, _ := json.Marshal(a)
		lines = append(lines, string(b))
	}
	want := []string{
		`{"method":"GET","path":"/v1/schema/enums/{name}","status":200}`,
		`{"method":"GET","path":"/v1/schema/types/{type}","status":404,"type":"HKNope"}`,
		`{"method":"GET","path":"/v1/schema/types/{type}","status":200,"type":"HKQuantityTypeIdentifierBodyMass"}`,
		`{"method":"GET","path":"/v1/schema","status":200}`,
	}
	if strings.Join(lines, "\n") != strings.Join(want, "\n") {
		t.Fatalf("activity:\n%s\nwant\n%s", strings.Join(lines, "\n"), strings.Join(want, "\n"))
	}
}
