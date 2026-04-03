#!/bin/sh
set -eu

# telegram_update.sh
# Cron-friendly wrapper for telegram_update.py + git commit/push.
#
# Default layout:
#   <repo>/telegram_update.sh
#   <repo>/telegram_update.py
#   <repo>/unblock.txt
#   <repo>/telegram_update.env   (optional, sourced if present)
#
# Example telegram_update.env:
#   TELEGRAM_API_ID=12345678
#   TELEGRAM_API_HASH=0123456789abcdef0123456789abcdef
#   TELEGRAM_SESSION_STRING=...
#   # or omit TELEGRAM_SESSION_STRING and use a saved session file
#
# First interactive auth (one time, outside cron):
#   TELEGRAM_API_ID=... TELEGRAM_API_HASH=... \
#   python3 telegram_update.py --unblock ./unblock.txt --session-file ./.telegram_update.session
#
# Then cron can run this wrapper with --no-interactive.

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_DIR="${REPO_DIR:-$SCRIPT_DIR}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
GIT_BIN="${GIT_BIN:-git}"
UPDATER="${UPDATER:-$SCRIPT_DIR/telegram_update.py}"
UNBLOCK_FILE="${UNBLOCK_FILE:-$REPO_DIR/unblock.txt}"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/telegram_update.env}"
SESSION_FILE="${SESSION_FILE:-$SCRIPT_DIR/.telegram_update.session}"
REMOTE="${REMOTE:-origin}"
BRANCH="${BRANCH:-main}"
NO_INTERACTIVE="${NO_INTERACTIVE:-1}"
PULL_REBASE="${PULL_REBASE:-1}"
COMMIT_PREFIX="${COMMIT_PREFIX:-telegram: refresh auto IP block}"
LOCK_FILE="${LOCK_FILE:-$SCRIPT_DIR/.telegram_update.lock}"

log() {
    printf '[telegram_update] %s\n' "$*"
}

err() {
    printf '[telegram_update][ERR] %s\n' "$*" >&2
}

# Load optional env file (API credentials, session string, overrides)
if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
fi

: "${TELEGRAM_API_ID:?Set TELEGRAM_API_ID in environment or telegram_update.env}"
: "${TELEGRAM_API_HASH:?Set TELEGRAM_API_HASH in environment or telegram_update.env}"

[ -f "$UPDATER" ] || { err "telegram_update.py not found: $UPDATER"; exit 1; }
[ -f "$UNBLOCK_FILE" ] || { err "unblock.txt not found: $UNBLOCK_FILE"; exit 1; }
command -v "$PYTHON_BIN" >/dev/null 2>&1 || { err "Python not found: $PYTHON_BIN"; exit 1; }
command -v "$GIT_BIN" >/dev/null 2>&1 || { err "Git not found: $GIT_BIN"; exit 1; }

# Prevent overlapping cron runs when flock is available.
if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log "Another run is already active. Exiting."
        exit 0
    fi
fi

cd "$REPO_DIR"

# Fail fast if repo is not clean for files other than unblock.txt.
DIRTY_OTHER="$("$GIT_BIN" status --porcelain --untracked-files=no | grep -v ' unblock.txt$' || true)"
if [ -n "$DIRTY_OTHER" ]; then
    err "Repository has unrelated local changes. Commit/stash them before using cron."
    printf '%s\n' "$DIRTY_OTHER" >&2
    exit 1
fi

if [ "$PULL_REBASE" = "1" ]; then
    log "Pulling latest changes from $REMOTE/$BRANCH"
    "$GIT_BIN" fetch "$REMOTE" "$BRANCH"
    "$GIT_BIN" pull --rebase "$REMOTE" "$BRANCH"
fi

BEFORE_SUM="$($GIT_BIN hash-object "$UNBLOCK_FILE")"

CMD="$PYTHON_BIN $UPDATER --unblock $UNBLOCK_FILE --session-file $SESSION_FILE"
if [ -n "${TELEGRAM_SESSION_STRING:-}" ]; then
    CMD="$CMD --session-string \"$TELEGRAM_SESSION_STRING\""
fi
if [ "$NO_INTERACTIVE" = "1" ]; then
    CMD="$CMD --no-interactive"
fi

log "Running telegram_update.py"
# shellcheck disable=SC2086
if ! eval "$CMD"; then
    err "telegram_update.py failed"
    exit 1
fi

AFTER_SUM="$($GIT_BIN hash-object "$UNBLOCK_FILE")"
if [ "$BEFORE_SUM" = "$AFTER_SUM" ]; then
    log "unblock.txt unchanged; nothing to commit"
    exit 0
fi

"$GIT_BIN" add -- "$UNBLOCK_FILE"
if "$GIT_BIN" diff --cached --quiet -- "$UNBLOCK_FILE"; then
    log "No staged changes after update"
    exit 0
fi

STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
COMMIT_MSG="$COMMIT_PREFIX ($STAMP)"
log "Committing changes"
"$GIT_BIN" commit -m "$COMMIT_MSG"

log "Pushing to $REMOTE/$BRANCH"
"$GIT_BIN" push "$REMOTE" "$BRANCH"

log "Done"
