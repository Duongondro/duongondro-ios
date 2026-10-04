import SwiftUI
import DuongondroCore

/// Today: daily practices and streaks. No logging here, so a stray tap while
/// scrolling never adds a mala to the wrong practice.
struct TodayView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.practices) { practice in
                    NavigationLink {
                        PracticeView(practice: practice)
                    } label: {
                        PracticeRow(practice: practice)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
        .background(Theme.ground.ignoresSafeArea())
        .navigationTitle("Today")
    }
}

private struct PracticeRow: View {
    let practice: Practice

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(practice.name).font(Typography.headline)
                if let second = practice.secondName {
                    Text(second).font(.subheadline).foregroundStyle(Theme.muted)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

/// A practice's own screen: the only place counts are logged.
struct PracticeView: View {
    @EnvironmentObject private var model: AppModel
    let practice: Practice
    @State private var taps = 0

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text(practice.name).font(Typography.largeTitle)
                if let second = practice.secondName {
                    Text(second).foregroundStyle(Theme.muted)
                }
            }
            Spacer()
            if let pending = model.pending, pending.practiceID == practice.id {
                HStack {
                    Text("Added \(pending.amount)")
                    Spacer()
                    Button("Undo") { model.pending = nil }.bold()
                }
                .cardStyle()
            }
            let mala = practice.effectiveMalaSize(default: model.malaSize)
            Button {
                taps += 1
                if var p = model.pending, p.practiceID == practice.id {
                    p.add(mala, at: Date())
                    model.pending = p
                } else {
                    model.pending = PendingLog(practiceID: practice.id, amount: mala, at: Date())
                }
            } label: {
                Text("+\(mala)")
                    .font(Typography.count)
                    .frame(maxWidth: .infinity, minHeight: 88)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: Theme.Radius.bigButton))
            .countTapFeedback(trigger: taps)
        }
        .padding(20)
        .background(Theme.ground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }
}
