package store

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

const (
	t0     = "2026-11-01T07:00:00+08:00"
	t1     = "2026-11-01T07:30:00+08:00"
	t2     = "2026-11-01T08:00:00+08:00"
	tLater = "2026-11-01T08:30:00+08:00"
)

type obj = map[string]any

func qty(v float64, unit string) obj { return obj{"value": v, "unit": unit} }

// at walks into nested objects and arrays: at(o, "route", 0) is the
// route's first location.
func at(o obj, path ...any) obj {
	var v any = o
	for _, p := range path {
		switch p := p.(type) {
		case string:
			v = v.(obj)[p]
		case int:
			v = v.([]any)[p]
		}
	}
	return v.(obj)
}

func heartRateSeries() obj {
	return obj{"kind": "quantity", "type": "HKQuantityTypeIdentifierHeartRate", "startDate": t0, "endDate": t2,
		"series": []any{
			obj{"quantity": qty(120, "count/min"), "startDate": t0, "endDate": t0},
			obj{"quantity": qty(150, "count/min"), "startDate": t1, "endDate": t2},
		}}
}

// run is an outdoor run with two laps, a route, energy and an effort score.
func run() obj {
	return obj{"kind": "workout", "type": "HKWorkoutTypeIdentifier", "startDate": t0, "endDate": t2,
		"workoutActivityTypeName": "running",
		"workoutActivities": []any{obj{
			"workoutConfiguration": obj{"activityType": 37, "locationType": 3},
			"startDate":            t0, "endDate": t2, "metadata": obj{"HKIndoorWorkout": false},
		}},
		"workoutEvents": []any{
			obj{"type": 3, "startDate": t0, "endDate": t1},
			obj{"type": 3, "startDate": t1, "endDate": t2},
			obj{"type": 1, "startDate": t1, "endDate": t1},
		},
		"route": []any{
			obj{"timestamp": t0, "latitude": 31.2304, "longitude": 121.4737, "altitude": 4.5, "horizontalAccuracy": 5,
				"verticalAccuracy": 3, "speed": 3.1, "course": 90},
			obj{"timestamp": t2, "latitude": 31.2404, "longitude": 121.4837},
		},
		"samples": []any{
			obj{"kind": "quantity", "type": "HKQuantityTypeIdentifierActiveEnergyBurned", "startDate": t0, "endDate": t2,
				"quantity": qty(420, "kcal")},
			obj{"kind": "quantity", "type": "HKQuantityTypeIdentifierWorkoutEffortScore", "startDate": t0, "endDate": t2,
				"quantity": qty(7, "appleEffortScore")},
		},
	}
}

func swim() obj {
	return obj{"kind": "workout", "type": "HKWorkoutTypeIdentifier", "startDate": t0, "endDate": t2,
		"workoutActivityType": 46,
		"workoutActivities": []any{obj{
			"workoutConfiguration": obj{"activityTypeName": "swimming", "swimmingLocationType": 1, "lapLength": qty(25, "m")},
			"startDate":            t1,
		}},
	}
}

func heartbeats() obj {
	return obj{"kind": "heartbeatSeries", "type": "HKDataTypeIdentifierHeartbeatSeries", "startDate": t0,
		"beats": []any{
			obj{"timeSinceSeriesStart": 0, "precededByGap": false},
			obj{"timeSinceSeriesStart": 0.82, "precededByGap": false},
			obj{"timeSinceSeriesStart": 2.5, "precededByGap": true},
		}}
}

func audiogram() obj {
	return obj{"kind": "audiogram", "type": "HKDataTypeIdentifierAudiogram", "startDate": t0, "endDate": t1,
		"sensitivityPoints": []any{obj{"frequency": qty(1000, "Hz"), "tests": []any{
			obj{"sensitivity": qty(15, "dBHL"), "type": 0, "masked": false, "side": 0},
			obj{"sensitivity": qty(20, "dBHL"), "type": 0, "masked": true, "side": 1,
				"clampingRange": obj{"lowerBound": qty(0, "dBHL")}},
		}}}}
}

func assessment(typ string, answers ...int) obj {
	return obj{"kind": "scoredAssessment", "type": typ, "startDate": t0, "answers": answers}
}

