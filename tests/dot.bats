#!/usr/bin/env bats
# Tests for `dot` pull/link/check/push. Each test gets its own bare "GitHub",
# a clone `a` (the other PC) and a clone `b` (this PC, the one `dot` runs on),
# its own git config and its own signing key. Nothing outside the temp dir is
# touched.  Run: bats tests

setup() {
  T="$BATS_TEST_TMPDIR"
  # the sandbox has its own XDG state, where mise has never trusted the repo's mise.toml
  export MISE_TRUSTED_CONFIG_PATHS="$BATS_TEST_DIRNAME/.."
  DOTBIN="$BATS_TEST_DIRNAME/../dot"
  export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
  unset DOT_PULL_MODE DOT_NO_HOOKS DOT_ALLOW_SECRET DOT DOT_JOB_NOTIFY DOT_JOB_BY DOT_JOB_UNIT DOT_JOB_ARGS
  ssh-keygen -q -t ed25519 -N '' -C test -f "$T/key"
  git config --global user.name Test
  git config --global user.email test@example.com
  git config --global init.defaultBranch master
  git config --global gpg.format ssh
  git config --global user.signingkey "$T/key"
  git config --global commit.gpgsign true

  git init -q --bare "$T/remote.git"
  git clone -q "$T/remote.git" "$T/a" 2>/dev/null
  mkdir -p "$T/a/git/.config/git"
  echo "test@example.com $(cat "$T/key.pub")" >"$T/a/git/.config/git/allowed_signers"
  echo one >"$T/a/f"
  git -C "$T/a" add -A
  git -C "$T/a" commit -qm init
  git -C "$T/a" push -qu origin master 2>/dev/null
  git clone -q "$T/remote.git" "$T/b"

  mkdir -p "$T/home" "$T/run" "$T/stub"
  export DOTFILES="$T/b" DOT_TARGET="$T/home" XDG_RUNTIME_DIR="$T/run" XDG_STATE_HOME="$T/state"
}

dot() { "$DOTBIN" "$@"; }
head_b() { git -C "$T/b" rev-parse HEAD; }
# change <file> in clone a, commit (signed unless 3rd arg is "unsigned"), push
change_a() {
  echo "$2" >>"$T/a/$1"
  git -C "$T/a" add -A
  if [ "${3:-}" = unsigned ]; then git -C "$T/a" -c commit.gpgsign=false commit -qm "a: $1"
  else git -C "$T/a" commit -qm "a: $1"; fi
  git -C "$T/a" push -q 2>/dev/null
}
mid_rebase() { [ -d "$T/b/.git/rebase-merge" ] || [ -d "$T/b/.git/rebase-apply" ]; }

# --- pull ---------------------------------------------------------------

@test "pull: already up to date" {
  run dot pull
  [ "$status" -eq 0 ]
  [[ $output == *"already up to date"* ]]
}

@test "pull: signed incoming commit is applied and linked" {
  change_a f two
  run dot pull
  [ "$status" -eq 0 ]
  [ "$(tail -1 "$T/b/f")" = two ]
  [ -e "$T/home/.config/git/allowed_signers" ]
}

@test "pull: an uncommitted edit to another file is kept" {
  change_a f two
  echo mine >"$T/b/g"
  git -C "$T/b" add g
  run dot pull
  [ "$status" -eq 0 ]
  [ "$(tail -1 "$T/b/f")" = two ]
  [ "$(cat "$T/b/g")" = mine ]
}

@test "pull: an uncommitted edit to an incoming file stops before changing anything" {
  change_a f two
  before=$(head_b)
  echo mine >>"$T/b/f"
  run dot pull
  [ "$status" -eq 1 ]
  [[ $output == *"uncommitted edits"* ]]
  [[ $output == *"  f"* ]]
  [ "$(head_b)" = "$before" ]
  [ "$(tail -1 "$T/b/f")" = mine ]
  ! grep -q '<<<<<<<' "$T/b/f"
}

@test "pull: clashing commits are rolled back, not left mid-rebase" {
  change_a f theirs
  echo ours >>"$T/b/f"
  git -C "$T/b" commit -qam ours
  before=$(head_b)
  run dot pull
  [ "$status" -eq 1 ]
  [[ $output == *"back where it was"* ]]
  [ "$(head_b)" = "$before" ]
  ! mid_rebase
}

@test "pull: ff-only explains when both PCs have new commits" {
  change_a f theirs
  echo other >"$T/b/g"
  git -C "$T/b" add g
  git -C "$T/b" commit -qm ours
  before=$(head_b)
  DOT_PULL_MODE=ff-only run dot pull
  [ "$status" -eq 1 ]
  [[ $output == *"can't fast-forward"* ]]
  [ "$(head_b)" = "$before" ]
}

@test "pull: unreachable remote says so" {
  git -C "$T/b" remote set-url origin "$T/nowhere.git"
  run dot pull
  [ "$status" -eq 1 ]
  [[ $output == *"couldn't reach GitHub"* ]]
}

# --- signature gate -----------------------------------------------------

@test "sig: unsigned incoming commit is refused" {
  change_a f two unsigned
  before=$(head_b)
  run dot pull
  [ "$status" -eq 1 ]
  [[ $output == *"aren't signed by a key this PC trusts"* ]]
  [ "$(head_b)" = "$before" ]
}

@test "sig: a commit can't add its own key to allowed_signers" {
  ssh-keygen -q -t ed25519 -N '' -C evil -f "$T/evil"
  echo "evil@x $(cat "$T/evil.pub")" >>"$T/a/git/.config/git/allowed_signers"
  git -C "$T/a" -c user.signingkey="$T/evil" commit -qam "trust me"
  git -C "$T/a" push -q 2>/dev/null
  before=$(head_b)
  run dot pull
  [ "$status" -eq 1 ]
  [[ $output == *"trust me"* ]]
  [ "$(head_b)" = "$before" ]
}

@test "sig: no committed allowed_signers means stop" {
  git -C "$T/b" rm -q git/.config/git/allowed_signers
  git -C "$T/b" commit -qm "drop signers"
  change_a f two
  run dot pull
  [ "$status" -eq 1 ]
  [[ $output == *"no committed"* ]]
}

# --- link ---------------------------------------------------------------

@test "link: a failing hook doesn't stop the others, and is named" {
  mkdir -p "$T/b/hooks/post-link.d"
  echo 'exit 3' >"$T/b/hooks/post-link.d/10-bad.sh"
  echo "touch '$T/ran'" >"$T/b/hooks/post-link.d/20-good.sh"
  run dot link
  [ "$status" -eq 1 ]
  [[ $output == *"1 of 2 hooks failed: 10-bad"* ]]
  [ -e "$T/ran" ]
}

# --- host layers ------------------------------------------------------------
# hypr (shared) has x.lua + y.lua, host-pcA overrides x.lua, host-pcB has z.lua
host_layers() {
  mkdir -p "$T/b/hypr/.config/hypr" "$T/b/host-pcA/.config/hypr" "$T/b/host-pcB/.config/hypr"
  echo shared >"$T/b/hypr/.config/hypr/x.lua"
  echo shared >"$T/b/hypr/.config/hypr/y.lua"
  echo pcA >"$T/b/host-pcA/.config/hypr/x.lua"
  echo pcB >"$T/b/host-pcB/.config/hypr/z.lua"
}

@test "host layers: only this PC's host package is linked, and its file wins" {
  host_layers
  DOT_HOST=pcA run dot link
  [ "$status" -eq 0 ]
  [ "$(cat "$T/home/.config/hypr/x.lua")" = pcA ]
  [ "$(cat "$T/home/.config/hypr/y.lua")" = shared ]
  [ ! -e "$T/home/.config/hypr/z.lua" ]
}

@test "host layers: relinking keeps the override, and the other PC gets the shared file" {
  host_layers
  DOT_HOST=pcA dot link
  DOT_HOST=pcA run dot link hypr
  [ "$status" -eq 0 ]
  [ "$(cat "$T/home/.config/hypr/x.lua")" = pcA ]
  rm -rf "$T/home/.config"
  DOT_HOST=pcB run dot link
  [ "$status" -eq 0 ]
  [ "$(cat "$T/home/.config/hypr/x.lua")" = shared ]
  [ "$(cat "$T/home/.config/hypr/z.lua")" = pcB ]
}

