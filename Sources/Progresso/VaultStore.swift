import Foundation
import SwiftUI

@MainActor
final class VaultStore: ObservableObject {
    @Published var boards: [BoardLocation] = []
    @Published var activeBoardID: UUID?
    @Published var tickets: [Ticket] = []
    @Published var expenses: [Expense] = []
    @Published var config: BoardConfig = .default
    @Published var lastError: String?

    private let boardsKey = "boardsJSON"
    private let activeKey = "activeBoardID"
    private let legacyPathKey = "vaultFolderPath"

    var activeBoard: BoardLocation? {
        boards.first { $0.id == activeBoardID } ?? boards.first
    }

    var folderURL: URL? {
        guard let board = activeBoard else { return nil }
        return URL(fileURLWithPath: board.path)
    }

    // MARK: - Pages ("book" support): subfolders with their own board-config.json.
    // The board root itself is page "Main" when it has content at the top level.

    @Published var pages: [String] = []
    @Published var activePage: String = "Main"

    /// Where the ACTIVE PAGE's data lives (root for "Main", subfolder otherwise).
    var pageURL: URL? {
        guard let root = folderURL else { return nil }
        return activePage == "Main" ? root
            : root.appendingPathComponent(activePage, isDirectory: true)
    }

    var ticketsDir: URL? { pageURL?.appendingPathComponent("Tickets", isDirectory: true) }
    var expensesDir: URL? { pageURL?.appendingPathComponent("Expenses", isDirectory: true) }
    var configFile: URL? { pageURL?.appendingPathComponent("board-config.json") }

