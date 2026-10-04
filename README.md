# duongondro-ios

The iOS app for [Duongöndro](https://duongondro.app): track your meditation practice together with your friends, end-to-end encrypted and fully open source. SwiftUI, iOS 16 and later.

## Layout

| Path | Contents |
| --- | --- |
| `Core/` | `DuongondroCore`, a Swift package with no UI: practice catalogue, civil dates, streak engine, rounds, the undo window. Tested with `swift test` against the shared cases from `duongondro-api/testdata/` |
| `App/` | The SwiftUI app |
| `project.yml` | XcodeGen spec; the `.xcodeproj` is generated and not committed |
| `Scripts/build-info.sh` | Writes the source commit into the app; refuses Release builds from a dirty tree |

## Building

Needs Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
make core-test   # swift test for DuongondroCore
make build       # generate the project, build for one installed iPhone simulator
make release     # Release build, fails on a dirty tree
```

Set your development team in Xcode locally; it is not committed.

## Licence

BSD 3-Clause.
