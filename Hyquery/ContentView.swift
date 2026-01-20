import SwiftUI
import AppKit
import Combine

// MARK: - Models

struct QueryConfig: Equatable {
    var host: String = "192.168.0.203"              // or "192.168.0.203"
    var port: Int = 5523                     // placeholder; set to your WebServer plugin port
    var path: String = "/Nitrado/Query"      // per plugin route
    var useHTTPS: Bool = true                // placeholder for later TLS support
    var timeoutSeconds: Double = 5

    // Polling placeholders
    var pollingEnabled: Bool = false
    var pollingInterval: Double = 5
}

struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let level: Level
    let message: String

    enum Level: String {
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
        case debug = "DEBUG"
    }
}


// MARK: - Query Response Models

struct QueryResponse: Codable, Equatable {
    let server: ServerInfo?
    let universe: UniverseInfo?
    let players: PlayersInfo?
    let plugins: PluginsInfo?

    enum CodingKeys: String, CodingKey {
        case server = "Server"
        case universe = "Universe"
        case players = "Players"
        case plugins = "Plugins"
    }
}

struct ServerInfo: Codable, Equatable {
    let name: String?
    let version: String?
    let revision: String?
    let patchline: String?
    let protocolVersion: Int?
    let protocolHash: String?
    let maxPlayers: Int?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case version = "Version"
        case revision = "Revision"
        case patchline = "Patchline"
        case protocolVersion = "ProtocolVersion"
        case protocolHash = "ProtocolHash"
        case maxPlayers = "MaxPlayers"
    }
}

struct UniverseInfo: Codable, Equatable {
    let currentPlayers: Int?
    let defaultWorld: String?

    enum CodingKeys: String, CodingKey {
        case currentPlayers = "CurrentPlayers"
        case defaultWorld = "DefaultWorld"
    }
}

// MARK: Players / Plugins (optional sections gated by permissions)

struct PlayerInfo: Codable, Equatable, Identifiable {
    // Best-effort stable id: UUID if present, otherwise Name.
    var id: String { uuid ?? name ?? UUID().uuidString }

    let name: String?
    let uuid: String?
    let world: String?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case uuid = "UUID"
        case world = "World"
    }
}

struct PluginInfo: Codable, Equatable, Identifiable {
    var id: String { name ?? UUID().uuidString }

    let name: String?
    let version: String?
    let loaded: Bool?
    let enabled: Bool?
    let state: String?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case version = "Version"
        case loaded = "Loaded"
        case enabled = "Enabled"
        case state = "State"
    }
}

struct PlayersInfo: Codable, Equatable {
    let entries: [PlayerInfo]
    var count: Int { entries.count }

    init(entries: [PlayerInfo] = []) { self.entries = entries }

    enum WrapperKeys: String, CodingKey {
        case players = "Players"
        case list = "List"
        case entries = "Entries"
        case data = "Data"
    }

    init(from decoder: Decoder) throws {
        // Players may be an array or wrapped object.
        if let single = try? decoder.singleValueContainer(),
           let arr = try? single.decode([PlayerInfo].self) {
            self.entries = arr
            return
        }

        let container = try decoder.container(keyedBy: WrapperKeys.self)

        if let arr = try? container.decode([PlayerInfo].self, forKey: .players) { self.entries = arr; return }
        if let arr = try? container.decode([PlayerInfo].self, forKey: .entries) { self.entries = arr; return }
        if let arr = try? container.decode([PlayerInfo].self, forKey: .list) { self.entries = arr; return }
        if let arr = try? container.decode([PlayerInfo].self, forKey: .data) { self.entries = arr; return }

        self.entries = []
    }
}

struct PluginsInfo: Codable, Equatable {
    let entries: [PluginInfo]
    var count: Int { entries.count }

    init(entries: [PluginInfo] = []) { self.entries = entries }

    enum WrapperKeys: String, CodingKey {
        case plugins = "Plugins"
        case list = "List"
        case entries = "Entries"
        case data = "Data"
    }
    
    private struct PluginInfoValue: Codable {
        let version: String?
        let loaded: Bool?
        let enabled: Bool?
        let state: String?

        enum CodingKeys: String, CodingKey {
            case version = "Version"
            case loaded = "Loaded"
            case enabled = "Enabled"
            case state = "State"
        }
    }

