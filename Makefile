.PHONY: app universal run test probe install package bump-patch bump-minor bump-major uninstall-helper clean

app:
	./scripts/build-app.sh

# Bản chạy được trên cả Apple Silicon và Intel (dùng cho release).
universal:
	UNIVERSAL=1 ./scripts/build-app.sh

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

# Tạo dist/*.dmg, dist/*.zip và SHA256SUMS.txt.
package: universal
	./scripts/package.sh

# Tăng version (sửa lỗi / tính năng / thay đổi lớn), commit và tạo tag.
bump-patch:
	./scripts/bump-version.sh patch
bump-minor:
	./scripts/bump-version.sh minor
bump-major:
	./scripts/bump-version.sh major

# Dùng helper vừa build để khôi phục SMC (helper đang cài có thể là bản cũ).
uninstall-helper:
	swift build -c release --product PowerHelper
	sudo ./scripts/helper-install.sh uninstall "$$(swift build -c release --show-bin-path)/PowerHelper"

clean:
	rm -rf .build build dist
