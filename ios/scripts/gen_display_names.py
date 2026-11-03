#!/usr/bin/env python3
"""Generate Rendu/Health/DisplayNames.swift: Apple's own display names for every
catalog type, taken from the localization tables of the system HealthKit
framework (macOS ships the same strings as iOS).

Nothing is translated by hand. Each type is mapped to one of Apple's string
keys — by rule where Apple's key follows the identifier, by the MANUAL table
where it doesn't — and every key is checked to exist in Apple's tables. Types
without a key get no name, and the app shows the identifier instead.

Needs macOS with Xcode: identifier raw values are read by compiling a small
Swift program, because a Swift constant's name can differ from its value
(environmentalAudioExposureEvent is "HKCategoryTypeIdentifierAudioExposureEvent").

Usage: python3 -I scripts/gen_display_names.py
"""

import os
import pathlib
import plistlib
import re
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent.parent
CATALOG = HERE / "Rendu/Health/TypeCatalogData.swift"
OUTPUT = HERE / "Rendu/Health/DisplayNames.swift"
TABLES = pathlib.Path("/System/Library/Frameworks/HealthKit.framework/Versions/A/Resources")
LOCALES = {"en": "en", "zh-Hans": "zh_CN"}

# Identifier (without the HK…TypeIdentifier prefix) → Apple's key, where the
# key doesn't follow from the identifier. Each pairing is backed by Apple's
# English string for the key naming the same data type (in comments where the
# names differ).
MANUAL = {
    "StepCount": "STEPS",
    "DistanceWalkingRunning": "DISTANCE",  # "Walking + Running Distance"
    "ActiveEnergyBurned": "ACTIVE_ENERGY",
    "BasalEnergyBurned": "BASAL_ENERGY",  # "Resting Energy"
    "AppleExerciseTime": "EXERCISE_MINUTE",
    "AppleMoveTime": "MOVE_MINUTE",
    "AppleStandTime": "STAND_MINUTE",
    "SwimmingStrokeCount": "SWIMMING_STROKES",
    "HeartRateRecoveryOneMinute": "HEART_RATE_RECOVERY",  # "Cardio Recovery"
    "PeripheralPerfusionIndex": "PERFUSION_INDEX",
    "VO2Max": "CARDIO_FITNESS",  # "Cardio Fitness"
    "DietaryEnergyConsumed": "DIETARY_ENERGY",
    "DietaryFatMonounsaturated": "MONOUNSATURATED_FAT",
    "DietaryFatPolyunsaturated": "POLYUNSATURATED_FAT",
    "DietaryFatSaturated": "SATURATED_FAT",
    "DietaryFatTotal": "TOTAL_FAT",
    "AppleSleepingBreathingDisturbances": "SLEEP_BREATHING_DISTURBANCES",
    "ForcedExpiratoryVolume1": "SPIROMETRY_FEV1",
    "ForcedVitalCapacity": "SPIROMETRY_FVC",
    "PeakExpiratoryFlowRate": "SPIROMETRY_PEFR",
    "HighHeartRateEvent": "TACHYCARDIA",  # "High Heart Rate Notifications"
    "LowHeartRateEvent": "BRADYCARDIA",  # "Low Heart Rate Notifications"
    "IrregularHeartRhythmEvent": "ATRIAL_FIBRILLATION_EVENT",  # "Irregular Rhythm Notifications"
    "LowCardioFitnessEvent": "CARDIO_FITNESS_EVENT",  # "Cardio Fitness Notifications"
    "MindfulSession": "MINDFUL_MINUTES",
    "MenstrualFlow": "MENSTRUATION",
    "InfrequentMenstrualCycles": "MENSTRUAL_CYCLE_DEVIATION_INFREQUENT",
    "IrregularMenstrualCycles": "MENSTRUAL_CYCLE_DEVIATION_IRREGULAR",
    "ProlongedMenstrualPeriods": "MENSTRUAL_CYCLE_DEVIATION_PROLONGED",
    "PersistentIntermenstrualBleeding": "MENSTRUAL_CYCLE_DEVIATION_SPOTTING",  # "Persistent Spotting"
    "GeneralizedBodyAche": "SYMPTOM_BODY_ACHE",  # "Body and Muscle Ache"
    "SinusCongestion": "SYMPTOM_CONGESTION",  # "Congestion"
}

