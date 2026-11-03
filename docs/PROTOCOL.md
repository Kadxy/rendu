# Rendu Protocol v1

The contract between the iPhone app, the server, and the CLI. The principle: Rendu only turns HealthKit into a read/write API, and every noun keeps its HealthKit name.

## General conventions

- Every endpoint is prefixed with `/v1`. Requests and responses are JSON (`Content-Type: application/json`).
- A request body may use `Content-Encoding: gzip`; the server must support it. The app always gzips uploads.
- Authentication: `Authorization: Bearer <key>`. Credentials are stored in the server's database, which keeps only the SHA-256 hash of each key. The server's configuration contains no secrets, and the server doesn't need to know its own public address. Each credential has one scope:
  - `owner`: the paired iPhone; there is at most one (see "Pairing"). Uploads, the write queue, wiping data, sync progress, managing API keys, plus every other endpoint. The phone generates the key, and the key never leaves the phone.
  - `read`: the read endpoints.
  - `readwrite`: the read endpoints, plus `POST /v1/writes`.
  - `read` and `readwrite` are API keys, created by the owner (see "API keys").
  - Every `/v1` endpoint except `GET /v1/health` and `POST /v1/pair` requires a key. A missing or unrecognized key returns `401` (with `WWW-Authenticate: Bearer`); insufficient scope returns `403`. A nonexistent `/v1` path returns `404` only for a valid key.
  - Each credential records when it was last used (`lastUsedAt`), updated at most once a minute.
  - Every request made with an API key is recorded in that key's activity log; owner requests aren't (see "API keys").
  - The server itself listens only on HTTP; a reverse proxy provides HTTPS. Keys must travel only over HTTPS.
- Timestamps: ISO 8601 with a UTC offset, to the second, for example `2026-11-01T08:00:00+08:00`.
  - When reading, the offset is the time zone the sample recorded (metadata `HKTimeZone`); if the sample recorded none, it's the device's time zone at sync time.
  - The server compares timestamps as absolute times, never as strings.
- Optional fields without a value are **omitted**, never output as `null`. The exception is fields this document explicitly gives as `null` (such as `share` and `updatedAt` in `GET /v1/authorization`), which mean the whole piece of data doesn't exist yet.
- Error responses: `{"error": "<message>"}`, with a 4xx/5xx status code.

## Object format (HealthKit samples)

Samples returned by reads and objects submitted for writes use the same structure. Field names match HealthKit property names. A quantity (`HKQuantity`) is always written as `{"value": <number>, "unit": "<HKUnit string>"}`. Fields marked "read-only" appear in read results; submitting them in a write returns `400`.

**The definitions the API returns are authoritative for each kind's object format** (`GET /v1/schema/kinds/{kind}`, see "Schema"). They come from a declarative table in the server's source (`internal/store/kinds.go`). `POST /v1/writes` validates against the same table, so the two can't disagree:

- Which fields exist: submitting a field that isn't in the table returns `400 {"error": "<path>.<field> is not a field of kind <kind>"}` (checked at every level, so a misspelled field name is never silently ignored). The contents of `metadata` are exempt.
- Each field's type (`timestamp`, `quantity`, `integer`, `number`, `string`, `uuid`, `boolean`, `object`, `array`), whether it's required (`true`, or a condition described in words), whether it's read-only (`readOnly`), whether it's used only for writing (`writeOnly`), which SDK enum its values come from (`enum`; a submitted value must be one of that enum's raw values), and a one-sentence description.
- Rules the table can't express (value ranges, constraints between fields) are checked in code, and each one is written in the description of the field it applies to.

The sections below describe the same format in prose, for easier reading. Where they differ, the API is authoritative.

### Read and write capabilities

**This table is authoritative** for whether each kind of data can be read and written (it matches `kinds` in `GET /v1/schema`; a server test checks that the two agree). "Read" means the app syncs the data to the server, where it can be read with `GET /v1/samples` and `GET /v1/changes` (or the endpoint noted in the table). "Write" means it can be submitted with `POST /v1/writes`, and the app saves it to Health.

| kind | HealthKit class | `type` | Read | Write | How |
|---|---|---|---|---|---|
| `quantity` | `HKQuantitySample` | `HKQuantityTypeIdentifier…` | ✓ | ✓ | `HKHealthStore.save`; a series (`series`) is written with `HKQuantitySeriesSampleBuilder` and read with `HKQuantitySeriesSampleQuery` |
| `category` | `HKCategorySample` | `HKCategoryTypeIdentifier…` | ✓ | ✓ | `HKHealthStore.save` |
| `correlation` | `HKCorrelation` | `HKCorrelationTypeIdentifierFood`, `HKCorrelationTypeIdentifierBloodPressure` | ✓ | ✓ | `HKHealthStore.save`; members can only be `quantity` |
| `workout` | `HKWorkout` | `HKWorkoutTypeIdentifier` | ✓ | ✓ | `HKWorkoutBuilder` (attached samples, activities, events); the route with `HKWorkoutRouteBuilder`; the effort score is related with `relateWorkoutEffortSample` |
| `workoutRoute` | `HKWorkoutRoute` | `HKWorkoutRouteTypeIdentifier` | ✓ | With its workout | Read with `HKWorkoutRouteQuery`; can only be written as a workout's `route` field; submitting it on its own returns `400` |
| `stateOfMind` | `HKStateOfMind` | `HKDataTypeStateOfMind` | ✓ | ✓ | `HKHealthStore.save` |
| `heartbeatSeries` | `HKHeartbeatSeriesSample` | `HKDataTypeIdentifierHeartbeatSeries` | ✓ | ✓ | Written with `HKHeartbeatSeriesBuilder`, read with `HKHeartbeatSeriesQuery` |
| `audiogram` | `HKAudiogramSample` | `HKDataTypeIdentifierAudiogram` | ✓ | ✓ | `HKHealthStore.save` |
| `scoredAssessment` | `HKGAD7Assessment`, `HKPHQ9Assessment` | `HKScoredAssessmentTypeIdentifierGAD7`, `HKScoredAssessmentTypeIdentifierPHQ9` | ✓ | ✓ | `HKHealthStore.save`; HealthKit computes `score` and `risk` |
| `visionPrescription` | `HKGlassesPrescription`, `HKContactsPrescription` | `HKVisionPrescriptionTypeIdentifier` | ✓ | ✓ | Reading requires the user to allow each prescription on the phone (per-object authorization, as with medications); written with `HKHealthStore.save` |
| `cdaDocument` | `HKCDADocumentSample` | `HKDocumentTypeIdentifierCDA` | ✗ | ✗ | Not supported: reading requires per-object authorization and crashes the app on a real device; Apple Health has no place that shows it |
| `electrocardiogram` | `HKElectrocardiogram` | `HKDataTypeIdentifierElectrocardiogram` | ✓ | ✗ | Voltages are read with `HKElectrocardiogramQuery`; HealthKit doesn't let apps create it |
| `medicationDoseEvent` | `HKMedicationDoseEvent` (iOS 26) | `HKMedicationDoseEventTypeIdentifierMedicationDoseEvent` | ✓ | ✗ | HealthKit doesn't let apps create it |
| `userAnnotatedMedication` | `HKUserAnnotatedMedication` (iOS 26, not a sample) | `HKDataTypeUserAnnotatedMedicationConcept` | ✓ `GET /v1/medications` | ✗ | Reading requires the user to allow each medication on the phone; HealthKit doesn't let apps create it |
| — | Statistics (`HKStatisticsCollectionQuery`) | quantity types | ✓ `GET /v1/statistics` | ✗ | Computed on the phone; not in the change feed |
| `activitySummary` | Activity rings (`HKActivitySummary`) | `HKActivitySummaryTypeIdentifier` | ✓ `GET /v1/activity-summaries` | ✗ | `HKActivitySummaryQuery`; not in the change feed |
| `characteristic` | User characteristics (sex, date of birth, etc., `HKCharacteristicType`) | `HKCharacteristicTypeIdentifier…` | ✓ `GET /v1/characteristics` | ✗ | Set by the user in Health |
| `clinicalRecord` | Health Records (`HKClinicalRecord`) | `HKClinicalTypeIdentifier…` | ✗ | ✗ | Not supported; see the end of this section |

- Submitting a kind that can't be written returns `400`. Submitting a `workoutRoute` on its own returns the error `write a route as part of its workout (the workout's route field)`.
- `userAnnotatedMedication`, `activitySummary`, `characteristic`, and `clinicalRecord` aren't samples and have no object format. They're listed here so that `GET /v1/schema` can say which kind every HealthKit type belongs to.
- Within a writable kind, whether a particular type can be written, and whether the user allows Rendu to write it, is determined by the authorization status the phone uploads; see `GET /v1/authorization`. HealthKit doesn't let third-party apps write some types (such as `HKQuantityTypeIdentifierWalkingHeartRateAverage` and `HKQuantityTypeIdentifierEstimatedWorkoutEffortScore`); they aren't in the authorization table.
- For unsupported data, see the end of this section.

### Common fields

| Field | Type | Description |
|---|---|---|
| `uuid` | string | `HKObject.uuid`. Always present when reading; the deduplication key. Not provided when writing |
| `kind` | string | See the table above: `quantity` / `category` / `correlation` / `workout` / `workoutRoute` / `stateOfMind` / `heartbeatSeries` / `audiogram` / `scoredAssessment` / `visionPrescription` / `cdaDocument` / `electrocardiogram` / `medicationDoseEvent` |
| `type` | string | `HKObjectType.identifier`, such as `HKQuantityTypeIdentifierStepCount` |
| `startDate` | string | `HKSample.startDate` |
| `endDate` | string | `HKSample.endDate`; equal to `startDate` for instantaneous samples |
| `sourceRevision` | object | Read-only. `{source: {name, bundleIdentifier}, version, productType, operatingSystemVersion}` |
| `device` | object | Read-only. The non-empty fields of `HKDevice`: `name`, `manufacturer`, `model`, `hardwareVersion`, `firmwareVersion`, `softwareVersion`, `localIdentifier`, `UDIDeviceIdentifier` |
| `metadata` | object | HealthKit metadata, passed through as is. Keys are HealthKit's raw strings (such as `HKTimeZone`, `HKWasUserEntered`, `HKFoodType`, `HKMetadataKeySyncIdentifier`; for each key's definition, see `GET /v1/schema/metadata/{key}`). Strings, numbers, and Booleans are output as is; dates are converted to timestamp strings; an `HKQuantity` is converted to a string (such as `"12 kcal"`). When writing, values can only be strings, numbers, or Booleans |

When writing, `startDate` and `endDate` are required and `endDate >= startDate`, unless a kind specifies otherwise (see each section).

### `kind: quantity` (`HKQuantitySample`)

| Field | Description |
|---|---|
| `quantity` | `{"value": 62, "unit": "count/min"}`. `unit` is `HKUnit.unitString`. For a series sample, `quantity` is the value HealthKit aggregates: the sum for cumulative types, the average for discrete types |
| `count` | Read-only. `HKQuantitySample.count`: the number of values the sample contains. Output only when > 1 (series samples) |
| `series` | Every value of a series sample (`count` > 1) (`HKQuantitySeriesSampleQuery`): `[{"quantity": {value, unit}, "startDate", "endDate"}]` |
| `minimumQuantity`, `maximumQuantity`, `mostRecentQuantity` | Read-only. Present only on series samples of discrete types (`HKDiscreteQuantitySample`): the minimum, maximum, and most recent value |
| `mostRecentQuantityDateInterval` | Read-only. As above: the time of the most recent value, `{"startDate", "endDate"}` |

Reads use a fixed unit for each type; see Appendix A. Percentage types follow HealthKit's native semantics: a fraction from 0 to 1 (`0.18` with `"%"` means 18%). Writes may use any `HKUnit` string compatible with the type (such as `"lb"`, `"mg"`, `"mcg"`); the app validates it.

Writing:

- Give either `quantity` or `series`, not both.
- `series`: a non-empty array. Each item needs `quantity`, `startDate`, and `endDate` (`endDate >= startDate`), and must fall within the sample's `startDate`–`endDate` range. The app writes it with `HKQuantitySeriesSampleBuilder`; HealthKit may store one series as several samples, and the reported `uuids` include all of them.
- Only a quantity submitted on its own can use `series`; correlation members and samples attached to a workout can only use `quantity`.
- `count`, `minimumQuantity`, `maximumQuantity`, `mostRecentQuantity`, and `mostRecentQuantityDateInterval` can't be submitted.

### `kind: category` (`HKCategorySample`)

| Field | Description |
|---|---|
| `value` | `HKCategorySample.value`, the raw integer value |
| `valueName` | Read-only. The enum case name (such as `asleepREM`). Output only for the types listed in Appendix B |

For the enum each category type's values come from, see `sdk.values` in `GET /v1/schema/types/{type}` (all of the enum's values are inlined there).

### `kind: correlation` (`HKCorrelation`)

Types: `HKCorrelationTypeIdentifierFood`, `HKCorrelationTypeIdentifierBloodPressure`.

| Field | Description |
|---|---|
| `objects` | When reading, an array of the member samples' uuids; the member samples also appear as ordinary samples under their own types. When writing, an array of member objects (`kind: quantity`; `startDate`/`endDate` may be omitted and default to the correlation's) |

When writing food (`HKCorrelationTypeIdentifierFood`), the app also writes the `HKFoodType` from the correlation's metadata onto each nutrient sample (Apple Health lists the nutrients, not the meal), except for members that set their own `HKFoodType`.

### `kind: workout` (`HKWorkout`, workouts)

| Field | Description |
|---|---|
| `workoutActivityType` | Raw `HKWorkoutActivityType` value (an integer), such as 37 running or 50 traditionalStrengthTraining. For all values, see `GET /v1/schema/enums/HKWorkoutActivityType` |
| `workoutActivityTypeName` | The enum case name (the Swift case name, i.e. the `short` of each case of that enum), such as `running` or `traditionalStrengthTraining`; deprecated or unknown values are `activity_<n>` |
| `duration` | Read-only, in seconds |
| `statistics` | Read-only. `HKWorkout.allStatistics`: `{"<quantity type>": {"sumQuantity": {...}, "averageQuantity": {...}, "minimumQuantity": {...}, "maximumQuantity": {...}}}`; each is `{value, unit}`, in the units of Appendix A |
| `workoutActivities` | Array of `HKWorkoutActivity` (such as the legs of a triathlon or the sets of a swim); see below |
| `workoutEvents` | Array of `HKWorkoutEvent` (pauses, laps, etc.); see below |
| `effortRelationships` | Read-only. Array of `HKWorkoutEffortRelationship`: the effort scores related to this workout. Each item is `{"samples": [uuid, …], "activityUUID": "…"}`; `samples` are the uuids of the effort score samples, and `activityUUID` is output only when the score is related to one activity (`workoutActivities[].uuid`) |
| `samples` | Write-only; see below |
| `route` | Write-only; see below. When reading, the route is a separate `workoutRoute` object |

Each item of `workoutActivities`:

| Field | Description |
|---|---|
| `uuid` | Read-only. `HKWorkoutActivity.uuid` |
| `workoutConfiguration` | `HKWorkoutConfiguration`: `activityType` (raw `HKWorkoutActivityType` value), `activityTypeName` (like `workoutActivityTypeName`), `locationType` (raw `HKWorkoutSessionLocationType` value: 1 unknown, 2 indoor, 3 outdoor), `swimmingLocationType` (raw `HKWorkoutSwimmingLocationType` value: 0 unknown, 1 pool, 2 openWater), `lapLength` (pool length, `{value, unit}`). Fields without a value are omitted |
| `startDate`, `endDate` | When this activity starts and ends |
| `duration` | Read-only, in seconds |
| `statistics` | Read-only. This activity's statistics, in the same format as the workout's `statistics` |
| `metadata` | Optional |

Each item of `workoutEvents`: `type` (raw `HKWorkoutEventType` value: 1 pause, 2 resume, 3 lap, 4 marker, 5 motionPaused, 6 motionResumed, 7 segment, 8 pauseOrResumeRequest), `startDate`, `endDate`, `metadata` (optional). As HealthKit requires, only lap and segment events can have a duration; for other events, `endDate` equals `startDate`.

Writing (the app executes it with `HKWorkoutBuilder`):

- `startDate` and `endDate` are required.
- Give either `workoutActivityType` or `workoutActivityTypeName`, not both. The former must be a raw `HKWorkoutActivityType` value; the latter must be one of its `short` names, with deprecated raw values written as `activity_<n>` (such as `activity_14`).
- `samples`: optional. An array of `kind: quantity` objects, each with `startDate` and `endDate`, falling within the workout's time range. The app adds them to the workout with `HKWorkoutBuilder.add`, and HealthKit computes the workout's `statistics` from them (such as active energy and distance). The effort score (`HKQuantityTypeIdentifierWorkoutEffortScore`, unit `appleEffortScore`, 1–10) is the exception: the app saves it separately, then relates it to the workout with `relateWorkoutEffortSample`; after that it appears in `effortRelationships`.
- `workoutActivities`: optional. Each item has `workoutConfiguration` (either `activityType` or `activityTypeName`; `locationType`, `swimmingLocationType`, and `lapLength` are optional), `startDate` (required), `endDate` (optional), and `metadata` (optional), and falls within the workout's time range. `uuid`, `duration`, and `statistics` can't be submitted.
- `workoutEvents`: optional. In each item, `type`, `startDate`, and `endDate` are required and `metadata` is optional; the event falls within the workout's time range. When `type` isn't 3 lap or 7 segment, `endDate` must equal `startDate`.
- `route`: optional. A non-empty array where each item is a location: `timestamp` (within the workout's time range), `latitude` (-90 to 90), and `longitude` (-180 to 180) are required; `altitude`, `horizontalAccuracy`, `verticalAccuracy`, `speed`, and `course` are optional, in the same units as `workoutRoute`. The app writes it with `HKWorkoutRouteBuilder` and relates it to the workout; when read, it's a separate `workoutRoute` object.
- `duration`, `statistics`, and `effortRelationships` are generated by HealthKit; submitting them returns `400`.
- The types this write involves (for the authorization check and `replaceTypes`): `HKWorkoutTypeIdentifier`, the `type` of each attached sample, and `HKWorkoutRouteTypeIdentifier` when there's a `route`. The `uuids` the app reports include the workout, the attached samples (including the effort score), and the route.

### `kind: workoutRoute` (`HKWorkoutRoute`, workout routes)

`type` is `HKWorkoutRouteTypeIdentifier`. `locations`: an array of `CLLocation`, each with `timestamp` (a timestamp), `latitude`, `longitude` (degrees), `altitude` (m), `horizontalAccuracy`, `verticalAccuracy` (m), `speed` (m/s), and `course` (degrees).

A route is a separate sample, matched to a workout by time: a route that falls within a `workout`'s `startDate`–`endDate` range is that workout's route.

It can't be written on its own; see the workout's `route` field.

### `kind: heartbeatSeries` (`HKHeartbeatSeriesSample`, heartbeat series)

`type` is `HKDataTypeIdentifierHeartbeatSeries`. Every heartbeat Apple Watch records when it measures heart rate variability. A `beats` array; each item has `timeSinceSeriesStart` (seconds since `startDate`) and `precededByGap` (whether readings were missed before this heartbeat).

Writing (the app executes it with `HKHeartbeatSeriesBuilder`): `startDate` is required; HealthKit sets `endDate` to the time of the last heartbeat, and submitting it returns `400`. `beats` is non-empty, and each item requires `timeSinceSeriesStart` (a number, ≥ 0, strictly increasing) and `precededByGap` (a Boolean).

### `kind: stateOfMind` (`HKStateOfMind`, state of mind)

`type` is `HKDataTypeStateOfMind`.

| Field | Description |
|---|---|
| `stateOfMindKind` | Raw `HKStateOfMind.Kind` value: 1 momentaryEmotion (an emotion felt in the moment), 2 dailyMood (the mood over a day) |
| `valence` | How pleasant it felt, from -1 (very unpleasant) to 1 (very pleasant) |
| `valenceClassification` | Read-only. The raw `HKStateOfMind.ValenceClassification` value derived from `valence`: 1 veryUnpleasant, 2 unpleasant, 3 slightlyUnpleasant, 4 neutral, 5 slightlyPleasant, 6 pleasant, 7 veryPleasant |
| `labels` | Array of raw `HKStateOfMind.Label` values (such as 29 stressed). For all values, see `GET /v1/schema/enums/HKStateOfMind.Label` |
| `associations` | Array of raw `HKStateOfMind.Association` values (such as 17 work). See `GET /v1/schema/enums/HKStateOfMind.Association` |

Writing: a state of mind is a moment. `startDate` is required; `endDate` may be omitted, and when provided it must equal `startDate`. `stateOfMindKind` and `valence` are required; `labels` and `associations` may be omitted (the same as an empty array), and when provided, every item must be a raw value of the corresponding enum.

### `kind: electrocardiogram` (`HKElectrocardiogram`, ECG, read-only)

| Field | Description |
|---|---|
| `classification` | Raw `HKElectrocardiogram.Classification` value (`GET /v1/schema/enums/HKElectrocardiogram.Classification`) |
| `symptomsStatus` | Raw `HKElectrocardiogram.SymptomsStatus` value |
| `averageHeartRate` | `{value, unit: "count/min"}` |
| `samplingFrequency` | `{value, unit: "Hz"}` |
| `numberOfVoltageMeasurements` | Number of voltage measurements |
| `voltageMeasurements` | The voltage waveform (`HKElectrocardiogramQuery`): `[{"timeSinceSampleStart": <seconds>, "appleWatchSimilarToLeadI": <number>}]`. Voltages are in microvolts (HKUnit `mcV`), written as plain numbers to keep the size down. Each ECG has about 15,000 points |

### `kind: audiogram` (`HKAudiogramSample`, hearing test results)

`type` is `HKDataTypeIdentifierAudiogram`.

`sensitivityPoints`: one item per frequency (`HKAudiogramSensitivityPoint`):

| Field | Description |
|---|---|
| `frequency` | The frequency, `{value, unit: "Hz"}` |
| `tests` | Array of test results at this frequency (`HKAudiogramSensitivityTest`). Each item: `sensitivity` (hearing threshold, `{value, unit: "dBHL"}`), `type` (conduction type, raw `HKAudiogramConductionType` value: 0 air), `masked` (whether masking was used, a Boolean), `side` (raw `HKAudiogramSensitivityTestSide` value: 0 left, 1 right), `clampingRange` (optional, the measurement range: `lowerBound` and `upperBound`, each `{value, unit: "dBHL"}`, omitted when absent) |

Writing uses the same format as reading: `startDate` and `endDate` are required; `sensitivityPoints` is non-empty; each item requires `frequency` and `tests`; `tests` is non-empty; each test requires `sensitivity`, `type`, `masked`, and `side`; when `clampingRange` is provided, it needs at least one of `lowerBound` and `upperBound`.

### `kind: scoredAssessment` (`HKScoredAssessment`, GAD-7 anxiety risk / PHQ-9 depression risk)

`type` is `HKScoredAssessmentTypeIdentifierGAD7` (`HKGAD7Assessment`) or `HKScoredAssessmentTypeIdentifierPHQ9` (`HKPHQ9Assessment`).

| Field | Description |
|---|---|
| `answers` | The answer to each question, an array of integers in question order: 0 notAtAll, 1 severalDays, 2 moreThanHalfTheDays, 3 nearlyEveryDay. Question 9 of PHQ-9 can also be 4 preferNotToAnswer |
| `score` | Read-only. The total score, computed by HealthKit from `answers` |
| `risk` | Read-only. Derived by HealthKit from `answers`. GAD-7 (`HKGAD7Assessment.Risk`): 1 noneToMinimal, 2 mild, 3 moderate, 4 severe; PHQ-9 (`HKPHQ9Assessment.Risk`): 1 noneToMinimal, 2 mild, 3 moderate, 4 moderatelySevere, 5 severe |

Writing: an assessment is a moment. `startDate` is required; `endDate` may be omitted, and when provided it must equal `startDate`. `answers` is required: exactly 7 for GAD-7, each 0–3; exactly 9 for PHQ-9, each 0–3, and the 9th can also be 4.

### `kind: visionPrescription` (`HKVisionPrescription`, vision prescriptions)

`type` is `HKVisionPrescriptionTypeIdentifier`.

| Field | Description |
|---|---|
| `prescriptionType` | Raw `HKVisionPrescriptionType` value: 1 glasses (`HKGlassesPrescription`), 2 contacts (contact lenses, `HKContactsPrescription`) |
| `dateIssued` | The date issued, a timestamp |
| `expirationDate` | Optional. The expiration date, a timestamp |
| `rightEye`, `leftEye` | Lens parameters for the right and left eye; at least one is present. See below |
| `brand` | The contact lens brand. Required for contact lenses; not allowed for glasses |
| `attachments` | Read-only. Information about files the user attached to the prescription in Health (`HKAttachment`): `identifier`, `name`, `contentType`, `size` (bytes), `creationDate`. File contents aren't uploaded |

Lens parameters (`HKGlassesLensSpecification` / `HKContactsLensSpecification`); all quantities are `{value, unit}`:

| Field | Description |
|---|---|
| `sphere` | Sphere power, required, in `D` (diopters); negative for nearsightedness |
| `cylinder` | Optional. Cylinder power (astigmatism), `D` |
| `axis` | Optional. Astigmatism axis, `deg` |
| `addPower` | Optional. Add power (for presbyopia), `D` |
| `vertexDistance` | Optional, glasses only. Vertex distance, `mm` |
| `prism` | Optional, glasses only. Prism (`HKVisionPrism`); see below |
| `farPupillaryDistance`, `nearPupillaryDistance` | Optional, glasses only. Pupillary distance for distance and near vision, `mm` |
| `baseCurve` | Optional, contact lenses only. Base curve, `mm` |
| `diameter` | Optional, contact lenses only. Diameter, `mm` |

`prism` can be written in one of two ways: `amount` (prism diopters, `pD`) + `angle` (base direction angle, `deg`); or `verticalAmount` + `verticalBase` + `horizontalAmount` + `horizontalBase` (amounts in `pD`; bases are raw `HKPrismBase` values: 0 none, 1 up, 2 down, 3 in, 4 out). It also has a required `eye` (raw `HKVisionEye` value: 1 left, 2 right).

- Reading: HealthKit sets `startDate` and `endDate`; they're present when reading. HealthKit requires the user to allow, one by one, which prescriptions the app may read (as with medications); only prescriptions the user allows on the phone are synced.
- Writing: `prescriptionType` and `dateIssued` are required; HealthKit sets `startDate` and `endDate`, and submitting them returns `400`. A glasses-only field on a contact lens prescription (or the reverse) returns `400`. `attachments` can't be submitted.

### `kind: cdaDocument` (`HKCDADocumentSample`, CDA clinical documents, not supported)

Reading requires per-object authorization, reading on a real device crashes the app, and Apple Health has no place that shows these documents, so Rendu neither reads nor writes them. Writing returns `400`.

### `kind: medicationDoseEvent` (`HKMedicationDoseEvent`, medication dose events, iOS 26, read-only)

`type` is `HKMedicationDoseEventTypeIdentifierMedicationDoseEvent`.

| Field | Description |
|---|---|
| `medicationId` | The medication; the same as `id` in `GET /v1/medications` |
| `medicationName` | The medication's name, i.e. its `displayText` |
| `scheduleType` | Raw `HKMedicationDoseEvent.ScheduleType` value: 1 asNeeded (taken as needed), 2 schedule (reminded on a schedule) |
| `logStatus` | Raw `HKMedicationDoseEvent.LogStatus` value: 1 notInteracted (no response to the reminder), 2 notificationNotSent (the reminder wasn't delivered), 3 snoozed (remind later), 4 taken, 5 skipped, 6 notLogged (an earlier log was undone) |
| `scheduledDate` | The scheduled time; omitted for as-needed medications |
| `scheduledDoseQuantity` | The scheduled dose (a number); omitted when absent |
| `doseQuantity` | The dose actually taken (a number); omitted when absent |
| `unit` | The dose unit (an `HKUnit` string) |

### Unsupported data

- Health Records (`HKClinicalRecord`, in FHIR format) and verifiable health records (`HKVerifiableClinicalRecord`, such as vaccination certificates): reading requires the Health Records entitlement, which Apple grants separately, and the feature isn't offered in mainland China.
- The file contents of attachments (`HKAttachment`, such as photos or PDFs of prescriptions): these are binary files; only information about the files is synced (see `attachments` in vision prescriptions).
- Some data in the Health app (Sleep Score, sleep schedules, balance, some fitness tests, etc.) is available only to Apple and has no public API; third-party apps can't read or write it.

---

## Endpoints without authentication

### `GET /v1/health`

Liveness check. Returns `200 {"ok": true}`.

### `POST /v1/pair` (pairing)

Pairs an iPhone as the server's owner.

1. The user enters the server address in the app. The app generates, on the device, a 6-digit pairing code and a 256-bit random key (base64url, 43 characters), and shows the pairing code and the command to run on the server.
2. The user runs `rendu-server pair CODE` on the server (Docker: `docker compose exec rendu rendu-server pair CODE`). The server accepts this pairing code for the next 5 minutes (running the command again replaces the previous code), and the command waits for the phone to finish pairing: on success it prints `{"paired": true, "id": "…"}`; if the code expires or is invalidated, it exits with an error.
3. The app sends a request every 2 seconds with the body `{"code": "123456", "key": "<key>"}`:
   - `404`: no pairing code has been entered on the server yet (or it expired or was invalidated); keep waiting.
   - `403`: a different pairing code was entered on the server. After 5 mismatched requests in total (including the app's polling), the pairing code is invalidated.
   - `400`: the key isn't 43–128 printable ASCII characters.
   - `200 {"paired": true, "id": "<credential id>"}`: the hash of this key becomes the owner, replacing the previously paired iPhone (requests from the old phone immediately return `401`). The pairing code is used up, and sync progress (see "Sync progress") is cleared: the new phone uploads all history once, and the server deduplicates by uuid. Write authorization (see `PUT /v1/authorization`) and the type catalog (see `PUT /v1/catalog`) are also cleared until the new phone uploads them. API keys are unaffected.

The plaintext key never appears in any response, terminal output, or log. The app stores it as a file in the app container (not in the Keychain, so deleting the app deletes it), with the data protection class "after first unlock" (background sync needs it while the device is locked), excluded from backups. The UI never shows the key; the only way to delete it is "Forget This Server".

---

Each group's heading gives the scope its endpoints require; `owner` can call every endpoint.

## Phone endpoints (`owner`, called by the app)

### `POST /v1/ingest`

The request body is a JSON array; each element is a **sample object** or a **deletion record**:

```json
[
  {"uuid": "…", "kind": "quantity", "type": "HKQuantityTypeIdentifierBodyMass",
   "startDate": "2026-11-01T08:00:00+08:00", "endDate": "2026-11-01T08:00:00+08:00",
   "quantity": {"value": 72.5, "unit": "kg"},
   "sourceRevision": {"source": {"name": "Rendu", "bundleIdentifier": "com.example.rendu"}},
   "metadata": {"HKMetadataKeySyncIdentifier": "…", "HKMetadataKeySyncVersion": 1}},
  {"deleted": ["A0B1C2D3-…", "E4F5A6B7-…"]}
]
```

- Delivery is at-least-once. The server deduplicates by `uuid` (a uuid that arrives again overwrites the earlier one).
- The uuids in a deletion record are marked as deleted, and the read endpoints no longer return them. A deletion whose uuid hasn't arrived yet must also be remembered: when the sample arrives later, it's treated as deleted right away.
- Malformed elements are skipped and counted in `rejected` (output only when greater than 0) instead of failing the whole batch; otherwise the app's upload queue would get stuck. A request body that isn't a JSON array returns `400`.
- A batch can carry sync progress (see the next section): `X-Rendu-Anchor-Type` (the type), `X-Rendu-Base-Anchor` (the anchor this batch of samples was read from; omitted when there is none), and `X-Rendu-Anchor` (the anchor the read reached). `X-Rendu-Anchor` without `X-Rendu-Anchor-Type` returns `400`.
- Response: `200 {"received": <elements>, "new": <new samples>, "deleted": <deletions>, "rejected": <skipped>, "anchor": "saved" | "stale"}`. `anchor` is output only when the batch carries sync progress.
- On a network error or 5xx, the app retries quickly once after 1 second and once after 3 seconds. If it still fails (or returns another non-2xx status), the app keeps the batch and retries with exponential backoff from 1 minute to 1 hour, without changing the order.

### Sync progress: `GET /v1/anchors`, `PUT /v1/anchors`

The server keeps a single set of sync progress: how far each type has synced, i.e. the anchor of the HealthKit query (opaque, base64). It belongs to the paired iPhone's Health database, so pairing an iPhone (see "Pairing") and `DELETE /v1/data` both clear it. It's written in the **same transaction** as the samples it covers, so it always matches the data the server actually has.

- When `POST /v1/ingest` carries sync progress, the server changes its stored anchor to `X-Rendu-Anchor` only if the stored anchor equals `X-Rendu-Base-Anchor` (both being absent also counts), and replies `"anchor": "saved"`. Otherwise it leaves the anchor alone and replies `"stale"` (the samples are still stored, deduplicated by uuid). For example, if the server was wiped while the phone was offline, the batches queued during that time were read from the old anchor, and the server's progress must not skip past the data that was lost.
- `GET /v1/anchors`: `{"anchors": {"HKQuantityTypeIdentifierHeartRate": "<base64>", …}}`. The app reads it before every sync. If it matches the local progress, the sync continues as usual. If it doesn't (the server was wiped, restored from a backup, or just paired), the app discards its queued batches and continues from the server's progress, uploading only what the server is missing; if the server has no progress, the app uploads all history. If it can't be read (offline), the app continues from its local progress.
- `PUT /v1/anchors`, body `{"anchors": {…}}`: replaces everything. The app uses it only to clear the progress (`{"anchors": {}}`) for "Re-import All History". Response `200 {"anchors": <count>}`.

### `GET /v1/latest`

The latest `endDate` on the server for each type: `{"HKQuantityTypeIdentifierHeartRate": "2026-11-01T08:59:12+08:00", …}`.

### `POST /v1/statistics`

Uploads statistics the app computed with `HKStatisticsCollectionQuery`. Each upload covers one type, one interval, and one time range:

```json
{
  "type": "HKQuantityTypeIdentifierStepCount",
  "interval": "day",
  "unit": "count",
  "timeZone": "Asia/Shanghai",
  "rangeStart": "2026-10-25T00:00:00+08:00",
  "rangeEnd": "2026-11-02T00:00:00+08:00",
  "statistics": [
    {"startDate": "2026-11-01T00:00:00+08:00", "endDate": "2026-11-02T00:00:00+08:00", "sumQuantity": 8123}
  ]
}
```

- `interval`: `hour` or `day`. Daily statistics cover all history; hourly statistics cover only about the last 30 days.
- Statistic field names match `HKStatistics` methods; values are numbers in `unit`:
  - Cumulative types: `sumQuantity`.
  - Discrete types: `averageQuantity`, `minimumQuantity`, `maximumQuantity`, `mostRecentQuantity`, `mostRecentQuantityDateInterval` (`{startDate, endDate}`).
  - `duration` (`HKStatisticsOptions.duration`): the total time covered by samples in the period, in seconds (unaffected by `unit`). Output only for types HealthKit computes it for (such as environmental sound levels and headphone audio levels).
- Only periods with data are included.
- In one transaction, the server first deletes the old records of that `type` + `interval` whose `startDate` falls in `[rangeStart, rangeEnd)`, then writes the new records. Response `200 {"stored": <count>}`.

### `POST /v1/activity-summaries`

An array of `HKActivitySummary`, replacing existing data by `dateComponents`:

```json
[{"dateComponents": "2026-11-01", "activityMoveMode": 1, "paused": false,
  "activeEnergyBurned": 520.3, "activeEnergyBurnedGoal": 600,
  "appleMoveTime": 0, "appleMoveTimeGoal": 0,
  "appleExerciseTime": 32, "exerciseTimeGoal": 30,
  "appleStandHours": 10, "standHoursGoal": 12}]