@test "host layers: another PC's package is refused by name, and doctor sees no conflict" {
  host_layers
  DOT_HOST=pcA run dot link host-pcB
  [ "$status" -eq 1 ]
  [[ $output == *"host-pcB is only linked on pcB. This PC is pcA."* ]]
  [ ! -e "$T/home/.config/hypr/z.lua" ]
  DOT_HOST=pcA dot link
  DOT_HOST=pcA run dot doctor --offline
  [[ $output != *"stow conflict"* ]]
  [[ $output == *"host-pcA"* ]]
}

@test "host layers: dot add into this PC's package works, into another PC's is refused" {
  host_layers
  mkdir -p "$T/home/.config/app"
  echo mine >"$T/home/.config/app/a.conf"
  DOT_HOST=pcA run dot add host-pcB .config/app/a.conf
  [ "$status" -eq 1 ]
  [[ $output == *"only linked on pcB"* ]]
  [ -f "$T/home/.config/app/a.conf" ] && [ ! -L "$T/home/.config/app/a.conf" ]
  DOT_HOST=pcA run dot add host-pcA .config/app/a.conf
  [ "$status" -eq 0 ]
  [ -L "$T/home/.config/app/a.conf" ]
  [ "$(cat "$T/b/host-pcA/.config/app/a.conf")" = mine ]
}

# --- keep-here + dead links ---------------------------------------------------
# x.lua is shared and pushed; this PC (pcA) has linked it
kept_setup() {
  mkdir -p "$T/a/hypr/.config/hypr" "$T/a/host-pcA"
  echo shared >"$T/a/hypr/.config/hypr/x.lua"
  touch "$T/a/host-pcA/.keep"
  git -C "$T/a" add -A && git -C "$T/a" commit -qm "a: hypr" && git -C "$T/a" push -q 2>/dev/null
  git -C "$T/b" pull -q 2>/dev/null
  DOT_HOST=pcA dot link
}

@test "keep-here: this PC's edit moves to host-pcA, the shared file goes back, one local commit" {
  kept_setup
  echo mine >"$T/home/.config/hypr/x.lua"
  DOT_HOST=pcA run dot keep-here .config/hypr/x.lua
  [ "$status" -eq 0 ]
  [ "$(cat "$T/home/.config/hypr/x.lua")" = mine ]
  [ "$(readlink -f "$T/home/.config/hypr/x.lua")" = "$(readlink -f "$T/b/host-pcA/.config/hypr/x.lua")" ]
  [ "$(cat "$T/b/hypr/.config/hypr/x.lua")" = shared ]
  [ -z "$(git -C "$T/b" status --porcelain)" ]
  [ "$(git -C "$T/b" log -1 --format=%s)" = "keep(pcA): hypr/.config/hypr/x.lua" ]
  git -C "$T/b" cat-file commit HEAD | grep -q '^gpgsig '
  [ "$(git -C "$T/b" rev-list --count '@{u}..HEAD')" = 1 ]
}

@test "keep-here: a later change to the shared file from the other PC doesn't touch this PC's copy" {
  kept_setup
  echo mine >"$T/home/.config/hypr/x.lua"
  DOT_HOST=pcA dot keep-here .config/hypr/x.lua
  change_a hypr/.config/hypr/x.lua "from a"
  DOT_HOST=pcA run dot pull
  [ "$status" -eq 0 ]
  [ "$(cat "$T/home/.config/hypr/x.lua")" = mine ]
  [[ "$(cat "$T/b/hypr/.config/hypr/x.lua")" == *"from a"* ]]
}

@test "keep-here: refuses another PC's file, files outside the repo, its own files and folders" {
  kept_setup
  mkdir -p "$T/b/host-pcB/.config/hypr" && echo pcB >"$T/b/host-pcB/.config/hypr/z.lua"
  DOT_HOST=pcB dot link host-pcB
  DOT_HOST=pcA run dot keep-here .config/hypr/z.lua
  [ "$status" -eq 1 ] && [[ $output == *"belongs to pcB"* ]]
  echo local >"$T/home/.notrepo"
  DOT_HOST=pcA run dot keep-here .notrepo
  [ "$status" -eq 1 ] && [[ $output == *"isn't from the dotfiles repo"* ]]
  DOT_HOST=pcA run dot keep-here .config/hypr
  [ "$status" -eq 1 ] && [[ $output == *"not a file"* ]]
  DOT_HOST=pcA dot keep-here .config/hypr/x.lua
  DOT_HOST=pcA run dot keep-here .config/hypr/x.lua
  [ "$status" -eq 1 ] && [[ $output == *"already this PC's own"* ]]
}

@test "link: dead links into the repo are removed and listed, other links are left alone" {
  mkdir -p "$T/b/wp/.config/wp/conf.d" "$T/b/keep/.config/k"
  echo x >"$T/b/wp/.config/wp/conf.d/a.conf"
  echo x >"$T/b/wp/.config/wp/b.conf"
  echo k >"$T/b/keep/.config/k/k.conf"
  dot link
  # a real dir with a file link inside, as stow leaves it when a dir is shared
  rm -rf "$T/home/.config/wp" && mkdir -p "$T/home/.config/wp/conf.d"
  ln -s "../../../../b/wp/.config/wp/conf.d/a.conf" "$T/home/.config/wp/conf.d/a.conf"
  ln -s /nonexistent/elsewhere "$T/home/.config/other"
  rm -rf "$T/b/wp"
  run dot doctor --offline
  [[ $output == *"wp/conf.d/a.conf"* ]]
  run dot link
  [ "$status" -eq 0 ]
  [[ $output == *"removed dead link: .config/wp/conf.d/a.conf"* ]]
  [ ! -L "$T/home/.config/wp/conf.d/a.conf" ]
  [ -L "$T/home/.config/other" ]
  [ "$(cat "$T/home/.config/k/k.conf")" = k ]
  run dot doctor --offline
  [[ $output != *"wp/conf.d/a.conf"* ]]
}

# --- check + push -------------------------------------------------------

@test "check: nothing outgoing" {
  run dot check
  [ "$status" -eq 0 ]
  [[ $output == *"nothing outgoing"* ]]
}

@test "check: broken JSON and shell are caught" {
  command -v shellcheck >/dev/null || skip "shellcheck not installed"
  echo '{"a":' >"$T/b/x.json"
  printf '#!/bin/bash\nrm -rf $1/*\n' >"$T/b/s.sh"
  run dot check
  [ "$status" -eq 1 ]
  [[ $output == *"json: not valid JSON"* ]]
  [[ $output == *"x.json"* ]]
  [[ $output == *"shellcheck warnings"* ]]
}

@test "check: a token is caught by gitleaks" {
  command -v gitleaks >/dev/null || skip "gitleaks not installed"
  echo "token=ghp_$(printf 'aB3dE5gH7jK9mN1pQ3sT5vW7yZ9bC1dF3hJ5')" >"$T/b/env.txt"
  run dot check
  [ "$status" -eq 1 ]
  [[ $output == *"looks like a secret"* ]]
  [[ $output == *"env.txt"* ]]
}

@test "push: a failed check commits and pushes nothing" {
  echo '{"a":' >"$T/b/x.json"
  before=$(head_b)
  run dot push
  [ "$status" -eq 1 ]
  [[ $output == *"Nothing was committed or pushed"* ]]
  [ "$(head_b)" = "$before" ]
  [ "$(git -C "$T/remote.git" rev-parse master)" = "$before" ]
}

@test "push: -- <paths> adds, checks and commits only those; other edits stay as they are" {
  mkdir -p "$T/b/mine" "$T/b/theirs"
  echo '{"a":1}' >"$T/b/mine/x.json"
  echo '{"b":' >"$T/b/theirs/y.json"          # half-done and broken: must not stop or join the push
  echo staged >"$T/b/theirs/z.txt"; git -C "$T/b" add theirs/z.txt
  run dot push -m "mine only" -- "$T/b/mine"
  [ "$status" -eq 0 ]
  [ "$(git -C "$T/remote.git" rev-parse master)" = "$(head_b)" ]
  [ "$(git -C "$T/b" show --name-only --format= HEAD)" = "mine/x.json" ]
  git -C "$T/b" status --short | grep -qx '?? theirs/y.json'
  git -C "$T/b" status --short | grep -qx 'A  theirs/z.txt'
  run dot push -- /tmp
  [ "$status" -ne 0 ]
  [[ $output == *"isn't inside"* ]]
}

