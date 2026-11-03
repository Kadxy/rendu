package store

import (
	"encoding/json"
	"fmt"
	"maps"
	"math"
	"slices"
	"strconv"
	"strings"

	sdk "github.com/Kadxy/rendu/internal/schema"
)

// Write objects: what POST /v1/writes accepts (docs/PROTOCOL.md, "Object format").
// The server checks structure only, by the kinds' table (kinds.go) and the
// rules in this file; whether HealthKit accepts the type, unit and values is
// the app's call when it executes the write.

// role is where an object sits in a write.
type role int

const (
	topLevel          role = iota
	correlationMember      // may omit its dates: they default to the correlation's
	workoutSample          // added to the workout (an effort score: related to it)
)

// validateObject checks a write object's structure.
func validateObject(raw json.RawMessage, path string, r role) error {
	f, ok := objectOf(raw)
	if !ok {
		return invalid("%s must be an object", path)
	}
	for _, c := range []Field{uuidField, sourceRevisionField, deviceField} {
		if f.has(c.Name) {
			return refuse(path+"."+c.Name, c)
		}
	}
	kind, _ := f.str("kind")
	typ, _ := f.str("type")
	if kind == "" || typ == "" {
		return invalid("%s: kind and type are required", path)
	}
	k, ok := kinds[kind]
	switch {
	case !ok:
		return invalid("%s.kind %q is unknown", path, kind)
	case kind == "workoutRoute":
		return invalid("%s", k.refusal)
	case !k.Write && k.Read:
		return invalid("%s.kind %q is read-only: %s", path, kind, k.refusal)
	case !k.Write:
		return invalid("%s.kind %q can't be written: %s", path, kind, k.refusal)
	}
	if err := checkKnown(f, k.Fields, path, kind, true); err != nil {
		return err
	}
	if !k.HasType(typ) {
		if k.TypePrefix != "" {
			return invalid("%s.type %q does not match kind %q (expected %s…)", path, typ, kind, k.TypePrefix)
		}
		return invalid("%s.type must be %s for kind %q", path, quoted(k.Types), kind)
	}
	if err := checkFields(f, k.Fields, path); err != nil {
		return err
	}
	start, end, err := checkDates(f, path, k.dates, r)
	if err != nil {
		return err
	}

	switch kind {
	case "quantity":
		return checkQuantitySample(f, path, r, start, end)
	case "correlation":
		return checkCorrelation(f, path, r)
	case "workout":
		return checkWorkout(f, path, start, end)
	case "stateOfMind":
		if v, _ := f.number("valence"); v < -1 || v > 1 {
			return invalid("%s.valence must be a number from -1 to 1", path)
		}
	case "heartbeatSeries":
		return checkBeats(f, path)
	case "audiogram":
		return checkAudiogram(f, path)
	case "scoredAssessment":
		return checkAnswers(f, path, typ)
	case "visionPrescription":
		return checkPrescription(f, path)
	}
	return nil
}

func quoted(values []string) string {
	q := make([]string, len(values))
	for i, v := range values {
		q[i] = fmt.Sprintf("%q", v)
	}
	return strings.Join(q, " or ")
}

// --- the table ----------------------------------------------------------

// checkKnown refuses members the table doesn't list, at every depth (a
// misspelled "quantiy" is an error, not a field HealthKit never sees).
// Read-only fields are refused later as such, so their insides aren't
// looked at; neither are free-form objects (metadata).
func checkKnown(f fields, specs []Field, path, kind string, top bool) error {
	for _, name := range slices.Sorted(maps.Keys(f)) {
		spec, ok := fieldNamed(specs, name)
		if !ok {
			return unknownField(path, name, kind, top)
		}
		if spec.ReadOnly {
			continue
		}
		if err := checkKnownValue(f[name], spec, path+"."+name, kind); err != nil {
			return err
		}
	}
	return nil
}

func checkKnownValue(raw json.RawMessage, spec Field, path, kind string) error {
	switch spec.Type {
	case TypeQuantity:
		return checkKnownQuantity(raw, path, kind)
	case TypeObject:
		if o, ok := objectOf(raw); ok && spec.Fields != nil {
			return checkKnown(o, spec.Fields, path, kind, false)
		}
	case TypeArray:
		// Not an array: no items here, and checkFields says so.
		var items []json.RawMessage
		_ = json.Unmarshal(raw, &items)
		for i, item := range items {
			p := fmt.Sprintf("%s[%d]", path, i)
			o, ok := objectOf(item)
			switch {
			case spec.Items == TypeQuantity:
				if err := checkKnownQuantity(item, p, kind); err != nil {
					return err
				}
			case !ok:
			case spec.ItemKind != "":
				// A member of another kind is refused as such (kindOf).
				if member, _ := o.str("kind"); member == spec.ItemKind {
					if err := checkKnown(o, kinds[member].Fields, p, member, true); err != nil {
						return err
					}
				}
			case spec.Fields != nil:
				if err := checkKnown(o, spec.Fields, p, kind, false); err != nil {
					return err
				}
			}
		}
	}
	return nil
}

