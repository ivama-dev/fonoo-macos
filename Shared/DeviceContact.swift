import Foundation

struct DevicePhoneNumber: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let value: String
}

struct DeviceContact: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let numbers: [DevicePhoneNumber]

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        if name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) != nil { return true }
        // Only treat phone-like input as a number; “Anna 5” must not match every number containing 5.
        let allowed = CharacterSet(charactersIn: "+0123456789 ()-./\t\n")
        guard query.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        let digits = query.filter(\.isNumber)
        guard !digits.isEmpty else { return false }
        return numbers.contains { $0.value.filter(\.isNumber).contains(digits) }
    }

    /// Exact phone matching only: never confuse extensions with suffixes of external numbers.
    func matchingPhoneNumber(_ value: String) -> DevicePhoneNumber? {
        let target = Self.normalizedPhoneNumber(value)
        guard !target.isEmpty else { return nil }
        return numbers.first { Self.normalizedPhoneNumber($0.value) == target }
    }
    func containsPhoneNumber(_ value: String) -> Bool { matchingPhoneNumber(value) != nil }
    private static func normalizedPhoneNumber(_ value: String) -> String {
        let digits = value.filter { $0.isNumber || $0 == "+" || $0 == "*" || $0 == "#" }
        if digits.hasPrefix("00") { return "+" + digits.dropFirst(2) }
        // Austria is the current tenant dialling region; match national contacts
        // exactly, never by suffix (which would confuse short extensions).
        if digits.hasPrefix("0") && digits.count > 6 { return "+43" + digits.dropFirst() }
        return digits
    }
    static func resolvedContact(in contacts: [DeviceContact], number: String) -> Contact? {
        var match: Contact?
        for person in contacts {
            guard let phone = person.matchingPhoneNumber(number) else { continue }
            guard match == nil else { return nil } // Ambiguous names are not guessed.
            match = person.callContact(for: phone)
        }
        return match
    }

    func callContact(for number: DevicePhoneNumber) -> Contact {
        Contact(id: "device:\(id):\(number.id)", name: name, role: number.label, number: number.value)
    }
}
