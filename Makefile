.PHONY: app run test probe install uninstall-helper clean

app:
	./scripts/build-app.sh

run: app
	open build/MacPowerManager.app

test:
	swift test

probe:
	swift run smc-probe

# Copy app vào /Applications.
install: app
	rm -rf /Applications/MacPowerManager.app
	cp -R build/MacPowerManager.app /Applications/

uninstall-helper:
	sudo ./scripts/helper-install.sh uninstall

clean:
	rm -rf .build build
