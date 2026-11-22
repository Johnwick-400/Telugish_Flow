# Telugish Flow setup

Telugish Flow is a macOS menu-bar app for Telugu-English dictation. The supported release target is Apple Silicon running macOS 14 or later. Offline dictation works without an account or API key.

## Run the release

1. Download `Telugish-Flow-macOS-arm64.zip` from the [release page](https://github.com/Johnwick-400/Telugish_Flow/releases/latest). The archive includes the app, Python runtime, OpenFlow Small INT8 for Romanized Telugish, and multilingual Whisper Small for English translation. The separate model ZIP is for source builds.
2. Unzip the app, move **Telugish Flow.app** to Applications, and open it. The test release is locally signed. If Gatekeeper blocks it, review the release and use **System Settings → Privacy & Security → Open Anyway** if you trust the build.
3. Open the microphone menu and select **Set Up Permissions…**. Grant Microphone and Accessibility access. The bundle may appear as **Telugish Dictation**. Use the **+** button in Accessibility to select the installed app if necessary.
4. Wait for **Ready · Offline**, focus an editable field in Notes, then hold **Control + Shift + Space**. Speak and release Space. The app copies the result and attempts to paste into the focused field.
5. Open **Open Telugish Flow…** for the dashboard. Use **Telugish** for Romanized output or **English** for translation. **Raw** preserves recognition output. **Smart** applies local cleanup. The personal dictionary supplies hints for names and technical terms.

## Build from a clean checkout

Install the Xcode Command Line Tools with `xcode-select --install` if needed. Install `uv` (for example, `brew install uv` on a Mac with Homebrew). Run these commands from Terminal:

```sh
git clone https://github.com/Johnwick-400/Telugish_Flow.git
cd Telugish_Flow
swiftc --version
uv --version
security find-identity -v -p codesigning
```

Choose a valid code-signing identity with its private key in your login Keychain. If the list is empty, import your signing identity or create a local self-signed **Code Signing** certificate in Keychain Access using Certificate Assistant. Use the same identity for subsequent builds so macOS can recognize the updated app.

```sh
# Replace the placeholder with the fingerprint listed by security.
export TELUGISH_SIGNING_IDENTITY='YOUR_CERTIFICATE_FINGERPRINT'
./build.sh "$PWD/Telugish Flow.app"
codesign --verify --strict "$PWD/Telugish Flow.app"
open "$PWD/Telugish Flow.app"
```

The destination must be a new path. For another build, pass a fresh destination such as `"$PWD/build-next/Telugish Flow.app"`. Quit other running copies before testing. For regular use, launch from a consistent installation path.

The build compiles the root Swift sources, installs Python **3.12.13** and pinned wheels, downloads the v0.9.0 OpenFlow checkpoint, checks its SHA-256, and bundles a revision-pinned English model. Initial setup needs network access for uncached dependencies. To reuse model downloads, set either variable before running the build:

| Variable | Local input |
| --- | --- |
| `TELUGISH_MODEL_ZIP` | Absolute path to the release's `OpenFlow-Small-INT8.zip`. The build checks the same release checksum. |
| `TELUGISH_WHISPER_DIR` | Directory containing the pinned English model's `config.json`, `model.bin`, `tokenizer.json`, and `vocabulary.txt`. See `build.sh` for the exact revision. |

## Verify dictation and paste independently

- **Paste** — Select **Test Paste** from the microphone menu, then click inside a new Notes note within three seconds. Verify that text appears. **Auto-Paste Diagnostics…** shows the running app path and permission states. If a rebuild loses access, check that path, remove the stale Accessibility entry, add the currently installed app, and relaunch.
- **Recognition** — In Offline Raw mode, dictate “GitHub open chesi API test cheyyi.” Inspect the actual transcript. Switch to Smart and try “Meeting nine ki pettu, kaadu ten ki pettu.” Check whether the final time survives cleanup. Recognition errors can prevent a correction from matching.
- **Worker only** — From the checkout, set the bundle path below and replace the example WAV path with an existing recording. Expect a ready message followed by a JSON transcript or error. This exercises local recognition independently of microphone and paste permissions.

```sh
resources="$PWD/Telugish Flow.app/Contents/Resources"
printf '%s\n' '{"path":"/absolute/path/to/clip.wav","output_language":"telugish"}' |
  "$resources/runtime/bin/python3.12" -I -B -u "$resources/worker.py" "$resources/model"
```

## Optional services and storage

**OpenAI Realtime.** Choose **Use OpenAI Realtime…** and enter your own key for that session. This mode streams microphone audio to OpenAI and may incur usage charges. Select **Switch to Offline** to resume local processing.

**Accounts.** For local sign-up and sign-in, start the backend from the repository root with a reachable MongoDB instance. The server asks for the URI at a hidden prompt or reads `TELUGISH_MONGODB_URI` from its environment. Keep credentials out of Git and the app bundle.

```sh
uv venv --python 3.12 .account-env
uv pip install --python .account-env/bin/python -r account-server/requirements.txt
.account-env/bin/python account-server/server.py
```

In another terminal, run `curl -fsS http://127.0.0.1:8766/health`. Open **Account** in the app to test sign-up or sign-in. The backend uses the `telugish_flow` database.

**History.** Offline results are stored locally. Enable **Keep Audio for Retry** if you want recordings retained for reprocessing. The background noise filter is also optional.

## Where to make changes

| Area | Files |
| --- | --- |
| Shortcut, recording, worker lifecycle, paste, and permissions | `main.swift`, `Info.plist` |
| Local inference, hints, repetition guard, and noise filtering | `worker.py`, `requirements.txt` |
| Transcript cleanup and history | `SmartDictation.swift`, `DictationHistory.swift` |
| Dashboard, accounts, and cloud dictation | `Dashboard.swift`, `Account.swift`, `account-server/`, `CloudDictation.swift` |
| Packaging, model pins, and persistent signing | `build.sh`, `sign-app.sh` |

The [jury presentation](docs/Telugish-Flow-Track-2.pptx) and [recorded demo](Telugish%20Flow%20-%20recorded%20voice%20demo.mp4) are included in this checkout.
