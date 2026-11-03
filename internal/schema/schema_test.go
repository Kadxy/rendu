package schema

import (
	"regexp"
	"testing"
)

// The generated file against values from Apple's documentation, so a bad
// regeneration (gen_healthkit_schema.py) fails here.
func TestKnownValues(t *testing.T) {
	if !regexp.MustCompile(`^\d+\.\d+$`).MatchString(Version()) {
		t.Errorf("SDK version %q", Version())
	}
	for _, c := range []struct {
		enum, short string
		value       int64
	}{
		{"HKWorkoutActivityType", "traditionalStrengthTraining", 50},
		{"HKWorkoutActivityType", "running", 37},
		{"HKWorkoutActivityType", "other", 3000},
		{"HKStateOfMind.Label", "stressed", 29},
		{"HKStateOfMindLabel", "stressed", 29},
		{"HKStateOfMind.Association", "work", 17},
		{"HKWorkoutEventType", "lap", 3},
		{"HKWorkoutEventType", "pauseOrResumeRequest", 8},
		{"HKCategoryValueSleepAnalysis", "inBed", 0},
		{"HKCategoryValueSleepAnalysis", "asleepREM", 5},
		{"HKStatisticsOptions", "cumulativeSum", 1 << 4},      // 1 << n
		{"HKStatisticsOptions", "discreteMostRecent", 1 << 5}, // a reference to an earlier case
		{"HKCategoryValueOvulationTestResult", "estrogenSurge", 4},
		{"HKFitzpatrickSkinType", "I", 1},
		{"HKBloodType", "abPositive", 5},
		{"HKAppleWalkingSteadinessClassification", "ok", 1}, // NS_SWIFT_NAME on the case
		{"HKPHQ9Assessment.Answer", "preferNotToAnswer", 4},
		{"HKVisionEye", "right", 2},
	} {
		e, ok := LookupEnum(c.enum)
		if !ok {
			t.Errorf("no enum %s", c.enum)
			continue
		}
		if got, ok := e.Case(c.short); !ok || got.Value != c.value {
			t.Errorf("%s.%s = %v (found %v), want %d", c.enum, c.short, got.Value, ok, c.value)
		}
	}

	activity, _ := LookupEnum("HKWorkoutActivityType")
	if _, ok := activity.Case("rest"); ok || activity.Has(2998) {
		t.Error("HKWorkoutActivityTypeRest is unavailable on iOS but listed")
	}
	if c, _ := activity.Case("dance"); !c.Deprecated {
		t.Errorf("dance = %+v, want deprecated", c)
	}
	if label, _ := LookupEnum("HKStateOfMind.Label"); label.Name != "HKStateOfMindLabel" || label.SwiftName != "HKStateOfMind.Label" || len(label.Cases) != 38 {
		t.Errorf("label = %s / %s, %d cases", label.Name, label.SwiftName, len(label.Cases))
	}
	if options, _ := LookupEnum("HKStatisticsOptions"); !options.Options {
		t.Error("HKStatisticsOptions is NS_OPTIONS")
	}
	sleep, _ := LookupEnum("HKCategoryValueSleepAnalysis")
	if c, _ := sleep.Case("asleepCore"); c.Doc != "Corresponds to Stages 1 and 2 of AASM scoring model." || c.Available != "16.0" {
		t.Errorf("asleepCore = %+v", c)
	}
}

func TestTypes(t *testing.T) {
	for id, want := range map[string]Type{
		"HKQuantityTypeIdentifierBodyFatPercentage": {Kind: "quantity", Available: "8.0", Note: "%, Discrete (Arithmetic)", Aggregation: "discreteArithmetic"},
		"HKQuantityTypeIdentifierStepCount":         {Kind: "quantity", Available: "8.0", Note: "count, Cumulative", Aggregation: "cumulative"},
		"HKQuantityTypeIdentifierHeartRate":         {Kind: "quantity", Available: "8.0", Note: "count/s, Discrete (Temporally Weighted)", Aggregation: "discreteTemporallyWeighted"},
		"HKCategoryTypeIdentifierSleepAnalysis":     {Kind: "category", Available: "8.0", Note: "HKCategoryValueSleepAnalysis", Values: "HKCategoryValueSleepAnalysis"},
		"HKCategoryTypeIdentifierMindfulSession":    {Kind: "category", Available: "10.0", Note: "HKCategoryValue", Values: "HKCategoryValue"},
		"HKCorrelationTypeIdentifierFood":           {Kind: "correlation", Available: "8.0"},
		"HKWorkoutTypeIdentifier":                   {Kind: "workout", Available: "8.0"},
		"HKDocumentTypeIdentifierCDA":               {Kind: "cdaDocument", Available: "10.0"},
		"HKScoredAssessmentTypeIdentifierPHQ9":      {Kind: "scoredAssessment", Available: "18.0"},
		"HKDataTypeIdentifierAudiogram":             {Kind: "audiogram", Factory: "audiogramSampleType", Available: "13.0"},
	} {
		got, typ, ok := LookupType(id)
		if !ok || got != id || typ != want {
			t.Errorf("%s = %+v (%v), want %+v", id, typ, ok, want)
		}
	}
	// Keyed by value; the constant's name finds it too.
	for constant, value := range map[string]string{
		"HKDataTypeIdentifierStateOfMind":                         "HKDataTypeStateOfMind",
		"HKCategoryTypeIdentifierEnvironmentalAudioExposureEvent": "HKCategoryTypeIdentifierAudioExposureEvent",
	} {
		got, typ, ok := LookupType(constant)
		if !ok || got != value || typ.Constant != constant {
			t.Errorf("%s = %s %+v %v, want %s", constant, got, typ, ok, value)
		}
	}
	quantity, category := 0, 0
	for _, id := range TypeIDs() {
		_, typ, _ := LookupType(id)
		switch typ.Kind {
		case "quantity":
			quantity++
		case "category":
			category++
		}
	}
	if quantity < 120 || category < 71 {
		t.Errorf("%d quantity, %d category types", quantity, category)
	}
}

func TestMetadataKeys(t *testing.T) {
	for _, name := range []string{"HKFoodType", "HKMetadataKeyFoodType"} {
		m, ok := LookupMetadataKey(name)
		if !ok || m.Key != "HKFoodType" || m.Constant != "HKMetadataKeyFoodType" || m.ValueType != "NSString" || m.Available != "8.0" {
			t.Errorf("%s = %+v %v", name, m, ok)
		}
	}
	if m, _ := LookupMetadataKey("HKMetadataKeyHeartRateMotionContext"); m.ValueType != "NSNumber" || m.Values != "HKHeartRateMotionContext" {
		t.Errorf("motion context = %+v", m)
	}
	if m, _ := LookupMetadataKey("HKMetadataKeySyncIdentifier"); m.Key != "HKMetadataKeySyncIdentifier" {
		t.Errorf("sync identifier = %+v", m)
	}
	if len(MetadataKeys()) < 70 {
		t.Errorf("%d metadata keys", len(MetadataKeys()))
	}
}
