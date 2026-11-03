package server

import (
	"fmt"
	"testing"
)

// synced is a sample as the phone uploads one Rendu wrote: with its
// syncIdentifier and syncVersion in the metadata.
func synced(uuid, typ, syncID string, version int) map[string]any {
	ts := "2026-11-01T12:30:00+08:00"
	o := map[string]any{"uuid": uuid, "kind": "quantity", "type": typ, "startDate": ts, "endDate": ts,
		"quantity":       map[string]any{"value": 30, "unit": "g"},
		"sourceRevision": map[string]any{"source": map[string]any{"name": "Rendu", "bundleIdentifier": "com.example.rendu"}},
		"metadata":       map[string]any{"HKMetadataKeySyncIdentifier": syncID, "HKMetadataKeySyncVersion": version}}
	if typ == food {
		o["kind"] = "correlation"
		delete(o, "quantity")
	}
	return o
}

const (
	food    = "HKCorrelationTypeIdentifierFood"
	protein = "HKQuantityTypeIdentifierDietaryProtein"
	energy  = "HKQuantityTypeIdentifierDietaryEnergyConsumed"
	mass    = "HKQuantityTypeIdentifierBodyMass"
)

// After the server's data (writes included) was cleared, what Rendu saved
// earlier can still be changed and deleted: the server falls back to the
// samples the phone uploads again, found by their syncIdentifier.
func TestWritesAfterWipe(t *testing.T) {
	e := newEnv(t)
	meal := e.must(201, "POST", "/v1/writes", e.agent, map[string]any{"op": "save", "syncIdentifier": "meal-1", "object": map[string]any{
		"kind": "correlation", "type": food,
		"startDate": "2026-11-01T12:30:00+08:00", "endDate": "2026-11-01T12:30:00+08:00",
		"objects": []any{
			map[string]any{"kind": "quantity", "type": protein, "quantity": map[string]any{"value": 30, "unit": "g"}},
			map[string]any{"kind": "quantity", "type": energy, "quantity": map[string]any{"value": 600, "unit": "kcal"}},
		},
	}})
	e.must(200, "POST", "/v1/writes/results", e.device, []any{map[string]any{"id": meal["id"], "status": "written", "uuids": []string{"C", "M0", "M1"}}})
	e.must(200, "DELETE", "/v1/data", e.device, nil)

	// Nothing uploaded yet: nothing to delete.
	e.must(404, "POST", "/v1/writes", e.agent, map[string]any{"op": "delete", "syncIdentifier": "meal-1"})

	// The phone uploads Health again, members sorted after the meal. A
	// removed member and a look-alike identifier are not part of it.
	e.must(200, "POST", "/v1/ingest", e.device, []any{
		synced("M10", protein, "meal-1:10", 1),
		synced("M1", energy, "meal-1:1", 1),
		synced("C", food, "meal-1", 1),
		synced("M0", protein, "meal-1:0", 1),
		synced("MX", protein, "meal-1:2", 1),
		synced("OTHER", protein, "meal-10", 1),
		synced("SEMI", protein, "meal-1;0", 1),
		synced("BM", mass, "bm", 3),
	})
	e.must(200, "POST", "/v1/ingest", e.device, []any{map[string]any{"deleted": []string{"MX"}}})

	// The authorization check covers the members' types.
	share := map[string]string{protein: "sharingDenied", energy: "sharingAuthorized", mass: "sharingAuthorized"}
	e.must(200, "PUT", "/v1/authorization", e.device, map[string]any{"share": share})
	status, out := e.call("POST", "/v1/writes", e.agent, map[string]any{"op": "delete", "syncIdentifier": "meal-1"}, false)
	if status != 422 || out.(map[string]any)["error"] != "write access to "+protein+" is turned off for Rendu in Apple Health settings" {
		t.Fatalf("delete with a member's type turned off: %d %v", status, out)
	}
	share[protein] = "sharingAuthorized"
	e.must(200, "PUT", "/v1/authorization", e.device, map[string]any{"share": share})

	del := e.must(201, "POST", "/v1/writes", e.agent, map[string]any{"op": "delete", "syncIdentifier": "meal-1"})
	// A save after the wipe outgrows the version in Health.
	edit := e.must(201, "POST", "/v1/writes", e.agent, map[string]any{"op": "save", "syncIdentifier": "bm", "object": bodyMass(71)})
	if edit["syncVersion"] != 4.0 {
		t.Fatalf("version after wipe = %v, want 4", edit["syncVersion"])
	}
	p := pending(t, e)
	if len(p) != 2 || p[0]["id"] != del["id"] || p[1]["id"] != edit["id"] {
		t.Fatalf("pending = %v", p)
	}
	if fmt.Sprint(p[0]["replaceUUIDs"]) != "[C M0 M1 M10]" || fmt.Sprint(p[0]["replaceTypes"]) != "["+food+" "+protein+" "+energy+"]" {
		t.Fatalf("meal delete targets = %v %v", p[0]["replaceUUIDs"], p[0]["replaceTypes"])
	}
	if fmt.Sprint(p[1]["replaceUUIDs"]) != "[BM]" || fmt.Sprint(p[1]["replaceTypes"]) != "["+mass+"]" {
		t.Fatalf("body mass save targets = %v %v", p[1]["replaceUUIDs"], p[1]["replaceTypes"])
	}

	// Once written, the server's own record takes over again, and versions
	// keep growing past both.
	e.must(200, "POST", "/v1/writes/results", e.device, []any{
		map[string]any{"id": del["id"], "status": "written"},
		map[string]any{"id": edit["id"], "status": "written", "uuids": []string{"BM2"}},
	})
	again := e.must(201, "POST", "/v1/writes", e.agent, map[string]any{"op": "save", "syncIdentifier": "bm", "object": bodyMass(70.5)})
	if again["syncVersion"] != 5.0 {
		t.Fatalf("next version = %v, want 5", again["syncVersion"])
	}
	if p := pending(t, e); len(p) != 1 || fmt.Sprint(p[0]["replaceUUIDs"]) != "[BM2]" {
		t.Fatalf("pending after the written save = %v", p)
	}

	// Still unknown: no write, no live sample.
	e.must(404, "POST", "/v1/writes", e.agent, map[string]any{"op": "delete", "syncIdentifier": "never-written"})
	e.must(404, "POST", "/v1/writes", e.agent, map[string]any{"op": "delete", "syncIdentifier": "meal-1:2"})
}