```

Units are fixed: energy in `kcal`, time in `min`, stand in `count` (hours). Fields without a value are omitted. Response `200 {"stored": <count>}`.

### `PUT /v1/characteristics`

User characteristics, replaced as a whole:

```json
{"biologicalSex": 2, "dateOfBirth": "1995-01-01", "bloodType": 0,
 "fitzpatrickSkinType": 0, "wheelchairUse": 1, "activityMoveMode": 1}
```

All are HealthKit raw values (`HKBiologicalSex`: 0 notSet, 1 female, 2 male, 3 other). Fields that aren't authorized or aren't set are omitted.

### `PUT /v1/authorization`

The app uploads its write authorization for each type (`HKHealthStore.authorizationStatus(for:)`, as `HKAuthorizationStatus` names), replacing everything:

```json
{"share": {"HKQuantityTypeIdentifierBodyMass": "sharingAuthorized",
           "HKQuantityTypeIdentifierDietaryProtein": "sharingDenied",
           "HKWorkoutTypeIdentifier": "notDetermined"}}
```

- Values: `sharingAuthorized` (allowed), `sharingDenied` (the user turned it off in Health settings), `notDetermined` (the user hasn't been asked yet).
- Lists only types the app can request write access for. **A type not in the table is one HealthKit doesn't let third-party apps write** (such as `WalkingHeartRateAverage`). Correlation types (`HKCorrelationTypeIdentifier…`) have no authorization of their own and aren't listed.
- The app uploads it at launch and after authorization changes. The server checks writes against it on `POST /v1/writes`; see that section. It's cleared when a new iPhone is paired, and not cleared by `DELETE /v1/data`.
- Response `200 {"stored": <type count>}`. Returns `400` if `share` isn't an object or a value isn't recognized.

### `PUT /v1/medications`

The app uploads the user's medication list from Health (`HKUserAnnotatedMedication`, iOS 26, read with `HKUserAnnotatedMedicationQuery`), replacing everything; the server stores it as is:

```json
{"medications": [
  {"id": "…", "medication": {"displayText": "Amlodipine 5 mg Oral Tablet", "generalForm": "tablet",
                             "relatedCodings": [{"system": "http://www.nlm.nih.gov/research/umls/rxnorm", "code": "197361"}]},
   "nickname": "Blood pressure pill", "isArchived": false, "hasSchedule": true}
]}
```

| Field | Description |
|---|---|
| `id` | The medication's stable identifier (`medication.identifier`); the `medicationId` of dose events points to it |
| `medication` | `HKMedicationConcept`: `displayText` (the name), `generalForm` (the dosage form, such as `tablet` or `capsule`), `relatedCodings` (array of `HKClinicalCoding`: `system`, `version`, `code`, such as RxNorm codes; `version` is omitted when absent. An empty array when there are no codings) |
| `nickname` | The nickname the user gave it; omitted when absent (or empty) |
| `isArchived` | Whether the user archived it (no longer takes it) |
| `hasSchedule` | Whether a schedule is set |

- `medications` must be an array of objects; otherwise returns `400`. Response `200 {"stored": <count>}`.
- `DELETE /v1/data` clears it.

### `PUT /v1/catalog`

The app uploads the types this iPhone's HealthKit actually supports (the type catalog), replacing everything. The server stores it as is and serves it to the API through `GET /v1/schema`:

```json
{"os": "27.1",
 "types": [
   {"type": "HKQuantityTypeIdentifierBodyMass", "kind": "quantity", "name": {"en": "Weight", "zh-Hans": "体重"},
    "unit": "kg", "preferredUnit": "kg", "aggregation": "discreteArithmetic"},
   {"type": "HKCategoryTypeIdentifierSleepAnalysis", "kind": "category", "name": {"en": "Sleep", "zh-Hans": "睡眠"},
    "values": [{"value": 0, "name": "inBed"}, {"value": 1, "name": "asleepUnspecified"}]},
   {"type": "HKVisionPrescriptionTypeIdentifier", "kind": "visionPrescription", "perObject": true}
 ]}
