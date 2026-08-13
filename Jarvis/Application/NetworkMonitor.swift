import Foundation
import Network

final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.nandan.jarvis.network-monitor")
    private let lock = NSLock()
    private var reachable = true

    var isInternetLikelyAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return reachable
    }

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.lock.lock()
            self?.reachable = path.status == .satisfied
            self?.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
