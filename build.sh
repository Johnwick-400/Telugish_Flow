#!/bin/bash
set -euo pipefail
destination=${1:-"$PWD/Telugish Flow.app"}
mkdir -p "$(dirname "$destination")"
destination="$(cd "$(dirname "$destination")" && pwd)/$(basename "$destination")"
[[ ! -e "$destination" ]] || { echo "Choose a new destination" >&2; exit 1; }
cd "$(dirname "$0")"
stage=$(mktemp -d "$(dirname "$destination")/.telugish-build.XXXXXX")
trap 'rm -rf "$stage"' EXIT
bundle="$stage/Telugish Flow.app"
resources="$bundle/Contents/Resources"
mkdir -p "$bundle/Contents/MacOS" "$resources/model" "$resources/model-english"
cp Info.plist "$bundle/Contents/"
cp worker.py "$resources/"
swiftc -target "$(uname -m)-apple-macos14.0" -swift-version 5 -O *.swift -o "$bundle/Contents/MacOS/TelugishDictation"

uv python install 3.12.13 --install-dir "$stage/python" --no-bin
# Select the runtime installed in this staging directory, independently of PATH.
for installed in "$stage"/python/cpython-3.12.13-*; do
    test -x "$installed/bin/python3.12"
    cp -R "$installed" "$resources/runtime"
done
uv pip install --only-binary :all: --python "$resources/runtime/bin/python3.12" --target "$resources/packages" -r requirements.txt
model_zip="$stage/model.zip"
if [[ -n "${TELUGISH_MODEL_ZIP:-}" ]]; then
    cp "$TELUGISH_MODEL_ZIP" "$model_zip"
else
    curl -fL --retry 2 "https://github.com/Johnwick-400/Telugish_Flow/releases/download/v0.9.0/OpenFlow-Small-INT8.zip" -o "$model_zip"
fi
echo "08dfec2850653f47971c1152951c7b8e026347d369aba53b11b0b61bbf0bf477  $model_zip" | shasum -a 256 -c -
unzip -q "$model_zip" -d "$resources/model"
cp MODEL-NOTICE.txt "$resources/model/"
translation_base="https://huggingface.co/Systran/faster-whisper-small/resolve/536b0662742c02347bc0e980a01041f333bce120"
for file in config.json model.bin tokenizer.json vocabulary.txt; do
    if [[ -n "${TELUGISH_WHISPER_DIR:-}" ]]; then
        cp "$TELUGISH_WHISPER_DIR/$file" "$resources/model-english/"
    else
        curl -fsSL --retry 2 "$translation_base/$file" -o "$resources/model-english/$file"
    fi
done
cp WHISPER-LICENSE.txt "$resources/model-english/LICENSE.txt"
./sign-app.sh "$bundle"
mv "$bundle" "$destination"
echo "Built $destination"
