import Foundation
import SwiftUI

/// Auday's "AI settings": the user's own provider, called straight from this iPhone. The key is
/// kept in this app's Keychain; text and context go to the provider, never audio.
enum AIConfig {
    /// Auday's list, in Auday's order. All are called through their OpenAI-compatible endpoints.
    enum Provider: String, CaseIterable {
        case deepSeek = "DeepSeek", openAI = "OpenAI", claude = "Claude", gemini = "Gemini", grok = "Grok",
             miniMax = "MiniMax", kimi = "Kimi", glm = "GLM", qwen = "Qwen", custom = "Custom"
    }

    static var provider: Provider {
        get { UserDefaults.standard.string(forKey: "aiProvider").flatMap(Provider.init) ?? .custom }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "aiProvider") }
    }
    static var model: String {
        get { UserDefaults.standard.string(forKey: "aiModel") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "aiModel") }
    }
    static var baseURL: String {
        get { UserDefaults.standard.string(forKey: "aiBaseURL") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "aiBaseURL") }
    }
    static var key: String {
        get { Keychain.aiKey ?? "" }
        set { Keychain.aiKey = newValue }
    }
    static var automaticHighlights: Bool {
        get { UserDefaults.standard.object(forKey: "aiHighlights") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "aiHighlights") }
    }
    static var dailyReflection: Bool {
        get { UserDefaults.standard.object(forKey: "aiReflection") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "aiReflection") }
    }
    static var reflectionTime: Date {
        get { UserDefaults.standard.object(forKey: "aiReflectionTime") as? Date
                ?? Calendar.current.date(bySettingHour: 0, minute: 0, second: 0, of: Date())! }
        set { UserDefaults.standard.set(newValue, forKey: "aiReflectionTime") }
    }

    static var configured: Bool { !model.isEmpty && !key.isEmpty && endpoint != nil }

    static func defaultBase(_ provider: Provider) -> String {
        switch provider {
        case .deepSeek: "https://api.deepseek.com/v1"
        case .openAI: "https://api.openai.com/v1"
        case .claude: "https://api.anthropic.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .grok: "https://api.x.ai/v1"
        case .miniMax: "https://api.minimax.io/v1"
        case .kimi: "https://api.moonshot.ai/v1"
        case .glm: "https://open.bigmodel.cn/api/paas/v4"
        case .qwen: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
        case .custom: ""
        }
    }

    /// A fallback to choose from until the provider's own list has loaded with the API key.
    /// gemini-3.8-flash is what the user's real Auday is set to.
    static func builtInModels(_ provider: Provider) -> [String] {
        switch provider {
        case .deepSeek: ["deepseek-chat", "deepseek-reasoner"]
        case .openAI: ["gpt-5", "gpt-5-mini", "gpt-5-nano"]
        case .claude: ["claude-sonnet-5-5", "claude-haiku-5-5", "claude-opus-5-5"]
        case .gemini: ["gemini-3.8-flash", "gemini-2.5-flash", "gemini-2.5-pro"]
        case .grok: ["grok-4", "grok-4-fast"]
        case .miniMax: ["MiniMax-M2"]
        case .kimi: ["kimi-k2-turbo-preview", "kimi-k2-0905-preview"]
        case .glm: ["glm-4.6", "glm-4.5-air"]
        case .qwen: ["qwen-plus", "qwen-max", "qwen-flash"]
        case .custom: []
        }
    }

    /// The provider's model list (GET …/models), for the Model Name picker.
    static func models(provider: Provider, baseURL: String, key: String) async throws -> [String] {
        guard let chat = endpoint(provider: provider, baseURL: baseURL) else { throw AIClient.Failure.notConfigured }
        let url = chat.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("models")
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if provider == .claude {           // Anthropic's own model list wants these headers
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw ListFailure.key }
        guard code == 200 else { throw ListFailure.other(code) }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let ids = ((object?["data"] as? [[String: Any]]) ?? []).compactMap { ($0["id"] as? String)?.replacingOccurrences(of: "models/", with: "") }
        // Chat models only: leave out embeddings, speech, image and moderation models.
        let skip = ["embed", "tts", "whisper", "dall-e", "image", "moderation", "audio", "transcribe", "aqa", "imagen", "veo"]
        return ids.filter { id in !skip.contains { id.contains($0) } }.sorted()
    }

    enum ListFailure: LocalizedError {
        case key, other(Int)
        var errorDescription: String? {
            switch self {
            case .key: "The provider did not accept this API key."
            case .other(let code): "The provider returned error \(code) for its model list."
            }
        }
    }

    /// OpenAI-compatible chat completions endpoint.
    static var endpoint: URL? { endpoint(provider: provider, baseURL: baseURL) }

    static func endpoint(provider: Provider, baseURL: String) -> URL? {
        let base = (baseURL.isEmpty ? defaultBase(provider) : baseURL).trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, var url = URL(string: base) else { return nil }
        if !url.path.hasSuffix("chat/completions") { url.appendPathComponent("chat/completions") }
        return url
    }
}