func checkKnownQuantity(raw json.RawMessage, path, kind string) error {
	q, ok := objectOf(raw)
	if !ok {
		return nil
	}
	for _, name := range slices.Sorted(maps.Keys(q)) {
		if name != "value" && name != "unit" {
			return unknownField(path, name, kind, false)
		}
	}
	return nil
}

func fieldNamed(specs []Field, name string) (Field, bool) {
	for _, s := range specs {
		if s.Name == name {
			return s, true
		}
	}
	return Field{}, false
}

// fieldOwners are the kinds with each top-level field, for pointing a
// field given to the wrong kind to its own.
var fieldOwners = func() map[string][]string {
	m := map[string][]string{}
	for _, k := range kindList {
		for _, f := range k.Fields {
			m[f.Name] = append(m[f.Name], k.Kind)
		}
	}
	return m
}()

func unknownField(path, name, kind string, top bool) error {
	if owners := fieldOwners[name]; top && len(owners) == 1 {
		return invalid("%s.%s is not a field of kind %s (it is a field of kind %s)", path, name, kind, owners[0])
	}
	return invalid("%s.%s is not a field of kind %s", path, name, kind)
}

func refuse(path string, spec Field) error {
	if spec.refused != "" {
		return invalid("%s %s", path, spec.refused)
	}
	return invalid("%s is read-only; omit it", path)
}

// checkFields applies the table to an object's members: read-only ones are
// refused, required ones must be there, and each must have its type (and be
// one of its enum's values).
func checkFields(f fields, specs []Field, path string) error {
	for _, spec := range specs {
		p := path + "." + spec.Name
		raw, has := f[spec.Name]
		switch {
		case !has && spec.Required:
			return invalid("%s is required", p)
		case !has:
		case spec.ReadOnly:
			return refuse(p, spec)
		default:
			if err := checkValue(raw, spec, p); err != nil {
				return err
			}
		}
	}
	return nil
}

func checkValue(raw json.RawMessage, spec Field, path string) error {
	switch spec.Type {
	case TypeTimestamp:
		_, err := timestampOf(raw, path)
		return err
	case TypeQuantity:
		return quantityOf(raw, path)
	case TypeInteger:
		return integerOf(raw, path, spec.Enum)
	case TypeNumber:
		if _, ok := numberOf(raw); !ok {
			return invalid("%s must be a number", path)
		}
	case TypeString, TypeUUID:
		if _, ok := strOf(raw); !ok {
			return invalid("%s must be a string", path)
		}
	case TypeBoolean:
		if _, ok := boolOf(raw); !ok {
			return invalid("%s must be true or false", path)
		}
	case TypeObject:
		o, ok := objectOf(raw)
		if !ok {
			return invalid("%s must be an object", path)
		}
		if spec.Name == "metadata" {
			return checkMetadata(o, path)
		}
		return checkFields(o, spec.Fields, path)
	case TypeArray:
		var items []json.RawMessage
		if json.Unmarshal(raw, &items) != nil || items == nil {
			return invalid("%s must be an array", path)
		}
		for i, item := range items {
			p := fmt.Sprintf("%s[%d]", path, i)
			switch spec.Items {
			case TypeObject:
				o, ok := objectOf(item)
				if !ok {
					return invalid("%s must be an object", p)
				}
				// Members of a kind are validated as objects of their own.
				if spec.ItemKind == "" {
					if err := checkFields(o, spec.Fields, p); err != nil {
						return err
					}
				}
			default:
				if err := checkValue(item, Field{Type: spec.Items, Enum: spec.Enum}, p); err != nil {
					return err
				}
			}
		}
	}
	return nil
}

// integerOf checks an integer, and that it is a raw value of enum if any.
func integerOf(raw json.RawMessage, path, enum string) error {
	v, ok := intOf(raw)
	if enum == "" {
		if !ok {
			return invalid("%s must be an integer", path)
		}
		return nil
	}
	e, known := sdk.LookupEnum(enum)
	if !known {
		panic("store: no SDK enum " + enum)
	}
	if !ok || !e.Has(v) {
		return invalid("%s must be %s", path, enumRule(enum, e))
	}
	return nil
}

