#!/bin/sh
# Tăng version theo SemVer, cập nhật CHANGELOG, commit và tạo tag.
#   scripts/bump-version.sh patch|minor|major|X.Y.Z
# Sau đó: git push --follow-tags  (tag sẽ kích hoạt workflow Release trên GitHub)
set -eu

cd "$(dirname "$0")/.."
KIND="${1:-}"
CURRENT="$(tr -d '[:space:]' < VERSION)"

if [ -n "$(git status --porcelain)" ]; then
    echo "Lỗi: còn thay đổi chưa commit. Hãy commit trước khi bump version." >&2
    exit 1
fi

IFS=. read -r MAJOR MINOR PATCH <<EOV
$CURRENT
EOV
case "$KIND" in
    patch) NEW="$MAJOR.$MINOR.$((PATCH + 1))" ;;
    minor) NEW="$MAJOR.$((MINOR + 1)).0" ;;
    major) NEW="$((MAJOR + 1)).0.0" ;;
    *)
        if ! printf '%s' "$KIND" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
            echo "Cách dùng: $0 patch|minor|major|X.Y.Z" >&2
            exit 1
        fi
        NEW="$KIND"
        ;;
esac

if [ "$NEW" = "$CURRENT" ]; then
    echo "Lỗi: version mới trùng version hiện tại ($CURRENT)." >&2
    exit 1
fi
if [ "$(printf '%s\n%s\n' "$CURRENT" "$NEW" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" != "$NEW" ]; then
    echo "Lỗi: version mới ($NEW) phải lớn hơn version hiện tại ($CURRENT)." >&2
    exit 1
fi
if git rev-parse -q --verify "refs/tags/v$NEW" >/dev/null; then
    echo "Lỗi: tag v$NEW đã tồn tại." >&2
    exit 1
fi

# Phải có ghi chú trong mục [Unreleased] để đưa vào bản phát hành.
NOTES="$(awk '/^## \[Unreleased\]/{f=1; next} /^## \[/ || /^\[[^]]+\]: /{f=0} f' CHANGELOG.md | sed '/^[[:space:]]*$/d')"
if [ -z "$NOTES" ]; then
    echo "Lỗi: mục [Unreleased] trong CHANGELOG.md đang trống. Hãy ghi lại thay đổi trước." >&2
    exit 1
fi

DATE="$(date +%Y-%m-%d)"
echo "$NEW" > VERSION
sed -i '' "s/current = \".*\"/current = \"$NEW\"/" Sources/PowerCore/Version.swift
awk -v v="$NEW" -v d="$DATE" '
    /^## \[Unreleased\]/ { print; print ""; print "## [" v "] - " d; next }
    { print }
' CHANGELOG.md > CHANGELOG.md.tmp && mv CHANGELOG.md.tmp CHANGELOG.md

# Cập nhật link so sánh ở cuối CHANGELOG.
REPO_URL="https://github.com/hasoftware/MacPowerManager"
sed -i '' "s#^\[Unreleased\]: .*#[Unreleased]: $REPO_URL/compare/v$NEW...HEAD\\
[$NEW]: $REPO_URL/compare/v$CURRENT...v$NEW#" CHANGELOG.md

git add VERSION Sources/PowerCore/Version.swift CHANGELOG.md
git commit -q -m "chore(release): v$NEW"
git tag -a "v$NEW" -m "MacPowerManager v$NEW"
echo "Đã bump $CURRENT -> $NEW và tạo tag v$NEW."
echo "Đẩy lên GitHub để phát hành: git push --follow-tags"
