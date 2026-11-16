#!/bin/sh
# Build the app (Release) and install it on an iPhone that's plugged in or on
# the same Wi-Fi, which also re-signs it: with a free Apple ID the signature
# lasts 7 days. The app's data is kept.
#
#   make ios-install                 # the one reachable iPhone
#   make ios-install DEVICE=<UDID>   # pick one when several are reachable
#
# Needs ios/Local.xcconfig and your Apple ID in Xcode → Settings → Accounts.
# Each step's full output is in $DERIVED/<step>.log.
set -eu

cd "$(dirname "$0")/.."
: "${DEVELOPER_DIR:=/Applications/Xcode-beta.app/Contents/Developer}"
export DEVELOPER_DIR
DERIVED=${DERIVED:-/tmp/rendu-rel}

if [ ! -f Local.xcconfig ]; then
	echo "ios/Local.xcconfig is missing: copy Local.xcconfig.example and fill it in" >&2
	exit 1
fi

# On exit (and Ctrl-C) stop the progress line and remove the device list.
ticker= list=
trap '[ -z "$ticker" ] || kill "$ticker" 2>/dev/null; [ -z "$list" ] || rm -f "$list"' EXIT
trap 'echo; exit 130' INT TERM

if [ -z "${DEVICE:-}" ]; then
	list=$(mktemp)
	xcrun devicectl list devices --quiet --json-output "$list" >/dev/null
	# Prefer iPhones whose tunnel is up; one on the same Wi-Fi shows as
	# "disconnected" until something connects to it ("unavailable" = not reachable).
	connected=$(python3 -I -c '
import json, sys
phones = [d for d in json.load(open(sys.argv[1]))["result"]["devices"] if d["hardwareProperties"].get("platform") == "iOS"]
for state in ("connected", "disconnected"):
    found = [d for d in phones if d["connectionProperties"].get("tunnelState") == state]
    for d in found:
        print(d["hardwareProperties"]["udid"], d["deviceProperties"]["name"])
    if found:
        break
' "$list")
	case $(printf '%s' "$connected" | grep -c .) in
	0)
		echo "no iPhone connected: plug it in (or turn on Wi-Fi pairing) and unlock it" >&2
		exit 1
		;;
	1) DEVICE=${connected%% *} ;;
	*)
		echo "several iPhones reachable, pick one with DEVICE=<UDID>:" >&2
		echo "$connected" >&2
		exit 1
		;;
	esac
	echo "iPhone: ${connected#* }"
fi

# step NAME LABEL PROGRESS COMMAND…: runs COMMAND with its output in
# $DERIVED/NAME.log. On a terminal one line says what it's doing (`PROGRESS
# LOG` adds to it) and for how long, next to how long it took last time; it
# ends in ✓ or ✗, followed by the warnings or errors from the log. COMMAND
# runs in the foreground, so Ctrl-C reaches it as usual.
step() {
	log="$DERIVED/$1.log" label=$2 progress=$3
	shift 3
	last=$(cat "$log.seconds" 2>/dev/null || true)
	start=$(date +%s)
	: >"$log"
	if [ -t 1 ]; then
		while :; do
			printf '\r\033[K… %s%s  %ss%s' "$label" "$($progress "$log")" \
				$(($(date +%s) - start)) "${last:+ (last time ${last}s)}"
			sleep 0.2
		done &
		ticker=$!
	else
		echo "… $label"
	fi
	if "$@" >"$log" 2>&1; then rc=0; else rc=$?; fi
	if [ -n "$ticker" ]; then
		kill "$ticker"
		wait "$ticker" 2>/dev/null || true
		ticker=
		printf '\r\033[K'
	fi
	seconds=$(($(date +%s) - start))
	if [ "$rc" -eq 0 ]; then
		echo "✓ $label  ${seconds}s"
		echo "$seconds" >"$log.seconds"
		grep ': warning: ' "$log" | sed "s|$PWD/||" | awk '!seen[$0]++' || true
	else
		echo "✗ $label  ${seconds}s"
		# Xcode 27 beta also prints a bogus "failed with exit code 0" error.
		errors=$(grep -E '(^|: )error: ' "$log" | grep -v 'exit code 0 but produced no further output' |
			sed "s|$PWD/||" | awk '!seen[$0]++' || true)
		if [ -n "$errors" ]; then echo "$errors"; else tail -n 20 "$log"; fi
		echo "Full log: $log"
		exit "$rc"
	fi
}

none() { :; }

# The build is mostly one silent task that compiles every Swift file (Release
# builds the whole module at once): name the phase from the latest task.
build_phase() {
	case $(grep -oE '^[A-Z][A-Za-z]+ ' "$1" | grep -vE '^(Command|Prepare|Build|ExecuteExternalTool|ClangStatCache) ' | tail -n 1) in
	'') echo ": preparing" ;;
	Swift*) echo ": compiling Swift" ;;
	CompileAssetCatalog* | LinkAssetCatalog*) echo ": compiling assets" ;;
	CompileXCStrings*) echo ": compiling strings" ;;
	CompileC*) echo ": compiling Objective-C" ;;
	Ld*) echo ": linking" ;;
	CodeSign*) echo ": signing" ;;
	*) echo ": packaging" ;;
	esac
}

install_percent() {
	grep -oE '[0-9]{1,3}%' "$1" | tail -n 1 | sed 's/^/: /' || true
}

mkdir -p "$DERIVED"
# Over Wi-Fi the tunnel only comes up on demand: open it before building.
step connect "Connecting to the iPhone" none xcrun devicectl device info details --device "$DEVICE"
step xcodegen "Generating the Xcode project" none xcodegen generate
step build "Building (Release)" build_phase xcodebuild -project Rendu.xcodeproj -scheme Rendu \
	-configuration Release -destination "id=$DEVICE" -derivedDataPath "$DERIVED" \
	-allowProvisioningUpdates build
app="$DERIVED/Build/Products/Release-iphoneos/Rendu.app"
step install "Installing" install_percent xcrun devicectl device install app --device "$DEVICE" "$app"

expires=$(security cms -D -i "$app/embedded.mobileprovision" 2>/dev/null |
	plutil -extract ExpirationDate raw -o - - 2>/dev/null) || true
if seconds=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$expires" +%s 2>/dev/null); then
	echo "Signed until $(date -r "$seconds" '+%Y-%m-%d %H:%M') ($(( (seconds - $(date +%s)) / 86400 )) days left)."
else
	echo "Signed until ${expires:-unknown}."
fi
