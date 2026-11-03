package store

import (
	"encoding/json"
	"time"
)

// Object formats (docs/PROTOCOL.md, "Object format"): one declarative table for
// every kind. Validation reads it (objects.go: which fields exist, read-only
// ones, required ones, their types and enums) and the server serves it
// (GET /v1/schema/kinds/{kind}), so the two can't disagree. Rules the table
// can't express are checked in code, and each is stated in its field's
// description.

// Field types.
const (
	TypeTimestamp = "timestamp" // ISO 8601 with a UTC offset
	TypeQuantity  = "quantity"  // {"value": number, "unit": HKUnit string}
	TypeInteger   = "integer"
	TypeNumber    = "number"
	TypeString    = "string"
	TypeUUID      = "uuid"
	TypeBoolean   = "boolean"
	TypeObject    = "object" // with Fields, or free-form
	TypeArray     = "array"  // of Items
)

// Field is one member of an object format.
type Field struct {
	Name string
	Type string
	// Items is the type of an array's items; ItemKind, for items that are
	// objects of a kind (validated as such).
	Items    string
	ItemKind string
	// Required: always. RequiredWhen: the condition, in words, when it
	// depends on the role or on other fields (checked in code).
	Required     bool
	RequiredWhen string
	// ReadOnly fields are in what's read and refused on write; WriteOnly
	// ones exist only for writing.
	ReadOnly  bool
	WriteOnly bool
	// Enum names the SDK enum (GET /v1/schema/enums/{name}) an integer, or
	// each integer item, is a raw value of; validation checks it is one.
	Enum        string
	Description string
	// Fields are an object's members, or an array's object items'.
	Fields []Field
	// refused ends the 400 error for a read-only field (after the path)
	// when it isn't "is read-only; omit it".
	refused string
}

func (f Field) MarshalJSON() ([]byte, error) {
	out := struct {
		Name        string  `json:"name"`
		Type        string  `json:"type"`
		Items       string  `json:"items,omitempty"`
		ItemKind    string  `json:"itemKind,omitempty"`
		Required    any     `json:"required,omitempty"`
		ReadOnly    bool    `json:"readOnly,omitempty"`
		WriteOnly   bool    `json:"writeOnly,omitempty"`
		Enum        string  `json:"enum,omitempty"`
		Description string  `json:"description"`
		Fields      []Field `json:"fields,omitempty"`
	}{f.Name, f.Type, f.Items, f.ItemKind, nil, f.ReadOnly, f.WriteOnly, f.Enum, f.Description, f.Fields}
	if f.Required {
		out.Required = true
	} else if f.RequiredWhen != "" {
		out.Required = f.RequiredWhen
	}
	return json.Marshal(out)
}

// Kind is one row of the capability table (docs/PROTOCOL.md, "Read and write capabilities")
// and, for samples, its object format.
type Kind struct {
	Kind  string `json:"kind"`
	Class string `json:"class"`
	// The kind's types: those with TypePrefix, or Types.
	TypePrefix string   `json:"typePrefix,omitempty"`
	Types      []string `json:"types,omitempty"`
	// Read: the phone uploads it (GET /v1/samples, or the endpoint How
	// names). Write: POST /v1/writes takes it.
	Read  bool   `json:"read"`
	Write bool   `json:"write"`
	How   string `json:"how"`
	// Fields of a sample kind, and an example: an object to write, or for
	// a kind that can't be written one as read.
	Fields  []Field         `json:"fields,omitempty"`
	Example json.RawMessage `json:"example,omitempty"`
	// typeExamples replace Example for types it doesn't fit.
	typeExamples map[string]json.RawMessage
	dates        dateRule
	// refusal is why a write of the kind is refused.
	refusal string
}

// dateRule is which of startDate and endDate a kind's write gives.
type dateRule int

const (
	startAndEnd dateRule = iota // both
	memberDates                 // both, but a correlation member may omit them
	moment                      // startDate; endDate only as its echo
	startOnly                   // HealthKit sets endDate: a heartbeat series ends at its last beat
	noDates                     // HealthKit sets both: a prescription has dateIssued instead
)

const (
	workoutType       = "HKWorkoutTypeIdentifier"
	workoutRouteType  = "HKWorkoutRouteTypeIdentifier"
	gad7Type          = "HKScoredAssessmentTypeIdentifierGAD7"
	phq9Type          = "HKScoredAssessmentTypeIdentifierPHQ9"
	correlationPrefix = "HKCorrelationTypeIdentifier"
)

// reservedMetadata are keys the app owns: it derives them from
// syncIdentifier/syncVersion.
var reservedMetadata = []string{"HKMetadataKeySyncIdentifier", "HKMetadataKeySyncVersion"}