// A failed save leaves Health as it was: the next write still replaces what
// the phone uploaded.
func TestFailedSaveAfterWipeKeepsTargets(t *testing.T) {
	e := newEnv(t)
	e.must(200, "POST", "/v1/ingest", e.device, []any{synced("BM", mass, "bm", 2)})
	w := e.must(201, "POST", "/v1/writes", e.agent, map[string]any{"op": "save", "syncIdentifier": "bm", "object": bodyMass(71)})
	e.must(200, "POST", "/v1/writes/results", e.device, []any{map[string]any{"id": w["id"], "status": "failed", "error": "x"}})
	del := e.must(201, "POST", "/v1/writes", e.agent, map[string]any{"op": "delete", "syncIdentifier": "bm"})
	if p := pending(t, e); len(p) != 1 || p[0]["id"] != del["id"] || fmt.Sprint(p[0]["replaceUUIDs"]) != "[BM]" {
		t.Fatalf("pending = %v", p)
	}
}

// runWithRoute is a run with energy, an effort score and a route.
func runWithRoute() map[string]any {
	o := workout(map[string]any{"workoutActivityTypeName": "running"}, "HKQuantityTypeIdentifierActiveEnergyBurned")
	o["samples"] = append(o["samples"].([]any), map[string]any{
		"kind": "quantity", "type": "HKQuantityTypeIdentifierWorkoutEffortScore",
		"startDate": "2026-11-01T18:00:00+08:00", "endDate": "2026-11-01T19:00:00+08:00",
		"quantity": map[string]any{"value": 7, "unit": "appleEffortScore"},
	})
	o["workoutEvents"] = []any{map[string]any{"type": 3, "startDate": "2026-11-01T18:00:00+08:00", "endDate": "2026-11-01T18:30:00+08:00"}}
	o["route"] = []any{
		map[string]any{"timestamp": "2026-11-01T18:00:00+08:00", "latitude": 31.23, "longitude": 121.47},
		map[string]any{"timestamp": "2026-11-01T18:59:00+08:00", "latitude": 31.24, "longitude": 121.48},
	}
	return o
}