@test "push: --no-check pushes anyway, and says so" {
  echo '{"a":' >"$T/b/x.json"
  run dot push --no-check
  [ "$status" -eq 0 ]
  [[ $output == *"checks skipped"* ]]
  [ "$(git -C "$T/remote.git" rev-parse master)" = "$(head_b)" ]
}

@test "push: clean change is checked, signed and pushed" {
  echo '{"a":1}' >"$T/b/x.json"
  run dot push -m "add x"
  [ "$status" -eq 0 ]
  [[ $output == *"✓"*"json"* ]]
  git -C "$T/b" cat-file commit HEAD | grep -q "^gpgsig "
  [ "$(git -C "$T/remote.git" rev-parse master)" = "$(head_b)" ]
}

# --- job progress (job.json) ----------------------------------------------

job() { jq -r "$1" "$T/run/dot/job.json"; }
steps() { job '[.steps[] | .id + ":" + .state] | join(" ")'; }

@test "job: a push writes its steps, result and log" {
  echo '{"a":1}' >"$T/b/x.json"
  run dot push -m "add x"
  [ "$status" -eq 0 ]
  [ "$(job .action)" = push ]
  [ "$(job .result)" = ok ]
  [ "$(job .summary)" = "Shared 1 file" ]
  [ "$(steps)" = "checks:ok tests:skip commit:ok push:ok" ]
  [ "$(job '.steps[2].label')" = "Commit 1 file" ]
  [ "$(job .stoppable)" = false ]
  grep -q "dot: pushed" "$(job .log)"
  [ ! -e "$T/run/dot/running" ]
}

@test "job: a failed check is the failed step, with what failed" {
  echo '{"a":' >"$T/b/x.json"
  run dot push
  [ "$status" -eq 1 ]
  [ "$(job .result)" = failed ]
  [ "$(job .summary)" = "stopped by the check above. Nothing was committed or pushed." ]
  [ "$(steps)" = "checks:fail tests:skip commit:wait push:wait" ]
  [[ $(job '.details[0]') == *json* ]]
}

@test "job: tests are counted as they pass, and failures named" {
  mkdir -p "$T/b/tests"; echo '# t' >"$T/b/tests/x.bats"
  printf '#!/bin/sh\nprintf "1..3\\nok 1 one\\nnot ok 2 two breaks\\nok 3 three\\n"\nexit 1\n' >"$T/stub/bats"
  chmod +x "$T/stub/bats"
  PATH="$T/stub:$PATH" run dot push
  [ "$status" -eq 1 ]
  [ "$(job '.steps[1] | "\(.state) \(.done)/\(.total)"')" = "fail 3/3" ]
  [ "$(job '.details | index("two breaks") != null')" = true ]
  [ "$(job .line)" = "ok 3 · three" ]
}

@test "job: pull says how many commits, and a clash names the files" {
  change_a f two
  run dot pull
  [ "$status" -eq 0 ]
  [ "$(job .summary)" = "Pulled 1 commit" ]
  [ "$(steps)" = "fetch:ok verify:ok backup:ok apply:ok link:ok" ]
  change_a f three
  echo mine >>"$T/b/f"; git -C "$T/b" commit -qam mine
  run dot pull
  [ "$status" -eq 1 ]
  [ "$(job .result)" = failed ]
  [ "$(job .summary)" = "Both PCs changed the same lines. Nothing was changed." ]
  [ "$(job '.details[0]')" = f ]
  [ "$(job '.steps[] | select(.id == "apply") | .state')" = fail ]
}

@test "job: the usual length comes from earlier runs, once there are two" {
  mkdir -p "$T/state/dot"
  run dot pull
  [ "$(job .expectSec)" = null ]
  printf 'pull\t30\npull\t10\npull\t20\npush\t99\n' >"$T/state/dot/job-times.tsv"
  run dot pull
  [ "$(job .expectSec)" = 20 ]
  [ "$(grep -c '^pull' "$T/state/dot/job-times.tsv")" -eq 4 ]
}

@test "job: stop stops a running job, but not once it's past the safe point" {
  run dot stop
  [[ $output == *"nothing is running"* ]]
  sleep 30 & pid=$!
  mkdir -p "$T/run/dot"
  printf '{"schema":1,"action":"push","pid":%s,"unit":"","stoppable":false,"result":null}\n' "$pid" >"$T/run/dot/job.json"
  run dot stop
  [ "$status" -eq 1 ]
  [[ $output == *"past the point"* ]]
  kill -0 "$pid"
  printf '{"schema":1,"action":"push","pid":%s,"unit":"","stoppable":true,"result":null}\n' "$pid" >"$T/run/dot/job.json"
  run dot stop
  [ "$status" -eq 0 ]
  sleep 0.2
  ! kill -0 "$pid" 2>/dev/null
}

@test "job: start runs a push in the background; a second start is refused while it runs" {
  echo '{"a":1}' >"$T/b/x.json"
  stub_toast
  DOT_START_INLINE=1 PATH="$T/stub:$PATH" run dot start push -m "add x"
  [ "$status" -eq 0 ]
  for _ in $(seq 50); do [ "$(job '.result // "none"' 2>/dev/null)" = ok ] && break; sleep 0.2; done
  [ "$(job .result)" = ok ]
  [ "$(git -C "$T/remote.git" rev-parse master)" = "$(head_b)" ]
  # the toast goes out just after the result is written
  for _ in $(seq 50); do [ -s "$T/toasts" ] && break; sleep 0.1; done
  grep -q "^Shared 1 file|Dotfiles · " "$T/toasts"
  sleep 30 & pid=$!
  printf '{"schema":1,"action":"pull","pid":%s,"result":null}\n' "$pid" >"$T/run/dot/job.json"
  DOT_START_INLINE=1 run dot start pull
  [ "$status" -eq 1 ]
  [[ $output == *"already running"* ]]
  kill "$pid"
}

@test "job: --retry repeats the failed job with exactly its options, so a path-limited push stays limited" {
  stub_toast
  echo '{"a":' >"$T/b/mine.json"            # broken: the check stops the first try
  echo '{"b":1}' >"$T/b/theirs.json"         # someone else's edit, never part of this push
  DOT_START_INLINE=1 PATH="$T/stub:$PATH" run dot start push -m "mine" -- "$T/b/mine.json"
  for _ in $(seq 50); do [ "$(job '.result // "none"' 2>/dev/null)" = failed ] && break; sleep 0.2; done
  [ "$(job .result)" = failed ]
  jq -e --arg f "$T/b/mine.json" '.args == ["-m", "mine", "--", $f]' "$T/run/dot/job.json"
  echo '{"a":1}' >"$T/b/mine.json"
  DOT_START_INLINE=1 PATH="$T/stub:$PATH" run dot job --retry
  [ "$status" -eq 0 ]
  for _ in $(seq 50); do [ "$(job '.result // "none"' 2>/dev/null)" = ok ] && break; sleep 0.2; done
  [ "$(job .result)" = ok ]
  [ "$(git -C "$T/b" show --name-only --format=%s HEAD | sed '/^$/d' | paste -sd' ')" = "mine mine.json" ]
  git -C "$T/b" status --short | grep -qx '?? theirs.json'
  run dot job --retry
  [ "$status" -ne 0 ]
  [[ $output == *"didn't fail or stop"* ]]
}

# notify-send stand-in: notifications land in $T/toasts as head|body
stub_toast() {
  cat >"$T/stub/notify-send" <<STUB
#!/bin/bash
while [[ \$1 == -* ]]; do shift 2; done
echo "\$1|\$2" >>"$T/toasts"
STUB
  chmod +x "$T/stub/notify-send"
  rm -f "$T/toasts"
}

@test "job: a background job ends with a desktop notification; a foreground one never" {
  echo '{"a":' >"$T/b/x.json"
  stub_toast
  DOT_JOB_NOTIFY=1 PATH="$T/stub:$PATH" run dot push
  [ "$status" -eq 1 ]
  grep -q "^Share stopped by a problem|stopped by the check above. Nothing was committed or pushed. See: dot job" "$T/toasts"
  stub_toast
  PATH="$T/stub:$PATH" run dot push
  [ ! -e "$T/toasts" ]
}

