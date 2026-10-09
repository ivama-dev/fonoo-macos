#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
MAC_BUILD_DIR="${FONOO_MAC_BUILD_DIR:-/private/tmp/FonooMacNativeBuild}"
AUDIO_REPORT_DIR="${FONOO_AUDIO_REPORT_DIR:-$PWD/build/audio-resilience}"
APP="$MAC_BUILD_DIR/Build/Products/Debug/fonoo.app"
codesign --verify --deep --strict "$APP"
mkdir -p "$AUDIO_REPORT_DIR"
# Let the sandboxed app use its private temporary directory. The runner exports
# only its synthetic measurements; generated audio files are removed by the app.
"$APP/Contents/MacOS/fonoo" --check-audio | tee "$AUDIO_REPORT_DIR/checks.jsonl"
# Below the profile's continuous media budget: measure degradation honestly,
# while still requiring the same call to survive and recover once restored.
"$APP/Contents/MacOS/fonoo" --check-audio --audio-case overloaded-link | tee "$AUDIO_REPORT_DIR/overload.jsonl"
python3 - "$AUDIO_REPORT_DIR" <<'PY'
import json,sys
from pathlib import Path
root=Path(sys.argv[1])
cases=[json.loads(line) for line in (root/'checks.jsonl').read_text().splitlines() if line.startswith('{')]
assert len(cases)==8 and all(case['status']=='pass' for case in cases)
overload=[json.loads(line) for line in (root/'overload.jsonl').read_text().splitlines() if line.startswith('{')]
assert len(overload)==1 and overload[0]['status']=='pass'
(root/'report.json').write_text(json.dumps({'status':'pass','scope':'native-sdk-loopback-generated-audio-srtp',
    'limits':'No microphone, acoustic echo or real provider/mobile path tested. Random loss simulation; observed loss reported separately.',
    'scenarios':cases,'overload_resilience':overload[0]},indent=2)+'\n')
PY
printf '\nAudio report: %s/report.json\n' "$AUDIO_REPORT_DIR"
