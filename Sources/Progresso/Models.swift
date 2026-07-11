import Foundation

enum TicketType: String, Codable, CaseIterable, Identifiable {
    case paid, free
    var id: String { rawValue }
}

/// What a ticket IS — drives which fields the editor shows and how the
/// card renders. Files without `kind:` read as .client (all pre-existing
/// tickets), so no migration is ever needed.
enum TicketKind: String, Codable, CaseIterable, Identifiable {
    case client, content, task
    var id: String { rawValue }

    var label: String {
        switch self {
        case .client: return "Client"
        case .content: return "Content"
        case .task: return "Task"
        }
    }

    var icon: String {
        switch self {
        case .client: return "briefcase"
        case .content: return "video"
        case .task: return "checklist"
        }
    }
}

enum ContractType: String, CaseIterable, Identifiable {
    case none = "", retainer = "retainer", oneTime = "one-time", project = "project"
    var id: String { rawValue }
    var label: String { rawValue.isEmpty ? "—" : rawValue }
}

enum TaskPriority: String, CaseIterable, Identifiable {
    case low, normal, high
    var id: String { rawValue }
}

struct Ticket: Identifiable, Equatable {
    var id: String                 // filename stem, also `id:` frontmatter
    var title: String
    var client: String
    var type: TicketType
    var amount: Double
    var currency: String
    var paid: Bool
    var status: String
    var tags: [String]
    var created: String            // yyyy-MM-dd
    var due: String?               // yyyy-MM-dd
    var paidDate: String?          // yyyy-MM-dd, stamped when marked paid
    var notes: String
    var fileURL: URL?
    // Type-specific fields (all optional in frontmatter — absent keys are
    // simply not written, so old files stay byte-compatible).
    var kind: TicketKind = .client
    var contract: String = ""          // client: retainer / one-time / project
    var platforms: [String] = []       // client + content: Instagram, TikTok…
    var deliverable: String = ""       // client: what's being delivered
    var pillar: String = ""            // content: content pillar/category
    var assignee: String = ""          // content + task: who owns it
    var filmingDate: String?           // content, yyyy-MM-dd
    var publishDate: String?           // content, yyyy-MM-dd
    var priority: String = "normal"    // task: low / normal / high
    var links: [String] = []           // any kind: URLs (footage, drafts, docs)
    // Unknown frontmatter keys (from Obsidian/LLM edits) preserved on save.
    var extra: [(key: String, value: String)] = []

    /// Full-field equality: refresh() uses it to skip publishing when a
    /// reload produced identical data, so background syncs don't rebuild
    /// the board (and steal clicks/focus) for nothing.
    static func == (lhs: Ticket, rhs: Ticket) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.client == rhs.client
        && lhs.type == rhs.type && lhs.amount == rhs.amount
        && lhs.currency == rhs.currency && lhs.paid == rhs.paid
        && lhs.status == rhs.status && lhs.tags == rhs.tags
        && lhs.created == rhs.created && lhs.due == rhs.due
        && lhs.paidDate == rhs.paidDate && lhs.notes == rhs.notes
        && lhs.kind == rhs.kind && lhs.contract == rhs.contract
        && lhs.platforms == rhs.platforms && lhs.deliverable == rhs.deliverable
        && lhs.pillar == rhs.pillar && lhs.assignee == rhs.assignee
        && lhs.filmingDate == rhs.filmingDate && lhs.publishDate == rhs.publishDate
        && lhs.priority == rhs.priority && lhs.links == rhs.links
        && lhs.extra.map(\.key) == rhs.extra.map(\.key)
        && lhs.extra.map(\.value) == rhs.extra.map(\.value)
    }

    static func blank(status: String, kind: TicketKind = .client) -> Ticket {
        let currency = UserDefaults.standard.string(forKey: "defaultCurrency") ?? "EUR"
        var t = Ticket(id: "", title: "", client: "", type: .paid, amount: 0,
                       currency: currency.isEmpty ? "EUR" : currency,
                       paid: false, status: status, tags: [],
                       created: Ticket.today(), due: nil, paidDate: nil,
                       notes: "", fileURL: nil)
        t.kind = kind
        if kind != .client { t.type = .free }   // content/tasks aren't billable
        return t
    }

    static func today() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    var isOverdue: Bool {
        guard let due, !due.isEmpty else { return false }
        return due < Ticket.today()
    }
}

struct BoardColumn: Identifiable, Codable, Equatable {
    var id: String
    var name: String
}

struct BoardConfig: Codable, Equatable {
    var columns: [BoardColumn]

    static let `default` = BoardConfig(columns: [
        BoardColumn(id: "backlog", name: "Backlog"),
        BoardColumn(id: "planning", name: "Planning"),
        BoardColumn(id: "working", name: "Working"),
        BoardColumn(id: "review", name: "Review"),
        BoardColumn(id: "done", name: "Done"),
    ])
}

/// A saved board folder (e.g. Client Work, Nacut, Brand Content).
/// Switchable from the sidebar or with ⌘1…⌘9.
struct BoardLocation: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var path: String
}

enum PayFilter: String, CaseIterable, Identifiable {
    case all = "All", paid = "Paid", free = "Free"
    var id: String { rawValue }
}

/// One expense entry — its own markdown file in `<board>/Expenses/`,
/// deliberately NOT a ticket: money out, not work to move across columns.
struct Expense: Identifiable, Equatable {
    var id: String                  // filename stem
    var date: String                // yyyy-MM-dd
    var category: String            // software, ads, contractor, equipment…
    var amount: Double
    var currency: String
    var vendor: String
    var client: String              // optional link to a client/project ("" = none)
    var recurring: Bool
    var receipt: String             // optional URL/path ("" = none)
    var notes: String
    var fileURL: URL?

    static func == (lhs: Expense, rhs: Expense) -> Bool {
        lhs.id == rhs.id && lhs.date == rhs.date && lhs.category == rhs.category
        && lhs.amount == rhs.amount && lhs.currency == rhs.currency
        && lhs.vendor == rhs.vendor && lhs.client == rhs.client
        && lhs.recurring == rhs.recurring && lhs.receipt == rhs.receipt
        && lhs.notes == rhs.notes
    }

    static func blank() -> Expense {
        let currency = UserDefaults.standard.string(forKey: "defaultCurrency") ?? "EUR"
        return Expense(id: "", date: Ticket.today(), category: "", amount: 0,
                       currency: currency.isEmpty ? "EUR" : currency,
                       vendor: "", client: "", recurring: false, receipt: "",
                       notes: "", fileURL: nil)
    }
}