// Fields every sample has, around its kind's own.
var (
	uuidField = Field{Name: "uuid", Type: TypeUUID, ReadOnly: true, refused: "is assigned by HealthKit; omit it",
		Description: "HKObject.uuid, which reads deduplicate on."}
	sourceRevisionField = Field{Name: "sourceRevision", Type: TypeObject, ReadOnly: true,
		Description: "HKSourceRevision: the app and device that saved the sample.",
		Fields: []Field{
			{Name: "source", Type: TypeObject, Description: "HKSource.", Fields: []Field{
				{Name: "name", Type: TypeString, Description: "The app's name."},
				{Name: "bundleIdentifier", Type: TypeString, Description: "The app's bundle identifier; Rendu's is the one it was built with (RENDU_BUNDLE_ID)."},
			}},
			{Name: "version", Type: TypeString, Description: "The app's version."},
			{Name: "productType", Type: TypeString, Description: "The device model, e.g. Watch7,1."},
			{Name: "operatingSystemVersion", Type: TypeString, Description: "major.minor.patch."},
		}}
	deviceField = Field{Name: "device", Type: TypeObject, ReadOnly: true,
		Description: "HKDevice: its fields that have values.",
		Fields: []Field{
			{Name: "name", Type: TypeString, Description: "HKDevice.name."},
			{Name: "manufacturer", Type: TypeString, Description: "HKDevice.manufacturer."},
			{Name: "model", Type: TypeString, Description: "HKDevice.model."},
			{Name: "hardwareVersion", Type: TypeString, Description: "HKDevice.hardwareVersion."},
			{Name: "firmwareVersion", Type: TypeString, Description: "HKDevice.firmwareVersion."},
			{Name: "softwareVersion", Type: TypeString, Description: "HKDevice.softwareVersion."},
			{Name: "localIdentifier", Type: TypeString, Description: "HKDevice.localIdentifier."},
			{Name: "UDIDeviceIdentifier", Type: TypeString, Description: "HKDevice.udiDeviceIdentifier."},
		}}
	metadataField = Field{Name: "metadata", Type: TypeObject,
		Description: "HealthKit metadata by key (GET /v1/schema/metadata/{key}, e.g. HKWasUserEntered) or your own; " +
			"written values are strings, numbers or booleans, and HKMetadataKeySyncIdentifier and HKMetadataKeySyncVersion are the app's."}
)

// sampleFields are a sample kind's fields: the common ones, its dates by
// rule, and its own.
func sampleFields(rule dateRule, own ...Field) []Field {
	start := Field{Name: "startDate", Type: TypeTimestamp, Required: true, Description: "HKSample.startDate."}
	end := Field{Name: "endDate", Type: TypeTimestamp, Required: true,
		Description: "HKSample.endDate: not before startDate, equal to it for an instant."}
	switch rule {
	case memberDates:
		const when = "except in a correlation's objects, where it defaults to the correlation's"
		start.Required, start.RequiredWhen = false, when
		end.Required, end.RequiredWhen = false, when
	case moment:
		end.Required = false
		end.Description = "Equal to startDate (this is a moment); may be left out when writing."
	case startOnly:
		end = Field{Name: "endDate", Type: TypeTimestamp, ReadOnly: true, refused: "is set by HealthKit (the last beat); omit it",
			Description: "Set by HealthKit: the last beat's time."}
	case noDates:
		start = Field{Name: "startDate", Type: TypeTimestamp, ReadOnly: true, refused: "is set by HealthKit; omit it",
			Description: "Set by HealthKit."}
		end = Field{Name: "endDate", Type: TypeTimestamp, ReadOnly: true, refused: "is set by HealthKit; omit it",
			Description: "Set by HealthKit."}
	}
	fields := []Field{
		uuidField,
		{Name: "kind", Type: TypeString, Required: true, Description: "The kind, which the type must belong to."},
		{Name: "type", Type: TypeString, Required: true, Description: "HKObjectType.identifier."},
		start, end,
	}
	fields = append(fields, own...)
	return append(fields, sourceRevisionField, deviceField, metadataField)
}

func quantityField(name, desc string) Field {
	return Field{Name: name, Type: TypeQuantity, Description: desc}
}

var activityConfiguration = []Field{
	{Name: "activityType", Type: TypeInteger, Enum: "HKWorkoutActivityType",
		RequiredWhen: "unless activityTypeName is given; give exactly one", Description: "HKWorkoutActivityType raw value."},
	{Name: "activityTypeName", Type: TypeString, RequiredWhen: "unless activityType is given; give exactly one",
		Description: "HKWorkoutActivityType case name (the enum's short names), e.g. cycling; activity_<n> for a deprecated raw value n."},
	{Name: "locationType", Type: TypeInteger, Enum: "HKWorkoutSessionLocationType", Description: "Indoor or outdoor."},
	{Name: "swimmingLocationType", Type: TypeInteger, Enum: "HKWorkoutSwimmingLocationType", Description: "Pool or open water."},
	quantityField("lapLength", "A pool's length, e.g. 25 m."),
}

// location is a route's point (CLLocation).
var location = []Field{
	{Name: "timestamp", Type: TypeTimestamp, Required: true, Description: "When the location was recorded; inside the workout when writing."},
	{Name: "latitude", Type: TypeNumber, Required: true, Description: "Degrees from -90 to 90 (WGS 84, as GPS gives it)."},
	{Name: "longitude", Type: TypeNumber, Required: true, Description: "Degrees from -180 to 180 (WGS 84)."},
	{Name: "altitude", Type: TypeNumber, Description: "Meters."},
	{Name: "horizontalAccuracy", Type: TypeNumber, Description: "Meters."},
	{Name: "verticalAccuracy", Type: TypeNumber, Description: "Meters."},
	{Name: "speed", Type: TypeNumber, Description: "Meters per second."},
	{Name: "course", Type: TypeNumber, Description: "Degrees from true north."},
}

