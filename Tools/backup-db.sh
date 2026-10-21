#!/bin/bash
#
# Back up the Shhhcribble transcript library.
#
# WHY THIS EXISTS: on 2026-08-31 this Mac was wiped and the entire transcript
# library went with it — ~1,100 dictations and every note. The commit before the
# wipe was literally "Raise sync's priority: the data has no backup story at
# all". The risk was identified, written down, ranked, and landed before it was
# acted on. This is the cheap thing that stops it happening twice while proper
# sync waits for a design session.
#
# WHY sqlite3 .backup AND NOT cp: the app may be writing while this runs. `cp`
# of a live SQLite file can capture a torn page and produce a backup that only
# fails when you try to restore it — the worst kind. `.backup` uses SQLite's
# online backup API, which is safe against a concurrent writer.
#
# USAGE
#   bash Tools/backup-db.sh                 # back up to the default destination
#   DEST=/some/where bash Tools/backup-db.sh
#
# WHERE BACKUPS GO — change DEST below, it is the only decision here.
#   NOT ~/Documents, ~/Desktop or ~/Downloads. All three are TCC-protected,
#   and a launchd agent has no grant for them — measured 2026-10-21: the backup
#   wrote but the rotation's `find` was denied, so the job exited 1 on every
#   run while still appearing to produce files. The home directory root is not
#   gated, which is why the default sits there.
#
#   Local (default)  keeps the "nothing leaves your Mac" promise intact and
#                    protects against a bad migration or an app bug. It does NOT
#                    protect against the failure that actually happened: the
#                    machine going away.
#   iCloud Drive     survives a dead or stolen Mac. The library is ~800 KB so
#                    the cost is nothing. But it is your own dictation leaving
#                    the machine, which is the thing this product promises not
#                    to do — a real tradeoff, not a technicality.
#                    DEST="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Shhhcribble Backups"
#
set -euo pipefail

DB="${DB:-$HOME/Library/Application Support/Shhhcribble/transcripts.sqlite}"
DEST="${DEST:-$HOME/Shhhcribble Backups}"
KEEP="${KEEP:-14}"

if [ ! -f "$DB" ]; then
  echo "❌ No database at: $DB" >&2
  exit 1
fi

mkdir -p "$DEST"
STAMP=$(date +%Y-%m-%d-%H%M%S)
OUT="$DEST/transcripts-$STAMP.sqlite"

# Online backup — safe while the app is running.
sqlite3 "$DB" ".backup '$OUT'"

# A backup nobody verified is a guess. Check it opens, passes an integrity
# check, and actually carries rows — a 0-row "successful" backup is the silent
# failure worth catching here rather than on the day you need it.
INTEGRITY=$(sqlite3 "$OUT" "PRAGMA integrity_check;" 2>&1 || echo "unreadable")
if [ "$INTEGRITY" != "ok" ]; then
  echo "❌ Backup failed its integrity check: $INTEGRITY" >&2
  rm -f "$OUT"
  exit 1
fi

ROWS=$(sqlite3 "$OUT" "select count(*) from transcripts;" 2>/dev/null || echo 0)
if [ "$ROWS" -eq 0 ]; then
  echo "❌ Backup contains no transcripts — refusing to keep it." >&2
  rm -f "$OUT"
  exit 1
fi

NOTES=$(sqlite3 "$OUT" "select count(*) from notes;" 2>/dev/null || echo 0)
SIZE=$(du -h "$OUT" | cut -f1)
echo "✅ $OUT"
echo "   $ROWS transcripts, $NOTES notes, $SIZE, integrity ok"

# Rotate. Deliberately keeps several: the point is to survive a bad migration
# or a corruption you don't notice for a few days, which one rolling copy
# cannot do.
# Pruning runs in a subshell that cannot fail the script: the backup is already
# written and verified at this point, and a failed prune is housekeeping, not a
# lost backup. Under `set -e` an un-guarded prune turned a GOOD backup into a
# non-zero exit — which is how this was found.
# NOTE: `find … | xargs ls -t` is WRONG here and was the first attempt. The
# default destination contains a space ("Shhhcribble Backups"), so xargs split
# it into two arguments and ls failed — pruning silently never ran while the
# guard below reported "skipped". `ls -t` on the glob emits one path per line
# and these filenames cannot contain newlines, so `read -r` is safe.
prune() {
  local files count
  files=$(ls -t "$DEST"/transcripts-*.sqlite 2>/dev/null) || return 0
  [ -n "$files" ] || return 0
  count=$(printf '%s\n' "$files" | wc -l | tr -d ' ')
  [ "$count" -gt "$KEEP" ] || return 0
  printf '%s\n' "$files" | tail -n +$((KEEP + 1)) | while read -r old; do
    rm -f "$old" && echo "   pruned $(basename "$old")"
  done
}
prune || echo "   ⚠ prune skipped (backup itself is fine)" >&2
