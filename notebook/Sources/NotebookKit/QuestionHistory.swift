import Foundation

/// Walking back through what you have already asked.
///
/// **A notebook is used by asking almost the same question repeatedly.** You
/// ask, you read what came back, and you ask again with one word changed. Every
/// shell has had this for forty years and it is the difference between an
/// instrument you refine a question in and a box you retype sentences into.
///
/// The whole of the difficulty is knowing when an arrow key means "recall" and
/// when it means "move the cursor", because the field is also a multi-line text
/// editor. The rule here is conservative: **recall only when the field holds
/// nothing the person has typed themselves.** Empty, or showing exactly what
/// recall last put there. Anything else and the arrow belongs to the cursor.
///
/// Getting that wrong destroys work, which is why it is a value type with tests
/// rather than three flags in a view.
public struct QuestionHistory: Equatable, Sendable {

    /// Most recent first, deduplicated.
    public private(set) var entries: [String]
    /// Where in the history the field is showing from, or nil for "not
    /// recalling": the person is writing something of their own.
    public private(set) var position: Int?
    /// What was in the field before recall started, so it can be given back.
    private var draft: String = ""

    public init(entries: [String] = []) {
        self.entries = QuestionHistory.tidy(entries)
    }

    /// Rebuild from a notebook's record, newest first.
    ///
    /// Deduplicated, because asking the same question twice is normal and a
    /// history that makes you press up twice to get past it is not helping.
    public mutating func replace(with questions: [String]) {
        entries = QuestionHistory.tidy(questions)
        position = nil
    }

    /// Note a question that was just asked.
    public mutating func remember(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries.removeAll { $0 == trimmed }
        entries.insert(trimmed, at: 0)
        position = nil
        draft = ""
    }

    /// Whether an arrow press should recall rather than move the cursor.
    ///
    /// True when the field is empty, or when it still holds exactly what recall
    /// put there. The moment somebody edits a recalled question it becomes
    /// theirs, and the arrows go back to being arrows.
    public func recalls(_ field: String) -> Bool {
        if field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        guard let position, entries.indices.contains(position) else { return false }
        return field == entries[position]
    }

    /// One step back through the history. Returns what the field should show,
    /// or nil if this press should be left to the cursor.
    public mutating func older(from field: String) -> String? {
        guard recalls(field), !entries.isEmpty else { return nil }
        if position == nil { draft = field }
        let next = (position.map { $0 + 1 }) ?? 0
        guard next < entries.count else { return nil }  // already at the oldest
        position = next
        return entries[next]
    }

    /// One step forward, ending at the draft the person had been writing.
    public mutating func newer(from field: String) -> String? {
        guard recalls(field), let current = position else { return nil }
        if current == 0 {
            position = nil
            return draft
        }
        position = current - 1
        return entries[position!]
    }

    /// Stop recalling, because the field now holds something typed.
    public mutating func release() {
        position = nil
        draft = ""
    }

    private static func tidy(_ questions: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for q in questions {
            let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }
}