// lens is an eye's HKGlassesLensSpecification or HKContactsLensSpecification.
var lens = []Field{
	{Name: "sphere", Type: TypeQuantity, Required: true, Description: "Spherical power in diopters (D), negative for nearsightedness."},
	quantityField("cylinder", "Cylindrical power (astigmatism), D."),
	quantityField("axis", "Cylinder axis, deg."),
	quantityField("addPower", "Added power for near vision, D."),
	quantityField("vertexDistance", "Glasses only: distance from the eye, mm."),
	{Name: "prism", Type: TypeObject, Description: "Glasses only: HKVisionPrism, as amount and angle or as vertical and horizontal parts.",
		Fields: []Field{
			{Name: "amount", Type: TypeQuantity, RequiredWhen: "with angle, unless the vertical and horizontal parts are given", Description: "Prism diopters (pD)."},
			{Name: "angle", Type: TypeQuantity, RequiredWhen: "with amount", Description: "Base direction, deg."},
			{Name: "verticalAmount", Type: TypeQuantity, RequiredWhen: "with verticalBase, horizontalAmount and horizontalBase, unless amount and angle are given", Description: "pD."},
			{Name: "verticalBase", Type: TypeInteger, Enum: "HKPrismBase", RequiredWhen: "with verticalAmount", Description: "Up or down."},
			{Name: "horizontalAmount", Type: TypeQuantity, RequiredWhen: "with verticalAmount", Description: "pD."},
			{Name: "horizontalBase", Type: TypeInteger, Enum: "HKPrismBase", RequiredWhen: "with verticalAmount", Description: "In or out."},
			{Name: "eye", Type: TypeInteger, Enum: "HKVisionEye", Required: true, Description: "The eye the prism is for."},
		}},
	quantityField("farPupillaryDistance", "Glasses only: pupillary distance for far vision, mm."),
	quantityField("nearPupillaryDistance", "Glasses only: pupillary distance for near vision, mm."),
	quantityField("baseCurve", "Contacts only: base curve, mm."),
	quantityField("diameter", "Contacts only: diameter, mm."),
}

// Lens fields only glasses or only contacts have.
var (
	glassesFields  = []string{"vertexDistance", "prism", "farPupillaryDistance", "nearPupillaryDistance"}
	contactsFields = []string{"baseCurve", "diameter"}
)

