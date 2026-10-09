#!/bin/bash
# Scenario tests for fullupdate.sh. They replace brew, mas, softwareupdate, sudo,
# npm, uv, git, zsh, caffeinate, pkgutil, sw_vers, osascript and launchctl with tests/stub.sh, so nothing on the Mac changes.
#
# Usage: bash tests/run_tests.sh [path/to/fullupdate.sh]
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${1:-$HERE/../fullupdate.sh}"
WORK_ROOT="$(mktemp -d)"
trap 'rm -rf "$WORK_ROOT"' EXIT
PASS=0
FAIL=0
FAILED_NAMES=""

# Fresh fake PATH, stub config, call log and HOME for each scenario
setup() {
    WORK="$WORK_ROOT/case"
    rm -rf "$WORK"
    mkdir -p "$WORK/bin" "$WORK/cfg" "$WORK/home"
    STUB_BIN="$WORK/bin"
    CFG="$WORK/cfg"
    LOG="$WORK/calls.log"
    OUT="$WORK/out.txt"
    FAKE_HOME="$WORK/home"
    : > "$LOG"
    local c
    for c in brew mas softwareupdate sudo npm uv git zsh caffeinate pkgutil sw_vers osascript launchctl; do
        ln -s "$HERE/stub.sh" "$STUB_BIN/$c"
    done
    # Default: macOS reports no updates (softwareupdate prints that to stderr).
    printf 'Software Update Tool\n\nFinding available software\n' > "$CFG/softwareupdate_--list.out"
    echo "No new software available." > "$CFG/softwareupdate_--list.err"
    echo "27.0.1" > "$CFG/sw_vers_-productVersion.out"
}

remove_tool() { rm -f "$STUB_BIN/$1"; }

add_omz() {
    mkdir -p "$FAKE_HOME/.oh-my-zsh/tools" "$FAKE_HOME/.oh-my-zsh/cache" "$FAKE_HOME/.oh-my-zsh/custom/plugins/fzf-tab/.git" \
        "$FAKE_HOME/.oh-my-zsh/custom/plugins/not-a-repo" "$FAKE_HOME/.oh-my-zsh/custom/themes"
}

# Runs the script in a clean environment; RUN_ENV can add one VAR=value.
run() {
    env -i HOME="$FAKE_HOME" ${RUN_ENV:-} PATH="$STUB_BIN:/usr/bin:/bin" STUB_LOG="$LOG" STUB_CFG="$CFG" TERM=dumb \
        /bin/bash "$SCRIPT" "$@" > "$OUT" 2>&1
    RC=$?
}

CURRENT=""
ERRORS=""
fail() { ERRORS="$ERRORS\n    - $1"; }
assert_rc() { [ "$RC" = "$1" ] || fail "exit code $RC, expected $1"; }
log_has() { grep -qF -- "$1" "$LOG" || fail "no call: $1"; }
log_lacks() { ! grep -qF -- "$1" "$LOG" || fail "unexpected call: $1"; }
out_has() { grep -qF -- "$1" "$OUT" || fail "output lacks: $1"; }
first_call() { grep -n -F -- "$1" "$LOG" | head -1 | cut -d: -f1; }
last_call() { grep -n -F -- "$1" "$LOG" | tail -1 | cut -d: -f1; }
out_lacks() { ! grep -qF -- "$1" "$OUT" || fail "output unexpectedly has: $1"; }

begin() { CURRENT="$1"; ERRORS=""; RUN_ENV=""; setup; }
end() {
    if [ -z "$ERRORS" ]; then
        PASS=$((PASS + 1))
        echo "PASS  $CURRENT"
    else
        FAIL=$((FAIL + 1))
        FAILED_NAMES="$FAILED_NAMES $CURRENT"
        echo -e "FAIL  $CURRENT$ERRORS"
        echo "    --- calls:"; sed 's/^/    | /' "$LOG"
        echo "    --- output:"; sed 's/^/    | /' "$OUT"
    fi
}

