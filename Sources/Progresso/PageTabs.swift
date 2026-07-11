import SwiftUI

/// "Book" pages: a board folder can hold multiple boards as subfolders.
/// This strip switches between them without leaving the folder context.
struct PageTabs: View {
    @EnvironmentObject var store: VaultStore
    @Environment(\.colorScheme) private var scheme
    @State private var addingPage = false
    @State private var newPageName = ""
    @State private var pagePendingDelete: String?

    var body: some View {
        // Hide entirely for plain single-page boards until the user adds one.
        if store.pages.count > 1 || addingPage {
            strip
        } else {
            strip.opacity(store.pages == ["Main"] ? 0.85 : 1)
        }
    }

    private var strip: some View {
        HStack(spacing: 6) {
            ForEach(store.pages, id: \.self) { page in
                Button {
                    store.switchPage(page)
                } label: {
                    Text(page)
                        .font(.caption.weight(page == store.activePage ? .bold : .regular))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(
                            Capsule().fill(page == store.activePage
                                           ? Color.accentColor.opacity(0.22)
                                           : Color.primary.opacity(0.05)))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if page != "Main" {
                        Button("Delete Page…", role: .destructive) {
                            pagePendingDelete = page
                        }
                    }
                }
            }

            if addingPage {
                TextField("page name", text: $newPageName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .onSubmit {
                        store.addPage(newPageName)
                        newPageName = ""
                        addingPage = false
                    }
                Button("Cancel") { addingPage = false; newPageName = "" }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    addingPage = true
                } label: {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Add a page (a separate board inside this folder)")
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Theme(scheme: scheme).boardBackground)
        .overlay(alignment: .bottom) {
            Theme(scheme: scheme).hairline.frame(height: 1)
        }
        .confirmationDialog(
            "Delete page “\(pagePendingDelete ?? "")” and move its folder to the Trash?",
            isPresented: .init(
                get: { pagePendingDelete != nil },
                set: { if !$0 { pagePendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Page", role: .destructive) {
                if let p = pagePendingDelete { store.deletePage(p) }
                pagePendingDelete = nil
            }
        }
    }
}
