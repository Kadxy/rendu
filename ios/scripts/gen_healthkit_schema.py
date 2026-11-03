#!/usr/bin/env python3
"""Generate internal/schema/healthkit.json from the iOS SDK's HealthKit headers.

The server embeds the file and serves it under GET /v1/schema
(docs/PROTOCOL.md, "数据定义"), so an agent gets Apple's own definitions
instead of hand-written docs that drift:

- types: every type identifier (HKTypeIdentifiers.h, HKClinicalType.h) and
  the HKObjectType factory types that have no identifier constant. Each has
  its kind, iOS availability and Apple's trailing comment verbatim ("note":
  canonical unit and aggregation style, or the category value enum).
- enums: every NS_ENUM / NS_OPTIONS, with each case's raw value computed
  (explicit, implicit increments, shifts, references to earlier cases) and
  its Swift case name. Cases unavailable on iOS are left out.
- metadataKeys: every HKMetadataKey… constant with its documentation.

Types and metadata keys are keyed by their string value, which is what goes
on the wire (HKObjectType.identifier, the keys of an object's metadata). A
constant's value can differ from its name (HKMetadataKeyFoodType is
"HKFoodType", HKDataTypeIdentifierStateOfMind is "HKDataTypeStateOfMind"),
and headers don't hold the values, so they are read from the system
HealthKit framework: run on macOS at least as new as the SDK.

Usage: python3 -I scripts/gen_healthkit_schema.py [path/to/iPhoneOS.sdk]
(default: $DEVELOPER_DIR's iPhoneOS SDK, else Xcode-beta's).
"""

import ast
import ctypes
import ctypes.util
import json
import os
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
OUTPUT = ROOT / "internal/schema/healthkit.json"
SDK_IN_DEVELOPER = "Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk"
SYSTEM_HEALTHKIT = "/System/Library/Frameworks/HealthKit.framework/HealthKit"

# Kinds use Rendu's names (docs/PROTOCOL.md, "读写能力"). Identifier
# constants typed NSString * have no typedef to tell their kind; neither do
# the HKObjectType factory types without a constant. A new one fails the run.
TYPEDEF_KINDS = {
    "HKQuantityTypeIdentifier": "quantity",
    "HKCategoryTypeIdentifier": "category",
    "HKCharacteristicTypeIdentifier": "characteristic",
    "HKCorrelationTypeIdentifier": "correlation",
    "HKScoredAssessmentTypeIdentifier": "scoredAssessment",
    "HKClinicalTypeIdentifier": "clinicalRecord",
    # HKDocumentTypeIdentifierCDA → cdaDocument (HKCDADocumentSample).
    "HKDocumentTypeIdentifier": "document",
}
CONSTANT_KINDS = {
    "HKWorkoutTypeIdentifier": "workout",
    "HKWorkoutRouteTypeIdentifier": "workoutRoute",
    "HKDataTypeIdentifierHeartbeatSeries": "heartbeatSeries",
    "HKVisionPrescriptionTypeIdentifier": "visionPrescription",
    "HKDataTypeIdentifierStateOfMind": "stateOfMind",
    "HKMedicationDoseEventTypeIdentifierMedicationDoseEvent": "medicationDoseEvent",
    "HKDataTypeIdentifierUserAnnotatedMedicationConcept": "userAnnotatedMedication",
}
FACTORY_KINDS = {
    "activitySummaryType": "activitySummary",
    "audiogramSampleType": "audiogram",
    "electrocardiogramType": "electrocardiogram",
}
# Factory methods whose types have identifier constants (checked: the values
# must match), and the ones taking an identifier.
FACTORY_WITH_CONSTANT = {
    "workoutType", "workoutRouteType", "heartbeatSeriesType", "medicationDoseEventType",
    "visionPrescriptionType", "stateOfMindType", "userAnnotatedMedicationType",
}
TYPE_HEADERS = ["HKTypeIdentifiers.h", "HKClinicalType.h"]
# Spot checks: a bad parse fails here rather than in the Go tests.
KNOWN_VALUES = {
    ("HKWorkoutActivityType", "traditionalStrengthTraining"): 50,
    ("HKWorkoutActivityType", "running"): 37,
    ("HKWorkoutActivityType", "other"): 3000,
    ("HKStateOfMindLabel", "stressed"): 29,
    ("HKWorkoutEventType", "lap"): 3,
    ("HKCategoryValueSleepAnalysis", "asleepREM"): 5,
    ("HKStatisticsOptions", "duration"): 64,
    ("HKCategoryValueOvulationTestResult", "positive"): 2,
}