```

| Field | Description |
|---|---|
| `os` | The phone's iOS version |
| `type`, `kind` | The type identifier and the kind it belongs to (see "Read and write capabilities") |
| `name` | Apple's display name in `en` and `zh-Hans`; missing ones are omitted |
| `unit` | Quantity only: the unit Rendu reads and returns this type in (see Appendix A) |
| `preferredUnit` | Quantity only: the unit the user uses in Apple Health (`preferredUnits(for:)`); present only when known |
| `aggregation` | Quantity only: the name of the `HKQuantityAggregationStyle`: `cumulative`, `discreteArithmetic`, `discreteTemporallyWeighted`, `discreteEquivalentContinuousLevel` |
| `values` | Category types with named values: `[{"value": <raw value>, "name": <name>}]` |
| `minimumDuration`, `maximumDuration` | Present only when HealthKit limits the sample duration (`minimumAllowedDuration`, `maximumAllowedDuration`), in seconds |
| `perObject` | `true` when HealthKit requires per-object read authorization (`requiresPerObjectAuthorization`); otherwise omitted |

- `os` must be a non-empty string, `types` a non-empty array of objects, and each item's `type` and `kind` non-empty strings; otherwise returns `400`. Other fields are stored as is. Response `200 {"stored": <type count>}`.
- The app uploads it at launch and after the iOS version changes. It's cleared when a new iPhone is paired, and not cleared by `DELETE /v1/data` (it describes the phone, not the data).

### `GET /v1/writes/pending`

Returns pending write requests in submission order, at most 500 at a time. **For each `syncIdentifier`, only the earliest one is returned at a time**; the next one is returned only after the previous one has a result:

```json
{"writes": [
  {"id": "…", "op": "save", "syncIdentifier": "…", "syncVersion": 2,
   "object": { … }, "replaceUUIDs": ["…"], "replaceTypes": ["HKQuantityTypeIdentifierBodyMass"],
   "submittedBy": {"id": "…", "name": "My Agent"}},
  {"id": "…", "op": "delete", "syncIdentifier": "…", "replaceUUIDs": ["…"], "replaceTypes": ["…"]}
],
 "anchor": "42"}
