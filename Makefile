KIT := BatteryTraceKit
BTTRACE := $(KIT)/.build/release/bttrace
APP := build/DerivedData/Build/Products/Release/Battery Trace.app
UNIVERSAL_APP := build/DerivedDataUniversal/Build/Products/Release/Battery Trace.app

# The version comes from the release tag (see .github/workflows/release.yml),
# the build number from the commit count.
BUILD_NUMBER := $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
VERSION_SETTINGS := CURRENT_PROJECT_VERSION=$(BUILD_NUMBER) $(if $(MARKETING_VERSION),MARKETING_VERSION=$(MARKETING_VERSION),)

.PHONY: app run install universal dmg cli test smoke validate validate-powermetrics totals cost measure icon clean

# The menu bar app, Release, for this Mac, signed to run locally.
app:
	set -o pipefail; xcodebuild -project BatteryTrace.xcodeproj -scheme BatteryTrace -configuration Release \
		-derivedDataPath build/DerivedData $(VERSION_SETTINGS) build | grep -E "error:|warning:|BUILD"

run: app
	@pkill -f "Battery Trace.app/Contents/MacOS" 2>/dev/null || true
	open "$(APP)"

# Into /Applications, replacing any older copy, and open it. Settings and
# history live in the user's Library and stay.
install: app
	@pkill -f "Battery Trace.app/Contents/MacOS" 2>/dev/null || true
	rm -rf "/Applications/Battery Trace.app"
	ditto "$(APP)" "/Applications/Battery Trace.app"
	open "/Applications/Battery Trace.app"

# Apple silicon and Intel in one app, as releases ship.
universal:
	set -o pipefail; xcodebuild -project BatteryTrace.xcodeproj -scheme BatteryTrace -configuration Release \
		-derivedDataPath build/DerivedDataUniversal ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
		$(VERSION_SETTINGS) build | grep -E "error:|warning:|BUILD"

# build/BatteryTrace.dmg: the universal app with a drag-to-Applications link.
dmg: universal
	Scripts/make-dmg.sh "$(UNIVERSAL_APP)"

# The sampling layer as a command-line tool.
cli:
	cd $(KIT) && swift build -c release --product bttrace

test:
	cd $(KIT) && swift test

# Launches the built app and checks it stays up.
smoke: app
	Scripts/smoke-test.sh "$(APP)"

# Ranks against top's POWER (Activity Monitor's Energy Impact). No password.
validate: cli
	Scripts/validate.sh

# Against `sudo powermetrics` under idle, CPU, Safari video and GPU loads.
# Asks for your password once.
validate-powermetrics: cli
	Scripts/validate-powermetrics.sh

# Minute-by-minute totals against the battery gauge. Best run on battery.
totals: cli
	$(BTTRACE) totals --minutes 5

# What sampling costs Battery Trace itself.
cost: cli
	$(BTTRACE) cost

# The built app's own CPU, Energy Impact rank and memory, measured from outside.
measure: app
	Scripts/measure-app.sh

clean:
	cd $(KIT) && swift package clean
	rm -rf build