// enumRule names an enum's raw values in an error: listed when they're few.
func enumRule(name string, e sdk.Enum) string {
	if len(e.Cases) > 12 {
		return fmt.Sprintf("an %s raw value (GET /v1/schema/enums/%s)", name, name)
	}
	var values []string
	for _, c := range e.Cases {
		if !c.Deprecated {
			values = append(values, fmt.Sprintf("%d %s", c.Value, c.Short))
		}
	}
	return fmt.Sprintf("an %s raw value: %s", name, strings.Join(values, ", "))
}

func checkMetadata(md fields, path string) error {
	for _, k := range reservedMetadata {
		if md.has(k) {
			return invalid("%s.%s is set by the app; omit it", path, k)
		}
	}
	for _, k := range slices.Sorted(maps.Keys(md)) {
		var v any
		_ = json.Unmarshal(md[k], &v)
		switch v.(type) {
		case string, float64, bool:
		default:
			return invalid("%s.%s must be a string, a number or a boolean", path, k)
		}
	}
	return nil
}

// --- rules the table can't express --------------------------------------

// checkDates applies the kind's date rule and returns the dates in Unix
// milliseconds (0 when absent). The table has checked they are timestamps.
func checkDates(f fields, path string, rule dateRule, r role) (start, end int64, err error) {
	hasStart, hasEnd := f.has("startDate"), f.has("endDate")
	if rule == memberDates && r != correlationMember && (!hasStart || !hasEnd) {
		return 0, 0, invalid("%s: startDate and endDate are required", path)
	}
	if hasStart {
		if start, err = f.timestamp("startDate", path); err != nil {
			return 0, 0, err
		}
	}
	if hasEnd {
		if end, err = f.timestamp("endDate", path); err != nil {
			return 0, 0, err
		}
	}
	if hasStart && hasEnd && end < start {
		return 0, 0, invalid("%s: endDate is before startDate", path)
	}
	if rule == moment && hasEnd && end != start {
		return 0, 0, invalid("%s.endDate must equal startDate (this is a moment); omit it", path)
	}
	return start, end, nil
}

// checkQuantitySample: a quantity, or a series of them (top level only:
// HKQuantitySeriesSampleBuilder builds a sample of its own).
func checkQuantitySample(f fields, path string, r role, start, end int64) error {
	hasQuantity, hasSeries := f.has("quantity"), f.has("series")
	switch {
	case hasSeries && r != topLevel:
		return invalid("%s.series is only for a sample of its own, not a correlation member or a workout sample", path)
	case hasQuantity && hasSeries, !hasQuantity && !hasSeries && r == topLevel:
		return invalid("%s: give exactly one of quantity and series", path)
	case !hasSeries:
		return f.quantity("quantity", path, true)
	}
	points, _ := f.list("series", path)
	if len(points) == 0 {
		return invalid("%s.series must be a non-empty array", path)
	}
	for i, raw := range points {
		p := fmt.Sprintf("%s.series[%d]", path, i)
		pt, _ := objectOf(raw)
		s, e, err := pt.interval(p)
		if err != nil {
			return err
		}
		if s < start || e > end {
			return invalid("%s must lie within the sample's startDate and endDate", p)
		}
	}
	return nil
}

func checkCorrelation(f fields, path string, r role) error {
	if r != topLevel {
		return invalid("%s: correlations cannot be nested", path)
	}
	members, _ := f.list("objects", path)
	if len(members) == 0 {
		return invalid("%s.objects must be a non-empty array", path)
	}
	for i, m := range members {
		p := fmt.Sprintf("%s.objects[%d]", path, i)
		if kindOf(m) != "quantity" {
			return invalid("%s.kind must be \"quantity\"", p)
		}
		if err := validateObject(m, p, correlationMember); err != nil {
			return err
		}
	}
	return nil
}

// HKWorkoutEventType values whose events may last (the others are moments).
const (
	eventLap     = 3
	eventSegment = 7
)

