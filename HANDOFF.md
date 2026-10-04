# Handoff to Claude Code on the Mac (4 October 2026)

Written by the cloud session that scaffolded this repository. It could not compile Swift (no Xcode there), so **nothing in `Core/` or `App/` has been compiled yet**. Start here:

1. `brew install xcodegen` if missing.
2. `make core-test`: fix any compile errors in `Core/` until all tests pass. The streak conformance test must pass unchanged against `Resources/streak-cases.json`; the Go reference (`duongondro-api/internal/streak`) passes the same 18 cases, so a failure is a Swift bug, not a case bug.
3. `make build`: fix the app target until it builds for the one installed iPhone simulator. Do not install other simulators.
4. Commit and push to `main`, then continue with issues #2–#8 in order (#5 app shell with GRDB, #6 onboarding and Settings, #7 GDPR export/purge UI, #8 modern look per iOS version).

Known gaps: the app uses placeholder state (`AppModel`) instead of GRDB; `vectors.json` is copied but no Swift crypto exists yet (comes with phase 3); `DEVELOPMENT_TEAM` is empty on purpose.

Delete this file once the first local build is green.
