import Foundation
import Yams

/// Parses and serializes ticket markdown files: YAML frontmatter + body.
/// Round-trips unknown frontmatter keys so external edits aren't destroyed.
enum Frontmatter {

    static func parseTicket(text: String, fileURL: URL) -> Ticket? {
        let stem = fileURL.deletingPathExtension().lastPathComponent
        var yamlPart = ""
        var body = text

        if text.hasPrefix("---") {
            let lines = text.components(separatedBy: "\n")
            if let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
                yamlPart = lines[1..<end].joined(separator: "\n")
                body = lines[(end + 1)...].joined(separator: "\n")
                    .trimmingCharacters(in: .newlines)
            }
        }

        var dict: [String: Any] = [:]
        if !yamlPart.isEmpty {
            dict = (try? Yams.load(yaml: yamlPart) as? [String: Any]) ?? [:]
            // Strict YAML failed (e.g. an unquoted value containing ": ").
            // Fall back to a lenient line parser rather than degrading the
            // ticket to defaults — a degraded ticket would DESTROY the real
            // fields on the next save.
            if dict.isEmpty {
                dict = lenientParse(yamlPart)
            }
        }

        let knownKeys: Set<String> = ["id", "title", "client", "type", "amount",
                                      "currency", "paid", "status", "tags",
                                      "created", "due", "paid_date",
                                      "kind", "contract", "platforms", "deliverable",
                                      "pillar", "assignee", "filming", "publish",
                                      "priority", "links",
                                      "gcal_sync", "gcal_due", "gcal_filming", "gcal_publish"]

        var extra: [(String, String)] = []
        for (k, v) in dict where !knownKeys.contains(k) {
            extra.append((k, scalarString(v)))
        }
        extra.sort { $0.0 < $1.0 }

