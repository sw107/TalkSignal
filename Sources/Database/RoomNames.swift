import Foundation

// Naming metadata only. A group member is never treated as a sender filter.
struct RoomNames: Equatable {
    let display: String
    let aliases: Set<String>

    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }
    static func resolve(room: String?, title: String?, openLink: String?, person: String?, members: String?) -> RoomNames? {
        let candidates = [room, title, openLink, person, members].compactMap { $0 }.map(normalized).filter { !$0.isEmpty }
        guard let display = candidates.first else { return nil }
        // The effective 1:1 contact name remains usable even if that room is renamed.
        var aliases: Set<String> = [display]
        if let person, !normalized(person).isEmpty { aliases.insert(normalized(person)) }
        return .init(display: display, aliases: aliases)
    }
}
