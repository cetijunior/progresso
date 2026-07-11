import SwiftUI

/// Single presentation enum — attaching multiple .sheet modifiers to one view
/// silently drops all but the last, which is what broke ticket creation in v1.
enum ActiveSheet: Identifiable {
    case create(inColumn: String)
    case edit(Ticket)
    case columns
    case cloneBoard
    case expenses
    case dashboard
    case calendar
    case view(Ticket)

    var id: String {
        switch self {
        case .create: return "create"
        case .edit(let t): return "edit-\(t.id)"
        case .columns: return "columns"
        case .cloneBoard: return "clone"
        case .expenses: return "expenses"
        case .dashboard: return "dashboard"
        case .calendar: return "calendar"
        case .view(let t): return "view-\(t.id)"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: VaultStore
    @AppStorage("sidebarPosition") private var sidebarPosition = "left"

    @State private var searchText = ""
    @State private var clientFilter: String?
    @State private var tagFilter: Set<String> = []
    @State private var payFilter: PayFilter = .all
    @State private var activeSheet: ActiveSheet?

    /// The board area shared by both sidebar layouts.
    private var boardDetail: some View {
        VStack(spacing: 0) {
            PageTabs()
            BoardView(tickets: filteredTickets,
                      onEdit: { activeSheet = .edit($0) },
                      onView: { activeSheet = .view($0) },
                      onCreate: { activeSheet = .create(inColumn: $0) })
        }
        .navigationTitle(store.activeBoard?.name ?? "Board")
        .navigationSubtitle(subtitle)
    }

    var body: some View {
        Group {
            if store.boards.isEmpty {
                WelcomeView()
            } else if sidebarPosition == "right" {
                // NavigationSplitView can't put its sidebar trailing on
                // macOS (layout-direction mirroring is ignored), so the
                // right-hand mode is a plain HSplitView.
                HSplitView {
                    boardDetail
                        .frame(minWidth: 500, maxWidth: .infinity)
                    SidebarView(clientFilter: $clientFilter,
                                tagFilter: $tagFilter,
                                payFilter: $payFilter,
                                onCloneBoard: { activeSheet = .cloneBoard })
                        .frame(minWidth: 210, idealWidth: 230, maxWidth: 320)
                }
            } else {
                NavigationSplitView {
                    SidebarView(clientFilter: $clientFilter,
                                tagFilter: $tagFilter,
                                payFilter: $payFilter,
                                onCloneBoard: { activeSheet = .cloneBoard })
                } detail: {
                    boardDetail
                }
            }
        }
        .toolbar {
            if !store.boards.isEmpty {
                ToolbarItemGroup {
                    TextField("Search…", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                    Button {
                        activeSheet = .create(
                            inColumn: store.config.columns.first?.id ?? "backlog")
                    } label: { Label("New Ticket", systemImage: "plus") }
                        .keyboardShortcut("n", modifiers: .command)
                        .help("New ticket (⌘N)")
                    Button {
                        activeSheet = .calendar
                    } label: { Label("Calendar", systemImage: "calendar") }
                        .help("Full calendar view")
                    Button {
                        activeSheet = .dashboard
                    } label: { Label("Dashboard", systemImage: "chart.bar.xaxis") }
                        .help("Business dashboard")
                    Button {
                        activeSheet = .expenses
                    } label: { Label("Expenses", systemImage: "banknote") }
                        .help("Expense log for this board")
                    Button {
                        activeSheet = .columns
                    } label: { Label("Columns", systemImage: "slider.horizontal.3") }
                        .help("Edit board columns")
                    Button {
                        store.refresh()
                    } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .keyboardShortcut("r", modifiers: .command)
                        .help("Reload from disk (⌘R)")
                }
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .create(let column):
                TicketEditorView(ticket: .blank(status: column), isNew: true)
            case .edit(let ticket):
                TicketEditorView(ticket: ticket, isNew: false)
            case .columns:
                ColumnManagerView()
            case .cloneBoard:
                CloneBoardView()
            case .expenses:
                ExpensesView()
            case .dashboard:
                DashboardView(onOpenTicket: { activeSheet = .view($0) })
            case .calendar:
                CalendarView(onOpenTicket: { activeSheet = .view($0) })
            case .view(let ticket):
                QuickViewSheet(ticket: ticket, onEdit: { activeSheet = .edit($0) })
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refresh()
            store.gitSync("focus")
        }
        .alert("Error", isPresented: .init(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private var subtitle: String {
        var parts: [String] = ["\(filteredTickets.count) tickets"]
        if let c = clientFilter { parts.append(c) }
        if !tagFilter.isEmpty { parts.append(tagFilter.map { "#\($0)" }.joined(separator: " ")) }
        return parts.joined(separator: " · ")
    }

    private var filteredTickets: [Ticket] {
        store.tickets.filter { t in
            if let c = clientFilter, t.client != c { return false }
            if !tagFilter.isEmpty, tagFilter.isDisjoint(with: t.tags) { return false }
            switch payFilter {
            case .paid: if t.type != .paid { return false }
            case .free: if t.type != .free { return false }
            case .all: break
            }
            if !searchText.isEmpty {
                let q = searchText.lowercased()
                if !t.title.lowercased().contains(q) && !t.notes.lowercased().contains(q)
                    && !t.client.lowercased().contains(q) {
                    return false
                }
            }
            return true
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject var store: VaultStore

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Progresso").font(.title2).bold()
            Text("Add a board folder from your Obsidian vault.\nTickets are plain .md files — the folder is the database.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Add Board Folder…") { store.addBoardViaPanel() }
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SidebarView: View {
    @EnvironmentObject var store: VaultStore
    @ObservedObject private var gcal = GCalManager.shared
    @Binding var clientFilter: String?
    @Binding var tagFilter: Set<String>
    @Binding var payFilter: PayFilter
    var onCloneBoard: () -> Void = {}

    var body: some View {
        List {
            Section("Boards") {
                ForEach(Array(store.boards.enumerated()), id: \.element.id) { index, board in
                    Button {
                        store.switchBoard(board)
                        clientFilter = nil
                        tagFilter = []
                    } label: {
                        HStack {
                            Image(systemName: board.id == store.activeBoard?.id
                                  ? "square.stack.3d.up.fill" : "square.stack.3d.up")
                                .foregroundStyle(board.id == store.activeBoard?.id
                                                 ? Color.accentColor : .secondary)
                            Text(board.name)
                                .fontWeight(board.id == store.activeBoard?.id ? .semibold : .regular)
                            Spacer()
                            if index < 9 {
                                Text("⌘\(index + 1)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [URL(fileURLWithPath: board.path)])
                        }
                        Button("Remove from list", role: .destructive) {
                            store.removeBoard(board)
                        }
                    }
                }
                Button {
                    store.addBoardViaPanel()
                } label: {
                    Label("Add Board…", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Button {
                    onCloneBoard()
                } label: {
                    Label("Clone Shared Board…", systemImage: "arrow.triangle.branch")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                // Calendar pushes that didn't go through — non-blocking,
                // but visible, with a one-click retry.
                if !gcal.failedSyncs.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar.badge.exclamationmark")
                            .foregroundStyle(.orange)
                        Text("\(gcal.failedSyncs.count) calendar sync\(gcal.failedSyncs.count == 1 ? "" : "s") failed")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help(gcal.failedSyncs.values.joined(separator: "\n"))
                        Spacer()
                        Button("Retry") { store.retryCalendarSyncs() }
                            .font(.caption2)
                            .controlSize(.small)
                    }
                }

                if store.syncState != .notGit {
                    HStack(spacing: 6) {
                        switch store.syncState {
                        case .syncing:
                            ProgressView().controlSize(.mini)
                            Text("Syncing…").font(.caption2).foregroundStyle(.secondary)
                        case .error(let detail):
                            Image(systemName: "exclamationmark.icloud.fill")
                                .foregroundStyle(.red)
                            Text("Sync error").font(.caption2).foregroundStyle(.red)
                                .help(detail)
                        default:
                            Image(systemName: "checkmark.icloud")
                                .foregroundStyle(.green)
                            Text("Synced").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Sync") { store.gitSync("manual") }
                            .font(.caption2)
                            .controlSize(.small)
                    }
                }
            }

            Section("Show") {
                Picker("", selection: $payFilter) {
                    ForEach(PayFilter.allCases) { f in Text(f.rawValue).tag(f) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if !store.clients.isEmpty {
                Section("Clients") {
                    ForEach(store.clients, id: \.self) { client in
                        Button {
                            clientFilter = (clientFilter == client) ? nil : client
                        } label: {
                            HStack {
                                Circle()
                                    .fill(clientColor(client))
                                    .frame(width: 8, height: 8)
                                Text(client)
                                Spacer()
                                Text("\(store.tickets.filter { $0.client == client }.count)")
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .fontWeight(clientFilter == client ? .bold : .regular)
                    }
                }
            }

            if !store.allTags.isEmpty {
                Section("Tags") {
                    ForEach(store.allTags, id: \.self) { tag in
                        Toggle(isOn: .init(
                            get: { tagFilter.contains(tag) },
                            set: { on in
                                if on { tagFilter.insert(tag) } else { tagFilter.remove(tag) }
                            })) {
                            Text("#\(tag)")
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }

            Section("Money") {
                LabeledContent("Outstanding") {
                    Text(money(store.outstandingTotal))
                        .foregroundStyle(store.outstandingTotal > 0 ? .orange : .secondary)
                        .bold(store.outstandingTotal > 0)
                }
                if store.overdueOutstanding > 0 {
                    LabeledContent("↳ overdue") {
                        Text(money(store.overdueOutstanding))
                            .foregroundStyle(.red).bold()
                    }
                }
                LabeledContent("Collected") {
                    Text(money(store.paidTotal)).foregroundStyle(.green)
                }
                if store.collectedThisMonth > 0 {
                    LabeledContent("↳ this month") {
                        Text(money(store.collectedThisMonth))
                            .foregroundStyle(.green)
                    }
                }
                if store.expensesTotal > 0 {
                    LabeledContent("Expenses") {
                        Text("−\(money(store.expensesTotal))")
                            .foregroundStyle(.red)
                    }
                    LabeledContent("Net") {
                        Text(money(store.netTotal))
                            .foregroundStyle(store.netTotal >= 0 ? .green : .red)
                            .bold()
                    }
                }
                LabeledContent("Free jobs", value: "\(store.freeCount)")
            }

            if !store.outstandingByClient.isEmpty {
                Section("Who owes what") {
                    ForEach(store.outstandingByClient.prefix(5), id: \.client) { entry in
                        HStack {
                            Circle().fill(clientColor(entry.client))
                                .frame(width: 6, height: 6)
                            Text(entry.client).lineLimit(1)
                            Spacer()
                            Text(money(entry.amount))
                                .foregroundStyle(.orange)
                                .font(.caption.weight(.semibold))
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 210)
    }

    private func money(_ v: Double) -> String {
        let amount = v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
        return "\(amount) \(store.mainCurrency)"
    }
}

/// Clone a git-hosted shared board (e.g. a private GitHub repo the agency
/// shares) into Application Support and register it as a board.
struct CloneBoardView: View {
    @EnvironmentObject var store: VaultStore
    @Environment(\.dismiss) private var dismiss

    @State private var urlString = ""
    @State private var working = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clone Shared Board").font(.headline)
            Text("Paste the repo URL your team shares (GitHub/GitLab, or any git URL). The board is cloned locally and kept in sync automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("https://github.com/your-team/board.git", text: $urlString)
                .textFieldStyle(.roundedBorder)
            if let errorText {
                ScrollView {
                    Text(errorText)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 80)
            }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(working ? "Cloning…" : "Clone") { clone() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || urlString.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 440)
    }

    private func clone() {
        let url = urlString.trimmingCharacters(in: .whitespaces)
        var name = url.components(separatedBy: "/").last ?? "shared-board"
        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        if name.isEmpty { name = "shared-board" }

        // Old clones under ClientTracker/Boards keep working — boards are
        // registered by absolute path; only NEW clones land here.
        let parent = FileManager.default.urls(for: .applicationSupportDirectory,
                                              in: .userDomainMask)[0]
            .appendingPathComponent("Progresso/Boards", isDirectory: true)
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        var dest = parent.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = parent.appendingPathComponent("\(name)-\(n)")
            n += 1
        }

        working = true
        errorText = nil
        let destPath = dest.path
        let boardName = name
        Task.detached {
            let result = Git.run(["clone", url, destPath], in: parent.path)
            await MainActor.run {
                working = false
                if result.ok {
                    store.addBoard(path: destPath, name: boardName)
                    dismiss()
                } else {
                    errorText = result.output
                }
            }
        }
    }
}

/// Stable pastel color per client name (used for sidebar dots + card accents).
func clientColor(_ name: String) -> Color {
    let palette: [Color] = [.blue, .purple, .teal, .pink, .indigo, .mint, .cyan, .brown]
    guard !name.isEmpty else { return .gray }
    let idx = abs(name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % palette.count
    return palette[idx]
}