```

- `replaceUUIDs`: the HealthKit uuids from this `syncIdentifier`'s last successful write (`written`); for a correlation they include its members, and for a workout its attached samples and route. An empty array when the last write was a delete or a `conflict`.
- `replaceTypes`: the types involved in the object of the last write (the object's own `type`, plus the `type` of each correlation member and of each sample attached to a workout, and `HKWorkoutRouteTypeIdentifier` when there's a route), deduplicated. HealthKit needs the type to look up an object by uuid.
- When the server has no earlier `written` or `conflict` write for this `syncIdentifier` (a first write, or the server's data was wiped), both come from samples the phone uploaded: the uuids and types of non-deleted samples whose metadata `HKMetadataKeySyncIdentifier` is X or starts with `X:` (members, attached samples, routes), with the object itself first. Both are empty arrays when there are no such samples.
- `submittedBy`: the credential that submitted this write, as in the `POST /v1/writes` response.
- `anchor`: the position of the most recently submitted write (an opaque string); it changes with every submitted write.
- Waiting for new writes (used while the app is in the foreground; there are no push notifications): pass the previous `anchor` and `wait` (seconds, 0–60). If there's already a newer write, the request returns immediately; otherwise it returns when a write is submitted or when the wait times out, in the same response format. Without `anchor`, it doesn't wait. Older writes that haven't been executed yet (such as ones waiting for authorization) don't make the request return immediately.

### `POST /v1/writes/results`

Reports write results; can be batched:

```json
[{"id": "…", "status": "written", "uuids": ["…"]},
 {"id": "…", "status": "failed", "error": "unit 'kg' is not compatible with HKQuantityTypeIdentifierStepCount"},
 {"id": "…", "status": "conflict", "error": "previous objects no longer exist in Health"}]
```

Response `200 {"updated": <count>}`. Reporting the same result again is safe.

### `DELETE /v1/data`

Wipes all health data on the server: samples, deletion records, statistics, activity rings, user characteristics, the medication list, sync progress, and all write requests (including `pending` ones), and assigns a new `dataId` (earlier change-feed anchors become invalid; see `GET /v1/changes`). Credentials are unchanged: the phone doesn't need to pair again, API keys keep working, and `lastUsedAt` (and `lastDeviceSeenAt`) and API activity logs are kept. Write authorization and the type catalog are also kept (they describe the phone, not the data). Response `200 {"wiped": true}`.

The app's "Clear Server Data" calls it and then syncs right away: the server has no sync progress, so the app uploads all of the device's Health history again. Data in Health is unaffected.

### API keys: `GET /v1/keys`, `POST /v1/keys`, `DELETE /v1/keys/{id}`, `GET /v1/keys/{id}/activity`

Keys for the CLI and other tools, managed by the owner (in the app: Settings → API Keys).

- `GET /v1/keys`: `{"keys": [{"id": "…", "name": "iPhone", "scope": "owner", "createdAt": "…", "lastUsedAt": "…"}, …]}`. Includes the owner itself, listed first; the rest are in order of creation. `lastUsedAt` is omitted if the key was never used. The keys themselves aren't included.
- `POST /v1/keys`, body `{"name": "My Agent", "scope": "read" | "readwrite"}` (`name` is 1–100 characters): responds `201` with the credential fields above plus `key`. The key format is `rdk_` followed by 43 base62 characters. The plaintext appears only in this response; the server stores only the hash.
- `DELETE /v1/keys/{id}`: revokes the key, effective immediately; its activity log is deleted with it. Response `200 {"revoked": true}`. Returns `404` if there's no such key or it's the owner (the owner can only be replaced by pairing a new iPhone).

#### API activity: `GET /v1/keys/{id}/activity`

Like the App Privacy Report in iOS: every `/v1` request made with an API key (including rejected ones) is recorded; owner requests aren't. Records are kept for 90 days.

Parameters: `limit` (default 100, maximum 500), `before` (the `next` returned with the previous page). Records are in reverse chronological order (newest first):

```json
{"activity": [
  {"at": "2026-11-02T13:05:00Z", "method": "POST", "path": "/v1/writes",
   "type": "HKQuantityTypeIdentifierBodyMass", "count": 1, "writeId": "…", "status": 201},
  {"at": "2026-11-02T13:04:58Z", "method": "GET", "path": "/v1/samples",
   "type": "HKQuantityTypeIdentifierBodyMass", "start": "2026-10-03T21:04:58+08:00", "count": 12, "status": 200}
], "next": "…"}
```

| Field | Description |
|---|---|
| `at` | The request time |
| `method`, `path` | The request method and endpoint path (the route template, such as `/v1/writes/{id}`; the actual path for nonexistent endpoints) |
| `type` | The type the request involves: the `type` query parameter (multiple types for `GET /v1/changes` are joined with commas); for `POST /v1/writes`, the submitted object's `type`; for `GET /v1/schema/types/{type}`, the type in the path |
| `start`, `end`, `interval` | Query parameters, recorded as is |
| `count` | The number of items returned: samples, statistics, days of activity summaries, write requests, change-feed samples plus deletion records, or medications; 1 for a successful `POST /v1/writes` |
| `writeId` | The write request created by `POST /v1/writes` or queried by `GET /v1/writes/{id}` |
| `status` | The HTTP status code |

Fields that don't apply or have no value are omitted. `next` is `null` when there are no earlier records. Returns `404` if there's no such key.

---

## Read and write endpoints (`read`; `POST /v1/writes` requires `readwrite`. Called by AI agents and the CLI; the app's Browse and Settings tabs also read them)

### `GET /v1/status`

```json
{"serverTime": "…", "lastIngestAt": "…", "lastDeviceSeenAt": "…",
 "dataId": "9F2C…", "samples": 1234567, "types": 45, "pendingWrites": 0,
 "version": "c4d9a27", "startedAt": "…"}