# Homebrew JSON as 'brew info --cask --json=v2' returns it (only the fields the script reads)
cask_json() {
    # args: token version bundle_short_version bundle_version [pkg receipt id...] (null for none)
    local t="$1" v="$2" s="$3" b="$4" ids="" id
    shift 4
    [ "$s" = null ] || s="\"$s\""
    [ "$b" = null ] || b="\"$b\""
    for id in "$@"; do ids="$ids${ids:+,}\"$id\""; done
    printf '{"token":"%s","version":"%s","bundle_short_version":%s,"bundle_version":%s,"artifacts":[{"pkg":["x.pkg"]},{"uninstall":[{"quit":"x","pkgutil":[%s]}]}]}' \
        "$t" "$v" "$s" "$b" "$ids"
}

# Writes a 'softwareupdate --list' result; each argument is "<label>|<title>|<version>|<restart or ->"
su_list() {
    local entry label title version action
    {
        printf 'Software Update Tool\n\nFinding available software\n'
        echo "Software Update found the following new or updated software:"
        for entry in "$@"; do
            IFS='|' read -r label title version action <<< "$entry"
            echo "* Label: $label"
            printf '\tTitle: %s, Version: %s, Size: 1500000KiB, Recommended: YES, %s\n' \
                "$title" "$version" "$([ "$action" = restart ] && echo 'Action: restart,')"
        done
    } > "$CFG/softwareupdate_--list.out"
    rm -f "$CFG/softwareupdate_--list.err"
}

# A: everything up to date
begin "A all up to date"
add_omz
run
assert_rc 0
log_has "brew update"
log_has "brew upgrade --formula"
log_has "brew outdated --cask --greedy-auto-updates --quiet"
log_lacks "brew upgrade --cask"
log_lacks "brew info"
log_has "brew cleanup -s"
log_has "mas outdated"
log_lacks "mas upgrade"
log_has "zsh -f $FAKE_HOME/.oh-my-zsh/tools/upgrade.sh"
log_has "git -C $FAKE_HOME/.oh-my-zsh/custom/plugins/fzf-tab pull --ff-only --quiet"
log_lacks "not-a-repo"
log_has "npm outdated --global --parseable"
log_lacks "npm update"
log_has "uv tool upgrade --all"
log_has "uv python upgrade"
log_has "sudo -k"
log_has "softwareupdate --list"
log_lacks "softwareupdate --install"
log_has "caffeinate -i -w"
out_has "All apps are up to date."
out_has "Your system is up to date."
out_has "All updates are complete!"
grep -q '^LAST_EPOCH=[0-9][0-9]*$' "$FAKE_HOME/.oh-my-zsh/cache/.zsh-update" || fail "LAST_EPOCH not written"
end

# B: brew update fails (no network) -> later steps still run, exit 1
begin "B brew update fails, other steps still run"
add_omz
echo 1 > "$CFG/brew_update.rc"
run
assert_rc 1
log_lacks "brew upgrade"
log_has "mas outdated"
log_has "zsh -f"
log_has "softwareupdate --list"
out_has "failed"
out_lacks "All updates are complete!"
end

# C: cask upgrade fails ("already an App at"), retry with --force succeeds -> brew step ok
begin "C cask conflict fixed by --force retry"
echo rectangle > "$CFG/brew_outdated_--cask_--greedy-auto-updates_--quiet.out"
cask_json rectangle 2.0.3 0.98 104 | sed 's/^/{"casks":[/; s/$/]}/' > "$CFG/brew_info_--cask_--json=v2_rectangle.out"
echo 1 > "$CFG/brew_upgrade_--cask_rectangle.rc"
echo "Error: It seems there is already an App at '/Applications/Rectangle.app'." > "$CFG/brew_upgrade_--cask_rectangle.err"
run
assert_rc 0
log_has "brew upgrade --cask rectangle"
log_has "brew upgrade --cask --force rectangle"
out_has "Retrying rectangle with --force"
end

