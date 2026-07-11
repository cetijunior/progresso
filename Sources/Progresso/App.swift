import SwiftUI

/// App-wide light/dark override, persisted in UserDefaults ("appearanceMode").
enum Appearance {
    static func apply(_ raw: String) {
        switch raw {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
        default:      NSApp.appearance = nil   // follow the system
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Appearance.apply(UserDefaults.standard.string(forKey: "appearanceMode") ?? "system")
    }
}

/// Headless verification of the exact parse→serialize→write path:
/// `Progresso --test-set-amount <file.md> <amount>`
enum TestMode {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--test-set-amount"), args.count > i + 2 else { return }
        let url = URL(fileURLWithPath: args[i + 1])
        let amount = Double(args[i + 2]) ?? 0
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              var t = Frontmatter.parseTicket(text: text, fileURL: url) else {
            print("TESTMODE: parse failed for \(url.path)"); exit(1)
        }
        print("TESTMODE parsed: title='\(t.title)' client='\(t.client)' amount=\(t.amount) status=\(t.status) tags=\(t.tags) extra=\(t.extra.map(\.key))")
        t.amount = amount
        do {
            try Frontmatter.serialize(t).write(to: url, atomically: true, encoding: .utf8)
            print("TESTMODE wrote amount \(amount) to \(url.lastPathComponent)")
            exit(0)
        } catch {
            print("TESTMODE write failed: \(error)"); exit(1)
        }
    }
}

@main
struct ProgressoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = VaultStore()
    @AppStorage("menuBarQuickAdd") private var menuBarQuickAdd = true

    init() {
        Self.migrateClientTrackerDefaults()
        TestMode.runIfRequested()
    }

    /// The app shipped as "ClientTracker" (bundle id com.cj.clienttracker)
    /// before becoming Progresso. Boards, settings, and per-board pages all
    /// live in UserDefaults, which is keyed by bundle id — copy the old
    /// domain over once so nothing is lost on the first Progresso launch.
    private static func migrateClientTrackerDefaults() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: "boardsJSON") == nil,
              let old = defaults.persistentDomain(forName: "com.cj.clienttracker"),
              !old.isEmpty else { return }
        for (key, value) in old { defaults.set(value, forKey: key) }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 860, minHeight: 540)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandMenu("Boards") {
                ForEach(Array(store.boards.prefix(9).enumerated()),
                        id: \.element.id) { index, board in
                    Button(board.name) {
                        store.switchBoard(board)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")),
                                      modifiers: .command)
                }
                Divider()
                Button("Add Board Folder…") { store.addBoardViaPanel() }
            }
        }

        MenuBarExtra("Quick Add Ticket", systemImage: "plus.square.on.square",
                     isInserted: $menuBarQuickAdd) {
            QuickAddView()
                .environmentObject(store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}

/// Mini capture form in the menu bar — add a ticket to any board's first
/// column without switching away from whatever you're doing.
struct QuickAddView: View {
    @EnvironmentObject var store: VaultStore
    @Environment(\.dismiss) private var dismiss

    @State private var boardID: UUID?
    @State private var kind: TicketKind = .client
    @State private var title = ""
    @State private var client = ""
    @State private var type: TicketType = .paid
    @State private var amountText = ""
    @State private var platformsText = ""
    @State private var assignee = ""
    @State private var priority = "normal"
    @State private var justAdded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick Add Ticket").font(.headline)

            Picker("Board", selection: $boardID) {
                ForEach(store.boards) { board in
                    Text(board.name).tag(Optional(board.id))
                }
            }

            Picker("", selection: $kind) {
                ForEach(TicketKind.allCases) { k in
                    Label(k.label, systemImage: k.icon).tag(k)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            TextField(titlePlaceholder, text: $title)
                .textFieldStyle(.roundedBorder)

            switch kind {
            case .client:
                TextField("Client", text: $client)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    Picker("", selection: $type) {
                        Text("Paid").tag(TicketType.paid)
                        Text("Free").tag(TicketType.free)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 120)
                    TextField("Amount", text: $amountText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .disabled(type == .free)
                        .opacity(type == .free ? 0.4 : 1)
                }
            case .content:
                TextField("Platforms (Instagram, TikTok…)", text: $platformsText)
                    .textFieldStyle(.roundedBorder)
                TextField("Assignee", text: $assignee)
                    .textFieldStyle(.roundedBorder)
            case .task:
                Picker("", selection: $priority) {
                    Text("Low").tag("low")
                    Text("Normal").tag("normal")
                    Text("High").tag("high")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                TextField("Assignee", text: $assignee)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                if justAdded {
                    Label("Added", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
                Spacer()
                Button("Add to board") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty
                              || boardID == nil)
            }
        }
        .padding(14)
        .frame(width: 280)
        .onAppear {
            if boardID == nil { boardID = store.activeBoard?.id }
            justAdded = false
        }
    }

    private var titlePlaceholder: String {
        switch kind {
        case .client: return "What's the job?"
        case .content: return "Video idea / working title"
        case .task: return "What needs doing?"
        }
    }

    private func add() {
        guard let boardID else { return }
        store.quickAdd(boardID: boardID,
                       kind: kind,
                       title: title,
                       client: kind == .client ? client : "",
                       type: kind == .client ? type : .free,
                       amount: kind == .client
                           ? Double(amountText.replacingOccurrences(of: ",", with: ".")) ?? 0
                           : 0,
                       platforms: kind == .content
                           ? platformsText.split(separator: ",")
                               .map { $0.trimmingCharacters(in: .whitespaces) }
                               .filter { !$0.isEmpty }
                           : [],
                       assignee: kind == .client ? "" : assignee.trimmingCharacters(in: .whitespaces),
                       priority: kind == .task ? priority : "normal")
        title = ""; client = ""; amountText = ""; platformsText = ""; assignee = ""
        justAdded = true
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: VaultStore
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @AppStorage("defaultCurrency") private var defaultCurrency = "EUR"
    @AppStorage("launchBoardID") private var launchBoardID = ""
    @AppStorage("menuBarQuickAdd") private var menuBarQuickAdd = true
    @AppStorage("liveSync") private var liveSync = true

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearanceMode) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                .onChange(of: appearanceMode) { _, newValue in
                    Appearance.apply(newValue)
                }
            }

            Section("General") {
                TextField("Default currency", text: $defaultCurrency)
                    .frame(width: 220)
                Picker("Start on board", selection: $launchBoardID) {
                    Text("Last used").tag("")
                    ForEach(store.boards) { board in
                        Text(board.name).tag(board.id.uuidString)
                    }
                }
            }

            Section("Obsidian sync") {
                Toggle("Live sync — update the board the moment files change on disk", isOn: $liveSync)
                    .onChange(of: liveSync) { _, newValue in
                        store.setLiveSync(newValue)
                    }
                Text("Off = reload only on ⌘R or when the app becomes active.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Menu bar") {
                Toggle("Show quick-add in the menu bar", isOn: $menuBarQuickAdd)
            }

            Text("Boards and tickets are markdown files in your vault — settings only change how this app behaves.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
