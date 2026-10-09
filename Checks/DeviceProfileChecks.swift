import Foundation
@main struct DeviceProfileChecks {
    static func main() throws {
        let standard=AvailabilitySnapshot.DeviceProfile.standard
        let data=try JSONEncoder().encode(standard)
        let fields=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        precondition(fields["device_ids"] is NSNull)
        let decoded=try JSONDecoder().decode(AvailabilitySnapshot.DeviceProfile.self,from:data)
        precondition(decoded == standard)
        let json = #"{"schema_version":1,"device_profiles_version":1,"profiles_available":true,"tenant_id":"alpha","user_id":"owner","self_user_id":"owner","revision":7,"settings":{"presence":null,"work_mode":"custom","mode_devices":{},"schedule_id":null,"device_profiles":[{"id":"standard","name":"Standard","device_ids":null},{"id":"work","name":"Büro","device_ids":["mac"]}],"active_profile_id":"work"},"effective":{"eligible":true,"reason_text":"Verfügbar","next_available_at":null,"effective_devices":[],"presence":null},"call_teams":[],"personal_devices":[{"id":"mac","name":"Mac","user_id":"owner","enabled":true},{"id":"foreign","name":"Fremd","user_id":"other","enabled":true}],"standalone_devices":[],"schedules":[],"company":{"routing_enabled":false}}"#
        let valid=try JSONDecoder().decode(AvailabilitySnapshot.self,from:Data(json.utf8))
        precondition(valid.profilesValid && valid.settings.activeProfile.name == "Büro")
        for bad in [json.replacingOccurrences(of:"[\"mac\"]",with:"[\"foreign\"]"),json.replacingOccurrences(of:"\"active_profile_id\":\"work\"",with:"\"active_profile_id\":\"absent\"")] {
            let decoded=try JSONDecoder().decode(AvailabilitySnapshot.self,from:Data(bad.utf8))
            precondition(!decoded.profilesValid)
        }
        print("PASS: profile contract, explicit Standard null, selected profile and foreign-device/unknown-profile rejection")
    }
}
