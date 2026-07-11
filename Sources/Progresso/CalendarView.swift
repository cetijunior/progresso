import SwiftUI

/// Full month grid — every ticket date (due/filming/publish, any kind) on
/// the active board merged with Google Calendar events, one glance. Click
/// a day to see what's on it; click a ticket to view it, an event to open
/// it in the browser. Complements the dashboard's 14-day list rather than
/// replacing it — this one you navigate.
struct CalendarView: View {
    @EnvironmentObject var store: VaultStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var gcal = GCalManager.shared
    let onOpenTicket: (Ticket) -> Void

    @State private var displayedMonth = Date()
    @State private var selectedDay = Date()
    @State private var confirmingBulkPush = false

    private let calendar = Calendar.current
    private let dayFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
    private let monthFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "LLLL yyyy"; return f }()
    private let dayTitleFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEEE, MMMM d"; return f }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 0) {
                grid.frame(width: 460)
                Divider()
                dayPanel.frame(width: 280)
            }
        }
        .frame(width: 760, height: 600)
        .onExitCommand { dismiss() }
        .task(id: monthKey) {
            await gcal.refreshEvents(from: gridStart, to: gridEnd)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Calendar — \(store.activeBoard?.name ?? "")")
                .font(.title3.bold())
            Spacer()
            Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain)
            Text(monthFmt.string(from: displayedMonth))
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 130)
            Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.plain)
            Button("Today") { goToday() }
                .font(.caption)
                .controlSize(.small)
            Spacer()
            if gcal.isConnected && !store.calendarPushCandidates.isEmpty {
                Button("Push to Calendar…") { confirmingBulkPush = true }
                    .font(.caption)
                    .controlSize(.small)
                    .help("Create calendar events for every unsynced ticket on this board")
            }
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .confirmationDialog(
            "Create Google Calendar events for \(store.calendarPushCandidates.count) ticket(s) on this board? Dated tickets land on their dates, undated ones on their creation day — and they stay in sync from then on.",
            isPresented: $confirmingBulkPush,
            titleVisibility: .visible
        ) {
            Button("Push \(store.calendarPushCandidates.count) to Calendar") {
                store.pushAllDatesToCalendar()
            }
        }
    }

    // MARK: Grid

    private var grid: some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, s in
                    Text(s)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(monthDays, id: \.self) { day in
                    dayCell(day)
                }
            }
            if !gcal.isConnected {
                Label("Google Calendar not connected — Settings (⌘,).",
                      systemImage: "calendar.badge.exclamationmark")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if let err = gcal.lastError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            legend
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private var legend: some View {
        HStack(spacing: 10) {
            legendDot(.orange, "Unpaid")
            legendDot(.green, "Paid")
            legendDot(.blue, "Free / event")
            legendDot(.purple, "Content")
            legendDot(.gray, "Task")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
        }
    }

    @ViewBuilder
    private func dayCell(_ day: Date) -> some View {
        let key = dayFmt.string(from: day)
        let inMonth = calendar.isDate(day, equalTo: displayedMonth, toGranularity: .month)
        let isToday = calendar.isDateInToday(day)
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
        let dots = dotColors(for: key)

        Button {
            selectedDay = day
            if !inMonth { displayedMonth = day }
        } label: {
            VStack(spacing: 3) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.caption.weight(isToday ? .bold : .regular))
                    .foregroundStyle(inMonth ? (isToday ? Color.accentColor : Color.primary) : Color.secondary)
                HStack(spacing: 2) {
                    ForEach(dots.prefix(3).indices, id: \.self) { i in
                        Circle().fill(dots[i]).frame(width: 4, height: 4)
                    }
                    if dots.count > 3 {
                        Text("+\(dots.count - 3)").font(.system(size: 8)).foregroundStyle(.secondary)
                    }
                }
                .frame(height: 6)
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.18)
                          : Theme(scheme: scheme).tileFill.opacity(inMonth ? 1 : 0.35))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(isToday ? Color.accentColor : .clear, lineWidth: 1.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Day panel

    private var dayPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(dayTitleFmt.string(from: selectedDay))
                .font(.subheadline.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    let (tickets, events) = items(for: selectedDay)
                    if tickets.isEmpty && events.isEmpty {
                        Text("Nothing scheduled.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(tickets.enumerated()), id: \.offset) { _, entry in
                        ticketRow(entry.0, label: entry.1, showDate: false)
                    }
                    ForEach(events) { event in
                        eventRow(event, showDate: false)
                    }

                    // What's coming — the practical "glance" half of the
                    // panel: everything from today forward, nearest first.
                    Divider().padding(.vertical, 4)
                    Text("UPCOMING")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                    let coming = upcoming()
                    if coming.isEmpty {
                        Text("Nothing ahead. Espresso time.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(coming) { row in
                        switch row {
                        case .ticket(let t, _, let label):
                            ticketRow(t, label: label, showDate: true)
                        case .event(let e):
                            eventRow(e, showDate: true)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func ticketRow(_ ticket: Ticket, label: String, showDate: Bool) -> some View {
        Button { onOpenTicket(ticket) } label: {
            HStack(spacing: 6) {
                Image(systemName: ticket.kind.icon)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ticket.title).font(.callout).lineLimit(2)
                    Text(showDate ? "\(label) \(dateFor(ticket, label) ?? "")" : label)
                        .font(.caption2)
                        .foregroundStyle(isOverdueLabel(ticket, label) ? .red : .secondary)
                }
                Spacer(minLength: 0)
                if !ticket.gcalEventIDs.isEmpty {
                    Image(systemName: "calendar.badge.checkmark")
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .help("Synced to Google Calendar")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func eventRow(_ event: GCalEvent, showDate: Bool) -> some View {
        Button {
            if let link = event.htmlLink, let url = URL(string: link) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar").foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title).font(.callout).lineLimit(2)
                    let detail = [showDate ? event.date : "", event.time]
                        .filter { !$0.isEmpty }.joined(separator: " ")
                    if !detail.isEmpty {
                        Text(detail).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Google Calendar event — opens in the browser")
    }

    // MARK: Data

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private var monthKey: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM"
        return f.string(from: displayedMonth)
    }

    /// 42 cells (6 weeks) so every month renders a stable full grid,
    /// leading/trailing days from adjacent months included but dimmed.
    private var monthDays: [Date] {
        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: displayedMonth))
        else { return [] }
        let weekday = calendar.component(.weekday, from: monthStart)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        guard let start = calendar.date(byAdding: .day, value: -leading, to: monthStart) else { return [] }
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private var gridStart: Date { monthDays.first ?? displayedMonth }
    private var gridEnd: Date {
        calendar.date(byAdding: .day, value: 1, to: monthDays.last ?? displayedMonth) ?? displayedMonth
    }

    private enum UpcomingRow: Identifiable {
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

    /// Everything from today forward, nearest first: all ticket dates on
    /// this board plus foreign events from the loaded calendar window.
    private func upcoming(limit: Int = 10) -> [UpcomingRow] {
        let today = Ticket.today()
        var rows: [UpcomingRow] = []
        for t in store.tickets {
            if let d = t.due, d >= today { rows.append(.ticket(t, date: d, label: "due")) }
            if let d = t.filmingDate, d >= today { rows.append(.ticket(t, date: d, label: "filming")) }
            if let d = t.publishDate, d >= today { rows.append(.ticket(t, date: d, label: "publish")) }
        }
        rows += gcal.events
            .filter { $0.date >= today && !$0.isProgresso }
            .map { .event($0) }
        return Array(rows.sorted { $0.sortKey < $1.sortKey }.prefix(limit))
    }

    private func dateFor(_ t: Ticket, _ label: String) -> String? {
        switch label {
        case "due": return t.due
        case "filming": return t.filmingDate
        case "publish": return t.publishDate
        default: return nil
        }
    }

    private func isOverdueLabel(_ t: Ticket, _ label: String) -> Bool {
        label == "due" && t.isOverdue
    }

    private func items(for day: Date) -> (tickets: [(Ticket, String)], events: [GCalEvent]) {
        let key = dayFmt.string(from: day)
        var tickets: [(Ticket, String)] = []
        for t in store.tickets {
            if t.due == key { tickets.append((t, "due")) }
            if t.filmingDate == key { tickets.append((t, "filming")) }
            if t.publishDate == key { tickets.append((t, "publish")) }
        }
        let events = gcal.events.filter { $0.date == key && !$0.isProgresso }
        return (tickets, events)
    }

    private func dotColors(for key: String) -> [Color] {
        var colors: [Color] = []
        for t in store.tickets where t.due == key || t.filmingDate == key || t.publishDate == key {
            colors.append(dotColor(for: t))
        }
        colors += gcal.events.filter { $0.date == key && !$0.isProgresso }.map { _ in Color.blue }
        return colors
    }

    private func dotColor(for ticket: Ticket) -> Color {
        switch ticket.kind {
        case .client: return ticket.type == .free ? .blue : (ticket.paid ? .green : .orange)
        case .content: return .purple
        case .task: return ticket.priority == "high" ? .red : .gray
        }
    }

    private func shiftMonth(_ delta: Int) {
        if let d = calendar.date(byAdding: .month, value: delta, to: displayedMonth) {
            displayedMonth = d
        }
    }

    private func goToday() {
        displayedMonth = Date()
        selectedDay = Date()
    }
}
