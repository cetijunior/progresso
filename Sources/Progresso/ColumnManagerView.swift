import SwiftUI

struct ColumnManagerView: View {
    @EnvironmentObject var store: VaultStore
    @Environment(\.dismiss) private var dismiss

    @State private var newColumnName = ""
    @State private var deletingColumn: BoardColumn?
    @State private var fallbackColumnID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Board Columns").font(.title3).bold()

            List {
                ForEach(Array(store.config.columns.enumerated()), id: \.element.id) { index, column in
                    HStack {
                        TextField("Name", text: binding(for: index))
                            .textFieldStyle(.roundedBorder)
                        Text("\(ticketCount(column.id))")
                            .foregroundStyle(.secondary)
                            .frame(width: 28)
                        Button { move(index, by: -1) } label: {
                            Image(systemName: "arrow.up")
                        }.disabled(index == 0)
                        Button { move(index, by: 1) } label: {
                            Image(systemName: "arrow.down")
                        }.disabled(index == store.config.columns.count - 1)
                        Button(role: .destructive) {
                            requestDelete(column)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .disabled(store.config.columns.count == 1)
                    }
                }
            }
            .frame(minHeight: 220)

            HStack {
                TextField("New column name", text: $newColumnName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addColumn)
                Button("Add", action: addColumn)
                    .disabled(newColumnName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
        .onExitCommand { dismiss() }
        .sheet(item: $deletingColumn) { column in
            deleteSheet(for: column)
        }
    }

    private func deleteSheet(for column: BoardColumn) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete “\(column.name)”")
                .font(.headline)
            Text("\(ticketCount(column.id)) ticket(s) are still in this column. Move them to:")
            Picker("Move to", selection: $fallbackColumnID) {
                ForEach(store.config.columns.filter { $0.id != column.id }) { col in
                    Text(col.name).tag(col.id)
                }
            }
            .labelsHidden()
            HStack {
                Spacer()
                Button("Cancel") { deletingColumn = nil }
                Button("Move & Delete", role: .destructive) {
                    store.deleteColumn(column.id, movingTicketsTo: fallbackColumnID)
                    deletingColumn = nil
                }
                .disabled(fallbackColumnID.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func binding(for index: Int) -> Binding<String> {
        Binding(
            get: {
                guard store.config.columns.indices.contains(index) else { return "" }
                return store.config.columns[index].name
            },
            set: { newValue in
                guard store.config.columns.indices.contains(index) else { return }
                store.config.columns[index].name = newValue
                store.saveConfig()
            }
        )
    }

    private func ticketCount(_ columnID: String) -> Int {
        store.tickets.filter { $0.status == columnID }.count
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard store.config.columns.indices.contains(target) else { return }
        store.config.columns.swapAt(index, target)
        store.saveConfig()
    }

    private func addColumn() {
        let name = newColumnName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var id = VaultStore.slugify(name)
        if id.isEmpty { id = "column" }
        var candidate = id
        var n = 2
        while store.config.columns.contains(where: { $0.id == candidate }) {
            candidate = "\(id)-\(n)"; n += 1
        }
        store.config.columns.append(BoardColumn(id: candidate, name: name))
        store.saveConfig()
        newColumnName = ""
    }

    private func requestDelete(_ column: BoardColumn) {
        if ticketCount(column.id) == 0 {
            store.config.columns.removeAll { $0.id == column.id }
            store.saveConfig()
        } else {
            fallbackColumnID = store.config.columns.first(where: { $0.id != column.id })?.id ?? ""
            deletingColumn = column
        }
    }
}
