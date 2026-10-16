import Foundation

/// The small amount of statistics the pattern finder needs, without a dependency.
public enum Stats {
    /// Ranks starting at 1. Tied values share their average rank.
    public static func ranks(_ values: [Double]) -> [Double] {
        let order = values.indices.sorted { values[$0] < values[$1] }
        var ranks = [Double](repeating: 0, count: values.count)
        var start = 0
        while start < order.count {
            var end = start
            while end + 1 < order.count, values[order[end + 1]] == values[order[start]] { end += 1 }
            let average = Double(start + end) / 2 + 1
            for i in start...end { ranks[order[i]] = average }
            start = end + 1
        }
        return ranks
    }

    /// Pearson correlation, or nil when there are fewer than 3 pairs or either side never varies.
    public static func pearson(_ x: [Double], _ y: [Double]) -> Double? {
        guard x.count == y.count, x.count >= 3 else { return nil }
        let mx = mean(x), my = mean(y)
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for (a, b) in zip(x, y) {
            sxy += (a - mx) * (b - my)
            sxx += (a - mx) * (a - mx)
            syy += (b - my) * (b - my)
        }
        guard sxx > 0, syy > 0 else { return nil }
        return min(1, max(-1, sxy / (sxx * syy).squareRoot()))
    }

    /// Spearman's rank correlation: Pearson on ranks, so outliers and curves don't distort it.
    public static func spearman(_ x: [Double], _ y: [Double]) -> Double? {
        pearson(ranks(x), ranks(y))
    }

    public static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    /// Lag-1 autocorrelation of a series in time order. 0 when it can't be computed.
    public static func lag1Autocorrelation(_ values: [Double]) -> Double {
        guard values.count >= 3 else { return 0 }
        let m = mean(values)
        var numerator = 0.0, denominator = 0.0
        for i in values.indices {
            let d = values[i] - m
            denominator += d * d
            if i + 1 < values.count { numerator += d * (values[i + 1] - m) }
        }
        return denominator > 0 ? numerator / denominator : 0
    }

    /// How many independent days `n` days are worth when both series carry over from
    /// one day to the next (a good HRV week, a stressful fortnight). Without this,
    /// two slow drifts look like a strong finding. Bretherton et al. 1999, J Climate.
    public static func effectiveSampleSize(n: Int, autocorrelationX: Double, autocorrelationY: Double) -> Double {
        let product = autocorrelationX * autocorrelationY
        guard product > 0 else { return Double(n) }
        return max(3, Double(n) * (1 - product) / (1 + product))
    }

    /// Two-sided p-value for correlation `r` over `n` (possibly effective) observations,
    /// from the t distribution with n - 2 degrees of freedom.
    public static func correlationPValue(r: Double, n: Double) -> Double {
        let df = n - 2
        guard df >= 1 else { return 1 }
        let r2 = r * r
        guard r2 < 1 else { return 0 }
        // With t^2 = r^2 df / (1 - r^2), the two-sided tail is I_{df / (df + t^2)}(df/2, 1/2),
        // and df / (df + t^2) simplifies to 1 - r^2.
        return regularizedIncompleteBeta(a: df / 2, b: 0.5, x: 1 - r2)
    }

    /// Benjamini-Hochberg adjusted p-values, in the input order. Testing 50 pairs at
    /// p < 0.05 "finds" about 2 by luck; keeping adjusted p < 0.05 holds false finds to 5%.
    public static func benjaminiHochberg(_ pValues: [Double]) -> [Double] {
        let m = pValues.count
        let order = pValues.indices.sorted { pValues[$0] < pValues[$1] }
        var adjusted = [Double](repeating: 1, count: m)
        var running = 1.0
        for rank in stride(from: m, through: 1, by: -1) {
            let index = order[rank - 1]
            running = min(running, pValues[index] * Double(m) / Double(rank))
            adjusted[index] = running
        }
        return adjusted
    }

    /// I_x(a, b), by the continued fraction in Numerical Recipes (3rd ed., 6.4).
    static func regularizedIncompleteBeta(a: Double, b: Double, x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        // Split up: exp/lgamma/log are overloaded, and one long expression times out the type checker.
        let lnGammaA: Double = lgamma(a)
        let lnGammaB: Double = lgamma(b)
        let lnGammaAB: Double = lgamma(a + b)
        let lnBeta: Double = lnGammaA + lnGammaB - lnGammaAB
        let lnX: Double = log(x)
        let lnOneMinusX: Double = log(1 - x)
        let front: Double = exp(a * lnX + b * lnOneMinusX - lnBeta)
        if x < (a + 1) / (a + b + 2) {
            return front * betaContinuedFraction(a: a, b: b, x: x) / a
        }
        return 1 - front * betaContinuedFraction(a: b, b: a, x: 1 - x) / b
    }

    private static func betaContinuedFraction(a: Double, b: Double, x: Double) -> Double {
        let tiny = 1e-300
        let qab = a + b, qap = a + 1, qam = a - 1
        var c = 1.0
        var d = 1 - qab * x / qap
        if abs(d) < tiny { d = tiny }
        d = 1 / d
        var h = d
        for i in 1...300 {
            let m = Double(i)
            let m2: Double = 2 * m
            var aa: Double = m * (b - m) * x / ((qam + m2) * (a + m2))
            d = 1 + aa * d
            if abs(d) < tiny { d = tiny }
            c = 1 + aa / c
            if abs(c) < tiny { c = tiny }
            d = 1 / d
            h *= d * c
            let numerator: Double = (a + m) * (qab + m) * x
            aa = -numerator / ((a + m2) * (qap + m2))
            d = 1 + aa * d
            if abs(d) < tiny { d = tiny }
            c = 1 + aa / c
            if abs(c) < tiny { c = tiny }
            d = 1 / d
            let delta: Double = d * c
            h *= delta
            if abs(delta - 1) < 1e-15 { break }
        }
        return h
    }
}
