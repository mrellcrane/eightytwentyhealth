import Foundation

/// Things you do that might move your bars. These are the *inputs* the
/// correlation engine will test against your Oura outcomes.
public enum ActivityKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case meditation
    case breathwork
    case run
    case walk
    case workout
    case yoga
    case sunlight
    case nature
    case social
    case sauna
    case coldExposure
    case alcohol
    case lateCaffeine
    case lateMeal
    case screensBeforeBed
    // Mental practices and coach steps, logged from the Mental screen.
    case reframe
    case journaling
    case selfCompassion
    case relaxation
    case music
    case kindness
    case nap
    /// A coach step that fits no kind above. Its note says what it was.
    case other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .meditation: return "Meditation"
        case .breathwork: return "Breathwork"
        case .run: return "Run"
        case .walk: return "Walk"
        case .workout: return "Strength"
        case .yoga: return "Yoga"
        case .sunlight: return "Morning sunlight"
        case .nature: return "Time in nature"
        case .social: return "Quality time with people"
        case .sauna: return "Sauna"
        case .coldExposure: return "Cold exposure"
        case .alcohol: return "Alcohol"
        case .lateCaffeine: return "Caffeine after 2pm"
        case .lateMeal: return "Late meal"
        case .screensBeforeBed: return "Screens in bed"
        case .reframe: return "Thought reframe"
        case .journaling: return "Expressive writing"
        case .selfCompassion: return "Self-compassion"
        case .relaxation: return "Muscle relaxation"
        case .music: return "Music"
        case .kindness: return "Act of kindness"
        case .nap: return "Nap"
        case .other: return "Other"
        }
    }

    /// SF Symbol name.
    public var systemImage: String {
        switch self {
        case .meditation: return "figure.mind.and.body"
        case .breathwork: return "wind"
        case .run: return "figure.run"
        case .walk: return "figure.walk"
        case .workout: return "dumbbell"
        case .yoga: return "figure.yoga"
        case .sunlight: return "sun.max"
        case .nature: return "leaf"
        case .social: return "person.2"
        case .sauna: return "flame"
        case .coldExposure: return "snowflake"
        case .alcohol: return "wineglass"
        case .lateCaffeine: return "cup.and.saucer"
        case .lateMeal: return "fork.knife"
        case .screensBeforeBed: return "iphone"
        case .reframe: return "arrow.triangle.2.circlepath"
        case .journaling: return "book.closed"
        case .selfCompassion: return "heart.circle"
        case .relaxation: return "figure.cooldown"
        case .music: return "music.note"
        case .kindness: return "gift"
        case .nap: return "powersleep"
        case .other: return "checkmark.circle"
        }
    }

    /// How a quick log is measured.
    public enum Measure: Sendable {
        case minutes(default: Double)
        case count(unit: String, default: Double)
        case occurrence
    }

    public var measure: Measure {
        switch self {
        case .meditation: return .minutes(default: 10)
        case .breathwork: return .minutes(default: 5)
        case .run: return .minutes(default: 30)
        case .walk: return .minutes(default: 20)
        case .workout: return .minutes(default: 45)
        case .yoga: return .minutes(default: 20)
        case .sunlight: return .minutes(default: 10)
        case .nature: return .minutes(default: 30)
        case .social: return .minutes(default: 60)
        case .sauna: return .minutes(default: 15)
        case .coldExposure: return .minutes(default: 3)
        case .alcohol: return .count(unit: "drinks", default: 1)
        case .lateCaffeine: return .occurrence
        case .lateMeal: return .occurrence
        case .screensBeforeBed: return .occurrence
        case .reframe: return .minutes(default: 10)
        case .journaling: return .minutes(default: 15)
        case .selfCompassion: return .minutes(default: 5)
        case .relaxation: return .minutes(default: 15)
        case .music: return .minutes(default: 15)
        case .kindness: return .occurrence
        case .nap: return .minutes(default: 15)
        case .other: return .minutes(default: 10)
        }
    }

    /// Counts toward the "Practices" component of the Mental bar: the evidence-backed
    /// mental practices, including time in nature and acts of kindness (see the catalog).
    /// Any log made from the catalog or a coach step that matched it counts too
    /// (`interventionID`, checked where practices are counted).
    public var isMentalPractice: Bool {
        switch self {
        case .meditation, .breathwork, .yoga, .reframe, .journaling, .selfCompassion, .relaxation, .nature, .kindness:
            return true
        default: return false
        }
    }

    /// Written to Apple Health as Mindful Minutes.
    public var isMindful: Bool {
        self == .meditation || self == .breathwork
    }

    /// Generally helps (true) or hurts (false). Used for UI tinting only;
    /// whether it helps *you* is the correlation engine's job.
    public var isGenerallyPositive: Bool {
        switch self {
        case .alcohol, .lateCaffeine, .lateMeal, .screensBeforeBed: return false
        default: return true
        }
    }

    /// Kinds shown in the quick-log grid, in order.
    public static let quickLog: [ActivityKind] = [
        .meditation, .breathwork, .walk, .workout, .yoga, .sunlight, .nature, .social,
        .sauna, .coldExposure, .alcohol, .lateCaffeine, .lateMeal, .screensBeforeBed,
    ]
}

/// Where a log entry came from. Stored as a string so new sources don't break old backups.
public enum ActivitySource: String, Codable, Sendable {
    case manual
    case meditationTimer
    case runRecorder
    case napTimer
    case ouraTag
    case ouraSession
    case healthKit
}
