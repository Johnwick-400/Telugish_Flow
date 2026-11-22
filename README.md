# Telugish Flow

A macOS menu-bar app for offline Telugu-English dictation. The OpenFlow-Telugish Small INT8 model outputs Telugu in Roman script and recognizes English within the same utterance.

The Small checkpoint uses around 237 MiB for model weights and may take a few seconds to transcribe a short utterance on CPU.

## Use the app

Build the app on your Apple Silicon Mac using the build instructions below. Open Telugish Dictation.app and look for the microphone in the menu bar.

1. Choose **Set Up Permissions…** in the microphone menu. Allow Microphone access and enable **Telugish Dictation** under **System Settings → Privacy & Security → Accessibility**. If it is absent from the list, use **+** and select the app. Relaunch if macOS requests it. If permissions stop working after an update, remove and re-add the current app in Accessibility.
2. Wait for **Ready** in the microphone menu and click a text field in the app where you want the transcript.
3. Hold **Control + Shift + Space** while speaking. Release Space to transcribe and paste. The transcript also replaces the current clipboard contents.
4. If you switch apps during dictation or Accessibility access is missing, paste the copied text yourself with **Command + V**.

Offline mode processes audio on your Mac and removes temporary recordings after processing. Recordings have a two-minute limit.

Choose **Dictation → Output language → English** for offline Telugu-to-English translation with Whisper Small. Choose **Telugish** for Romanized output with OpenFlow.

## Telugish Flow window

Choose **Open Telugish Flow…** from the microphone menu. The Dictation page shows the active engine, Raw or Smart output, shortcut, and paste access. The optional **Background noise filter** applies light spectral noise reduction in Offline mode. It is off by default. Use History to copy, retry, or undo cleanup for saved Saaras dictation. Use Dictionary to view or edit your recognition hints. Closing the window leaves the global shortcut available.

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

## Sarvam and OpenAI comparison

In the microphone menu, choose **Use Sarvam / Compare…** and enter the Sarvam and OpenAI API keys. Hold **Control + Shift + Space** for each phrase. Release **Space** and wait for the results before recording the next phrase. The comparison window keeps both transcripts for every recording. Use **Show Comparison Results** to reopen it. Select and copy any result you want to paste.

Each recording is sent to both providers. Sarvam uses Saaras v4 in Romanized mode. OpenAI Realtime receives 24 kHz PCM converted from the same WAV. Comparison requests start after release and are intended to compare transcript quality. Sarvam accepts up to 30 seconds per request.

Leave the OpenAI field empty for Sarvam-only dictation with automatic paste. Keys and comparison results stay in memory until the app quits. Changing modes clears the previous mode’s keys. Starting a new comparison clears the previous results.

## Smart Dictation with Saaras or OpenFlow

Use the offline OpenFlow engine or enable Sarvam alone from **Use Sarvam / Compare…**. **Dictation Output** switches between **Raw** and **Smart** for either engine. Smart applies local cleanup to clear leading fillers, immediate phrase repeats, explicit time corrections, and selected number formats. **Copy Raw Transcript** copies the latest unedited OpenFlow or Saaras transcript. The comparison window continues to show both providers’ original outputs.

**Personal Dictionary…** edits recognition hints for Saaras and offline OpenFlow. Offline hints stay on the Mac. The supplied default list contains the names and technical terms from the six-phrase test. You can edit or clear it. The dictionary and output mode are stored locally.

## Paste diagnostics and local history

Open **Auto-Paste Diagnostics…** to see the current build’s macOS permissions. **Test Paste** gives you three seconds to focus a text field and then attempts to paste a sample phrase. If keyboard event access is missing, use **Request Paste Access** and confirm the permission in System Settings.

**Dictation History** keeps the latest 12 Saaras results on this Mac, including failed requests. **Retry with Saaras** resends the saved recording to Saaras and copies the new result. **Undo Cleanup** replaces the history result with the raw transcript and copies it for manual replacement. **Keep Audio for Retry** is enabled by default and can be turned off to remove saved audio while keeping text. **Clear History…** deletes both saved text and audio.

## Offline accuracy model

The supplied accuracy build uses the conversationally retrained OpenFlow Small INT8 model. It bounds decoding and falls back to the original OpenFlow Small checkpoint when the candidate is empty or shows signs of repetition. Offline audio retains all samples and has 100 ms of leading padding. The offline worker limits repeated sequences and caps generated tokens by recording length.

## Build from source

On an Apple Silicon Mac with the Xcode Command Line Tools, Python 3.12 and uv installed, run:

```sh
./build.sh
```

The build downloads the pinned baseline model and Python dependencies, then creates a signed app beside the script. Local updates use the same private signing identity in `~/Library/Application Support/Telugish Flow Signing`. Keep this directory private and back it up securely. Moving from an ad-hoc build to this identity needs one Accessibility approval. On a different build machine, set `TELUGISH_SIGNING_IDENTITY` to the fingerprint of your Keychain signing certificate and keep using it for subsequent builds. The build stops if the configured signing identity is unavailable. To reproduce the accuracy build, set `TELUGISH_ACCURACY_MODEL` to the extracted OpenFlow Conversational Telugish INT8 model directory before running the build. Set `TELUGISH_PYTHON` to the absolute path of a Python 3.12 executable if needed. The app bundles the Python packages and uses that Python installation to run them. Build on each Mac where the original Python path is unavailable.

`main.swift` implements the menu bar, global shortcut, microphone and paste. `worker.py` keeps the model loaded and communicates with the app over standard input and output.

## License

The app source is MIT licensed. The bundled checkpoint is published as Apache-2.0. See MODEL-NOTICE.txt for attribution and the pinned model revision.