var kindList = []Kind{
	{
		Kind: "quantity", Class: "HKQuantitySample", TypePrefix: "HKQuantityTypeIdentifier",
		Read: true, Write: true, dates: memberDates,
		How: "Read with HKAnchoredObjectQuery, a series' values with HKQuantitySeriesSampleQuery; written with HKHealthStore.save, a series with HKQuantitySeriesSampleBuilder.",
		Fields: sampleFields(memberDates,
			Field{Name: "quantity", Type: TypeQuantity,
				RequiredWhen: "unless series is given (give exactly one); always in a correlation's objects and a workout's samples",
				Description:  "The value in a unit the type takes (writes take any compatible HKUnit; reads use the type's unit); a series sample's sum or average."},
			Field{Name: "count", Type: TypeInteger, ReadOnly: true, Description: "HKQuantitySample.count: how many values a series sample holds; only when more than 1."},
			Field{Name: "series", Type: TypeArray, Items: TypeObject, RequiredWhen: "unless quantity is given (give exactly one)",
				Description: "Every value of a series sample: non-empty, each inside the sample's startDate and endDate; only for a sample of its own, not in a correlation or a workout.",
				Fields: []Field{
					{Name: "quantity", Type: TypeQuantity, Required: true, Description: "The value."},
					{Name: "startDate", Type: TypeTimestamp, Required: true, Description: "Its start."},
					{Name: "endDate", Type: TypeTimestamp, Required: true, Description: "Its end, not before its start."},
				}},
			Field{Name: "minimumQuantity", Type: TypeQuantity, ReadOnly: true, Description: "A discrete series' minimum (HKDiscreteQuantitySample)."},
			Field{Name: "maximumQuantity", Type: TypeQuantity, ReadOnly: true, Description: "A discrete series' maximum."},
			Field{Name: "mostRecentQuantity", Type: TypeQuantity, ReadOnly: true, Description: "A discrete series' most recent value."},
			Field{Name: "mostRecentQuantityDateInterval", Type: TypeObject, ReadOnly: true, Description: "When the most recent value was.",
				Fields: []Field{
					{Name: "startDate", Type: TypeTimestamp, Description: "Its start."},
					{Name: "endDate", Type: TypeTimestamp, Description: "Its end."},
				}},
		),
		Example: json.RawMessage(`{"kind": "quantity", "type": "HKQuantityTypeIdentifierBodyMass",
			"startDate": "2026-11-01T08:00:00+08:00", "endDate": "2026-11-01T08:00:00+08:00",
			"quantity": {"value": 72.5, "unit": "kg"}, "metadata": {"HKWasUserEntered": true}}`),
	},
	{
		Kind: "category", Class: "HKCategorySample", TypePrefix: "HKCategoryTypeIdentifier",
		Read: true, Write: true,
		How: "Read with HKAnchoredObjectQuery; written with HKHealthStore.save.",
		Fields: sampleFields(startAndEnd,
			Field{Name: "value", Type: TypeInteger, Required: true,
				Description: "HKCategorySample.value: a raw value of the type's value enum (its values in GET /v1/schema/types/{type})."},
			Field{Name: "valueName", Type: TypeString, ReadOnly: true,
				Description: "The value's case name, e.g. asleepREM; for sleep analysis, stand hours, and symptom severity and presence types."},
		),
		Example: json.RawMessage(`{"kind": "category", "type": "HKCategoryTypeIdentifierMindfulSession",
			"startDate": "2026-11-01T22:00:00+08:00", "endDate": "2026-11-01T22:10:00+08:00", "value": 0}`),
	},
	{
		Kind: "correlation", Class: "HKCorrelation", TypePrefix: correlationPrefix,
		Read: true, Write: true,
		How: "Written with HKHealthStore.save; its members are quantity samples, read also as samples of their own types.",
		Fields: sampleFields(startAndEnd,
			Field{Name: "objects", Type: TypeArray, Items: TypeObject, ItemKind: "quantity", Required: true,
				Description: "Written: the member quantity samples, non-empty, dates defaulting to the correlation's (a meal's HKFoodType goes on each member). Read: the members' uuids."},
		),
		Example: json.RawMessage(`{"kind": "correlation", "type": "HKCorrelationTypeIdentifierFood",
			"startDate": "2026-11-01T12:30:00+08:00", "endDate": "2026-11-01T12:30:00+08:00",
			"metadata": {"HKFoodType": "Beef noodle soup"},
			"objects": [
				{"kind": "quantity", "type": "HKQuantityTypeIdentifierDietaryEnergyConsumed", "quantity": {"value": 650, "unit": "kcal"}},
				{"kind": "quantity", "type": "HKQuantityTypeIdentifierDietaryProtein", "quantity": {"value": 32, "unit": "g"}}]}`),
		typeExamples: map[string]json.RawMessage{
			"HKCorrelationTypeIdentifierBloodPressure": json.RawMessage(`{"kind": "correlation", "type": "HKCorrelationTypeIdentifierBloodPressure",
				"startDate": "2026-11-01T08:00:00+08:00", "endDate": "2026-11-01T08:00:00+08:00",
				"objects": [
					{"kind": "quantity", "type": "HKQuantityTypeIdentifierBloodPressureSystolic", "quantity": {"value": 118, "unit": "mmHg"}},
					{"kind": "quantity", "type": "HKQuantityTypeIdentifierBloodPressureDiastolic", "quantity": {"value": 76, "unit": "mmHg"}}]}`),
		},
	},
	{
		Kind: "workout", Class: "HKWorkout", Types: []string{workoutType},
		Read: true, Write: true,
		How: "Written with HKWorkoutBuilder (samples, activities, events), its route with HKWorkoutRouteBuilder, an effort score related with relateWorkoutEffortSample.",
		Fields: sampleFields(startAndEnd,
			Field{Name: "workoutActivityType", Type: TypeInteger, Enum: "HKWorkoutActivityType",
				RequiredWhen: "unless workoutActivityTypeName is given; give exactly one", Description: "HKWorkoutActivityType raw value, e.g. 37 (running)."},
			Field{Name: "workoutActivityTypeName", Type: TypeString, RequiredWhen: "unless workoutActivityType is given; give exactly one",
				Description: "HKWorkoutActivityType case name (the enum's short names), e.g. traditionalStrengthTraining; activity_<n> for a deprecated raw value n."},
			Field{Name: "duration", Type: TypeNumber, ReadOnly: true, Description: "Seconds."},
			Field{Name: "statistics", Type: TypeObject, ReadOnly: true,
				Description: "HKWorkout.allStatistics by quantity type: sumQuantity, averageQuantity, minimumQuantity, maximumQuantity, in the type's read unit."},
			Field{Name: "workoutActivities", Type: TypeArray, Items: TypeObject,
				Description: "HKWorkoutActivity: the parts of a multisport or interval workout, each inside the workout.",
				Fields: []Field{
					{Name: "uuid", Type: TypeUUID, ReadOnly: true, Description: "HKWorkoutActivity.uuid."},
					{Name: "workoutConfiguration", Type: TypeObject, Required: true, Description: "HKWorkoutConfiguration.", Fields: activityConfiguration},
					{Name: "startDate", Type: TypeTimestamp, Required: true, Description: "Inside the workout."},
					{Name: "endDate", Type: TypeTimestamp, Description: "Not before startDate and inside the workout; leave it out for an activity without an end."},
					{Name: "duration", Type: TypeNumber, ReadOnly: true, Description: "Seconds."},
					{Name: "statistics", Type: TypeObject, ReadOnly: true, Description: "The activity's statistics, as the workout's."},
					metadataField,
				}},
			Field{Name: "workoutEvents", Type: TypeArray, Items: TypeObject,
				Description: "HKWorkoutEvent: pauses, laps, segments and markers, each inside the workout.",
				Fields: []Field{
					{Name: "type", Type: TypeInteger, Enum: "HKWorkoutEventType", Required: true,
						Description: "Only lap (3) and segment (7) events last; the others' endDate equals their startDate."},
					{Name: "startDate", Type: TypeTimestamp, Required: true, Description: "Inside the workout."},
					{Name: "endDate", Type: TypeTimestamp, Required: true, Description: "Not before startDate and inside the workout."},
					metadataField,
				}},
			Field{Name: "effortRelationships", Type: TypeArray, Items: TypeObject, ReadOnly: true,
				Description: "HKWorkoutEffortRelationship: the effort scores related to the workout.",
				Fields: []Field{
					{Name: "samples", Type: TypeArray, Items: TypeUUID, Description: "The effort score samples' uuids."},
					{Name: "activityUUID", Type: TypeUUID, Description: "The workout activity the scores are for, if any."},
				}},
			Field{Name: "samples", Type: TypeArray, Items: TypeObject, ItemKind: "quantity", WriteOnly: true,
				Description: "Quantity samples added to the workout, each with startDate and endDate inside it; HealthKit computes statistics from them, and relates an HKQuantityTypeIdentifierWorkoutEffortScore sample (appleEffortScore 1–10) instead."},
			Field{Name: "route", Type: TypeArray, Items: TypeObject, WriteOnly: true, Fields: location,
				Description: "The route, non-empty; read back as a workoutRoute sample of its own."},
		),
		Example: json.RawMessage(`{"kind": "workout", "type": "HKWorkoutTypeIdentifier",
			"startDate": "2026-11-02T07:00:00+08:00", "endDate": "2026-11-02T07:30:00+08:00",
			"workoutActivityTypeName": "running", "metadata": {"HKIndoorWorkout": false},
			"workoutEvents": [
				{"type": 3, "startDate": "2026-11-02T07:00:00+08:00", "endDate": "2026-11-02T07:14:40+08:00"},
				{"type": 3, "startDate": "2026-11-02T07:14:40+08:00", "endDate": "2026-11-02T07:30:00+08:00"}],
			"samples": [
				{"kind": "quantity", "type": "HKQuantityTypeIdentifierDistanceWalkingRunning",
				 "startDate": "2026-11-02T07:00:00+08:00", "endDate": "2026-11-02T07:30:00+08:00", "quantity": {"value": 5, "unit": "km"}},
				{"kind": "quantity", "type": "HKQuantityTypeIdentifierActiveEnergyBurned",
				 "startDate": "2026-11-02T07:00:00+08:00", "endDate": "2026-11-02T07:30:00+08:00", "quantity": {"value": 310, "unit": "kcal"}},
				{"kind": "quantity", "type": "HKQuantityTypeIdentifierWorkoutEffortScore",
				 "startDate": "2026-11-02T07:00:00+08:00", "endDate": "2026-11-02T07:30:00+08:00", "quantity": {"value": 6, "unit": "appleEffortScore"}}],
			"route": [
				{"timestamp": "2026-11-02T07:00:00+08:00", "latitude": 31.2304, "longitude": 121.4737, "altitude": 4},
				{"timestamp": "2026-11-02T07:30:00+08:00", "latitude": 31.2305, "longitude": 121.4738, "altitude": 4}]}`),
	},
	{
		Kind: "workoutRoute", Class: "HKWorkoutRoute", Types: []string{workoutRouteType},
		Read: true, Write: false, refusal: "write a route as part of its workout (the workout's route field)",
		How: "Read with HKWorkoutRouteQuery; it is the route of the workout whose time it falls in. Written only as a workout's route field (HKWorkoutRouteBuilder).",
		Fields: sampleFields(startAndEnd,
			Field{Name: "locations", Type: TypeArray, Items: TypeObject, Fields: location, Description: "CLLocation points, in order."},
		),
		Example: json.RawMessage(`{"uuid": "6C0F7E59-2B8D-4F3A-9E1C-5A7B3D2E1F00", "kind": "workoutRoute", "type": "HKWorkoutRouteTypeIdentifier",
			"startDate": "2026-11-02T07:00:00+08:00", "endDate": "2026-11-02T07:30:00+08:00",
			"sourceRevision": {"source": {"name": "Workout", "bundleIdentifier": "com.apple.workout"}},
			"locations": [
				{"timestamp": "2026-11-02T07:00:00+08:00", "latitude": 31.2304, "longitude": 121.4737, "altitude": 4,
				 "horizontalAccuracy": 5, "verticalAccuracy": 3, "speed": 2.8, "course": 90}]}`),
	},
	{
		Kind: "stateOfMind", Class: "HKStateOfMind", Types: []string{"HKDataTypeStateOfMind"},
		Read: true, Write: true, dates: moment,
		How: "Written with HKHealthStore.save.",
		Fields: sampleFields(moment,
			Field{Name: "stateOfMindKind", Type: TypeInteger, Enum: "HKStateOfMind.Kind", Required: true,
				Description: "A momentary emotion or a daily mood."},
			Field{Name: "valence", Type: TypeNumber, Required: true, Description: "-1 (very unpleasant) to 1 (very pleasant), 0 neutral."},
			Field{Name: "valenceClassification", Type: TypeInteger, Enum: "HKStateOfMind.ValenceClassification", ReadOnly: true,
				Description: "Derived from valence by HealthKit."},
			Field{Name: "labels", Type: TypeArray, Items: TypeInteger, Enum: "HKStateOfMind.Label",
				Description: "What was felt, e.g. 29 (stressed); empty when left out."},
			Field{Name: "associations", Type: TypeArray, Items: TypeInteger, Enum: "HKStateOfMind.Association",
				Description: "What it was about, e.g. 17 (work); empty when left out."},
		),
		Example: json.RawMessage(`{"kind": "stateOfMind", "type": "HKDataTypeStateOfMind", "startDate": "2026-11-01T21:00:00+08:00",
			"stateOfMindKind": 1, "valence": -0.6, "labels": [29], "associations": [17]}`),
	},
	{
		Kind: "heartbeatSeries", Class: "HKHeartbeatSeriesSample", Types: []string{"HKDataTypeIdentifierHeartbeatSeries"},
		Read: true, Write: true, dates: startOnly,
		How: "Read with HKHeartbeatSeriesQuery; written with HKHeartbeatSeriesBuilder.",
		Fields: sampleFields(startOnly,
			Field{Name: "beats", Type: TypeArray, Items: TypeObject, Required: true,
				Description: "Every heartbeat, non-empty and in order.",
				Fields: []Field{
					{Name: "timeSinceSeriesStart", Type: TypeNumber, Required: true,
						Description: "Seconds since startDate: at least 0 and greater than the previous beat's."},
					{Name: "precededByGap", Type: TypeBoolean, Required: true, Description: "Whether beats went unmeasured right before this one."},
				}},
		),
		Example: json.RawMessage(`{"kind": "heartbeatSeries", "type": "HKDataTypeIdentifierHeartbeatSeries", "startDate": "2026-11-01T07:00:00+08:00",
			"beats": [
				{"timeSinceSeriesStart": 0, "precededByGap": false},
				{"timeSinceSeriesStart": 0.82, "precededByGap": false},
				{"timeSinceSeriesStart": 2.5, "precededByGap": true}]}`),
	},
	{
		Kind: "audiogram", Class: "HKAudiogramSample", Types: []string{"HKDataTypeIdentifierAudiogram"},
		Read: true, Write: true,
		How: "Written with HKHealthStore.save.",
		Fields: sampleFields(startAndEnd,
			Field{Name: "sensitivityPoints", Type: TypeArray, Items: TypeObject, Required: true,
				Description: "HKAudiogramSensitivityPoint, one per frequency; non-empty.",
				Fields: []Field{
					{Name: "frequency", Type: TypeQuantity, Required: true, Description: "Hz."},
					{Name: "tests", Type: TypeArray, Items: TypeObject, Required: true,
						Description: "HKAudiogramSensitivityTest, the frequency's results; non-empty.",
						Fields: []Field{
							{Name: "sensitivity", Type: TypeQuantity, Required: true, Description: "The hearing threshold, dBHL."},
							{Name: "type", Type: TypeInteger, Enum: "HKAudiogramConductionType", Required: true, Description: "The conduction type."},
							{Name: "masked", Type: TypeBoolean, Required: true, Description: "Whether the test used masking."},
							{Name: "side", Type: TypeInteger, Enum: "HKAudiogramSensitivityTestSide", Required: true, Description: "The ear."},
							{Name: "clampingRange", Type: TypeObject, Description: "The range the test could measure: lowerBound, upperBound or both.",
								Fields: []Field{
									quantityField("lowerBound", "dBHL."),
									quantityField("upperBound", "dBHL."),
								}},
						}},
				}},
		),
		Example: json.RawMessage(`{"kind": "audiogram", "type": "HKDataTypeIdentifierAudiogram",
			"startDate": "2026-11-01T10:00:00+08:00", "endDate": "2026-11-01T10:15:00+08:00",
			"sensitivityPoints": [{"frequency": {"value": 1000, "unit": "Hz"}, "tests": [
				{"sensitivity": {"value": 15, "unit": "dBHL"}, "type": 0, "masked": false, "side": 0},
				{"sensitivity": {"value": 20, "unit": "dBHL"}, "type": 0, "masked": false, "side": 1}]}]}`),
	},
	{
		Kind: "scoredAssessment", Class: "HKGAD7Assessment, HKPHQ9Assessment", Types: []string{gad7Type, phq9Type},
		Read: true, Write: true, dates: moment,
		How: "Written with HKHealthStore.save; HealthKit computes score and risk.",
		Fields: sampleFields(moment,
			Field{Name: "answers", Type: TypeArray, Items: TypeInteger, Required: true,
				Description: "One per question in order, GAD-7 seven and PHQ-9 nine: HKGAD7Assessment.Answer / HKPHQ9Assessment.Answer raw values 0–3, and PHQ-9's ninth may be 4 (preferNotToAnswer)."},
			Field{Name: "score", Type: TypeInteger, ReadOnly: true, Description: "The total, computed by HealthKit."},
			Field{Name: "risk", Type: TypeInteger, ReadOnly: true, Description: "HKGAD7Assessment.Risk or HKPHQ9Assessment.Risk raw value, computed by HealthKit."},
		),
		Example: json.RawMessage(`{"kind": "scoredAssessment", "type": "HKScoredAssessmentTypeIdentifierGAD7",
			"startDate": "2026-11-02T21:00:00+08:00", "answers": [1, 2, 1, 0, 1, 2, 1]}`),
		typeExamples: map[string]json.RawMessage{
			phq9Type: json.RawMessage(`{"kind": "scoredAssessment", "type": "HKScoredAssessmentTypeIdentifierPHQ9",
				"startDate": "2026-11-02T21:05:00+08:00", "answers": [1, 1, 2, 1, 0, 1, 0, 0, 0]}`),
		},
	},
	{
		Kind: "visionPrescription", Class: "HKGlassesPrescription, HKContactsPrescription", Types: []string{"HKVisionPrescriptionTypeIdentifier"},
		Read: true, Write: true, dates: noDates,
		How: "Read only for the prescriptions the user allows one by one (per-object authorization); written with HKHealthStore.save.",
		Fields: sampleFields(noDates,
			Field{Name: "prescriptionType", Type: TypeInteger, Enum: "HKVisionPrescriptionType", Required: true,
				Description: "Glasses (HKGlassesPrescription) or contacts (HKContactsPrescription)."},
			Field{Name: "dateIssued", Type: TypeTimestamp, Required: true, Description: "When the prescription was issued."},
			Field{Name: "expirationDate", Type: TypeTimestamp, Description: "When it expires."},
			Field{Name: "rightEye", Type: TypeObject, RequiredWhen: "unless leftEye is given", Fields: lens,
				Description: "The right eye's lens; glasses-only and contacts-only fields go with the prescription type."},
			Field{Name: "leftEye", Type: TypeObject, RequiredWhen: "unless rightEye is given", Fields: lens,
				Description: "The left eye's lens, as rightEye."},
			Field{Name: "brand", Type: TypeString, RequiredWhen: "for contacts; glasses have none", Description: "The contact lenses' brand."},
			Field{Name: "attachments", Type: TypeArray, Items: TypeObject, ReadOnly: true,
				Description: "HKAttachment: files the user attached in Health (their contents aren't uploaded).",
				Fields: []Field{
					{Name: "identifier", Type: TypeString, Description: "HKAttachment.identifier."},
					{Name: "name", Type: TypeString, Description: "The file's name."},
					{Name: "contentType", Type: TypeString, Description: "Its uniform type identifier."},
					{Name: "size", Type: TypeInteger, Description: "Bytes."},
					{Name: "creationDate", Type: TypeTimestamp, Description: "When it was attached."},
				}},
		),
		Example: json.RawMessage(`{"kind": "visionPrescription", "type": "HKVisionPrescriptionTypeIdentifier",
			"prescriptionType": 1, "dateIssued": "2026-10-20T10:00:00+08:00", "expirationDate": "2028-10-20T10:00:00+08:00",
			"rightEye": {"sphere": {"value": -2.25, "unit": "D"}, "cylinder": {"value": -0.5, "unit": "D"}, "axis": {"value": 180, "unit": "deg"},
			             "farPupillaryDistance": {"value": 31.5, "unit": "mm"}},
			"leftEye": {"sphere": {"value": -2, "unit": "D"}, "farPupillaryDistance": {"value": 31, "unit": "mm"}}}`),
	},
	{
		Kind: "cdaDocument", Class: "HKCDADocumentSample", Types: []string{"HKDocumentTypeIdentifierCDA"},
		Read: false, Write: false, refusal: "Rendu doesn't read or write clinical documents",
		How: "Not supported: reading needs per-object authorization and crashed on the device; Apple Health has no place to show them.",
		Fields: sampleFields(startAndEnd,
			Field{Name: "documentData", Type: TypeString, Required: true,
				Description: "The CDA XML: non-empty and at most 10 MB (UTF-8)."},
			Field{Name: "title", Type: TypeString, ReadOnly: true, Description: "Read by HealthKit from the XML."},
			Field{Name: "patientName", Type: TypeString, ReadOnly: true, Description: "Read by HealthKit from the XML."},
			Field{Name: "authorName", Type: TypeString, ReadOnly: true, Description: "Read by HealthKit from the XML."},
			Field{Name: "custodianName", Type: TypeString, ReadOnly: true, Description: "Read by HealthKit from the XML."},
		),
		Example: json.RawMessage(`{"kind": "cdaDocument", "type": "HKDocumentTypeIdentifierCDA",
			"startDate": "2026-10-28T09:00:00+08:00", "endDate": "2026-10-28T09:30:00+08:00",
			"documentData": "<?xml version=\"1.0\" encoding=\"UTF-8\"?><ClinicalDocument xmlns=\"urn:hl7-org:v3\">…</ClinicalDocument>"}`),
	},
	{
		Kind: "electrocardiogram", Class: "HKElectrocardiogram", Types: []string{"HKDataTypeIdentifierElectrocardiogram"},
		Read: true, Write: false, refusal: "HealthKit doesn't let apps create electrocardiograms",
		How: "Read, its voltages with HKElectrocardiogramQuery; HealthKit doesn't let apps create electrocardiograms.",
		Fields: sampleFields(startAndEnd,
			Field{Name: "classification", Type: TypeInteger, Enum: "HKElectrocardiogram.Classification", Description: "The ECG app's result."},
			Field{Name: "symptomsStatus", Type: TypeInteger, Enum: "HKElectrocardiogram.SymptomsStatus", Description: "Whether the user reported symptoms."},
			quantityField("averageHeartRate", "count/min."),
			quantityField("samplingFrequency", "Hz."),
			Field{Name: "numberOfVoltageMeasurements", Type: TypeInteger, Description: "How many voltage measurements there are."},
			Field{Name: "voltageMeasurements", Type: TypeArray, Items: TypeObject,
				Description: "The waveform, about 15,000 points: large, read it only to analyze it.",
				Fields: []Field{
					{Name: "timeSinceSampleStart", Type: TypeNumber, Description: "Seconds since startDate."},
					{Name: "appleWatchSimilarToLeadI", Type: TypeNumber, Description: "Microvolts (mcV)."},
				}},
		),
		Example: json.RawMessage(`{"uuid": "0B5E3C1A-7D2F-4E6B-8A9C-1D2E3F4A5B6C", "kind": "electrocardiogram", "type": "HKDataTypeIdentifierElectrocardiogram",
			"startDate": "2026-11-01T09:00:00+08:00", "endDate": "2026-11-01T09:00:30+08:00",
			"sourceRevision": {"source": {"name": "ECG", "bundleIdentifier": "com.apple.NanoHeartRhythm"}},
			"classification": 1, "symptomsStatus": 1, "averageHeartRate": {"value": 64, "unit": "count/min"},
			"samplingFrequency": {"value": 512, "unit": "Hz"}, "numberOfVoltageMeasurements": 15360,
			"voltageMeasurements": [{"timeSinceSampleStart": 0, "appleWatchSimilarToLeadI": 12.5}]}`),
	},
	{
		Kind: "medicationDoseEvent", Class: "HKMedicationDoseEvent", Types: []string{"HKMedicationDoseEventTypeIdentifierMedicationDoseEvent"},
		Read: true, Write: false, refusal: "HealthKit doesn't let apps create medication dose events",
		How: "Read; HealthKit doesn't let apps create medication dose events.",
		Fields: sampleFields(startAndEnd,
			Field{Name: "medicationId", Type: TypeString, Description: "The medication's id in GET /v1/medications."},
			Field{Name: "medicationName", Type: TypeString, Description: "The medication's displayText."},
			Field{Name: "scheduleType", Type: TypeInteger, Enum: "HKMedicationDoseEvent.ScheduleType", Description: "As needed or on a schedule."},
			Field{Name: "logStatus", Type: TypeInteger, Enum: "HKMedicationDoseEvent.LogStatus", Description: "Taken, skipped, snoozed…"},
			Field{Name: "scheduledDate", Type: TypeTimestamp, Description: "When the dose was scheduled; absent for as-needed doses."},
			Field{Name: "scheduledDoseQuantity", Type: TypeNumber, Description: "The scheduled dose, in unit."},
			Field{Name: "doseQuantity", Type: TypeNumber, Description: "The dose taken, in unit."},
			Field{Name: "unit", Type: TypeString, Description: "The doses' HKUnit string."},
		),
		Example: json.RawMessage(`{"uuid": "9D8C7B6A-5F4E-4D3C-2B1A-0F9E8D7C6B5A", "kind": "medicationDoseEvent",
			"type": "HKMedicationDoseEventTypeIdentifierMedicationDoseEvent",
			"startDate": "2026-11-01T08:05:00+08:00", "endDate": "2026-11-01T08:05:00+08:00",
			"medicationId": "…", "medicationName": "Amlodipine 5 mg Oral Tablet", "scheduleType": 2, "logStatus": 4,
			"scheduledDate": "2026-11-01T08:00:00+08:00", "scheduledDoseQuantity": 1, "doseQuantity": 1, "unit": "count"}`),
	},
	{
		Kind: "characteristic", Class: "HKCharacteristicType", TypePrefix: "HKCharacteristicTypeIdentifier",
		Read: true, Write: false, refusal: "the user sets characteristics in the Health app",
		How: "Read as GET /v1/characteristics (raw values of the type's enum); the user sets them in the Health app.",
	},
	{
		Kind: "activitySummary", Class: "HKActivitySummary", Types: []string{"HKActivitySummaryTypeIdentifier"},
		Read: true, Write: false, refusal: "HealthKit computes activity summaries",
		How: "Read as GET /v1/activity-summaries (HKActivitySummaryQuery), not in the change feed; HealthKit computes them.",
	},
	{
		Kind: "userAnnotatedMedication", Class: "HKUserAnnotatedMedication", Types: []string{"HKDataTypeUserAnnotatedMedicationConcept"},
		Read: true, Write: false, refusal: "HealthKit doesn't let apps create medications",
		How: "Read as GET /v1/medications, for the medications the user allows one by one; HealthKit doesn't let apps create them.",
	},
	{
		Kind: "clinicalRecord", Class: "HKClinicalRecord", TypePrefix: "HKClinicalTypeIdentifier",
		Read: false, Write: false, refusal: "Rendu doesn't read or write Health Records",
		How: "Not supported: Health Records need an entitlement Apple grants separately, and aren't offered in mainland China.",
	},
}