# --- the system framework: constant values -------------------------------

class Runtime:
    """String values of HealthKit constants and factory types, read from the
    system framework with the Objective-C runtime."""

    def __init__(self):
        try:
            self.hk = ctypes.CDLL(SYSTEM_HEALTHKIT)
            objc = ctypes.CDLL(ctypes.util.find_library("objc"))
        except OSError as e:
            sys.exit(f"needs macOS with HealthKit ({SYSTEM_HEALTHKIT}): {e}")
        objc.sel_registerName.restype = ctypes.c_void_p
        objc.sel_registerName.argtypes = [ctypes.c_char_p]
        objc.objc_getClass.restype = ctypes.c_void_p
        objc.objc_getClass.argtypes = [ctypes.c_char_p]
        self.objc = objc
        self.send_id = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p)(
            ctypes.cast(objc.objc_msgSend, ctypes.c_void_p).value)
        self.send_str = ctypes.CFUNCTYPE(ctypes.c_char_p, ctypes.c_void_p, ctypes.c_void_p)(
            ctypes.cast(objc.objc_msgSend, ctypes.c_void_p).value)

    def _sel(self, name):
        return self.objc.sel_registerName(name.encode())

    def _string(self, obj):
        return self.send_str(obj, self._sel("UTF8String")).decode() if obj else None

    def constant(self, name):
        """The NSString a constant holds, or None when this Mac lacks it."""
        try:
            pointer = ctypes.c_void_p.in_dll(self.hk, name).value
        except ValueError:
            return None
        return self._string(pointer)

    def factory_identifier(self, cls, method):
        klass = self.objc.objc_getClass(cls.encode())
        if not klass:
            return None
        return self._string(self.send_id(self.send_id(klass, self._sel(method)), self._sel("identifier")))


# --- headers -------------------------------------------------------------

def preprocess(text):
    """Keep what an Objective-C compile sees: drop the Swift side of
    `#if defined(__swift__) && __swift__` (and `#ifdef __swift__`), keep
    every other conditional's first branch, drop directives."""
    out, stack = [], []  # stack: is the current branch kept?
    for line in text.splitlines():
        directive = re.match(r"\s*#\s*(\w+)\s*(.*)", line)
        if not directive:
            out.append(line if all(stack) else "")
            continue
        word, rest = directive.groups()
        if word in ("if", "ifdef", "ifndef"):
            swift = "__swift__" in rest
            stack.append(not swift if word != "ifndef" else swift)
        elif word in ("else", "elif"):
            stack[-1] = not stack[-1]
        elif word == "endif":
            stack.pop()
        out.append("")
    return "\n".join(out)


def platform_versions(args):
    """{"ios": ("8.0", "16.0"), …} from an availability macro's arguments."""
    return {m.group(1): tuple(v.strip() for v in m.group(2).split(","))
            for m in re.finditer(r"\b(ios|macos|watchos|tvos|visionos|macCatalyst)\(([^()]*)\)", args)}


def availability(attrs):
    """iOS availability from a declaration's macros: {"available", "deprecated",
    "replacement"} (absent when not stated), or None when unavailable on iOS."""
    info = {}
    for m in re.finditer(r"\b(API_AVAILABLE|API_DEPRECATED_WITH_REPLACEMENT|API_DEPRECATED|API_UNAVAILABLE)\s*\(", attrs):
        args = balanced(attrs, m.end() - 1)
        macro = m.group(1)
        if macro == "API_UNAVAILABLE":
            if re.search(r"\bios\b", args):
                return None
            continue
        versions = platform_versions(args)
        if "ios" in versions:
            info.setdefault("available", versions["ios"][0])
        if macro.startswith("API_DEPRECATED") and ("ios" in versions or not versions):
            info["deprecated"] = True
            if macro == "API_DEPRECATED_WITH_REPLACEMENT":
                info["replacement"] = re.match(r'\s*"([^"]*)"', args).group(1)
    if re.search(r"__IOS_PROHIBITED|NS_UNAVAILABLE", attrs):
        return None
    return info


