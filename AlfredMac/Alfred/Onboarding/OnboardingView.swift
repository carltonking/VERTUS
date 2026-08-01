import SwiftUI
import AppKit

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState

    @State private var currentStep: Int
    @State private var apiKeyInput: String = ""
    @State private var connectionState: ConnectionState = .idle
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @Environment(\.dismiss) private var dismiss

    init(initialStep: Int = 0) {
        _currentStep = State(initialValue: initialStep)
    }

    // MARK: Owner Configuration (OCS) intake — step 5, present only when the feature is enabled.
    //
    // With `ownerConfigEnabled` off, `totalSteps` stays 5 and every existing step keeps its index,
    // so the current onboarding is byte-identical. With it on, one extra step collects the minimum
    // the assistant needs to speak for someone: name, pronouns, sign-off, zone, and how cautious to
    // be. Registers, folders, Adobe/Rhino, classifications, and cloud sync are deliberately NOT here.
    @State private var ownerPreferredName = ""
    @State private var ownerPronounSubject = OwnerConfig.Identity.Pronouns.neutral.subject
    @State private var ownerPronounObject = OwnerConfig.Identity.Pronouns.neutral.object
    @State private var ownerPronounPossessive = OwnerConfig.Identity.Pronouns.neutral.possessive
    @State private var ownerSignOffName = ""
    @State private var ownerRoleTitle = ""
    @State private var ownerOrganization = ""
    @State private var ownerTimeZone = OwnerConfigDefaults.provisionalTimeZone
    @State private var ownerUses24HourTime = true
    @State private var ownerApprovalPreset: OwnerConfigDefaults.ApprovalPreset = .balanced
    @State private var ownerSaveError: String?

    private var ownerConfigStepIndex: Int { 5 }
    private var totalSteps: Int { appState.ownerConfigEnabled ? 6 : 5 }
    private let bg = Color(red: 0.11, green: 0.11, blue: 0.12)

    enum ConnectionState {
        case idle, testing, success, failure(String)
    }

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()

            VStack(spacing: 0) {
                progressBar
                    .padding(.horizontal, 32)
                    .padding(.top, 28)

                Spacer(minLength: 0)

                stepContent
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 40)

                Spacer(minLength: 0)

                navigationButtons
                    .padding(.horizontal, 40)
                    .padding(.bottom, 32)
            }
        }
        .frame(width: 560, height: 480)
        .preferredColorScheme(.dark)
    }

    // MARK: - Progress bar

    private var progressBar: some View {
        HStack(spacing: 6) {
            ForEach(0..<totalSteps, id: \.self) { i in
                Capsule()
                    .fill(i <= currentStep ? Color.white : Color.white.opacity(0.18))
                    .frame(height: 3)
                    .animation(.easeInOut(duration: 0.25), value: currentStep)
            }
        }
    }

    // MARK: - Step routing

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case 0: stepWelcome
        case 1: stepName
        case 2: stepChooseAI
        case 3: stepAPIKey
        case 4: stepPermissions
        case 5 where appState.ownerConfigEnabled: stepOwnerProfile
        default: EmptyView()
        }
    }

    // MARK: - Step 5: Owner profile (Owner Configuration only)

    private var stepOwnerProfile: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader(title: "A little about you")
            Text("Alfred writes and schedules on your behalf, so it needs these before it can draft anything. Everything else can wait until Settings.")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ownerField("What should Alfred call you?", text: $ownerPreferredName,
                               placeholder: "preferred name")
                    ownerField("Name to sign outgoing messages with", text: $ownerSignOffName,
                               placeholder: "sign-off name")

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your pronouns").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                        HStack(spacing: 8) {
                            TextField("they", text: $ownerPronounSubject).textFieldStyle(.roundedBorder)
                            TextField("them", text: $ownerPronounObject).textFieldStyle(.roundedBorder)
                            TextField("their", text: $ownerPronounPossessive).textFieldStyle(.roundedBorder)
                        }
                        Text("Used whenever Alfred refers to you. Defaults to they/them until you change it.")
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                    }

                    ownerField("Role or title (optional)", text: $ownerRoleTitle, placeholder: "role")
                    ownerField("Organization (optional)", text: $ownerOrganization, placeholder: "organization")

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Time zone").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                        Picker("", selection: $ownerTimeZone) {
                            ForEach(Self.commonTimeZones, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().pickerStyle(.menu)
                        Text("Every time Alfred writes — calendar entries included — uses this. Confirm it even if it already looks right.")
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Toggle("Use 24-hour times (14:30)", isOn: $ownerUses24HourTime)
                        .font(.system(size: 12)).toggleStyle(.switch)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("How cautious should Alfred be?")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                        Picker("", selection: $ownerApprovalPreset) {
                            ForEach(OwnerConfigDefaults.ApprovalPreset.allCases, id: \.self) {
                                Text($0.label).tag($0)
                            }
                        }
                        .labelsHidden().pickerStyle(.menu)
                        Text(ownerApprovalPreset.detail)
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Sending, deleting, computer control, and shell commands always ask — you can loosen the rest later, never below that floor.")
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let ownerSaveError {
                        Text(ownerSaveError).font(.system(size: 11)).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(maxHeight: 320)
        }
        .frame(maxWidth: 460, alignment: .leading)
        .onAppear(perform: seedOwnerFieldsFromExistingConfig)
    }

    private func ownerField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }

    /// A short, sane list plus the machine's own zone. Not exhaustive — Settings can offer the full
    /// IANA database later; onboarding only needs to get the common case right.
    private static var commonTimeZones: [String] {
        var zones = ["America/New_York", "America/Chicago", "America/Denver", "America/Los_Angeles",
                     "Europe/London", "Europe/Berlin", "Europe/Paris", "Asia/Tokyo",
                     "Australia/Sydney", "UTC"]
        let current = TimeZone.current.identifier
        if !zones.contains(current) { zones.insert(current, at: 0) }
        return zones
    }

    /// Pre-fill from an existing configuration (or the legacy name) so re-running onboarding doesn't
    /// present empty fields over values the owner already set.
    private func seedOwnerFieldsFromExistingConfig() {
        guard appState.ownerConfigEnabled else { return }
        if let snapshot = OwnerConfigStore.shared.currentSnapshot() {
            let id = snapshot.config.identity
            if ownerPreferredName.isEmpty { ownerPreferredName = id.preferredName ?? id.fullName ?? "" }
            if ownerSignOffName.isEmpty { ownerSignOffName = id.signOffName ?? "" }
            if ownerRoleTitle.isEmpty { ownerRoleTitle = id.roleTitle ?? "" }
            if ownerOrganization.isEmpty { ownerOrganization = id.organization ?? "" }
            ownerPronounSubject = id.pronouns.subject
            ownerPronounObject = id.pronouns.object
            ownerPronounPossessive = id.pronouns.possessive
            ownerTimeZone = id.timeZone
            ownerUses24HourTime = id.timeFormat == .h24
        } else if ownerPreferredName.isEmpty {
            ownerPreferredName = appState.ownerName
        }
        if ownerSignOffName.isEmpty { ownerSignOffName = ownerPreferredName }
    }

    /// Write the intake into the canonical configuration. Returns false (and surfaces the reason)
    /// when validation rejects it, so onboarding cannot complete with an unusable owner profile.
    private func saveOwnerConfig() -> Bool {
        guard appState.ownerConfigEnabled else { return true }
        let store = OwnerConfigStore.shared
        var config = store.currentSnapshot()?.config ?? OwnerConfigDefaults.blank

        let preferred = ownerPreferredName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullName = appState.ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        config.identity.fullName = fullName.isEmpty ? preferred : fullName
        config.identity.preferredName = preferred
        config.identity.signOffName = ownerSignOffName.trimmingCharacters(in: .whitespacesAndNewlines)
        config.identity.pronouns = .init(
            subject: ownerPronounSubject.trimmingCharacters(in: .whitespacesAndNewlines),
            object: ownerPronounObject.trimmingCharacters(in: .whitespacesAndNewlines),
            possessive: ownerPronounPossessive.trimmingCharacters(in: .whitespacesAndNewlines))
        config.identity.roleTitle = ownerRoleTitle.isEmptyAfterTrim ? nil : ownerRoleTitle
        config.identity.organization = ownerOrganization.isEmptyAfterTrim ? nil : ownerOrganization
        config.identity.timeZone = ownerTimeZone
        config.identity.timeZoneConfirmed = true          // the owner just chose it
        config.identity.timeFormat = ownerUses24HourTime ? .h24 : .h12
        config.approvals.policies = ownerApprovalPreset.policies

        do {
            try store.save(config, updatedBy: .onboarding)
            ownerSaveError = nil
            return true
        } catch {
            ownerSaveError = error.localizedDescription
            return false
        }
    }

    // MARK: - Step 0: Welcome

    private var stepWelcome: some View {
        VStack(spacing: 24) {
            AlfredWelcomeLogo()
                .frame(width: 380, height: 136)

            VStack(spacing: 10) {
                Text("Meet Alfred")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.white)

                Text("Your personal AI assistant for Mac.\nControls your computer, searches the web,\nand remembers what matters.")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
        }
    }

    // MARK: - Step 1: Name

    private var stepName: some View {
        VStack(spacing: 28) {
            stepHeader(title: "What should Alfred call you?")

            TextField("Your first name", text: $appState.ownerName)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
        }
    }

    // MARK: - Step 2: Choose AI

    private let providers: [(id: String, name: String, description: String, badge: String)] = [
        ("groq",        "Groq",                     "Fast Llama models — free and reliable",  "Free"),
        ("gemini",      "Google Gemini",            "Gemini 2.0 Flash — best free model",     "Free"),
        ("openrouter",  "OpenRouter",               "Access 100+ models with one key",        "Free models available"),
        ("ollama",      "Ollama (Local)",            "Run models locally on your Mac, fully private", "Private"),
    ]

    private var stepChooseAI: some View {
        VStack(spacing: 12) {
            VStack(spacing: 6) {
                stepHeader(title: "Choose your AI")
                Text("You can change this anytime in Settings.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.45))
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(providers, id: \.id) { provider in
                        providerCard(provider)
                    }
                }
            }
        }
    }

    private func providerCard(_ provider: (id: String, name: String, description: String, badge: String)) -> some View {
        let selected = appState.selectedProvider == provider.id
        return Button {
            appState.selectedProvider = provider.id
            connectionState = .idle
            apiKeyInput = ""
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(provider.description)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                Text(provider.badge)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? Color.black : Color.white.opacity(0.5))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(selected ? Color.white : Color.white.opacity(0.1))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.white.opacity(selected ? 0.1 : 0.04))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? Color.white : Color.white.opacity(0.12), lineWidth: selected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: selected)
    }

    // MARK: - Step 3: API Key

    private var stepAPIKey: some View {
        VStack(spacing: 24) {
            stepHeader(title: "Enter your API key")

            if appState.selectedProvider == "ollama" {
                ollamaNoKeyView
            } else {
                apiKeyInputView
            }
        }
    }

    private var ollamaNoKeyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text("No API key needed for local models.")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var apiKeyInputView: some View {
        VStack(alignment: .leading, spacing: 14) {
            SecureField(keyPlaceholder, text: $apiKeyInput)
                .textFieldStyle(.plain)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
                .onChange(of: apiKeyInput) { connectionState = .idle }

            HStack(spacing: 12) {
                Button("Test Connection") {
                    Task { await testConnection() }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)

                connectionBadge

                Spacer()

                if let url = keyGetURL {
                    Link("Get API key ↗", destination: URL(string: url)!)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
    }

    private var keyGetURL: String? {
        switch appState.selectedProvider {
        case "openrouter": return "https://openrouter.ai/keys"
        case "gemini":     return "https://aistudio.google.com/apikey"
        case "groq":       return "https://console.groq.com/keys"
        default:           return nil
        }
    }

    private var keyPlaceholder: String {
        switch appState.selectedProvider {
        case "openrouter": return "sk-or-..."
        case "gemini":     return "AIza..."
        case "groq":       return "gsk_..."
        default:           return "API key"
        }
    }

    @ViewBuilder
    private var connectionBadge: some View {
        switch connectionState {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text("Testing…").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
            }
        case .success:
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Connected").font(.system(size: 13)).foregroundStyle(.green)
            }
        case .failure(let msg):
            HStack(spacing: 5) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                Text(msg).font(.system(size: 12)).foregroundStyle(.red).lineLimit(2)
            }
        }
    }

    private func testConnection() async {
        let key = apiKeyInput.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }

        connectionState = .testing

        do {
            let provider: any LLMProvider = switch appState.selectedProvider {
            case "openrouter": OpenRouterProvider()
            case "gemini":     LLMRouter.gemini
            case "ollama":     LLMRouter.ollama
            default:           LLMRouter.groq
            }

            // Temporarily save to keychain so the provider can read it
            KeychainHelper.save(service: "com.alfred.app", account: appState.selectedProvider, value: key)
            _ = try await provider.complete(prompt: "Reply with exactly one word: ready", system: "")
            connectionState = .success
        } catch let error as LLMError {
            // Remove key if test failed — don't leave invalid credentials in keychain
            KeychainHelper.delete(service: "com.alfred.app", account: appState.selectedProvider)
            connectionState = .failure(error.errorDescription ?? "Unknown error")
        } catch {
            KeychainHelper.delete(service: "com.alfred.app", account: appState.selectedProvider)
            connectionState = .failure(error.localizedDescription)
        }
    }

    // MARK: - Step 4: Permissions

    private var stepPermissions: some View {
        VStack(spacing: 24) {
            stepHeader(title: "Grant permissions")

            VStack(spacing: 12) {
                permissionRow(
                    icon: "accessibility",
                    title: "Accessibility",
                    description: accessibilityGranted ? "Granted" : "Required for explicit computer control, context, and text insertion",
                    isGranted: accessibilityGranted,
                    url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                )
                permissionRow(
                    icon: "camera.metering.spot",
                    title: "Screen Recording",
                    description: "Required for explicit screen context and opt-in screen monitoring",
                    isGranted: nil,
                    url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                )
            }

            Text("Alfred checks permission state silently and will not repeatedly prompt.\nUse Open Settings when you want to grant or change access.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.35))
                .multilineTextAlignment(.center)
        }
        .onAppear {
            accessibilityGranted = AXIsProcessTrusted()
        }
    }

    private func permissionRow(icon: String, title: String, description: String, isGranted: Bool?, url: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(isGranted == true ? .green : .white.opacity(0.7))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()

            if isGranted == true {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 16))
            }

            Button("Open Settings") {
                if let u = URL(string: url) {
                    NSWorkspace.shared.open(u)
                }
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    // MARK: - Navigation buttons

    private var navigationButtons: some View {
        HStack(spacing: 12) {
            if currentStep > 0 {
                Button("Back") { currentStep -= 1 }
                    .buttonStyle(SecondaryButtonStyle())
            }

            Spacer()

            if currentStep < totalSteps - 1 {
                Button("Next") { advance() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!canAdvance)
            } else {
                Button("Done") { finish() }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private var canAdvance: Bool {
        switch currentStep {
        case 1: return !appState.ownerName.trimmingCharacters(in: .whitespaces).isEmpty
        case 2: return !appState.selectedProvider.isEmpty
        case 3:
            if appState.selectedProvider == "ollama" || appState.selectedProvider == "local" { return true }
            if case .success = connectionState { return true }
            // Allow advancing with a non-empty key even without testing
            return !apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty
        case 5 where appState.ownerConfigEnabled:
            // The three fields the assistant cannot speak for someone without.
            return !ownerPreferredName.isEmptyAfterTrim
                && !ownerSignOffName.isEmptyAfterTrim
                && !ownerPronounSubject.isEmptyAfterTrim
                && !ownerPronounObject.isEmptyAfterTrim
                && !ownerPronounPossessive.isEmptyAfterTrim
        default: return true
        }
    }

    private func advance() {
        guard canAdvance else { return }
        if currentStep == 3, appState.selectedProvider != "ollama", appState.selectedProvider != "local" {
            let key = apiKeyInput.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                KeychainHelper.save(service: "com.alfred.app", account: appState.selectedProvider, value: key)
            }
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            currentStep += 1
        }
    }

    private func finish() {
        // With Owner Configuration on, a rejected profile blocks completion — finishing onboarding
        // with an unusable owner profile would leave drafting silently disabled with no explanation.
        guard saveOwnerConfig() else { return }
        appState.isOnboardingComplete = true
        UserDefaults.standard.set(true, forKey: "isOnboardingComplete")
        dismiss()
    }

    // MARK: - Shared helpers

    private func stepHeader(title: String) -> some View {
        Text(title)
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Welcome logo

private struct AlfredWelcomeLogo: View {
    var body: some View {
        Group {
            if let image = Self.logoImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                HStack(spacing: 28) {
                    AlfredTriangleMark()
                        .fill(Color.white, style: FillStyle(eoFill: true))
                        .frame(width: 86, height: 86)

                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 2, height: 112)

                    Text("ALFRED")
                        .font(.system(size: 48, weight: .black, design: .monospaced))
                        .tracking(3)
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.75)
                        .lineLimit(1)
                }
                .padding(.horizontal, 28)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static let logoImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "alfred-big-logo", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()
}

private struct AlfredTriangleMark: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let x = rect.midX
        let top = rect.midY - side * 0.47
        let bottom = rect.midY + side * 0.42
        let halfWidth = side * 0.44

        let outer = [
            CGPoint(x: x, y: top),
            CGPoint(x: x + halfWidth, y: bottom),
            CGPoint(x: x - halfWidth, y: bottom),
        ]

        let inner = [
            CGPoint(x: x, y: rect.midY - side * 0.18),
            CGPoint(x: x - side * 0.24, y: bottom - side * 0.13),
            CGPoint(x: x + side * 0.24, y: bottom - side * 0.13),
        ]

        var path = Path()
        path.addLines(outer)
        path.closeSubpath()
        path.addLines(inner)
        path.closeSubpath()
        return path
    }
}

// MARK: - Button styles

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background(configuration.isPressed ? Color.white.opacity(0.85) : Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.white.opacity(configuration.isPressed ? 0.12 : 0.08))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}
