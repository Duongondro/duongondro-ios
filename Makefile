# One simulator only: whatever iPhone is already installed. Never download runtimes.
SIM ?= $(shell xcrun simctl list devices available | grep -m1 -oE 'iPhone[[:alnum:] ]*' | sed 's/ *$$//')

.PHONY: core-test project build test release device testflight

# TEAM_ID, ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH for signing and uploading; kept
# out of the repository (see local.mk.example).
-include local.mk
SIGNING = DEVELOPMENT_TEAM=$(TEAM_ID) -allowProvisioningUpdates \
  -authenticationKeyPath $(ASC_KEY_PATH) -authenticationKeyID $(ASC_KEY_ID) -authenticationKeyIssuerID $(ASC_ISSUER_ID)
# Build numbers must rise with every upload: the commit count does.
BUILD_NUMBER = $(shell git rev-list --count HEAD)
DEVICE ?=

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

signing-check:
	@test -n "$(TEAM_ID)" -a -n "$(ASC_KEY_ID)" -a -n "$(ASC_ISSUER_ID)" -a -f "$(ASC_KEY_PATH)" || \
	  (echo "set TEAM_ID, ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH in local.mk (see local.mk.example)"; exit 1)

# The phone must be registered with the team first (an API key cannot do that from
# xcodebuild): App Store Connect › Devices, or POST /v1/devices with the same key.
device: project signing-check  ## Release build installed on a paired iPhone: make device DEVICE=<udid>
	@test -n "$(DEVICE)" || (echo "usage: make device DEVICE=<udid from 'xcrun devicectl device info details --device <name>'>"; exit 1)
	xcodebuild -project Duongondro.xcodeproj -scheme Duongondro -configuration Release \
	  -destination 'platform=iOS,id=$(DEVICE)' -derivedDataPath build/device build \
	  CURRENT_PROJECT_VERSION=$(BUILD_NUMBER) $(SIGNING)
	xcrun devicectl device install app --device "$(DEVICE)" build/device/Build/Products/Release-iphoneos/Duongondro.app

testflight: project signing-check  ## Archive from a clean tree and upload to App Store Connect
	rm -rf build/testflight
	xcodebuild -project Duongondro.xcodeproj -scheme Duongondro -configuration Release \
	  -destination 'generic/platform=iOS' -archivePath build/testflight/Duongondro.xcarchive archive \
	  CURRENT_PROJECT_VERSION=$(BUILD_NUMBER) $(SIGNING)
	sed 's/TEAM_ID/$(TEAM_ID)/' Scripts/ExportOptions.plist > build/testflight/ExportOptions.plist
	xcodebuild -exportArchive -archivePath build/testflight/Duongondro.xcarchive \
	  -exportOptionsPlist build/testflight/ExportOptions.plist -exportPath build/testflight $(SIGNING)
