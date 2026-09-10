.PHONY: build test hook-test signing-test

build:
	swift build

test:
	swift test

hook-test: build
	./scripts/hook-integration-test.sh

signing-test:
	./scripts/signing-argv-test.sh

app:
	bash scripts/make-app.sh

dmg: app
	bash scripts/make-dmg.sh
