import SwiftUI
import AppKit

/// Every editable field gets its OWN @State scalar — binding fields straight
/// into a whole `Ticket` struct once caused keystroke-driven re-renders that
/// teleported focus mid-typing. Kind sections are conditional, but `kind`
/// only changes on an explicit click, never while typing.
struct TicketEditorView: View {
    @EnvironmentObject var store: VaultStore
    @Environment(\.dismiss) private var dismiss

    let original: Ticket
    let isNew: Bool

    @State private var kind: TicketKind
    @State private var title: String
    @State private var client: String
    @State private var type: TicketType
    @State private var amountText: String
    @State private var currency: String
    @State private var isPaid: Bool
    @State private var contract: String
    @State private var platformsText: String
    @State private var deliverable: String
    @State private var pillar: String
    @State private var assignee: String
    @State private var priority: String
    @State private var status: String
    @State private var tagsText: String
    @State private var linksText: String
    @State private var hasDue: Bool
    @State private var dueDate: Date
    @State private var hasFilming: Bool
    @State private var filmingDate: Date
    @State private var hasPublish: Bool
    @State private var publishDate: Date
    @State private var notes: String
    @State private var gcalSync: Bool
    @ObservedObject private var gcal = GCalManager.shared

    @FocusState private var focusedField: Field?
    private enum Field { case title }

    private let labelWidth: CGFloat = 84

