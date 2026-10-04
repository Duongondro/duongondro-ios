import SwiftUI
import DuongondroCore
import DuongondroStore

/// Today: the headline streak and the daily practices. No logging here, so a
/// stray tap while scrolling never adds a mala to the wrong practice.
struct TodayView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HeadlineStreakCard(result: model.headline())
                ForEach(model.snapshot.activePractices) { practice in
                    NavigationLink {
                        PracticeView(practiceID: practice.id)
                    } label: {
                        PracticeRow(practice: practice)
                    }
                    .buttonStyle(.plain)
                    .edgeScrollTransition()
                }
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.vertical, Theme.Space.m)
        }
        .background(Theme.ground.ignoresSafeArea())
        .navigationTitle("Today")
    }
}

private struct HeadlineStreakCard: View {
    let result: Streak.Result

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Image(systemName: "flame.fill")
                .font(Typography.title)
                .foregroundStyle(Theme.flame)
                .symbolBounce(value: result.current)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("\(result.current) days")
                    .font(Typography.largeTitle)
                if result.current > 0, let deadline = result.deadline {
                    Text("Practise before \(CivilDate.of(deadline.addingTimeInterval(-1), in: .current).weekdayName()) ends")
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                } else {
                    Text("Any practice today starts a streak.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.l)
        .background(Theme.streakCard, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct PracticeRow: View {
    @EnvironmentObject private var model: AppModel
    let practice: TrackedPractice

    var body: some View {
        let streak = model.streak(of: practice.id)
        let done = model.practisedToday(practice.id)
        HStack(spacing: Theme.Space.m) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(done ? Theme.accent : Theme.muted)
                .symbolBounce(value: done)
                .accessibilityLabel(done ? Text("Done today") : Text("Not yet today"))
            VStack(alignment: .leading, spacing: 2) {
                PracticeName(practice: practice.practice)
                ProgressLine(practice: practice)
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: Theme.Space.s)
            if streak.current > 0 {
                Label("\(streak.current)", systemImage: "flame.fill")
                    .labelStyle(.titleAndIcon)
                    .font(Typography.headline)
                    .foregroundStyle(Theme.flame)
                    .accessibilityLabel(Text("\(streak.current) days"))
            }
            Image(systemName: "chevron.right").foregroundStyle(Theme.muted).accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

/// The leading name and, below it, the English second line. Wraps rather than
/// truncates: German and Hungarian run long.
struct PracticeName: View {
    let practice: Practice
    var large = false

    var body: some View {
        VStack(alignment: large ? .center : .leading, spacing: 2) {
            Text(practice.name)
                .font(large ? Typography.title : Typography.headline)
                .multilineTextAlignment(large ? .center : .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let second = practice.secondName {
                Text(second)
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(large ? .center : .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// "Round 5 · 35,556 of 111,111", a lifetime total, or "Streak only".
struct ProgressLine: View {
    @EnvironmentObject private var model: AppModel
    let practice: TrackedPractice

    var body: some View {
        let sessions = model.snapshot.sessions(of: practice.id)
        if practice.streakOnly {
            Text("Streak only")
        } else if let r = practice.rounds(sessions: sessions), let target = practice.practice.target {
            Text("Round \(r.round) · \(r.inRound.grouped) of \(target.grouped)")
        } else {
            Text("\(practice.lifetime(sessions: sessions).grouped) in total")
        }
    }
}

#Preview {
    NavigationStack { TodayView() }.environmentObject(AppModel.preview())
}
