#!/bin/zsh
# Screen tour: renders every main-window screen (each project × section × width) to PNG and opens the folder.
#   ./scripts/screens.sh <project folder> [<project folder> …]
#   LANG_SCREENS_OUT=<folder> ./scripts/screens.sh …     (default: ~/Desktop/lang-screens)
# Only reads the projects (no indexing, no recording). Uses a separate bundle id so it never touches the running app.
set -e
cd "$(dirname "$0")/.."

if [[ $# -eq 0 ]]; then
  echo "Cách dùng: ./scripts/screens.sh <thư mục dự án> [<thư mục dự án> …]"
  exit 1
fi
PROJECTS=""
for project in "$@"; do
  PROJECTS="${PROJECTS:+$PROJECTS:}${project:A}"
done

OUT="${LANG_SCREENS_OUT:-$HOME/Desktop/lang-screens}"
mkdir -p "$OUT"
# find instead of a *.png glob: zsh stops with "no matches found" when the folder is empty.
find "${OUT:?}" -maxdepth 1 -name '*.png' -delete

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
LANG_BUNDLE_SUFFIX=.clitests \
TEST_RUNNER_LANG_SNAPSHOT_DIR="$OUT" \
TEST_RUNNER_LANG_TOUR_PROJECTS="$PROJECTS" \
TEST_RUNNER_LANG_TEST_PROJECT="${1:A}" \
xcodebuild test -scheme MeetingMate -destination 'platform=macOS' \
  -derivedDataPath "${TMPDIR:-/tmp}/lang-screens-build" CODE_SIGN_IDENTITY=- \
  -only-testing:MeetingMateTests/ScreenTourTests -only-testing:MeetingMateTests/UISnapshotTests \
  2>&1 | grep -E "error:|✘|passed|failed|TEST (SUCCEEDED|FAILED)" || true

echo "Ảnh ở: $OUT ($(find "$OUT" -maxdepth 1 -name '*.png' | wc -l | tr -d ' ') ảnh)"
open "$OUT"