var kinds = func() map[string]*Kind {
	m := map[string]*Kind{}
	for i := range kindList {
		m[kindList[i].Kind] = &kindList[i]
	}
	return m
}()

// Kinds lists every kind, as the capability table does.
func Kinds() []Kind { return kindList }

// LookupKind returns a kind by name.
func LookupKind(name string) (Kind, bool) {
	k, ok := kinds[name]
	if !ok {
		return Kind{}, false
	}
	return *k, true
}

// HasType reports whether typ is one of the kind's types.
func (k Kind) HasType(typ string) bool {
	if k.TypePrefix != "" {
		return len(typ) > len(k.TypePrefix) && typ[:len(k.TypePrefix)] == k.TypePrefix
	}
	for _, t := range k.Types {
		if t == typ {
			return true
		}
	}
	return false
}

// KindOfType returns the kind a type belongs to ("" for none).
func KindOfType(typ string) string {
	for _, k := range kindList {
		if k.HasType(typ) {
			return k.Kind
		}
	}
	return ""
}

// ExampleHints tailor a kind's example to one type.
type ExampleHints struct {
	// Unit is a unit the quantity type takes.
	Unit string
	// Value is a raw value of the category type's enum.
	Value *int64
	// Cumulative: the quantity type adds up over time, so the example
	// covers an interval rather than an instant.
	Cumulative bool
}