    init(from decoder: Decoder) throws {
        // Plugins may be an array, a wrapped array, or a dictionary of name -> details.
        if let single = try? decoder.singleValueContainer(),
           let arr = try? single.decode([PluginInfo].self) {
            self.entries = arr
            return
        }

        let container = try decoder.container(keyedBy: WrapperKeys.self)

        if let arr = try? container.decode([PluginInfo].self, forKey: .plugins) { self.entries = arr; return }
        if let arr = try? container.decode([PluginInfo].self, forKey: .entries) { self.entries = arr; return }
        if let arr = try? container.decode([PluginInfo].self, forKey: .list) { self.entries = arr; return }
        if let arr = try? container.decode([PluginInfo].self, forKey: .data) { self.entries = arr; return }

        // Try dictionary form: { "Plugins": { "Name": { ...details... }, ... } }
        if let dict = try? container.decode([String: PluginInfoValue].self, forKey: .plugins) {
            self.entries = dict.map { key, value in
                PluginInfo(name: key, version: value.version, loaded: value.loaded, enabled: value.enabled, state: value.state)
            }.sorted { ($0.name ?? "") < ($1.name ?? "") }
            return
        }

        // If top-level is a dictionary without a wrapping key, try decoding directly as [String: PluginInfoValue].
        if let topDict = try? decoder.singleValueContainer().decode([String: PluginInfoValue].self) {
            self.entries = topDict.map { key, value in
                PluginInfo(name: key, version: value.version, loaded: value.loaded, enabled: value.enabled, state: value.state)
            }.sorted { ($0.name ?? "") < ($1.name ?? "") }
            return
        }

        self.entries = []
    }
}

// MARK: - Networking Client

final class HytaleQueryClient: NSObject {
    // Critical: the endpoint expects a specific Accept header, otherwise it may 406.
    // Modified to application/json to match new requirement.
    private let acceptHeader = "application/json"

    private let allowedSelfSignedHosts: Set<String> = ["NUCTAX", "192.168.0.203", "nuctax.local"]

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    override init() {
        super.init()
    }

    func buildURL(from config: QueryConfig) -> URL? {
        var comps = URLComponents()
        comps.scheme = config.useHTTPS ? "https" : "http"
        comps.host = config.host
        comps.port = config.port
        comps.path = config.path
        return comps.url
    }

    func fetchOnce(config: QueryConfig) async -> Result<(HTTPURLResponse, Data), Error> {
        guard let url = buildURL(from: config) else {
            return .failure(URLError(.badURL))
        }

        var request = URLRequest(url: url, timeoutInterval: config.timeoutSeconds)
        request.httpMethod = "GET"
        request.setValue(acceptHeader, forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(URLError(.badServerResponse))
            }
            return .success((http, data))
        } catch {
            return .failure(error)
        }
    }
}

extension HytaleQueryClient: URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust {
            let host = challenge.protectionSpace.host
            if allowedSelfSignedHosts.contains(host) {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
                return
            }
        }
        completionHandler(.performDefaultHandling, nil)
    }
}

// MARK: - ViewModel

@MainActor
final class AppViewModel: ObservableObject {
    @Published var config = QueryConfig()
    @Published var logs: [LogEntry] = []
    @Published var lastRawJSON: String = ""
    @Published var isRequestInFlight = false
    @Published var lastParsed: QueryResponse?

    private let client = HytaleQueryClient()
    private var pollingTask: Task<Void, Never>?

    private func cancelPollingTask(logMessage: Bool) {
        if pollingTask != nil {
            pollingTask?.cancel()
            pollingTask = nil
            if logMessage {
                log(.info, "Polling stopped")
            }
        }
    }

    func log(_ level: LogEntry.Level, _ message: String) {
        logs.append(.init(date: Date(), level: level, message: message))
    }

    func clearLogs() {
        logs.removeAll()
    }

    func testRequest() {
        Task<Void, Never> { await performRequest(reason: "Manual Test") }
    }

    func togglePolling() {
        config.pollingEnabled.toggle()
        if config.pollingEnabled {
            startPolling()
        } else {
            stopPolling()
        }
    }

