# Rendu usage guide (for AI assistants)

Rendu lets you read the user's Apple Health data and write entries (workouts, meals, mindful minutes, body measurements, etc.) back to Apple Health. Every term is the HealthKit original, and its meaning in the HealthKit documentation applies here too.

## Setup

There are two ways to use it; pick either: the `rendu` command-line tool (see the README for installation), or the REST API directly. Both can do exactly the same things; the CLI is just a thin wrapper around the REST API.

```bash
export RENDU_URL=https://rendu.example.com   # the user's server URL
export RENDU_API_KEY=rdk_...                 # the API key the user created for you in the Rendu app
export RENDU_TZ=Asia/Shanghai                # the CLI interprets date-only arguments in this time zone
```

**CLI**: on success it prints JSON to stdout; on failure it exits non-zero (2 for usage errors, 1 for everything else) and prints one line on stderr, e.g. `rendu: unknown type "NotAType"; did you mean …? (HTTP 400)`. `rendu help` lists the commands, `rendu help <command>` shows its flags; `rendu -v` prints the version (plain text). A mistyped command name gets a suggestion of the closest command. `rendu update` updates to the latest version (`--check` only checks).

**REST API**: send `Authorization: Bearer $RENDU_API_KEY` with every request. Requests and responses are JSON; error responses are `{"error": "…"}` with a 4xx/5xx status code.

```bash
curl -s -H "Authorization: Bearer $RENDU_API_KEY" "$RENDU_URL/v1/status"
```

Common errors:

- `401`: the key has been revoked (or is wrong). Ask the user to create a new one for you in the app.
- `403`: this key is read-only and can't write. When you need to write, ask the user to create a key with "Read & Write" permission in the app.
- `400`: bad parameters or object format; fix it according to `error`. Misspelled or extra fields are errors too (`… is not a field of kind …`); a misspelled type name gives `unknown type` along with the closest identifiers (an empty list means that type really has no data).
- `422`: the type you're writing can't be written; see "First, check what you can write".

## When unsure, look up the definition first

Types, values and object formats are as the server defines them; don't go from memory. **Before writing a type for the first time, look it up**:

```bash
rendu schema HKQuantityTypeIdentifierBodyFatPercentage
curl -s -H "Authorization: Bearer $RENDU_API_KEY" "$RENDU_URL/v1/schema/types/HKQuantityTypeIdentifierBodyFatPercentage"
```

The output includes: `fields` (each field of this kind of object: its type, whether it's required, whether it's read-only, which enum its values come from, and its rules), `example` (an example object of this type; change the time and values and it's ready to submit), `catalog.unit` (the unit used when reading), `sdk.note` (Apple's original comment, e.g. `"%, Discrete (Arithmetic)"`), `sdk.values` for category types (all values), and `share` (whether it can be written).

A field's `enum` names the HealthKit enum its values come from; the submitted value must be one of them. Look up all of its values:

```bash
rendu schema HKStateOfMind.Label          # the Objective-C name HKStateOfMindLabel works too
rendu schema HKWorkoutActivityType
curl -s -H "Authorization: Bearer $RENDU_API_KEY" "$RENDU_URL/v1/schema/enums/HKStateOfMind.Label"
```

Each entry's `value` is the raw value to submit, and `short` is its name (that's what `valueName` and `workoutActivityTypeName` use). `rendu schema` with no argument lists all kinds, types, enums and metadata keys; `rendu schema <kind>` (e.g. `workout`) gives the full format of one kind of object; `rendu schema HKFoodType` describes a metadata key.

## Commands and endpoints

| Task | CLI | REST |
|---|---|---|
| How fresh the data is | `rendu status` | `GET /v1/status` |
| Which types exist | `rendu types` | `GET /v1/types` |
| Statistics | `rendu stats <type> --interval day --since 30d` | `GET /v1/statistics?type=…&interval=day&start=…&end=…` |
| Raw samples | `rendu samples <type> --since 7d [--all]` | `GET /v1/samples?type=…&start=…&end=…&limit=…&cursor=…` |
| Activity rings | `rendu activity --since 7d` | `GET /v1/activity-summaries?start=YYYY-MM-DD&end=YYYY-MM-DD` |
| Characteristics | `rendu characteristics` | `GET /v1/characteristics` |
| Medication list | `rendu medications` | `GET /v1/medications` |
| Follow new data | `rendu changes --anchor A --wait 60` | `GET /v1/changes?anchor=A&type=…&limit=…&wait=60` |
| What can be written | `rendu authorization` | `GET /v1/authorization` |
| Definitions of types, enums and object formats | `rendu schema [<type, kind, enum or metadata key>]` | `GET /v1/schema`, `GET /v1/schema/types/{type}`, `/kinds/{kind}`, `/enums/{name}`, `/metadata/{key}` |
| Create an entry | `rendu write save < object.json` or `rendu write save --file object.json` | `POST /v1/writes`, `{"op": "save", "object": {…}}` |
| Modify an entry | `rendu write save --sync-identifier X < object.json` | `POST /v1/writes`, `{"op": "save", "syncIdentifier": "X", "object": {…}}` |
| Delete an entry | `rendu write delete X` | `POST /v1/writes`, `{"op": "delete", "syncIdentifier": "X"}` |
| Write results | `rendu write get <id>`, `rendu write list --status pending` | `GET /v1/writes/{id}`, `GET /v1/writes?status=pending` |