@test "job: --mark notes seen and dismissed on a finished job only" {
  run dot job --mark seen
  [ "$status" -eq 0 ]
  mkdir -p "$T/run/dot"
  printf '{"schema":1,"action":"push","pid":1,"result":null}\n' >"$T/run/dot/job.json"
  run dot job --mark seen
  [ "$(job '.seenAt // "none"')" = none ]
  run dot pull
  run dot job --mark seen
  t=$(job .seenAt)
  [ "$t" -gt 0 ]
  sleep 1
  run dot job --mark seen
  [ "$(job .seenAt)" = "$t" ]
  run dot job --mark dismissed
  [ "$(job .dismissedAt)" -gt 0 ]
  run dot job --mark gone
  [ "$status" -eq 1 ]
}

@test "job: --fix gives Claude the failed step, the problem and the log" {
  printf '#!/bin/sh\npwd >"%s/claude-ran"\nprintf "%%s" "$1" >>"%s/claude-ran"\n' "$T" "$T" >"$T/stub/claude"
  chmod +x "$T/stub/claude"
  run dot pull
  PATH="$T/stub:$PATH" run dot job --fix
  [ "$status" -eq 1 ]
  [[ $output == *"didn't fail"* ]]
  echo '{"a":' >"$T/b/x.json"
  run dot push
  PATH="$T/stub:$PATH" run dot job --fix
  [ "$status" -eq 0 ]
  [ "$(head -n 1 "$T/claude-ran")" = "$T/b" ]
  grep -q '^`dot push` on .* stopped by a problem: stopped by the check above' "$T/claude-ran"
  grep -q "^It stopped at the step: Secrets and lint.$" "$T/claude-ran"
  grep -q "^- .*json" "$T/claude-ran"
  grep -q "^The full log is $T/state/dot/logs/.*-push.log.$" "$T/claude-ran"
  grep -q "Do not commit, push or pull" "$T/claude-ran"
}

@test "job: --json prints the job, or none" {
  run dot job --json
  [ "$(jq -r .result <<<"$output")" = none ]
  run dot pull
  run dot job --json
  [ "$(jq -r .action <<<"$output")" = pull ]
}

# --- status --json --------------------------------------------------------

sj() { "$DOTBIN" status --json; }

@test "status --json: clean repo" {
  run sj
  [ "$status" -eq 0 ]
  [ "$(jq -r '.schema, .state, .branch, .upstream, .ahead, .behind' <<<"$output" | paste -sd' ')" = "1 clean master origin/master 0 0" ]
  jq -e '.dirty == [] and .incoming == [] and .outgoing == [] and .hosts == null and .watch == null' <<<"$output"
}

@test "status --json: each kind of local change, incl. a path with spaces" {
  echo x >>"$T/b/f"
  echo n >"$T/b/new file.txt"
  echo s >"$T/b/staged"; git -C "$T/b" add staged
  git -C "$T/b" mv git/.config/git/allowed_signers git/.config/git/signers
  run sj
  [ "$status" -eq 0 ]
  jq -e '.state == "dirty"' <<<"$output"
  jq -e '.dirty[] | select(.path == "f") | .kind == "modified" and .unstaged and (.staged | not)' <<<"$output"
  jq -e '.dirty[] | select(.path == "new file.txt") | .kind == "new"' <<<"$output"
  jq -e '.dirty[] | select(.path == "staged") | .kind == "added" and .staged' <<<"$output"
  jq -e '.dirty[] | select(.path == "git/.config/git/signers") | .kind == "renamed" and .from == "git/.config/git/allowed_signers"' <<<"$output"
}

@test "status --json: incoming commits from the last fetch, with signature" {
  change_a f two
  change_a f three unsigned
  git -C "$T/b" fetch -q
  run sj
  jq -e '.state == "behind" and .behind == 2 and (.incoming | length) == 2' <<<"$output"
  jq -e '.incomingUntrusted == 1' <<<"$output"
  jq -e '.incoming[0].signature != "G" and .incoming[1].signature == "G"' <<<"$output"
  jq -e '.lastFetch != null and .lastFetchAgeSec >= 0' <<<"$output"
}

@test "status --json: unpushed and diverged" {
  echo o >"$T/b/g"; git -C "$T/b" add g; git -C "$T/b" commit -qm "mine"
  run sj
  jq -e '.state == "ahead" and .ahead == 1 and .outgoing[0].subject == "mine"' <<<"$output"
  change_a f two
  git -C "$T/b" fetch -q
  run sj
  jq -e '.state == "diverged"' <<<"$output"
}

@test "status --json: a rebase left half done shows as in-progress" {
  change_a f theirs
  echo ours >>"$T/b/f"; git -C "$T/b" commit -qam ours
  git -C "$T/b" fetch -q
  git -C "$T/b" rebase -q '@{u}' >/dev/null 2>&1 || true
  run sj
  jq -e '.state == "in-progress" and .operation == "rebase"' <<<"$output"
  jq -e '.dirty[] | select(.path == "f") | .kind == "conflict"' <<<"$output"
}

@test "status --json: never touches the network" {
  git -C "$T/b" remote set-url origin "$T/nowhere.git"
  run sj
  [ "$status" -eq 0 ]
  jq -e '.state == "clean"' <<<"$output"
}

@test "status --json: merges the host cache when there is one" {
  mkdir -p "$T/run/dot"
  echo '{"schema":1,"checkedAt":1,"fetch":{"ok":false},"hosts":{"laptop":{"online":true}}}' >"$T/run/dot/hosts.json"
  run sj
  jq -e '.hosts.laptop.online == true and .watch.fetchOk == false and .watch.ageSec >= 0' <<<"$output"
}

@test "status --json: not a repo gives JSON with an error" {
  export DOTFILES="$T/home"
  run sj
  [ "$status" -eq 1 ]
  jq -e '.error == "no dotfiles repo" and .schema == 1' <<<"$output"
}

# --- watch ----------------------------------------------------------------
# A fake ssh: "up" answers with a status, "old" has an old dot, anything else
# is unreachable (exit 255, like a sleeping laptop).

fake_ssh() {
  cat >"$T/stub/ssh" <<'SH'
#!/bin/bash
for a; do case $a in up|old|down) host=$a ;; esac; done
case $host in
  up)  echo '{"schema":1,"host":"other","state":"behind"}' ;;
  old) echo "usage: dot ..."; exit 1 ;;
  *)   exit 255 ;;
esac
SH
  chmod +x "$T/stub/ssh"
  mkdir -p "$T/b/system/hosts"
  printf '# test\nother up\nlegacy old\nlaptop down\n%s self\n' "$(cat /etc/hostname 2>/dev/null || hostname)" \
    >"$T/b/system/hosts/pcs.txt"
}

@test "watch: online, old dot and offline PCs; this PC is skipped" {
  fake_ssh
  PATH="$T/stub:$PATH" run dot watch
  [ "$status" -eq 0 ]
  h="$T/run/dot/hosts.json"
  jq -e '.schema == 1 and .fetch.ok == true' "$h"
  jq -e '.hosts | keys == ["laptop","legacy","other"]' "$h"
  jq -e '.hosts.other | .online and .status.state == "behind" and .error == null' "$h"
  jq -e '.hosts.legacy | .online and .status == null and (.error | test("old dot"))' "$h"
  jq -e '.hosts.laptop | (.online | not) and .error == "unreachable" and .lastSeen == null' "$h"
  run sj
  jq -e '.hosts.other.status.state == "behind" and .watch.fetchOk == true' <<<"$output"
}

@test "watch: an offline PC keeps its last known status and lastSeen" {
  fake_ssh
  PATH="$T/stub:$PATH" dot watch
  seen=$(jq '.hosts.other.lastSeen' "$T/run/dot/hosts.json")
  sed -i 's/^other up$/other down/' "$T/b/system/hosts/pcs.txt"
  PATH="$T/stub:$PATH" dot watch
  jq -e --argjson s "$seen" '.hosts.other | (.online | not) and .lastSeen == $s and .status.state == "behind"' "$T/run/dot/hosts.json"
}

@test "watch: GitHub unreachable is recorded, not fatal" {
  git -C "$T/b" remote set-url origin "$T/nowhere.git"
  run dot watch
  [ "$status" -eq 0 ]
  [[ $output == *"couldn't fetch"* ]]
  jq -e '.fetch.ok == false' "$T/run/dot/hosts.json"
}

# --- running marker ---------------------------------------------------------

@test "status --json: running pull/push from the marker, ignored when its process is gone" {
  mkdir -p "$T/run/dot"
  echo "pull $$" >"$T/run/dot/running"
  run sj
  jq -e '.running == "pull"' <<<"$output"
  echo "push 999999" >"$T/run/dot/running"
  run sj
  jq -e '.running == null' <<<"$output"
}

