.PHONY: build test hook-test

build:
	swift build

test:
	swift test

hook-test: build
	./scripts/hook-integration-test.sh
