#!/usr/bin/env python3
"""Generate Rendu/Health/TypeCatalogData.swift from the iOS SDK's HKTypeIdentifiers.h.

Apple annotates every quantity identifier with its canonical unit and every
category identifier with its value enum; this script turns those comments into
a Swift table so "all types" stays a regeneration away when the SDK grows.

The table references the typed Swift constants, never string literals: a
constant's value can differ from its name (EnvironmentalAudioExposureEvent is
"HKCategoryTypeIdentifierAudioExposureEvent"), and a misspelled constant fails
to compile instead of crashing at launch.

Usage: python3 -I scripts/gen_type_catalog.py [path/to/HKTypeIdentifiers.h]
"""

import pathlib
import re
import sys

DEFAULT_HEADER = (
    "/Applications/Xcode-beta.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/"
    "SDKs/iPhoneOS.sdk/System/Library/Frameworks/HealthKit.framework/Headers/HKTypeIdentifiers.h"
)
OUTPUT = pathlib.Path(__file__).resolve().parent.parent / "Rendu/Health/TypeCatalogData.swift"

# Header units that read badly on the wire (per-second rates, micrograms as
# grams). Replacements match what the Health app displays.
UNIT_OVERRIDES = {
    "HeartRate": "count/min",
    "RespiratoryRate": "count/min",
    "UVExposure": "count",
}
for name in [
    "Caffeine", "Calcium", "Chloride", "Cholesterol", "Copper", "Iron", "Magnesium",
    "Manganese", "Niacin", "PantothenicAcid", "Phosphorus", "Potassium", "Riboflavin",
    "Sodium", "Thiamin", "VitaminB6", "VitaminC", "VitaminE", "Zinc",
]:
    UNIT_OVERRIDES["Dietary" + name] = "mg"
for name in [
    "Biotin", "Chromium", "Folate", "Iodine", "Molybdenum", "Selenium",
    "VitaminA", "VitaminB12", "VitaminD", "VitaminK",
]:
    UNIT_OVERRIDES["Dietary" + name] = "mcg"

# Types presumed read-only for third-party apps. Only a fallback: the app asks
# HealthKit itself which types it may write (see HealthAuthorization) and uses
# this list only if HealthKit's refusal can't be parsed.
READ_ONLY = {
    # quantity
    "AppleExerciseTime", "AppleMoveTime", "AppleStandTime", "AppleSleepingWristTemperature",
    "AppleSleepingBreathingDisturbances", "AppleWalkingSteadiness", "AtrialFibrillationBurden",
    "WalkingHeartRateAverage", "EstimatedWorkoutEffortScore", "NikeFuel",
    "EnvironmentalSoundReduction", "HeartRateRecoveryOneMinute", "SixMinuteWalkTestDistance",
    "WalkingSpeed", "WalkingStepLength", "WalkingAsymmetryPercentage",
    "WalkingDoubleSupportPercentage", "StairAscentSpeed", "StairDescentSpeed", "PhysicalEffort",
    "TimeInDaylight", "EnvironmentalAudioExposure", "HeadphoneAudioExposure", "UnderwaterDepth",
    # category
    "AppleStandHour", "HighHeartRateEvent", "LowHeartRateEvent", "IrregularHeartRhythmEvent",
    "LowCardioFitnessEvent", "AppleWalkingSteadinessEvent", "SleepApneaEvent", "HypertensionEvent",
    "EnvironmentalAudioExposureEvent", "HeadphoneAudioExposureEvent", "InfrequentMenstrualCycles",
    "IrregularMenstrualCycles", "PersistentIntermenstrualBleeding", "ProlongedMenstrualPeriods",
    "MenopausalState", "BleedingAfterMenopause",
}

# Category value enums that get a `valueName` on the wire.
VALUE_ENUMS = {
    "HKCategoryValueSleepAnalysis": ".sleepAnalysis",
    "HKCategoryValueAppleStandHour": ".appleStandHour",
    "HKCategoryValueSeverity": ".severity",
    "HKCategoryValuePresence": ".presence",
}

def swift_name(name: str) -> str:
    """Swift's import name for an identifier suffix: the leading word is
    lowercased, an acronym all but its last letter when a word follows
    (UVExposure → uvExposure, VO2Max → vo2Max, SleepAnalysis → sleepAnalysis)."""
    run = len(name) - len(name.lstrip("ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
    if run > 1 and run < len(name) and name[run].islower():
        run -= 1
    return name[:run].lower() + name[run:]


LINE = re.compile(
    r"HK_EXTERN HK(Quantity|Category)TypeIdentifier const HK(?:Quantity|Category)TypeIdentifier(\w+)"
    r"\s+(API_\w+\(.*?\))\s*;\s*(?://\s*(.*))?$"
)


def main() -> None:
    header = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_HEADER)
    quantity, category = [], []
    for raw in header.read_text().splitlines():
        match = LINE.search(raw)
        if not match:
            continue
        kind, name, availability, comment = match.groups()
        if "DEPRECATED" in availability:
            continue
        comment = (comment or "").strip()
        shareable = "false" if name in READ_ONLY else "true"
        if kind == "Quantity":
            unit = UNIT_OVERRIDES.get(name) or comment.split(",")[0].strip()
            if not unit:
                sys.exit(f"no unit for {name}; add an override")
            quantity.append(f'        .init(.{swift_name(name)}, unit: "{unit}", shareable: {shareable}),')
        else:
            values = VALUE_ENUMS.get(comment, "nil")
            category.append(f'        .init(.{swift_name(name)}, values: {values}, shareable: {shareable}),')

    OUTPUT.write_text(
        "// Generated by scripts/gen_type_catalog.py from HKTypeIdentifiers.h. Do not edit.\n\n"
        "enum TypeCatalogData {\n"
        "    static let quantity: [QuantityEntry] = [\n" + "\n".join(quantity) + "\n    ]\n\n"
        "    static let category: [CategoryEntry] = [\n" + "\n".join(category) + "\n    ]\n"
        "}\n"
    )
    print(f"{OUTPUT.name}: {len(quantity)} quantity, {len(category)} category types")


if __name__ == "__main__":
    main()
