import Foundation

/// Google's encoded polyline format (precision 1e-5, about 1 m). A 10 km run
/// shrinks from tens of KB of JSON to a few KB of text, small enough to keep
/// in the synced store and in plain-JSON backups.
public enum Polyline {
    public static func encode(_ coordinates: [(latitude: Double, longitude: Double)]) -> String {
        var result = ""
        var previousLat = 0
        var previousLon = 0
        for coordinate in coordinates {
            let lat = Int((coordinate.latitude * 1e5).rounded())
            let lon = Int((coordinate.longitude * 1e5).rounded())
            encodeValue(lat - previousLat, into: &result)
            encodeValue(lon - previousLon, into: &result)
            previousLat = lat
            previousLon = lon
        }
        return result
    }

    public static func decode(_ string: String) -> [(latitude: Double, longitude: Double)]? {
        let bytes = Array(string.utf8)
        var index = 0
        var lat = 0
        var lon = 0
        var result: [(latitude: Double, longitude: Double)] = []
        while index < bytes.count {
            guard let dLat = decodeValue(bytes, &index), let dLon = decodeValue(bytes, &index) else { return nil }
            lat += dLat
            lon += dLon
            result.append((Double(lat) / 1e5, Double(lon) / 1e5))
        }
        return result
    }

    private static func encodeValue(_ value: Int, into result: inout String) {
        var v = value < 0 ? ~(value << 1) : (value << 1)
        while v >= 0x20 {
            result.unicodeScalars.append(Unicode.Scalar(UInt8((0x20 | (v & 0x1f)) + 63)))
            v >>= 5
        }
        result.unicodeScalars.append(Unicode.Scalar(UInt8(v + 63)))
    }

    private static func decodeValue(_ bytes: [UInt8], _ index: inout Int) -> Int? {
        var result = 0
        var shift = 0
        while true {
            guard index < bytes.count else { return nil }
            let byte = Int(bytes[index]) - 63
            index += 1
            guard byte >= 0 else { return nil }
            result |= (byte & 0x1f) << shift
            shift += 5
            if byte < 0x20 { break }
            guard shift < 64 else { return nil }
        }
        return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
    }
}
