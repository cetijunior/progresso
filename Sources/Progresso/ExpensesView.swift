import SwiftUI

/// Expense log for the active board — money OUT, kept deliberately separate
/// from tickets (money IN). List + inline editor in one sheet, so we never
/// stack presentation modifiers.
struct ExpensesView: View {
    @EnvironmentObject var store: VaultStore
    @Environment(\.dismiss) private var dismiss

    @State private var editing: Expense?
    @State private var confirmingDelete: Expense?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Expenses — \(store.activeBoard?.name ?? "")")
                    .font(.title3.bold())
                Spacer()
                Text("Total \(money(store.expensesTotal))  ·  This month \(money(store.expensesThisMonth))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)

            Divider()

            if let editing {
                ExpenseEditor(expense: editing,
                              categorySuggestions: store.expenseCategories,
                              vendorSuggestions: store.vendors,
                              clientSuggestions: store.clients,
                              onSave: { store.saveExpense($0); self.editing = nil },
                              onCancel: { self.editing = nil })
            } else {
                listBody
            }
        }
        .frame(width: 640, height: 520)
        // Escape backs out one level: expense editor first, then the sheet.
        .onExitCommand {
            if editing != nil { editing = nil } else { dismiss() }
        }
        .confirmationDialog(
            "Delete this expense? The .md file will be removed.",
            isPresented: .init(
                get: { confirmingDelete != nil },
                set: { if !$0 { confirmingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete File", role: .destructive) {
                if let e = confirmingDelete { store.deleteExpense(e) }
                confirmingDelete = nil
            }
        }
    }

    private var listBody: some View {
        VStack(spacing: 0) {
            if store.expenses.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "banknote")
                        .font(.system(size: 30))
                        .foregroundStyle(.tertiary)
                    Text("No expenses logged on this board yet.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.expenses) { expense in
                        HStack(spacing: 10) {
                            Text(expense.date)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(width: 80, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(expense.vendor.isEmpty ? expense.category : expense.vendor)
                                    .fontWeight(.medium)
                                HStack(spacing: 6) {
                                    if !expense.category.isEmpty {
                                        Text(expense.category)
                                            .font(.caption2)
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(Capsule().fill(.quaternary))
                                            .foregroundStyle(.secondary)
                                    }
                                    if !expense.client.isEmpty {
                                        Text(expense.client)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    if expense.recurring {
                                        Label("recurring", systemImage: "repeat")
                                            .font(.caption2)
                                            .foregroundStyle(.blue)
                                    }
                                }
                            }
                            Spacer()
                            Text("−\(money(expense.amount))")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.red)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { editing = expense }
                        .contextMenu {
                            Button("Edit…") { editing = expense }
                            if let url = expense.fileURL {
                                Button("Show in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                }
                            }
                            Divider()
                            Button("Delete…", role: .destructive) { confirmingDelete = expense }
                        }
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Button {
                    editing = Expense.blank()
                } label: {
                    Label("Add Expense", systemImage: "plus")
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
    }

    private func money(_ v: Double) -> String {
        let amount = v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
        return "\(amount) \(store.mainCurrency)"
    }
}

struct ExpenseEditor: View {
    let expense: Expense
    var categorySuggestions: [String] = []
    var vendorSuggestions: [String] = []
    var clientSuggestions: [String] = []
    let onSave: (Expense) -> Void
    let onCancel: () -> Void

    @State private var date: Date
    @State private var category: String
    @State private var amountText: String
    @State private var currency: String
    @State private var vendor: String
    @State private var client: String
    @State private var recurring: Bool
    @State private var receipt: String
    @State private var notes: String

    private let labelWidth: CGFloat = 76

    init(expense: Expense,
         categorySuggestions: [String] = [], vendorSuggestions: [String] = [],
         clientSuggestions: [String] = [],
         onSave: @escaping (Expense) -> Void, onCancel: @escaping () -> Void) {
        self.expense = expense
        self.categorySuggestions = categorySuggestions
        self.vendorSuggestions = vendorSuggestions
        self.clientSuggestions = clientSuggestions
        self.onSave = onSave
        self.onCancel = onCancel
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        _date = State(initialValue: f.date(from: expense.date) ?? Date())
        _category = State(initialValue: expense.category)
        _amountText = State(initialValue: expense.amount == 0 ? "" :
            (expense.amount == expense.amount.rounded()
                ? String(Int(expense.amount)) : String(expense.amount)))
        _currency = State(initialValue: expense.currency)
        _vendor = State(initialValue: expense.vendor)
        _client = State(initialValue: expense.client)
        _recurring = State(initialValue: expense.recurring)
        _receipt = State(initialValue: expense.receipt)
        _notes = State(initialValue: expense.notes)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    row("Date") {
                        DatePicker("", selection: $date, displayedComponents: .date)
                            .labelsHidden()
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
                            Toggle("Recurring", isOn: $recurring)
                                .toggleStyle(.checkbox)
                        }
                    }
                    row("Category") {
                        SuggestTextField(placeholder: "software / ads / contractor / equipment…",
                                         text: $category, suggestions: categorySuggestions)
                    }
                    row("Vendor") {
                        SuggestTextField(placeholder: "who got paid",
                                         text: $vendor, suggestions: vendorSuggestions)
                    }
                    row("Client") {
                        SuggestTextField(placeholder: "optional — tie to a client/project",
                                         text: $client, suggestions: clientSuggestions)
                    }
                    row("Receipt") {
                        TextField("optional URL or file path", text: $receipt)
                            .textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("NOTES")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        NotesEditor(text: $notes)
                            .frame(minHeight: 90)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary))
                    }
                }
                .padding(18)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save Expense") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(Double(amountText.replacingOccurrences(of: ",", with: ".")) == nil)
            }
            .padding(14)
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

    private func save() {
        var e = expense
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        e.date = f.string(from: date)
        e.category = category.trimmingCharacters(in: .whitespaces)
        e.amount = Double(amountText.replacingOccurrences(of: ",", with: ".")) ?? 0
        e.currency = currency.trimmingCharacters(in: .whitespaces).isEmpty
            ? "EUR" : currency.trimmingCharacters(in: .whitespaces)
        e.vendor = vendor.trimmingCharacters(in: .whitespaces)
        e.client = client.trimmingCharacters(in: .whitespaces)
        e.recurring = recurring
        e.receipt = receipt.trimmingCharacters(in: .whitespaces)
        e.notes = notes
        onSave(e)
    }
}