def balanced(text, open_index):
    """The text inside the parentheses opening at open_index."""
    depth = 0
    for i in range(open_index, len(text)):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return text[open_index + 1:i]
    raise ValueError("unbalanced parentheses: " + text[open_index:open_index + 80])


def clean(text):
    """Collapse a comment's text: paragraphs joined by blank lines, each on
    one line."""
    paragraphs, current = [], []
    for line in text.splitlines():
        line = re.sub(r"^\s*(///?|\*(?!/))\s?", "", line).strip()
        if line:
            current.append(line)
        elif current:
            paragraphs.append(" ".join(current))
            current = []
    if current:
        paragraphs.append(" ".join(current))
    return "\n\n".join(paragraphs).strip()


def doc_before(text, start):
    """The doc comment right before position start (a /** */ or /*! */ block,
    or /// lines), parsed into HeaderDoc tags: {"text", "abstract",
    "discussion", "constants": {name: text}}; {} when there is none."""
    before = text[:start].rstrip()
    if before.endswith("*/"):
        opening = before.rfind("/*")
        if before[opening:opening + 3] not in ("/**", "/*!"):
            return {}
        body = before[opening + 3:-2]
    else:
        lines = []
        for line in reversed(before.splitlines()):
            if not line.strip().startswith("///"):
                break
            lines.insert(0, line.strip()[3:])
        if not lines:
            return {}
        body = "\n".join(lines)
    return headerdoc(body)


def headerdoc(body):
    tags = {"constants": {}}
    tag, constant, lines = "text", None, []

    def flush():
        value = clean("\n".join(lines))
        if tag == "constant":
            if constant and value:
                tags["constants"][constant] = value
        elif value:
            tags[tag] = (tags[tag] + "\n\n" + value) if tag in tags else value

    for line in body.splitlines():
        m = re.match(r"\s*@(\w+)\s*(.*)", line)
        if m:
            flush()
            tag, rest = m.group(1), m.group(2)
            constant = None
            if tag == "constant":
                parts = rest.split(None, 1)
                constant = parts[0] if parts else None
                rest = parts[1] if len(parts) > 1 else ""
            lines = [rest]
        else:
            lines.append(line)
    flush()
    return tags


def summary(doc):
    """An abstract and its discussion, or the plain doc comment."""
    parts = [doc[k] for k in ("abstract", "discussion") if k in doc]
    return "\n\n".join(parts) if parts else doc.get("text", "")


# --- enums ---------------------------------------------------------------

ENUM = re.compile(r"typedef\s+NS_(ENUM|OPTIONS|CLOSED_ENUM)\s*\(\s*\w+\s*,\s*(\w+)\s*\)\s*\{(.*?)\}([^;]*);", re.S)


def words(name):
    """Camel-case words: HKCategoryValueSleepAnalysisAsleepREM → HK, Category,
    Value, Sleep, Analysis, Asleep, REM."""
    return re.findall(r"[A-Z]+(?![a-z])|[A-Z][a-z0-9]*|[a-z0-9]+", name)


def common_prefix(a, b):
    """Swift's common word prefix of two names, a plural "s" matching
    (HKQueryOptions ~ HKQueryOption…)."""
    wa, wb, n = words(a), words(b), 0
    while n < min(len(wa), len(wb)) and (wa[n] == wb[n] or wa[n].rstrip("s") == wb[n].rstrip("s")):
        n += 1
    return wb[:n]


