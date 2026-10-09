import Foundation
import Network

@MainActor
final class NetworkMonitor {
    var onChange: ((Bool, String) -> Void)?
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "Fonoo.NetworkMonitor")
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            let label = !available ? "Offline" : path.usesInterfaceType(.wifi) ? "WLAN" : path.usesInterfaceType(.cellular) ? "Mobilfunk" : "Netzwerk"
            Task { @MainActor [weak self] in self?.onChange?(available, label) }
        }
        monitor.start(queue: queue)
    }
    deinit { monitor.cancel() }
}
