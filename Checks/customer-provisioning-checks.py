"""Compile actual account decoding code without SwiftUI macro/plugin execution."""
from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[1]
source=(root/'Shared/CustomerAccount.swift').read_text()
configuration=source[source.index('private struct CustomerConfiguration:'):source.index('struct CloudMembership:')]
memberships=source[source.index('struct CloudMembership:'):source.index('@MainActor\nfinal class CustomerAccount:')]
checks=r'''
@main struct ProvisioningChecks {
 static func main() throws {
  let base: [String: Any] = ["server":"pbx.example.test", "domain":"pbx.example.test", "username":"phone1", "authentication_name":"phone1", "password":"fixture-only", "port":5061, "transport":"TLS", "stun_server":"", "turn_server":"", "turn_username":"", "turn_password":"", "turn_transport":"TCP", "stun_port":3478, "turn_port":443, "ice_enabled":false, "turn_enabled":false, "force_turn":false]
  func decode(_ fields: [String: Any]) throws -> SIPAccount {
   let payload=try JSONSerialization.data(withJSONObject:["revision":1,"configuration":fields])
   return try JSONDecoder().decode(CustomerConfiguration.self,from:payload).configuration.account()
  }
  precondition(try decode(base).mediaEncryption == .none)
  let secure=base.merging(["media_encryption":"SRTP","media_encryption_mandatory":true]){_,v in v}
  precondition(try decode(secure).mediaEncryption == .srtp)
  for invalid: [String:Any] in [["media_encryption":"RTP","media_encryption_mandatory":true],["media_encryption_mandatory":true],["media_encryption":"unexpected"]] {
   do { _ = try decode(base.merging(invalid){_,v in v}); fatalError("Invalid encryption downgrade accepted") } catch {}
  }
  let cloud=Data(#"{"tenants":[{"id":"test-company","name":"Testfirma","role":"member","extension":"101","trial":{"expires_at":1793000000,"expired":false,"telephony_status":"awaiting_pbx"}}]}"#.utf8)
  let result=try JSONDecoder().decode(CloudSummary.self,from:cloud)
  precondition(result.tenants[0].number == "101" && result.tenants[0].trial.telephony_status == "awaiting_pbx")
  let cloudFields: [String:Any] = ["status":"ready","tenant_id":"test-company","device_id":"iphone-a","schema_version":1,"backend":"asterisk","revision":4,"configuration":secure]
  func cloudReply(_ fields: [String:Any], tenant: String = "test-company", device: String = "iphone-a") throws -> CustomerConfiguration.Configuration? {
   let reply=try JSONDecoder().decode(CloudDeviceConfiguration.self,from:JSONSerialization.data(withJSONObject:fields))
   return try reply.validated(tenantID:tenant,deviceID:device)
  }
  let accepted=try cloudReply(cloudFields); precondition(accepted != nil)
  let pending=try cloudReply(["status":"provisioning","tenant_id":"test-company","device_id":"iphone-a"]); precondition(pending == nil)
  for invalid: [String:Any] in [["tenant_id":"other"],["device_id":"other"],["backend":"other"],["schema_version":2],["status":"unexpected"],["configuration":base],["configuration":secure.merging(["transport":"UDP"]){_,v in v}]] {
   do { _ = try cloudReply(cloudFields.merging(invalid){_,v in v}); fatalError("Unsafe cloud configuration accepted") } catch {}
  }
  func membership(_ id: String, number: String? = "500", expired: Bool = false, ready: Bool = true) throws -> CloudMembership {
   var fields: [String:Any] = ["id":id,"name":id,"role":"member","trial":["expired":expired,"telephony_status":ready ? "internal_ready" : "awaiting_pbx"]]
   if let number { fields["extension"] = number }
   return try JSONDecoder().decode(CloudMembership.self,from:JSONSerialization.data(withJSONObject:fields))
  }
  let first = try membership("systemiq"), second = try membership("ivama",number:"100")
  let selected = ["account_id":"ivan","tenant_id":"systemiq","endpoint_id":"phone500","extension":"500"]
  func decision(_ teams:[CloudMembership], selection:[String:String]? = nil, owner:String = "ivan", endpoint:String = "phone500", credentials:Bool = true) -> CloudSetupDecision {
   CloudAutoSetup.decision(teams,accountID:owner,selection:selection,endpoint:endpoint,hasCredentials:credentials)
  }
  precondition(decision([first]) == .configure("systemiq"))
  precondition(decision([first],selection:selected) == .keep("systemiq"))
  precondition(decision([first,second]) == .chooseCompany)
  precondition(decision([first,second],selection:selected) == .keep("systemiq"))
  precondition(decision([first,second],selection:selected,owner:"kevin") == .chooseCompany)
  precondition(decision([first],selection:selected,owner:"kevin") == .configure("systemiq"))
  precondition(decision([first],selection:selected,endpoint:"old-phone") == .configure("systemiq"))
  precondition(decision([first],selection:selected,credentials:false) == .configure("systemiq"))
  var legacySelection=selected;legacySelection.removeValue(forKey:"extension")
  precondition(decision([first],selection:legacySelection) == .configure("systemiq"))
  let reassigned = try membership("systemiq",number:"510")
  precondition(decision([reassigned],selection:selected) == .configure("systemiq"))
  for blocked in [try membership("systemiq",expired:true),try membership("systemiq",number:nil),try membership("systemiq",ready:false)] {
   precondition(decision([blocked],selection:selected) == .waiting)
  }
  precondition(decision([]) == .waiting)
  precondition(decision([first],owner:"") == .waiting)
  print("PASS: automatic single-company setup, explicit multi-company selection, identity binding, unchanged-profile reuse, trial guards and TLS/SRTP")
 }
}
'''
# throwing expressions cannot be evaluated by precondition's nonthrowing autoclosure.
checks=checks.replace('precondition(try decode(base).mediaEncryption == .none)','let legacy = try decode(base); precondition(legacy.mediaEncryption == .none)')
checks=checks.replace('precondition(try decode(secure).mediaEncryption == .srtp)','let cloudAccount = try decode(secure); precondition(cloudAccount.mediaEncryption == .srtp)')
build=root/'build/checks';build.mkdir(parents=True,exist_ok=True)
file=build/'CustomerProvisioningChecks.swift';file.write_text('import Foundation\n'+configuration+memberships+checks)
subprocess.run(['swiftc','-parse-as-library','-module-cache-path',str(build/'module-cache'),str(root/'Shared/SIPAccount.swift'),str(file),'-o',str(build/'CustomerProvisioningChecks')],check=True)
subprocess.run([str(build/'CustomerProvisioningChecks')],check=True)