@test "pull: the running marker is removed afterwards" {
  run dot pull
  [ "$status" -eq 0 ]
  [ ! -e "$T/run/dot/running" ]
}

# --- worktree ---------------------------------------------------------------

@test "worktree: link and add refuse; push sets the upstream" {
  git -C "$T/b" worktree add -q -b wip "$T/b-wip"
  DOTFILES="$T/b-wip" run dot link
  [ "$status" -eq 1 ]
  [[ $output == *"git worktree"* ]]
  DOTFILES="$T/b-wip" run dot add git x
  [ "$status" -eq 1 ]
  echo wip >"$T/b-wip/w"
  DOTFILES="$T/b-wip" run dot push -m wip
  [ "$status" -eq 0 ]
  [ "$(git -C "$T/remote.git" rev-parse wip)" = "$(git -C "$T/b-wip" rev-parse HEAD)" ]
  [ "$(git -C "$T/remote.git" rev-parse master)" != "$(git -C "$T/b-wip" rev-parse HEAD)" ]
}

@test "worktree: pull doesn't link" {
  git -C "$T/b" worktree add -q -b wip "$T/b-wip"
  git -C "$T/b-wip" push -qu origin wip 2>/dev/null
  DOTFILES="$T/b-wip" run dot pull
  [ "$status" -eq 0 ]
  [ ! -e "$T/home/.config" ]
}

# --- backups + undo -------------------------------------------------------

backups() { git -C "$T/b" for-each-ref --format='%(refname:lstrip=3)' refs/dot/backup/; }

@test "pull: saves a backup before changing anything, none when up to date" {
  run dot pull
  [ -z "$(backups)" ]
  before=$(head_b)
  change_a f two
  run dot pull
  [ "$status" -eq 0 ]
  [[ $output == *"saved where you were as backup"* ]]
  [ "$(git -C "$T/b" rev-parse "refs/dot/backup/$(backups)")" = "$before" ]
}

@test "pull: a clash still leaves the backup, and uncommitted edits are saved as -wip" {
  change_a f theirs
  echo ours >>"$T/b/f"
  git -C "$T/b" commit -qam ours
  echo wip >"$T/b/g"
  git -C "$T/b" add g
  run dot pull
  [ "$status" -eq 1 ]
  [ "$(backups | wc -l)" -eq 2 ]
  backups | grep -q -- '-wip$'
}

@test "undo: lists backups newest first, says when there are none" {
  run dot undo
  [ "$status" -eq 1 ]
  [[ $output == *"no backups yet"* ]]
  change_a f two; dot pull >/dev/null
  change_a f three; dot pull >/dev/null
  run dot undo
  [ "$status" -eq 0 ]
  [[ ${lines[1]} == *" 1  "*"a: f"* ]]
  [[ ${lines[2]} == *" 2  "*"init"* ]]
}

@test "undo: goes back, keeps what it replaced as a new backup, relinks" {
  before=$(head_b)
  change_a f two
  dot pull >/dev/null
  pulled=$(head_b)
  echo late >"$T/b/h"; git -C "$T/b" add h
  run dot undo 1 -y
  [ "$status" -eq 0 ]
  [[ $output == *"a: f"* ]]
  [ "$(head_b)" = "$before" ]
  [ "$(cat "$T/b/f")" = one ]
  [ ! -e "$T/b/h" ]
  # what was replaced is backup 1 now, with its uncommitted file
  run dot undo 1 -y
  [ "$status" -eq 0 ]
  [ "$(head_b)" = "$pulled" ]
  [ "$(cat "$T/b/h")" = late ]
}

@test "undo: restores the uncommitted edits saved with the backup" {
  change_a f two
  echo wip >"$T/b/g"; git -C "$T/b" add g
  dot pull >/dev/null
  rm "$T/b/g"; git -C "$T/b" add -A
  run dot undo 1 -y
  [ "$status" -eq 0 ]
  [ "$(cat "$T/b/g")" = wip ]
}

@test "undo: no answer means nothing changes" {
  change_a f two
  dot pull >/dev/null
  after=$(head_b)
  run dot undo 1 </dev/null
  [ "$status" -eq 0 ]
  [[ $output == *"nothing changed"* ]]
  [ "$(head_b)" = "$after" ]
}

@test "undo: refuses mid-rebase, an unknown backup, and in a worktree" {
  change_a f two
  dot pull >/dev/null
  run dot undo 9 -y
  [ "$status" -eq 1 ]
  [[ $output == *"no backup '9'"* ]]
  mkdir -p "$T/b/.git/rebase-merge"
  run dot undo 1 -y
  [ "$status" -eq 1 ]
  [[ $output == *"half done"* ]]
  rmdir "$T/b/.git/rebase-merge"
  git -C "$T/b" worktree add -q "$T/b-wt" -b wt 2>/dev/null
  DOTFILES="$T/b-wt" run dot undo
  [ "$status" -eq 1 ]
  [[ $output == *"worktree"* ]]
}

@test "backups: only the newest 20 are kept" {
  for i in $(seq 1 22); do git -C "$T/b" update-ref "refs/dot/backup/20200101-0000$(printf %02d "$i")" HEAD; done
  change_a f two
  dot pull >/dev/null
  [ "$(backups | wc -l)" -eq 20 ]
  ! backups | grep -q '20200101-000001'
}

# --- merge rules ----------------------------------------------------------

LOCK=nvim/.config/nvim/lazy-lock.json
lock_entry() { printf '  "%s": { "branch": "main", "commit": "%s" }' "$1" "$2"; }
# write a lazy-lock.json from name=commit pairs, in Lazy's own layout
write_lock() {
  local dir=$1; shift
  mkdir -p "$dir/$(dirname "$LOCK")"
  { echo "{"; local first=1 p
    for p in "$@"; do [ $first = 1 ] || echo ","; first=0; lock_entry "${p%%=*}" "${p#*=}" | tr -d '\n'; done
    echo; echo "}"; } >"$dir/$LOCK"
}
rules_in_a() {
  echo "$LOCK  merge=lazylock" >"$T/a/.gitattributes"
  write_lock "$T/a" alpha=a1 beta=b1 gamma=g1
  git -C "$T/a" add -A; git -C "$T/a" commit -qm rules; git -C "$T/a" push -q 2>/dev/null
  dot pull >/dev/null
}

@test "merge rules: lazy-lock clash is merged per plugin, incoming wins, Lazy's layout kept" {
  rules_in_a
  write_lock "$T/a" alpha=a2 beta=b1 gamma=g2 delta=d1
  git -C "$T/a" commit -qam "a: lazy update"; git -C "$T/a" push -q 2>/dev/null
  write_lock "$T/b" alpha=a1 beta=b2 gamma=g3
  git -C "$T/b" commit -qam "b: lazy update"
  run dot pull
  [ "$status" -eq 0 ]
  expected=$(write_lock "$T/x" alpha=a2 beta=b2 delta=d1 gamma=g2; cat "$T/x/$LOCK")
  [ "$(cat "$T/b/$LOCK")" = "$expected" ]
  ! mid_rebase
}

@test "merge rules: an uncommitted lazy-lock edit doesn't stop the pull and is kept" {
  rules_in_a
  write_lock "$T/a" alpha=a2 beta=b1 gamma=g1
  git -C "$T/a" commit -qam "a: lazy update"; git -C "$T/a" push -q 2>/dev/null
  write_lock "$T/b" alpha=a1 beta=b2 gamma=g1
  run dot pull
  [ "$status" -eq 0 ]
  grep -q '"alpha": { "branch": "main", "commit": "a2" }' "$T/b/$LOCK"
  grep -q '"beta": { "branch": "main", "commit": "b2" }' "$T/b/$LOCK"
}

@test "merge rules: other files still stop the pull" {
  rules_in_a
  change_a f two
  echo mine >>"$T/b/f"
  run dot pull
  [ "$status" -eq 1 ]
  [[ $output == *"uncommitted edits"* ]]
}