// checkWorkout: what HKWorkoutBuilder takes — samples (HKWorkoutBuilder.add,
// or relateWorkoutEffortSample for effort scores), activities and events,
// all inside the workout — and a route for HKWorkoutRouteBuilder.
func checkWorkout(f fields, path string, start, end int64) error {
	if err := checkActivityType(f, path, "workoutActivityType", "workoutActivityTypeName"); err != nil {
		return err
	}
	inside := func(s, e int64) bool { return s >= start && e <= end }

	samples, _ := f.list("samples", path)
	for i, m := range samples {
		p := fmt.Sprintf("%s.samples[%d]", path, i)
		if kindOf(m) != "quantity" {
			return invalid("%s.kind must be \"quantity\"", p)
		}
		if err := validateObject(m, p, workoutSample); err != nil {
			return err
		}
		mf, _ := objectOf(m)
		if s, e, _ := mf.interval(p); !inside(s, e) {
			return invalid("%s must lie within the workout's startDate and endDate", p)
		}
	}

	activities, _ := f.list("workoutActivities", path)
	for i, raw := range activities {
		p := fmt.Sprintf("%s.workoutActivities[%d]", path, i)
		a, _ := objectOf(raw)
		c, _ := objectOf(a["workoutConfiguration"])
		if err := checkActivityType(c, p+".workoutConfiguration", "activityType", "activityTypeName"); err != nil {
			return err
		}
		s, _ := a.timestamp("startDate", p)
		e := s
		if a.has("endDate") {
			e, _ = a.timestamp("endDate", p)
			if e < s {
				return invalid("%s: endDate is before startDate", p)
			}
		}
		if !inside(s, e) {
			return invalid("%s must lie within the workout's startDate and endDate", p)
		}
	}

	events, _ := f.list("workoutEvents", path)
	for i, raw := range events {
		p := fmt.Sprintf("%s.workoutEvents[%d]", path, i)
		ev, _ := objectOf(raw)
		typ, _ := ev.integer("type")
		s, e, err := ev.interval(p)
		if err != nil {
			return err
		}
		if e != s && typ != eventLap && typ != eventSegment {
			return invalid("%s: only lap (3) and segment (7) events last; endDate must equal startDate", p)
		}
		if !inside(s, e) {
			return invalid("%s must lie within the workout's startDate and endDate", p)
		}
	}

	if !f.has("route") {
		return nil
	}
	locations, _ := f.list("route", path)
	if len(locations) == 0 {
		return invalid("%s.route must be a non-empty array", path)
	}
	for i, raw := range locations {
		p := fmt.Sprintf("%s.route[%d]", path, i)
		l, _ := objectOf(raw)
		if ts, _ := l.timestamp("timestamp", p); !inside(ts, ts) {
			return invalid("%s.timestamp must lie within the workout's startDate and endDate", p)
		}
		if v, _ := l.number("latitude"); v < -90 || v > 90 {
			return invalid("%s.latitude must be a number from -90 to 90", p)
		}
		if v, _ := l.number("longitude"); v < -180 || v > 180 {
			return invalid("%s.longitude must be a number from -180 to 180", p)
		}
	}
	return nil
}

// checkActivityType: an HKWorkoutActivityType as its raw value or its name,
// exactly one. A name is a case's Swift name, or activity_<n> for a
// deprecated case (what the app reads and writes: WorkoutActivityName).
func checkActivityType(f fields, path, valueField, nameField string) error {
	hasValue, hasName := f.has(valueField), f.has(nameField)
	if hasValue == hasName {
		return invalid("%s: give exactly one of %s and %s", path, valueField, nameField)
	}
	if hasValue {
		return nil // the table checked it is a raw value
	}
	name, _ := f.str(nameField)
	if !activityNames[name] {
		return invalid("%s.%s must be a name such as \"running\": an HKWorkoutActivityType case (GET /v1/schema/enums/HKWorkoutActivityType)", path, nameField)
	}
	return nil
}

var activityNames = func() map[string]bool {
	e, ok := sdk.LookupEnum("HKWorkoutActivityType")
	if !ok {
		panic("store: no SDK enum HKWorkoutActivityType")
	}
	names := map[string]bool{}
	for _, c := range e.Cases {
		if c.Deprecated {
			names["activity_"+strconv.FormatInt(c.Value, 10)] = true
		} else {
			names[c.Short] = true
		}
	}
	return names
}()

// checkBeats: HKHeartbeatSeriesBuilder adds beats in order.
func checkBeats(f fields, path string) error {
	beats, _ := f.list("beats", path)
	if len(beats) == 0 {
		return invalid("%s.beats must be a non-empty array", path)
	}
	var prev float64
	for i, raw := range beats {
		p := fmt.Sprintf("%s.beats[%d]", path, i)
		b, _ := objectOf(raw)
		t, _ := b.number("timeSinceSeriesStart")
		if t < 0 {
			return invalid("%s.timeSinceSeriesStart must be a number of seconds, at least 0", p)
		}
		if i > 0 && t <= prev {
			return invalid("%s.timeSinceSeriesStart must be greater than the previous beat's", p)
		}
		prev = t
	}
	return nil
}

