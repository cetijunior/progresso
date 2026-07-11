import SwiftUI

/// TextField with lightweight autocomplete: matching existing values appear
/// as small chips under the field; click to accept. `tokenized` suggests for
/// the last comma-separated token (tags, platforms).
struct SuggestTextField: View {
    let placeholder: String
    @Binding var text: String
    var suggestions: [String]
    var tokenized = false

    @FocusState private var focused: Bool

    private var currentToken: String {
        guard tokenized else { return text }
        let last = text.split(separator: ",", omittingEmptySubsequences: false).last ?? ""
        return last.trimmingCharacters(in: .whitespaces)
    }

    private var matches: [String] {
        let q = currentToken.lowercased()
        guard focused, !q.isEmpty else { return [] }
        return Array(suggestions
            .filter { $0.lowercased().hasPrefix(q) && $0.lowercased() != q }
            .prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
            if !matches.isEmpty {
                HStack(spacing: 4) {
                    ForEach(matches, id: \.self) { match in
                        Button(match) { accept(match) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private func accept(_ match: String) {
        if tokenized {
            var parts = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            if parts.isEmpty { parts = [""] }
            parts[parts.count - 1] = (parts.count > 1 ? " " : "") + match
            text = parts.joined(separator: ",")
        } else {
            text = match
        }
    }
}
