# duongondro-ios

SwiftUI app for Duongöndro. The design lives in `Duongondro/duongondro-design` (read its `README.md` and `CLAUDE.md` first, then `docs/16-implementation-plan.md`). Work items are GitHub issues in this repository (#1–#8).

- **Build and test locally on the Mac, not on GitHub CI.** `make core-test`, then `make build`. Use the one iPhone simulator already installed; never install additional simulators or runtimes.
- **iOS 16 floor.** `ObservableObject`/`@Published`, not `@Observable`; single-argument `onChange`; `NavigationStack`. Newer features (Liquid Glass on 26, `sensoryFeedback`, symbol effects on 17+) go behind `if #available` inside small helpers in `App/Sources/Support/`, never in forked screens.
- **Logic lives in `Core/`**, tested with `swift test`. `Core/Tests/DuongondroCoreTests/Resources/streak-cases.json` and `Core/Tests/DuongondroCryptoTests/Resources/vectors.json` are copies of `duongondro-api/testdata/`; refresh them from there, never edit them here. End-to-end encryption lives in `DuongondroCrypto` (CryptoKit), which must reproduce every vector.
- **Theme tokens only** (`Theme.swift`): colours, small radii (4/6/8/12 pt), no literals in views. Light and dark designed together.
- **Fonts:** IBM Plex Sans SemiBold/Bold (`App/Resources/Fonts/`, OFL) for headings and big numbers, via `Typography` in `Theme.swift` (Dynamic Type through `relativeTo:`); the system font for prose, lists, buttons and labels; `.monospaced` only for invite codes and recovery words. No other bundled fonts. Note the SemiBold PostScript name is `IBMPlexSans-SmBld`.
- **Never log from Today.** Counts are logged only on a practice's screen, through `PendingLog` (5-second undo window, written only when it closes, no source recorded).
- **Day keys** come from `CivilDate` (Gregorian, explicit time zone), never `DateFormatter` with `YYYY`.
- **Release builds refuse a dirty tree** (`Scripts/build-info.sh`); Debug builds show `<hash>-dirty` in Settings.
- **Practice names:** Tibetan/Sanskrit first (Dorje Sempa, Chenrezig, Amitabha), English as the second line.
- Commits end with the attribution trailers the session asks for.