def swift_case(enum_name, case_names, name):
    """The Swift name of an enum case (ClangImporter): the prefix shared by the
    enum's name and its available cases dropped, backing off a word if the
    rest would start with a digit; then the leading initialism lowercased,
    unless the whole rest is uppercase (HKFitzpatrickSkinTypeI → I)."""
    prefix = words(case_names[0])
    for other in case_names[1:]:
        prefix = common_prefix("".join(prefix), other)
    prefix = common_prefix(enum_name, "".join(prefix))
    rest_words = words(name)[len(prefix):]
    while rest_words and rest_words[0][0].isdigit() and prefix:
        rest_words.insert(0, prefix.pop())
    rest = "".join(rest_words)
    if not rest or not re.search(r"[a-z]", rest):
        return rest
    run = len(rest) - len(rest.lstrip("ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
    if run > 1 and run < len(rest) and rest[run].islower():
        run -= 1
    return rest[:run].lower() + rest[run:]


def evaluate(expr, known, where):
    """An enumerator's value: integers (hex, suffixes), shifts and bitwise
    operators, parentheses, and earlier enumerators."""
    expr = re.sub(r"\b(0[xX][0-9a-fA-F]+|\d+)[uUlL]+\b", r"\1", expr)
    expr = re.sub(r"\(\s*(?:NSU?Integer|unsigned|long|int)\s*\)", "", expr)

    def name(m):
        if m.group(0) not in known:
            sys.exit(f"{where}: unknown name {m.group(0)} in value {expr!r}")
        return str(known[m.group(0)])

    expr = re.sub(r"\b[A-Za-z_]\w*\b", name, expr)
    node = ast.parse(expr.strip(), mode="eval")
    allowed = (ast.Expression, ast.BinOp, ast.UnaryOp, ast.Constant, ast.LShift, ast.RShift, ast.BitOr,
               ast.BitAnd, ast.BitXor, ast.Invert, ast.USub, ast.UAdd, ast.Add, ast.Sub, ast.Mult)
    for n in ast.walk(node):
        if not isinstance(n, allowed):
            sys.exit(f"{where}: can't evaluate {expr!r}")
    return eval(compile(node, where, "eval"))  # only integer arithmetic, checked above


def split_entries(body):
    """An enum body's enumerators: [(code, doc)], doc from /// lines above or
    a comment trailing the enumerator."""
    entries, pending, current = [], [], ""
    for line in body.splitlines():
        code, comment = line, ""
        m = re.search(r"//|/\*", line)
        if m:
            code, comment = line[:m.start()], line[m.start():]
        if not code.strip():
            if comment.strip().startswith("///"):
                pending.append(comment.strip()[3:])
            continue
        trailing = clean(re.sub(r"^/\*+!?|\*/$|^/+", "", comment.strip()))
        depth, start = 0, 0
        for i, ch in enumerate(code):
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
            elif ch == "," and depth == 0:
                entries.append([current + code[start:i], clean("\n".join(pending))])
                current, pending, start = "", [], i + 1
        current += code[start:]
        if trailing:
            if current.strip():
                pending.append(trailing)
            elif entries:
                entries[-1][1] = entries[-1][1] or trailing
    if current.strip():
        entries.append([current, clean("\n".join(pending))])
    return [(code.strip(), doc) for code, doc in entries]


def parse_enums(headers, values):
    enums = {}
    for header, text in headers.items():
        for m in ENUM.finditer(text):
            flavor, name, body, after = m.groups()
            info = availability(after)
            if info is None:
                continue
            doc = doc_before(text, m.start())
            entry = {"options": flavor == "OPTIONS", **info}
            swift = re.search(r"NS_SWIFT_NAME\(\s*([\w.]+)\s*\)", after)
            if swift:
                entry["swiftName"] = swift.group(1)
            if summary(doc):
                entry["doc"] = summary(doc)

            cases, previous = [], -1
            for code, case_doc in split_entries(body):
                cm = re.match(r"(\w+)\s*(.*)", code, re.S)
                case_name, rest = cm.groups()
                value_expr = None
                eq = rest.find("=")
                if eq >= 0:
                    rest, value_expr = rest[:eq], rest[eq + 1:]
                    value_expr = re.sub(r"\b(API_\w+|NS_\w+)\s*\(.*\)", "", value_expr, flags=re.S)
                value = evaluate(value_expr, values, f"{header}: {case_name}") if value_expr else previous + 1
                values[case_name] = previous = value
                case_info = availability(rest)
                if case_info is None:
                    continue
                case = {"name": case_name, "value": value}
                if case_info.get("deprecated"):
                    case["deprecated"] = True
                if case_info.get("available") and case_info["available"] != entry.get("available"):
                    case["available"] = case_info["available"]
                case_swift = re.search(r"NS_SWIFT_NAME\(\s*(\w+)\s*\)", rest)
                if case_swift:
                    case["swiftName"] = case_swift.group(1)
                case_doc = case_doc or doc.get("constants", {}).get(case_name, "")
                if case_doc:
                    case["doc"] = case_doc
                cases.append(case)
            # Swift names: the shared prefix comes from the non-deprecated cases.
            current = [c["name"] for c in cases if not c.get("deprecated")] or [c["name"] for c in cases]
            for case in cases:
                case["short"] = case.pop("swiftName", None) or swift_case(name, current, case["name"])
            entry["cases"] = cases
            enums[name] = entry
    return enums


# --- type identifiers and metadata keys ----------------------------------

CONSTANT = re.compile(r"HK_EXTERN\s+(\w+)\s*\*?\s*const\s+(HK\w+)\s*([^;]*);[ \t]*(//[^\n]*)?")


def parse_types(headers, runtime, enums):
    types = {}
    for header in TYPE_HEADERS:
        text = headers[header]
        for m in CONSTANT.finditer(text):
            typedef, constant, attrs, note = m.groups()
            if typedef == "NSString":
                if constant not in CONSTANT_KINDS:
                    sys.exit(f"{header}: {constant} is new; add its kind to CONSTANT_KINDS")
                kind = CONSTANT_KINDS[constant]
            elif typedef in TYPEDEF_KINDS:
                kind = TYPEDEF_KINDS[typedef]
                if kind == "document":
                    kind = constant.removeprefix("HKDocumentTypeIdentifier").lower() + "Document"
            else:
                continue
            info = availability(attrs)
            if info is None:
                continue
            entry = {"kind": kind, **info}
            doc = summary(doc_before(text, m.start()))
            if doc:
                entry["doc"] = doc
            if note and note.strip("/ \t"):
                entry["note"] = note[2:].strip()
            add_values(entry, enums)
            add_type(types, runtime, constant, entry)

    # Factory types without a constant (HKObjectType, HKSeriesType).
    text = headers["HKObjectType.h"]
    for cls in re.finditer(r"@interface\s+(\w+)\s*:.*?@end", text, re.S):
        for m in re.finditer(r"^\+\s*\((?:nullable\s+)?(?:\w+\s*\*|instancetype)\)(\w+)\s*([^;:]*);", cls.group(0), re.M):
            method, attrs = m.groups()
            if method in FACTORY_WITH_CONSTANT:
                identifier = runtime.factory_identifier(cls.group(1), method)
                if identifier not in types and identifier not in (t.get("constant") for t in types.values()):
                    sys.exit(f"+{method} returns {identifier}, which no identifier constant holds")
                continue
            if method not in FACTORY_KINDS:
                sys.exit(f"HKObjectType.h: +{method} is new; add it to FACTORY_KINDS or FACTORY_WITH_CONSTANT")
            info = availability(attrs)
            identifier = runtime.factory_identifier(cls.group(1), method)
            if info is None or identifier is None:
                sys.exit(f"+{method}: no identifier on this Mac")
            types[identifier] = {"kind": FACTORY_KINDS[method], "factory": method, **info}
    return types


def add_values(entry, enums):
    """The enum a category type's (or a characteristic's) values come from,
    and a quantity type's aggregation style, from Apple's note."""
    note = entry.get("note", "")
    if entry["kind"] == "category" and note in enums:
        entry["values"] = note
    elif entry["kind"] == "characteristic" and note.removesuffix("Object") in enums:
        entry["values"] = note.removesuffix("Object")
    elif entry["kind"] == "quantity":
        style = note.split(",", 1)[-1] if "," in note else ""
        short = swift_case("", [""], "".join(w[:1].upper() + w[1:] for w in re.findall(r"\w+", style)))
        styles = {c["short"] for c in enums["HKQuantityAggregationStyle"]["cases"]}
        if short not in styles:
            sys.exit(f"aggregation {style!r} in note {note!r} is not an HKQuantityAggregationStyle")
        entry["aggregation"] = short


def add_type(types, runtime, constant, entry):
    value = runtime.constant(constant)
    if value is None:
        sys.exit(f"{constant} is not in this Mac's HealthKit; run on macOS at least as new as the SDK")
    if value != constant:
        entry["constant"] = constant
    if value in types:
        # A deprecated constant naming the same type as a current one
        # (HKCategoryTypeIdentifierAudioExposureEvent): keep the current one.
        if entry.get("deprecated"):
            return
        if not types[value].get("deprecated"):
            sys.exit(f"{constant} and {types[value].get('constant', value)} are both {value}")
    types[value] = entry


# "The expected value type is NSString", "Value is a BOOL", "The key for an
# NSNumber", "should be used to store an HKQuantity"…
VALUE_TYPE = re.compile(r"(?:\b[Vv]alue(?: type)?(?: of the metadata)? (?:is|should be)|\bkey for|\bused to store)"
                        r"(?: an?)*(?: boolean)? (NSString|NSNumber|NSDate|HKQuantity|BOOL)\b")


def parse_metadata(headers, runtime, enums):
    keys = {}
    for header, text in headers.items():
        for m in CONSTANT.finditer(text):
            typedef, constant, attrs, _ = m.groups()
            if not constant.startswith("HKMetadataKey") or typedef != "NSString":
                continue
            info = availability(attrs)
            if info is None:
                continue
            value = runtime.constant(constant)
            if value is None:
                sys.exit(f"{constant} is not in this Mac's HealthKit; run on macOS at least as new as the SDK")
            entry = {"constant": constant, **info}
            doc = summary(doc_before(text, m.start()))
            if doc:
                entry["doc"] = doc
                vt = VALUE_TYPE.search(doc)
                if vt:
                    entry["valueType"] = "NSNumber" if vt.group(1) == "BOOL" else vt.group(1)
                enum = re.search(r"\bcontaining an? (HK\w+) value\b", doc)
                if enum and enum.group(1) in enums:
                    entry["values"] = enum.group(1)
            if value in keys:
                sys.exit(f"{constant} and {keys[value]['constant']} are both {value}")
            keys[value] = entry
    return keys


# --- main ----------------------------------------------------------------

def default_sdk():
    developer = os.environ.get("DEVELOPER_DIR", "/Applications/Xcode-beta.app/Contents/Developer")
    return pathlib.Path(developer) / SDK_IN_DEVELOPER


def main():
    sdk = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else default_sdk()
    header_dir = sdk / "System/Library/Frameworks/HealthKit.framework/Headers"
    if not header_dir.is_dir():
        sys.exit(f"no HealthKit headers in {sdk}")
    version = json.loads((sdk / "SDKSettings.json").read_text())["Version"]
    headers = {p.name: preprocess(p.read_text(errors="replace")) for p in sorted(header_dir.glob("*.h"))}
    runtime = Runtime()

    values = {}
    enums = parse_enums(headers, values)
    for (enum, short), want in KNOWN_VALUES.items():
        got = next((c["value"] for c in enums[enum]["cases"] if c["short"] == short), None)
        if got != want:
            sys.exit(f"{enum}.{short} = {got}, want {want}: the parser is off")
    types = parse_types(headers, runtime, enums)
    keys = parse_metadata(headers, runtime, enums)

    out = {"sdk": {"version": version}, "types": types, "enums": enums, "metadataKeys": keys}
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(out, indent=1, sort_keys=True, ensure_ascii=False) + "\n")
    print(f"{OUTPUT.relative_to(ROOT)}: SDK {version}, {len(types)} types, {len(enums)} enums, "
          f"{sum(len(e['cases']) for e in enums.values())} cases, {len(keys)} metadata keys")


if __name__ == "__main__":
    main()