# D: one app fails in the single brew call and its forced retry fails too -> brew step failed.
#    Only that app is retried (not the one that succeeded, not one skipped as current); other steps continue.
begin "D cask retry fails"
printf 'rectangle\nmicrosoft-teams\ntelegram\n' > "$CFG/brew_outdated_--cask_--greedy-auto-updates_--quiet.out"
# After the brew call, rectangle (failed) and telegram (skipped as current) are still outdated.
printf 'rectangle\ntelegram\n' > "$CFG/brew_outdated_--cask_--greedy-auto-updates_--quiet.out.2"
{ printf '{"casks":['; cask_json rectangle 2.0.3 0.98 104; printf ','; cask_json microsoft-teams 26261.303.5165.1465 null null
  printf ','; cask_json telegram 13.0 13.0 1; printf ']}'; } \
    > "$CFG/brew_info_--cask_--json=v2_rectangle_microsoft-teams_telegram.out"
echo 1 > "$CFG/brew_upgrade_--cask_rectangle_microsoft-teams.rc"
echo 1 > "$CFG/brew_upgrade_--cask_--force_rectangle.rc"
run
assert_rc 1
log_has "brew upgrade --cask rectangle microsoft-teams"
log_has "brew upgrade --cask --force rectangle"
log_lacks "brew upgrade --cask --force microsoft-teams"
log_lacks "--force telegram"
log_has "brew cleanup -s"
log_has "mas outdated"
end

# Q: apps that already updated themselves are not reinstalled; pkg apps (no bundle info) are upgraded
begin "Q skip apps that already report the latest version"
printf 'telegram\nwhatsapp\nmicrosoft-outlook\n' > "$CFG/brew_outdated_--cask_--greedy-auto-updates_--quiet.out"
{ printf '{"casks":['; cask_json telegram "13.0,283301" 13.0 283301; printf ','
  cask_json whatsapp 26.40.20 26.40.16 1084308996; printf ','
  cask_json microsoft-outlook 16.113.26091740 null null; printf ']}'; } \
    > "$CFG/brew_info_--cask_--json=v2_telegram_whatsapp_microsoft-outlook.out"
run
assert_rc 0
log_lacks "brew upgrade --cask telegram"
log_has "brew upgrade --cask whatsapp microsoft-outlook"
out_has "telegram: the app already has the latest version."
end

# U: pkg-installed apps: Homebrew can't read their bundle, so the installer receipt decides
begin "U pkg apps checked via installer receipts"
printf 'google-drive\nmicrosoft-outlook\nmicrosoft-auto-update\n' > "$CFG/brew_outdated_--cask_--greedy-auto-updates_--quiet.out"
{ printf '{"casks":['; cask_json google-drive 132.0.0 null null com.google.drivefs.arm64 com.google.drivefs.shortcuts; printf ','
  cask_json microsoft-outlook 16.113.26091740 null null com.microsoft.package.Microsoft_Outlook.app; printf ','
  cask_json microsoft-auto-update 4.85.26091737 null null com.microsoft.package.Microsoft_AutoUpdate.app; printf ']}'; } \
    > "$CFG/brew_info_--cask_--json=v2_google-drive_microsoft-outlook_microsoft-auto-update.out"
printf 'package-id: com.google.drivefs.arm64\nversion: 132.0.0.0\n' > "$CFG/pkgutil_--pkg-info_com.google.drivefs.arm64.out"
echo 1 > "$CFG/pkgutil_--pkg-info_com.google.drivefs.shortcuts.rc"
printf 'package-id: com.microsoft.package.Microsoft_Outlook.app\nversion: 16.101.25092124\n' > "$CFG/pkgutil_--pkg-info_com.microsoft.package.Microsoft_Outlook.app.out"
echo 1 > "$CFG/pkgutil_--pkg-info_com.microsoft.package.Microsoft_AutoUpdate.app.rc"
run
assert_rc 0
log_lacks "brew upgrade --cask google-drive"
log_has "brew upgrade --cask microsoft-outlook microsoft-auto-update"
out_has "google-drive: the app already has the latest version."
end

# R: FULLUPDATE_SKIP_CASKS
begin "R FULLUPDATE_SKIP_CASKS"
RUN_ENV="FULLUPDATE_SKIP_CASKS=docker-desktop"
printf 'docker-desktop\nwhatsapp\n' > "$CFG/brew_outdated_--cask_--greedy-auto-updates_--quiet.out"
{ printf '{"casks":['; cask_json docker-desktop 4.50.0 4.49.0 4.49.0; printf ','; cask_json whatsapp 26.40.20 26.40.16 1; printf ']}'; } \
    > "$CFG/brew_info_--cask_--json=v2_docker-desktop_whatsapp.out"
