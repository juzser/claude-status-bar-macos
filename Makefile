.PHONY: build test hook-test

build:
	swift build

test:
	swift test

hook-test: build
	./scripts/hook-integration-test.sh

app:
	bash scripts/make-app.sh

dmg: app
	rm -f dist/ClaudeStatusBar.dmg
	hdiutil create -volname ClaudeStatusBar -srcfolder dist/ClaudeStatusBar.app \
		-ov -format UDZO dist/ClaudeStatusBar.dmg
