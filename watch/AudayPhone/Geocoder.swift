import AudayKit
import CoreLocation
import MapKit

/// Names a place with Apple's reverse geocoder, like Auday ("Place · Street"), only when it is a
/// real place; a plain street address stays unresolved, as most of Auday's do. The coordinate goes
/// to Apple for this lookup; nothing else leaves the phone except to the user's own Mac.
enum Geocoder {
    static func name(latitude: Double, longitude: Double) async -> String? {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        if #available(iOS 26.0, *) {
            guard let request = MKReverseGeocodingRequest(location: location),
                  let item = try? await request.mapItems.first else { return nil }
            let line = item.address?.shortAddress?.components(separatedBy: ",").first
            return PlaceNaming.placeLabel(name: item.name, addressLine: line, isPlace: item.pointOfInterestCategory != nil)
        } else {
            guard let mark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
            let area = mark.areasOfInterest?.first
            return PlaceNaming.placeLabel(name: area ?? mark.name, addressLine: mark.name, isPlace: area != nil)
        }
    }
}
