//
//  NetworkReachability.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  Checks for internet connectivity
//

import Foundation
import Network

/// Monitors network connectivity status
class NetworkReachability: ObservableObject {

    // MARK: - Published Properties

    @Published var isConnected: Bool = false
    @Published var connectionType: NWInterface.InterfaceType?

    // MARK: - Private Properties

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.tallyoh.networkmonitor", qos: .utility)

    // MARK: - Initialization

    init() {
        monitor = NWPathMonitor()
        startMonitoring()
    }

    deinit {
        stopMonitoring()
    }

    // MARK: - Public Methods

    /// Start monitoring network status
    func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isConnected = path.status == .satisfied

                // Determine connection type
                if path.usesInterfaceType(.wifi) {
                    self?.connectionType = .wifi
                } else if path.usesInterfaceType(.cellular) {
                    self?.connectionType = .cellular
                } else if path.usesInterfaceType(.wiredEthernet) {
                    self?.connectionType = .wiredEthernet
                } else {
                    self?.connectionType = nil
                }

                if self?.isConnected == true {
                    print("🌐 Internet connection available (\(self?.connectionType?.description ?? "unknown"))")
                } else {
                    print("🌐 No internet connection")
                }
            }
        }

        monitor.start(queue: queue)
    }

    /// Stop monitoring network status
    func stopMonitoring() {
        monitor.cancel()
    }

    /// Check if internet is reachable (one-time check)
    static func isInternetReachable(completion: @escaping (Bool) -> Void) {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "com.tallyoh.reachability.check", qos: .utility)

        monitor.pathUpdateHandler = { path in
            let isReachable = path.status == .satisfied
            DispatchQueue.main.async {
                completion(isReachable)
            }
            monitor.cancel()
        }

        monitor.start(queue: queue)

        // Timeout after 3 seconds
        DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) {
            monitor.cancel()
            DispatchQueue.main.async {
                completion(false)
            }
        }
    }

    /// Test internet connectivity by making a simple request
    static func testInternetConnectivity(completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "https://api.adsb.lol") else {
            completion(false)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5.0

        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                if let httpResponse = response as? HTTPURLResponse,
                   (200...299).contains(httpResponse.statusCode) {
                    completion(true)
                } else {
                    completion(false)
                }
            }
        }

        task.resume()
    }
}

// MARK: - Extensions

extension NWInterface.InterfaceType {
    var description: String {
        switch self {
        case .wifi:
            return "WiFi"
        case .cellular:
            return "Cellular"
        case .wiredEthernet:
            return "Ethernet"
        case .loopback:
            return "Loopback"
        case .other:
            return "Other"
        @unknown default:
            return "Unknown"
        }
    }
}