    func startPolling() {
        // Cancel any existing polling loop without changing the toggle state.
        cancelPollingTask(logMessage: false)

        log(.info, "Polling started: every \(Int(config.pollingInterval))s")

        pollingTask = Task<Void, Never> { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.performRequest(reason: "Polling")
                let nanos = UInt64(self.config.pollingInterval * 1_000_000_000.0)
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
    }

    func stopPolling() {
        cancelPollingTask(logMessage: true)
    }

    private func formatHeaders(_ headers: [AnyHashable: Any]) -> String {
        let pairs: [(String, String)] = headers
            .compactMap { (element: (key: AnyHashable, value: Any)) -> (String, String)? in
                let (key, value) = element
                guard let k = key as? String else { return nil }
                return (k, String(describing: value))
            }
            .sorted { (lhs, rhs) in lhs.0.lowercased() < rhs.0.lowercased() }

        return pairs.map { "\($0): \($1)" }.joined(separator: "\n")
    }

    func performRequest(reason: String) async {
        // prevent overlap
        guard !isRequestInFlight else {
            log(.debug, "Skipped \(reason): request already in flight")
            return
        }
        isRequestInFlight = true
        defer { isRequestInFlight = false }

        guard let url = client.buildURL(from: config) else {
            log(.error, "\(reason): bad URL (host/port/path)")
            return
        }

        log(.info, "\(reason): GET \(url.absoluteString)")
        log(.debug, "Accept: application/json")

        let result = await client.fetchOnce(config: config)

        switch result {
        case .failure(let error):
            log(.error, "\(reason): \(error.localizedDescription)")
        case .success(let (http, data)):
            log(.info, "\(reason): HTTP \(http.statusCode) (\(data.count) bytes)")

            let headerText = formatHeaders(http.allHeaderFields)
            log(.debug, "Response headers:\n\(headerText)")

            let contentType = (http.allHeaderFields["Content-Type"] as? String) ?? ""
            let lower = contentType.lowercased()
            let isLatin1 = lower.contains("charset=iso-8859-1") || lower.contains("charset=latin1")
            let bodyPreview: String
            if isLatin1 {
                bodyPreview = String(data: data, encoding: .isoLatin1) ?? "<non-decodable body>"
            } else {
                bodyPreview = String(data: data, encoding: .utf8) ?? "<non-decodable body>"
            }
            lastRawJSON = bodyPreview

            // Decode into strongly-typed model for the Dashboard.
            do {
                let normalizedData: Data
                if isLatin1 {
                    // Convert Latin-1 bytes -> String -> UTF-8 bytes for JSONDecoder.
                    normalizedData = bodyPreview.data(using: .utf8) ?? data
                } else {
                    normalizedData = data
                }

                let decoder = JSONDecoder()
                let parsed = try decoder.decode(QueryResponse.self, from: normalizedData)
                lastParsed = parsed
            } catch {
                lastParsed = nil
                log(.warn, "Decode failed: \(error.localizedDescription)")
            }

            // short preview in logs so it’s not too spammy
            let maxChars = 1200
            let snippet = bodyPreview.count > maxChars ? String(bodyPreview.prefix(maxChars)) + "\n…(truncated)…" : bodyPreview
            log(.debug, "Body preview:\n\(snippet)")

            // Helpful hint if 406
            if http.statusCode == 406 {
                log(.warn, "HTTP 406: check Accept header and endpoint path. This endpoint often requires a specific Accept type.")
            }
        }
    }
}

// MARK: - Views

struct ContentView: View {
    @StateObject private var vm = AppViewModel()
    @State private var portString: String = ""
    private let projectNotesText: String = """
HYQUERY (macOS SwiftUI) — Project Summary

Purpose
- Simple LAN monitor app that polls the Hytale Nitrado Query endpoint and shows server/universe info.

Environment
- Hytale server runs in Docker on host: NUCTAX (LAN IP 192.168.0.203)
- Web endpoint is HTTPS (self-signed cert) on port 5523
- Endpoint path: /Nitrado/Query

Plugins
- WebServer plugin: https://github.com/nitrado/hytale-plugin-webserver
- Query plugin: https://github.com/nitrado/hytale-plugin-query

Docker / Ports
- Game port is UDP (example: 5520/udp)
- WebServer port must be published as TCP (5523/tcp) to reach it from the LAN/macOS app
- WebServer binds to 0.0.0.0:5523 inside the container

HTTP Notes
- Use HTTPS (NOT http). Plain HTTP to 5523 causes protocol errors.
- Accept header:
  - Use: Accept: application/json (works reliably)
  - Custom nitrado media-type Accept variants caused 406 during testing.
- Response Content-Type includes: application/x.hytale.nitrado.query+json;version=1;charset=iso-8859-1
  - App decodes ISO-8859-1 as needed and converts to UTF-8 for JSON decoding.

Permissions (Anonymous)
- permissions.json includes ANONYMOUS group mapped to the anonymous UUID (00000000-0000-0000-0000-000000000000).
- Grant at minimum:
  - nitrado.query.web.read.server
  - nitrado.query.web.read.universe
- With these, /Nitrado/Query returns 200 for anonymous requests (no /login redirect).

macOS App Sandbox
- Must enable: App Sandbox → Outgoing Connections (Client)
  - Without this, networking fails with NECP/Operation not permitted errors.

SwiftUI App Layout
- Tabs: Dashboard, Players, Plugins, Raw JSON, Logs, Notes
- Polling: Toggle + interval picker; uses a Task loop and avoids overlapping requests.
- TLS: URLSessionDelegate allows self-signed cert only for allowed hosts: NUCTAX, nuctax.local, 192.168.0.203

Current Defaults
- host: 192.168.0.203
- port: 5523
- path: /Nitrado/Query
- useHTTPS: true
- Accept: application/json
"""

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            TabView {
                dashboardTab
                    .tabItem { Label("Dashboard", systemImage: "gauge") }

                playersTab
                    .tabItem { Label("Players", systemImage: "person.3") }

                pluginsTab
                    .tabItem { Label("Plugins", systemImage: "puzzlepiece") }

                rawJSONTab
                    .tabItem { Label("Raw JSON", systemImage: "curlybraces") }

                logTab
                    .tabItem { Label("Logs", systemImage: "list.bullet.rectangle") }

                notesTab
                    .tabItem { Label("Notes", systemImage: "note.text") }
            }
            .padding()
        }
        .frame(minWidth: 1100, minHeight: 720)
    }

    private var sidebar: some View {
        Form {
            Section("Connection") {
                TextField("Host (DNS or IP)", text: $vm.config.host)

                HStack {
                    Text("Port")
                    Spacer()
                    TextField("", text: Binding(
                        get: { portString.isEmpty ? String(vm.config.port) : portString },
                        set: { newValue in
                            // Keep only digits
                            let digits = newValue.filter { $0.isNumber }
                            portString = digits
                            if let intVal = Int(digits) {
                                vm.config.port = max(0, min(65535, intVal))
                            }
                        }
                    ))
                    .frame(width: 120)
                    .onAppear { portString = String(vm.config.port) }
                }

                TextField("Path", text: $vm.config.path)
                    .font(.system(.body, design: .monospaced))

                Toggle("HTTPS", isOn: $vm.config.useHTTPS)

                HStack {
                    Text("Timeout")
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer()
                    TextField("", value: $vm.config.timeoutSeconds, format: .number)
                        .frame(width: 120)
                    Text("sec")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }

            Section("Polling") {
                Toggle("Enable Polling", isOn: Binding<Bool>(
                    get: { vm.config.pollingEnabled },
                    set: { (newValue: Bool) in
                        vm.config.pollingEnabled = newValue
                        if newValue {
                            vm.startPolling()
                        } else {
                            vm.stopPolling()
                        }
                    }
                ))

                HStack {
                    Text("Interval")
                    Spacer()
                    Picker("", selection: $vm.config.pollingInterval) {
                        Text("1s").tag(1.0)
                        Text("2s").tag(2.0)
                        Text("5s").tag(5.0)
                        Text("10s").tag(10.0)
                        Text("30s").tag(30.0)
                        Text("60s").tag(60.0)
                    }
                    .frame(width: 160)
                }
                .onChange(of: vm.config.pollingInterval) { _ in
                    // If polling is running, restart to apply interval immediately
                    if vm.config.pollingEnabled {
                        vm.startPolling()
                    }
                }
            }

            Section {
                HStack {
                    Button {
                        vm.testRequest()
                    } label: {
                        Label("Run Query", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut(.return, modifiers: [.command])

                    Spacer()

                    if vm.isRequestInFlight {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                Button(role: .destructive) {
                    vm.clearLogs()
                } label: {
                    Label("Clear Logs", systemImage: "trash")
                }
            }
        }
        .frame(minWidth: 280)
        .formStyle(.grouped)
        .navigationTitle("Hytale LAN Monitor")
        .padding()
    }

    private var dashboardTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Status")
                .font(.title2.weight(.semibold))

            HStack(spacing: 12) {
                StatusCard(
                    title: "Endpoint",
                    value: "\(vm.config.host):\(vm.config.port)\(vm.config.path)",
                    systemImage: "network"
                )

                StatusCard(
                    title: "Polling",
                    value: vm.config.pollingEnabled ? "On (\(Int(vm.config.pollingInterval))s)" : "Off",
                    systemImage: vm.config.pollingEnabled ? "timer" : "timer.square"
                )
            }

            Divider()

            Text("Overview")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                PlaceholderRow(label: "Server Name", value: vm.lastParsed?.server?.name ?? "—")
                PlaceholderRow(label: "Version", value: vm.lastParsed?.server?.version ?? "—")
                PlaceholderRow(label: "Universe / World", value: vm.lastParsed?.universe?.defaultWorld ?? "—")
                PlaceholderRow(label: "Players Online", value: {
                    if let cur = vm.lastParsed?.universe?.currentPlayers {
                        return String(cur)
                    }
                    return "—"
                }())
                PlaceholderRow(label: "Max Players", value: {
                    if let max = vm.lastParsed?.server?.maxPlayers {
                        return String(max)
                    }
                    return "—"
                }())
                PlaceholderRow(label: "Players Listed", value: {
                    if let players = vm.lastParsed?.players {
                        return String(players.count)
                    }
                    return "—"
                }())
                PlaceholderRow(label: "Plugins Listed", value: {
                    if let plugins = vm.lastParsed?.plugins {
                        return String(plugins.count)
                    }
                    return "—"
                }())
            }
            .padding(12)
            .background(GlassCardBackground(cornerRadius: 14))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Spacer()
        }
    }

    private var playersTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Players")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("Total: \(vm.lastParsed?.players?.count ?? 0)")
                    .foregroundStyle(.secondary)
            }

            if let players = vm.lastParsed?.players?.entries, !players.isEmpty {
                List(players) { p in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(p.name ?? "<unknown>")
                            .font(.system(.body, design: .rounded).weight(.semibold))
                        HStack(spacing: 12) {
                            if let world = p.world {
                                Label(world, systemImage: "globe")
                                    .foregroundStyle(.secondary)
                            }
                            if let uuid = p.uuid {
                                Text(uuid)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Text("No player list available. Enable permission nitrado.query.web.read.players (or log in) to include the Players section in the response.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var pluginsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Plugins")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("Total: \(vm.lastParsed?.plugins?.count ?? 0)")
                    .foregroundStyle(.secondary)
            }

            if let plugins = vm.lastParsed?.plugins?.entries, !plugins.isEmpty {
                List(plugins) { pl in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(pl.name ?? "<unknown>")
                                .font(.system(.body, design: .rounded).weight(.semibold))
                            Spacer()
                            if let enabled = pl.enabled {
                                Text(enabled ? "Enabled" : "Disabled")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        HStack(spacing: 12) {
                            if let version = pl.version {
                                Label(version, systemImage: "tag")
                                    .foregroundStyle(.secondary)
                            }
                            if let loaded = pl.loaded {
                                Label(loaded ? "Loaded" : "Not loaded",
                                      systemImage: loaded ? "checkmark.circle" : "xmark.circle")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Text("No plugin list available. Enable permission nitrado.query.web.read.plugins (or log in) to include the Plugins section in the response.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }


    private var rawJSONTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Raw Response")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    let pretty = prettyPrintedJSON(from: vm.lastRawJSON)
                    NSPasteboard.general.setString(pretty, forType: .string)
                    vm.log(.info, "Copied Raw JSON to clipboard")
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(vm.lastRawJSON.isEmpty)
            }
            
            if vm.lastRawJSON.isEmpty {
                Text("No data yet. Hit Test.")
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, minHeight: 280, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
                    .background(GlassCardBackground(cornerRadius: 12))
            } else {
                let pretty = prettyPrintedJSON(from: vm.lastRawJSON)
                let attributed = JSONSyntaxHighlighter.highlight(pretty)
                AttributedTextView(attributedString: attributed)
                    .frame(maxWidth: .infinity, minHeight: 280, alignment: .leading)
                    .padding(12)
                    .background(GlassCardBackground(cornerRadius: 12))
            }
        }
    }

    private var logTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Logs")
                .font(.title3.weight(.semibold))

            ScrollViewReader { proxy in
                List(vm.logs) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        Text(entry.date, style: .time)
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .leading)

                        Text(entry.level.rawValue)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(entry.level == .error ? .red : (entry.level == .warn ? .orange : .secondary))
                            .frame(width: 60, alignment: .leading)

                        Text(entry.message)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .id(entry.id)
                }
                .onChange(of: vm.logs.count) { _ in
                    guard let last = vm.logs.last else { return }
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var notesTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Project Notes")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(projectNotesText, forType: .string)
                    vm.log(.info, "Copied Project Notes to clipboard")
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }

            ScrollView {
                Text(projectNotesText)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
                    .background(GlassCardBackground(cornerRadius: 12))
            }
        }
    }
}

// MARK: - Liquid Glass helpers (macOS 26+)

private struct GlassCardBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        if #available(macOS 26.0, *) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.clear)
                .glassEffect(.regular,
                             in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.thinMaterial)
        }
    }
}

