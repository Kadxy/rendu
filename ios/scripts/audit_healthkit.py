#!/usr/bin/env python3
"""Lists what HealthKit's SDK headers offer for reading and writing, and
fails when something appears that Rendu hasn't accounted for: a new sample
class, query, builder, or object type. Run after each Xcode / SDK upgrade,
next to gen_type_catalog.py (new quantity and category identifiers) and the
on-device HealthUIProbe (types the Health app shows).

Usage: python3 -I scripts/audit_healthkit.py [path to HealthKit.framework/Headers]
"""

import pathlib
import re
import sys

DEFAULT = ("/Applications/Xcode-beta.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/"
           "SDKs/iPhoneOS.sdk/System/Library/Frameworks/HealthKit.framework/Headers")

# What Rendu does with each, and why where it doesn't (docs/PROTOCOL.md).
KNOWN = {
    "samples": {
        "HKQuantitySample", "HKCumulativeQuantitySample", "HKDiscreteQuantitySample", "HKCumulativeQuantitySeriesSample",
        "HKCategorySample", "HKCorrelation", "HKWorkout", "HKStateOfMind", "HKElectrocardiogram", "HKAudiogramSample",
        "HKScoredAssessment", "HKGAD7Assessment", "HKPHQ9Assessment", "HKWorkoutRoute", "HKHeartbeatSeriesSample",
        "HKSeriesSample", "HKMedicationDoseEvent", "HKVisionPrescription", "HKGlassesPrescription",
        "HKContactsPrescription", "HKDocumentSample", "HKCDADocumentSample",
        # Health Records: needs the clinical records entitlement; not offered in China.
        "HKClinicalRecord", "HKVerifiableClinicalRecord",
    },
    "queries": {
        "HKQuery", "HKSampleQuery", "HKAnchoredObjectQuery", "HKObserverQuery", "HKStatisticsQuery",
        "HKStatisticsCollectionQuery", "HKActivitySummaryQuery", "HKCorrelationQuery", "HKSourceQuery",
        "HKQuantitySeriesSampleQuery", "HKElectrocardiogramQuery", "HKHeartbeatSeriesQuery", "HKWorkoutRouteQuery",
        "HKWorkoutEffortRelationshipQuery", "HKUserAnnotatedMedicationQuery", "HKDocumentQuery",
        "HKVerifiableClinicalRecordQuery",
    },
    "builders": {
        "HKWorkoutBuilder", "HKLiveWorkoutBuilder", "HKWorkoutRouteBuilder", "HKHeartbeatSeriesBuilder",
        "HKQuantitySeriesSampleBuilder", "HKSeriesBuilder",
    },
    "types": {
        "quantityTypeForIdentifier", "categoryTypeForIdentifier", "characteristicTypeForIdentifier",
        "correlationTypeForIdentifier", "documentTypeForIdentifier", "scoredAssessmentTypeForIdentifier",
        "seriesTypeForIdentifier", "workoutType", "activitySummaryType", "audiogramSampleType", "electrocardiogramType",
        "medicationDoseEventType", "visionPrescriptionType", "stateOfMindType", "userAnnotatedMedicationType",
        "clinicalTypeForIdentifier",
    },
}


def main() -> None:
    headers = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else DEFAULT)
    text = {p.name: p.read_text(errors="ignore") for p in headers.glob("*.h")}
    found = {"samples": set(), "queries": set(), "builders": set(), "types": set()}
    sample_bases = {"HKSample", "HKQuantitySample", "HKSeriesSample", "HKScoredAssessment", "HKVisionPrescription",
                    "HKDocumentSample"}
    for body in text.values():
        for cls, base in re.findall(r"@interface\s+(HK\w+)\s*:\s*(\w+)", body):
            if base in sample_bases:
                found["samples"].add(cls)
            if cls.endswith("Query"):
                found["queries"].add(cls)
            if cls.endswith("Builder"):
                found["builders"].add(cls)
    found["types"] = set(re.findall(r"^\+ \((?:nullable )?HK\w*Type \*\)(\w+)", text.get("HKObjectType.h", ""), re.M))
    new = {k: sorted(v - KNOWN[k]) for k, v in found.items() if v - KNOWN[k]}
    for kind, names in found.items():
        print(f"{kind}: {len(names)}")
    if new:
        print("\nNew in the SDK — decide how Rendu reads/writes them, update docs/PROTOCOL.md and KNOWN:")
        for kind, names in new.items():
            print(f"  {kind}: {', '.join(names)}")
        sys.exit(1)
    print("Nothing new.")


if __name__ == "__main__":
    main()