func checkAudiogram(f fields, path string) error {
	points, _ := f.list("sensitivityPoints", path)
	if len(points) == 0 {
		return invalid("%s.sensitivityPoints must be a non-empty array", path)
	}
	for i, raw := range points {
		p := fmt.Sprintf("%s.sensitivityPoints[%d]", path, i)
		pt, _ := objectOf(raw)
		tests, _ := pt.list("tests", p)
		if len(tests) == 0 {
			return invalid("%s.tests must be a non-empty array", p)
		}
		for j, raw := range tests {
			t, _ := objectOf(raw)
			if c, ok := objectOf(t["clampingRange"]); t.has("clampingRange") && ok && !c.has("lowerBound") && !c.has("upperBound") {
				return invalid("%s.tests[%d].clampingRange must be an object with lowerBound, upperBound or both", p, j)
			}
		}
	}
	return nil
}

// checkAnswers: one answer per question, HKGAD7Assessment.Answer /
// HKPHQ9Assessment.Answer raw values; PHQ-9's last question may also be
// declined (4, preferNotToAnswer).
func checkAnswers(f fields, path, typ string) error {
	answers, _ := f.list("answers", path)
	n, name := 7, "GAD-7"
	if typ == phq9Type {
		n, name = 9, "PHQ-9"
	}
	if len(answers) != n {
		return invalid("%s.answers must have %d answers for %s", path, n, name)
	}
	for i, raw := range answers {
		limit := int64(3)
		if typ == phq9Type && i == 8 {
			limit = 4
		}
		if v, _ := intOf(raw); v < 0 || v > limit {
			return invalid("%s.answers[%d] must be an integer from 0 to %d", path, i, limit)
		}
	}
	return nil
}

// checkPrescription: HKGlassesPrescription or HKContactsPrescription.
func checkPrescription(f fields, path string) error {
	pt, _ := f.integer("prescriptionType")
	glasses := pt == 1
	if !f.has("rightEye") && !f.has("leftEye") {
		return invalid("%s: give rightEye, leftEye or both", path)
	}
	for _, eye := range []string{"rightEye", "leftEye"} {
		if f.has(eye) {
			if err := checkLens(f[eye], path+"."+eye, glasses); err != nil {
				return err
			}
		}
	}
	brand, _ := f.str("brand")
	switch {
	case glasses && f.has("brand"):
		return invalid("%s.brand is only for contacts (prescriptionType 2)", path)
	case !glasses && brand == "":
		return invalid("%s.brand is required for contacts", path)
	}
	return nil
}

func checkLens(raw json.RawMessage, path string, glasses bool) error {
	l, _ := objectOf(raw)
	other, otherName := glassesFields, "glasses (prescriptionType 1)"
	if glasses {
		other, otherName = contactsFields, "contacts (prescriptionType 2)"
	}
	for _, name := range other {
		if l.has(name) {
			return invalid("%s.%s is only for %s", path, name, otherName)
		}
	}
	if l.has("prism") {
		return checkPrism(l["prism"], path+".prism")
	}
	return nil
}

// checkPrism: HKVisionPrism in polar or in rectangular coordinates.
func checkPrism(raw json.RawMessage, path string) error {
	p, _ := objectOf(raw)
	polar := p.has("amount") || p.has("angle")
	rectangular := p.has("verticalAmount") || p.has("verticalBase") || p.has("horizontalAmount") || p.has("horizontalBase")
	if polar == rectangular {
		return invalid("%s: give either amount and angle, or verticalAmount, verticalBase, horizontalAmount and horizontalBase", path)
	}
	required := []string{"amount", "angle"}
	if rectangular {
		required = []string{"verticalAmount", "verticalBase", "horizontalAmount", "horizontalBase"}
	}
	for _, name := range required {
		if !p.has(name) {
			return invalid("%s.%s is required", path, name)
		}
	}
	return nil
}

func kindOf(raw json.RawMessage) string {
	var head struct {
		Kind string `json:"kind"`
	}
	_ = json.Unmarshal(raw, &head)
	return head.Kind
}