@test "status --json: changedAt per file, incoming/outgoing files, merge rules" {
  echo o >"$T/b/g"; git -C "$T/b" add g; git -C "$T/b" commit -qm "mine"
  change_a f two
  git -C "$T/b" fetch -q
  echo x >"$T/b/new file"
  touch -d @1700000000 "$T/b/new file"
  git -C "$T/b" rm -q f
  printf '# c\nnotes/todo.md merge=union\nlock.json  merge=lazylock\nother.txt -diff\n' >"$T/b/.gitattributes"
  run sj
  jq -e '.incomingFiles == ["f"] and .outgoingFiles == ["g"]' <<<"$output"
  jq -e '.dirty[] | select(.path == "new file") | .changedAt == 1700000000' <<<"$output"
  jq -e '.dirty[] | select(.path == "f") | .kind == "deleted" and .changedAt == null' <<<"$output"
  jq -e '.mergeRules == ["notes/todo.md", "lock.json"]' <<<"$output"
}

@test "watch: the other PC's own host cache isn't stored, so nothing nests or grows" {
  fake_ssh
  sed -i 's|"state":"behind"}|"state":"behind","hosts":{"me":{"status":{"hosts":{"deep":1}}}},"watch":{"ageSec":1}}|' "$T/stub/ssh"
  for i in 1 2 3; do PATH="$T/stub:$PATH" dot watch >/dev/null; done
  h="$T/run/dot/hosts.json"
  jq -e '.hosts.other.status | .state == "behind" and has("hosts") == false and has("watch") == false' "$h"
  # a big cache is read from a file, never passed as one argument
  jq '.hosts.other.status.pad = ("x" * 200000)' "$h" >"$h.tmp" && mv "$h.tmp" "$h"
  run sj
  [ "$status" -eq 0 ]
  jq -e '.hosts.other.status.state == "behind"' <<<"$output"
}

# --- share-from -----------------------------------------------------------

# "ssh up <cmd>" runs <cmd> as the other PC: clone a, its own HOME and runtime dir
other_pc() {
  mkdir -p "$T/ahome/.local/bin" "$T/atarget" "$T/arun" "$T/b/system/hosts"
  ln -sf "$DOTBIN" "$T/ahome/.local/bin/dot"
  {
    echo '#!/bin/bash'
    echo 'args=(); while [ $# -gt 0 ]; do case $1 in -o) shift 2 ;; -t) shift ;; *) args+=("$1"); shift ;; esac; done'
    echo 'case ${args[0]} in'
    echo "  up) HOME='$T/ahome' DOTFILES='$T/a' DOT_TARGET='$T/atarget' DOT_NO_HOOKS=1 XDG_RUNTIME_DIR='$T/arun' bash -c \"\${args[*]:1}\" ;;"
    echo '  *) exit 255 ;;'
    echo 'esac'
  } >"$T/stub/ssh"
  chmod +x "$T/stub/ssh"
  printf 'laptop up\nasleep down\n' >"$T/b/system/hosts/pcs.txt"
}
sf() { PATH="$T/stub:$PATH" dot share-from "$@"; }
remote_head() { git -C "$T/remote.git" rev-parse master; }

@test "share-from: lists, flags fresh edits, pulls + pushes there, never pulls here" {
  other_pc
  echo edited >>"$T/a/f"
  echo hello >"$T/a/new.txt"
  before_b=$(head_b)
  run sf laptop -y
  [ "$status" -eq 0 ]
  [[ $output == *"has 2 changed files"* ]]
  [[ $output == *"f  changed  now   <- changed in the last 5 min"* ]]
  [[ $output == *"+hello"* ]]
  [[ $output == *"Shared from laptop"* ]]
  [ "$(remote_head)" = "$(git -C "$T/a" rev-parse HEAD)" ]
  [ -z "$(git -C "$T/a" status --porcelain)" ]
  [ "$(head_b)" = "$before_b" ]
}

@test "share-from: no answer shares nothing; nothing to share says so" {
  other_pc
  run sf laptop
  [ "$status" -eq 0 ]
  [[ $output == *"nothing to share"* ]]
  echo edited >>"$T/a/f"
  before=$(remote_head)
  run sf laptop </dev/null
  [ "$status" -eq 0 ]
  [[ $output == *"nothing was shared"* ]]
  [ "$(remote_head)" = "$before" ]
  [ -n "$(git -C "$T/a" status --porcelain)" ]
}

@test "share-from: the other PC behind pulls first, then shares" {
  other_pc
  echo mine >"$T/b/g"; git -C "$T/b" add g; git -C "$T/b" commit -qm "b: g"; git -C "$T/b" push -q 2>/dev/null
  echo edited >>"$T/a/f"
  run sf laptop -y
  [ "$status" -eq 0 ]
  git -C "$T/remote.git" log --format=%s master | grep -qx "b: g"
  [ "$(remote_head)" = "$(git -C "$T/a" rev-parse HEAD)" ]
}

@test "share-from: refuses bad names, unknown PCs, offline, busy and half-done" {
  other_pc
  run sf 'x;rm'
  [ "$status" -eq 1 ]; [[ $output == *"isn't a PC name"* ]]
  run sf desk
  [ "$status" -eq 1 ]; [[ $output == *"no PC named 'desk'"* ]]
  run sf
  [ "$status" -eq 1 ]; [[ $output == *"which PC?"* ]]
  run sf asleep
  [ "$status" -eq 1 ]; [[ $output == *"can't reach asleep"* ]]
  echo edited >>"$T/a/f"
  echo "push $$" >"$T/arun/dot/running" 2>/dev/null || { mkdir -p "$T/arun/dot"; echo "push $$" >"$T/arun/dot/running"; }
  run sf laptop -y
  [ "$status" -eq 1 ]; [[ $output == *"running dot push"* ]]
  rm "$T/arun/dot/running"
  mkdir -p "$T/a/.git/rebase-merge"
  run sf laptop -y
  [ "$status" -eq 1 ]; [[ $output == *"half done on laptop"* ]]
}

@test "share-from: with one other PC the name can be left out" {
  other_pc
  printf 'laptop up\n' >"$T/b/system/hosts/pcs.txt"
  echo edited >>"$T/a/f"
  run sf -y
  [ "$status" -eq 0 ]
  [[ $output == *"Shared from laptop"* ]]
}

@test "share-from: --json lists as JSON; --expect shares only that list" {
  other_pc
  echo edited >>"$T/a/f"
  run sf laptop --json
  [ "$status" -eq 0 ]
  [ "$(jq -r .pc <<<"$output")" = laptop ]
  [ "$(jq -r '.files[0] | "\(.path) \(.kind) \(.ageSec < 60)"' <<<"$output")" = "f modified true" ]
  [ "$(jq '.commits | length' <<<"$output")" = 0 ]
  token=$(jq -r .token <<<"$output")
  [[ $token =~ ^[0-9a-f]{40}$ ]]
  echo more >"$T/a/new.txt"
  before=$(remote_head)
  run sf laptop --expect "$token"
  [ "$status" -eq 1 ]
  [[ $output == *"changed since you looked"* ]]
  [ "$(remote_head)" = "$before" ]
  run sf laptop --json
  run sf laptop --expect "$(jq -r .token <<<"$output")"
  [ "$status" -eq 0 ]
  [ "$(remote_head)" = "$(git -C "$T/a" rev-parse HEAD)" ]
  run sf laptop --expect 'x;y'
  [ "$status" -eq 1 ]
}

@test "share-from: the job shows the other PC's push, step by step" {
  other_pc
  echo edited >>"$T/a/f"
  echo hello >"$T/a/new.txt"
  run sf laptop -y
  [ "$status" -eq 0 ]
  [ "$(job .action)" = sharefrom ]
  [ "$(job .host)" = laptop ]
  [ "$(job .result)" = ok ]
  [ "$(job .summary)" = "Shared 2 files from laptop" ]
  [ "$(steps)" = "reach:ok pull:ok checks:ok tests:skip commit:ok push:ok" ]
  [ "$(job '.steps[4].label')" = "Commit 2 files" ]
  # the other PC's own card says who started it
  [ "$(jq -r '.action + " " + .by' "$T/arun/dot/job.json")" = "push $(job .by)" ]
}

@test "share-from: a push that fails there fails here, with its reason" {
  other_pc
  echo '{"a":' >"$T/a/x.json"
  run sf laptop -y
  [ "$status" -eq 1 ]
  [ "$(job .result)" = failed ]
  [ "$(job .summary)" = "On laptop: stopped by the check above. Nothing was committed or pushed." ]
  [ "$(steps)" = "reach:ok pull:ok checks:fail tests:skip commit:wait push:wait" ]
  [[ $(job '.details[0]') == *json* ]]
}