run
assert_rc 0
log_lacks "brew upgrade --cask docker-desktop"
log_has "brew upgrade --cask whatsapp"
out_has "docker-desktop: skipped, it is listed in FULLUPDATE_SKIP_CASKS."
end

# E: mas outdated fails with no output -> must not claim "up to date"
begin "E mas outdated fails"
echo 1 > "$CFG/mas_outdated.rc"
echo "Error: network" > "$CFG/mas_outdated.err"
run
assert_rc 1
out_lacks "All App Store apps are up to date."
log_lacks "mas upgrade"
log_has "softwareupdate --list"
end

# F: mas has updates -> mas upgrade runs
begin "F mas updates available"
echo "497799835 Xcode (16.0 -> 16.1)" > "$CFG/mas_outdated.out"
run
assert_rc 0
log_has "mas upgrade"
end

# G: macOS updates with restart -> install that update by its label via sudo, restart notice
begin "G macOS update needing restart"
su_list "macOS 27.0.2-26A500|macOS 27.0.2|27.0.2|restart"
run
assert_rc 0
log_has "sudo softwareupdate --install macOS 27.0.2-26A500 --verbose"
out_has "Restart your Mac"
end

# H: softwareupdate check fails (no Label, no "No new software") -> fail, no install
begin "H softwareupdate check fails"
echo "Can't connect to the Apple Software Update server." > "$CFG/softwareupdate_--list.err"
run
assert_rc 1
log_lacks "softwareupdate --install"
out_has "Could not check for macOS updates."
end

# I: npm globals: skip npm itself and npm-linked packages
begin "I npm globals filtering"
mkdir -p "$FAKE_HOME/nm/tailwindcss" "$FAKE_HOME/nm/@vue/cli" "$FAKE_HOME/nm/npm" "$FAKE_HOME/proj"
ln -s "$FAKE_HOME/proj" "$FAKE_HOME/nm/linked"
cat > "$CFG/npm_outdated_--global_--parseable.out" <<EOF
$FAKE_HOME/nm/@vue/cli:@vue/cli@5.0.9:@vue/cli@5.0.8:@vue/cli@5.0.9:global
$FAKE_HOME/nm/npm:npm@12.2.0:npm@11.20.0:npm@12.2.0:global
$FAKE_HOME/nm/linked:linked@2.0.0:linked@1.0.0:linked@2.0.0:global
$FAKE_HOME/nm/tailwindcss:tailwindcss@4.3.3:tailwindcss@4.1.6:tailwindcss@4.3.3:global
EOF
echo 1 > "$CFG/npm_outdated_--global_--parseable.rc"
run
assert_rc 0
log_has "npm update --global @vue/cli tailwindcss"
log_lacks "linked"
end

# J: npm outdated fails with no output -> dev step failed
begin "J npm check fails"
echo 1 > "$CFG/npm_outdated_--global_--parseable.rc"
run
assert_rc 1
out_has "Could not check global npm packages."
log_lacks "npm update"
log_has "uv tool upgrade --all"
end

# K: --check changes nothing and reports which steps have updates
begin "K --check is read-only"
add_omz
echo 3 > "$CFG/git_-C_fzf-tab_rev-list_--count_HEAD..@{upstream}.out"
echo 0 > "$CFG/git_-C_.oh-my-zsh_rev-list_--count_HEAD..@{upstream}.out"
echo "node (24.1.0) < 24.2.0" > "$CFG/brew_outdated_--formula_--verbose.out"
printf 'telegram\nwhatsapp\n' > "$CFG/brew_outdated_--cask_--greedy-auto-updates_--quiet.out"
{ printf '{"casks":['; cask_json telegram 13.0 13.0 1; printf ','; cask_json whatsapp 26.40.20 26.40.16 1; printf ']}'; } \
    > "$CFG/brew_info_--cask_--json=v2_telegram_whatsapp.out"
