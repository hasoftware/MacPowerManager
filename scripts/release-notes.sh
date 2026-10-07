#!/bin/sh
# In ghi chú phát hành của một version từ CHANGELOG.md (dùng trong workflow Release).
#   scripts/release-notes.sh 0.1.0
set -eu
cd "$(dirname "$0")/.."
awk -v v="$1" '
    $0 ~ "^## \\[" v "\\]" { f=1; next }
    /^## \[/ || /^\[[^]]+\]: / { f=0 }
    f
' CHANGELOG.md