```

- `lastDeviceSeenAt`: when the paired iPhone last called an endpoint that requires authentication, i.e. the owner credential's `lastUsedAt` (updated at most once a minute). Use it to judge how fresh the data is.
- `lastIngestAt`: the time of the last `POST /v1/ingest`.
- `dataId`: the identifier of the server's health data. Generated when the database is created and replaced after `DELETE /v1/data`; it doesn't change otherwise.
- `samples`: the number of non-deleted samples. `types`: the number of types that have received samples (including types whose samples were all deleted). `pendingWrites`: the number of writes with status `pending`.
- `version`: the server build version. `startedAt`: when the server process started.
- Time fields without a value are omitted (for example, before an iPhone is paired, if nothing has ever been uploaded, or after the data is wiped).
- The app uses it to check the server's status: when a request fails, the app tries again after 1.5 seconds and shows the server as offline only if that fails too. `401` means this iPhone has been replaced, and the app prompts the user to pair again.

### `GET /v1/types`

Types that have data on the server:

```json
{"types": [{"type": "HKQuantityTypeIdentifierBodyMass", "kind": "quantity",
            "count": 812, "firstStartDate": "…", "lastEndDate": "…", "share": "sharingAuthorized"}]}
```

`share`: this type's write authorization (see `GET /v1/authorization`); output only when the authorization table the phone uploaded includes this type.

### `GET /v1/samples`

Parameters:

| Parameter | Description |
|---|---|
| `type` | Required |
| `start`, `end` | Optional, timestamps. Returns samples that overlap `[start, end)` |
| `source` | Optional. Filters by `sourceRevision.source.bundleIdentifier` |
| `order` | Optional. `desc` for reverse order (newest first); any other value, or none, for ascending order |
| `limit` | Default 1000, maximum 10000 |
| `cursor` | The `nextCursor` returned with the previous page. Keep `order` the same when paging |

`type` is a HealthKit type identifier; constant names are also accepted. An unknown type returns `400 {"error": "unknown type \"…\"; did you mean …?"}` (with the closest identifiers) instead of being treated as having no data; a type that's in the SDK but has no data on the server returns an empty list. The same applies to `type` in `GET /v1/statistics` and `GET /v1/changes`. A type that already has data on the server but is newer than the server's SDK snapshot works as usual.

Sorted by `startDate`, and by `uuid` when `startDate` is equal. Response `{"samples": [ … ], "nextCursor": "…"}`; `nextCursor` is omitted when there's no next page. Deleted samples aren't returned.

### `GET /v1/statistics`

Parameters: `type` (required), `interval` (`day`, the default, or `hour`), `start`, `end`.

Response `{"type": "…", "interval": "day", "unit": "count", "statistics": [ … ]}`; each item has the same format as in the upload, plus `timeZone`.

### `GET /v1/activity-summaries`

Parameters: `start`, `end` (`YYYY-MM-DD`, inclusive on both ends). Response `{"activitySummaries": [ … ]}`.

### `GET /v1/characteristics`

Returns the most recently uploaded user characteristics, in the upload format; `{}` if they were never uploaded.

### `GET /v1/changes` (change feed)

Changes to the samples on the server since a given position: new samples, samples whose content changed, and deleted samples, in the order the changes happened. The equivalent of `HKAnchoredObjectQuery`; with `wait`, the equivalent of `HKObserverQuery`.

| Parameter | Description |
|---|---|
| `anchor` | The `anchor` from the previous response (an opaque string). Omit it to start from the beginning |
| `type` | Optional. Only these types. Can be repeated (`type=A&type=B`) or comma-separated |
| `limit` | Default 500, maximum 5000. `0` returns no samples, only the current `anchor` (for tracking changes "from now on") |
| `wait` | Seconds, 0–60, default 0. When there are no changes (matching `type`) after `anchor`, waits until new changes are uploaded or the time is up |

Response:

```json
{"samples": [ … ], "deleted": [{"uuid": "…", "type": "HKQuantityTypeIdentifierBodyMass"}],
 "anchor": "…", "more": false}
```

- `samples`: new samples and samples whose content changed, in the same format as `GET /v1/samples`. A sample that changes appears again.
- `deleted`: samples deleted in Health (`HKDeletedObject`); each appears only once. Samples that never appeared in the change feed (the deletion record arrived before the sample) don't appear.
- `samples` and `deleted` together hold at most `limit` items, each in the order the changes happened.
- `anchor`: the next request continues from here. `more` is `true` when there are changes not yet returned; request again immediately with the new `anchor`. `false` means you're up to date.
- Tracking changes: request in a loop with the previous `anchor` and `wait=60`. When there are no changes, the request is held open; it returns as soon as the phone uploads new data. On timeout it returns empty `samples` and `deleted`; continue with the returned `anchor` (with `type`, it may have moved past changes to other types). No polling is needed.
- After `DELETE /v1/data`, earlier `anchor`s are invalid: the server returns `410 {"error": "anchor expired: the server's data was cleared; start again without an anchor"}` (waiting requests receive it immediately too). Start again without an `anchor`.
- An `anchor` in an invalid format returns `400`.
- Statistics, activity rings, user characteristics, and the medication list aren't in the change feed.

### `GET /v1/authorization`

The write authorization the phone uploaded (see `PUT /v1/authorization`):

```json
{"share": {"HKQuantityTypeIdentifierBodyMass": "sharingAuthorized", "HKQuantityTypeIdentifierDietaryProtein": "sharingDenied", …},
 "updatedAt": "2026-11-02T13:00:00Z"}
```

If it was never uploaded (for example, just after pairing), returns `{"share": null, "updatedAt": null}`.

- `sharingAuthorized`: can be written.
- `sharingDenied`: the user turned off Rendu's write access to this type in Health settings; writes are rejected.
- `notDetermined`: the user hasn't been asked yet; writes are executed after the user allows them on the phone.
- Not in the table: HealthKit doesn't let third-party apps write this type.

### `GET /v1/medications`

The medication list the phone uploaded (for the format, see `PUT /v1/medications`): `{"medications": [ … ], "updatedAt": "…"}`. If it was never uploaded, returns `{"medications": [], "updatedAt": null}`.

### Schema: `GET /v1/schema`

The API provides the definitions of types, enums, metadata keys, and object formats; nothing depends on hand-written documentation. The definitions have three sources, none of them maintained by hand:

- **The iOS SDK**: HealthKit header data embedded in the server at build time (`internal/schema/healthkit.json`, generated from the SDK by `ios/scripts/gen_healthkit_schema.py` and regenerated after SDK upgrades): every type identifier, every enum (including each case's raw value), and every metadata key, with Apple's original comments.
- **The phone's type catalog**: what this iPhone's HealthKit actually supports (`PUT /v1/catalog`).
- **Rendu's object formats**: the same declarative table that write validation uses (see "Object format").

`GET /v1/schema`: an overview.

```json
{"sdk": {"version": "27.0"}, "os": "27.1", "catalogUpdatedAt": "2026-11-02T13:00:00Z",
 "kinds": [{"kind": "quantity", "read": true, "write": true, "how": "Read with HKAnchoredObjectQuery, …"}, …],
 "types": [{"type": "HKQuantityTypeIdentifierBodyMass", "kind": "quantity", "name": {"en": "Weight", "zh-Hans": "体重"},
            "unit": "kg", "aggregation": "discreteArithmetic", "share": "sharingAuthorized"}, …],
 "enums": ["HKActivityMoveMode", …], "metadataKeys": ["HKAlgorithmVersion", …]}
