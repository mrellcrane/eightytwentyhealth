import Foundation

/// What to practice, for how long, and the research behind it, for the
/// Meditate screen. Every number below was checked against the paper's
/// abstract or results text (October 2026).
public enum MeditationStyle: String, CaseIterable, Sendable {
    case breath
    case bodyScan
    case cyclicSighing
    case selfCompassion

    public var title: String {
        switch self {
        case .breath: return "Breath-focused mindfulness"
        case .bodyScan: return "Body scan"
        case .cyclicSighing: return "Cyclic sighing"
        case .selfCompassion: return "Self-compassion meditation"
        }
    }

    public var steps: [String] {
        switch self {
        case .breath:
            return [
                "Sit upright and comfortable. Close your eyes or rest your gaze on the floor.",
                "Feel the breath where it's clearest: nostrils, chest or belly.",
                "When your mind wanders, notice where it went and come back to the breath. Every return is a rep.",
            ]
        case .bodyScan:
            return [
                "Lie down or sit back. Let your breathing settle.",
                "Move your attention slowly from your toes up to your head, a few breaths per area.",
                "Notice each sensation (warmth, pressure, tension) without trying to change it. If you fall asleep, that's fine.",
            ]
        case .cyclicSighing:
            return [
                "Breathe in through your nose. When your lungs feel full, take one more short sip of air.",
                "Breathe out slowly through your mouth until empty. Make the exhale longer than both inhales.",
                "Keep that rhythm, unhurried, for the whole timer.",
            ]
        case .selfCompassion:
            return [
                "Bring to mind what's hard right now, and say to yourself: \"This is hard.\"",
                "Remind yourself it's shared: \"Everyone struggles sometimes.\"",
                "Hand on your chest, offer yourself what you'd say to a friend: \"May I be kind to myself.\" Repeat slowly.",
            ]
        }
    }

    public var logsAs: ActivityKind {
        switch self {
        case .breath, .bodyScan: return .meditation
        case .cyclicSighing: return .breathwork
        case .selfCompassion: return .selfCompassion
        }
    }

    /// The catalog entry a session counts toward.
    public var interventionID: String? {
        switch self {
        case .breath, .bodyScan: return "meditation"
        case .cyclicSighing: return "cyclic-sighing"
        case .selfCompassion: return "self-compassion"
        }
    }
}

public struct MeditationFinding: Equatable, Identifiable, Sendable {
    public let id: String
    public let headline: String
    public let detail: String
    public let citation: String
    public let doi: String
    public let grade: Intervention.Grade

    public var url: URL? { URL(string: "https://doi.org/\(doi)") }
}

public struct MeditationPlan: Equatable, Sendable {
    public let style: MeditationStyle
    public let minutes: Int
    /// Why this today, from your data. Nil on an ordinary day.
    public let reason: String?
    /// The research behind the style and length.
    public let why: String
    public let evidence: MeditationFinding
}

public enum MeditationGuide {
    /// The daily dose that worked in Basso et al. 2019.
    public static let dailyMinutes = 13

    /// Picks the style and length for right now from the same signals as the
    /// Mental screen: late → body scan for sleep; stressed → cyclic sighing;
    /// low mood → self-compassion; otherwise daily breath-focused mindfulness.
    public static func plan(signals: RankingSignals) -> MeditationPlan {
        let reason = { (need: Intervention.Need) in signals.needs.first { $0.need == need }?.reason }

        if signals.hour >= 20 || signals.hour < 5 {
            return MeditationPlan(
                style: .bodyScan, minutes: 15,
                reason: reason(.lowSleep) ?? "It's late, so something that winds you down for sleep",
                why: "Mindfulness practice improved sleep quality against attention-matched activities, though not more than proven sleep treatments.",
                evidence: finding("sleep")
            )
        }
        if let stressed = reason(.stressed) {
            return MeditationPlan(
                style: .cyclicSighing, minutes: 5, reason: stressed,
                why: "Breathwork lowered stress across 12 randomized trials, and 5 minutes a day of cyclic sighing lifted mood more than mindfulness meditation over a month.",
                evidence: style("breathwork")
            )
        }
        if let low = reason(.lowMood) {
            return MeditationPlan(
                style: .selfCompassion, minutes: 10, reason: low,
                why: "Self-compassion programs cut stress and depression by moderate amounts across 27 randomized trials.",
                evidence: style("self-compassion")
            )
        }
        return MeditationPlan(
            style: .breath, minutes: dailyMinutes, reason: reason(.fewPractices),
            why: "13 minutes a day for 8 weeks improved mood, attention and memory and lowered anxiety under stress, compared with listening to podcasts. At 4 weeks nothing had changed yet, so give it two months.",
            evidence: dose[0]
        )
    }

