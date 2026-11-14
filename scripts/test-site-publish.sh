#!/usr/bin/env bash
# Exercise the real Jekyll build and the atomic publisher against temporary fixtures.
#
# Runs inside the site image (offline): every case builds with the shipped gems,
# so this proves rendering, the failure path, and release retention for real
# instead of asserting on script text.
set -euo pipefail

TEMPLATE_DIR="${HORIZON_TEMPLATE_DIR:-/opt/horizon/docs}"
GEMFILE="${HORIZON_GEMFILE:-/opt/horizon/Gemfile}"
BUILD_SCRIPT="${HORIZON_BUILD_SITE:-/opt/horizon/scripts/build-site.sh}"
VERIFY_SCRIPT="${HORIZON_VERIFY_POSTS:-/opt/horizon/scripts/verify-posts.rb}"
FEED_SCRIPT="${HORIZON_FEED_ENTRIES:-/opt/horizon/scripts/feed-entries.rb}"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/horizon-site-test.XXXXXX")
SITE="$WORK/site"
POSTS="$WORK/posts"
SUMMARIES="$WORK/summaries"
mkdir -p "$SITE" "$POSTS" "$SUMMARIES"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

export HORIZON_TEMPLATE_DIR="$TEMPLATE_DIR"
export HORIZON_GEMFILE="$GEMFILE"
export HORIZON_VERIFY_POSTS="$VERIFY_SCRIPT"
export HORIZON_FEED_ENTRIES="$FEED_SCRIPT"

fail() { echo "FAIL: $*" >&2; exit 1; }

build() { bash "$BUILD_SCRIPT" --posts-dir "$POSTS" --site-dir "$SITE" "$@"; }

current_target() { readlink "$SITE/current"; }

SUMMARY_BODY='## 今日要点

- 模型推理性能提升
- 新的开源工具链

## 详情

正文引用原文链接。'

write_pair() { # <date>
  local date="$1"
  printf '# Horizon 日报 %s\n\n%s\n' "$date" "$SUMMARY_BODY" > "$SUMMARIES/horizon-$date-zh.md"
  {
    printf -- '---\nlayout: default\ntitle: "Horizon Summary: %s (ZH)"\ndate: %s\nlang: zh\n---\n\n' "$date" "$date"
    printf '%s\n' "$SUMMARY_BODY"
  } > "$POSTS/$date-summary-zh.md"
}

feed_entries() { # <feed path> -> prints "title<TAB>link" per entry, fails on invalid XML
  ruby "$FEED_SCRIPT" "$1"
}

# --- 1. empty state -------------------------------------------------------
echo "== initial empty site =="
build --initial-only
first=$(current_target)
[ -n "$first" ] || fail "--initial-only did not create a site"
[ -L "$SITE/current" ] || fail "current is not a symlink"
[ -f "$SITE/$first/index.html" ] || fail "current has no index.html"
[ -f "$SITE/$first/feed-zh.xml" ] || fail "current has no feed-zh.xml"
grep -q '暂无内容' "$SITE/$first/index.html" || fail "empty index lacks the placeholder"
entries=$(feed_entries "$SITE/$first/feed-zh.xml") || fail "empty feed is not valid Atom"
[ -z "$entries" ] || fail "empty feed already has entries"
[ ! -d "$SITE/$first/_posts" ] || fail "raw posts leaked into the published site"
[ ! -d "$SITE/$first/assets/../summaries" ] || fail "summaries leaked into the published site"

# --- 2. published post ----------------------------------------------------
echo "== publish a real daily post =="
write_pair "2026-11-14"
build --summaries-dir "$SUMMARIES"
second=$(current_target)
[ "$second" != "$first" ] || fail "publishing an unchanged site kept the same release"
[ -f "$SITE/$second/index.html" ] || fail "published index missing"
grep -q '2026-11-14' "$SITE/$second/index.html" || fail "index does not list the post date"
grep -rq '模型推理性能提升' "$SITE/$second" || fail "rendered post body missing"
entries=$(feed_entries "$SITE/$second/feed-zh.xml") || fail "feed is not valid Atom"
[ -n "$entries" ] || fail "feed has no entry for the published post"
link=$(printf '%s' "$entries" | cut -f2 | head -1)
case "$link" in
  https://*) ;;
  *) fail "feed entry link is not absolute HTTPS: $link" ;;
esac
post_path="$SITE/$second${link#https://horizon.great-wrasse.ts.net}"
for candidate in "${post_path%/}/index.html" "${post_path%/}.html" "$post_path"; do
  if [ -f "$candidate" ]; then post_path="$candidate"; break; fi
done
[ -f "$post_path" ] || fail "feed link $link does not resolve inside the release"
if grep -qF 'layout: default' "$post_path"; then fail "front matter leaked into the post page"; fi
if grep -qF '{{' "$post_path"; then fail "Liquid markup survived into the post page"; fi
before="$second"

# --- 3. broken post fails without touching the published release ----------
echo "== a post that cannot render is rejected =="
# Unbalanced Liquid makes Jekyll abort, which is the only post-level defect the
# builder must never publish. A merely weird date or layout is normalized by
# Jekyll itself and is not a build failure.
printf -- '---\nlayout: default\ntitle: "Bad"\ndate: 2026-11-17\nlang: zh\n---\n\n{%% if %%}\n' > "$POSTS/2026-11-17-summary-zh.md"
if build; then fail "build published a post Jekyll cannot render"; fi
[ "$(current_target)" = "$before" ] || fail "current moved after a failed build"
[ -f "$SITE/$before/index.html" ] || fail "previous release was destroyed"

# --- 4. stale/mismatched posts are refused --------------------------------
echo "== summary without a matching post is refused =="
printf '# Horizon 日报 2026-11-15\n\n%s\n' "$SUMMARY_BODY" > "$SUMMARIES/horizon-2026-11-15-zh.md"
printf -- '---\nlayout: default\ntitle: "Stale"\ndate: 2026-11-15\nlang: zh\n---\n\ndifferent body\n' > "$POSTS/2026-11-15-summary-zh.md"
if build --summaries-dir "$SUMMARIES"; then fail "publish accepted a mismatched post"; fi
rm -f "$POSTS/2026-11-15-summary-zh.md"
if build --summaries-dir "$SUMMARIES"; then fail "publish accepted a summary with no post"; fi
[ "$(current_target)" = "$before" ] || fail "current moved after a refused publish"
[ -f "$SITE/$before/index.html" ] || fail "previous release was destroyed"

# --- 5. --initial-only never overwrites ------------------------------------
echo "== --initial-only is a no-op once published =="
build --initial-only
[ "$(current_target)" = "$before" ] || fail "--initial-only replaced the published release"

# --- 6. retention keeps current + previous only ---------------------------
echo "== release retention =="
rm -f "$POSTS/2026-11-17-summary-zh.md" "$SUMMARIES/horizon-2026-11-15-zh.md"
write_pair "2026-11-16"
build --summaries-dir "$SUMMARIES"
new=$(current_target)
[ "$new" != "$before" ] || fail "new build did not publish"
[ -f "$SITE/$before/index.html" ] || fail "previous release was pruned"
[ -f "$SITE/$new/index.html" ] || fail "current release incomplete"
count=$(find "$SITE/releases" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')
[ "$count" -le 2 ] || fail "retained $count releases, expected at most 2"

echo "OK: site publish behaviour verified"