    private func discoverPages() {
        guard let root = folderURL else { pages = []; return }
        let fm = FileManager.default
        var found: [String] = []
        if fm.fileExists(atPath: root.appendingPathComponent("Tickets").path)
            || fm.fileExists(atPath: root.appendingPathComponent("board-config.json").path) {
            found.append("Main")
        }
        if let subs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            for sub in subs where sub.hasDirectoryPath && !sub.lastPathComponent.hasPrefix(".") {
                if fm.fileExists(atPath: sub.appendingPathComponent("board-config.json").path) {
                    found.append(sub.lastPathComponent)
                }
            }
        }
        if found.isEmpty { found = ["Main"] }
        pages = found
        let saved = (UserDefaults.standard.dictionary(forKey: "activePages") as? [String: String])?[activeBoard?.id.uuidString ?? ""]
        activePage = (saved.flatMap { found.contains($0) ? $0 : nil }) ?? found[0]
    }

    func switchPage(_ name: String) {
        guard pages.contains(name), name != activePage else { return }
        activePage = name
        var dict = UserDefaults.standard.dictionary(forKey: "activePages") as? [String: String] ?? [:]
        if let id = activeBoard?.id.uuidString { dict[id] = name }
        UserDefaults.standard.set(dict, forKey: "activePages")
        refresh()
    }

    func addPage(_ name: String) {
        guard let root = folderURL else { return }
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, !pages.contains(clean), clean != "Main" else { return }
        let dir = root.appendingPathComponent(clean, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Tickets"), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(BoardConfig.default) {
            try? data.write(to: dir.appendingPathComponent("board-config.json"))
        }
        discoverPages()
        switchPage(clean)
        gitSyncSoon("add page \(clean)")
    }

    func deletePage(_ name: String) {
        guard name != "Main", let root = folderURL else { return }
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.trashItem(at: dir, resultingItemURL: nil)
        if activePage == name { activePage = "Main" }
        refresh()
        gitSyncSoon("remove page \(name)")
    }

    private var watcher: FolderWatcher?
    @Published var syncState: GitSyncState = .notGit
    private var syncDebounce: DispatchWorkItem?
    private var pullTimer: Timer?

    init() {
        loadBoards()
        refresh()
        updateWatcher()
        updateGitState()
    }

    // MARK: - Git sync (shared boards)

    var activeBoardIsGit: Bool {
        folderURL.map { Git.isRepo($0.path) } ?? false
    }

    func updateGitState() {
        pullTimer?.invalidate()
        pullTimer = nil
        if activeBoardIsGit {
            if case .error = syncState {} else { syncState = .idle }
            gitSync("open board")
            pullTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.gitSync("periodic") }
            }
        } else {
            syncState = .notGit
        }
    }

    /// Debounced sync — called after local edits so rapid changes batch
    /// into one commit.
    func gitSyncSoon(_ message: String) {
        guard activeBoardIsGit else { return }
        syncDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.gitSync(message) }
        syncDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    /// Full cycle: commit local changes → pull --rebase → push → reload.
    /// One ticket = one file keeps conflicts rare; a genuine conflict aborts
    /// the rebase and surfaces as a sync error instead of mangling files.
    func gitSync(_ message: String) {
        guard activeBoardIsGit, let path = folderURL?.path else { return }
        guard syncState != .syncing else { return }
        syncState = .syncing
        let commitMessage = "\(NSFullUserName()): \(message)"
        let boardAtStart = activeBoardID
        Task.detached(priority: .utility) { [weak self] in
            Git.ensureIdentity(in: path)
            _ = Git.run(["add", "-A"], in: path)
            _ = Git.run(["commit", "-m", commitMessage], in: path) // no-op if clean
            let pull = Git.run(["pull", "--rebase", "--autostash"], in: path)
            if !pull.ok {
                _ = Git.run(["rebase", "--abort"], in: path)
            }
            let push = pull.ok ? Git.run(["push"], in: path) : (ok: false, output: pull.output)
            let ok = pull.ok && push.ok
            var detail = ok ? "" : String((pull.ok ? push.output : pull.output).suffix(300))
            if detail.contains("could not read Username") || detail.contains("Authentication failed") {
                detail = "GitHub login needed on this Mac: open Terminal, run `gh auth login` (choose GitHub.com → HTTPS → Login with browser), then press Sync. Original error: \(detail)"
            }
            let finalDetail = detail
            await MainActor.run { [weak self] in
                guard let self else { return }
                // The user may have switched boards while this sync ran —
                // don't stamp another board's UI with our result.
                guard self.activeBoardID == boardAtStart else { return }
                self.syncState = ok ? .idle : .error(finalDetail)
                self.refresh()
            }
        }
    }

    /// Register an already-materialized folder (e.g. a fresh git clone) as a board.
    func addBoard(path: String, name: String) {
        if let existing = boards.first(where: { $0.path == path }) {
            switchBoard(existing)
            return
        }
        let board = BoardLocation(name: name, path: path)
        boards.append(board)
        activeBoardID = board.id
        persistBoards()
        refresh()
        updateWatcher()
        updateGitState()
    }

    // MARK: - Live sync (FSEvents)

    var liveSyncEnabled: Bool {
        UserDefaults.standard.object(forKey: "liveSync") as? Bool ?? true
    }

    func setLiveSync(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "liveSync")
        updateWatcher()
    }

    func updateWatcher() {
        watcher?.stop()
        watcher = nil
        guard liveSyncEnabled, let path = folderURL?.path else { return }
        watcher = FolderWatcher(path: path) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: - Boards (saved folder locations, ⌘1…⌘9)

    private func loadBoards() {
        let defaults = UserDefaults.standard
        if let json = defaults.string(forKey: boardsKey),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([BoardLocation].self, from: data) {
            // Never silently drop boards whose folder isn't reachable right now —
            // iCloud Drive may simply not have mounted yet. Keep them; refresh()
            // surfaces an error for the active one instead of wiping the list.
            boards = decoded
        }
        // Migrate the old single-folder setup into a board entry.
        if boards.isEmpty, let legacy = defaults.string(forKey: legacyPathKey),
           FileManager.default.fileExists(atPath: legacy) {
            let name = URL(fileURLWithPath: legacy).lastPathComponent
            boards = [BoardLocation(name: name, path: legacy)]
        }
        if let idString = defaults.string(forKey: activeKey),
           let id = UUID(uuidString: idString),
           boards.contains(where: { $0.id == id }) {
            activeBoardID = id
        } else {
            activeBoardID = boards.first?.id
        }
        // Settings: start on a specific board instead of the last-used one.
        if let launchID = defaults.string(forKey: "launchBoardID"),
           let id = UUID(uuidString: launchID),
           boards.contains(where: { $0.id == id }) {
            activeBoardID = id
        }
    }

    private func persistBoards() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(boards),
           let json = String(data: data, encoding: .utf8) {
            defaults.set(json, forKey: boardsKey)
        }
        defaults.set(activeBoardID?.uuidString ?? "", forKey: activeKey)
    }

    func switchBoard(_ board: BoardLocation) {
        guard board.id != activeBoardID else { return }
        activeBoardID = board.id
        persistBoards()
        refresh()
        updateWatcher()
        updateGitState()
    }

    func addBoardViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose a board folder (it will get a Tickets/ subfolder and a board-config.json)."
        panel.prompt = "Add Board"
        if panel.runModal() == .OK, let url = panel.url {
            if let existing = boards.first(where: { $0.path == url.path }) {
                switchBoard(existing)   // already registered — just switch to it
                return
            }
            let board = BoardLocation(name: url.lastPathComponent, path: url.path)
            boards.append(board)
            activeBoardID = board.id
            persistBoards()
            refresh()
            updateWatcher()
        }
    }

    func removeBoard(_ board: BoardLocation) {
        boards.removeAll { $0.id == board.id }
        if activeBoardID == board.id { activeBoardID = boards.first?.id }
        persistBoards()
        refresh()
        updateWatcher()
    }

    func renameBoard(_ board: BoardLocation, to name: String) {
        guard let idx = boards.firstIndex(where: { $0.id == board.id }),
              !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        boards[idx].name = name
        persistBoards()
    }

    // MARK: - Load

    func refresh() {
        guard folderURL != nil else {
            tickets = []
            return
        }
        lastError = nil
        discoverPages()
        let fm = FileManager.default

        guard let pageFolder = pageURL, fm.fileExists(atPath: pageFolder.path) || activePage == "Main" else {
            tickets = []
            lastError = "Board folder not reachable right now.\nIf it lives in iCloud Drive it may still be syncing — hit Refresh (⌘R) in a moment."
            return
        }

        // Board config: create default on first run.
        if let cfgURL = configFile {
            if fm.fileExists(atPath: cfgURL.path) {
                do {
                    let data = try Data(contentsOf: cfgURL)
                    config = try JSONDecoder().decode(BoardConfig.self, from: data)
                    if config.columns.isEmpty { config = .default }
                } catch {
                    lastError = "board-config.json unreadable: \(error.localizedDescription)"
                    config = .default
                }
            } else {
                config = .default
                saveConfig()
            }
        }

        guard let dir = ticketsDir else { return }
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        do {
            let files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "md" }
            var loaded: [Ticket] = []
            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8)
                if let t = Frontmatter.parseTicket(text: text, fileURL: file) {
                    loaded.append(t)
                }
            }
            let sorted = loaded.sorted { $0.created > $1.created }
            // Only publish when something actually changed — background
            // git syncs and self-triggered FSEvents otherwise rebuild the
            // board constantly and interrupt in-flight clicks and edits.
            if sorted != tickets {
                tickets = sorted
            }
        } catch {
            lastError = "Could not read tickets: \(error.localizedDescription)"
        }

        // Expenses (folder is optional — created on first expense).
        var loadedExpenses: [Expense] = []
        if let eDir = expensesDir, fm.fileExists(atPath: eDir.path),
           let files = try? fm.contentsOfDirectory(at: eDir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension.lowercased() == "md" {
                if let text = try? String(contentsOf: file, encoding: .utf8),
                   let e = Frontmatter.parseExpense(text: text, fileURL: file) {
                    loadedExpenses.append(e)
                }
            }
        }
        let sortedExpenses = loadedExpenses.sorted { $0.date > $1.date }
        if sortedExpenses != expenses {
            expenses = sortedExpenses
        }
    }

    // MARK: - Expenses

    func saveExpense(_ expense: Expense) {
        var e = expense
        guard let dir = expensesDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if e.fileURL == nil {
            let base = Self.slugify("\(e.date)-\(e.vendor.isEmpty ? e.category : e.vendor)")
            var candidate = base.isEmpty ? "expense" : base
            var url = dir.appendingPathComponent("\(candidate).md")
            var n = 2
            while FileManager.default.fileExists(atPath: url.path) {
                candidate = "\(base)-\(n)"
                url = dir.appendingPathComponent("\(candidate).md")
                n += 1
            }
            e.id = candidate
            e.fileURL = url
        }
        do {
            try Frontmatter.serialize(e).write(to: e.fileURL!, atomically: true, encoding: .utf8)
            if let idx = expenses.firstIndex(where: { $0.id == e.id }) {
                expenses[idx] = e
            } else {
                expenses.insert(e, at: 0)
                expenses.sort { $0.date > $1.date }
            }
            gitSyncSoon("expense \(e.vendor.isEmpty ? e.category : e.vendor)")
        } catch {
            lastError = "Could not save expense: \(error.localizedDescription)"
        }
    }

    func deleteExpense(_ expense: Expense) {
        if let url = expense.fileURL {
            do { try FileManager.default.removeItem(at: url) }
            catch {
                lastError = "Could not delete expense: \(error.localizedDescription)"
                return
            }
        }
        expenses.removeAll { $0.id == expense.id }
        gitSyncSoon("remove expense")
    }

    var expensesTotal: Double { expenses.reduce(0) { $0 + $1.amount } }

    var expensesThisMonth: Double {
        let month = String(Ticket.today().prefix(7))
        return expenses.filter { $0.date.hasPrefix(month) }.reduce(0) { $0 + $1.amount }
    }

    /// Simple all-time P/L: collected income minus logged expenses.
    var netTotal: Double { paidTotal - expensesTotal }

    var expenseCategories: [String] {
        Array(Set(expenses.map(\.category).filter { !$0.isEmpty })).sorted()
    }

    var vendors: [String] {
        Array(Set(expenses.map(\.vendor).filter { !$0.isEmpty })).sorted()
    }

    var assignees: [String] {
        Array(Set(tickets.map(\.assignee).filter { !$0.isEmpty })).sorted()
    }

    var allPlatforms: [String] {
        let used = Set(tickets.flatMap(\.platforms))
        return Array(used.union(["Instagram", "TikTok", "YouTube", "LinkedIn", "X"])).sorted()
    }

    // MARK: - Save / create / delete

    func save(_ ticket: Ticket) {
        var t = ticket
        guard let dir = ticketsDir else { return }
        if t.fileURL == nil {
            let slug = Self.slugify("\(t.created)-\(t.title)")
            var candidate = slug.isEmpty ? "ticket" : slug
            var url = dir.appendingPathComponent("\(candidate).md")
            var n = 2
            while FileManager.default.fileExists(atPath: url.path) {
                candidate = "\(slug)-\(n)"
                url = dir.appendingPathComponent("\(candidate).md")
                n += 1
            }
            t.id = candidate
            t.fileURL = url
        }
        do {
            try Frontmatter.serialize(t).write(to: t.fileURL!, atomically: true, encoding: .utf8)
            if let idx = tickets.firstIndex(where: { $0.id == t.id }) {
                tickets[idx] = t
            } else {
                tickets.insert(t, at: 0)
            }
            gitSyncSoon(t.title)
            calendarSyncSoon(t)
        } catch {
            lastError = "Could not save '\(t.title)': \(error.localizedDescription)"
        }
    }

    // MARK: - Google Calendar push (never blocks saving — the file is
    // already on disk; a failed push only lights the sidebar indicator)

    func calendarSyncSoon(_ ticket: Ticket) {
        // Worth a network call only if sync is on, or was on (stale events
        // to clean up after the toggle went off / dates were removed).
        guard ticket.gcalSync || !ticket.gcalEventIDs.isEmpty else { return }
        guard GCalManager.shared.isConnected else { return }
        Task { @MainActor in
            do {
                let updated = try await GCalManager.shared.syncEvents(for: ticket)
                // Persist newly learned event IDs (direct write — not save(),
                // which would loop back here).
                if updated.gcalEventIDs != ticket.gcalEventIDs, let url = updated.fileURL {
                    try? Frontmatter.serialize(updated).write(to: url, atomically: true, encoding: .utf8)
                    if let idx = tickets.firstIndex(where: { $0.id == updated.id }) {
                        tickets[idx] = updated
                    }
                }
            } catch {
                GCalManager.shared.recordSyncFailure(ticket, error: error)
            }
        }
    }

    func retryCalendarSyncs() {
        for id in GCalManager.shared.failedSyncs.keys {
            if let t = tickets.first(where: { $0.id == id }) {
                calendarSyncSoon(t)
            } else {
                GCalManager.shared.failedSyncs.removeValue(forKey: id)
            }
        }
    }

    func delete(_ ticket: Ticket) {
        if let url = ticket.fileURL {
            do { try FileManager.default.removeItem(at: url) }
            catch {
                lastError = "Could not delete file: \(error.localizedDescription)"
                return
            }
        }
        tickets.removeAll { $0.id == ticket.id }
        gitSyncSoon("remove \(ticket.title)")
        if !ticket.gcalEventIDs.isEmpty {
            let ids = Array(ticket.gcalEventIDs.values)
            Task { await GCalManager.shared.deleteEvents(ids: ids) }
        }
    }

    func moveTicket(id: String, toColumn columnID: String) {
        guard var t = tickets.first(where: { $0.id == id }), t.status != columnID else { return }
        t.status = columnID
        save(t)
    }

    func togglePaid(_ ticket: Ticket) {
        var t = ticket
        t.paid.toggle()
        t.paidDate = t.paid ? Ticket.today() : nil
        save(t)
    }

    /// Create a ticket on ANY board (menu-bar quick add) without switching to it.
    func quickAdd(boardID: UUID, kind: TicketKind = .client, title: String, client: String,
                  type: TicketType, amount: Double,
                  platforms: [String] = [], assignee: String = "", priority: String = "normal") {
        guard let board = boards.first(where: { $0.id == boardID }) else { return }
        var root = URL(fileURLWithPath: board.path)
        // Respect that board's active page.
        if let page = (UserDefaults.standard.dictionary(forKey: "activePages") as? [String: String])?[board.id.uuidString],
           page != "Main" {
            root = root.appendingPathComponent(page, isDirectory: true)
        }
        let dir = root.appendingPathComponent("Tickets", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // First column of THAT board's config, not the active one's.
        var status = "backlog"
        if let data = try? Data(contentsOf: root.appendingPathComponent("board-config.json")),
           let cfg = try? JSONDecoder().decode(BoardConfig.self, from: data),
           let first = cfg.columns.first {
            status = first.id
        }

        var t = Ticket.blank(status: status)
        t.kind = kind
        t.title = title
        t.client = client.trimmingCharacters(in: .whitespaces)
        t.type = type
        t.amount = amount
        t.platforms = platforms
        t.assignee = assignee
        t.priority = priority

        let slug = Self.slugify("\(t.created)-\(t.title)")
        var candidate = slug.isEmpty ? "ticket" : slug
        var url = dir.appendingPathComponent("\(candidate).md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            candidate = "\(slug)-\(n)"
            url = dir.appendingPathComponent("\(candidate).md")
            n += 1
        }
        t.id = candidate
        t.fileURL = url
        do {
            try Frontmatter.serialize(t).write(to: url, atomically: true, encoding: .utf8)
            if board.id == activeBoard?.id { refresh() }
        } catch {
            lastError = "Quick add failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Columns

    func saveConfig() {
        guard let url = configFile else { return }
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted]
            try enc.encode(config).write(to: url, options: .atomic)
        } catch {
            lastError = "Could not save board-config.json: \(error.localizedDescription)"
        }
        gitSyncSoon("columns")
    }

    /// Deletes a column; tickets still in it are moved to `fallback`.
    func deleteColumn(_ id: String, movingTicketsTo fallback: String) {
        for t in tickets where t.status == id {
            moveTicket(id: t.id, toColumn: fallback)
        }
        config.columns.removeAll { $0.id == id }
        saveConfig()
    }

    // MARK: - Derived

    var clients: [String] {
        Array(Set(tickets.map(\.client).filter { !$0.isEmpty })).sorted()
    }

    var allTags: [String] {
        Array(Set(tickets.flatMap(\.tags))).sorted()
    }

    var outstandingTotal: Double {
        tickets.filter { $0.type == .paid && !$0.paid }.reduce(0) { $0 + $1.amount }
    }

    var paidTotal: Double {
        tickets.filter { $0.type == .paid && $0.paid }.reduce(0) { $0 + $1.amount }
    }

    var freeCount: Int {
        tickets.filter { $0.type == .free }.count
    }

    /// Unpaid money already past its due date.
    var overdueOutstanding: Double {
        tickets.filter { $0.type == .paid && !$0.paid && $0.isOverdue }
            .reduce(0) { $0 + $1.amount }
    }

    /// Money marked paid during the current calendar month (needs paid_date,
    /// which the app stamps automatically when a ticket is marked paid).
    var collectedThisMonth: Double {
        let month = String(Ticket.today().prefix(7))   // yyyy-MM
        return tickets
            .filter { $0.type == .paid && $0.paid && ($0.paidDate?.hasPrefix(month) ?? false) }
            .reduce(0) { $0 + $1.amount }
    }

    /// Who owes what, largest first.
    var outstandingByClient: [(client: String, amount: Double)] {
        Dictionary(grouping: tickets.filter { $0.type == .paid && !$0.paid && $0.amount > 0 },
                   by: \.client)
            .map { (($0.key.isEmpty ? "(no client)" : $0.key),
                    $0.value.reduce(0) { $0 + $1.amount }) }
            .sorted { $0.1 > $1.1 }
    }

    var mainCurrency: String {
        let counts = Dictionary(grouping: tickets.filter { $0.type == .paid }, by: \.currency)
        return counts.max { $0.value.count < $1.value.count }?.key ?? "EUR"
    }

    static func slugify(_ s: String) -> String {
        let lowered = s.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
        let mapped = lowered.map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : "-"
        }
        var out = ""
        var lastDash = false
        for ch in mapped {
            if ch == "-" {
                if !lastDash { out.append(ch) }
                lastDash = true
            } else {
                out.append(ch)
                lastDash = false
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
