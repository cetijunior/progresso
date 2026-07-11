import SwiftUI

/// Business roll-up over data already tracked — no separate entry, ever.
struct DashboardView: View {
    @EnvironmentObject var store: VaultStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var gcal = GCalManager.shared
    let onOpenTicket: (Ticket) -> Void

    /// One merged schedule: ticket dates + foreign Google Calendar events.
    /// Events Progresso created are hidden here — their tickets already
    /// appear as rows (with a blue calendar badge marking them as synced).
    private enum ScheduleRow: Identifiable {
        case ticket(Ticket, date: String, label: String)
        case event(GCalEvent)
        var id: String {
            switch self {
            case .ticket(let t, _, let label): return "t-\(t.id)-\(label)"
            case .event(let e): return "e-\(e.id)"
            }
        }
        var sortKey: String {
            switch self {
            case .ticket(_, let date, _): return date
            case .event(let e): return "\(e.date) \(e.time)"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Dashboard — \(store.activeBoard?.name ?? "")")
                    .font(.title3.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Money
                    HStack(spacing: 10) {
                        stat("Collected", money(store.paidTotal), .green,
                             sub: "this month \(money(store.collectedThisMonth))")
                        stat("Expenses", "−\(money(store.expensesTotal))", .red,
                             sub: "this month −\(money(store.expensesThisMonth))")
                        stat("Net", money(store.netTotal),
                             store.netTotal >= 0 ? .green : .red, sub: "all time")
                        stat("Outstanding", money(store.outstandingTotal), .orange,
                             sub: store.overdueOutstanding > 0
                                ? "overdue \(money(store.overdueOutstanding))" : "nothing overdue")
                    }

                    // Open tickets by kind × column
                    section("Open tickets") {
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                            GridRow {
                                Text("").frame(width: 70, alignment: .leading)
                                ForEach(store.config.columns) { col in
                                    Text(col.name).font(.caption.bold()).foregroundStyle(.secondary)
                                }
                            }
                            ForEach(TicketKind.allCases) { kind in
                                GridRow {
                                    Label(kind.label, systemImage: kind.icon)
                                        .font(.caption)
                                        .frame(width: 70, alignment: .leading)
                                    ForEach(store.config.columns) { col in
                                        let n = store.tickets.filter { $0.kind == kind && $0.status == col.id }.count
                                        Text(n == 0 ? "·" : "\(n)")
                                            .font(.callout.monospacedDigit())
                                            .foregroundStyle(n == 0 ? .quaternary : .primary)
                                    }
                                }
                            }
                        }
                    }

                    // Schedule: ticket dates + Google Calendar, one list
                    section("Upcoming (14 days) & overdue") {
                        if !gcal.isConnected {
                            Label("Google Calendar not connected — Settings (⌘,) to see events here.",
                                  systemImage: "calendar.badge.exclamationmark")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        } else if let err = gcal.lastError {
                            Label(err, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        let rows = scheduleRows()
                        if rows.isEmpty {
                            Text("Nothing due. Breathe.").foregroundStyle(.secondary).font(.callout)
                        }
                        ForEach(rows.prefix(14)) { row in
                            scheduleRowView(row)
                        }
                    }
                }
                .padding(18)
            }
        }
        .frame(width: 620, height: 560)
        .task { await gcal.refreshEvents() }
        // .keyboardShortcut(.cancelAction) alone doesn't receive Escape in
        // these sheets (found in the 2026-07-10 gauntlet) — wire it explicitly.
        .onExitCommand { dismiss() }
    }

    private func scheduleRows() -> [ScheduleRow] {
        var rows: [ScheduleRow] = deadlineItems().map { .ticket($0.0, date: $0.1, label: $0.2) }
        rows += gcal.events.filter { !$0.isProgresso }.map { .event($0) }
        return rows.sorted { $0.sortKey < $1.sortKey }
    }

