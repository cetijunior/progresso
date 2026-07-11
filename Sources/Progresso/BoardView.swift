import SwiftUI

struct BoardView: View {
    @EnvironmentObject var store: VaultStore
    @Environment(\.colorScheme) private var scheme
    let tickets: [Ticket]
    let onEdit: (Ticket) -> Void
    var onView: (Ticket) -> Void = { _ in }
    let onCreate: (String) -> Void   // column id

    // Deletion confirmation lives HERE, not on each card: presentation
    // modifiers inside ForEach rows silently lose their button actions
    // when the row is recreated (same failure class as the stacked
    // .sheet bug in ContentView).
    @State private var ticketPendingDelete: Ticket?

    var body: some View {
        GeometryReader { geo in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(store.config.columns) { column in
                        ColumnView(column: column,
                                   tickets: tickets.filter { $0.status == column.id },
                                   onEdit: onEdit,
                                   onView: onView,
                                   onCreate: onCreate,
                                   onDelete: { ticketPendingDelete = $0 },
                                   width: columnWidth(available: geo.size.width))
                    }
                    if !unsorted.isEmpty {
                        ColumnView(column: BoardColumn(id: "__unsorted__", name: "Unsorted"),
                                   tickets: unsorted,
                                   onEdit: onEdit,
                                   onView: onView,
                                   onCreate: onCreate,
                                   onDelete: { ticketPendingDelete = $0 },
                                   width: columnWidth(available: geo.size.width),
                                   isVirtual: true)
                    }
                }
                .padding(10)
                .frame(minHeight: geo.size.height)
            }
        }
        .background(Theme(scheme: scheme).boardBackground)
        .confirmationDialog(
            "Delete “\(ticketPendingDelete?.title ?? "")”? The .md file will be removed.",
            isPresented: .init(
                get: { ticketPendingDelete != nil },
                set: { if !$0 { ticketPendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete File", role: .destructive) {
                if let t = ticketPendingDelete { store.delete(t) }
                ticketPendingDelete = nil
            }
        }
    }

    /// Columns flex to fill the window; never narrower than 230 pt.
    private func columnWidth(available: CGFloat) -> CGFloat {
        let count = CGFloat(max(store.config.columns.count + (unsorted.isEmpty ? 0 : 1), 1))
        let flexible = (available - 20 - (count - 1) * 10) / count
        return max(230, flexible)
    }

    /// Tickets whose status matches no configured column (e.g. hand-edited
    /// in Obsidian) — shown, not hidden.
    private var unsorted: [Ticket] {
        let known = Set(store.config.columns.map(\.id))
        return tickets.filter { !known.contains($0.status) }
    }
}

struct ColumnView: View {
    @EnvironmentObject var store: VaultStore
    @Environment(\.colorScheme) private var scheme
    let column: BoardColumn
    let tickets: [Ticket]
    let onEdit: (Ticket) -> Void
    var onView: (Ticket) -> Void = { _ in }
    let onCreate: (String) -> Void
    let onDelete: (Ticket) -> Void
    let width: CGFloat
    var isVirtual = false

    @State private var isTargeted = false
    @State private var hoveringHeader = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(column.name)
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                Text("\(tickets.count)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
                Spacer()
                if !isVirtual {
                    Button {
                        onCreate(column.id)
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(hoveringHeader ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("New ticket in \(column.name)")
                }
            }
            .padding(.horizontal, 6)
            .onHover { hoveringHeader = $0 }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(tickets) { ticket in
                        TicketCardView(ticket: ticket, onEdit: onEdit,
                                       onView: onView, onDelete: onDelete)
                            .draggable(ticket.id)
                    }
                    if tickets.isEmpty {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
                            .foregroundStyle(.quaternary)
                            .frame(height: 60)
                            .overlay(
                                Text(isVirtual ? "—" : "Drop tickets here")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            )
                    }
                }
                .padding(3)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme(scheme: scheme).columnFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(isTargeted ? Color.accentColor
                            : Theme(scheme: scheme).columnBorder,
                            lineWidth: isTargeted ? 2 : 1)
                )
        )
        .animation(.easeOut(duration: 0.15), value: isTargeted)
        .dropDestination(for: String.self) { ids, _ in
            guard !isVirtual else { return false }
            for id in ids { store.moveTicket(id: id, toColumn: column.id) }
            return true
        } isTargeted: { over in
            isTargeted = over && !isVirtual
        }
    }
}