func gad7() obj { return assessment(gad7Type, 1, 2, 0, 3, 1, 0, 2) }
func phq9() obj { return assessment(phq9Type, 0, 1, 2, 3, 0, 1, 2, 3, 4) }

func glasses() obj {
	return obj{"kind": "visionPrescription", "type": "HKVisionPrescriptionTypeIdentifier",
		"prescriptionType": 1, "dateIssued": t0, "expirationDate": "2028-11-01T00:00:00+08:00",
		"rightEye": obj{"sphere": qty(-2.25, "D"), "cylinder": qty(-0.5, "D"), "axis": qty(180, "deg"),
			"vertexDistance": qty(12, "mm"), "farPupillaryDistance": qty(31.5, "mm"),
			"prism": obj{"amount": qty(1, "pD"), "angle": qty(90, "deg"), "eye": 2}},
		"leftEye": obj{"sphere": qty(-2, "D"), "nearPupillaryDistance": qty(30, "mm"),
			"prism": obj{"verticalAmount": qty(0.5, "pD"), "verticalBase": 1,
				"horizontalAmount": qty(1, "pD"), "horizontalBase": 3, "eye": 1}},
	}
}

func contacts() obj {
	return obj{"kind": "visionPrescription", "type": "HKVisionPrescriptionTypeIdentifier",
		"prescriptionType": 2, "dateIssued": t0, "brand": "Acuvue Oasys",
		"leftEye": obj{"sphere": qty(-2, "D"), "baseCurve": qty(8.4, "mm"), "diameter": qty(14, "mm")}}
}

func cda() obj {
	return obj{"kind": "cdaDocument", "type": "HKDocumentTypeIdentifierCDA", "startDate": t0, "endDate": t1,
		"documentData": `<?xml version="1.0"?><ClinicalDocument xmlns="urn:hl7-org:v3"/>`}
}

func validate(o obj) error {
	raw, err := json.Marshal(o)
	if err != nil {
		panic(err)
	}
	return validateObject(raw, "object", topLevel)
}

func TestValidObjects(t *testing.T) {
	for name, o := range map[string]obj{
		"quantity series":  heartRateSeries(),
		"run":              run(),
		"swim":             swim(),
		"heartbeat series": heartbeats(),
		"audiogram":        audiogram(),
		"GAD-7":            gad7(),
		"PHQ-9 declined 9": phq9(),
		"GAD-7 echo end":   with(gad7, func(o obj) { o["endDate"] = "2026-10-31T23:00:00Z" }),
		"glasses":          glasses(),
		"glasses, one eye": with(glasses, func(o obj) { delete(o, "rightEye") }),
		"contacts":         contacts(),
		"series member point": with(heartRateSeries, func(o obj) {
			o["series"] = []any{obj{"quantity": qty(60, "count/min"), "startDate": t2, "endDate": t2}}
		}),
		"empty activities and events": with(run, func(o obj) { o["workoutActivities"], o["workoutEvents"] = []any{}, []any{} }),
	} {
		if err := validate(o); err != nil {
			t.Errorf("%s: %v", name, err)
		}
	}
}

func with(base func() obj, change func(o obj)) obj {
	o := base()
	change(o)
	return o
}

