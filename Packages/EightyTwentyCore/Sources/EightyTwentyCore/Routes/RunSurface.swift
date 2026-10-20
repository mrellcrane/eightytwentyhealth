import Foundation

/// What a path is made of, for picking where to run. OpenStreetMap's many surface
/// tags fold into these six (see `tools/routes/build_routes.py`).
public enum RunSurface: String, Codable, CaseIterable, Identifiable, Sendable {
    case asphalt
    case concrete
    case gravel
    case dirt
    case boardwalk
    case track

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .asphalt: return "Asphalt"
        case .concrete: return "Concrete"
        case .gravel: return "Gravel"
        case .dirt: return "Dirt"
        case .boardwalk: return "Boardwalk"
        case .track: return "Track"
        }
    }

    public var detail: String {
        switch self {
        case .asphalt: return "Blacktop trails and park paths"
        case .concrete: return "Promenades, plazas and concrete paths, the hardest underfoot"
        case .gravel: return "Crushed rock and packed fines"
        case .dirt: return "Natural trail: earth, bark, grass, roots"
        case .boardwalk: return "Wood and composite boardwalks"
        case .track: return "Rubberized running tracks"
        }
    }

    /// Easier on the legs than pavement.
    public var isSoft: Bool {
        switch self {
        case .gravel, .dirt, .track: return true
        case .asphalt, .concrete, .boardwalk: return false
        }
    }

    /// Stored in UserDefaults as "asphalt,dirt". Empty or unreadable means all of them.
    public static func set(from stored: String) -> Set<RunSurface> {
        let picked = Set(stored.split(separator: ",").compactMap { RunSurface(rawValue: String($0)) })
        return picked.isEmpty ? Set(allCases) : picked
    }

    /// A tap on a surface chip. With everything showing, it picks just that surface
    /// ("only dirt"); after that it adds or removes one; removing the last shows all again.
    public static func toggled(_ surface: RunSurface, in picked: Set<RunSurface>) -> Set<RunSurface> {
        if picked.count == allCases.count { return [surface] }
        var next = picked
        if next.contains(surface) { next.remove(surface) } else { next.insert(surface) }
        return next.isEmpty ? Set(allCases) : next
    }

    public static func stored(_ surfaces: Set<RunSurface>) -> String {
        allCases.filter(surfaces.contains).map(\.rawValue).joined(separator: ",")
    }
}