@test "diff: tracked edits, new files and unpushed commits" {
  echo o >"$T/b/g"; git -C "$T/b" add g; git -C "$T/b" commit -qm "b: unpushed"
  echo edited >>"$T/b/f"
  echo hi >"$T/b/new file"
  run dot diff
  [ "$status" -eq 0 ]
  [[ $output == *"+edited"* ]]
  [[ $output == *"+hi"* ]]
  [[ $output == *"commit "*"b: unpushed"* ]]
}

# --- conflicts + dot resolve ------------------------------------------------

# a clash on f: one line changed on both PCs
clash() {
  printf 'one\nshared\n' >"$T/a/f"; git -C "$T/a" commit -qam "a: base"; git -C "$T/a" push -q 2>/dev/null
  dot pull >/dev/null
  sed -i 's/shared/theirs/' "$T/a/f"; git -C "$T/a" commit -qam "a: theirs"; git -C "$T/a" push -q 2>/dev/null
  sed -i 's/shared/ours/' "$T/b/f"; git -C "$T/b" commit -qam "b: ours"
}
cdir() { ls -1d "$T/state/dot/conflict"/*/ | tail -1; }
# a stand-in for claude: $FAKE = good | markers | unsigned | quit
fake_claude() {
  cat >"$T/stub/fakeclaude" <<'SH'
#!/bin/bash
dir=$(sed -n 's|^Each side is saved in \(.*\)/files/ as.*|\1|p' <<<"$1")
[ -n "$dir" ] && grep -q '^Rules:' <<<"$1" || { echo "bad prompt"; exit 3; }
case "$FAKE" in
  quit) exit 0 ;;
  markers) git add -A ;;
  *) printf 'one\nours and theirs\n' >f; git add f ;;
esac
GIT_EDITOR=true git rebase --continue >/dev/null
[ "$FAKE" = unsigned ] && git commit -q --amend --no-edit --no-gpg-sign
echo "f: kept both" >"$dir/RESOLUTION.md"
SH
  chmod +x "$T/stub/fakeclaude"
  export DOT_CLAUDE="$T/stub/fakeclaude"
}
sj_conflict() { "$DOTBIN" status --json | jq -c .conflict; }

@test "conflict: a clash saves both sides, the commits and a prompt; nothing changes" {
  clash
  before=$(head_b)
  run dot pull
  [ "$status" -eq 1 ]
  [[ $output == *"dot resolve"* ]]
  [ "$(head_b)" = "$before" ]
  d=$(cdir)
  [ "$(sed -n 2p "$d/files/f.this-pc")" = ours ]
  [ "$(sed -n 2p "$d/files/f.incoming")" = theirs ]
  [ "$(sed -n 2p "$d/files/f.base")" = shared ]
  jq -e '.files == ["f"] and (.commitsHere[0] | endswith("b: ours")) and (.commitsIncoming[0] | endswith("a: theirs"))' "$d/info.json"
  grep -q "^- f$" "$d/prompt.md"
  grep -q "never push" "$d/prompt.md"
  jq -e '.files == ["f"] and .solving == false and .ready == false' <<<"$(sj_conflict)"
}

@test "resolve: Claude solves it in a copy, accept checks and applies it, conflict closes" {
  clash; dot pull >/dev/null 2>&1 || true
  fake_claude
  run dot resolve </dev/null
  [ "$status" -eq 0 ]
  [[ $output == *"f: kept both"* ]]
  [[ $output == *"Not accepted"* ]]
  [ "$(sed -n 2p "$T/b/f")" = ours ]
  jq -e '.solving and .ready and .solvedAt != null' <<<"$(sj_conflict)"
  run dot resolve --accept
  [ "$status" -eq 0 ]
  [[ $output == *"Fix applied"* ]]
  [ "$(sed -n 2p "$T/b/f")" = "ours and theirs" ]
  git -C "$T/b" merge-base --is-ancestor origin/master HEAD
  [ ! -d "$T/b-resolve" ]
  [ "$(sj_conflict)" = null ]
  [ -n "$(git -C "$T/b" for-each-ref refs/dot/backup)" ]
}

@test "resolve: accept refuses conflict markers and unsigned commits" {
  clash; dot pull >/dev/null 2>&1 || true
  fake_claude
  FAKE=markers run dot resolve </dev/null
  run dot resolve --accept
  [ "$status" -eq 1 ]; [[ $output == *"conflict markers"* ]]
  [ "$(sed -n 2p "$T/b/f")" = ours ]
  dot resolve --drop >/dev/null
  FAKE=unsigned run dot resolve </dev/null
  run dot resolve --accept
  [ "$status" -eq 1 ]; [[ $output == *"aren't signed"* ]]
  [ "$(sed -n 2p "$T/b/f")" = ours ]
}

@test "resolve: an unfinished fix waits; drop removes it and the conflict stays open" {
  clash; dot pull >/dev/null 2>&1 || true
  fake_claude
  FAKE=quit run dot resolve </dev/null
  [[ $output == *"Not finished yet"* ]]
  jq -e '.solving and (.ready | not)' <<<"$(sj_conflict)"
  run dot resolve --accept
  [ "$status" -eq 1 ]; [[ $output == *"isn't finished"* ]]
  run dot resolve --drop
  [ "$status" -eq 0 ]
  [ ! -d "$T/b-resolve" ]
  ! git -C "$T/b" show-ref -q --heads | grep -q resolve/
  jq -e '.solving == false' <<<"$(sj_conflict)"
}

@test "resolve: out of date when this PC moved on; a pull that goes through closes the conflict" {
  clash; dot pull >/dev/null 2>&1 || true
  fake_claude
  dot resolve </dev/null >/dev/null
  echo x >"$T/b/g"; git -C "$T/b" add g; git -C "$T/b" commit -qm "b: more"
  run dot resolve --accept
  [ "$status" -eq 1 ]; [[ $output == *"out of date"* ]]
  dot resolve --drop >/dev/null
  git -C "$T/b" reset -q --hard origin/master
  run dot pull
  [ "$status" -eq 0 ]
  [ "$(sj_conflict)" = null ]
  run dot resolve
  [ "$status" -eq 1 ]; [[ $output == *"no stopped pull"* ]]
}

# --- drift ----------------------------------------------------------------
# This PC is pcB (clone b, home), the other is "laptop" (clone a, atarget) via
# the other_pc ssh stub. Both watch three files.
drift_setup() {
  other_pc
  sed -i "s|  up) HOME=|  up) DOT_HOST=laptop HOME=|" "$T/stub/ssh"
  mkdir -p "$T/a/system/drift"
  printf '# test\n.config/t/conf\n.config/same\n.config/kept\n' >"$T/a/system/drift/watch.txt"
  git -C "$T/a" add -A && git -C "$T/a" commit -qm "a: watch" && git -C "$T/a" push -q 2>/dev/null
  git -C "$T/b" pull -q 2>/dev/null
  mkdir -p "$T/home/.config/t" "$T/atarget/.config/t" "$T/b/host-pcB/.config"
  echo "size = 9" >"$T/home/.config/t/conf"
  echo "size = 8" >"$T/atarget/.config/t/conf"
  echo same >"$T/home/.config/same"; echo same >"$T/atarget/.config/same"
  echo mine >"$T/b/host-pcB/.config/kept"; echo theirs >"$T/atarget/.config/kept"
  DOT_HOST=pcB DOT_NO_HOOKS=1 dot link >/dev/null
}
dr() { PATH="$T/stub:$PATH" DOT_HOST=pcB DOT_NO_HOOKS=1 dot "$@"; }
a_dot() { (cd "$T/a" && HOME="$T/ahome" DOTFILES="$T/a" DOT_TARGET="$T/atarget" DOT_HOST=laptop DOT_NO_HOOKS=1 XDG_RUNTIME_DIR="$T/arun" XDG_STATE_HOME="$T/astate" "$DOTBIN" "$@"); }

@test "drift: fingerprints travel in status; only real differences are rows, with the first difference" {
  drift_setup
  dr status --json | jq -e '.drift | map(.path) == [".config/t/conf", ".config/same", ".config/kept"]'
  dr status --json | jq -e '.drift[2].link == "host" and .drift[0].link == "none" and .drift[0].repo == null'
  dr watch >/dev/null
  run dr drift --json detail
  [ "$status" -eq 0 ]
  jq -e '.pcs[0] | .name == "laptop" and .online and (.oldDot | not)' <<<"$output"
  jq -e '.pcs[0].rows == [{path: ".config/t/conf", state: "differs", detail: "size 9 here · 8 on laptop"}]' <<<"$output"
  run dr drift
  [[ $output == *".config/t/conf  size 9 here · 8 on laptop"* ]]
}

@test "drift: only on one PC, an old dot there, and an offline PC's last known rows" {
  drift_setup
  rm "$T/atarget/.config/same"
  dr watch >/dev/null
  dr drift --json | jq -e '.pcs[0].rows | map(.state) == ["differs", "only-here"]'
  sed -i 's/^laptop up$/laptop down/' "$T/b/system/hosts/pcs.txt"
  dr watch >/dev/null
  dr drift --json | jq -e '.pcs[0] | (.online | not) and .asOf != null and (.rows | length) == 2'
  jq '.hosts.laptop.status |= del(.drift)' "$T/run/dot/hosts.json" >"$T/h" && mv "$T/h" "$T/run/dot/hosts.json"
  dr drift --json | jq -e '.pcs[0] | .oldDot and .rows == []'
}

@test "drift sort: keep per PC saves both copies in git, links here, one signed local commit; the other PC links on pull" {
  drift_setup
  run dr drift sort .config/t/conf <<<"3"
  [ "$status" -eq 0 ]
  [[ $output == *"differs between pcB (here) and laptop"* ]]
  [[ $output == *"Committed here, not pushed"* ]]
  [ "$(cat "$T/b/host-pcB/.config/t/conf")" = "size = 9" ]
  [ "$(cat "$T/b/host-laptop/.config/t/conf")" = "size = 8" ]
  [ "$(readlink -f "$T/home/.config/t/conf")" = "$(readlink -f "$T/b/host-pcB/.config/t/conf")" ]
  [ "$(git -C "$T/b" log -1 --format=%s)" = "drift(pcB): .config/t/conf kept per PC" ]
  git -C "$T/b" cat-file commit HEAD | grep -q '^gpgsig '
  [ "$(git -C "$T/b" rev-list --count '@{u}..HEAD')" = 1 ]
  ls "$T/state/dot/drift-backup/"*/.config/t/conf
  git -C "$T/b" push -q 2>/dev/null
  run a_dot pull
  [ "$status" -eq 0 ]
  [[ $output != *"differed from the repo"* ]]
  [ -L "$T/atarget/.config/t/conf" ]
  [ "$(cat "$T/atarget/.config/t/conf")" = "size = 8" ]
}