# Object types outside the quantity/category tables, by full identifier.
OTHER = {
    "HKWorkoutTypeIdentifier": "WORKOUT",
    "HKDataTypeStateOfMind": "STATE_OF_MIND",
    "HKDataTypeIdentifierElectrocardiogram": "ELECTROCARDIOGRAM",
    "HKCorrelationTypeIdentifierBloodPressure": "BLOOD_PRESSURE",
    "HKCorrelationTypeIdentifierFood": "FOOD",
    "HKActivitySummaryTypeIdentifier": "ACTIVITY",
    "HKDataTypeIdentifierAudiogram": "AUDIOGRAM",
    "HKScoredAssessmentTypeIdentifierGAD7": "GAD7",
    "HKScoredAssessmentTypeIdentifierPHQ9": "PHQ9",
    "HKWorkoutRouteTypeIdentifier": "WORKOUT_ROUTE",
    "HKMedicationDoseEventTypeIdentifierMedicationDoseEvent": "MEDICATION_DOSE_EVENT",
    "HKVisionPrescriptionTypeIdentifier": "VISION_PRESCRIPTION",
    "HKDocumentTypeIdentifierCDA": "CLINICAL_DOCUMENTS",
}


def snake(name: str) -> str:
    return re.sub(r"(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])", "_", name).upper()


def load_tables() -> dict:
    """locale → key → string, merged across every Localizable*.loctable."""
    merged = {locale: {} for locale in LOCALES.values()}
    for path in sorted(TABLES.glob("Localizable*.loctable")):
        with open(path, "rb") as f:
            table = plistlib.load(f)
        for locale in merged:
            for key, value in table.get(locale, {}).items():
                if isinstance(value, str) and value:
                    merged[locale].setdefault(key, value)
    return merged


def raw_values() -> list:
    """(kind, rawValue) for every catalog identifier, via a Swift helper."""
    source = CATALOG.read_text()
    quantity = re.findall(r"\.init\(\.(\w+), unit:", source)
    category = re.findall(r"\.init\(\.(\w+), values:", source)
    lines = ["import HealthKit"]
    lines += [f'print(HKQuantityTypeIdentifier.{n}.rawValue)' for n in quantity]
    lines += [f'print(HKCategoryTypeIdentifier.{n}.rawValue)' for n in category]
    with tempfile.TemporaryDirectory() as tmp:
        main = pathlib.Path(tmp) / "main.swift"
        main.write_text("\n".join(lines))
        binary = pathlib.Path(tmp) / "rawvalues"
        subprocess.run(["swiftc", str(main), "-o", str(binary)], check=True, env=os.environ)
        out = subprocess.run([str(binary)], check=True, capture_output=True, text=True).stdout
    return out.split()


def resolve(identifier: str, keys: dict):
    suffix = re.sub(r"^HK(Quantity|Category)TypeIdentifier", "", identifier)
    if suffix in MANUAL:
        key = MANUAL[suffix]
        if key not in keys:
            sys.exit(f"MANUAL key {key} for {identifier} is not in Apple's tables")
        return key
    base = snake(suffix)
    candidates = [base, base.removeprefix("DIETARY_"), base.removeprefix("APPLE_"), "SYMPTOM_" + base]
    if base.startswith("DISTANCE_"):
        candidates.append(base.removeprefix("DISTANCE_") + "_DISTANCE")
    return next((c for c in candidates if c in keys), None)


def swift_dict(entries: dict) -> str:
    body = "\n".join(f'        "{k}": "{v}",' for k, v in sorted(entries.items()))
    return "[\n" + body + "\n    ]"


def main() -> None:
    tables = load_tables()
    en = tables["en"]
    resolved, missing = {}, []
    for identifier in raw_values():
        key = resolve(identifier, en)
        if key:
            resolved[identifier] = key
        else:
            missing.append(identifier)
    for identifier, key in OTHER.items():
        if key in en:
            resolved[identifier] = key
        else:
            missing.append(identifier)

    names = {}
    for swift_locale, table_locale in LOCALES.items():
        names[swift_locale] = {i: tables[table_locale][k] for i, k in resolved.items() if k in tables[table_locale]}

    OUTPUT.write_text(
        "// Generated by scripts/gen_display_names.py from the system HealthKit\n"
        "// framework's localization tables. Do not edit.\n\n"
        "enum DisplayNames {\n"
        + "".join(
            f"    static let {('zhHans' if loc == 'zh-Hans' else loc)}: [String: String] = {swift_dict(entries)}\n\n"
            for loc, entries in names.items()
        ).rstrip("\n")
        + "\n}\n"
    )
    print(f"{OUTPUT.name}: " + ", ".join(f"{loc} {len(e)}" for loc, e in names.items()))
    print("no Apple name (identifier shown):", ", ".join(missing) or "none")


if __name__ == "__main__":
    main()
