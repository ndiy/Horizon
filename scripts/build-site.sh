#!/usr/bin/env bash
# Build one immutable release of the Horizon digest site and publish it atomically.
#
# The container ships the stock Jekyll assets at ${HORIZON_TEMPLATE_DIR}; every
# run copies them into a scratch tree, injects the persistent posts, renders it,
# and only then repoints ``<site-dir>/current``. A failed build leaves the
# previously published release untouched.
set -euo pipefail

TEMPLATE_DIR="${HORIZON_TEMPLATE_DIR:-/opt/horizon/docs}"
GEMFILE="${HORIZON_GEMFILE:-/opt/horizon/Gemfile}"
VERIFY_SCRIPT="${HORIZON_VERIFY_POSTS:-/opt/horizon/scripts/verify-posts.rb}"
GEM_PATH="${HORIZON_GEM_PATH:-/opt/horizon/.gems}"
LOCK_TIMEOUT="${HORIZON_PUBLISH_LOCK_TIMEOUT:-900}"

POSTS_DIR=""
SITE_DIR=""
SUMMARIES_DIR=""
INITIAL_ONLY=0

usage() {
  cat <<'EOF'
Usage: build-site.sh --posts-dir PATH --site-dir PATH [--summaries-dir PATH] [--initial-only]

  --posts-dir PATH      Jekyll posts written by the collector ("<date>-summary-zh.md")
  --site-dir PATH       Persistent site root holding "releases/" and the "current" link
  --summaries-dir PATH  Collector summaries; every summary must match a published post
  --initial-only        Do nothing when the site is already published
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --posts-dir) POSTS_DIR="${2:?--posts-dir needs a value}"; shift 2 ;;
    --site-dir) SITE_DIR="${2:?--site-dir needs a value}"; shift 2 ;;
    --summaries-dir) SUMMARIES_DIR="${2:?--summaries-dir needs a value}"; shift 2 ;;
    --initial-only) INITIAL_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$POSTS_DIR" ] || [ -z "$SITE_DIR" ]; then
  echo "error: --posts-dir and --site-dir are required" >&2
  usage >&2
  exit 2
fi

POSTS_DIR=$(cd "$POSTS_DIR" && pwd)
SITE_DIR=$(cd "$SITE_DIR" && pwd)
if [ -n "$SUMMARIES_DIR" ]; then
  SUMMARIES_DIR=$(cd "$SUMMARIES_DIR" && pwd)
fi
RELEASES_DIR="$SITE_DIR/releases"
mkdir -p "$RELEASES_DIR"

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/horizon-site.XXXXXX")
RELEASE_DIR=""
PUBLISHED=0
cleanup() {
  # Releases become durable only after they are current; anything still in
  # RELEASE_DIR without PUBLISHED=1 is scratch from a failed run.
  if [ "$PUBLISHED" -eq 0 ] && [ -n "$RELEASE_DIR" ] && [ -d "$RELEASE_DIR" ]; then
    rm -rf "$RELEASE_DIR"
  fi
  rm -rf "$WORK_DIR"
}

# Current release target, resolved relative to the site root ("" when unpublished).
current_release() {
  local target
  target=$(readlink "$SITE_DIR/current" 2>/dev/null || true)
  [ -n "$target" ] || return 0
  case "$target" in
    /*) printf '%s' "$target" ;;
    *) printf '%s' "$SITE_DIR/$target" ;;
  esac
}

prune_releases() {
  local keep_current="$1" keep_previous="$2" entry path
  for entry in "$RELEASES_DIR"/*; do
    [ -e "$entry" ] || continue
    path=$(cd "$entry" && pwd)
    if [ "$path" = "$keep_current" ] || [ "$path" = "$keep_previous" ]; then
      continue
    fi
    case "$path" in
      "$RELEASES_DIR"/*) rm -rf "$path" ;;
      *) echo "warning: refusing to prune ${path} outside ${RELEASES_DIR}" >&2 ;;
    esac
  done
}

build_release() {
  local src="$WORK_DIR/source" destination="$1" home="$WORK_DIR/home"
  mkdir -p "$src" "$home"
  cp -a "$TEMPLATE_DIR/." "$src/"
  # Container images never ship posts; the persistent volume owns them.
  rm -rf "$src/_posts"
  mkdir -p "$src/_posts"
  find "$POSTS_DIR" -maxdepth 1 -type f -name '*.md' -exec cp -a {} "$src/_posts/" \;

  echo "building release ${destination#"$RELEASES_DIR"/}"
  HOME="$home" \
  JEKYLL_ENV=production \
  BUNDLE_GEMFILE="$GEMFILE" \
  BUNDLE_PATH="$GEM_PATH" \
  BUNDLE_FROZEN=true \
  bundle exec jekyll build \
    --config "$src/_config.yml,$src/_config.k8s.yml" \
    --source "$src" \
    --destination "$destination" \
    --disable-disk-cache

  [ -f "$destination/index.html" ] || { echo "error: index.html missing from build" >&2; return 1; }
  [ -f "$destination/feed-zh.xml" ] || { echo "error: feed-zh.xml missing from build" >&2; return 1; }
}

publish_release() {
  local release_dir="$1" previous="$2" link_tmp
  link_tmp="$SITE_DIR/.current.$$"
  rm -f "$link_tmp"
  ln -s "releases/$(basename "$release_dir")" "$link_tmp"
  mv -T "$link_tmp" "$SITE_DIR/current"
  PUBLISHED=1
  prune_releases "$release_dir" "$previous"
}

main() {
  local previous
  previous=$(current_release)
  if [ "$INITIAL_ONLY" -eq 1 ] && [ -n "$previous" ]; then
    echo "site already published at ${previous#"$SITE_DIR"/}; initial build skipped"
    return 0
  fi

  if [ -n "$SUMMARIES_DIR" ]; then
    ruby "$VERIFY_SCRIPT" --posts-dir "$POSTS_DIR" --summaries-dir "$SUMMARIES_DIR"
  fi

  RELEASE_DIR=$(mktemp -d "$RELEASES_DIR/release-$(date -u +%Y%m%d-%H%M%S)-XXXXXX")
  build_release "$RELEASE_DIR"
  publish_release "$RELEASE_DIR" "$previous"
  echo "published release $(basename "$RELEASE_DIR")"
}

trap cleanup EXIT
exec 9>"$SITE_DIR/.publish.lock"
if ! flock -w "$LOCK_TIMEOUT" 9; then
  echo "error: timed out waiting for the publish lock at $SITE_DIR/.publish.lock" >&2
  exit 1
fi
main