func TestInvalidObjects(t *testing.T) {
	member := func(o obj) obj {
		return obj{"kind": "correlation", "type": "HKCorrelationTypeIdentifierFood", "startDate": t0, "endDate": t0,
			"objects": []any{o}}
	}
	// Each case breaks one rule; want is part of the error.
	for _, c := range []struct {
		name, want string
		o          obj
	}{
		// Kinds.
		{"route alone", "write a route as part of its workout (the workout's route field)",
			obj{"kind": "workoutRoute", "type": workoutRouteType, "startDate": t0, "endDate": t2}},
		{"ECG", "read-only", obj{"kind": "electrocardiogram", "type": "HKDataTypeIdentifierElectrocardiogram", "startDate": t0, "endDate": t2}},
		{"dose event", "read-only", obj{"kind": "medicationDoseEvent", "type": "HKMedicationDoseEventTypeIdentifierMedicationDoseEvent", "startDate": t0, "endDate": t2}},
		{"unknown kind", "unknown", obj{"kind": "allergyRecord", "type": "HKClinicalTypeIdentifierAllergyRecord", "startDate": t0, "endDate": t2}},
		{"health record", "can't be written", obj{"kind": "clinicalRecord", "type": "HKClinicalTypeIdentifierAllergyRecord", "startDate": t0, "endDate": t2}},

		// Quantity series.
		{"quantity and series", "exactly one of quantity and series", with(heartRateSeries, func(o obj) { o["quantity"] = qty(1, "count/min") })},
		{"neither", "exactly one of quantity and series", with(heartRateSeries, func(o obj) { delete(o, "series") })},
		{"empty series", "non-empty", with(heartRateSeries, func(o obj) { o["series"] = []any{} })},
		{"series object", "must be an array", with(heartRateSeries, func(o obj) { o["series"] = obj{} })},
		{"point outside", "series[1] must lie within", with(heartRateSeries, func(o obj) { at(o, "series", 1)["endDate"] = tLater })},
		{"point before start", "series[0] must lie within", with(heartRateSeries, func(o obj) { at(o, "series", 0)["startDate"] = "2026-11-01T06:59:00+08:00" })},
		{"point end before start", "series[1]: endDate is before startDate", with(heartRateSeries, func(o obj) { at(o, "series", 1)["endDate"] = t0 })},
		{"point without quantity", "series[0].quantity is required", with(heartRateSeries, func(o obj) { delete(at(o, "series", 0), "quantity") })},
		{"point without unit", "series[0].quantity.unit", with(heartRateSeries, func(o obj) { at(o, "series", 0)["quantity"] = obj{"value": 1} })},
		{"point without dates", "series[0].endDate is required", with(heartRateSeries, func(o obj) { delete(at(o, "series", 0), "endDate") })},
		{"count", "count is read-only", with(heartRateSeries, func(o obj) { o["count"] = 2 })},
		{"minimum", "minimumQuantity is read-only", with(heartRateSeries, func(o obj) { o["minimumQuantity"] = qty(120, "count/min") })},
		{"maximum", "maximumQuantity is read-only", with(heartRateSeries, func(o obj) { o["maximumQuantity"] = qty(150, "count/min") })},
		{"most recent", "mostRecentQuantity is read-only", with(heartRateSeries, func(o obj) { o["mostRecentQuantity"] = qty(150, "count/min") })},
		{"most recent interval", "mostRecentQuantityDateInterval is read-only", with(heartRateSeries, func(o obj) {
			o["mostRecentQuantityDateInterval"] = obj{"startDate": t1, "endDate": t2}
		})},
		{"series member", "objects[0].series is only for a sample of its own", member(obj{"kind": "quantity",
			"type": "HKQuantityTypeIdentifierDietaryProtein", "series": heartRateSeries()["series"]})},
		{"series workout sample", "samples[0].series is only for a sample of its own", with(run, func(o obj) {
			s := at(o, "samples", 0)
			delete(s, "quantity")
			s["series"] = []any{obj{"quantity": qty(1, "kcal"), "startDate": t0, "endDate": t1}}
		})},
		{"series on a category", "object.series is not a field of kind category (it is a field of kind quantity)", obj{"kind": "category", "type": "HKCategoryTypeIdentifierMindfulSession",
			"startDate": t0, "endDate": t1, "value": 0, "series": []any{}}},

		// Workout: activities.
		{"activity without configuration", "workoutActivities[0].workoutConfiguration is required", with(run, func(o obj) {
			delete(at(o, "workoutActivities", 0), "workoutConfiguration")
		})},
		{"configuration not an object", "workoutConfiguration must be an object", with(run, func(o obj) {
			at(o, "workoutActivities", 0)["workoutConfiguration"] = 37
		})},
		{"both activity types", "exactly one of activityType and activityTypeName", with(run, func(o obj) {
			at(o, "workoutActivities", 0, "workoutConfiguration")["activityTypeName"] = "running"
		})},
		{"no activity type", "exactly one of activityType and activityTypeName", with(run, func(o obj) {
			delete(at(o, "workoutActivities", 0, "workoutConfiguration"), "activityType")
		})},
		{"activity type 0", "activityType must be an HKWorkoutActivityType", with(run, func(o obj) {
			at(o, "workoutActivities", 0, "workoutConfiguration")["activityType"] = 0
		})},
		{"empty activity name", "activityTypeName must be a name", with(swim, func(o obj) {
			at(o, "workoutActivities", 0, "workoutConfiguration")["activityTypeName"] = ""
		})},
		{"location type 4", "locationType must be an HKWorkoutSessionLocationType raw value: 1 unknown, 2 indoor, 3 outdoor", with(run, func(o obj) {
			at(o, "workoutActivities", 0, "workoutConfiguration")["locationType"] = 4
		})},
		{"swimming location 3", "swimmingLocationType must be an HKWorkoutSwimmingLocationType raw value: 0 unknown, 1 pool, 2 openWater", with(swim, func(o obj) {
			at(o, "workoutActivities", 0, "workoutConfiguration")["swimmingLocationType"] = 3
		})},
		{"lap length number", "lapLength must be", with(swim, func(o obj) {
			at(o, "workoutActivities", 0, "workoutConfiguration")["lapLength"] = 25
		})},
		{"activity outside", "workoutActivities[0] must lie within", with(run, func(o obj) { at(o, "workoutActivities", 0)["endDate"] = tLater })},
		{"open activity after the end", "workoutActivities[0] must lie within", with(swim, func(o obj) { at(o, "workoutActivities", 0)["startDate"] = tLater })},
		{"activity end before start", "workoutActivities[0]: endDate is before startDate", with(run, func(o obj) {
			at(o, "workoutActivities", 0)["startDate"] = t1
			at(o, "workoutActivities", 0)["endDate"] = t0
		})},
		{"activity without start", "workoutActivities[0].startDate is required", with(run, func(o obj) { delete(at(o, "workoutActivities", 0), "startDate") })},
		{"activity uuid", "workoutActivities[0].uuid is read-only", with(run, func(o obj) { at(o, "workoutActivities", 0)["uuid"] = "A" })},
		{"activity duration", "workoutActivities[0].duration is read-only", with(run, func(o obj) { at(o, "workoutActivities", 0)["duration"] = 60 })},
		{"activity statistics", "workoutActivities[0].statistics is read-only", with(run, func(o obj) { at(o, "workoutActivities", 0)["statistics"] = obj{} })},
		{"activity sync metadata", "workoutActivities[0].metadata.HKMetadataKeySyncIdentifier is set by the app", with(run, func(o obj) {
			at(o, "workoutActivities", 0)["metadata"] = obj{"HKMetadataKeySyncIdentifier": "x"}
		})},
		{"activities object", "workoutActivities must be an array", with(run, func(o obj) { o["workoutActivities"] = obj{} })},

		// Workout: events.
		{"event type 0", "workoutEvents[0].type must be an HKWorkoutEventType", with(run, func(o obj) { at(o, "workoutEvents", 0)["type"] = 0 })},
		{"event type 9", "workoutEvents[0].type must be an HKWorkoutEventType", with(run, func(o obj) { at(o, "workoutEvents", 0)["type"] = 9 })},
		{"event type name", "workoutEvents[0].type must be an HKWorkoutEventType", with(run, func(o obj) { at(o, "workoutEvents", 0)["type"] = "lap" })},
		{"event without end", "workoutEvents[0].endDate is required", with(run, func(o obj) { delete(at(o, "workoutEvents", 0), "endDate") })},
		{"event end before start", "workoutEvents[0]: endDate is before startDate", with(run, func(o obj) { at(o, "workoutEvents", 0)["endDate"] = "2026-11-01T06:00:00+08:00" })},
		{"pause that lasts", "only lap (3) and segment (7) events last", with(run, func(o obj) { at(o, "workoutEvents", 2)["endDate"] = t2 })},
		{"event outside", "workoutEvents[1] must lie within", with(run, func(o obj) { at(o, "workoutEvents", 1)["endDate"] = tLater })},
		{"event metadata", "workoutEvents[0].metadata must be an object", with(run, func(o obj) { at(o, "workoutEvents", 0)["metadata"] = "lap 1" })},

		// Workout: route.
		{"empty route", "route must be a non-empty array", with(run, func(o obj) { o["route"] = []any{} })},
		{"route latitude", "route[0].latitude must be a number from -90 to 90", with(run, func(o obj) { at(o, "route", 0)["latitude"] = 91 })},
		{"route without latitude", "route[1].latitude", with(run, func(o obj) { delete(at(o, "route", 1), "latitude") })},
		{"route longitude", "route[1].longitude must be a number from -180 to 180", with(run, func(o obj) { at(o, "route", 1)["longitude"] = -180.5 })},
		{"route timestamp outside", "route[1].timestamp must lie within", with(run, func(o obj) { at(o, "route", 1)["timestamp"] = tLater })},
		{"route without timestamp", "route[0].timestamp is required", with(run, func(o obj) { delete(at(o, "route", 0), "timestamp") })},
		{"route bad timestamp", "route[0].timestamp", with(run, func(o obj) { at(o, "route", 0)["timestamp"] = "07:00" })},
		{"route speed", "route[0].speed must be a number", with(run, func(o obj) { at(o, "route", 0)["speed"] = "fast" })},
		{"route on a quantity", "object.route is not a field of kind quantity (it is a field of kind workout)", with(heartRateSeries, func(o obj) { o["route"] = run()["route"] })},

		// Workout: the rest.
		{"effort relationships", "effortRelationships is read-only", with(run, func(o obj) { o["effortRelationships"] = []any{} })},
		{"workout duration", "duration is read-only", with(run, func(o obj) { o["duration"] = 3600 })},
		{"events on a mood", "object.workoutEvents is not a field of kind stateOfMind", obj{"kind": "stateOfMind", "type": "HKDataTypeStateOfMind",
			"startDate": t0, "stateOfMindKind": 1, "valence": 0, "workoutEvents": []any{}}},
		{"effort sample outside", "samples[1] must lie within", with(run, func(o obj) { at(o, "samples", 1)["endDate"] = tLater })},

		// Heartbeat series.
		{"heartbeat endDate", "endDate is set by HealthKit", with(heartbeats, func(o obj) { o["endDate"] = t1 })},
		{"heartbeat no start", "startDate is required", with(heartbeats, func(o obj) { delete(o, "startDate") })},
		{"no beats", "object.beats is required", with(heartbeats, func(o obj) { delete(o, "beats") })},
		{"empty beats", "beats must be a non-empty array", with(heartbeats, func(o obj) { o["beats"] = []any{} })},
		{"beat repeated", "beats[1].timeSinceSeriesStart must be greater", with(heartbeats, func(o obj) { at(o, "beats", 1)["timeSinceSeriesStart"] = 0 })},
		{"beat back in time", "beats[2].timeSinceSeriesStart must be greater", with(heartbeats, func(o obj) { at(o, "beats", 2)["timeSinceSeriesStart"] = 0.5 })},
		{"negative beat", "beats[0].timeSinceSeriesStart must be a number", with(heartbeats, func(o obj) { at(o, "beats", 0)["timeSinceSeriesStart"] = -1 })},
		{"beat without time", "beats[0].timeSinceSeriesStart", with(heartbeats, func(o obj) { delete(at(o, "beats", 0), "timeSinceSeriesStart") })},
		{"beat without gap", "beats[1].precededByGap is required", with(heartbeats, func(o obj) { delete(at(o, "beats", 1), "precededByGap") })},
		{"gap as number", "beats[2].precededByGap must be true or false", with(heartbeats, func(o obj) { at(o, "beats", 2)["precededByGap"] = 1 })},
		{"heartbeat type", "type must be \"HKDataTypeIdentifierHeartbeatSeries\"", with(heartbeats, func(o obj) { o["type"] = "HKQuantityTypeIdentifierHeartRate" })},

		// Audiogram.
		{"audiogram without end", "object.endDate is required", with(audiogram, func(o obj) { delete(o, "endDate") })},
		{"no points", "object.sensitivityPoints is required", with(audiogram, func(o obj) { delete(o, "sensitivityPoints") })},
		{"empty points", "sensitivityPoints must be a non-empty array", with(audiogram, func(o obj) { o["sensitivityPoints"] = []any{} })},
		{"no frequency", "sensitivityPoints[0].frequency is required", with(audiogram, func(o obj) { delete(at(o, "sensitivityPoints", 0), "frequency") })},
		{"frequency number", "sensitivityPoints[0].frequency must be", with(audiogram, func(o obj) { at(o, "sensitivityPoints", 0)["frequency"] = 1000 })},
		{"no tests", "sensitivityPoints[0].tests must be a non-empty array", with(audiogram, func(o obj) { at(o, "sensitivityPoints", 0)["tests"] = []any{} })},
		{"no sensitivity", "tests[0].sensitivity is required", with(audiogram, func(o obj) { delete(at(o, "sensitivityPoints", 0, "tests", 0), "sensitivity") })},
		{"conduction type", "tests[0].type must be an HKAudiogramConductionType", with(audiogram, func(o obj) { at(o, "sensitivityPoints", 0, "tests", 0)["type"] = -1 })},
		{"no masked", "tests[0].masked is required", with(audiogram, func(o obj) { delete(at(o, "sensitivityPoints", 0, "tests", 0), "masked") })},
		{"side 2", "tests[1].side must be an HKAudiogramSensitivityTestSide raw value: 0 left, 1 right", with(audiogram, func(o obj) { at(o, "sensitivityPoints", 0, "tests", 1)["side"] = 2 })},
		{"no side", "tests[0].side", with(audiogram, func(o obj) { delete(at(o, "sensitivityPoints", 0, "tests", 0), "side") })},
		{"empty clamping range", "clampingRange must be an object with lowerBound, upperBound or both", with(audiogram, func(o obj) {
			at(o, "sensitivityPoints", 0, "tests", 1)["clampingRange"] = obj{}
		})},
		{"clamping bound number", "clampingRange.upperBound must be", with(audiogram, func(o obj) {
			at(o, "sensitivityPoints", 0, "tests", 1)["clampingRange"] = obj{"upperBound": 100}
		})},

		// Scored assessments.
		{"GAD-7 short", "answers must have 7 answers for GAD-7", assessment(gad7Type, 0, 0, 0, 0, 0, 0)},
		{"GAD-7 nine answers", "answers must have 7 answers for GAD-7", assessment(gad7Type, 0, 0, 0, 0, 0, 0, 0, 0, 0)},
		{"GAD-7 declined", "answers[6] must be an integer from 0 to 3", assessment(gad7Type, 0, 0, 0, 0, 0, 0, 4)},
		{"PHQ-9 short", "answers must have 9 answers for PHQ-9", assessment(phq9Type, 0, 0, 0, 0, 0, 0, 0)},
		{"PHQ-9 declined early", "answers[0] must be an integer from 0 to 3", assessment(phq9Type, 4, 0, 0, 0, 0, 0, 0, 0, 0)},
		{"PHQ-9 last 5", "answers[8] must be an integer from 0 to 4", assessment(phq9Type, 0, 0, 0, 0, 0, 0, 0, 0, 5)},
		{"negative answer", "answers[2] must be an integer", assessment(gad7Type, 0, 0, -1, 0, 0, 0, 0)},
		{"answers names", "answers[0] must be an integer", with(gad7, func(o obj) { o["answers"] = []any{"notAtAll", 0, 0, 0, 0, 0, 0} })},
		{"no answers", "object.answers is required", with(gad7, func(o obj) { delete(o, "answers") })},
		{"score", "score is read-only", with(gad7, func(o obj) { o["score"] = 9 })},
		{"risk", "risk is read-only", with(phq9, func(o obj) { o["risk"] = 2 })},
		{"assessment end", "endDate must equal startDate", with(gad7, func(o obj) { o["endDate"] = t1 })},
		{"assessment no start", "startDate is required", with(gad7, func(o obj) { delete(o, "startDate") })},
		{"assessment type", "type must be \"" + gad7Type + "\" or \"" + phq9Type + "\"", with(gad7, func(o obj) { o["type"] = "HKScoredAssessmentTypeIdentifierPCL5" })},

		// Vision prescriptions.
		{"prescription startDate", "object.startDate is set by HealthKit; omit it", with(glasses, func(o obj) { o["startDate"] = t0 })},
		{"prescription endDate", "object.endDate is set by HealthKit; omit it", with(contacts, func(o obj) { o["endDate"] = t0 })},
		{"prescription type 3", "prescriptionType must be an HKVisionPrescriptionType raw value: 1 glasses, 2 contacts", with(glasses, func(o obj) { o["prescriptionType"] = 3 })},
		{"no prescription type", "object.prescriptionType is required", with(glasses, func(o obj) { delete(o, "prescriptionType") })},
		{"no dateIssued", "dateIssued is required", with(glasses, func(o obj) { delete(o, "dateIssued") })},
		{"bad expiration", "expirationDate", with(glasses, func(o obj) { o["expirationDate"] = "2028" })},
		{"no eyes", "give rightEye, leftEye or both", with(contacts, func(o obj) { delete(o, "leftEye") })},
		{"no sphere", "leftEye.sphere is required", with(glasses, func(o obj) { delete(at(o, "leftEye"), "sphere") })},
		{"cylinder number", "rightEye.cylinder must be", with(glasses, func(o obj) { at(o, "rightEye")["cylinder"] = -0.5 })},
		{"glasses brand", "brand is only for contacts", with(glasses, func(o obj) { o["brand"] = "Zeiss" })},
		{"contacts without brand", "brand is required for contacts", with(contacts, func(o obj) { delete(o, "brand") })},
		{"contacts vertex distance", "leftEye.vertexDistance is only for glasses", with(contacts, func(o obj) { at(o, "leftEye")["vertexDistance"] = qty(12, "mm") })},
		{"contacts prism", "leftEye.prism is only for glasses", with(contacts, func(o obj) { at(o, "leftEye")["prism"] = at(glasses(), "rightEye", "prism") })},
		{"glasses base curve", "rightEye.baseCurve is only for contacts", with(glasses, func(o obj) { at(o, "rightEye")["baseCurve"] = qty(8.4, "mm") })},
		{"glasses diameter", "leftEye.diameter is only for contacts", with(glasses, func(o obj) { at(o, "leftEye")["diameter"] = qty(14, "mm") })},
		{"prism both", "give either amount and angle", with(glasses, func(o obj) { at(o, "rightEye", "prism")["verticalBase"] = 1 })},
		{"prism neither", "give either amount and angle", with(glasses, func(o obj) { at(o, "rightEye")["prism"] = obj{"eye": 2} })},
		{"prism no angle", "rightEye.prism.angle is required", with(glasses, func(o obj) { delete(at(o, "rightEye", "prism"), "angle") })},
		{"prism no horizontal base", "leftEye.prism.horizontalBase is required", with(glasses, func(o obj) { delete(at(o, "leftEye", "prism"), "horizontalBase") })},
		{"prism base 5", "leftEye.prism.verticalBase must be an HKPrismBase", with(glasses, func(o obj) { at(o, "leftEye", "prism")["verticalBase"] = 5 })},
		{"prism no vertical amount", "leftEye.prism.verticalAmount is required", with(glasses, func(o obj) { delete(at(o, "leftEye", "prism"), "verticalAmount") })},
		{"prism eye 3", "rightEye.prism.eye must be an HKVisionEye raw value: 1 left, 2 right", with(glasses, func(o obj) { at(o, "rightEye", "prism")["eye"] = 3 })},
		{"prism no eye", "leftEye.prism.eye is required", with(glasses, func(o obj) { delete(at(o, "leftEye", "prism"), "eye") })},
		{"attachments", "attachments is read-only", with(contacts, func(o obj) { o["attachments"] = []any{} })},

		// CDA documents: not supported.
		{"document", "object.kind \"cdaDocument\" can't be written: Rendu doesn't read or write clinical documents", cda()},

		// Metadata anywhere.
		{"null metadata", "metadata must be an object", with(gad7, func(o obj) { o["metadata"] = nil })},
	} {
		err := validate(c.o)
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: %v, want %q", c.name, err, c.want)
		}
	}
}

func TestObjectTypes(t *testing.T) {
	noRoute := with(run, func(o obj) { delete(o, "route") })
	for _, c := range []struct {
		o    obj
		want string
	}{
		{run(), "[HKWorkoutTypeIdentifier HKQuantityTypeIdentifierActiveEnergyBurned HKQuantityTypeIdentifierWorkoutEffortScore HKWorkoutRouteTypeIdentifier]"},
		{noRoute, "[HKWorkoutTypeIdentifier HKQuantityTypeIdentifierActiveEnergyBurned HKQuantityTypeIdentifierWorkoutEffortScore]"},
		{heartRateSeries(), "[HKQuantityTypeIdentifierHeartRate]"},
		{glasses(), "[HKVisionPrescriptionTypeIdentifier]"},
		{phq9(), "[" + phq9Type + "]"},
	} {
		raw, _ := json.Marshal(c.o)
		if got := fmt.Sprint(objectTypes(raw)); got != c.want {
			t.Errorf("objectTypes(%s) = %s, want %s", c.o["type"], got, c.want)
		}
	}
}