func TestWorkoutRouteWrites(t *testing.T) {
	e := newEnv(t)
	share := map[string]string{
		"HKWorkoutTypeIdentifier":                    "sharingAuthorized",
		"HKQuantityTypeIdentifierActiveEnergyBurned": "sharingAuthorized",
		"HKQuantityTypeIdentifierWorkoutEffortScore": "sharingAuthorized",
	}
	e.must(200, "PUT", "/v1/authorization", e.device, map[string]any{"share": share})
	save := map[string]any{"op": "save", "syncIdentifier": "run-1", "object": runWithRoute()}

	// The route has a type of its own.
	status, out := e.call("POST", "/v1/writes", e.agent, save, false)
	if status != 422 || out.(map[string]any)["error"] != "HealthKit doesn't allow apps to write HKWorkoutRouteTypeIdentifier" {
		t.Fatalf("route type missing: %d %v", status, out)
	}
	share["HKWorkoutRouteTypeIdentifier"] = "sharingDenied"
	e.must(200, "PUT", "/v1/authorization", e.device, map[string]any{"share": share})
	status, out = e.call("POST", "/v1/writes", e.agent, save, false)
	if status != 422 || out.(map[string]any)["error"] != "write access to HKWorkoutRouteTypeIdentifier is turned off for Rendu in Apple Health settings" {
		t.Fatalf("route type denied: %d %v", status, out)
	}
	// Without the route, its type isn't needed.
	noRoute := runWithRoute()
	delete(noRoute, "route")
	e.must(201, "POST", "/v1/writes", e.agent, map[string]any{"op": "save", "object": noRoute})

	share["HKWorkoutRouteTypeIdentifier"] = "sharingAuthorized"
	e.must(200, "PUT", "/v1/authorization", e.device, map[string]any{"share": share})
	w := e.must(201, "POST", "/v1/writes", e.agent, save)
	for _, p := range pending(t, e) {
		e.must(200, "POST", "/v1/writes/results", e.device, []any{map[string]any{"id": p["id"], "status": "written",
			"uuids": map[bool][]string{true: {"HK-W", "HK-E", "HK-F", "HK-R"}, false: {"HK-X"}}[p["id"] == w["id"]]}})
	}

	// Replacing the run targets the workout, its samples and its route.
	e.must(201, "POST", "/v1/writes", e.agent, save)
	p := pending(t, e)
	if len(p) != 1 || fmt.Sprint(p[0]["replaceUUIDs"]) != "[HK-W HK-E HK-F HK-R]" ||
		fmt.Sprint(p[0]["replaceTypes"]) != "[HKWorkoutTypeIdentifier HKQuantityTypeIdentifierActiveEnergyBurned "+
			"HKQuantityTypeIdentifierWorkoutEffortScore HKWorkoutRouteTypeIdentifier]" {
		t.Fatalf("pending replacement = %v", p)
	}
	e.must(200, "POST", "/v1/writes/results", e.device, []any{map[string]any{"id": p[0]["id"], "status": "written",
		"uuids": []string{"HK-W2", "HK-E2", "HK-F2", "HK-R2"}}})

	// Deleting it needs the route's type too.
	share["HKWorkoutRouteTypeIdentifier"] = "sharingDenied"
	e.must(200, "PUT", "/v1/authorization", e.device, map[string]any{"share": share})
	e.must(422, "POST", "/v1/writes", e.agent, map[string]any{"op": "delete", "syncIdentifier": "run-1"})
}

func TestNewKindsCheckAuthorization(t *testing.T) {
	e := newEnv(t)
	e.must(200, "PUT", "/v1/authorization", e.device, map[string]any{"share": map[string]string{
		"HKScoredAssessmentTypeIdentifierPHQ9": "sharingAuthorized",
	}})
	assessment := func(typ string) map[string]any {
		return map[string]any{"op": "save", "object": map[string]any{"kind": "scoredAssessment", "type": typ,
			"startDate": "2026-11-01T21:00:00+08:00", "answers": []int{0, 1, 0, 2, 1, 0, 0, 1, 0}}}
	}
	if w := e.must(201, "POST", "/v1/writes", e.agent, assessment("HKScoredAssessmentTypeIdentifierPHQ9")); w["syncVersion"] != 1.0 {
		t.Fatalf("PHQ-9 = %v", w)
	}
	status, out := e.call("POST", "/v1/writes", e.agent, map[string]any{"op": "save", "object": map[string]any{
		"kind": "heartbeatSeries", "type": "HKDataTypeIdentifierHeartbeatSeries", "startDate": "2026-11-01T21:00:00+08:00",
		"beats": []any{map[string]any{"timeSinceSeriesStart": 0, "precededByGap": false}},
	}}, false)
	if status != 422 || out.(map[string]any)["error"] != "HealthKit doesn't allow apps to write HKDataTypeIdentifierHeartbeatSeries" {
		t.Fatalf("heartbeat series = %d %v", status, out)
	}
}