struct StatusCard: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GlassCardBackground(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct PlaceholderRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.body, design: .rounded).weight(.semibold))
        }
    }
}

// MARK: - Raw JSON Pretty Print & Highlighting

private func prettyPrintedJSON(from raw: String) -> String {
    guard let data = raw.data(using: .utf8) else { return raw }
    do {
        let obj = try JSONSerialization.jsonObject(with: data, options: [])
        let prettyData = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        return String(data: prettyData, encoding: .utf8) ?? raw
    } catch {
        return raw
    }
}

private struct JSONSyntaxHighlighter {
    static func highlight(_ text: String) -> NSAttributedString {
        let full = NSMutableAttributedString(string: text)
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        full.addAttributes([
            .font: font,
            .foregroundColor: NSColor.labelColor
        ], range: NSRange(location: 0, length: full.length))

        // Regex patterns
        let keyPattern = #"\"([^\"]+)\"(?=\s*: )"#
        let stringPattern = #"\"([^\"]*)\""#
        let numberPattern = #"(?<![\w\"])(?:-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)(?![\w\"])"#
        let boolPattern = #"(?<![\w\"])\b(?:true|false)\b(?![\w\"])"#
        let nullPattern = #"(?<![\w\"])\bnull\b(?![\w\"])"#
        let punctuationPattern = #"[\{\}\[\]\:,]"#

        apply(pattern: keyPattern, to: full, color: NSColor.systemTeal)
        apply(pattern: stringPattern, to: full, color: NSColor.systemGreen)
        apply(pattern: numberPattern, to: full, color: NSColor.systemOrange)
        apply(pattern: boolPattern, to: full, color: NSColor.systemPurple)
        apply(pattern: nullPattern, to: full, color: NSColor.secondaryLabelColor)
        apply(pattern: punctuationPattern, to: full, color: NSColor.secondaryLabelColor)

        return full
    }

    private static func apply(pattern: String, to attr: NSMutableAttributedString, color: NSColor) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
        let range = NSRange(location: 0, length: attr.length)
        regex.enumerateMatches(in: attr.string, options: [], range: range) { match, _, _ in
            guard let r = match?.range else { return }
            attr.addAttribute(.foregroundColor, value: color, range: r)
        }
    }
}

// MARK: - NSAttributedString display in SwiftUI (macOS)

private struct AttributedTextView: NSViewRepresentable {
    let attributedString: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textStorage?.setAttributedString(attributedString)

        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        textView.textStorage?.setAttributedString(attributedString)
    }
}

#Preview {
    ContentView()
}

