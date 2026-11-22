import SwiftUI

enum DashboardPage: String, CaseIterable {
    case dictation = "Dictation", history = "History", dictionary = "Dictionary", account = "Account"

    var icon: String {
        switch self {
        case .dictation: return "waveform"
        case .history: return "clock.arrow.circlepath"
        case .dictionary: return "text.book.closed"
        case .account: return "person.crop.circle"

        }
    }
}


final class DashboardState: ObservableObject {
    @Published var page: DashboardPage = .dictation
    @Published var status = "Starting…"
    @Published var engine = "OpenFlow · Offline"
    @Published var smart = true
    @Published var english = false
    @Published var offline = true
    @Published var noiseReduction = false
    @Published var pasteAllowed = false
    @Published var entries: [HistoryEntry] = []
    @Published var terms: [String] = []
    @Published var retryable: Set<UUID> = []
}

struct DictationDashboard: View {
    @ObservedObject var state: DashboardState
    @ObservedObject var account: AccountState

    let setSmart: (Bool) -> Void
    let setEnglish: (Bool) -> Void
    let setNoiseReduction: (Bool) -> Void
    let changeEngine: () -> Void
    let editDictionary: () -> Void
    let testPaste: () -> Void
    let diagnostics: () -> Void
    let copy: (String) -> Void
    let retry: (HistoryEntry) -> Void
    let undo: (HistoryEntry) -> Void

    private let background = Color(red: 0.055, green: 0.073, blue: 0.105)
    private let rail = Color(red: 0.076, green: 0.098, blue: 0.14)
    private let surface = Color(red: 0.097, green: 0.128, blue: 0.178)
    private let accent = Color(red: 0.41, green: 0.93, blue: 0.81)
    private let ink = Color(red: 0.91, green: 0.95, blue: 0.98)
    private let muted = Color(red: 0.65, green: 0.72, blue: 0.8)

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(state.page.rawValue)
                        .font(.system(size: 34, weight: .semibold))
                        .tracking(-1.5)
                        .accessibilityAddTraits(.isHeader)
                    switch state.page {
                    case .dictation: overview
                    case .history: history
                    case .dictionary: dictionary
                    case .account: AccountView(account: account)
                    }
                }
                .padding(32)
                .frame(maxWidth: 850, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .foregroundStyle(ink)
        .background(background)
        .preferredColorScheme(.dark)
        .tint(accent)
        .frame(minWidth: 720, minHeight: 480)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(background)
                    .frame(width: 28, height: 28)
                    .background(accent, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
                Text("Telugish Flow").font(.system(size: 14, weight: .semibold))
            }
            .padding(.bottom, 24)
            ForEach(DashboardPage.allCases, id: \.self) { candidate in
                Button { state.page = candidate } label: {
                    Label(candidate.rawValue, systemImage: candidate.icon)
                        .font(.system(size: 13, weight: state.page == candidate ? .semibold : .regular))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 11).padding(.vertical, 10)
                        .foregroundStyle(state.page == candidate ? accent : muted)
                        .background(state.page == candidate ? accent.opacity(0.11) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(state.page == candidate ? .isSelected : [])
            }
            Spacer()
            Button(action: diagnostics) {
                Label("Paste diagnostics", systemImage: "stethoscope")
                    .font(.system(size: 12))
                    .foregroundStyle(muted)
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .frame(width: 175)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(rail)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "mic")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(accent)
                        .frame(width: 52, height: 52)
                        .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hold to dictate").font(.title2.weight(.semibold))
                        Text("Focus a text field, speak, then release Space.")
                            .foregroundStyle(muted)
                    }
                    Spacer(minLength: 8)
                }
                HStack(spacing: 6) {
                    keycap("Control")
                    keycap("Shift")
                    keycap("Space")
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Control plus Shift plus Space")
                Text(state.status)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(surface, in: RoundedRectangle(cornerRadius: 14))

            preferenceRow("Output language", detail: state.english ? "Translate Telugu speech into English on this Mac" : "Write Telugu-English speech in Roman letters") {
                Picker("Output language", selection: Binding(get: { state.english }, set: setEnglish)) {
                    Text("Telugish").tag(false)
                    Text("English").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 165)
            }
            preferenceRow("Speech engine", detail: state.engine) {
                Button("Change engine…", action: changeEngine).disabled(state.english)
            }
            if !state.english { preferenceRow("Output", detail: state.smart ? "Clean up fillers and clear corrections" : "Keep the original transcript") {
                Picker("Dictation output", selection: Binding(get: { state.smart }, set: setSmart)) {
                    Text("Raw").tag(false)
                    Text("Smart").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 130)
            }
            }
            preferenceRow("Background noise filter", detail: state.offline ? "Light noise reduction for OpenFlow" : "Available in Offline mode") {
                Toggle("Background noise filter", isOn: Binding(
                    get: { state.noiseReduction }, set: setNoiseReduction
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!state.offline)
            }
            preferenceRow("Auto-paste", detail: state.pasteAllowed ? "Paste access available" : "Paste access required") {
                Button("Test Paste", action: testPaste)
            }
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 14) {
            if state.entries.isEmpty {
                Text("No Saaras recordings yet. Your latest Saaras results will appear here.")
                    .foregroundStyle(muted)
            }
            ForEach(state.entries, id: \.id) { entry in
                VStack(alignment: .leading, spacing: 9) {
                    Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(muted)
                    Text(entry.output ?? entry.failure ?? "No transcript")
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        if let output = entry.output { Button("Copy result") { copy(output) } }
                        if let raw = entry.raw { Button("Copy raw") { copy(raw) } }
                        if entry.output != entry.raw, entry.raw != nil { Button("Undo cleanup") { undo(entry) } }
                        if state.retryable.contains(entry.id) { Button("Retry with Saaras") { retry(entry) } }
                    }
                }
                .padding(15)
                .background(surface, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var dictionary: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Names and terms used as recognition hints.")
                .foregroundStyle(muted)
            Button("Edit personal dictionary…", action: editDictionary)
            if state.terms.isEmpty {
                Text("Add names or work terms you say often.").foregroundStyle(muted)
            } else {
                Text(state.terms.joined(separator: "  ·  "))
                    .font(.body)
                    .lineSpacing(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(surface, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func keycap(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(background, in: RoundedRectangle(cornerRadius: 6))
    }

    private func preferenceRow<T: View>(_ title: String, detail: String,
                                        @ViewBuilder control: () -> T) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.callout).foregroundStyle(muted)
            }
            Spacer()
            control()
        }
        .padding(14)
        .background(surface, in: RoundedRectangle(cornerRadius: 10))
    }
}