```

- `sdk.version`: the SDK version embedded in the server. `os`, `catalogUpdatedAt`: the iOS version in the phone's type catalog and when the catalog was uploaded; `null` if it hasn't been uploaded yet.
- `kinds`: whether each kind can be read and written, and how; the same as "Read and write capabilities".
- `types`: if the phone has uploaded a type catalog, the types in it (`type`, `kind`, `name`, `unit`, `aggregation`, `perObject`, in the order the phone gave); otherwise, all non-deprecated types in the SDK (`type`, `kind`, `aggregation`, sorted by identifier). `share`: write authorization (see `GET /v1/authorization`), present only when the authorization table includes this type.
- `enums`: the Objective-C names of all enums in the SDK. `metadataKeys`: all metadata keys (the strings actually used, such as `HKFoodType`).

`GET /v1/schema/types/{type}`: everything about one type. `{type}` can also be a constant name (`HKDataTypeIdentifierStateOfMind` gives `HKDataTypeStateOfMind`).

```json
{"type": "HKCategoryTypeIdentifierSleepAnalysis", "kind": "category", "read": true, "write": true, "how": "…",
 "share": "sharingAuthorized",
 "catalog": {"type": "…", "kind": "category", "name": {…}, "values": [{"value": 0, "name": "inBed"}, …]},
 "sdk": {"kind": "category", "available": "8.0", "note": "HKCategoryValueSleepAnalysis",
         "values": {"name": "HKCategoryValueSleepAnalysis", "cases": [{"name": "HKCategoryValueSleepAnalysisInBed", "short": "inBed", "value": 0, "doc": "The user is in bed."}, …]}},
 "fields": [{"name": "value", "type": "integer", "required": true, "description": "…"}, …],
 "example": {"kind": "category", "type": "HKCategoryTypeIdentifierSleepAnalysis", "startDate": "…", "endDate": "…", "value": 0}}
```

- `catalog`: this type's entry in the phone's type catalog, returned as is; omitted if the catalog doesn't include it.
- `sdk`: this type's entry in the SDK: `kind`, `available` (iOS version), `deprecated`, `doc`; `note` is the comment Apple wrote after the declaration, verbatim (for quantity types, the standard unit and aggregation style, such as `"%, Discrete (Arithmetic)"`; for category types, the enum of values); `aggregation` (quantity); `values` (the enum of values, with all values inlined). Omitted if the SDK doesn't have the type (the phone's iOS is newer than the server's SDK).
- `read`, `write`, `how`, `fields`: the read/write capabilities and object format of the kind this type belongs to (the same as `GET /v1/schema/kinds/{kind}`). Types without an object format (such as user characteristics) have no `fields`.
- `example`: an example object for this type that can be submitted directly (when the kind is writable). Quantity examples use this type's read unit (the unit annotated in the SDK when there's no type catalog) and, for cumulative types, cover a period of time; category examples use a real value of this type; others use the kind's example. When the kind can't be written, the example shows what a read returns.
- Returns `404` if neither the type catalog nor the SDK has the type.

`GET /v1/schema/kinds/{kind}`: one kind's read/write capabilities and object format:

```json
{"kind": "stateOfMind", "class": "HKStateOfMind", "types": ["HKDataTypeStateOfMind"], "read": true, "write": true, "how": "…",
 "fields": [
   {"name": "startDate", "type": "timestamp", "required": true, "description": "HKSample.startDate."},
   {"name": "endDate", "type": "timestamp", "description": "Equal to startDate (this is a moment); may be left out when writing."},
   {"name": "valence", "type": "number", "required": true, "description": "-1 (very unpleasant) to 1 (very pleasant), 0 neutral."},
   {"name": "valenceClassification", "type": "integer", "readOnly": true, "enum": "HKStateOfMind.ValenceClassification", "description": "…"},
   {"name": "labels", "type": "array", "items": "integer", "enum": "HKStateOfMind.Label", "description": "…"}, …],
 "example": {…}}
```

| Field property | Description |
|---|---|
| `name`, `type` | The field name and type: `timestamp`, `quantity` (`{value, unit}`), `integer`, `number`, `string`, `uuid`, `boolean`, `object`, `array` |
| `items`, `itemKind` | The type of the array's elements; `itemKind` when the elements are objects of a kind (a correlation's `objects`, a workout's `samples`) |
| `required` | `true`, or a sentence saying when the field is required; omitted when it isn't required |
| `readOnly` | Present when reading; submitting it in a write returns `400` |
| `writeOnly` | Used only for writing (such as a workout's `samples` and `route`) |
| `enum` | The value (for an array, each item) is a raw value of this SDK enum; see `GET /v1/schema/enums/{name}` |
| `description` | A one-sentence description, including rules the table can't express (ranges, constraints between fields) |
| `fields` | The fields of an object (or of an array's object elements) |

`types` or `typePrefix` gives this kind's types. Returns `404` if there's no such kind.

`GET /v1/schema/enums/{name}`: one SDK enum. `{name}` is the Objective-C name (`HKStateOfMindLabel`) or the Swift name (`HKStateOfMind.Label`):

```json
{"name": "HKStateOfMindLabel", "swiftName": "HKStateOfMind.Label", "options": false,
 "doc": "A specific word describing a felt experience.", "available": "18.0",
 "cases": [{"name": "HKStateOfMindLabelAmazed", "short": "amazed", "value": 1}, …]}
```

- `options`: whether the enum is a bitmask (`NS_OPTIONS`). `cases` are in header order. `value` is the computed raw value; `short` is the Swift case name (the names Rendu outputs, such as `valueName` and `workoutActivityTypeName`, are these); `doc` is Apple's comment; `deprecated` marks a deprecated case (its raw value may equal another case's); `available` is given when it differs from the enum's own. Cases unavailable on iOS aren't listed. Returns `404` if there's no such enum.

`GET /v1/schema/metadata/{key}`: one metadata key. `{key}` is the string actually used (`HKFoodType`) or the constant name (`HKMetadataKeyFoodType`): `{"key", "constant", "doc", "available", "valueType", "values"}`. `valueType` is the value type Apple's documentation requires (`NSString`, `NSNumber`, `NSDate`, `HKQuantity`), present only when it can be read from the documentation; `values` is the enum of values (inlined), present only when the documentation specifies one. When writing, an `NSNumber` is written as a number or Boolean; `HKQuantity` and `NSDate` values can't currently be written through Rendu (the app writes only strings, numbers, and Booleans). Returns `404` if there's no such key.

### `POST /v1/writes`

Submits a write request, which is executed asynchronously. Requires `readwrite` (or `owner`); a `read` key gets `403`.

Creating an object:

```json
{"op": "save",
 "object": {"kind": "quantity", "type": "HKQuantityTypeIdentifierBodyMass",
            "startDate": "2026-11-01T08:00:00+08:00", "endDate": "2026-11-01T08:00:00+08:00",
            "quantity": {"value": 72.5, "unit": "kg"},
            "metadata": {"HKWasUserEntered": true}}}
```

A meal:

```json
{"op": "save",
 "object": {"kind": "correlation", "type": "HKCorrelationTypeIdentifierFood",
            "startDate": "2026-11-01T12:30:00+08:00", "endDate": "2026-11-01T12:30:00+08:00",
            "metadata": {"HKFoodType": "Lunch: beef noodle soup"},
            "objects": [
              {"kind": "quantity", "type": "HKQuantityTypeIdentifierDietaryEnergyConsumed", "quantity": {"value": 650, "unit": "kcal"}},
              {"kind": "quantity", "type": "HKQuantityTypeIdentifierDietaryProtein", "quantity": {"value": 32, "unit": "g"}}
            ]}}
```

A strength training workout (with active energy):

```json
{"op": "save",
 "object": {"kind": "workout", "type": "HKWorkoutTypeIdentifier",
            "startDate": "2026-11-01T18:00:00+08:00", "endDate": "2026-11-01T19:00:00+08:00",
            "workoutActivityTypeName": "traditionalStrengthTraining",
            "metadata": {"HKIndoorWorkout": true},
            "samples": [
              {"kind": "quantity", "type": "HKQuantityTypeIdentifierActiveEnergyBurned",
               "startDate": "2026-11-01T18:00:00+08:00", "endDate": "2026-11-01T19:00:00+08:00",
               "quantity": {"value": 320, "unit": "kcal"}}
            ]}}
```

An emotion in the moment (stressed, related to work):

```json
{"op": "save",
 "object": {"kind": "stateOfMind", "type": "HKDataTypeStateOfMind",
            "startDate": "2026-11-01T21:00:00+08:00",
            "stateOfMindKind": 1, "valence": -0.5, "labels": [29], "associations": [17]}}
