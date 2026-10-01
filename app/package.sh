#!/usr/bin/env bash
# Build the self-contained Sayso.app: the panel, the bridge, the engine and a
# Python runtime, for Apple Silicon Macs. On first launch the app installs
# the engine into ~/Library/Application Support/Sayso and keeps every user's
# state (login, settings, logs) there.
#
#   PYTHON_RUNTIME=/path/to/python ./package.sh    -> app/build/dist/Sayso.app
#
# Its own folder: app/build/Sayso.app is always the development build, which
# runs this checkout's engine with this Mac's login, mic set-up and voice.
#
# PYTHON_RUNTIME is an unpacked python-build-standalone "install_only" build
# of CPython 3.13 for aarch64-apple-darwin (the folder named `python`): it is
# relocatable, unlike a venv or a Homebrew Python.
#
# Then sign and notarise it with sign.sh (Developer ID). Until then it is
# ad-hoc signed and runs on this Mac only.
set -euo pipefail
: "${PYTHON_RUNTIME:?set PYTHON_RUNTIME to an unpacked python-build-standalone build (its python/ folder)}"
# Resolved before changing directory, so a relative path works from anywhere.
PYTHON_RUNTIME="$(cd "$PYTHON_RUNTIME" && pwd)"
cd "$(dirname "$0")"
[ "$(uname -m)" = "arm64" ] || { echo "Apple Silicon only (the speech model runs on MLX)"; exit 1; }

APP=build/dist/Sayso.app
DIST=1 APP="$APP" ./build.sh
ENGINE=build/engine
rm -rf "$ENGINE"
mkdir -p "$ENGINE/bridge"

echo "runtime"
ditto "$PYTHON_RUNTIME" "$ENGINE/python"
PY="$ENGINE/python/bin/python3"
"$PY" -c 'import sys; assert sys.version_info[:2] == (3, 13), sys.version' \
  || { echo "PYTHON_RUNTIME must be CPython 3.13, as the engine is tested with"; exit 1; }

echo "dependencies"
"$PY" -m pip install --quiet --disable-pip-version-check --no-cache-dir -r requirements-dist.txt
"$PY" -m pip install --quiet --disable-pip-version-check --no-cache-dir --no-deps mlx-whisper==0.4.3
# Console scripts carry this build Mac's path in their #! line, and the
# engine never runs them (it uses python -m): only the interpreter stays.
for f in "$ENGINE"/python/bin/*; do
  case "$(basename "$f")" in python*) ;; *) rm -f "$f" ;; esac
done
# Shoonya's connector is downloaded on each Mac, never shipped (licence).
cp sdk-requirements.txt "$ENGINE/"
if "$PY" -c 'import NorenRestApiPy' 2>/dev/null; then
  echo "Shoonya's connector must not be bundled (its licence forbids copying)"; exit 1
fi

echo "engine and bridge"
# The code only: no tests, no venv, no state (sessions, config, symbol masters).
rsync -a --exclude '__pycache__' ../sayso/shoonya ../sayso/voice "$ENGINE/sayso/"
cp ../sayso/LICENSE ../sayso/README.md ../sayso/requirements.txt "$ENGINE/sayso/"
cp ../bridge/bridge.py "$ENGINE/bridge/"
"$PY" -m compileall -q "$ENGINE/sayso" "$ENGINE/bridge" "$ENGINE/python/lib"

echo "check"
# The packaged engine must import and load its pieces with no microphone:
# the same import-contract the bridge tests check. The connector is fetched
# into a throwaway folder for the check only, exactly as a Mac will fetch it.
SDK_CHECK="$(mktemp -d)"
"$PY" -m pip install --quiet --disable-pip-version-check --no-cache-dir --no-deps \
  --require-hashes --target "$SDK_CHECK" -r sdk-requirements.txt
PYTHONPATH="$SDK_CHECK" SAYSO_HOME="$(mktemp -d)" "$PY" - <<'PY'
import sys
sys.path.insert(0, "build/engine/sayso")
from voice import agent, listen, safety, speak, watch, calibrate   # noqa
import shoonya.broker, shoonya.client, shoonya.network, shoonya.underlyings  # noqa
import mlx_whisper, sounddevice, numpy   # noqa
import numpy as np
text = listen.transcribe(np.zeros(listen.SAMPLE_RATE, dtype=np.float32))
assert "torch" not in sys.modules, "torch was pulled in"
print(f"engine imports and speech model: ok ({listen._model[1]})")
PY

# Stamp last: an install compares this, and a copy without it is refused.
dirty=$([ -n "$(git -C .. status --porcelain)" ] && echo -dirty || true)
echo "$(git -C .. rev-parse --short HEAD)${dirty}-$(date +%Y%m%d%H%M%S)" > "$ENGINE/VERSION"
# ditto keeps timestamps, so the compiled .pyc files stay valid.
ditto "$ENGINE" "$APP/Contents/Resources/engine"
codesign --force --sign - "$APP" >/dev/null
echo "packaged $APP ($(du -sh "$APP" | cut -f1), engine $(cat "$ENGINE/VERSION"))"
