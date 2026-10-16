import Foundation

// Every effect size and DOI below was checked against the paper's abstract or
// results text (October 2026). Effects are vs a control condition unless the
// finding says otherwise. Percentages shown in the app are effect size × 33
// (see `EffectEstimate`), so only the effect size is stored here.
//
// Left out on purpose: music for stress (de Witte 2020, d = 0.55 on psychological
// stress) because the abstract doesn't say whether trials were one session or many,
// and cyclic sighing's own trial (Balban 2023), which reports no standardized
// effect, so the breathing entry uses the breathwork meta-analysis instead.

extension Intervention {
    public static let catalog: [Intervention] = feelBetterNow + buildItUp

    // MARK: Feel better now (measured right after one session)

    static let feelBetterNow: [Intervention] = [
        Intervention(
            id: "brisk-walk",
            title: "Brisk 10-minute walk",
            minutes: 10,
            timing: .rightAway,
            summary: "Easy-to-moderate movement lifts energy within minutes.",
            steps: [
                "Walk briskly for 10 minutes, outside if you can. A few flights of stairs at a steady pace work too.",
                "Keep it easy enough to talk. Low to moderate effort is where the energy boost is most reliable.",
                "Leave your phone in your pocket.",
            ],
            evidence: Evidence(
                citation: "Reed & Ones 2006, Psychology of Sport and Exercise",
                doi: "10.1016/j.psychsport.2005.11.003",
                grade: .a,
                effectSize: 0.47,
                outcome: "more energy",
                finding: "158 studies (13,101 people): right after one bout of aerobic exercise, energy and positive mood rose by an average effect of 0.47, most consistently at low intensity and for sessions up to 35 minutes. In a small crossover trial, 10 minutes of stair walking raised vigor more than 50 mg of caffeine (Randolph & O'Connor 2017)."
            ),
            targets: [.mood],
            logsAs: .walk
        ),
        Intervention(
            id: "nature",
            title: "Time outside in nature",
            minutes: 20,
            timing: .rightAway,
            summary: "Green space beats the same time indoors or on a city street.",
            steps: [
                "Go somewhere with trees, grass or water. A park or a tree-lined street counts.",
                "Spend 15 to 20 minutes there, walking or sitting.",
                "Put the phone away and notice what you see and hear.",
            ],
            evidence: Evidence(
                citation: "Yao et al. 2021, Frontiers in Public Health",
                doi: "10.3389/fpubh.2021.758457",
                grade: .a,
                effectSize: 0.61,
                outcome: "more positive mood",
                finding: "20 studies: time in natural settings raised positive mood (SMD 0.61, 95% CI 0.41-0.81) and lowered negative mood (SMD 0.47) compared with built environments. The studies varied a lot and many had a high risk of bias, so treat the size as rough."
            ),
            targets: [.mood, .stressBalance],
            logsAs: .nature,
            hours: 7...18
        ),
        Intervention(
            id: "reframe",
            title: "Reframe the thought (CBT)",
            minutes: 5,
            timing: .rightAway,
            summary: "The core CBT skill: look at the situation another way.",
            steps: [
                "Write down the thought that's bothering you, word for word.",
                "Ask what the evidence for it is, and what the evidence against it is.",
                "Ask what you'd tell a friend who had this thought.",
                "Write a more balanced version, then notice how strong the feeling is now.",
            ],
            evidence: Evidence(
                citation: "Webb, Miles & Sheeran 2012, Psychological Bulletin",
                doi: "10.1037/a0027600",
                grade: .a,
                effectSize: 0.36,
                outcome: "less negative emotion",
                finding: "306 experiments: reappraising the situation changed emotions in the intended direction by d = 0.36, and taking another person's perspective by d = 0.45. Distracting yourself had no effect on average (d = 0.00), and controlling the response, such as suppressing it, a small one (d = 0.16)."
            ),
            targets: [.mood, .stressBalance],
            logsAs: .reframe
        ),
        Intervention(
            id: "power-nap",
            title: "10-minute nap",
            minutes: 15,
            timing: .rightAway,
            summary: "Short enough to skip the grogginess, early enough to keep tonight's sleep.",
            steps: [
                "Find somewhere you can lie back: a couch, a quiet room, a reclined car seat.",
                "Set an alarm for 15 minutes, aiming for about 10 minutes of actual sleep.",
                "Get up when it rings. Naps of 30 minutes or more bring grogginess first.",
            ],
            evidence: Evidence(
                citation: "Dutheil et al. 2021, Int J Environ Res Public Health",
                doi: "10.3390/ijerph181910212",
                grade: .a,
                effectSize: 0.29,
                outcome: "more alertness",
                finding: "11 lab studies (381 adults): a daytime nap improved alertness vs no nap (effect 0.29, 95% CI 0.10-0.48). Brooks & Lack 2006 found 10 minutes the best length: benefits started right away and some lasted 155 minutes, while a 30-minute nap caused grogginess first."
            ),
            targets: [.mentalSleep, .mood],
            logsAs: .nap,
            hours: 12...16
        ),
    ]

