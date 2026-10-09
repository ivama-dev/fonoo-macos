import Foundation

@main
struct TeamPresenceChecks {
    static func main() throws {
        let now = Date().timeIntervalSince1970
        let context = TeamContext(tenantID:"alpha",accountID:"owner",sessionID:UUID())
        let json = """
        {"schema_version":1,"tenant_id":"alpha","self_user_id":"owner","collector_available":true,
         "observed_at":\(now),"expires_at":\(now+15),"members":[
          {"user_id":"owner","state":"idle","call_count":0,"peer_number":null,"peer_user_id":null,"direction":null},
          {"user_id":"paul","state":"busy","call_count":1,"peer_number":"+436761234567","peer_user_id":null,"direction":"incoming"}]}
        """
        let snapshot = try JSONDecoder().decode(TeamPresenceSnapshot.self,from:Data(json.utf8)).validated(for:context)
        precondition(snapshot.presence(for:"paul").label == "Telefoniert")
        precondition(snapshot.presence(for:"paul",at:Date(timeIntervalSince1970:now+16)).state == "unknown")
        precondition(snapshot.presence(for:"absent").state == "unknown")
        for bad in [json.replacingOccurrences(of:"\"alpha\"",with:"\"beta\""),
            json.replacingOccurrences(of:"\"+436761234567\"",with:"\"sip:secret@host\""),
            json.replacingOccurrences(of:"\"state\":\"busy\"",with:"\"state\":\"idle\""),
            json.replacingOccurrences(of:"\"collector_available\":true",with:"\"collector_available\":false") ] {
            do { _ = try JSONDecoder().decode(TeamPresenceSnapshot.self,from:Data(bad.utf8)).validated(for:context); preconditionFailure("Invalid presence accepted") }
            catch { }
        }
        let member = TeamMember(id:"paul",name:"Paul",email:"paul@example.invalid",number:"505",personalDeviceCount:1,personalDevices:[])
        let team = TeamSnapshot(schemaVersion:1,tenantID:"alpha",tenantName:"Alpha",revision:1,selfUserID:"owner",members:[member])
        precondition(team.presenceMember(for:member.callContact(tenantID:"alpha")!)?.id == "paul")
        precondition(team.presenceMember(for:member.callContact(tenantID:"beta")!) == nil)
        precondition(team.presenceMember(for:Contact(id:"local",name:"Paul",role:"Intern",number:"505"))?.id == "paul")
        precondition(team.presenceMember(for:Contact(id:"external",name:"External",role:"Mobil",number:"+43505")) == nil)
        let contacts = [DeviceContact(id:"one",name:"Alex",numbers:[.init(id:"n",label:"Mobil",value:"0676 1234567")])]
        precondition(DeviceContact.resolvedContact(in:contacts,number:"+436761234567")?.name == "Alex")
        precondition(DeviceContact.resolvedContact(in:contacts,number:"00436761234567")?.name == "Alex")
        precondition(DeviceContact.resolvedContact(in:contacts,number:"567") == nil)
        precondition(DeviceContact.resolvedContact(in:contacts+contacts,number:"+436761234567") == nil)
        print("PASS: telephone presence expiry/schema, company-bound favorites and exact Austrian contact resolution")
    }
}