```

- Modifying: pass the existing `syncIdentifier` with `op: save`, and submit the complete new object.
- Deleting: `{"op": "delete", "syncIdentifier": "…"}`. Returns `404` if the server has neither a write record for this `syncIdentifier` nor a non-deleted sample whose metadata `HKMetadataKeySyncIdentifier` equals it.
- Only objects written by Rendu can be modified or deleted. The server doesn't check this; the phone checks it when executing the write. If an object to replace or delete wasn't written by Rendu, the write is marked `failed`, with the `error` `only entries saved by Rendu can be changed or deleted`.
- Objects written by Rendu carry `HKMetadataKeySyncIdentifier` in their metadata, and the phone syncs them to the server. So even after the server's data (including write records) is wiped, previously written objects can still be modified and deleted: the server finds the objects to replace from these samples (see `GET /v1/writes/pending`).
- For a `save` without a `syncIdentifier`, the server generates a new one (a UUID). The server maintains `syncVersion`: it takes the highest `syncVersion` among this `syncIdentifier`'s previous `save`s and the highest `HKMetadataKeySyncVersion` among non-deleted samples whose metadata `HKMetadataKeySyncIdentifier` equals it, and adds 1 to the larger of the two; it's 1 when there's neither. HealthKit ignores a new write when Health already has an object with the same `HKMetadataKeySyncIdentifier` and a higher version, so the version must also exceed the one in Health.
- `metadata` can't contain `HKMetadataKeySyncIdentifier` or `HKMetadataKeySyncVersion`; the app writes these.
- The server validates the structure against the object format definition (`GET /v1/schema/kinds/{kind}`): no undefined fields, all required fields present, correct types, valid enum values, parseable times, `endDate >= startDate`, `kind` consistent with `type`, no read-only fields, and the rules written in each field's description. Returns `400` if validation fails. A kind that can't be written (see "Read and write capabilities") returns `400`.
- If the phone has uploaded write authorization (`share` in `GET /v1/authorization` isn't `null`), the server checks the types this write involves:
  - `save`: the object's `type`, the `type` of each correlation member, the `type` of each sample attached to a workout, and `HKWorkoutRouteTypeIdentifier` when the workout has a `route` (correlation types themselves aren't checked).
  - `delete`: the server looks at this `syncIdentifier`'s most recent write that didn't fail. If it's a `save` that's `pending` or `written`, the server checks the types that object involves; if it's a `delete` or a `conflict`, there's no check; if there's no write that didn't fail (for example, because the server's data was wiped), the server checks the types of the samples described under `GET /v1/writes/pending`.
  - If a type isn't in the authorization table: `422 {"error": "HealthKit doesn't allow apps to write <type>"}`.
  - If a type is `sharingDenied`: `422 {"error": "write access to <type> is turned off for Rendu in Apple Health settings"}`.
  - `notDetermined` is accepted as usual; the write stays `pending` until the user allows it on the phone.
  - If the phone has never uploaded authorization, there's no check.
- The app checks whether units are compatible and values are reasonable when it executes the write; if a check fails, the write is marked `failed`.

Responds `201` with the write request:

```json
{"id": "…", "op": "save", "syncIdentifier": "…", "syncVersion": 1,
 "status": "pending", "createdAt": "…", "updatedAt": "…",
 "submittedBy": {"id": "3F2A9C1B", "name": "My Agent"}, "object": { … }}
```

`submittedBy`: the `id` of the credential (API key or owner) that submitted this write, and the credential's name at submission time (kept after the key is revoked). Early write requests don't have this field.

### `GET /v1/writes`, `GET /v1/writes/{id}`

List parameters: `status` (optional), `syncIdentifier` (optional), `limit` (default 100, maximum 1000). Sorted by creation time, newest first. A single write request and each list element have the format above (including `submittedBy`); once executed, they also carry `uuids` (the HealthKit uuids after writing) or `error`.

Statuses:

| status | Meaning |
|---|---|
| `pending` | Waiting for the app to execute it (the next time the app opens) |
| `written` | Written to Health (for `delete`, deleted) |
| `failed` | The app rejected it or HealthKit returned an error; see `error` |
| `conflict` | When modifying, the original object was no longer in Health (the user deleted it); nothing was written |

---

## App write flow (implementation contract)

Each sync first executes pending writes (the app shows "Saving to Apple Health"), then reads Health, then uploads, so the same sync sends the newly written objects to the server.

For each pending write (`syncIdentifier` = X, `syncVersion` = n):

1. Using `replaceTypes`, fetch the objects in `replaceUUIDs` that are still in Health. If any of them wasn't written by Rendu: report `failed`, with the `error` `only entries saved by Rendu can be changed or deleted`.
2. Query Health for objects whose metadata `HKMetadataKeySyncIdentifier` is X (`X:<index>` for correlation members and samples attached to a workout, `X:route` for a workout's route) and whose version is n. If they exist, they were written earlier but success wasn't reported; skip to step 5.
3. If `replaceUUIDs` is non-empty and none of those objects are in Health anymore: report `conflict` for a `save`, and `written` for a `delete`.
4. `save`: write the new object (with `HKMetadataKeySyncIdentifier` and `HKMetadataKeySyncVersion` in its metadata; for food, each nutrient sample also gets the meal's `HKFoodType`, unless the member set its own), then delete the objects in `replaceUUIDs` that still exist. `delete`: delete `replaceUUIDs`.
5. Report `written` with the uuids of the new objects (for a correlation including its members, for a workout its attached samples and route).

HealthKit can't write while the device is locked. Such errors aren't reported; the write stays `pending` and is executed after the next unlock.

Once read back to the server, written objects are ordinary samples; the `HKMetadataKeySyncIdentifier` in their metadata ties them to their write requests.

---

## CLI

```
rendu status
rendu types
rendu samples <type> [--since 7d | --start T --end T] [--source BUNDLE] [--limit N] [--all]
rendu stats <type> [--interval day|hour] [--since 30d | --start T --end T]
rendu activity [--since 7d | --start DATE --end DATE]
rendu characteristics
rendu medications
rendu changes [--anchor A] [--type T ...] [--limit N] [--wait S]
rendu authorization
rendu schema [<type> | <kind> | <enum> | <metadata key>]
rendu write save [--sync-identifier X] [--file F]      # object JSON from --file or stdin
rendu write delete <syncIdentifier>
rendu write get <id>
rendu write list [--status S] [--sync-identifier X] [--limit N]
```

- Configuration: the environment variables `RENDU_URL` (such as `https://rendu.example.com`) and `RENDU_API_KEY` (an API key created in the app, `read` or `readwrite`; see "API keys").
- Output: on success, JSON to stdout; on failure, `{"error": "…"}` to stderr (errors returned by the server also carry `status`). The exit code is 2 for argument errors and 1 for other errors.
- Time arguments: `--since` accepts `90m`, `24h`, `7d`, `2w`. `--start`/`--end` accept RFC 3339, `YYYY-MM-DD`, or local time without an offset (the latter two are interpreted in the time zone given by the environment variable `RENDU_TZ`, defaulting to the machine's time zone). A date-only `--end` includes that day.
- `--all` pages automatically and outputs all pages merged.
- `schema` without arguments corresponds to `GET /v1/schema`. With a name, it looks the name up as a type, kind, enum, and metadata key, in that order (`GET /v1/schema/types/…`, `kinds/…`, `enums/…`, `metadata/…`), outputs the first match, and reports an error (`status` 404) if nothing matches.
- `changes` corresponds to `GET /v1/changes`: `--anchor` takes the `anchor` from the previous output, `--type` can be repeated or comma-separated, `--limit 0` gets only the current `anchor`, and `--wait` is the number of seconds to wait (maximum 60).

Server administration:

```
rendu-server serve [--addr 127.0.0.1:8787] [--db rendu.db]
rendu-server pair CODE [--db rendu.db]   # pair the iPhone showing CODE (see "Pairing"), replacing the paired iPhone
```

Environment variables: `RENDU_ADDR` (the default for `--addr`), `RENDU_DB` (the default for `--db`). There are no secrets to configure. The Docker image presets `RENDU_ADDR=0.0.0.0:8787` and `RENDU_DB=/data/rendu.db`. `pair` opens the database directly, so run it on the server against the same database (Docker: `docker compose exec rendu rendu-server pair CODE`); `serve` doesn't need to be stopped.

To switch phones, pair again on the new phone. If an API key leaks, revoke it in the app and create a new one.

---

## Appendix A: Read units of quantity types

The type catalog the phone uploads is authoritative for each quantity type's read unit (`catalog.unit` in `GET /v1/schema/types/{type}`; see `PUT /v1/catalog`). The unit is taken from the units Apple annotates in the iOS SDK header `HKTypeIdentifiers.h` (`sdk.note`), except for the following, which use the units the Health app's interface uses, to avoid tiny decimals:

| Type | Unit |
|---|---|
| `HeartRate`, `RespiratoryRate` | `count/min` (the header has `count/s`) |
| `DietaryCaffeine`, `Calcium`, `Chloride`, `Cholesterol`, `Copper`, `Iron`, `Magnesium`, `Manganese`, `Niacin`, `PantothenicAcid`, `Phosphorus`, `Potassium`, `Riboflavin`, `Sodium`, `Thiamin`, `VitaminB6`, `VitaminC`, `VitaminE`, `Zinc` | `mg` |
| `DietaryBiotin`, `Chromium`, `Folate`, `Iodine`, `Molybdenum`, `Selenium`, `VitaminA`, `VitaminB12`, `VitaminD`, `VitaminK` | `mcg` |
| `UVExposure` | `count` (not annotated in the header) |

For the complete list, the type catalog in the app's source is authoritative (`ios/Rendu/Health/TypeCatalog.swift`).

## Appendix B: Category types that output `valueName`

| Type | Enum |
|---|---|
| `SleepAnalysis` | `HKCategoryValueSleepAnalysis` |
| `AppleStandHour` | `HKCategoryValueAppleStandHour` |
| Symptoms | `HKCategoryValueSeverity` |
| `MoodChanges`, `SleepChanges` | `HKCategoryValuePresence` |

`valueName` is the Swift name of the enum case, i.e. the `short` of each case in `GET /v1/schema/enums/{name}` (for example, 5 in `HKCategoryValueSleepAnalysis` is `asleepREM`). Other category types output only the raw `value`; for what it means, see `sdk.values` in `GET /v1/schema/types/{type}`.
