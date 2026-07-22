import CoreLocation
import Foundation

/// Sunrise and sunset for a place and a day.
///
/// Night Shift's daemon already knows these, and its `sunSchedulePermitted`
/// flag proves it, but `CBBlueLightClient` exposes no accessor for them: the
/// status struct carries only the custom schedule, identical in sunset mode,
/// and nothing in the CoreBrightness preferences holds them either. So we
/// work them out, which means asking macOS where we are.
enum SolarTimes {

    /// NOAA's low-precision sunrise equation. Good to about a minute, which
    /// is far better than a label like this needs, and it is closed form:
    /// no tables, no network, no dependency.
    ///
    /// Returns nil above the polar circles when the sun does not cross the
    /// horizon that day, because there genuinely is no sunrise to print.
    static func riseAndSet(latitude: Double, longitude: Double, on date: Date)
        -> (sunrise: Date, sunset: Date)? {

        let rad = Double.pi / 180
        // Days since 2000-01-01 12:00 TT, rounded to the day. The 0.0008 is
        // a leap-second fudge carried by the published algorithm.
        let julian = date.timeIntervalSince1970 / 86400 + 2440587.5
        let n = (julian - 2451545.0 + 0.0008).rounded()

        // The published equation takes degrees WEST; ours is the usual
        // east-positive, so this subtracts where the paper adds. Sanity
        // check: 15 degrees east means solar noon an hour earlier in UTC,
        // so the term must reduce the transit, not raise it.
        let meanSolarNoon = n - longitude / 360
        let meanAnomaly = (357.5291 + 0.98560028 * meanSolarNoon)
            .truncatingRemainder(dividingBy: 360)
        let center = 1.9148 * sin(meanAnomaly * rad)
            + 0.0200 * sin(2 * meanAnomaly * rad)
            + 0.0003 * sin(3 * meanAnomaly * rad)
        let eclipticLongitude = (meanAnomaly + center + 180 + 102.9372)
            .truncatingRemainder(dividingBy: 360)

        let transit = 2451545.0 + meanSolarNoon
            + 0.0053 * sin(meanAnomaly * rad)
            - 0.0069 * sin(2 * eclipticLongitude * rad)

        let declination = asin(sin(eclipticLongitude * rad) * sin(23.44 * rad))
        // -0.833 degrees: the sun's disc is half a degree wide and the
        // atmosphere refracts it into view before it geometrically rises.
        let cosHourAngle = (sin(-0.833 * rad) - sin(latitude * rad) * sin(declination))
            / (cos(latitude * rad) * cos(declination))
        guard cosHourAngle >= -1, cosHourAngle <= 1 else { return nil }
        let hourAngle = acos(cosHourAngle) / rad

        func asDate(_ julianDay: Double) -> Date {
            Date(timeIntervalSince1970: (julianDay - 2440587.5) * 86400)
        }
        return (asDate(transit - hourAngle / 360), asDate(transit + hourAngle / 360))
    }
}

/// One coarse location fix, asked for only when something actually needs it.
///
/// Deliberately not started at launch: Luma asks for Accessibility because
/// brightness keys cannot work without it, and a location prompt on top of
/// that, before the user has gone anywhere near a sunset schedule, would be
/// asking for trust it has not earned yet.
///
/// Nothing is transmitted. The coordinate is used to compute two times for a
/// label and is never written to disk.
final class LocationOnce: NSObject, CLLocationManagerDelegate {
    static let shared = LocationOnce()

    private let manager = CLLocationManager()
    private var onFix: (() -> Void)?
    private(set) var coordinate: CLLocationCoordinate2D?
    private var asked = false

    /// Kilometre accuracy is plenty: a minute of sunset is roughly 20 km of
    /// north-south movement, and it is the least precise fix macOS offers.
    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Safe to call repeatedly; only the first call prompts.
    func request(_ onFix: @escaping () -> Void) {
        guard !asked else { return }
        asked = true
        self.onFix = onFix
        guard CLLocationManager.locationServicesEnabled() else { return }
        manager.requestWhenInUseAuthorization()
        manager.requestLocation()
    }

    var isDenied: Bool {
        [.denied, .restricted].contains(manager.authorizationStatus)
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        coordinate = locations.last?.coordinate
        DispatchQueue.main.async { self.onFix?() }
    }

    /// A refusal is an answer. Leaving `coordinate` nil makes the label fall
    /// back to prose, and we do not ask again this launch.
    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        if m.authorizationStatus == .authorizedAlways { m.requestLocation() }
    }
}
