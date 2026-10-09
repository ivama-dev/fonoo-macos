import Foundation
import Intents

@main
struct SystemCallActivityChecks {
    static func main() {
        func person(_ value: String) -> INPerson {
            INPerson(personHandle: INPersonHandle(value: value, type: .phoneNumber),
                     nameComponents: nil, displayName: value, image: nil,
                     contactIdentifier: nil, customIdentifier: nil)
        }
        func intent(_ contacts: [INPerson]?, video: Bool = false, record: INCallRecord? = nil) -> INStartCallIntent {
            INStartCallIntent(callRecordFilter: nil, callRecordToCallBack: record,
                              audioRoute: .unknown, destinationType: .normal,
                              contacts: contacts, callCapability: video ? .videoCall : .audioCall)
        }
        precondition(SystemCallActivity.contact(from: intent([person("100")]))?.number == "100")
        precondition(SystemCallActivity.contact(from: intent([person("+43 720 022801")]))?.number == "+43720022801")
        precondition(SystemCallActivity.contact(from: intent([person("100")], video: true)) == nil)
        precondition(SystemCallActivity.contact(from: intent([person("100"), person("101")])) == nil)
        precondition(SystemCallActivity.contact(from: intent([person("sip:100@example.com")])) == nil)
        precondition(SystemCallActivity.contact(from: intent([person("Unbekannt")])) == nil)
        precondition(SystemCallActivity.contact(from: intent(nil)) == nil)
        let record = INCallRecord(__identifier: "missed-call", dateCreated: nil,
                                  callRecordType: .missed, callCapability: .audioCall,
                                  callDuration: nil, unseen: true, participants: [person("101")],
                                  numberOfCalls: 1, isCallerIdBlocked: false)
        precondition(SystemCallActivity.contact(from: intent(nil, record: record))?.number == "101")
        let blocked = INCallRecord(__identifier: "private-call", dateCreated: nil,
                                   callRecordType: .missed, callCapability: .audioCall,
                                   callDuration: nil, unseen: true, participants: [person("101")],
                                   numberOfCalls: 1, isCallerIdBlocked: true)
        precondition(SystemCallActivity.contact(from: intent(nil, record: blocked)) == nil)
        let handoff = NSUserActivity(activityType: "INStartCallIntent")
        handoff.userInfo = ["fonoo_request": "once", "fonoo_number": "100"]
        precondition(SystemCallActivity.request(from: handoff)?.contact.number == "100")
        precondition(SystemCallActivity.request(from: handoff)?.id == "once")
        let unsupported = NSUserActivity(activityType: "unrelated")
        unsupported.userInfo = handoff.userInfo
        precondition(SystemCallActivity.request(from: unsupported) == nil)
        let missingIdentity = NSUserActivity(activityType: "INStartCallIntent")
        missingIdentity.userInfo = ["fonoo_number": "100"]
        precondition(SystemCallActivity.request(from: missingIdentity) == nil)
        print("PASS: system redial, internal/E.164 normalization, call-record fallback, video/group/anonymous/invalid rejection and handoff identity")
    }
}
