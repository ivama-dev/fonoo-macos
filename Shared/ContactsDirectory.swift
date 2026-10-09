import Combine
import Contacts
import Foundation

@MainActor
final class ContactsDirectory: ObservableObject {
    enum Access { case notRequested, allowed, limited, denied, restricted }

    @Published private(set) var access: Access = .notRequested
    @Published private(set) var contacts: [DeviceContact] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    private var revision = 0

    var canRead: Bool { access == .allowed || access == .limited }

    static func currentAccess() -> Access {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        #if os(iOS)
        if #available(iOS 18.0, *), status == .limited { return .limited }
        #endif
        switch status {
        case .authorized: return .allowed
        case .notDetermined: return .notRequested
        case .denied: return .denied
        default: return .restricted
        }
    }

    func requestAccess() async {
        guard Self.currentAccess() == .notRequested else { await refresh(); return }
        do {
            _ = try await CNContactStore().requestAccess(for: .contacts)
            await refresh()
        } catch {
            access = Self.currentAccess()
            errorMessage = "Der Kontaktzugriff konnte nicht angefragt werden. Bitte versuche es erneut."
        }
    }

    func clear() {
        revision += 1
        contacts = []
        isLoading = false
    }

    func refresh() async {
        revision += 1
        let requestRevision = revision
        access = Self.currentAccess()
        contacts = []
        errorMessage = nil
        isLoading = canRead
        guard canRead else { return }
        do {
            let worker = Task.detached(priority: .userInitiated) { try Self.readContacts() }
            let result = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            guard requestRevision == revision, !Task.isCancelled else { return }
            access = Self.currentAccess()
            contacts = canRead ? result : []
            isLoading = false
        } catch {
            guard requestRevision == revision, !Task.isCancelled else { return }
            access = Self.currentAccess()
            isLoading = false
            errorMessage = canRead ? "Die Kontakte konnten nicht geladen werden. Bitte versuche es erneut." : nil
        }
    }

    /// Synchronous Contacts I/O runs off the main actor. No uploads or address-book writes.
    nonisolated private static func readContacts() throws -> [DeviceContact] {
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .userDefault
        var result: [DeviceContact] = []
        try Task.checkCancellation()
        try CNContactStore().enumerateContacts(with: request) { contact, stop in
            if Task.isCancelled { stop.pointee = true; return }
            let numbers = contact.phoneNumbers.compactMap { entry -> DevicePhoneNumber? in
                let value = entry.value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return nil }
                let label = entry.label.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } ?? "Telefon"
                return DevicePhoneNumber(id: entry.identifier, label: label, value: value)
            }
            guard !numbers.isEmpty else { return }
            let formatted = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
            let name = !formatted.isEmpty ? formatted : (!contact.organizationName.isEmpty ? contact.organizationName : numbers[0].value)
            result.append(DeviceContact(id: contact.identifier, name: name, numbers: numbers))
        }
        try Task.checkCancellation()
        return result
    }
}
