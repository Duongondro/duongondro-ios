#!/bin/sh
# Writes the commit this build comes from into BuildInfo.plist, shown in
# Settings › About. Debug builds may come from a dirty tree ("-dirty");
# Release builds must not, so the hash in the App Store build exists on GitHub.
#
# Also writes Contributors.json for Settings › About: every human with a commit
# in this repository and its siblings (api, design, android) checked out next to
# it, most commits first, ties alphabetical. Names go through .mailmap; bots and
# AI authors are left out (Co-Authored-By trailers are never read).
set -eu

cd "${SRCROOT:-$(dirname "$0")/..}"
out="${DERIVED_FILE_DIR:-build}/BuildInfo.plist"
mkdir -p "$(dirname "$out")"

rev=$(git rev-parse HEAD 2>/dev/null || echo unknown)
dirty=false
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then dirty=true; fi

if [ "${CONFIGURATION:-Debug}" = "Release" ] && [ "$dirty" = true ]; then
  echo "error: refusing a Release build from a dirty tree; commit first" >&2
  git status --short >&2
  exit 1
fi

contributors="$(dirname "$out")/Contributors.json"
{
  for repo in . ../duongondro-api ../duongondro-design ../duongondro-android; do
    [ -d "$repo/.git" ] || continue
    git -C "$repo" log --use-mailmap --format='%aN%x09%aE' 2>/dev/null || true
  done
} | grep -viE '\[bot\]|bot@|noreply@anthropic\.com|noreply@openai\.com|^(claude|copilot|github-actions|dependabot)[[:space:]]' \
  | cut -f1 | sort | uniq -c | sort -k1,1nr -k2 \
  | sed -E 's/^ *[0-9]+ //; s/\\/\\\\/g; s/"/\\"/g; s/.*/"&"/' \
  | paste -sd, - | sed 's/^/[/; s/$/]/' > "$contributors"
[ -s "$contributors" ] || echo '[]' > "$contributors"

cat > "$out" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Revision</key><string>$rev</string>
  <key>Dirty</key><$dirty/>
</dict>
</plist>
EOF