echo "497799835 Xcode (16.0 -> 16.1)" > "$CFG/mas_outdated.out"
su_list "Safari 27.1-27.1|Safari 27.1|27.1|-"
run --check
assert_rc 0
log_lacks "brew update"
log_lacks "brew upgrade"
log_lacks "brew cleanup"
log_lacks "brew doctor"
log_lacks "mas upgrade"
log_lacks "zsh -f"
log_lacks "pull"
log_has "fetch --quiet"
log_lacks "npm update"
log_lacks "uv tool upgrade"
log_lacks "uv python upgrade"
log_has "uv tool list --outdated"
log_lacks "softwareupdate --install"
log_lacks "sudo"
log_lacks "caffeinate"
log_lacks "osascript"
out_has "node (24.1.0) < 24.2.0"
out_has "Apps to upgrade: whatsapp"
out_has "fzf-tab: 3 new commits"
out_has "Oh My Zsh: 0 new commits"
grep -q "^  dev .*up to date" "$OUT" || fail "dev should be up to date"
for step in omz brew mas system; do
    grep -q "^  $step .*updates available" "$OUT" || fail "$step should have updates available"
done
out_has "Updates are available. Run fullupdate to install them."
out_lacks "Restart your Mac"
[ ! -f "$FAKE_HOME/.oh-my-zsh/cache/.zsh-update" ] || fail "--check wrote LAST_EPOCH"
end

# L: --skip, repeated and comma-separated
begin "L --skip"
add_omz
run --skip system --skip omz,dev
assert_rc 0
log_lacks "softwareupdate"
log_lacks "zsh -f"
log_lacks "npm"
log_has "mas outdated"
out_has "skipped"
end

# S: --only
begin "S --only brew,mas"
add_omz
run --only brew,mas
assert_rc 0
log_has "brew update"
log_has "mas outdated"
log_lacks "zsh -f"
log_lacks "npm"
log_lacks "softwareupdate"
end

# M: bad options
begin "M unknown option and bad --skip"
run --bogus
assert_rc 2
out_has "Unknown option: --bogus"
run --skip nope
assert_rc 2
out_has "Unknown step for --skip: 'nope'"
run --only brew,nope
assert_rc 2
out_has "Unknown step for --only: 'nope'"
run --skip
assert_rc 2
out_has "Missing step names after --skip"
[ ! -s "$LOG" ] || fail "bad options still ran commands"
end

# N: tools missing -> steps "not installed", exit 0
begin "N tools missing"
remove_tool brew; remove_tool mas; remove_tool npm; remove_tool uv
run
assert_rc 0
out_has "Homebrew not found"
out_has "not installed"
log_lacks "brew "
log_lacks "mas "
end

# O: --help
begin "O --help"
run --help
assert_rc 0
out_has "Usage: fullupdate"
[ ! -s "$LOG" ] || fail "--help ran commands"
end

# P: Oh My Zsh upgrade fails -> omz failed, LAST_EPOCH not written, plugins still pulled
begin "P omz upgrade fails"
add_omz
echo 1 > "$CFG/zsh_-f_upgrade.sh.rc"
run
assert_rc 1
log_has "pull --ff-only"
[ ! -f "$FAKE_HOME/.oh-my-zsh/cache/.zsh-update" ] || fail "LAST_EPOCH written after failed upgrade"
end

# W: steps that never need a password run first; the ones that may need it run back to back
#    at the end, with no "sudo -k" between them (so one password prompt can cover them all)
begin "W step order"
add_omz
run
assert_rc 0
[ "$(first_call 'npm outdated')" -lt "$(first_call 'zsh -f')" ] || fail "dev should run before omz"
[ "$(first_call 'zsh -f')" -lt "$(first_call 'brew update')" ] || fail "omz should run before brew"
[ "$(first_call 'brew update')" -lt "$(first_call 'mas outdated')" ] || fail "brew should run before mas"
[ "$(first_call 'mas outdated')" -lt "$(first_call 'softwareupdate --list')" ] || fail "mas should run before system"
[ "$(last_call 'sudo -k')" -lt "$(first_call 'brew update')" ] || fail "sudo -k must not run after brew starts"
end