    // MARK: Build it up (measured after weeks of practice)

    static let buildItUp: [Intervention] = [
        Intervention(
            id: "cyclic-sighing",
            title: "Cyclic sighing",
            minutes: 5,
            timing: .overWeeks,
            summary: "Two inhales, one long exhale, five minutes a day.",
            steps: [
                "Breathe in through your nose. When your lungs feel full, take one more short sip of air through your nose.",
                "Breathe out slowly through your mouth until your lungs are empty. The exhale should be longer than both inhales.",
                "Repeat for 5 minutes. Do it daily.",
            ],
            evidence: Evidence(
                citation: "Fincham et al. 2023, Scientific Reports",
                doi: "10.1038/s41598-022-27247-y",
                grade: .a,
                effectSize: 0.35,
                outcome: "less stress",
                finding: "12 randomized trials (785 adults): breathwork lowered self-reported stress vs controls (g = 0.35, 95% CI 0.14-0.55), with similar drops in anxiety (0.32) and depression (0.40). In Balban 2023, 5 minutes a day of cyclic sighing for a month lifted mood more than mindfulness meditation did."
            ),
            targets: [.stressBalance, .practice],
            logsAs: .breathwork
        ),
        Intervention(
            id: "meditation",
            title: "Mindfulness meditation",
            minutes: 10,
            timing: .overWeeks,
            summary: "Train attention on the breath; anxiety drops over about 8 weeks.",
            steps: [
                "Sit comfortably and close your eyes or lower your gaze.",
                "Rest your attention on the feeling of breathing.",
                "When your mind wanders, notice where it went and come back to the breath. That return is the exercise.",
                "Do it most days. The timer logs it for you.",
            ],
            evidence: Evidence(
                citation: "Goyal et al. 2014, JAMA Internal Medicine",
                doi: "10.1001/jamainternmed.2013.13018",
                grade: .a,
                effectSize: 0.38,
                outcome: "less anxiety",
                finding: "47 trials (3,515 people), all against active control programs: mindfulness programs reduced anxiety by 0.38 (95% CI 0.12-0.64) at 8 weeks and 0.22 at 3-6 months, and depression by 0.30 at 8 weeks. They didn't beat other active treatments such as exercise."
            ),
            targets: [.stressBalance, .practice],
            logsAs: .meditation,
            action: .meditationTimer
        ),
        Intervention(
            id: "muscle-relaxation",
            title: "Progressive muscle relaxation",
            minutes: 15,
            timing: .overWeeks,
            summary: "Tense and release each muscle group, feet to face.",
            steps: [
                "Lie or sit somewhere comfortable.",
                "Tense one muscle group (start with your feet) for about 5 seconds, then let go completely for 10 to 20 seconds.",
                "Work up through calves, thighs, stomach, hands, arms, shoulders and face.",
                "Notice the difference between tense and relaxed. Practice daily so it's quick when you need it.",
            ],
            evidence: Evidence(
                citation: "Manzoni et al. 2008, BMC Psychiatry",
                doi: "10.1186/1471-244X-8-41",
                grade: .a,
                effectSize: 0.51,
                outcome: "less anxiety",
                finding: "27 studies of relaxation training (progressive muscle relaxation, applied relaxation, meditation and similar): anxiety fell by d = 0.51 (95% CI 0.46-0.63) compared with control groups. Longer training gave larger effects."
            ),
            targets: [.stressBalance, .practice],
            logsAs: .relaxation
        ),
        Intervention(
            id: "three-good-things",
            title: "Three good things",
            minutes: 5,
            timing: .overWeeks,
            summary: "Each evening, three things that went well and why.",
            steps: [
                "Before bed, write down three things that went well today, big or small.",
                "For each one, write why it happened.",
                "Keep it up for at least a week.",
            ],
            evidence: Evidence(
                citation: "Cregg & Cheavens 2021, Journal of Happiness Studies",
                doi: "10.1007/s10902-020-00236-6",
                grade: .a,
                effectSize: 0.29,
                outcome: "fewer depression and anxiety symptoms",
                finding: "27 studies (3,675 people): gratitude exercises reduced symptoms of depression and anxiety by g = 0.29 after the program and 0.23 at follow-up. The authors call that modest. In Seligman 2005, three good things raised happiness and lowered depressive symptoms for six months."
            ),
            targets: [.mood, .practice],
            logsAs: .journaling,
            action: .gratitude
        ),
        Intervention(
            id: "self-compassion",
            title: "Self-compassion break",
            minutes: 5,
            timing: .overWeeks,
            summary: "Talk to yourself the way you'd talk to a friend who's struggling.",
            steps: [
                "Name it: \"This is hard right now.\"",
                "Remind yourself it's shared: \"Everyone struggles sometimes. I'm not alone in this.\"",
                "Put a hand on your chest and ask: \"What do I need right now?\" Then offer yourself that, in words or in action.",
            ],
            evidence: Evidence(
                citation: "Ferrari et al. 2019, Mindfulness",
                doi: "10.1007/s12671-019-01134-6",
                grade: .a,
                effectSize: 0.67,
                outcome: "less stress",
                finding: "27 randomized trials of self-compassion programs: moderate drops in stress (g = 0.67), depression (0.66) and anxiety (0.57), and a large drop in rumination (1.37). Against active comparison programs the depression effect wasn't significant."
            ),
            targets: [.mood, .stressBalance, .practice],
            logsAs: .selfCompassion
        ),
        Intervention(
            id: "kindness",
            title: "Do something kind",
            minutes: 5,
            timing: .overWeeks,
            summary: "Small, deliberate acts of kindness lift the person doing them.",
            steps: [
                "Do one kind thing for someone today: a thank-you text, help a coworker, buy someone a coffee.",
                "Make it on purpose, not on autopilot.",
                "Notice how it lands, for them and for you.",
            ],
            evidence: Evidence(
                citation: "Curry et al. 2018, Journal of Experimental Social Psychology",
                doi: "10.1016/j.jesp.2018.02.014",
                grade: .a,
                effectSize: 0.28,
                outcome: "more well-being",
                finding: "27 studies (4,045 people): performing acts of kindness raised the doer's well-being by δ = 0.28 (95% CI 0.16-0.41), a small-to-medium effect."
            ),
            targets: [.mood],
            logsAs: .kindness
        ),
        Intervention(
            id: "move-most-days",
            title: "Move most days",
            minutes: 30,
            timing: .overWeeks,
            summary: "Regular exercise builds energy and cuts fatigue over weeks.",
            steps: [
                "Get 20 to 30 minutes of movement on most days: walking counts.",
                "Keep most sessions easy to moderate.",
                "Log it, or let your Oura and Apple Health workouts count.",
            ],
            evidence: Evidence(
                citation: "Puetz, O'Connor & Dishman 2006, Psychological Bulletin",
                doi: "10.1037/0033-2909.132.6.866",
                grade: .a,
                effectSize: 0.37,
                outcome: "more energy, less fatigue",
                finding: "Randomized trials of regular exercise: feelings of energy rose and fatigue fell vs control conditions by δ = 0.37 (95% CI 0.29-0.45). Trials with a placebo control found no effect, so part of this may be expectation."
            ),
            targets: [.mood],
            logsAs: .walk
        ),
        Intervention(
            id: "expressive-writing",
            title: "Expressive writing",
            minutes: 15,
            timing: .overWeeks,
            summary: "Write freely about what's weighing on you, a few days running.",
            steps: [
                "Write for 15 to 20 minutes about your deepest thoughts and feelings on something that's bothering you.",
                "Don't worry about spelling or structure. Nobody reads it.",
                "Do it 3 or 4 days in a row.",
            ],
            evidence: Evidence(
                citation: "Frattaroli 2006, Psychological Bulletin",
                doi: "10.1037/0033-2909.132.6.823",
                grade: .a,
                // Reported as r = .075; converted with d = 2r / sqrt(1 - r²).
                effectSize: 0.15,
                outcome: "better health overall",
                finding: "146 randomized studies: writing about thoughts and feelings had a small average benefit across psychological and physical health (r = 0.075, about d = 0.15)."
            ),
            targets: [.mood, .practice],
            logsAs: .journaling
        ),
    ]
}