        var t = Ticket(
            id: str(dict["id"]) ?? stem,
            title: str(dict["title"]) ?? stem,
            client: str(dict["client"]) ?? "",
            type: TicketType(rawValue: str(dict["type"])?.lowercased() ?? "paid") ?? .paid,
            amount: num(dict["amount"]) ?? 0,
            currency: str(dict["currency"]) ?? "EUR",
            paid: bool(dict["paid"]) ?? false,
            status: str(dict["status"]) ?? "backlog",
            tags: tagList(dict["tags"]),
            created: dateStr(dict["created"]) ?? Ticket.today(),
            due: dateStr(dict["due"]),
            paidDate: dateStr(dict["paid_date"]),
            notes: body,
            fileURL: fileURL,
            extra: extra
        )
        t.kind = TicketKind(rawValue: str(dict["kind"])?.lowercased() ?? "client") ?? .client
        t.contract = str(dict["contract"]) ?? ""
        t.platforms = tagList(dict["platforms"])
        t.deliverable = str(dict["deliverable"]) ?? ""
        t.pillar = str(dict["pillar"]) ?? ""
        t.assignee = str(dict["assignee"]) ?? ""
        t.filmingDate = dateStr(dict["filming"])
        t.publishDate = dateStr(dict["publish"])
        t.priority = str(dict["priority"]) ?? "normal"
        t.links = tagList(dict["links"])
        t.gcalSync = bool(dict["gcal_sync"]) ?? false
        for key in ["due", "filming", "publish"] {
            if let id = str(dict["gcal_\(key)"]), !id.isEmpty {
                t.gcalEventIDs[key] = id
            }
        }
        return t
    }

    static func serialize(_ t: Ticket) -> String {
        var lines: [String] = ["---"]
        lines.append("id: \(quote(t.id))")
        lines.append("title: \(quote(t.title))")
        if t.kind != .client {
            lines.append("kind: \(t.kind.rawValue)")
        }
        lines.append("client: \(quote(t.client))")
        lines.append("type: \(t.type.rawValue)")
        if t.type == .paid {
            lines.append("amount: \(amountString(t.amount))")
            lines.append("currency: \(quote(t.currency))")
            lines.append("paid: \(t.paid)")
            if let pd = t.paidDate, !pd.isEmpty {
                lines.append("paid_date: \(pd)")
            }
        }
        if !t.contract.isEmpty { lines.append("contract: \(quote(t.contract))") }
        if !t.platforms.isEmpty {
            lines.append("platforms: [\(t.platforms.map(quote).joined(separator: ", "))]")
        }
        if !t.deliverable.isEmpty { lines.append("deliverable: \(quote(t.deliverable))") }
        if !t.pillar.isEmpty { lines.append("pillar: \(quote(t.pillar))") }
        if !t.assignee.isEmpty { lines.append("assignee: \(quote(t.assignee))") }
        if let f = t.filmingDate, !f.isEmpty { lines.append("filming: \(f)") }
        if let p = t.publishDate, !p.isEmpty { lines.append("publish: \(p)") }
        if t.kind == .task && t.priority != "normal" {
            lines.append("priority: \(quote(t.priority))")
        }
        if !t.links.isEmpty {
            lines.append("links: [\(t.links.map(quote).joined(separator: ", "))]")
        }
        lines.append("status: \(quote(t.status))")
        if !t.tags.isEmpty {
            lines.append("tags: [\(t.tags.map(quote).joined(separator: ", "))]")
        } else {
            lines.append("tags: []")
        }
        lines.append("created: \(t.created)")
        if let due = t.due, !due.isEmpty {
            lines.append("due: \(due)")
        }
        if t.gcalSync { lines.append("gcal_sync: true") }
        for key in ["due", "filming", "publish"] {
            if let id = t.gcalEventIDs[key], !id.isEmpty {
                lines.append("gcal_\(key): \(quote(id))")
            }
        }
        for (k, v) in t.extra {
            lines.append("\(k): \(v)")
        }
        lines.append("---")
        lines.append("")
        lines.append(t.notes)
        var out = lines.joined(separator: "\n")
        if !out.hasSuffix("\n") { out += "\n" }
        return out
    }

    /// Line-based `key: value` parser used when strict YAML fails.
    /// Handles quoted strings, [a, b] lists, and values containing colons.
    private static func lenientParse(_ yaml: String) -> [String: Any] {
        var dict: [String: Any] = [:]
        for line in yaml.components(separatedBy: "\n") {
            guard !line.hasPrefix(" "), !line.hasPrefix("#"),
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            var value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
                dict[key] = value
            } else if value.hasPrefix("["), value.hasSuffix("]") {
                dict[key] = value.dropFirst().dropLast()
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            } else {
                dict[key] = value
            }
        }
        return dict
    }

    // MARK: - Expenses (own lightweight format, same file philosophy)

    static func parseExpense(text: String, fileURL: URL) -> Expense? {
        let stem = fileURL.deletingPathExtension().lastPathComponent
        var yamlPart = ""
        var body = text
        if text.hasPrefix("---") {
            let lines = text.components(separatedBy: "\n")
            if let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
                yamlPart = lines[1..<end].joined(separator: "\n")
                body = lines[(end + 1)...].joined(separator: "\n")
                    .trimmingCharacters(in: .newlines)
            }
        }
        var dict: [String: Any] = [:]
        if !yamlPart.isEmpty {
            dict = (try? Yams.load(yaml: yamlPart) as? [String: Any]) ?? [:]
            if dict.isEmpty { dict = lenientParse(yamlPart) }
        }
        return Expense(
            id: stem,
            date: dateStr(dict["date"]) ?? Ticket.today(),
            category: str(dict["category"]) ?? "",
            amount: num(dict["amount"]) ?? 0,
            currency: str(dict["currency"]) ?? "EUR",
            vendor: str(dict["vendor"]) ?? "",
            client: str(dict["client"]) ?? "",
            recurring: bool(dict["recurring"]) ?? false,
            receipt: str(dict["receipt"]) ?? "",
            notes: body,
            fileURL: fileURL
        )
    }

    static func serialize(_ e: Expense) -> String {
        var lines: [String] = ["---"]
        lines.append("date: \(e.date)")
        lines.append("category: \(quote(e.category))")
        lines.append("amount: \(amountString(e.amount))")
        lines.append("currency: \(quote(e.currency))")
        lines.append("vendor: \(quote(e.vendor))")
        if !e.client.isEmpty { lines.append("client: \(quote(e.client))") }
        lines.append("recurring: \(e.recurring)")
        if !e.receipt.isEmpty { lines.append("receipt: \(quote(e.receipt))") }
        lines.append("---")
        lines.append("")
        lines.append(e.notes)
        var out = lines.joined(separator: "\n")
        if !out.hasSuffix("\n") { out += "\n" }
        return out
    }

    // MARK: - Value coercion (Yams may hand back Date, Int, Double, Bool, arrays…)

    private static func str(_ v: Any?) -> String? {
        guard let v else { return nil }
        if let s = v as? String { return s }
        if let d = v as? Date { return format(d) }
        if v is NSNull { return nil }
        return String(describing: v)
    }

    private static func num(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }

    private static func bool(_ v: Any?) -> Bool? {
        if let b = v as? Bool { return b }
        if let s = v as? String { return ["true", "yes"].contains(s.lowercased()) }
        return nil
    }

    private static func dateStr(_ v: Any?) -> String? {
        if let d = v as? Date { return format(d) }
        if let s = v as? String, !s.isEmpty { return s }
        return nil
    }

    private static func tagList(_ v: Any?) -> [String] {
        if let arr = v as? [Any] {
            return arr.compactMap { str($0) }.filter { !$0.isEmpty }
        }
        if let s = v as? String {
            return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return []
    }

    private static func format(_ d: Date) -> String {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    private static func scalarString(_ v: Any) -> String {
        if let s = v as? String { return quote(s) }
        if let d = v as? Date { return format(d) }
        if let arr = v as? [Any] {
            return "[\(arr.map { scalarString($0) }.joined(separator: ", "))]"
        }
        return String(describing: v)
    }

    private static func amountString(_ a: Double) -> String {
        a == a.rounded() ? String(Int(a)) : String(a)
    }

    private static func quote(_ s: String) -> String {
        let needs = s.contains(":") || s.contains("#") || s.contains("\"")
            || s.hasPrefix(" ") || s.hasSuffix(" ") || s.hasPrefix("[")
            || s.hasPrefix("{") || s.hasPrefix("@") || s.isEmpty
        guard needs else { return s }
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