# X: a new major macOS version is only reported; the other updates are installed
begin "X major macOS version is not installed"
su_list "macOS 28.0-27A100|macOS 28.0|28.0|restart" "Safari 27.1-27.1|Safari 27.1|27.1|-" "macOS 27.0.2-26A500|macOS 27.0.2|27.0.2|restart"
run
assert_rc 0
log_has "sudo softwareupdate --install Safari 27.1-27.1 macOS 27.0.2-26A500 --verbose"
log_lacks "macOS 28.0-27A100"
out_has "macOS 28.0 is available. Upgrade from System Settings when you are ready."
out_has "Restart your Mac"
end

# Y: only a major macOS version is available -> nothing to install, not "updates available"
begin "Y only a major macOS version available"
su_list "macOS 28.0-27A100|macOS 28.0|28.0|restart"
run --check
assert_rc 0
log_lacks "softwareupdate --install"
out_has "Your macOS version is up to date."
grep -q "^  system .*up to date" "$OUT" || fail "system should be up to date"
out_has "Everything is up to date."
end

# Z: Brave-style versions: the app reports a prefix in front of Homebrew's version
begin "Z app version with a prefix counts as current"
printf 'brave-browser\nfoo\n' > "$CFG/brew_outdated_--cask_--greedy-auto-updates_--quiet.out"
{ printf '{"casks":['; cask_json brave-browser 1.97.60.0 155.1.97.60 195.60; printf ','
  cask_json foo 1.2.3 11.2.3 7; printf ']}'; } > "$CFG/brew_info_--cask_--json=v2_brave-browser_foo.out"
run
assert_rc 0
out_has "brave-browser: the app already has the latest version."
log_has "brew upgrade --cask foo"
log_lacks "brew upgrade --cask brave-browser"
end

# N1: --check --notify with updates -> one notification naming the steps
begin "N1 notify when updates are available"
echo "497799835 Xcode (16.0 -> 16.1)" > "$CFG/mas_outdated.out"
run --check --notify
assert_rc 0
log_has "osascript -e display notification \"Updates available: mas. Run fullupdate to install them.\" with title \"fullupdate\""
end

# N2: --check --notify with nothing to do -> no notification
begin "N2 no notification when everything is up to date"
run --check --notify
assert_rc 0
log_lacks "osascript"
out_has "Everything is up to date."
end

# N3: --notify after an update run, and after a failed one
begin "N3 notify after updating and after a failure"
run --notify
assert_rc 0
log_has "display notification \"All updates are complete.\""
echo 1 > "$CFG/brew_update.rc"
run --notify
assert_rc 1
log_has "display notification \"Some steps failed: brew\""
end

# V: --install-weekly-check writes a valid launchd job and loads it; --uninstall-weekly-check removes it
begin "V weekly check install and uninstall"
run --install-weekly-check
assert_rc 0
PLIST="$FAKE_HOME/Library/LaunchAgents/com.github.patrykwiener.fullupdate.check.plist"
[ -f "$PLIST" ] || fail "plist not written"
plutil -lint "$PLIST" > /dev/null || fail "plist is not valid"
grep -q "<string>$SCRIPT</string>" "$PLIST" || grep -q "<string>$(cd "$(dirname "$SCRIPT")" && pwd)/$(basename "$SCRIPT")</string>" "$PLIST" || fail "plist lacks the script path"
grep -q "<string>--check</string>" "$PLIST" || fail "plist lacks --check"
grep -q "<string>--notify</string>" "$PLIST" || fail "plist lacks --notify"
grep -q "<string>$STUB_BIN:/usr/bin:/bin</string>" "$PLIST" || fail "plist lacks the PATH"
log_has "launchctl bootstrap gui/$(id -u) $PLIST"
out_has "Weekly check installed"
run --uninstall-weekly-check
assert_rc 0
[ ! -f "$PLIST" ] || fail "plist not removed"
log_has "launchctl bootout gui/$(id -u)/com.github.patrykwiener.fullupdate.check"
end

# T: no color codes when output is not a terminal
begin "T no escape codes in piped output"
run
grep -q "$(printf '\033')" "$OUT" && fail "escape codes in non-terminal output"
end

echo
echo "passed: $PASS, failed: $FAIL${FAILED_NAMES:+ ($FAILED_NAMES )}"
[ "$FAIL" -eq 0 ]
