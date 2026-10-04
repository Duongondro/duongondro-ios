# One simulator only: whatever iPhone is already installed. Never download runtimes.
SIM ?= $(shell xcrun simctl list devices available | grep -m1 -o 'iPhone[^(]*' | sed 's/ *$$//')

.PHONY: core-test project build test release

core-test:            ## DuongondroCore unit and conformance tests (no simulator)
	cd Core && swift test

project:              ## Generate Duongondro.xcodeproj from project.yml
	xcodegen generate

build: project        ## Debug build for the simulator (dirty tree allowed)
	xcodebuild -project Duongondro.xcodeproj -scheme Duongondro -configuration Debug \
	  -destination 'platform=iOS Simulator,name=$(SIM)' -derivedDataPath build build

test: core-test build

release: project      ## Release build; Scripts/build-info.sh refuses a dirty tree
	xcodebuild -project Duongondro.xcodeproj -scheme Duongondro -configuration Release \
	  -destination 'generic/platform=iOS' -derivedDataPath build build CODE_SIGNING_ALLOWED=NO
