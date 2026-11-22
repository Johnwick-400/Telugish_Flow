import AppKit
import ApplicationServices
import AVFoundation
import Carbon
import SwiftUI

// App state belongs to the main thread. Worker callbacks dispatch to it.
final class Dictation: NSObject, NSApplicationDelegate, AVAudioRecorderDelegate, @unchecked Sendable {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let status = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private var worker: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var outputBuffer = Data()
    private var ready = false
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var pendingURL: URL?
    private var englishOutput = UserDefaults.standard.bool(forKey: "englishOutput")
    private var pendingOfflineSmart = false
    private var noiseReduction = UserDefaults.standard.object(forKey: "offlineNoiseReduction") as? Bool ?? false
    private let noiseItem = NSMenuItem(title: "Offline Noise Filter", action: nil, keyEquivalent: "")
    private var target: NSRunningApplication?
    private var cloudKey: String?
    private var retryEntry: HistoryEntry?
    private let history = DictationHistory()
    private let dashboardState = DashboardState()
    private let accountState = AccountState()
    private var dashboardWindow: NSWindow?
    private let historyItem = NSMenuItem(title: "Dictation History", action: nil, keyEquivalent: "")
    private var keepHistoryAudio = UserDefaults.standard.object(forKey: "keepHistoryAudio") as? Bool ?? false
    private var testPasteTimer: Timer?
    private var smartEnabled = UserDefaults.standard.object(forKey: "smartDictation") as? Bool ?? true
    private var lastRawTranscript: String?
    private let cleanupMode = NSMenuItem(title: "Dictation Output", action: nil, keyEquivalent: "")
    private let copyRawItem = NSMenuItem(title: "Copy Raw Transcript", action: nil, keyEquivalent: "")
    private var dictionary: [String] {
        UserDefaults.standard.stringArray(forKey: "personalDictionary") ??
            ["Naveen", "Hyderabad", "WhatsApp", "HDFC", "home loan", "EMI",
             "GitHub", "pull request", "backend API logs", "AWS", "Slack"]
    }
    private var cloudTurn: CloudDictation?
    private var cloudID: UUID?
    private var cloudTimeout: Timer?
    private let cloudMode = NSMenuItem(title: "Use OpenAI Realtime…", action: nil, keyEquivalent: "")
    private var shortcutHeld = false
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var recordingTimeout: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        item.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Telugish Dictation")
        let menu = NSMenu()
        let dashboard = menu.addItem(withTitle: "Open Telugish Flow…", action: #selector(showDashboard), keyEquivalent: "")
        dashboard.target = self
        menu.addItem(status)
        menu.addItem(NSMenuItem(title: "Hold ⌃⇧Space to dictate", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        cloudMode.action = #selector(toggleCloud)
        cloudMode.target = self
        menu.addItem(cloudMode)
        let outputMenu = NSMenu()
        for (title, tag) in [("Raw", 0), ("Smart", 1)] {
            let option = outputMenu.addItem(withTitle: title, action: #selector(setCleanupMode(_:)), keyEquivalent: "")
            option.target = self
            option.tag = tag
        }
        cleanupMode.submenu = outputMenu
        menu.addItem(cleanupMode)
        noiseItem.action = #selector(toggleNoiseReduction)
        noiseItem.target = self
        noiseItem.state = noiseReduction ? .on : .off
        menu.addItem(noiseItem)
        updateCleanupMenu()
        let dictionaryItem = menu.addItem(withTitle: "Personal Dictionary…", action: #selector(editDictionary), keyEquivalent: "")
        dictionaryItem.target = self
        copyRawItem.target = self
        menu.addItem(copyRawItem)
        menu.addItem(historyItem)
        refreshHistoryMenu()
        let diagnostics = menu.addItem(withTitle: "Auto-Paste Diagnostics…", action: #selector(pasteDiagnostics), keyEquivalent: "")
        diagnostics.target = self
        let test = menu.addItem(withTitle: "Test Paste", action: #selector(testPaste), keyEquivalent: "")
        test.target = self
        let permissions = menu.addItem(withTitle: "Set Up Permissions…", action: #selector(setUpPermissions), keyEquivalent: "")
        permissions.target = self
        menu.addItem(withTitle: "Quit Telugish Dictation", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu

        guard registerShortcut() else {
            show("Could not register ⌃⇧Space")
            return
        }
        defer {
            if CommandLine.arguments.contains("--show-account") {
                dashboardState.page = .account
                showDashboard()
            } else if CommandLine.arguments.contains("--show-dashboard") { showDashboard() }
        }
        NSLog("Auto-paste permission · Accessibility: %@ · Post Events: %@",
              AXIsProcessTrusted() ? "granted" : "required", CGPreflightPostEventAccess() ? "granted" : "required")
        startWorker()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if dashboardWindow != nil { refreshDashboard() }
    }

    @objc private func showDashboard() {
        refreshDashboard()
        if dashboardWindow == nil {
            let view = DictationDashboard(
                state: dashboardState,
                account: accountState,
                setSmart: { [weak self] in self?.setSmartMode($0) },
                setEnglish: { [weak self] enabled in
                    guard let self, !self.busy else { return }
                    self.englishOutput = enabled
                    UserDefaults.standard.set(enabled, forKey: "englishOutput")
                    self.refreshDashboard()
                },
                setNoiseReduction: { [weak self] in self?.setNoiseReduction($0) },
                changeEngine: { [weak self] in self?.chooseEngine() },
                editDictionary: { [weak self] in self?.editDictionary() },
                testPaste: { [weak self] in self?.testPaste() },
                diagnostics: { [weak self] in self?.pasteDiagnostics() },
                copy: { [weak self] in self?.copyHistoryText($0, status: "Copied transcript") },
                retry: { [weak self] in self?.retry(entry: $0) },
                undo: { [weak self] in self?.undoCleanup(entry: $0) }
            )
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 630),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Telugish Flow"
            window.contentMinSize = NSSize(width: 720, height: 480)
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            window.center()
            dashboardWindow = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        dashboardWindow?.makeKeyAndOrderFront(nil)
    }

    private func refreshDashboard() {
            dashboardState.engine = cloudKey == nil ? "OpenFlow · Offline" : "OpenAI Realtime"
        dashboardState.english = englishOutput
        if englishOutput { dashboardState.engine = "Whisper Small · Offline translation" }
        dashboardState.status = status.title
        dashboardState.smart = smartEnabled
        dashboardState.offline = englishOutput || (cloudKey == nil)
        dashboardState.noiseReduction = noiseReduction
        dashboardState.pasteAllowed = AXIsProcessTrusted() || CGPreflightPostEventAccess()
        dashboardState.entries = history.entries
        dashboardState.terms = dictionary
        dashboardState.retryable = Set(history.entries.filter { history.audio(for: $0.id) != nil }.map(\.id))
    }

    private func chooseEngine() {
        guard !busy else { return }
        let alert = NSAlert()
        alert.messageText = "Speech engine"
        alert.informativeText = "Choose which engine receives your dictation."
        alert.addButton(withTitle: "Keep current")
        alert.addButton(withTitle: "Offline OpenFlow")
        alert.addButton(withTitle: "OpenAI Realtime…")
        switch alert.runModal().rawValue {
        case NSApplication.ModalResponse.alertSecondButtonReturn.rawValue:
            if cloudKey != nil { toggleCloud() }
        case NSApplication.ModalResponse.alertThirdButtonReturn.rawValue:
            if cloudKey == nil { toggleCloud() }
        default: break
        }
    }

    private func refreshHistoryMenu() {
        let menu = NSMenu()
        for entry in history.entries {
            let item = menu.addItem(withTitle: entry.title, action: nil, keyEquivalent: "")
            let actions = NSMenu()
            if entry.output != nil {
                addHistoryAction("Copy Result", action: #selector(copyHistoryOutput(_:)), id: entry.id, to: actions)
            }
            if let raw = entry.raw {
                addHistoryAction("Copy Raw Transcript", action: #selector(copyHistoryRaw(_:)), id: entry.id, to: actions)
                if raw != entry.output {
                    addHistoryAction("Undo Cleanup", action: #selector(undoHistoryCleanup(_:)), id: entry.id, to: actions)
                }
            } else if let failure = entry.failure {
                actions.addItem(withTitle: failure, action: nil, keyEquivalent: "")
            }
            if history.audio(for: entry.id) != nil {
                addHistoryAction("Retry offline", action: #selector(retryHistory(_:)), id: entry.id, to: actions)
            }
            item.submenu = actions
        }
        if history.entries.isEmpty {
            menu.addItem(withTitle: "No dictations yet", action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())
        let audio = menu.addItem(withTitle: "Keep Audio for Retry", action: #selector(toggleHistoryAudio), keyEquivalent: "")
        audio.target = self
        audio.state = keepHistoryAudio ? .on : .off
        let clear = menu.addItem(withTitle: "Clear History…", action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        historyItem.submenu = menu
        if dashboardWindow != nil { refreshDashboard() }
    }

    private func addHistoryAction(_ title: String, action: Selector, id: UUID, to menu: NSMenu) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = id.uuidString
    }

    private func historyEntry(_ item: NSMenuItem) -> HistoryEntry? {
        guard let id = item.representedObject as? String else { return nil }
        return history.entries.first { $0.id.uuidString == id }
    }

    private func copyHistoryText(_ text: String?, status: String) {
        guard let text else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(text, forType: .string) { show(status) }
    }

    @objc private func copyHistoryOutput(_ item: NSMenuItem) {
        copyHistoryText(historyEntry(item)?.output, status: "Copied history result")
    }

    @objc private func copyHistoryRaw(_ item: NSMenuItem) {
        copyHistoryText(historyEntry(item)?.raw, status: "Copied raw history transcript")
    }

    @objc private func undoHistoryCleanup(_ item: NSMenuItem) {
        guard let entry = historyEntry(item) else { return }
        undoCleanup(entry: entry)
    }

    private func undoCleanup(entry original: HistoryEntry) {
        var entry = original
        guard let raw = entry.raw else { return }
        entry.output = raw
        do {
            try history.save(entry)
            refreshHistoryMenu()
            copyHistoryText(raw, status: "Cleanup undone · Raw transcript copied")
        } catch {
            show("Could not update history")
        }
    }

    @objc private func retryHistory(_ item: NSMenuItem) {
        guard let entry = historyEntry(item) else { return }
        retry(entry: entry)
    }

    private func retry(entry: HistoryEntry) {
        guard !busy, ready, let audio = history.audio(for: entry.id) else { return }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        do { try FileManager.default.copyItem(at: audio, to: temp) }
        catch { show("Could not open saved audio"); return }
        retryEntry = entry
        submitRecording(temp)
    }

    @objc private func toggleHistoryAudio() {
        guard !busy else { return }
        if keepHistoryAudio {
            do { try history.removeAudio() }
            catch {
                show("Could not remove all saved audio")
                refreshHistoryMenu()
                return
            }
        }
        keepHistoryAudio.toggle()
        UserDefaults.standard.set(keepHistoryAudio, forKey: "keepHistoryAudio")
        refreshHistoryMenu()
    }

    @objc private func clearHistory() {
        guard !busy else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Clear local dictation history?"
        alert.informativeText = "This deletes saved transcripts and recordings from this Mac."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try history.clear()
            refreshHistoryMenu()
            show("History cleared")
        } catch {
            show("Could not clear history")
        }
    }

    @objc private func pasteDiagnostics() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Auto-Paste Diagnostics"
        let accessibility = AXIsProcessTrusted() ? "granted" : "required"
        let posting = CGPreflightPostEventAccess() ? "granted" : "required"
        let path = Bundle.main.bundlePath
        alert.informativeText = "Accessibility: \(accessibility)\nKeyboard event access: \(posting)\n\nRunning app: \(path)\n\nTest Paste gives you three seconds to focus a text field."
        alert.addButton(withTitle: "Test Paste")
        alert.addButton(withTitle: "Request Paste Access")
        alert.addButton(withTitle: "Close")
        switch alert.runModal() {
        case .alertFirstButtonReturn: testPaste()
        case .alertSecondButtonReturn: requestPasteAccess()
        default: break
        }
    }

    private func requestPasteAccess() {
        if CGRequestPostEventAccess() {
            show("Keyboard event access granted")
        } else {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            show("Enable keyboard event access in System Settings")
        }
    }

    @objc private func testPaste() {
        guard !busy else { return }
        guard AXIsProcessTrusted() || CGPreflightPostEventAccess() else {
            requestPasteAccess()
            return
        }
        testPasteTimer?.invalidate()
        show("Test Paste · Click a text field within 3 seconds")
        testPasteTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            guard let self, !self.busy,
                  let app = NSWorkspace.shared.frontmostApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  app.bundleIdentifier != "com.apple.systempreferences" else {
                self?.show("Test Paste · Focus a text field in another app")
                return
            }
            self.paste("Telugish Flow paste test", to: app)
        }
    }

    @objc private func setCleanupMode(_ item: NSMenuItem) {
        setSmartMode(item.tag == 1)
    }

    private func setSmartMode(_ enabled: Bool) {
        smartEnabled = enabled
        dashboardState.smart = enabled
        UserDefaults.standard.set(smartEnabled, forKey: "smartDictation")
        updateCleanupMenu()
        if ready && !busy && cloudKey == nil {
            show(smartEnabled ? "Ready · Offline Smart" : "Ready · Offline Raw")
        }
    }

    @objc private func toggleNoiseReduction() {
        setNoiseReduction(!noiseReduction)
    }

    private func setNoiseReduction(_ enabled: Bool) {
        noiseReduction = enabled
        UserDefaults.standard.set(enabled, forKey: "offlineNoiseReduction")
        noiseItem.state = enabled ? .on : .off
        dashboardState.noiseReduction = enabled
    }

    private func updateCleanupMenu() {
        cleanupMode.title = smartEnabled ? "Dictation Output · Smart" : "Dictation Output · Raw"
        cleanupMode.submenu?.items.forEach { $0.state = ($0.tag == (smartEnabled ? 1 : 0)) ? .on : .off }
    }

    private func rememberRawTranscript(_ text: String) {
        lastRawTranscript = text
        copyRawItem.action = #selector(copyRawTranscript)
    }

    @objc private func copyRawTranscript() {
        guard let lastRawTranscript else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastRawTranscript, forType: .string)
        show("Copied raw transcript")
    }

    @objc private func editDictionary() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let dialog = NSAlert()
        dialog.messageText = "Personal Dictionary"
        dialog.informativeText = "One name or phrase per line. Up to 50 terms of 64 characters each are used as recognition hints. Offline OpenFlow uses them locally."
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 180))
        scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.string = dictionary.joined(separator: "\n")
        scroll.documentView = text
        dialog.accessoryView = scroll
        dialog.window.initialFirstResponder = text
        dialog.addButton(withTitle: "Save")
        dialog.addButton(withTitle: "Cancel")
        guard dialog.runModal() == .alertFirstButtonReturn else { return }
        var seen = Set<String>()
        let terms = text.string.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        guard terms.count <= 50, terms.allSatisfy({ $0.unicodeScalars.count <= 64 }) else {
            show("Use up to 50 terms of 64 characters each")
            return
        }
        UserDefaults.standard.set(terms, forKey: "personalDictionary")
        show("Saved \(terms.count) dictionary terms")
    }

    private var busy: Bool {
        recorder != nil || pendingURL != nil || cloudTurn != nil
    }

    @objc private func toggleCloud() {
        guard !busy else { return }
        if cloudKey != nil {
            cloudKey = nil
            cloudMode.state = .off
            cloudMode.title = "Use OpenAI Realtime…"
            show(ready ? "Ready · Offline" : "Offline engine unavailable")
            return
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        let dialog = NSAlert()
        dialog.messageText = "Use OpenAI Realtime"
        dialog.informativeText = "Microphone audio will stream to OpenAI while you hold the shortcut. Your API key stays in memory until you switch back to offline mode or quit."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "OpenAI API key"
        dialog.accessoryView = field
        dialog.window.initialFirstResponder = field
        dialog.addButton(withTitle: "Enable")
        dialog.addButton(withTitle: "Cancel")
        guard dialog.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sk-"), key.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            show("Enter a valid OpenAI API key")
            return
        }
        cloudKey = key
        cloudMode.state = .on
        cloudMode.title = "Switch to Offline"
        show("Ready · OpenAI Realtime")
    }

    @objc private func setUpPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                if !granted, let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(settings)
                }
                self.requestPasteAccess()
            }
        }
    }

    private func registerShortcut() -> Bool {
        var events = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                      EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            let app = Unmanaged<Dictation>.fromOpaque(context).takeUnretainedValue()
            if GetEventKind(event) == UInt32(kEventHotKeyPressed) {
                guard !app.shortcutHeld else { return noErr }
                app.shortcutHeld = true
                app.beginRecording()
            } else {
                app.shortcutHeld = false
                app.endRecording()
            }
            return noErr
        }, events.count, &events, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard result == noErr else { return false }
        return RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | shiftKey),
                                   EventHotKeyID(signature: 0x54454C55, id: 1),
                                   GetApplicationEventTarget(), 0, &hotKey) == noErr
    }