struct TicketCardView: View {
    @EnvironmentObject var store: VaultStore
    @Environment(\.colorScheme) private var scheme
    let ticket: Ticket
    let onEdit: (Ticket) -> Void
    var onView: (Ticket) -> Void = { _ in }
    let onDelete: (Ticket) -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2)
                .fill(accentColor)
                .frame(width: 4)
                .padding(.vertical, 6)
                .padding(.leading, 6)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if ticket.kind != .client {
                        Image(systemName: ticket.kind.icon)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(ticket.title)
                        .font(.system(.callout, design: .rounded, weight: .semibold))
                        .lineLimit(2)
                }

                if !ticket.client.isEmpty {
                    HStack(spacing: 4) {
                        Circle().fill(clientColor(ticket.client)).frame(width: 6, height: 6)
                        Text(ticket.client)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                WrapChips(spacing: 6) {
                    switch ticket.kind {
                    case .client:
                        if ticket.type == .paid {
                            Label("\(amountLabel) \(ticket.currency)",
                                  systemImage: ticket.paid ? "checkmark.seal.fill" : "hourglass")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(
                                    Capsule().fill(ticket.paid ? Color.green.opacity(0.18)
                                                               : Color.orange.opacity(0.18)))
                                .foregroundStyle(ticket.paid ? .green : .orange)
                        } else {
                            Text("free")
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.blue.opacity(0.14)))
                                .foregroundStyle(.blue)
                        }
                        if !ticket.contract.isEmpty {
                            Text(ticket.contract)
                                .font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(.quaternary))
                                .foregroundStyle(.secondary)
                        }
                    case .content:
                        ForEach(ticket.platforms.prefix(2), id: \.self) { p in
                            Text(p)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.purple.opacity(0.16)))
                                .foregroundStyle(.purple)
                        }
                        if let pub = ticket.publishDate {
                            Label(pub, systemImage: "calendar.badge.clock")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    case .task:
                        if ticket.priority != "normal" {
                            Text(ticket.priority)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(
                                    ticket.priority == "high" ? Color.red.opacity(0.18)
                                                              : Color.blue.opacity(0.14)))
                                .foregroundStyle(ticket.priority == "high" ? .red : .blue)
                        }
                    }
                    if !ticket.assignee.isEmpty {
                        Label(ticket.assignee, systemImage: "person")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let due = ticket.due {
                        Label(due, systemImage: "calendar")
                            .font(.caption2)
                            .foregroundStyle(ticket.isOverdue ? .red : .secondary)
                            .fontWeight(ticket.isOverdue ? .bold : .regular)
                    }
                }

                if !ticket.tags.isEmpty {
                    WrapChips(spacing: 4) {
                        ForEach(ticket.tags.prefix(4), id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(.quaternary))
                                .foregroundStyle(.secondary)
                        }
                        if ticket.tags.count > 4 {
                            Text("+\(ticket.tags.count - 4)")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Theme(scheme: scheme).cardFill)
                .shadow(color: Theme(scheme: scheme).cardShadow(hovering: hovering),
                        radius: hovering ? 4 : 2, y: 1.5)
                .overlay(Theme(scheme: scheme).cardBorder.map {
                    RoundedRectangle(cornerRadius: 9).strokeBorder($0)
                })
        )
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button {
                    onEdit(ticket)
                } label: {
                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.accentColor)
                        .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                }
                .buttonStyle(.plain)
                .padding(5)
                .help("Edit ticket")
            }
        }
        .scaleEffect(hovering ? 1.015 : 1)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .onTapGesture { onView(ticket) }   // click = read-only quick view; edit via pencil/context/Edit
        .contextMenu {
            Button("View") { onView(ticket) }
            Button("Edit…") { onEdit(ticket) }
            if ticket.type == .paid {
                Button(ticket.paid ? "Mark Unpaid" : "Mark Paid") {
                    store.togglePaid(ticket)
                }
            }
            Menu("Move to") {
                ForEach(store.config.columns) { col in
                    Button(col.name) { store.moveTicket(id: ticket.id, toColumn: col.id) }
                }
            }
            if let url = ticket.fileURL {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            Divider()
            Button("Delete…", role: .destructive) { onDelete(ticket) }
        }
        .help("Double-click to edit · drag to move")
    }

    private var accentColor: Color {
        switch ticket.kind {
        case .client:
            if ticket.type == .free { return .blue }
            return ticket.paid ? .green : .orange
        case .content:
            return .purple
        case .task:
            return ticket.priority == "high" ? .red : .gray
        }
    }

    private var amountLabel: String {
        ticket.amount == ticket.amount.rounded()
            ? String(Int(ticket.amount)) : String(format: "%.2f", ticket.amount)
    }
}