    static func finding(_ id: String) -> MeditationFinding { findings.first { $0.id == id }! }
    static func style(_ id: String) -> MeditationFinding { styles.first { $0.id == id }! }

    /// How long and how often.
    public static let dose: [MeditationFinding] = [
        MeditationFinding(
            id: "basso", headline: "About 13 minutes a day is enough to start",
            detail: "New meditators did 13 minutes a day of guided meditation or listened to a podcast for 8 weeks. Meditation lowered negative mood, improved attention, working memory and recognition memory, and lowered anxiety during a stress test. At 4 weeks there was no difference yet.",
            citation: "Basso et al. 2019, Behavioural Brain Research", doi: "10.1016/j.bbr.2018.08.023", grade: .b
        ),
        MeditationFinding(
            id: "parsons", headline: "What people in 8-week courses actually did",
            detail: "Across 43 studies (1,427 people) of MBSR and MBCT, people did 64% of the home practice they were given, about 30 minutes a day, 6 days a week. More practice went with somewhat better results (r = 0.26).",
            citation: "Parsons et al. 2017, Behaviour Research and Therapy", doi: "10.1016/j.brat.2017.05.004", grade: .a
        ),
        MeditationFinding(
            id: "strohmaier", headline: "Daily beats long",
            detail: "Across 203 randomized trials (15,971 people), bigger doses of mindfulness programs (more sessions, longer sessions, more practice) did not predict bigger drops in depression, anxiety or stress.",
            citation: "Strohmaier 2020, Mindfulness", doi: "10.1007/s12671-020-01319-4", grade: .a
        ),
    ]

