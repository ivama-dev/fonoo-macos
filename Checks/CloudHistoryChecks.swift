import Foundation

@main struct CloudHistoryChecks {
    static func main() throws {
        let id = UUID().uuidString.lowercased()
        let now = Int64(Date().timeIntervalSince1970) - 60
        func payload(user: String = "user", tenant: String = "tenant", outcome: String = "completed", incoming: Bool = true,
                     duration: Int = 20, duplicate: Bool = false, unchanged: Bool = false) -> CloudHistoryPayload {
            let entry = CloudHistoryPayload.Entry(id: id, number: "+437200101010", incoming: incoming,
                                                 started_at: now, duration_seconds: duration, outcome: outcome)
            return CloudHistoryPayload(schema_version: 1, tenant_id: tenant, self_user_id: user, revision: 2,
                not_modified: unchanged, collector_available: true, last_collected_at: now,
                entries: duplicate ? [entry,entry] : [entry])
        }
        let rows = try payload().validated(tenant: "tenant", user: "user")
        precondition(rows.count == 1 && rows[0].id == UUID(uuidString: id) && rows[0].duration == 20 && !rows[0].missed)
        for bad in [payload(user:"other"),payload(tenant:"other"),payload(duplicate:true),
                    payload(outcome:"missed"),payload(outcome:"missed",incoming:false,duration:0),payload(unchanged:true)] {
            do { _ = try bad.validated(tenant:"tenant",user:"user"); preconditionFailure("Invalid history accepted") }
            catch { }
        }
        let missed = try payload(outcome:"missed",duration:0).validated(tenant:"tenant",user:"user")
        precondition(missed[0].missed && missed[0].incoming == true)
        print("PASS: shared history identity, account isolation, canonical IDs, duration and missed outcomes")
    }
}
