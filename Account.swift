import SwiftUI

final class AccountState: ObservableObject {
    @Published var email = ""
    @Published var password = ""
    @Published var creating = false
    @Published var busy = false
    @Published var message = ""
    @Published private(set) var signedInEmail: String?
    private var token: String?

    private let service = URL(string: "http://127.0.0.1:8766")!

    @MainActor
    func submit() async {
        guard !busy, signedInEmail == nil else { return }
        busy = true
        message = ""
        defer { busy = false }
        let endpoint = creating ? "signup" : "signin"
        var request = URLRequest(url: service.appendingPathComponent(endpoint), timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let fields = ["email": email, "password": password]
        password = ""
        do {
            request.httpBody = try JSONEncoder().encode(fields)
            let (data, response) = try await URLSession.shared.data(for: request)
            struct Result: Decodable {
                let email: String?
                let token: String?
                let error: String?
            }
            let result = try JSONDecoder().decode(Result.self, from: data)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let email = result.email, let token = result.token else {
                message = result.error ?? "The account service rejected the request."
                return
            }
            self.token = token
            signedInEmail = email
        } catch {
            message = "Could not reach the account service. Check that it is running."
        }
    }

    @MainActor
    func signOut() async {
        guard !busy, let token else { return }
        busy = true
        defer { busy = false }
        var request = URLRequest(url: service.appendingPathComponent("signout"), timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                message = "Could not confirm sign-out. Try again."
                return
            }
            self.token = nil
            signedInEmail = nil
            message = ""
        } catch {
            message = "Could not confirm sign-out. Check the service and try again."
        }
    }
}

struct AccountView: View {
    @ObservedObject var account: AccountState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let email = account.signedInEmail {
                Text("Signed in").font(.title2.weight(.semibold))
                Text(email).textSelection(.enabled)
                Button("Sign out") { Task { await account.signOut() } }
                    .disabled(account.busy)
            } else {
                Picker("Account action", selection: $account.creating) {
                    Text("Sign in").tag(false)
                    Text("Sign up").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                .onChange(of: account.creating) { _, _ in
                    account.password = ""
                    account.message = ""
                }

                TextField("Email address", text: $account.email)
                    .textContentType(.emailAddress)
                    .accessibilityLabel("Email address")
                SecureField("Password", text: $account.password)
                    .textContentType(account.creating ? .newPassword : .password)
                    .accessibilityLabel("Password")
                    .onSubmit { Task { await account.submit() } }
                if account.creating {
                    Text("Use at least 12 characters.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(account.creating ? "Create account" : "Sign in") {
                        Task { await account.submit() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(account.busy || account.email.isEmpty || account.password.isEmpty)
                    if account.busy { ProgressView().controlSize(.small) }
                }
                Text("You can dictate offline without signing in.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !account.message.isEmpty {
                Label(account.message, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(Color(red: 1, green: 0.74, blue: 0.56))
            }
        }
        .frame(maxWidth: 380, alignment: .leading)
    }
}