    /// What meditation does and doesn't do.
    public static let findings: [MeditationFinding] = [
        MeditationFinding(
            id: "anxiety", headline: "Less anxiety and depression, against real comparison programs",
            detail: "47 trials (3,515 people), all compared with active control programs: mindfulness programs reduced anxiety by 0.38 (95% CI 0.12-0.64) at 8 weeks and 0.22 at 3-6 months, and depression by 0.30. They weren't better than drugs, exercise or other therapies, and showed no clear effect on positive mood, attention, sleep or weight.",
            citation: "Goyal et al. 2014, JAMA Internal Medicine", doi: "10.1001/jamainternmed.2013.13018", grade: .a
        ),
        MeditationFinding(
            id: "everyday", headline: "It works for everyday stress, not just for patients",
            detail: "136 trials (11,605 adults, outside clinical settings): compared with doing nothing, mindfulness courses lowered anxiety (SMD 0.56), depression (0.53) and distress (0.45) and raised wellbeing (0.33), measured 1-6 months later. Against other active activities they were mostly no better, and in the best-quality trials only the drop in distress held.",
            citation: "Galante et al. 2021, PLOS Medicine", doi: "10.1371/journal.pmed.1003481", grade: .a
        ),
        MeditationFinding(
            id: "medication", headline: "As good as an antidepressant for anxiety disorders",
            detail: "276 adults with anxiety disorders got 8 weeks of MBSR or escitalopram. Anxiety severity fell about the same (difference −0.07, 95% CI −0.38 to 0.23). Side effects: 15% with MBSR, 79% with the drug.",
            citation: "Hoge et al. 2023, JAMA Psychiatry", doi: "10.1001/jamapsychiatry.2022.3679", grade: .b
        ),
        MeditationFinding(
            id: "healthy", headline: "Healthy people get less stressed too",
            detail: "29 studies (2,668 healthy adults): MBSR beat control groups by g = 0.53 (95% CI 0.41-0.64), with large effects on stress and moderate effects on anxiety and depression, still there about 19 weeks later.",
            citation: "Khoury et al. 2015, Journal of Psychosomatic Research", doi: "10.1016/j.jpsychores.2015.03.009", grade: .a
        ),
        MeditationFinding(
            id: "sleep", headline: "Better sleep, but not better than sleep therapy",
            detail: "18 randomized trials (1,654 people): mindfulness improved sleep quality by 0.33 (95% CI 0.17-0.48) compared with attention-matched activities, and by 0.54 at follow-up. Against proven sleep treatments it made no difference (0.03).",
            citation: "Rusch et al. 2019, Annals of the New York Academy of Sciences", doi: "10.1111/nyas.13996", grade: .a
        ),
        MeditationFinding(
            id: "disorders", headline: "Holds up against standard treatments",
            detail: "142 groups (12,005 people with psychiatric conditions): mindfulness beat no treatment (d = 0.55) and other active controls (d = 0.23-0.35), and did as well as evidence-based treatments (d = −0.004). The evidence is most consistent for depression, pain, smoking and addiction.",
            citation: "Goldberg et al. 2018, Clinical Psychology Review", doi: "10.1016/j.cpr.2017.10.011", grade: .a
        ),
        MeditationFinding(
            id: "brief", headline: "One-off sessions do little on their own",
            detail: "65 randomized trials (5,489 people) of brief training, from a single session to 2 weeks: a small drop in negative feelings (g = 0.21), shrinking to 0.04 after correcting for unpublished null results. The benefits come from weeks of practice.",
            citation: "Schumer, Lindsay & Creswell 2018, J Consult Clin Psychol", doi: "10.1037/ccp0000324", grade: .a
        ),
        MeditationFinding(
            id: "hrv", headline: "Don't expect your Oura HRV to rise",
            detail: "19 randomized trials: no reliable effect on resting HRV (g = 0.38, 95% CI −0.01 to 0.77; 0.19 without one outlier). Judge it by how you feel and your mood check-ins, not by HRV.",
            citation: "Brown et al. 2021, Psychosomatic Medicine", doi: "10.1097/PSY.0000000000000900", grade: .a
        ),
        MeditationFinding(
            id: "safety", headline: "Side effects are uncommon, but real",
            detail: "83 studies (6,703 people): unwanted effects, most often anxiety or low mood, in 8.3% overall and 3.7% in experimental studies, including people with no mental-health history. If practice makes you feel worse, scale back or stop.",
            citation: "Farias et al. 2020, Acta Psychiatrica Scandinavica", doi: "10.1111/acps.13225", grade: .a
        ),
    ]

    /// The evidence behind the non-mindfulness styles.
    public static let styles: [MeditationFinding] = [
        MeditationFinding(
            id: "breathwork", headline: "Breathwork lowers stress",
            detail: "12 randomized trials (785 adults): breathwork lowered self-reported stress (g = 0.35, 95% CI 0.14-0.55), anxiety (0.32) and depression (0.40). In Balban 2023, 5 minutes a day of cyclic sighing for a month lifted mood more than mindfulness meditation.",
            citation: "Fincham et al. 2023, Scientific Reports", doi: "10.1038/s41598-022-27247-y", grade: .a
        ),
        MeditationFinding(
            id: "self-compassion", headline: "Self-compassion eases stress and low mood",
            detail: "27 randomized trials of self-compassion programs: moderate drops in stress (g = 0.67), depression (0.66) and anxiety (0.57), and a large drop in rumination (1.37).",
            citation: "Ferrari et al. 2019, Mindfulness", doi: "10.1007/s12671-019-01134-6", grade: .a
        ),
    ]
}
