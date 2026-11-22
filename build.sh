#!/bin/bash
set -euo pipefail
if [[ -n "${TELUGISH_ACCURACY_MODEL:-}" ]]; then
    TELUGISH_ACCURACY_MODEL=$(cd "$TELUGISH_ACCURACY_MODEL" && pwd)
fi
cd "$(dirname "$0")"

destination=${1:-"$PWD/Telugish Dictation.app"}
if [[ -e "$destination" ]]; then
    echo "Choose a new destination. An app already exists at $destination." >&2
    exit 1
fi
python=${TELUGISH_PYTHON:-python3.12}
python=$("$python" -c 'import sys; assert sys.version_info[:2] == (3, 12), "Python 3.12 is required"; print(sys.executable)')
mkdir -p "$(dirname "$destination")"
stage=$(mktemp -d "$(dirname "$destination")/.telugish-build.XXXXXX")
trap 'rm -rf "$stage"' EXIT
bundle="$stage/Telugish Dictation.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources/model"
resources="$bundle/Contents/Resources"
cp Info.plist "$bundle/Contents/"
cp worker.py "$resources/"
cp MODEL-NOTICE.txt "$resources/model/NOTICE.txt"
swiftc -swift-version 5 -O main.swift CloudDictation.swift Saaras.swift SmartDictation.swift DictationHistory.swift Dashboard.swift Account.swift -o "$bundle/Contents/MacOS/TelugishDictation"

printf '%s\n' "$python" > "$resources/python-path.txt"
uv pip install --python "$python" --target "$resources/packages" -r requirements.txt
revision=f9e7fca1d6983d7d5f62d18170bb7bd8be0c83a5
model_base="https://huggingface.co/Johnwick0007/openflow-telugish/resolve/$revision/models/telugish-whisper-small-int8"
for file in config.json model.bin preprocessor_config.json tokenizer.json vocabulary.json; do
    curl -fsSL --retry 2 "$model_base/$file" -o "$resources/model/$file"
done
cp APACHE-2.0.txt "$resources/model/LICENSE.txt"
if [[ -n "${TELUGISH_ACCURACY_MODEL:-}" ]]; then
    for file in config.json model.bin preprocessor_config.json tokenizer.json vocabulary.json NOTICE.txt LICENSE.txt; do
        test -f "$TELUGISH_ACCURACY_MODEL/$file"
    done
    mv "$resources/model" "$resources/model-fallback"
    mkdir "$resources/model"
    for file in config.json model.bin preprocessor_config.json tokenizer.json vocabulary.json NOTICE.txt LICENSE.txt; do
        cp "$TELUGISH_ACCURACY_MODEL/$file" "$resources/model/"
    done
fi
mkdir -p "$resources/model-english"
translation_base="https://huggingface.co/Systran/faster-whisper-small/resolve/536b0662742c02347bc0e980a01041f333bce120"
for file in config.json model.bin tokenizer.json vocabulary.txt; do
    curl -fsSL --retry 2 "$translation_base/$file" -o "$resources/model-english/$file"
done
cp WHISPER-LICENSE.txt "$resources/model-english/LICENSE.txt"
./sign-app.sh "$bundle"
mv "$bundle" "$destination"
echo "Built $destination"
