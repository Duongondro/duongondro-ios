import SwiftUI
import PhotosUI

/// The mockup's cover at the top of a practice: the person's own photo if they
/// chose one, else the thangka of a built-in ngöndro practice (from the 2022
/// ngondro-tracker), else nothing. A photo never leaves the phone (design:
/// Overview, Cover photos).
struct CoverView: View {
    let practiceID: String
    @Environment(\.colorScheme) private var scheme
    @State private var image: UIImage?
    @State private var own = false
    @State private var choosing = false
    @State private var picking = false
    @State private var item: PhotosPickerItem?

    static let height: CGFloat = 300

    init(practiceID: String) {
        self.practiceID = practiceID
        // Loaded here, not on appear: with no image the view is empty and
        // would never appear to load one.
        let photo = Covers.photo(for: practiceID)
        _image = State(initialValue: photo ?? Covers.builtIn(for: practiceID))
        _own = State(initialValue: photo != nil)
    }

    var body: some View {
        Group {
            if let image {
                Color.clear
                    .frame(height: Self.height)
                    .overlay(Image(uiImage: image).resizable().scaledToFill(), alignment: .top)
                    .clipped()
                    .opacity(scheme == .dark ? Theme.coverOpacity.dark : Theme.coverOpacity.light)
                    .accessibilityHidden(true)
                    .overlay(alignment: .bottomTrailing) { changeButton.padding(Theme.Space.m) }
            }
        }
        .confirmationDialog("Cover", isPresented: $choosing) {
            Button("Choose a photo") { picking = true }
            if own { Button("Use the default", role: .destructive) { Covers.remove(for: practiceID); load() } }
        } message: {
            Text("Your photo stays on this phone: it is not synced or backed up.")
        }
        .photosPicker(isPresented: $picking, selection: $item, matching: .images)
        .onChange(of: item) { picked in
            guard let picked else { return }
            Task {
                if let data = try? await picked.loadTransferable(type: Data.self) {
                    try? Covers.save(data, for: practiceID)
                    load()
                }
                item = nil
            }
        }
    }

    private var changeButton: some View {
        Button { choosing = true } label: {
            Image(systemName: "photo")
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: Theme.Size.minTap, height: Theme.Size.minTap)
                .background(Theme.card.opacity(0.9), in: Circle())
        }
        .accessibilityLabel(Text("Change cover"))
    }

    private func load() {
        if let photo = Covers.photo(for: practiceID) {
            image = photo
            own = true
        } else {
            image = Covers.builtIn(for: practiceID)
            own = false
        }
    }
}

/// For practices without a cover: a quiet row offering one.
struct AddCoverButton: View {
    let practiceID: String
    let picked: () -> Void
    @State private var picking = false
    @State private var item: PhotosPickerItem?

    var body: some View {
        Button { picking = true } label: {
            Label("Add a cover photo", systemImage: "photo")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
        }
        .photosPicker(isPresented: $picking, selection: $item, matching: .images)
        .onChange(of: item) { chosen in
            guard let chosen else { return }
            Task {
                if let data = try? await chosen.loadTransferable(type: Data.self) {
                    try? Covers.save(data, for: practiceID)
                    picked()
                }
                item = nil
            }
        }
    }
}
