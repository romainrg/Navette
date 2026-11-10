ifeq ($(shell xcode-select -p),/Library/Developer/CommandLineTools)
export DEVELOPER_DIR := $(lastword $(sort $(wildcard /Applications/Xcode*.app)))/Contents/Developer
endif

APP := build/Build/Products/Debug/Navette.app
XCB := xcodebuild -project Navette.xcodeproj -scheme Navette -destination 'platform=macOS' -derivedDataPath build

.PHONY: generate build test core-test check-strings run demo release clean

generate:
	xcodegen generate

build: generate
	$(XCB) build

test: generate
	$(XCB) test
	$(MAKE) check-strings

core-test:
	swift test --package-path NavetteCore $(if $(FILTER),--filter $(FILTER))

check-strings:
	scripts/check-strings.sh

run: build
	open $(APP)

demo: build
	$(APP)/Contents/MacOS/Navette --demo

release:
	scripts/build-release.sh

clean:
	rm -rf build Navette.xcodeproj Navette/Resources/Info.plist NavetteCore/.build
