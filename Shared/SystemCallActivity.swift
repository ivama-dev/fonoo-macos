import Foundation
import Intents

/// Decode only explicit, single-person audio call requests. Never guess a number
/// from a contact name or choose a participant from a group call.
enum SystemCallActivity {
    static let types = ["INStartCallIntent", "INStartAudioCallIntent"]

    static func contact(from intent: INIntent) -> Contact? {
        if let call = intent as? INStartCallIntent {
            guard call.callCapability != .videoCall else { return nil }
            if let contacts = call.contacts, !contacts.isEmpty { return contact(contacts) }
            guard let record = call.callRecordToCallBack,
                  record.callCapability != .videoCall, record.__isCallerIdBlocked?.boolValue != true else { return nil }
            return contact(record.participants)
        }
        #if os(iOS)
        // Older CallKit versions can deliver this activity from Phone Recents.
        if let call = intent as? INStartAudioCallIntent { return contact(call.contacts) }
        #endif
        return nil
    }

    private static func contact(_ people: [INPerson]?) -> Contact? {
        guard let people, people.count == 1, let person = people.first,
              let value = person.personHandle?.value,
              let number = try? SIPAccount.normalizedNumber(value) else { return nil }
        return Contact(id: number, name: person.displayName.isEmpty ? number : person.displayName,
                       role: "Anrufliste", number: number)
    }

    static func request(from activity: NSUserActivity) -> (contact: Contact, id: String)? {
        guard types.contains(activity.activityType) else { return nil }
        let contact: Contact
        if let intent = activity.interaction?.intent {
            guard let decoded = Self.contact(from: intent) else { return nil }
            contact = decoded
        } else {
            // Existing in-app Siri/CarPlay handoff uses an explicit one-use ID.
            guard activity.activityType == "INStartCallIntent",
                  let id = activity.userInfo?["fonoo_request"] as? String, !id.isEmpty,
                  let value = activity.userInfo?["fonoo_number"] as? String,
                  let number = try? SIPAccount.normalizedNumber(value) else { return nil }
            contact = Contact(id: number, name: activity.userInfo?["fonoo_name"] as? String ?? number,
                              role: "Anrufliste", number: number)
        }
        let id = activity.userInfo?["fonoo_request"] as? String
            ?? activity.interaction?.identifier ?? activity.interaction?.intent.identifier ?? UUID().uuidString
        // Preserve identity if SwiftUI and UIApplication deliver the same activity.
        activity.addUserInfoEntries(from: ["fonoo_request": id])
        return (contact, id)
    }
}
