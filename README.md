# Telugish Flow

A macOS menu-bar app for offline Telugu-English dictation. The OpenFlow-Telugish Small INT8 model outputs Telugu in Roman script and recognizes English within the same utterance.

The Small checkpoint uses around 237 MiB for model weights and may take a few seconds to transcribe a short utterance on CPU.

## Use the app

Download **Telugish-Flow-macOS-arm64.zip** from the [GitHub release](https://github.com/Johnwick-400/Telugish_Flow/releases/latest), unzip it and move **Telugish Flow.app** to Applications. This test build targets Apple Silicon and macOS 14 or later. Python and both offline models are included. The build is locally signed and has no Apple notarization. If macOS blocks launch, review the release and use System Settings → Privacy & Security → Open Anyway if you trust it. Open the app and look for the microphone in the menu bar.

1. Choose **Set Up Permissions…** in the microphone menu. Allow Microphone access and enable **Telugish Dictation** under **System Settings → Privacy & Security → Accessibility**. If it is absent from the list, use **+** and select the app. Relaunch if macOS requests it. If permissions stop working after an update, remove and re-add the current app in Accessibility.
2. Wait for **Ready** in the microphone menu and click a text field in the app where you want the transcript.
3. Hold **Control + Shift + Space** while speaking. Release Space to transcribe and paste. The transcript also replaces the current clipboard contents.
4. If you switch apps during dictation or Accessibility access is missing, paste the copied text yourself with **Command + V**.

Offline mode processes audio on your Mac and removes temporary recordings after processing. Recordings have a two-minute limit.

Choose **Dictation → Output language → English** for offline Telugu-to-English translation with Whisper Small. Choose **Telugish** for Romanized output with OpenFlow.

## Telugish Flow window

Choose **Open Telugish Flow…** from the microphone menu. The Dictation page shows the active engine, Raw or Smart output, shortcut, and paste access. The optional **Background noise filter** applies light spectral noise reduction in Offline mode. It is off by default. Use History to copy, retry, or undo cleanup for saved offline dictation. Use Dictionary to view or edit your recognition hints. Closing the window leaves the global shortcut available.

## Account sign-up and sign-in

Open **Account** from the Telugish Flow window to create an account or sign in. The local account backend listens at `127.0.0.1:8766` and uses the dedicated `telugish_flow` MongoDB database. The Mac app receives a session token for the current launch. Accounts are optional for dictation.

Start the development backend with Python 3.12 and supply the MongoDB URI at its hidden prompt:

```sh
python3.12 -m venv .account-env
.account-env/bin/pip install -r account-server/requirements.txt
.account-env/bin/python account-server/server.py
```

You can also pass the URI through `TELUGISH_MONGODB_URI`. Keep it in the backend environment. For remote use, deploy behind HTTPS with a production WSGI server and an appropriate authentication and abuse prevention configuration.

## OpenAI Realtime mode

Choose **Use OpenAI Realtime…** in the microphone menu and enter your own OpenAI API key. The app keeps the key in memory for the current session. Hold the regular shortcut to stream microphone audio to OpenAI and release Space to commit the turn and paste its final transcript. OpenAI usage may incur API charges. Romanized Telugu is requested as a hint and output can vary.

Choose **Switch to Offline** to return to local processing or retry a failed cloud turn. Each launch starts in offline mode.

## Offline Smart Dictation

Choose Raw for the original recognition result or Smart to clean up repetitions, fillers and clear spoken corrections. Use the personal dictionary for recognition hints. History keeps recent offline results locally. Enable **Keep Audio for Retry** to reprocess saved recordings. English output uses the bundled multilingual Whisper Small model.

## Build from source

Install the Xcode command line tools and uv. Set `TELUGISH_SIGNING_IDENTITY` to your Keychain code-signing certificate fingerprint, then run `./build.sh`. The build bundles a relocatable Python runtime, downloads the release checkpoint, verifies its SHA-256 checksum and includes the English translation model.

## License

The application source is MIT licensed. See the included dependency notices and model attribution.
