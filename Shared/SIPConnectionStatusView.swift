import SwiftUI

struct SIPConnectionStatusView: View {
    @EnvironmentObject private var phone: PhoneStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Telefonieverbindung").font(.headline)
            LabeledContent("SDK", value: "Liblinphone · " + phone.sdkVersion)
            if phone.connectionRestarting { ProgressView("Verbindung wird erneuert …") }
            if let error = phone.connectionFailure {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                Button("Erneut verbinden") { Task { await phone.restartConnection() } }
                    .disabled(!phone.canRestartConnection)
            }
        }
    }
}
