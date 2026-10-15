import Foundation

/// Apple's 7-step State of Mind scale. Stored as valence -1...1 so it maps
/// one-to-one onto HealthKit's `HKStateOfMind.valence`.
public enum MoodScale {
    public static let steps: [(valence: Double, label: String)] = [
        (-1, "Very unpleasant"),
        (-2.0 / 3, "Unpleasant"),
        (-1.0 / 3, "Slightly unpleasant"),
        (0, "Neutral"),
        (1.0 / 3, "Slightly pleasant"),
        (2.0 / 3, "Pleasant"),
        (1, "Very pleasant"),
    ]

    /// Step index 0...6 to valence.
    public static func valence(forStep step: Int) -> Double {
        steps[min(max(step, 0), steps.count - 1)].valence
    }

    /// Closest step index for a valence.
    public static func step(forValence valence: Double) -> Int {
        let clamped = min(max(valence, -1), 1)
        return Int(((clamped + 1) * 3).rounded())
    }

    public static func label(forValence valence: Double) -> String {
        steps[step(forValence: valence)].label
    }

    /// Emotion words offered as chips. Names match `HKStateOfMind.Label` cases
    /// so the app can mirror them into Apple Health.
    public static let pleasantEmotions = [
        "calm", "content", "grateful", "happy", "hopeful", "joyful", "peaceful",
        "proud", "relieved", "confident", "excited", "satisfied",
    ]
    public static let unpleasantEmotions = [
        "anxious", "stressed", "overwhelmed", "irritated", "frustrated", "sad",
        "lonely", "drained", "worried", "disappointed", "angry", "indifferent",
    ]
}