    init(ticket: Ticket, isNew: Bool) {
        self.original = ticket
        self.isNew = isNew
        _kind = State(initialValue: ticket.kind)
        _title = State(initialValue: ticket.title)
        _client = State(initialValue: ticket.client)
        _type = State(initialValue: ticket.type)
        _amountText = State(initialValue: ticket.amount == 0 ? "" :
            (ticket.amount == ticket.amount.rounded()
                ? String(Int(ticket.amount)) : String(ticket.amount)))
        _currency = State(initialValue: ticket.currency)
        _isPaid = State(initialValue: ticket.paid)
        _contract = State(initialValue: ticket.contract)
        _platformsText = State(initialValue: ticket.platforms.joined(separator: ", "))
        _deliverable = State(initialValue: ticket.deliverable)
        _pillar = State(initialValue: ticket.pillar)
        _assignee = State(initialValue: ticket.assignee)
        _priority = State(initialValue: ticket.priority)
        _status = State(initialValue: ticket.status)
        _tagsText = State(initialValue: ticket.tags.joined(separator: ", "))
        _linksText = State(initialValue: ticket.links.joined(separator: ", "))
        _notes = State(initialValue: ticket.notes)
        _gcalSync = State(initialValue: ticket.gcalSync)

        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        func parse(_ s: String?) -> (Bool, Date) {
            if let s, let d = f.date(from: s) { return (true, d) }
            return (false, Date())
        }
        let due = parse(ticket.due)
        _hasDue = State(initialValue: due.0); _dueDate = State(initialValue: due.1)
        let film = parse(ticket.filmingDate)
        _hasFilming = State(initialValue: film.0); _filmingDate = State(initialValue: film.1)
        let pub = parse(ticket.publishDate)
        _hasPublish = State(initialValue: pub.0); _publishDate = State(initialValue: pub.1)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "New Ticket" : "Edit Ticket")
                    .font(.title3.bold())
                Spacer()
                if !isNew {
                    Text("\(original.id).md")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    row("Kind") {
                        Picker("", selection: $kind) {
                            ForEach(TicketKind.allCases) { k in
                                Label(k.label, systemImage: k.icon).tag(k)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 280)
                        .onChange(of: kind) { _, newKind in
                            // Content/tasks default to non-billable.
                            if newKind != .client && type == .paid && amountText.isEmpty {
                                type = .free
                            }
                        }
                    }

                    row("Title") {
                        TextField(titlePlaceholder, text: $title)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .title)
                    }

                    // ---- Client ticket fields ----
                    if kind == .client {
                        row("Client") {
                            SuggestTextField(placeholder: "Who is it for?",
                                             text: $client, suggestions: store.clients)
                        }
                        row("Contract") {
                            Picker("", selection: $contract) {
                                Text("—").tag("")
                                Text("Retainer").tag("retainer")
                                Text("One-time").tag("one-time")
                                Text("Project").tag("project")
                            }
                            .labelsHidden()
                            .frame(width: 170)
                        }
                        row("Type") {
                            Picker("", selection: $type) {
                                Text("Paid").tag(TicketType.paid)
                                Text("Free").tag(TicketType.free)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 170)
                        }
                        row("Amount") {
                            HStack(spacing: 10) {
                                TextField("0", text: $amountText)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 100)
                                    .multilineTextAlignment(.trailing)
                                TextField("EUR", text: $currency)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 64)
                                Toggle("Already paid", isOn: $isPaid)
                                    .toggleStyle(.checkbox)
                            }
                            .disabled(type == .free)
                            .opacity(type == .free ? 0.35 : 1)
                        }
                        row("Deliverable") {
                            TextField("e.g. 8 reels / landing page / logo", text: $deliverable)
                                .textFieldStyle(.roundedBorder)
                        }
                        row("Platforms") {
                            SuggestTextField(placeholder: "Instagram, TikTok (comma-separated)",
                                             text: $platformsText,
                                             suggestions: store.allPlatforms, tokenized: true)
                        }
                    }

                    // ---- Content ticket fields ----
                    if kind == .content {
                        row("Platforms") {
                            SuggestTextField(placeholder: "Instagram, TikTok, YouTube",
                                             text: $platformsText,
                                             suggestions: store.allPlatforms, tokenized: true)
                        }
                        row("Pillar") {
                            TextField("content pillar / category", text: $pillar)
                                .textFieldStyle(.roundedBorder)
                        }
                        row("Assignee") {
                            SuggestTextField(placeholder: "who owns it",
                                             text: $assignee, suggestions: store.assignees)
                        }
                        row("Filming") { dateToggle($hasFilming, $filmingDate) }
                        row("Publish") { dateToggle($hasPublish, $publishDate) }
                    }

                    // ---- Task ticket fields ----
                    if kind == .task {
                        row("Priority") {
                            Picker("", selection: $priority) {
                                Text("Low").tag("low")
                                Text("Normal").tag("normal")
                                Text("High").tag("high")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 220)
                        }
                        row("Assignee") {
                            SuggestTextField(placeholder: "who owns it",
                                             text: $assignee, suggestions: store.assignees)
                        }
                    }

                    // ---- Common fields ----
                    row("Column") {
                        Picker("", selection: $status) {
                            ForEach(store.config.columns) { col in
                                Text(col.name).tag(col.id)
                            }
                            if !store.config.columns.contains(where: { $0.id == status }) {
                                Text("\(status) (not a column)").tag(status)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 200)
                    }
                    row("Tags") {
                        SuggestTextField(placeholder: "design, logo (comma-separated)",
                                         text: $tagsText,
                                         suggestions: store.allTags, tokenized: true)
                    }
                    if kind != .content {
                        row("Due") { dateToggle($hasDue, $dueDate) }
                    }
                    row("Links") {
                        TextField("https://… , https://… (comma-separated)", text: $linksText)
                            .textFieldStyle(.roundedBorder)
                    }
                    row("Calendar") {
                        VStack(alignment: .leading, spacing: 3) {
                            Toggle("Sync dates to Google Calendar", isOn: $gcalSync)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .disabled(!gcal.isConnected && !gcalSync)
                            if !gcal.isConnected {
                                Text("Connect in Settings (⌘,) → Google Calendar")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            } else if gcalSync {
                                Text("Due, filming, and publish dates become all-day events; edits update them, deleting the ticket removes them.")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(kind == .content ? "SCRIPT / NOTES" : "NOTES")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        NotesEditor(text: $notes)
                            .frame(minHeight: 170)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(.quaternary))
                    }
                    .padding(.top, 4)
                }
                .padding(18)
            }

            Divider()
            HStack {
                if !isNew, let url = original.fileURL {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Save") {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    DispatchQueue.main.async { saveAndClose() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(14)
        }
        .frame(width: 560, height: 680)
        // .keyboardShortcut(.cancelAction) alone doesn't receive Escape in
        // these sheets — wire it explicitly.
        .onExitCommand { dismiss() }
        .onAppear { if isNew { focusedField = .title } }
    }

    private var titlePlaceholder: String {
        switch kind {
        case .client: return "What's the job?"
        case .content: return "Video idea / working title"
        case .task: return "What needs doing?"
        }
    }

    @ViewBuilder
    private func dateToggle(_ on: Binding<Bool>, _ date: Binding<Date>) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: on)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            DatePicker("", selection: date, displayedComponents: .date)
                .labelsHidden()
                .disabled(!on.wrappedValue)
                .opacity(on.wrappedValue ? 1 : 0.35)
        }
    }

    @ViewBuilder
    private func row(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .trailing)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func csv(_ s: String) -> [String] {
        s.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func saveAndClose() {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"

        var t = original
        t.kind = kind
        t.title = title
        t.client = client.trimmingCharacters(in: .whitespaces)
        t.type = kind == .client ? type : .free
        t.amount = Double(amountText.replacingOccurrences(of: ",", with: ".")) ?? 0
        t.currency = currency.trimmingCharacters(in: .whitespaces).isEmpty
            ? "EUR" : currency.trimmingCharacters(in: .whitespaces)
        t.paid = isPaid
        if isPaid && !original.paid {
            t.paidDate = Ticket.today()
        } else if !isPaid {
            t.paidDate = nil
        }
        t.contract = kind == .client ? contract : ""
        t.platforms = kind == .task ? [] : csv(platformsText)
        t.deliverable = kind == .client ? deliverable.trimmingCharacters(in: .whitespaces) : ""
        t.pillar = kind == .content ? pillar.trimmingCharacters(in: .whitespaces) : ""
        t.assignee = kind == .client ? "" : assignee.trimmingCharacters(in: .whitespaces)
        t.priority = kind == .task ? priority : "normal"
        t.status = status
        t.tags = csv(tagsText)
        t.links = csv(linksText)
        t.due = (hasDue && kind != .content) ? f.string(from: dueDate) : nil
        t.filmingDate = (hasFilming && kind == .content) ? f.string(from: filmingDate) : nil
        t.publishDate = (hasPublish && kind == .content) ? f.string(from: publishDate) : nil
        t.gcalSync = gcalSync   // event IDs ride along from `original`
        t.notes = notes
        store.save(t)
        dismiss()
    }
}
