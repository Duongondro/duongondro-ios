import SwiftUI
import DuongondroCore
import DuongondroStore

/// Today (design canvas "Today"): the date and title, the headline streak on a
/// burgundy card, then the daily practices as cards with their progress. No
/// logging here, so a stray tap while scrolling never adds a mala to the wrong
/// practice.
struct TodayView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: AccountModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(model.clock.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(.appLanguage)))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.muted)
                    Text("Today")
                        .font(Typography.largeTitle)
                        .accessibilityAddTraits(.isHeader)
                }
                .padding(.top, Theme.Space.l)
                HeadlineStreakCard(result: model.headline())
                    .padding(.top, Theme.Space.m)
                Text("Daily practices")
                    .font(.footnote.weight(.bold))
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(Theme.muted)
                    .padding(.top, Theme.Space.xl)
                    .padding(.bottom, Theme.Space.s)
                VStack(spacing: Theme.Space.s + Theme.Space.xxs) {
                    ForEach(model.snapshot.activePractices) { practice in
                        NavigationLink {
                            PracticeView(practiceID: practice.id)
                        } label: {
                            PracticeCard(practice: practice)
                        }
                        .buttonStyle(.plain)
                        .edgeScrollTransition()
                    }
                }
                // The mockup's line from Friends: the latest friend who finished today.
                if let latest = FriendsView.news(account.friends).first(where: \.doneToday) {
                    Button { model.tab = .friends } label: {
                        NewsRow(item: latest)
                            .padding(.horizontal, Theme.Space.l)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, Theme.Space.m)
                }
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.bottom, Theme.Space.xl)
        }
        .background(Theme.ground.ignoresSafeArea())
        .statusBarScrim()
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct HeadlineStreakCard: View {
    let result: Streak.Result

    var body: some View {
        HStack(spacing: Theme.Space.m + Theme.Space.xxs) {
            Image(systemName: "flame.fill")
                .font(.system(size: Theme.Size.heroFlame))
                .foregroundStyle(Theme.gold)
                .symbolBounce(value: result.current)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text("\(result.current) days")
                    .font(Typography.headingBold(28, relativeTo: .title))
                if result.current > 0 {
                    Text("Practice streak · longest \(result.longest)")
                        .font(.subheadline.weight(.medium))
                        .opacity(0.9)
                } else {
                    Text("Any practice today starts a streak.")
                        .font(.subheadline.weight(.medium))
                        .opacity(0.9)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.heroInk)
        .padding(.vertical, Theme.Space.l)
        .padding(.horizontal, Theme.Space.l + Theme.Space.xxs)
        .background(Theme.hero, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// One daily practice: the name with its streak, a progress bar for counted
/// practices, and a line saying where it stands. A streak-only practice shows a
/// filled check once done today.
private struct PracticeCard: View {
    @EnvironmentObject private var model: AppModel
    let practice: TrackedPractice

    var body: some View {
        let streak = model.streak(of: practice.id)
        let done = model.practisedToday(practice.id)
        let sessions = model.snapshot.sessions(of: practice.id)
        let rounds = practice.streakOnly ? nil : practice.rounds(sessions: sessions)
        HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xs + Theme.Space.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text(practice.practice.shownName)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    if streak.current > 0 {
                        HStack(spacing: Theme.Space.xxs) {
                            Image(systemName: "flame.fill").foregroundStyle(Theme.flame)
                            Text("\(streak.current)")
                        }
                        .font(.subheadline.weight(.bold))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("\(streak.current) days"))
                    }
                }
                if let rounds, let target = practice.practice.target {
                    Bar(fraction: Double(rounds.inRound) / Double(target))
                }
                Text(statusLine(rounds: rounds, sessions: sessions, done: done))
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if practice.streakOnly && done {
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.heavy))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: Theme.Size.checkBadge, height: Theme.Size.checkBadge)
                    .background(Theme.accent, in: Circle())
                    .accessibilityLabel(Text("Done today"))
            } else {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.muted)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, Theme.Space.m + Theme.Space.xxs)
        .padding(.leading, Theme.Space.l)
        .padding(.trailing, Theme.Space.m + Theme.Space.xxs)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).stroke(Theme.cardBorder, lineWidth: 1))
    }

    /// "Diamond Mind · 43,308 of 111,111", "12,960 of 111,111 · not yet today",
    /// "Loving Eyes · done today".
    private func statusLine(rounds: RoundProgress?, sessions: [Session], done: Bool) -> String {
        var parts: [String] = []
        if let second = practice.practice.shownSecondName { parts.append(second) }
        if let rounds, let target = practice.practice.target {
            let progress = rounds.round > 1
                ? String(localized: "round \(rounds.round) · \(rounds.inRound.grouped) of \(target.grouped)", bundle: .appLanguage, locale: .appLanguage)
                : String(localized: "\(rounds.inRound.grouped) of \(target.grouped)", bundle: .appLanguage, locale: .appLanguage)
            parts.append(progress)
        } else if !practice.streakOnly {
            parts.append(String(localized: "\(practice.lifetime(sessions: sessions).grouped) in total", bundle: .appLanguage, locale: .appLanguage))
        }
        if practice.streakOnly {
            parts.append(done ? String(localized: "done today", bundle: .appLanguage, locale: .appLanguage) : String(localized: "not yet today", bundle: .appLanguage, locale: .appLanguage))
        } else if !done {
            parts.append(String(localized: "not yet today", bundle: .appLanguage, locale: .appLanguage))
        }
        return parts.joined(separator: " · ")
    }
}

/// The leading name and, below it, the English second line. Wraps rather than
/// truncates: German and Hungarian run long.
struct PracticeName: View {
    let practice: Practice
    var large = false

    var body: some View {
        VStack(alignment: large ? .center : .leading, spacing: Theme.Space.xxs) {
            Text(verbatim: practice.shownName)
                .font(large ? Typography.title : Typography.headline)
                .multilineTextAlignment(large ? .center : .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let second = practice.shownSecondName {
                Text(verbatim: second)
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
    let model = AppModel.preview()
    return NavigationStack { TodayView() }
        .environmentObject(model)
        .environmentObject(AccountModel(database: model.database))
}