    @ViewBuilder
    private func scheduleRowView(_ row: ScheduleRow) -> some View {
        switch row {
        case .ticket(let ticket, let date, let label):
            Button {
                onOpenTicket(ticket)
            } label: {
                HStack {
                    Image(systemName: ticket.kind.icon)
                        .foregroundStyle(.secondary)
                    Text(ticket.title).lineLimit(1)
                    if !ticket.gcalEventIDs.isEmpty {
                        Image(systemName: "calendar.badge.checkmark")
                            .font(.caption)
                            .foregroundStyle(.blue)
                            .help("Synced to Google Calendar")
                    }
                    Spacer()
                    Text("\(label) \(date)")
                        .font(.caption)
                        .foregroundStyle(date < Ticket.today() ? .red : .secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case .event(let event):
            Button {
                if let link = event.htmlLink, let url = URL(string: link) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack {
                    Image(systemName: "calendar")
                        .foregroundStyle(.blue)
                    Text(event.title).lineLimit(1)
                    Spacer()
                    Text(event.time.isEmpty ? event.date : "\(event.date) \(event.time)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Google Calendar event — opens in the browser")
        }
    }

    /// (ticket, date, kind-of-date) for due/publish/filming within 14 days or past due.
    private func deadlineItems() -> [(Ticket, String, String)] {
        let today = Ticket.today()
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let horizon = f.string(from: Date().addingTimeInterval(14 * 86_400))
        var out: [(Ticket, String, String)] = []
        for t in store.tickets {
            if let d = t.due, d <= horizon { out.append((t, d, d < today ? "overdue" : "due")) }
            if let p = t.publishDate, p <= horizon, p >= today { out.append((t, p, "publish")) }
            if let fl = t.filmingDate, fl <= horizon, fl >= today { out.append((t, fl, "filming")) }
        }
        return out.sorted { $0.1 < $1.1 }
    }

    @ViewBuilder
    private func stat(_ label: String, _ value: String, _ color: Color, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold()).foregroundStyle(color)
            Text(sub).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme(scheme: scheme).tileFill)
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme(scheme: scheme).tileBorder))
        )
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.bold()).foregroundStyle(.secondary)
            content()
        }
    }

    private func money(_ v: Double) -> String {
        let a = v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
        return "\(a) \(store.mainCurrency)"
    }
}

/// Read-only quick look at a ticket — see everything without entering edit mode.
struct QuickViewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let ticket: Ticket
    let onEdit: (Ticket) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: ticket.kind.icon).foregroundStyle(.secondary)
                Text(ticket.title).font(.title3.bold())
                Spacer()
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    field("Client", ticket.client)
                    if ticket.kind == .client {
                        field("Contract", ticket.contract)
                        field("Deliverable", ticket.deliverable)
                        if ticket.type == .paid {
                            field("Amount", "\(Int(ticket.amount)) \(ticket.currency) — \(ticket.paid ? "paid\(ticket.paidDate.map { " \($0)" } ?? "")" : "unpaid")")
                        }
                    }
                    field("Platforms", ticket.platforms.joined(separator: ", "))
                    field("Pillar", ticket.pillar)
                    field("Assignee", ticket.assignee)
                    field("Filming", ticket.filmingDate ?? "")
                    field("Publish", ticket.publishDate ?? "")
                    if ticket.kind == .task { field("Priority", ticket.priority) }
                    field("Due", ticket.due ?? "")
                    field("Tags", ticket.tags.map { "#\($0)" }.joined(separator: " "))
                    if !ticket.links.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("LINKS").font(.caption2.bold()).foregroundStyle(.secondary)
                            ForEach(ticket.links, id: \.self) { link in
                                if let url = URL(string: link) {
                                    Link(link, destination: url).font(.callout)
                                } else {
                                    Text(link).font(.callout)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                    if !ticket.notes.isEmpty {
                        Text("NOTES").font(.caption2.bold()).foregroundStyle(.secondary)
                            .padding(.top, 6)
                        Text(ticket.notes)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(18)
            }
            Divider()
            HStack {
                Text("\(ticket.id).md").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Edit") { onEdit(ticket) }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 460, height: 480)
        .onExitCommand { dismiss() }
    }

    @ViewBuilder
    private func field(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                    .frame(width: 76, alignment: .trailing)
                Text(value).font(.callout)
            }
        }
    }
}
