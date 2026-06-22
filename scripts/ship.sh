#!/usr/bin/env bash
set -euo pipefail

# Full local "ship" pipeline: format → lint → test → build (release) → install.
# The build/install steps sign with $MACTERM_SIGN_IDENTITY when it's set.
#
# Invoke via `mise run ship` so mise injects MACTERM_SIGN_IDENTITY from
# .mise.local.toml (see CONTRIBUTING.md → "Local Code Signing"). Running this
# script directly works too, but signs ad-hoc unless the var is already
# exported in your environment.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

if [[ -n ${MACTERM_SIGN_IDENTITY:-} ]]; then
  printf '\033[2mSigning identity: %s\033[0m\n' "$MACTERM_SIGN_IDENTITY"
else
  printf '\033[1;33m⚠ MACTERM_SIGN_IDENTITY is unset — building ad-hoc; macOS will re-prompt for permissions.\033[0m\n' >&2
fi

step() { printf '\n\033[1;34m▶ %s\033[0m\n' "$1"; }

step "Format"
./scripts/format.sh
step "Lint"
./scripts/lint.sh
step "Test"
./scripts/test.sh
step "Build (release)"
./scripts/build.sh
step "Install"
./scripts/install.sh

# Report the resulting signature. Read all of codesign's output (no early awk
# `exit`, which would SIGPIPE codesign and trip `set -o pipefail`).
authority="$(codesign -dvv /Applications/Seshterm.app 2>&1 | awk -F= '/^Authority=/ && !seen { print $2; seen = 1 }')"
if [[ -n $authority ]]; then
  printf '\n\033[1;32m✓ Shipped to /Applications/Seshterm.app — signed by %s\033[0m\n' "$authority"
else
  printf '\n\033[1;32m✓ Shipped to /Applications/Seshterm.app — ad-hoc signed\033[0m\n'
fi