// objectTypes lists the types an object touches, deduplicated: its own,
// then its correlation members' and its workout samples', and a workout's
// route.
func objectTypes(object []byte) []string {
	var o struct {
		Type    string `json:"type"`
		Objects []struct {
			Type string `json:"type"`
		} `json:"objects"`
		Samples []struct {
			Type string `json:"type"`
		} `json:"samples"`
		Route []json.RawMessage `json:"route"`
	}
	_ = json.Unmarshal(object, &o)
	types := []string{}
	add := func(t string) {
		if t != "" && !slices.Contains(types, t) {
			types = append(types, t)
		}
	}
	add(o.Type)
	for _, m := range o.Objects {
		add(m.Type)
	}
	for _, m := range o.Samples {
		add(m.Type)
	}
	if len(o.Route) > 0 {
		add(workoutRouteType)
	}
	return types
}

// --- reading members ----------------------------------------------------

// fields are an object's members, checked one by one. Reading a member
// that is absent, null or of another JSON type reports !ok.
type fields map[string]json.RawMessage

func objectOf(raw json.RawMessage) (fields, bool) {
	var f fields
	if json.Unmarshal(raw, &f) != nil || f == nil {
		return nil, false
	}
	return f, true
}

func (f fields) has(name string) bool {
	_, ok := f[name]
	return ok
}

func (f fields) str(name string) (string, bool) { return strOf(f[name]) }

func strOf(raw json.RawMessage) (string, bool) {
	var v *string
	if json.Unmarshal(raw, &v) != nil || v == nil {
		return "", false
	}
	return *v, true
}

func (f fields) integer(name string) (int64, bool) { return intOf(f[name]) }

func intOf(raw json.RawMessage) (int64, bool) {
	var v *int64
	if json.Unmarshal(raw, &v) != nil || v == nil {
		return 0, false
	}
	return *v, true
}

func (f fields) number(name string) (float64, bool) { return numberOf(f[name]) }

func numberOf(raw json.RawMessage) (float64, bool) {
	var v *float64
	if json.Unmarshal(raw, &v) != nil || v == nil || math.IsNaN(*v) || math.IsInf(*v, 0) {
		return 0, false
	}
	return *v, true
}

func boolOf(raw json.RawMessage) (bool, bool) {
	var v *bool
	if json.Unmarshal(raw, &v) != nil || v == nil {
		return false, false
	}
	return *v, true
}

// list reads an array member; nil when absent.
func (f fields) list(name, path string) ([]json.RawMessage, error) {
	if !f.has(name) {
		return nil, nil
	}
	var v []json.RawMessage
	if json.Unmarshal(f[name], &v) != nil || v == nil {
		return nil, invalid("%s.%s must be an array", path, name)
	}
	return v, nil
}

// timestamp reads a required timestamp as Unix milliseconds.
func (f fields) timestamp(name, path string) (int64, error) {
	if !f.has(name) {
		return 0, invalid("%s.%s is required", path, name)
	}
	return timestampOf(f[name], path+"."+name)
}

func timestampOf(raw json.RawMessage, path string) (int64, error) {
	v, ok := strOf(raw)
	if !ok {
		return 0, invalid("%s must be a timestamp", path)
	}
	t, err := ParseTimestamp(v)
	if err != nil {
		return 0, invalid("%s: %v", path, err)
	}
	return t.UnixMilli(), nil
}

// interval reads a required startDate and endDate, end not before start.
func (f fields) interval(path string) (start, end int64, err error) {
	if start, err = f.timestamp("startDate", path); err != nil {
		return 0, 0, err
	}
	if end, err = f.timestamp("endDate", path); err != nil {
		return 0, 0, err
	}
	if end < start {
		return 0, 0, invalid("%s: endDate is before startDate", path)
	}
	return start, end, nil
}

// quantity checks a member is {"value": number, "unit": "…"} (an HKQuantity
// and its HKUnit string).
func (f fields) quantity(name, path string, required bool) error {
	p := path + "." + name
	if !f.has(name) {
		if required {
			return invalid("%s is required", p)
		}
		return nil
	}
	return quantityOf(f[name], p)
}

func quantityOf(raw json.RawMessage, path string) error {
	q, ok := objectOf(raw)
	if !ok {
		return invalid("%s must be {\"value\": number, \"unit\": string}", path)
	}
	if _, ok := q.number("value"); !ok {
		return invalid("%s.value must be a number", path)
	}
	if unit, _ := q.str("unit"); unit == "" {
		return invalid("%s.unit is required", path)
	}
	return nil
}