    private func startWorker() {
        guard let resources = Bundle.main.resourceURL else {
            show("App resources missing")
            return
        }
        let path = resources.appendingPathComponent("runtime/bin/python3.12").path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            show("Bundled Python runtime missing")
            return
        }
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-I", "-B", "-u", resources.appendingPathComponent("worker.py").path,
                             resources.appendingPathComponent("model").path]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.standardError
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.workerStopped() }
        }
        input = stdinPipe.fileHandleForWriting
        output = stdoutPipe.fileHandleForReading
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            DispatchQueue.main.async { self?.receive(data) }
        }
        do {
            try process.run()
            worker = process
            show("Loading offline model…")
        } catch {
            output?.readabilityHandler = nil
            show("Could not start Python runtime")
            NSLog("Dictation worker launch failed: %@", error.localizedDescription)
        }
    }

    private func receive(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 10) {
            let line = Data(outputBuffer[..<newline])
            outputBuffer.removeSubrange(...newline)
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if message["ready"] as? Bool == true {
                ready = true
                if cloudKey == nil {
                    show(smartEnabled ? "Ready · Offline Smart" : "Ready · Offline Raw")
                    NSLog("Offline dictation output: %@ · Noise filter: %@",
                          smartEnabled ? "Smart" : "Raw", noiseReduction ? "On" : "Off")
                }
                NSLog("Offline Telugish engine ready")
            } else if let url = pendingURL {
                defer { try? FileManager.default.removeItem(at: url); retryEntry = nil }
                pendingURL = nil
                defer { target = nil }
                if let error = message["error"] as? String {
                    NSLog("Dictation failed: %@", error)
                    show("Transcription failed")
                } else if let text = message["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    rememberRawTranscript(text)
                    let result = pendingOfflineSmart ? SmartDictation.clean(text) : text
                    let entry = HistoryEntry(id: retryEntry?.id ?? UUID(), date: retryEntry?.date ?? Date(),
                                             raw: text, output: result, failure: nil)
                    do {
                        try history.save(entry, recording: keepHistoryAudio && retryEntry == nil ? url : nil)
                        refreshHistoryMenu()
                    } catch { NSLog("History save failed") }
                    if retryEntry == nil { paste(result) }
                    else { show("Retry saved to history") }
                } else {
                    show("No speech detected")
                }
            }
        }
    }

    private func beginRecording() {
        guard !busy else { return }
        guard ready || (!englishOutput && (cloudKey != nil)) else { show("Offline engine unavailable"); return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            show("Microphone permission required")
            setUpPermissions()
            return
        }
        if !englishOutput, let cloudKey {
            beginCloudRecording(key: cloudKey)
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("telugish-\(UUID().uuidString).wav")
        do {
            let newRecorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16
            ])
            newRecorder.delegate = self
            guard newRecorder.record() else {
                try? FileManager.default.removeItem(at: url)
                show("Could not record")
                return
            }
            recorder = newRecorder
            recordingURL = url
            target = NSWorkspace.shared.frontmostApplication
            recordingTimeout = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
                self?.endRecording()
            }
            show("Recording…", icon: "mic.fill")
        } catch {
            try? FileManager.default.removeItem(at: url)
            NSLog("Microphone failed: %@", error.localizedDescription)
            show("Could not open microphone")
        }
    }

    private func beginCloudRecording(key: String) {
        let id = UUID()
        do {
            target = NSWorkspace.shared.frontmostApplication
            cloudTurn = try CloudDictation(key: key) { [weak self] transcript in
                DispatchQueue.main.async { self?.completeCloud(id: id, transcript: transcript) }
            }
            cloudID = id
            recordingTimeout = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
                self?.endRecording()
            }
            show("Recording · Streaming to OpenAI", icon: "mic.fill")
        } catch {
            target = nil
            show("Could not start cloud recording")
        }
    }

    private func completeCloud(id: UUID, transcript: String?) {
        guard cloudID == id else { return }
        cloudTurn?.cancel()
        cloudTurn = nil
        cloudID = nil
        recordingTimeout?.invalidate()
        recordingTimeout = nil
        cloudTimeout?.invalidate()
        cloudTimeout = nil
        defer { target = nil }
        guard let transcript else {
            show("OpenAI unavailable · Check key or switch to offline")
            return
        }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { show("No speech detected") }
        else { paste(text) }
    }

    private func endRecording() {
        if let cloudTurn, let id = cloudID {
            guard cloudTimeout == nil else { return }
            recordingTimeout?.invalidate()
            recordingTimeout = nil
            cloudTurn.finish()
            show("Finishing OpenAI transcription…", icon: "waveform")
            cloudTimeout = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
                self?.completeCloud(id: id, transcript: nil)
            }
            return
        }
        guard let recorder, recorder.isRecording else { return }
        recordingTimeout?.invalidate()
        recordingTimeout = nil
        recorder.stop()
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let identity = ObjectIdentifier(recorder)
        DispatchQueue.main.async { [weak self] in self?.finishRecording(identity, successfully: flag) }
    }

    private func finishRecording(_ identity: ObjectIdentifier, successfully flag: Bool) {
        guard let recorder, ObjectIdentifier(recorder) == identity, let url = recordingURL else { return }
        self.recorder = nil
        recordingURL = nil
        recordingTimeout?.invalidate()
        recordingTimeout = nil
        guard flag, ready, input != nil else {
            try? FileManager.default.removeItem(at: url)
            target = nil
            show("Recording unavailable")
            return
        }
        submitRecording(url)
    }

    private func submitRecording(_ url: URL) {
        guard let input else { try? FileManager.default.removeItem(at: url); retryEntry = nil; return }
        do {
            var request = try JSONSerialization.data(withJSONObject: ["path": url.path, "keyterms": dictionary, "noise_reduction": noiseReduction, "output_language": englishOutput ? "english" : "telugish"])
            request.append(10)
            pendingOfflineSmart = !englishOutput && smartEnabled
            pendingURL = url
            try input.write(contentsOf: request)
            show("Transcribing…", icon: "waveform")
        } catch {
            workerStopped()
        }
    }


    private func paste(_ text: String) {
        paste(text, to: target)
    }

    private func paste(_ text: String, to target: NSRunningApplication?) {
        let clipboard = NSPasteboard.general
        clipboard.clearContents()
        guard clipboard.setString(text, forType: .string) else {
            show("Could not copy transcript")
            return
        }
        guard let target else {
            show("Copied · No active app")
            return
        }
        pasteWhenModifiersReleased(in: target.processIdentifier,
                                   clipboardVersion: clipboard.changeCount,
                                   remainingChecks: 25)
    }

    private func pasteWhenModifiersReleased(in pid: pid_t, clipboardVersion: Int, remainingChecks: Int) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            NSLog("Auto-paste skipped: active app changed")
            show("Copied · Active app changed")
            return
        }
        guard NSPasteboard.general.changeCount == clipboardVersion else { return }
        let modifiers: CGEventFlags = [.maskControl, .maskShift, .maskAlternate, .maskCommand]
        if !CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty {
            guard remainingChecks > 0 else {
                show("Copied · Release shortcut modifiers before paste")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                self?.pasteWhenModifiersReleased(in: pid, clipboardVersion: clipboardVersion,
                                                  remainingChecks: remainingChecks - 1)
            }
            return
        }
        if AXIsProcessTrusted() {
            let application = AXUIElementCreateApplication(pid)
            func attribute(_ element: AXUIElement, _ key: CFString) -> CFTypeRef? {
                var value: CFTypeRef?
                AXUIElementCopyAttributeValue(element, key, &value)
                return value
            }
            func children(_ element: AXUIElement) -> [AXUIElement] {
                attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
            }
            if let bar = attribute(application, kAXMenuBarAttribute as CFString),
               CFGetTypeID(bar) == AXUIElementGetTypeID(),
               let edit = children(bar as! AXUIElement).first(where: { attribute($0, kAXTitleAttribute as CFString) as? String == "Edit" }),
               let menu = children(edit).first,
               let paste = children(menu).first(where: { attribute($0, kAXTitleAttribute as CFString) as? String == "Paste" }),
               attribute(paste, kAXEnabledAttribute as CFString) as? Bool == true {
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      NSPasteboard.general.changeCount == clipboardVersion else {
                    show("Copied · Paste target or clipboard changed")
                    return
                }
                let result = AXUIElementPerformAction(paste, kAXPressAction as CFString)
                if result == .success {
                    show("Paste sent via Edit menu")
                    return
                }
                if result == .cannotComplete {
                    show("Paste unconfirmed · Check the text field")
                    return
                }
            }
        }
        guard CGPreflightPostEventAccess() else {
            show("Copied · Paste manually or check Auto-Paste Diagnostics")
            return
        }
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            show("Copied · Paste manually")
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        show("Paste sent")
    }

    private func workerStopped() {
        ready = false
        retryEntry = nil
        if let pendingURL { try? FileManager.default.removeItem(at: pendingURL) }
        pendingURL = nil
        if recorder != nil { endRecording() }
        if cloudKey == nil { show("Offline engine stopped · Relaunch app") }
    }

    private func show(_ title: String, icon: String = "mic") {
        status.title = title
        if dashboardWindow != nil { refreshDashboard() }
        item.button?.toolTip = "Telugish Dictation — \(title)"
        item.button?.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        recordingTimeout?.invalidate()
        cloudTurn?.cancel()
        cloudTimeout?.invalidate()
        let activeRecorder = recorder
        recorder = nil
        activeRecorder?.stop()
        output?.readabilityHandler = nil
        if let worker, worker.isRunning { worker.terminate() }
        for url in [recordingURL, pendingURL].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

let app = NSApplication.shared
let delegate = Dictation()
app.delegate = delegate
app.run()