When using the REST API directly:

- Time parameters (`start`, `end`) must be timestamps with a UTC offset, e.g. `2026-11-01T00:00:00+08:00`; remember to URL-encode them (`+` becomes `%2B`). Forms like `--since 7d` are CLI-only. For activity rings, `start` and `end` are dates (`YYYY-MM-DD`, both inclusive).
- Paging raw samples: if the response has a `nextCursor`, there's another page; fetch it with `cursor=<nextCursor>`, until there's no `nextCursor` (this is what the CLI's `--all` does). `limit` defaults to 1000, max 10000.
- The write request body wraps the object in `object`, with `op` and an optional `syncIdentifier` outside it; what the CLI reads from stdin (or `--file`) is only the `object` itself.

## First, check how fresh the data is

```bash
rendu status
curl -s -H "Authorization: Bearer $RENDU_API_KEY" "$RENDU_URL/v1/status"
```

- `lastDeviceSeenAt`: when the iPhone last contacted the server. The data is only as recent as this time. If the field is missing, no iPhone has been paired yet; see "Pairing the iPhone and API keys".
- The iPhone can't sync while it's locked. If this time is long ago, remind the user to open the Rendu app.

## Reading

### For totals, use statistics; don't add up raw samples yourself

```bash
rendu stats HKQuantityTypeIdentifierStepCount --interval day --since 30d
rendu stats HKQuantityTypeIdentifierHeartRate --interval hour --since 1d

curl -s -G -H "Authorization: Bearer $RENDU_API_KEY" "$RENDU_URL/v1/statistics" \
  --data-urlencode type=HKQuantityTypeIdentifierStepCount --data-urlencode interval=day \
  --data-urlencode start=2026-10-01T00:00:00+08:00 --data-urlencode end=2026-11-01T00:00:00+08:00
```

The response is `{"type", "interval", "unit", "statistics": [{"startDate", "endDate", "sumQuantity" …}]}`; values are in the outer `unit`.

Statistics are computed by HealthKit on the iPhone, deduplicated by data source priority, and match what the Health app shows. iPhone and Apple Watch often record steps and energy at the same time, so **adding up raw samples directly double-counts**.

- Cumulative types (steps, energy, nutrients): `sumQuantity`.
- Discrete types (heart rate, HRV, weight): `averageQuantity`, `minimumQuantity`, `maximumQuantity`, `mostRecentQuantity`.
- Some types (e.g. environmental sound levels, headphone audio levels) also have `duration`: the total seconds covered by samples in the interval (not affected by `unit`).
- Daily statistics cover all history; hourly statistics cover only about the last 30 days.

### Raw samples

```bash
rendu types                                                   # which types exist, how many samples each, date ranges
rendu samples HKQuantityTypeIdentifierBodyMass --since 90d
rendu samples HKCategoryTypeIdentifierSleepAnalysis --start 2026-10-31 --end 2026-11-01
rendu samples HKQuantityTypeIdentifierHeartRate --since 1d --all   # --all fetches every page

curl -s -G -H "Authorization: Bearer $RENDU_API_KEY" "$RENDU_URL/v1/samples" \
  --data-urlencode type=HKQuantityTypeIdentifierBodyMass --data-urlencode start=2026-08-01T00:00:00+08:00
# response {"samples": [...], "nextCursor": "..."}; if there's a nextCursor, add --data-urlencode cursor=<nextCursor> to get the next page
```

- Every sample has `sourceRevision.source` (whether it came from Apple Watch, iPhone or another app). Use `--source <bundleIdentifier>` to see only one source.
- Samples Apple Watch measures continuously (e.g. heart rate during a workout) may be a series: `count` is greater than 1, `quantity` is the aggregate (the sum for cumulative types, the average for discrete types), `series` holds each value and its time, and discrete types also have `minimumQuantity`, `maximumQuantity`, `mostRecentQuantity`.
- Fields without a value are omitted, never `null`.
- **Sleep has no statistics**; compute it yourself from raw samples. One night may have several sources (Watch, third-party apps); pick one source before computing, preferring Apple Watch. Each sample's `valueName` gives the name directly (`inBed`, `asleepCore`, `asleepREM`, etc.); for all values see `rendu schema HKCategoryValueSleepAnalysis`.

### Following new data: the change feed

To find out "what's new since I last looked" (a new weigh-in, last night's sleep, a workout that just ended), use the change feed instead of querying `samples` over and over:

```bash
rendu changes --limit 0                                   # start following from now: get only the current anchor
rendu changes --anchor <anchor> --type HKQuantityTypeIdentifierBodyMass --type HKCategoryTypeIdentifierSleepAnalysis --wait 60

curl -s -G -H "Authorization: Bearer $RENDU_API_KEY" "$RENDU_URL/v1/changes" --data-urlencode limit=0
curl -s -G -H "Authorization: Bearer $RENDU_API_KEY" "$RENDU_URL/v1/changes" --max-time 90 \
  --data-urlencode anchor=<anchor> --data-urlencode type=HKQuantityTypeIdentifierBodyMass,HKCategoryTypeIdentifierSleepAnalysis \
  --data-urlencode wait=60
```

- The output is `{"samples": [...], "deleted": [{"uuid", "type"}], "anchor": "...", "more": false}`. `samples` are samples that were added or whose content changed (a sample that changes appears again); `deleted` are samples the user deleted in Apple Health.
- **Remember the `anchor` from each output** and pass it back next time with `--anchor`. Without `--anchor` you read all history from the beginning (possibly many pages).
- When `more` is `true`, fetch again immediately with the new `anchor`, until it's `false`.
- `--wait 60` (REST: `wait=60`): when there are no new changes, the request is held until the iPhone uploads new data (or 60 seconds pass) before returning. Set your HTTP client's timeout longer than `wait`. To keep following, call `rendu changes --wait 60` in a loop with the previous `anchor`; **you don't need to sleep and poll yourself**. A timeout returns an empty list; carry on with the `anchor` from that output as usual.
- `410` (`anchor expired`): the user cleared the server's data and the old `anchor` is no longer valid. Start over without `--anchor` (the iPhone will upload the data again).
- The change feed only has samples. Read statistics, activity rings and the medication list with their own commands.

### Medications

```bash
rendu medications                                                          # the user's medication list in Apple Health
rendu samples HKMedicationDoseEventTypeIdentifierMedicationDoseEvent --since 7d   # dose events
```

- Medications: `id`, `medication.displayText` (name), `medication.generalForm` (dosage form), `nickname` (a nickname the user gave it; omitted if none), `isArchived` (no longer taken), `hasSchedule` (has a dosing schedule).
- Dose events: `medicationId` matches a medication's `id`, `medicationName` is its name; `logStatus`: 4 taken, 5 skipped, 3 snoozed (remind later), 1 notInteracted (no response to the reminder), 2 notificationNotSent (the reminder wasn't delivered), 6 notLogged (the log was undone); `scheduleType`: 1 as needed, 2 scheduled (only scheduled doses have `scheduledDate`); `doseQuantity` and `unit` are the dose (there's no `doseQuantity` when no dose was logged).
- Medications and dose events are read-only; they can't be written.

### Other data

```bash
rendu activity --since 7d     # activity rings: energy, exercise minutes, stand hours, and their goals
rendu characteristics         # sex (1 female, 2 male), date of birth, blood type, etc.
```

Workout (`HKWorkoutTypeIdentifier`) samples carry `workoutActivityTypeName`, `duration` (seconds) and `statistics` (energy, distance, heart rate, etc.); multi-activity workouts have `workoutActivities`, laps and pauses are in `workoutEvents`, and the effort rating the user gave is in `effortRelationships` (its `samples` are the uuids of `HKQuantityTypeIdentifierWorkoutEffortScore` samples). Workout routes (`HKWorkoutRouteTypeIdentifier`) are separate samples; a route belongs to the workout whose time range it falls in.

Other types to read only when needed:

| What | type | Notes |
|---|---|---|
| ECG | `HKDataTypeIdentifierElectrocardiogram` | `classification`, `averageHeartRate`; `voltageMeasurements` is the full waveform (about 15,000 points, in microvolts) and is large, so read it only when you really need to analyze the waveform |
| Heartbeat series | `HKDataTypeIdentifierHeartbeatSeries` | every heartbeat during an HRV measurement: `beats[].timeSinceSeriesStart` (seconds) |
| Audiogram (hearing test) | `HKDataTypeIdentifierAudiogram` | `sensitivityPoints`: the hearing threshold (dBHL) of the left and right ear at each frequency |
| GAD-7 / PHQ-9 | `HKScoredAssessmentTypeIdentifierGAD7` / `HKScoredAssessmentTypeIdentifierPHQ9` | `answers`, `score`, `risk`; see "GAD-7 / PHQ-9 assessments" |
| Vision prescription | `HKVisionPrescriptionTypeIdentifier` | see "Vision prescriptions"; only prescriptions the user has allowed on the iPhone |


## Common types and units

| What | type | Read unit |
|---|---|---|
| Steps | `HKQuantityTypeIdentifierStepCount` | `count` |
| Active energy / Resting energy | `HKQuantityTypeIdentifierActiveEnergyBurned` / `BasalEnergyBurned` | `kcal` |
| Heart rate / Resting heart rate | `HKQuantityTypeIdentifierHeartRate` / `RestingHeartRate` | `count/min` |
| HRV | `HKQuantityTypeIdentifierHeartRateVariabilitySDNN` | `ms` |
| Weight / Lean body mass | `HKQuantityTypeIdentifierBodyMass` / `LeanBodyMass` | `kg` |
| Body fat percentage | `HKQuantityTypeIdentifierBodyFatPercentage` | `%`, **a fraction from 0 to 1**: 0.18 means 18% |
| Dietary energy | `HKQuantityTypeIdentifierDietaryEnergyConsumed` | `kcal` |
| Protein / Carbohydrates / Fat / Fiber / Sugar | `HKQuantityTypeIdentifierDietaryProtein` / `DietaryCarbohydrates` / `DietaryFatTotal` / `DietaryFiber` / `DietarySugar` | `g` |
| Sodium / Caffeine / Calcium / Magnesium / Iron / Zinc / Vitamin C | `HKQuantityTypeIdentifierDietarySodium` / `DietaryCaffeine` / … | `mg` |
| Vitamin D / B12 / Folate | `HKQuantityTypeIdentifierDietaryVitaminD` / `DietaryVitaminB12` / `DietaryFolate` | `mcg` |
| Water | `HKQuantityTypeIdentifierDietaryWater` | `mL` |
| Workout effort score | `HKQuantityTypeIdentifierWorkoutEffortScore` | `appleEffortScore`, 1–10 |
| Sleep | `HKCategoryTypeIdentifierSleepAnalysis` | category values, see above |

When writing, you can use any compatible HKUnit string (`lb`, `g`, `mg`, `mcg`, `mL`, `kcal`…); the app converts. For types not in the table, the read unit is `catalog.unit` in `rendu schema <type>`.

## Writing

Writable kinds: `quantity` (one value, or a `series` of values), `category`, `correlation` (food, blood pressure), `workout` (can include activities, laps, a route and an effort score), `stateOfMind` (state of mind), `scoredAssessment` (GAD-7, PHQ-9), `audiogram` (hearing test), `heartbeatSeries` (heartbeat series), `visionPrescription` (vision prescription). ECGs, dose events and the medication list are read-only; workout routes can only be written together with a workout. Look up the full format of each kind of object with `rendu schema <kind>` (e.g. `rendu schema workout`).

Fields marked read-only (e.g. `duration`, `statistics`, `score`, `risk`, `count`) are computed by HealthKit; submitting them returns `400`. Omit fields that have no value; don't write `null`.

### First, check what you can write

```bash
rendu authorization
curl -s -H "Authorization: Bearer $RENDU_API_KEY" "$RENDU_URL/v1/authorization"
```

The output is `{"share": {"<type>": "sharingAuthorized" | "sharingDenied" | "notDetermined", ...}, "updatedAt": "..."}`: the write permission for each type, as reported by the iPhone.

- `sharingAuthorized`: can be written.
- `sharingDenied`: the user turned off Rendu's write access to this type in Apple Health. Submitting returns `422`; ask the user to find Rendu in Apple Health, under the apps that access their data, and turn it on (the Rendu app has a shortcut in Settings → Apple Health).
- `notDetermined`: never authorized. You can submit; the write stays `pending` until the user opens Rendu on the iPhone and allows it.
- Not in the map: HealthKit doesn't let any third-party app write this type (e.g. `HKQuantityTypeIdentifierWalkingHeartRateAverage`). Submitting returns `422`; don't try again.
- `share` is `null`: the iPhone hasn't reported yet, so the server doesn't check; problems will show up as `failed` when the iPhone executes the write.

`rendu types` also includes each type's `share`.

### Submitting

Writes are **asynchronous**: after you submit, the status is `pending`, and the entry is actually written to Apple Health when the iPhone syncs. While the Rendu app is open, the iPhone executes it as soon as it arrives, usually becoming `written` within a few seconds; when the app isn't in the foreground, it waits for the next sync (the user unlocking the iPhone or opening the app, or iOS waking the app in the background, which iOS restricts tightly, so it can take a long time). Multiple writes to the same entry (write → modify → delete) run one after another in the order submitted.

```bash
# Weight
echo '{"kind":"quantity","type":"HKQuantityTypeIdentifierBodyMass",
  "startDate":"2026-11-01T08:00:00+08:00","endDate":"2026-11-01T08:00:00+08:00",
  "quantity":{"value":72.5,"unit":"kg"},"metadata":{"HKWasUserEntered":true}}' | rendu write save

# Body fat percentage 18%
echo '{"kind":"quantity","type":"HKQuantityTypeIdentifierBodyFatPercentage",
  "startDate":"2026-11-01T08:00:00+08:00","endDate":"2026-11-01T08:00:00+08:00",
  "quantity":{"value":0.18,"unit":"%"}}' | rendu write save

# A meal: bundle the nutrients in a food correlation, with the dish name in HKFoodType (the app also writes it on each nutrient)
echo '{"kind":"correlation","type":"HKCorrelationTypeIdentifierFood",
  "startDate":"2026-11-01T12:30:00+08:00","endDate":"2026-11-01T12:30:00+08:00",
  "metadata":{"HKFoodType":"Lunch: beef noodle soup"},
  "objects":[
    {"kind":"quantity","type":"HKQuantityTypeIdentifierDietaryEnergyConsumed","quantity":{"value":650,"unit":"kcal"}},
    {"kind":"quantity","type":"HKQuantityTypeIdentifierDietaryProtein","quantity":{"value":32,"unit":"g"}},
    {"kind":"quantity","type":"HKQuantityTypeIdentifierDietaryCarbohydrates","quantity":{"value":85,"unit":"g"}},
    {"kind":"quantity","type":"HKQuantityTypeIdentifierDietaryFatTotal","quantity":{"value":18,"unit":"g"}}
  ]}' | rendu write save

# Supplements: also a food correlation; only write nutrients Apple Health has
echo '{"kind":"correlation","type":"HKCorrelationTypeIdentifierFood",
  "startDate":"2026-11-01T09:00:00+08:00","endDate":"2026-11-01T09:00:00+08:00",
  "metadata":{"HKFoodType":"Vitamin D3 + magnesium"},
  "objects":[
    {"kind":"quantity","type":"HKQuantityTypeIdentifierDietaryVitaminD","quantity":{"value":50,"unit":"mcg"}},
    {"kind":"quantity","type":"HKQuantityTypeIdentifierDietaryMagnesium","quantity":{"value":200,"unit":"mg"}}
  ]}' | rendu write save

# A strength workout: 1 hour, with 320 kcal of active energy (HealthKit computes the workout's energy statistics from the attached samples)
echo '{"kind":"workout","type":"HKWorkoutTypeIdentifier",
  "startDate":"2026-11-01T18:00:00+08:00","endDate":"2026-11-01T19:00:00+08:00",
  "workoutActivityTypeName":"traditionalStrengthTraining",
  "metadata":{"HKIndoorWorkout":true},
  "samples":[
    {"kind":"quantity","type":"HKQuantityTypeIdentifierActiveEnergyBurned",
     "startDate":"2026-11-01T18:00:00+08:00","endDate":"2026-11-01T19:00:00+08:00",
     "quantity":{"value":320,"unit":"kcal"}}
  ]}' | rendu write save

# "Really stressed today because of work": a momentary emotion, negative valence, label 29 stressed, association 17 work
echo '{"kind":"stateOfMind","type":"HKDataTypeStateOfMind",
  "startDate":"2026-11-01T21:00:00+08:00",
  "stateOfMindKind":1,"valence":-0.6,"labels":[29],"associations":[17]}' | rendu write save
```

When submitting through the REST API, wrap the object above in `object`:

```bash
curl -s -H "Authorization: Bearer $RENDU_API_KEY" -H "Content-Type: application/json" "$RENDU_URL/v1/writes" -d '{
  "op": "save",
  "object": {"kind":"quantity","type":"HKQuantityTypeIdentifierBodyMass",
    "startDate":"2026-11-01T08:00:00+08:00","endDate":"2026-11-01T08:00:00+08:00",
    "quantity":{"value":72.5,"unit":"kg"},"metadata":{"HKWasUserEntered":true}}}'

# When the object is in a file
rendu write save --file run.json
curl -s -H "Authorization: Bearer $RENDU_API_KEY" -H "Content-Type: application/json" "$RENDU_URL/v1/writes" \
  -d "{\"op\":\"save\",\"object\":$(cat run.json)}"
```

On success it returns `201` and the write request (`id`, `syncIdentifier`, `syncVersion`, `status: "pending"`, `submittedBy`, `object`).

Workouts:

- `startDate` and `endDate` are required. Give the activity type as either `workoutActivityTypeName` (a name, e.g. `running`, `walking`, `cycling`, `traditionalStrengthTraining`, `functionalStrengthTraining`, `yoga`, `highIntensityIntervalTraining`, `swimming`) or `workoutActivityType` (the raw `HKWorkoutActivityType` value, e.g. 37 running, 50 traditionalStrengthTraining), not both. Both names and raw values must be in `rendu schema HKWorkoutActivityType`.
- `samples` is optional and may only contain `quantity` objects, each with its own complete `startDate` and `endDate` within the workout's time range. Common ones are active energy (`ActiveEnergyBurned`), distance (`DistanceWalkingRunning`, `DistanceCycling`), and the effort score (see below).
- `workoutEvents` is optional and records laps, pauses, etc. `type` is the raw `HKWorkoutEventType` value (e.g. 1 pause, 3 lap, 7 segment; all of them in `rendu schema HKWorkoutEventType`). Only 3 lap and 7 segment can have a duration; for other events, `endDate` must equal `startDate`.
- `workoutActivities` is optional, for workouts done in segments such as triathlons and interval training: each segment has a `workoutConfiguration` (`activityTypeName` or `activityType`, and optionally `locationType`: 1 unknown, 2 indoor, 3 outdoor) and its own `startDate` and `endDate`.
- `route` is optional, the workout's track: each point has `timestamp`, `latitude`, `longitude`, and optionally `altitude` (m), `speed` (m/s), etc., all within the workout's time range. Coordinates are raw GPS coordinates (WGS-84); coordinates shown by map apps in mainland China (GCJ-02) must be converted first.
- Don't submit `duration`, `statistics` or `effortRelationships`; HealthKit computes them.

State of mind:

- `stateOfMindKind`: 1 momentary emotion (momentaryEmotion), 2 daily mood (dailyMood).
- `valence`: from -1 (very unpleasant) to 1 (very pleasant); 0 is neutral.
- Fill in only `startDate` (a single moment); omit `endDate`.
- `labels` (feelings) and `associations` (causes) are integer arrays whose values are the raw values of `HKStateOfMind.Label` (e.g. 29 stressed, 7 calm, 17 happy) and `HKStateOfMind.Association` (e.g. 17 work, 5 family, 8 health) respectively; look up all values with `rendu schema HKStateOfMind.Label` and `rendu schema HKStateOfMind.Association`.

### Running: laps and route

30 minutes, 5 km, two laps, with distance, energy and a route:

```bash
cat > run.json <<'JSON'
{"kind":"workout","type":"HKWorkoutTypeIdentifier",
 "startDate":"2026-11-02T07:00:00+08:00","endDate":"2026-11-02T07:30:00+08:00",
 "workoutActivityTypeName":"running","metadata":{"HKIndoorWorkout":false},
 "workoutEvents":[
   {"type":3,"startDate":"2026-11-02T07:00:00+08:00","endDate":"2026-11-02T07:14:40+08:00"},
   {"type":3,"startDate":"2026-11-02T07:14:40+08:00","endDate":"2026-11-02T07:30:00+08:00"}],
 "samples":[
   {"kind":"quantity","type":"HKQuantityTypeIdentifierDistanceWalkingRunning",
    "startDate":"2026-11-02T07:00:00+08:00","endDate":"2026-11-02T07:30:00+08:00","quantity":{"value":5,"unit":"km"}},
   {"kind":"quantity","type":"HKQuantityTypeIdentifierActiveEnergyBurned",
    "startDate":"2026-11-02T07:00:00+08:00","endDate":"2026-11-02T07:30:00+08:00","quantity":{"value":310,"unit":"kcal"}}],
 "route":[
   {"timestamp":"2026-11-02T07:00:00+08:00","latitude":31.2304,"longitude":121.4737,"altitude":4},
   {"timestamp":"2026-11-02T07:15:00+08:00","latitude":31.2410,"longitude":121.4900,"altitude":5},
   {"timestamp":"2026-11-02T07:30:00+08:00","latitude":31.2305,"longitude":121.4738,"altitude":4}]}
JSON
rendu write save --file run.json
curl -s -H "Authorization: Bearer $RENDU_API_KEY" -H "Content-Type: application/json" "$RENDU_URL/v1/writes" \
  -d "{\"op\":\"save\",\"object\":$(cat run.json)}"
```

Once written, the route is a separate `HKWorkoutRouteTypeIdentifier` sample in Apple Health, which `rendu samples HKWorkoutRouteTypeIdentifier` can read. Writing a route requires the iPhone to allow writing `HKWorkoutRouteTypeIdentifier`.

### Workout effort score

The effort score (`HKQuantityTypeIdentifierWorkoutEffortScore`, unit `appleEffortScore`) is the user's subjective rating of how hard the workout was, 1–10: 1–3 easy, 4–6 moderate, 7–8 hard, 9–10 all out. Put it in the workout's `samples`, and the app relates it to the workout (when read back, it appears in the workout's `effortRelationships`) instead of adding it as an ordinary sample:

```bash
cat > strength.json <<'JSON'
{"kind":"workout","type":"HKWorkoutTypeIdentifier",
 "startDate":"2026-11-02T18:00:00+08:00","endDate":"2026-11-02T19:00:00+08:00",
 "workoutActivityTypeName":"traditionalStrengthTraining","metadata":{"HKIndoorWorkout":true},
 "samples":[
   {"kind":"quantity","type":"HKQuantityTypeIdentifierWorkoutEffortScore",
    "startDate":"2026-11-02T18:00:00+08:00","endDate":"2026-11-02T19:00:00+08:00","quantity":{"value":7,"unit":"appleEffortScore"}}]}
JSON
rendu write save --file strength.json
curl -s -H "Authorization: Bearer $RENDU_API_KEY" -H "Content-Type: application/json" "$RENDU_URL/v1/writes" \
  -d "{\"op\":\"save\",\"object\":$(cat strength.json)}"
```

An effort score can only be submitted together with a workout Rendu writes; it can't be added afterwards to workouts recorded by other sources such as Apple Watch. `HKQuantityTypeIdentifierEstimatedWorkoutEffortScore` (the score Apple Watch estimates) can't be written.

### GAD-7 / PHQ-9 assessments

For GAD-7 (anxiety, 7 questions) and PHQ-9 (depression, 9 questions), fill in `answers` in the standard questionnaire's question order; the questions ask about the past two weeks. Each answer: 0 not at all, 1 several days, 2 more than half the days, 3 nearly every day. PHQ-9's question 9 also accepts 4 (prefer not to answer). An assessment is a single moment: fill in only `startDate`.

```bash
cat > gad7.json <<'JSON'
{"kind":"scoredAssessment","type":"HKScoredAssessmentTypeIdentifierGAD7",
 "startDate":"2026-11-02T21:00:00+08:00","answers":[1,2,1,0,1,2,1]}
JSON
rendu write save --file gad7.json
curl -s -H "Authorization: Bearer $RENDU_API_KEY" -H "Content-Type: application/json" "$RENDU_URL/v1/writes" \
  -d "{\"op\":\"save\",\"object\":$(cat gad7.json)}"

# PHQ-9: change type to HKScoredAssessmentTypeIdentifierPHQ9, with 9 answers
echo '{"kind":"scoredAssessment","type":"HKScoredAssessmentTypeIdentifierPHQ9",
  "startDate":"2026-11-02T21:05:00+08:00","answers":[1,1,2,1,0,1,0,0,0]}' | rendu write save
```

Don't submit `score` or `risk`: HealthKit computes the total score and the risk level from `answers`; after writing, read them back with `rendu samples HKScoredAssessmentTypeIdentifierGAD7`. `risk`: for GAD-7, 1 none to minimal, 2 mild, 3 moderate, 4 severe; for PHQ-9, 1 none to minimal, 2 mild, 3 moderate, 4 moderately severe, 5 severe.

### Vision prescriptions

On the prescription, "sphere (SPH / S / DS)" goes in `sphere`, "cylinder (CYL / C / DC)" in `cylinder`, "axis (A / AX)" in `axis`, "add (ADD)" in `addPower`, and "pupillary distance (PD)" in `farPupillaryDistance` (distance) or `nearPupillaryDistance` (near). Powers are in `D`, and nearsightedness is negative (what's commonly called "200 degrees" of myopia in China is `-2`); axis is in `deg`; distances are in `mm`. `prescriptionType` 1 is glasses, 2 is contact lenses (contact lenses need a `brand`, may have `baseCurve` and `diameter`, and can't have pupillary distance or prism). Don't write `startDate` or `endDate`; use `dateIssued` (the date it was issued) and the optional `expirationDate` (the expiration date).

```bash
cat > glasses.json <<'JSON'
{"kind":"visionPrescription","type":"HKVisionPrescriptionTypeIdentifier",
 "prescriptionType":1,"dateIssued":"2026-10-20T10:00:00+08:00","expirationDate":"2028-10-20T10:00:00+08:00",
 "rightEye":{"sphere":{"value":-2.25,"unit":"D"},"cylinder":{"value":-0.5,"unit":"D"},"axis":{"value":180,"unit":"deg"},
             "farPupillaryDistance":{"value":31.5,"unit":"mm"}},
 "leftEye":{"sphere":{"value":-2.0,"unit":"D"},"cylinder":{"value":-0.75,"unit":"D"},"axis":{"value":170,"unit":"deg"},
            "farPupillaryDistance":{"value":31.0,"unit":"mm"}}}
JSON
rendu write save --file glasses.json
curl -s -H "Authorization: Bearer $RENDU_API_KEY" -H "Content-Type: application/json" "$RENDU_URL/v1/writes" \
  -d "{\"op\":\"save\",\"object\":$(cat glasses.json)}"
```

Reading vision prescriptions requires the user to allow each one on the iPhone, so `rendu samples HKVisionPrescriptionTypeIdentifier` only returns prescriptions the user has allowed.

### Modifying, deleting and checking results

The result includes an `id` and a `syncIdentifier`. **Remember the `syncIdentifier`**; you need it to modify or delete the entry:

```bash
rendu write save --sync-identifier <syncIdentifier> < corrected.json   # modify: submit the complete new object
rendu write delete <syncIdentifier>                                    # delete
rendu write get <id>                                                   # the result of one write
rendu write list --status pending                                      # writes not yet in Apple Health
```

REST API:

```bash
# Modify: same syncIdentifier, submit the complete new object
curl -s -H "Authorization: Bearer $RENDU_API_KEY" -H "Content-Type: application/json" "$RENDU_URL/v1/writes" \
  -d '{"op":"save","syncIdentifier":"<syncIdentifier>","object":{…}}'
# Delete
curl -s -H "Authorization: Bearer $RENDU_API_KEY" -H "Content-Type: application/json" "$RENDU_URL/v1/writes" \
  -d '{"op":"delete","syncIdentifier":"<syncIdentifier>"}'
# Check results
curl -s -H "Authorization: Bearer $RENDU_API_KEY" "$RENDU_URL/v1/writes/<id>"
curl -s -H "Authorization: Bearer $RENDU_API_KEY" "$RENDU_URL/v1/writes?status=pending"
```

If you've lost the `syncIdentifier`, find it in the samples: entries Rendu wrote carry it in `metadata.HKMetadataKeySyncIdentifier` (their source `sourceRevision.source.name` is `Rendu`; the bundle ID is whatever was set when the app was built). The member samples of meals and workouts carry `<syncIdentifier>:<index>`; to modify or delete, use the one without the index (the correlation's or the workout's own).

Result statuses:

| status | Meaning | What you should do |
|---|---|---|
| `pending` | Waiting for the iPhone to execute it (it also keeps waiting while the iPhone is locked, or while the app doesn't yet have write access to the type, in which case the app's Summary tab asks the user to allow access) | If it needs to take effect soon, remind the user to open the app |
| `written` | Written to Apple Health | It then shows up in `rendu samples`, with `HKMetadataKeySyncIdentifier` in its metadata |
| `failed` | Rejected; the reason is in `error` | Fix it and submit again. Common causes: incompatible unit, value out of range; `only entries saved by Rendu can be changed or deleted` means the entry you tried to change wasn't written by Rendu, so don't try again |
| `conflict` | The entry to modify has been deleted by the user in Apple Health | Ask the user whether to record it again |

Errors returned right at submission:

- `400`: the object is malformed (missing field, misspelled field name, time format, value not in the enum, `kind` and `type` don't match, a read-only kind or field was submitted, etc.). Fix it according to `error`, checking against `fields` in `rendu schema <type>`.
- `404`: when deleting, the server can't find this `syncIdentifier` (neither a write request nor a sample carrying it).
- `422`: the iPhone reports that this type can't be written (`HealthKit doesn't allow apps to write …` or `write access to … is turned off …`); see "First, check what you can write".

Every write carries `submittedBy` (`{"id", "name"}`: the API key that submitted it and its name), so the user can see in the app who wrote each entry.

Any entry Rendu has written can be modified and deleted, including entries written before the user did "Clear Server Data" in the app: the write requests were cleared, but the iPhone uploads the Apple Health data again, and the server finds the original entry through the `HKMetadataKeySyncIdentifier` in the sample. Until the iPhone has re-uploaded, deleting returns `404`; try again later.

## Pairing the iPhone and API keys

You can't do either of these; the user does them in the app:

- Pairing the iPhone: when the user gets a new iPhone, the app shows "No Longer Paired" (the server no longer accepts this iPhone), or `rendu status` has no `lastDeviceSeenAt`, ask the user to pair (again) in the app: the app shows a `rendu-server pair <code>` command for the user to run on the server.
- API keys: the user creates and revokes them in the app under Settings → API Keys, with the permission "Read Only" or "Read & Write". A key is shown only once, when it's created.

## Rules

- Always include the time zone offset in times (`+08:00`). For an instantaneous entry, `startDate` equals `endDate` (state of mind and GAD-7 / PHQ-9 take only `startDate`; vision prescriptions take neither and use `dateIssued`).
- Converting servings is your job ("how many grams of protein are in one scoop of protein powder"); what you submit must be a HealthKit type plus a value and a unit.
- You can only modify and delete entries written through Rendu; data from Apple Watch and other sources is read-only.
- Don't write `HKMetadataKeySyncIdentifier` or `HKMetadataKeySyncVersion`; the app maintains them.
- `RENDU_API_KEY` can read all of the user's health data; never show it in replies, logs or files.
- Every request you make with this key (time, endpoint, type, count) is recorded in the app, and the user can view it at any time. Read only the data your task needs.
