import Foundation
import CoreLocation
import CoreWLAN

/// Answers "is the Mac in a trusted place right now?" by matching the connected Wi-Fi
/// network against TrustedPlaceStore.
///
/// Since macOS 14 the SSID is only readable by apps with Location Services permission, so
/// that permission is required for this feature. Unknown SSID (no permission, Wi-Fi off,
/// ethernet only) is always treated as NOT trusted - failing toward monitoring.
final class TrustedPlaceService: NSObject, CLLocationManagerDelegate {
    static let shared = TrustedPlaceService()

    private let store: TrustedPlaceStore
    private let currentSSIDProvider: () -> String?
    private lazy var locationManager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        return manager
    }()

    init(store: TrustedPlaceStore = .shared,
         currentSSID: @escaping () -> String? = { CWWiFiClient.shared().interface()?.ssid() }) {
        self.store = store
        self.currentSSIDProvider = currentSSID
    }

    var currentSSID: String? {
        guard let ssid = currentSSIDProvider(), !ssid.isEmpty else { return nil }
        return ssid
    }

    var isInTrustedPlace: Bool {
        guard let ssid = currentSSID else { return false }
        return store.isTrusted(ssid: ssid)
    }

    var locationDenied: Bool {
        let status = locationManager.authorizationStatus
        return status == .denied || status == .restricted
    }

    /// Triggers the one-time macOS Location prompt (no-op once decided).
    func requestLocationAccessIfNeeded() {
        guard locationManager.authorizationStatus == .notDetermined else { return }
        locationManager.requestWhenInUseAuthorization()
    }
}
