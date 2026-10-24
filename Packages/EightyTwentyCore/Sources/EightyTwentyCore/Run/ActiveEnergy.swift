import Foundation

/// Calories a run or walk burns on top of what you'd burn sitting still, for Apple Health.
///
/// ACSM's metabolic equations on flat ground: running takes 0.2 ml of oxygen per kg per
/// meter and walking 0.1, at about 5 kcal per liter of oxygen. That's about 1 kcal per kg
/// per km running and half that walking, at any pace.
public enum ActiveEnergy {
    public static func kilocalories(meters: Double, kilograms: Double, kind: ActivityKind) -> Double {
        let oxygenPerKgMeter = kind == .walk ? 0.1 : 0.2
        return oxygenPerKgMeter * kilograms * meters / 1000 * 5
    }
}
