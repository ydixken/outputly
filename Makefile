.PHONY: app lint test

app:
	sh scripts/package-app.sh

lint:
	sh -n scripts/package-app.sh
	plutil -lint Packaging/Info.plist
	swift build --build-tests -Xswiftc -warnings-as-errors

test:
	swift test