enum AIClient {
    struct Message: Encodable { var role: String; var content: String }

    enum Failure: LocalizedError {
        case notConfigured, http(Int, String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: "Add your AI in Settings › AI settings."
            case .http(let code, let body): "The provider returned error \(code). \(body.prefix(160))"
            }
        }
    }

    static func complete(_ messages: [Message], json: Bool = false) async throws -> String {
        guard AIConfig.configured, let url = AIConfig.endpoint else { throw Failure.notConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(AIConfig.key)", forHTTPHeaderField: "Authorization")
        struct Format: Encodable { var type = "json_object" }
        struct Body: Encodable { var model: String; var messages: [Message]; var response_format: Format? }
        request.httpBody = try JSONEncoder().encode(Body(model: AIConfig.model, messages: messages,
                                                         response_format: json ? Format() : nil))
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw Failure.http(code, String(decoding: data, as: UTF8.self)) }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choice = (object?["choices"] as? [[String: Any]])?.first
        return ((choice?["message"] as? [String: Any])?["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct AISettingsView: View {
    @State private var provider = AIConfig.provider
    @State private var model = AIConfig.model
    @State private var baseURL = AIConfig.baseURL
    @State private var key = AIConfig.key
    @State private var highlights = AIConfig.automaticHighlights
    @State private var reflection = AIConfig.dailyReflection
    @State private var time = AIConfig.reflectionTime
    @State private var checking = false
    @State private var result: String?
    @State private var available: [String] = []
    @State private var loadingModels = false
    @State private var listError: String?
    @State private var typing = false
    @State private var typedModel = ""
    @State private var editingKey = AIConfig.key.isEmpty
    @FocusState private var keyFocused: Bool

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("An AI of your\nchoosing.").font(Theme.serif(30, .regular))
                    Text("Add your API key for Chat, Highlights, and more. These AI features send text and context directly to your provider, not original audio. Optional remote transcription is configured separately. No Auday servers.")
                        .font(.system(size: 17)).foregroundStyle(Theme.muted)
                }
                .padding(.vertical, 8)
            }
            Section {
                StackedPicker("Provider", selection: $provider, options: AIConfig.Provider.allCases) { $0.rawValue }
                    .onChange(of: provider) { _, value in
                        AIConfig.provider = value
                        available = []
                        listError = nil
                        // Drop the previous provider's model; otherwise `choices` would keep listing it.
                        let builtIn = AIConfig.builtInModels(value)
                        if value == .custom { model = ""; typedModel = "" }
                        else if !builtIn.contains(model) { model = builtIn.first ?? "" }
                        AIConfig.model = model
                        Task { await loadModels() }
                    }
                if provider == .custom && (typing || choices.isEmpty) {
                    LabeledContent("Model Name") {
                        TextField("model name", text: $typedModel).multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onSubmit { model = typedModel; AIConfig.model = typedModel }
                            .onChange(of: typedModel) { _, value in model = value; AIConfig.model = value }
                    }
                } else {
                    LabeledContent {
                        Menu {
                            Picker("Model Name", selection: $model) {
                                ForEach(choices, id: \.self) { Text($0).tag($0) }
                                if provider == .custom { Text("Other…").tag("__other__") }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                if loadingModels { ProgressView().controlSize(.small) }
                                Text(model.isEmpty ? "Choose" : model).lineLimit(1).truncationMode(.tail)
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 20, weight: .regular))
                            }
                            .foregroundStyle(Theme.text)
                        }
                    } label: { Text("Model Name") }
                    .onChange(of: model) { _, value in
                        if value == "__other__" { typing = true; typedModel = ""; return }
                        AIConfig.model = value
                    }
                }
                if let listError {
                    Label(listError, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Theme.red)
                } else if !available.isEmpty {
                    Text("\(available.count) models from \(provider.rawValue).").font(.footnote).foregroundStyle(Theme.muted)
                }
                LabeledContent("Base URL") {
                    TextField(provider == .custom ? "Required" : "Optional", text: $baseURL)
                        .multilineTextAlignment(.trailing).lineLimit(1)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .foregroundStyle(Theme.text)
                        .onSubmit { Task { await loadModels() } }
                }
                if editingKey {
                    SecureField("API key", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($keyFocused)
                        .onChange(of: key) { _, _ in Task { await loadModels(debounce: true) } }
                        .onChange(of: keyFocused) { _, focused in
                            // Leaving the field empty keeps the saved key; a typed one is masked again.
                            guard !focused else { return }
                            if key.isEmpty { key = AIConfig.key }
                            editingKey = key.isEmpty
                        }
                } else {
                    // Like Auday: a saved key shows as a short fixed mask, not one dot per character.
                    Button {
                        key = ""
                        editingKey = true
                        DispatchQueue.main.async { keyFocused = true }
                    } label: {
                        LabeledContent("API key") { Text("••••••").foregroundStyle(Theme.muted) }
                    }
                    .foregroundStyle(Theme.text)
                }
                Button(checking ? "Checking…" : "Check Connection & Save") { save() }
                    .foregroundStyle(Theme.text).disabled(checking)
                if let result { Text(result).font(.footnote).foregroundStyle(Theme.muted) }
                Button("Delete AI Settings", role: .destructive) {
                    model = ""; baseURL = ""; key = ""; editingKey = true
                    AIConfig.model = ""; AIConfig.baseURL = ""; AIConfig.key = ""
                    result = nil
                }
            } header: { SectionHeader("Your AI") }
            Section {
                Toggle("Automatic Highlights & Summaries", isOn: $highlights)
                    .onChange(of: highlights) { _, on in AIConfig.automaticHighlights = on }
                Toggle("Daily Reflection", isOn: $reflection)
                    .onChange(of: reflection) { _, on in AIConfig.dailyReflection = on }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Reflection Time")
                    DatePicker("Reflection Time", selection: $time, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .onChange(of: time) { _, value in AIConfig.reflectionTime = value }
                }
            } header: { SectionHeader("How Auday remembers") }
        }
        .settingsStyle()
        .task {
            // A model saved under another provider (e.g. gemini-3.8-flash while OpenAI is chosen) is replaced.
            let builtIn = AIConfig.builtInModels(provider)
            if provider != .custom, model.isEmpty || (belongsToAnotherProvider(model) && !builtIn.contains(model)) {
                model = builtIn.first ?? ""
                AIConfig.model = model
            }
            await loadModels()
        }
        .navigationTitle("AI settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The models to pick from: the provider's own list once loaded, else the built-in one;
    /// the current choice always stays listed.
    private var choices: [String] {
        var list = available.isEmpty ? AIConfig.builtInModels(provider) : available
        if !model.isEmpty && model != "__other__" && !list.contains(model) && !belongsToAnotherProvider(model) { list.insert(model, at: 0) }
        return list
    }

    /// A model that is on another provider's built-in list and not on this one's.
    private func belongsToAnotherProvider(_ name: String) -> Bool {
        provider != .custom && !AIConfig.builtInModels(provider).contains(name) && !available.contains(name)
            && AIConfig.Provider.allCases.contains { $0 != provider && AIConfig.builtInModels($0).contains(name) }
    }

    private func loadModels(debounce: Bool = false) async {
        if debounce {
            let current = key
            try? await Task.sleep(for: .milliseconds(700))
            guard current == key else { return }
        }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, provider != .custom || !baseURL.isEmpty else { return }
        loadingModels = true
        defer { loadingModels = false }
        do {
            available = try await AIConfig.models(provider: provider, baseURL: baseURL, key: key)
            listError = available.isEmpty ? "The provider returned no models." : nil
            if !available.isEmpty && (model.isEmpty || !available.contains(model)) && provider != .custom {
                model = available.first { $0.contains("flash") || $0.contains("mini") } ?? available[0]
                AIConfig.model = model
            }
        } catch let error as URLError {
            listError = error.code == .notConnectedToInternet ? "No internet connection." : "Could not reach the provider."
        } catch {
            listError = error.localizedDescription
        }
    }

    private func save() {
        if provider == .custom && baseURL.trimmingCharacters(in: .whitespaces).isEmpty {
            result = "A custom provider needs a Base URL."
            return
        }
        if belongsToAnotherProvider(model) { model = AIConfig.builtInModels(provider).first ?? "" }
        AIConfig.provider = provider
        AIConfig.model = model.trimmingCharacters(in: .whitespaces)
        AIConfig.baseURL = baseURL.trimmingCharacters(in: .whitespaces)
        AIConfig.key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        keyFocused = false
        editingKey = AIConfig.key.isEmpty
        checking = true
        Task {
            do {
                await loadModels()
                _ = try await AIClient.complete([.init(role: "user", content: "Reply with OK.")])
                result = "Connected and saved."
                Task { await AppDelegate.pipeline.run() }
            } catch {
                result = "Saved. " + error.localizedDescription
            }
            checking = false
        }
    }
}

/// Auday's settings pickers: the label on one line and the value with ⌃⌄ under it
/// (Appearance, Language, Provider), so every such row has the same size.
struct StackedPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String

    init(_ title: String, selection: Binding<Value>, options: [Value], label: @escaping (Value) -> String) {
        self.title = title
        self._selection = selection
        self.options = options
        self.label = label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
            Menu {
                Picker(title, selection: $selection) {
                    ForEach(options, id: \.self) { Text(label($0)).tag($0) }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(label(selection))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 20, weight: .regular))
                }
                .foregroundStyle(Theme.text)
                .padding(.leading, 14)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Grey section titles as in Auday's settings pages ("Your AI", "Apple Health").
struct SectionHeader: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 28, weight: .semibold)).foregroundStyle(Theme.faint).textCase(nil)
    }
}

extension View {
    /// Auday's settings lists: warm grey background, white rounded groups.
    func settingsStyle() -> some View {
        scrollContentBackground(.hidden)
            .background(Theme.bg)
            .listSectionSpacing(18)
            .font(.system(size: 28))       // Auday's settings rows are about this size on the phone
    }
}