// ExampleFor returns an example of the kind for one of its types: the type's
// own example, or the kind's with the type and the hints applied.
func (k Kind) ExampleFor(typ string, h ExampleHints) json.RawMessage {
	if ex, ok := k.typeExamples[typ]; ok {
		return compact(ex)
	}
	if k.Example == nil {
		return nil
	}
	var o map[string]json.RawMessage
	if err := json.Unmarshal(k.Example, &o); err != nil {
		panic("store: example of " + k.Kind + ": " + err.Error())
	}
	set := func(name string, v any) {
		b, _ := json.Marshal(v)
		o[name] = b
	}
	set("type", typ)
	switch k.Kind {
	case "quantity":
		if h.Unit != "" {
			var q map[string]any
			_ = json.Unmarshal(o["quantity"], &q)
			q["unit"] = h.Unit
			set("quantity", q)
		}
		if h.Cumulative {
			var start string
			_ = json.Unmarshal(o["startDate"], &start)
			if t, err := ParseTimestamp(start); err == nil {
				set("endDate", t.Add(30*time.Minute).Format(time.RFC3339))
			}
		}
		delete(o, "metadata")
	case "category":
		if h.Value != nil {
			set("value", *h.Value)
		}
	}
	b, _ := json.Marshal(o)
	return b
}

func compact(raw json.RawMessage) json.RawMessage {
	b, err := compactJSON(raw)
	if err != nil {
		panic("store: example: " + err.Error())
	}
	return b
}