@test "drift sort: use this PC's on both (new package); the other PC's own copy is backed up on its pull" {
  drift_setup
  printf '1\nterm\n' >"$T/in"
  run dr drift sort "$T/home/.config/t/conf" <"$T/in"
  [ "$status" -eq 0 ]
  [ "$(cat "$T/b/term/.config/t/conf")" = "size = 9" ]
  [ -L "$T/home/.config/t/conf" ]
  [ "$(git -C "$T/b" log -1 --format=%s)" = "drift(pcB): .config/t/conf from pcB on both" ]
  git -C "$T/b" push -q 2>/dev/null
  run a_dot pull
  [ "$status" -eq 0 ]
  [[ $output == *".config/t/conf differed from the repo and was replaced by the link"* ]]
  [ "$(cat "$T/atarget/.config/t/conf")" = "size = 9" ]
  [ "$(cat "$T/astate/dot/drift-backup/"*/.config/t/conf)" = "size = 8" ]
}

@test "drift sort: unreachable PC, leave it, stop watching, and paths not on the list" {
  drift_setup
  before=$(head_b)
  sed -i 's/^laptop up$/laptop down/' "$T/b/system/hosts/pcs.txt"
  run dr drift sort .config/t/conf <<<"1"
  [ "$status" -eq 1 ]
  [[ $output == *"Can't reach laptop, so nothing was changed"* ]]
  sed -i 's/^laptop down$/laptop up/' "$T/b/system/hosts/pcs.txt"
  run dr drift sort .config/t/conf <<<"q"
  [[ $output == *"Nothing was changed"* ]]
  [ "$(head_b)" = "$before" ]
  run dr drift sort ../etc/passwd
  [ "$status" -eq 1 ]
  [[ $output == *"isn't on the watch list"* ]]
  run a_dot drift --cat .bashrc
  [ "$status" -eq 4 ]
  mkdir -p "$T/run/dot"; echo .config/t/conf >"$T/run/dot/drift-target"
  run dr drift sort --from-bar <<<"4"
  [ "$status" -eq 0 ]
  ! grep -qxF .config/t/conf "$T/b/system/drift/watch.txt"
  [ "$(git -C "$T/b" log -1 --format=%s)" = "drift(pcB): stop watching .config/t/conf" ]
}

@test "drift: a watched file saved over its link shows as unlinked; relink keeps the edit or uses the repo's; link re-adopts" {
  drift_setup
  mkdir -p "$T/b/apps/.config"; echo repo >"$T/b/apps/.config/same"
  rm "$T/home/.config/same"
  DOT_HOST=pcB DOT_NO_HOOKS=1 dot link >/dev/null
  [ -L "$T/home/.config/same" ]
  rm "$T/home/.config/same"; echo edited >"$T/home/.config/same"
  dr watch >/dev/null
  dr drift --json | jq -e 'any(.pcs[0].rows[]; . == {path: ".config/same", state: "unlinked"})'
  run dr drift relink .config/same <<<"1"
  [ "$status" -eq 0 ]
  [ -L "$T/home/.config/same" ]
  [ "$(cat "$T/b/apps/.config/same")" = edited ]
  rm "$T/home/.config/same"; echo again >"$T/home/.config/same"
  run dr drift relink .config/same <<<"2"
  [ "$(cat "$T/home/.config/same")" = edited ]
  ls "$T/state/dot/drift-backup/"*/.config/same >/dev/null
  echo edited >"$T/home/.config/same.tmp"; rm "$T/home/.config/same"; mv "$T/home/.config/same.tmp" "$T/home/.config/same"
  run env DOT_HOST=pcB DOT_NO_HOOKS=1 "$DOTBIN" link
  [ "$status" -eq 0 ]
  [[ $output != *"differed"* ]]
  [ -L "$T/home/.config/same" ]
}

# --- today -------------------------------------------------------------------

@test "status --json: today lists today's commits with the PC that made them" {
  echo mine >>"$T/b/f"
  dot push -m "sync(laptop): f" -- "$T/b/f" >/dev/null 2>&1
  dot status --json | jq -e '.today[0] | .subject == "f" and .host != null and (.hash | length) == 40'
}

# --- pick / revert -----------------------------------------------------------

@test "pick theirs: drops this PC's edit (saved), then pulls the other PC's" {
  change_a f theirs
  echo mine >>"$T/b/f"
  run dot pick f theirs
  [ "$status" -eq 0 ]
  [ "$(tail -1 "$T/b/f")" = theirs ]
  grep -qx mine "$T"/state/dot/picked/*/f
}

@test "pick mine: pulls the other PC's change, then shares this PC's version on top" {
  change_a f theirs
  echo mine >>"$T/b/f"
  run dot pick f mine
  [ "$status" -eq 0 ]
  [ "$(tail -1 "$T/b/f")" = mine ]
  [ "$(git -C "$T/remote.git" rev-parse master)" = "$(head_b)" ]
  git -C "$T/remote.git" show master:f | grep -qx mine
  ! git -C "$T/remote.git" show master:f | grep -qx theirs
}

@test "pick: refuses a file that isn't shared" {
  echo x >"$T/b/new"
  run dot pick new mine
  [ "$status" -ne 0 ]
  [[ $output == *"isn't a shared file"* ]]
}

@test "revert: takes one shared change back on both PCs" {
  echo mine >>"$T/b/f"
  dot push -m "add mine" -- "$T/b/f" >/dev/null 2>&1
  c=$(head_b)
  run dot revert "$c"
  [ "$status" -eq 0 ]
  ! grep -qx mine "$T/b/f"
  [ "$(git -C "$T/remote.git" rev-parse master)" = "$(head_b)" ]
  [ "$(git -C "$T/b" log -1 --format=%s)" = "Undo: add mine" ]
}

@test "revert: refuses while a file in that change is edited here" {
  echo mine >>"$T/b/f"
  dot push -m "add mine" -- "$T/b/f" >/dev/null 2>&1
  c=$(head_b)
  echo more >>"$T/b/f"
  run dot revert "$c"
  [ "$status" -ne 0 ]
  [ "$(head_b)" = "$c" ]
  [ "$(tail -1 "$T/b/f")" = more ]
}

