#!/usr/bin/env bash
#
# verify.sh — the gate. Must exit 0 before any phase counts as done.
#
# Purpose : build + test + lint in one command, so "is this phase finished?" has a
#           single mechanical answer.
# Inputs  : the whole repo.
# Outputs : exit status. Anything non-zero means the phase is not done.
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
require_toolchain

log "verify: 1/5 Core tests"
"$REPO_ROOT/scripts/test.sh"

log "verify: 2/5 build app"
"$REPO_ROOT/scripts/build.sh" release

log "verify: 3/5 lint"
"$REPO_ROOT/scripts/lint.sh"

log "verify: 4/5 offscreen self-QA"
"$REPO_ROOT/scripts/selfqa.sh" offscreen

log "verify: 5/5 app self-QA (layout + live graph + analog chain)"
"$REPO_ROOT/scripts/selfqa.sh" ui
"$REPO_ROOT/scripts/selfqa.sh" playback
"$REPO_ROOT/scripts/selfqa.sh" analog
# Loopback only, on 127.0.0.1 — this never puts anything on the network.
"$REPO_ROOT/scripts/selfqa.sh" stream

log "verify: OK"
