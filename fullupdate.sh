#!/bin/bash

# fullupdate - A comprehensive macOS update script.
#
# This script updates:
# 1. Developer tools: global npm packages, uv tools and uv-managed Pythons.
# 2. Oh My Zsh and the plugins and themes cloned into its custom folder.
# 3. Homebrew formulae and casks, including apps that also update themselves.
# 4. Mac App Store applications (via mas-cli).
# 5. macOS system software, except a new major macOS version (it only reports that).
#
# Every step runs even if an earlier one fails. A summary at the end shows the
# result of each step, and the script exits with status 1 if any step failed.
#
# Run 'fullupdate --help' for options.

# Note: no 'set -e' on purpose. With it, one failing command (for example
# 'brew update' without network) skipped every later step, including macOS
# security updates. Each step now reports its own failure instead.

# --- Homebrew non-interactive behaviour ---
# Auto-confirm upgrades so we never get stuck on the "Do you want to proceed? [y/n]" prompt.
export HOMEBREW_NO_ASK=1
# Silence the extra environment hints Homebrew prints during upgrades.
export HOMEBREW_NO_ENV_HINTS=1

# Define some colors for output to make it more readable
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_RED='\033[0;31m'
COLOR_BLUE='\033[0;34m'
COLOR_NC='\033[0m' # No Color
# No colors when the output goes to a file or a pipe
if [ ! -t 1 ]; then
    COLOR_GREEN='' COLOR_YELLOW='' COLOR_RED='' COLOR_BLUE='' COLOR_NC=''
fi

# A step returns 0 when it succeeded, 1 when it failed, and STEP_SKIPPED when
# the tool it updates is not installed.
STEP_SKIPPED=2

# Options, set by parse_args
CHECK_ONLY=false # --check: only show what is outdated
NOTIFY=false     # --notify: show a macOS notification when the run ends
ONLY_STEPS=""    # --only: run just these steps (space-separated names)
SKIP_STEPS=""    # --skip: don't run these steps

# Optional, from your environment: casks fullupdate must never upgrade,
# e.g. export FULLUPDATE_SKIP_CASKS="docker-desktop" in ~/.zshrc.
FULLUPDATE_SKIP_CASKS="${FULLUPDATE_SKIP_CASKS:-}"

# Set by update_system when an installed update needs a restart to finish.
RESTART_NEEDED=false

# The step that is running, the steps that failed, and with --check the steps
# that found something to update
CURRENT_STEP=""
FAILED_STEPS=""
PENDING_STEPS=""

# One line per step for the final summary
SUMMARY=()

# The weekly check: a launchd job (macOS's scheduler) set up by --install-weekly-check
WEEKLY_CHECK_LABEL="com.github.patrykwiener.fullupdate.check"
WEEKLY_CHECK_PLIST="$HOME/Library/LaunchAgents/$WEEKLY_CHECK_LABEL.plist"
WEEKLY_CHECK_LOG="$HOME/Library/Logs/fullupdate-check.log"

usage() {
    cat <<'EOF'
Usage: fullupdate [options]

Updates developer tools, Oh My Zsh, Homebrew, Mac App Store apps and macOS.
A new major macOS version (e.g. 27 -> 28) is only reported, never installed.

Options:
  --check                   Only show what is outdated; upgrade nothing.
  --only STEPS              Run only these steps, e.g. --only brew,mas
  --skip STEPS              Skip these steps, e.g. --skip system
  --notify                  Show a macOS notification when the run ends
                            (with --check: only if something is outdated).
  --install-weekly-check    Run 'fullupdate --check --notify' every Monday at 10:00.
  --uninstall-weekly-check  Remove that weekly check.
  -h, --help                Show this help.

Steps, in the order they run: dev, omz, brew, mas, system.

Casks listed in the environment variable FULLUPDATE_SKIP_CASKS
(space-separated) are never upgraded.
EOF
}

# Helper function for printing styled headers for each section, now with emoji support
print_header() {
    # $1 = message, $2 = emoji (optional)
    local emoji="${2:-}"
    echo -e "\n${COLOR_BLUE}==> ${emoji} $1${COLOR_NC}"
}

print_warning() {
    echo -e "${COLOR_YELLOW}⚠️  $1${COLOR_NC}"
}

# "Updating" normally, "Checking" with --check
action_word() {
    if $CHECK_ONLY; then echo "Checking"; else echo "Updating"; fi
}

# True if word $1 appears in the whitespace-separated list $2.
in_list() {
    local word
    for word in $2; do
        [ "$word" = "$1" ] && return 0
    done
    return 1
}

# With --check: records that the running step found something to update.
mark_pending() {
    in_list "$CURRENT_STEP" "$PENDING_STEPS" || PENDING_STEPS="$PENDING_STEPS $CURRENT_STEP"
}

# Shows a macOS notification; $1 = message
notify() {
    osascript -e "display notification \"$1\" with title \"fullupdate\"" > /dev/null 2>&1 || true
}

# --- Homebrew Updates ---
update_homebrew() {
    print_header "$(action_word) Homebrew..." "🍺"
    # Check if the 'brew' command exists
    if ! command -v brew &> /dev/null; then
        print_warning "Homebrew not found. Please install it from https://brew.sh/"
        return $STEP_SKIPPED
    fi

    local status=0
    if $CHECK_ONLY; then
        local formulas
        formulas=$(brew outdated --formula --verbose) || return 1
        if [ -n "$formulas" ]; then
            echo "📋 Outdated formulas:"
            echo "$formulas"
            mark_pending
        else
            echo "🟢 All formulas are up to date."
        fi
    else
        echo "🔄 Updating formulas..."
        brew update || return 1
        # The package lists are fresh now, so the brew calls below needn't check again.
        export HOMEBREW_NO_AUTO_UPDATE=1
        echo "⬆️  Upgrading formulas..."
        brew upgrade --formula || status=1
    fi

    echo "🔄 Checking apps (casks)..."
    local casks cask
    casks=$(casks_to_upgrade) || return 1
    if [ -z "$casks" ]; then
        echo "🟢 All apps are up to date."
    elif $CHECK_ONLY; then
        # $casks is unquoted on purpose: print the names on one line.
        # shellcheck disable=SC2086
        echo "📋 Apps to upgrade:" $casks
        mark_pending
    else
        # shellcheck disable=SC2086
        echo "⬆️  Upgrading apps:" $casks
        # One brew call for all apps: each brew call makes sudo forget your
        # password the first time it needs sudo, so one call means one
        # password prompt for all the .pkg installers. A failing app doesn't
        # stop the others.
        # Homebrew quits a running app before upgrading it and reopens it afterwards.
        # $casks is unquoted on purpose: one argument per cask.
        # shellcheck disable=SC2086
        if ! brew upgrade --cask $casks; then
            # Retry each app that is still outdated once with --force. An app
            # replaced outside Homebrew (e.g. by its own updater) fails with
            # "It seems there is already an App at ...", which --force overwrites.
            for cask in $(brew outdated --cask --greedy-auto-updates --quiet); do
                in_list "$cask" "$casks" || continue
                echo "🔁 Retrying $cask with --force..."
                brew upgrade --cask --force "$cask" || status=1
            done
        fi
    fi
    if $CHECK_ONLY; then
        return $status
    fi

    echo "🧹 Cleaning up old versions and cache..."
    brew cleanup -s || print_warning "Cleanup failed. Continuing."
    echo "🔍 Checking for potential issues..."
    brew doctor || true
    return $status
}

# Prints the casks (apps) to upgrade, one per line, and explains on stderr each
# outdated cask it leaves out.
casks_to_upgrade() {
    # --greedy-auto-updates also lists casks marked "auto_updates", i.e. apps
    # with their own updater, which is most apps. Without it Homebrew skips
    # most of them, so an app whose own updater is broken (Outlook and Teams,
    # for example) silently stays far behind.
    local outdated
    outdated=$(brew outdated --cask --greedy-auto-updates --quiet) || return 1
    [ -n "$outdated" ] || return 0

    # That list compares the latest version with the version Homebrew
    # installed, so it also contains apps that have since updated themselves.
    # Upgrading those would quit them and download them again for nothing, so
    # look up which version each installed app reports (jq ships with macOS 15+).
    local versions=""
    if command -v jq &> /dev/null; then
        # $outdated is unquoted on purpose: one argument per cask.
        # shellcheck disable=SC2086
        versions=$(brew info --cask --json=v2 $outdated | jq -r "$JQ_CASK_VERSIONS") || return 1
    fi

    local cask
    for cask in $outdated; do
        if in_list "$cask" "$FULLUPDATE_SKIP_CASKS"; then
            echo "⏭️  $cask: skipped, it is listed in FULLUPDATE_SKIP_CASKS." >&2
        elif app_is_current "$(echo "$versions" | awk -v cask="$cask" '$1 == cask')"; then
            echo "⏭️  $cask: the app already has the latest version." >&2
        else
            echo "$cask"
        fi
    done
}

# jq filter for 'brew info --cask --json=v2'. Prints one line per cask:
#   <token> <latest version> <latest build> <installed version>...
# An installed version comes from the app bundle, or is "pkg:<receipt id>" for
# an app installed from a .pkg, whose bundle Homebrew does not read.
# shellcheck disable=SC2016 # $latest is a jq variable, not a shell one
JQ_CASK_VERSIONS='
    .casks[]
    | (.version | split(",")) as $latest
    | [.token, $latest[0], ($latest[1] // $latest[0]), .bundle_short_version, .bundle_version]
      + [.artifacts[]? | objects | .uninstall? // empty | .[] | .pkgutil? // empty
         | if type == "array" then .[] else . end | "pkg:" + .]
    | map(select(. != null)) | join(" ")'

# True if the installed app already reports the cask's latest version.
# $1 = one line printed by JQ_CASK_VERSIONS (empty when unknown)
app_is_current() {
    local cask latest build installed version
    read -r cask latest build installed <<< "$1"
    for version in $installed; do
        case "$version" in
            pkg:*) version=$(pkgutil --pkg-info "${version#pkg:}" 2> /dev/null | sed -n 's/^version: //p') ;;
        esac
        if [ -n "$version" ] && { version_matches "$version" "$latest" || version_matches "$version" "$build"; }; then
            return 0
        fi
    done
    return 1
}

# True if installed version $1 matches latest version $2, ignoring trailing
# ".0" parts: an installer receipt says 132.0.0.0 where Homebrew says 132.0.0.
# $1 may also have extra parts in front: Brave reports 155.1.97.56 (Chromium
# 155, Brave 1.97.56) where Homebrew says 1.97.56.0.
version_matches() {
    local installed="$1" latest="$2"
    while [ "${installed%.0}" != "$installed" ]; do installed="${installed%.0}"; done
    while [ "${latest%.0}" != "$latest" ]; do latest="${latest%.0}"; done
    [ -n "$latest" ] || return 1
    case ".$installed" in
        *".$latest") return 0 ;;
    esac
    return 1
}

# --- Mac App Store Updates ---
update_mas() {
    print_header "$(action_word) Mac App Store Apps..." "🛍️"
    # Check if the 'mas' command-line interface is installed
    if ! command -v mas &> /dev/null; then
        # If brew is available, install mas automatically
        if $CHECK_ONLY || ! command -v brew &> /dev/null; then
            print_warning "'mas-cli' not found. Skipping App Store updates."
            return $STEP_SKIPPED
        fi
        print_warning "'mas-cli' not found. Installing it with Homebrew..."
        brew install mas || return 1
    fi
    echo "🔄 Checking for App Store updates..."
    # Store the list first: if 'mas outdated' itself fails (e.g. no network),
    # the step must fail instead of reporting "up to date".
    local outdated
    outdated=$(mas outdated) || return 1
    if [ -z "$outdated" ]; then
        echo "🟢 All App Store apps are up to date."
        return 0
    fi
    echo "$outdated"
    if $CHECK_ONLY; then
        mark_pending
        return 0
    fi
    # Updating App Store apps needs root; mas asks for your password itself.
    echo "⬆️  Upgrading apps..."
    mas upgrade
}

# Prints how many new commits a git repository has upstream.
print_commits_behind() {
    # $1 = repository, $2 = name to print (optional)
    local behind
    if git -C "$1" fetch --quiet && behind=$(git -C "$1" rev-list --count 'HEAD..@{upstream}'); then
        echo "📋 ${2:-$(basename "$1")}: $behind new commits"
        [ "$behind" = 0 ] || mark_pending
    else
        print_warning "Could not check $1"
        return 1
    fi
}

# --- Oh My Zsh Update (Optional Bonus) ---
update_ohmyzsh() {
    local omz_dir="${ZSH:-$HOME/.oh-my-zsh}"
    # Check if the Oh My Zsh directory exists
    if [ ! -d "$omz_dir" ]; then
        return $STEP_SKIPPED
    fi
    print_header "$(action_word) Oh My Zsh..." "🦄"
    local status=0
    if $CHECK_ONLY; then
        print_commits_behind "$omz_dir" "Oh My Zsh" || status=1
    elif ZSH="$omz_dir" zsh -f "$omz_dir/tools/upgrade.sh"; then
        # That is the script 'omz update' runs. Also record the update date
        # like 'omz update' does, so Oh My Zsh doesn't offer to update again
        # right after this run.
        if [ -d "$omz_dir/cache" ]; then
            echo "LAST_EPOCH=$(( $(date +%s) / 86400 ))" > "$omz_dir/cache/.zsh-update"
        fi
    else
        status=1
    fi

    # Plugins and themes cloned into the custom folder are separate git
    # repositories, which Oh My Zsh's upgrade script does not touch.
    local custom_dir="${ZSH_CUSTOM:-$omz_dir/custom}" repo
    for repo in "$custom_dir"/plugins/* "$custom_dir"/themes/*; do
        [ -d "$repo/.git" ] || continue
        if $CHECK_ONLY; then
            print_commits_behind "$repo" || status=1
        else
            echo "🔄 Updating $(basename "$repo")..."
            # --ff-only: never create a merge commit over local changes.
            git -C "$repo" pull --ff-only --quiet || status=1
        fi
    done
    return $status
}

# Upgrades global npm packages, except npm itself and packages added with 'npm link'.
update_npm_globals() {
    echo "🔄 Checking global npm packages..."
    local outdated
    # 'npm outdated' also exits with 1 when it finds outdated packages, so only
    # a failure with no output means the check itself failed.
    if ! outdated=$(npm outdated --global --parseable) && [ -z "$outdated" ]; then
        print_warning "Could not check global npm packages."
        return 1
    fi
    local packages="" path current name
    # Each line looks like: <path>:<wanted>:<current>:<latest>:<location>
    while IFS=: read -r path _ current _; do
        [ -n "$path" ] || continue
        # Skip a package linked from a local folder with 'npm link'.
        [ -L "$path" ] && continue
        name="${current%@*}" # "@vue/cli@5.0.8" -> "@vue/cli"
        # npm comes with Homebrew's node, and Homebrew upgrades it.
        case "$name" in npm | corepack) continue ;; esac
        packages="$packages $name"
    done <<< "$outdated"
    if [ -z "$packages" ]; then
        echo "🟢 All global npm packages are up to date."
        return 0
    fi
    echo "📋 Outdated:$packages"
    if $CHECK_ONLY; then
        mark_pending
        return 0
    fi
    echo "⬆️  Upgrading global npm packages..."
    # $packages is unquoted on purpose: one argument per package.
    # shellcheck disable=SC2086
    npm update --global $packages
}

# --- Developer Tools (npm, uv) ---
update_dev_tools() {
    local has_npm=false has_uv=false
    command -v npm &> /dev/null && has_npm=true
    command -v uv &> /dev/null && has_uv=true
    if ! $has_npm && ! $has_uv; then
        return $STEP_SKIPPED
    fi
    print_header "$(action_word) developer tools..." "🧰"
    if ! $CHECK_ONLY; then
        # npm and uv can run install scripts from third-party packages. Make
        # sudo forget any password you entered recently, so those scripts
        # can't use it.
        sudo -k
    fi
    local status=0
    if $has_npm; then
        update_npm_globals || status=1
    fi
    if $has_uv; then
        if $CHECK_ONLY; then
            local tools
            tools=$(uv tool list --outdated 2> /dev/null) || status=1
            if [ -n "$tools" ]; then
                echo "📋 Outdated uv tools:"
                echo "$tools"
                mark_pending
            fi
        else
            echo "⬆️  Upgrading uv tools..."
            uv tool upgrade --all || status=1
            echo "⬆️  Upgrading Python versions installed by uv..."
            uv python upgrade || status=1
        fi
    fi
    return $status
}

# awk program for 'softwareupdate --list'. Prints one line per update:
#   <label>|<title>|<version>|<"restart" if it needs a restart, else "-">
# shellcheck disable=SC2016 # $0 is an awk field, not a shell one
AWK_UPDATES='
    /^\* Label: / { label = substr($0, 10); next }
    label != "" && /Title: / {
        title = $0;   sub(/^[ \t]*Title: /, "", title); sub(/, Version: .*/, "", title)
        version = $0; sub(/.*Version: /, "", version);   sub(/,.*/, "", version)
        print label "|" title "|" version "|" (/Action: restart/ ? "restart" : "-")
        label = ""
    }'

# True if macOS version $1 (e.g. 28.0) has a higher major number than $2 (e.g. 27).
is_newer_major() {
    local major="${1%%.*}"
    case "$major" in '' | *[!0-9]*) return 1 ;; esac
    [ "$major" -gt "$2" ]
}

# --- macOS System Updates ---
update_system() {
    print_header "Checking for macOS System Updates..." "🖥️"
    # softwareupdate prints "No new software available." to stderr, so capture both.
    local updates
    updates=$(softwareupdate --list 2>&1)
    echo "$updates" # Print the output of the command for the user to see

    if echo "$updates" | grep -q "No new software available"; then
        echo "🟢 Your system is up to date."
        return 0
    fi
    # Every available update has a "Label:" line. Without one, the check itself
    # failed (e.g. no network), so there is nothing to install.
    if ! echo "$updates" | grep -q "Label:"; then
        print_warning "Could not check for macOS updates."
        return 1
    fi

    # Install everything except a new major macOS version (e.g. 27 -> 28): a
    # new major version can break developer tools for weeks, so you start that
    # upgrade yourself when you are ready.
    local current_major labels=() restart=false label title version action
    current_major=$(sw_vers -productVersion | cut -d. -f1)
    while IFS='|' read -r label title version action; do
        [ -n "$label" ] || continue
        case "$title" in
            macOS*)
                if is_newer_major "$version" "$current_major"; then
                    echo "ℹ️  $title is available. Upgrade from System Settings when you are ready."
                    continue
                fi
                ;;
        esac
        labels+=("$label")
        [ "$action" = restart ] && restart=true
    done <<< "$(echo "$updates" | awk "$AWK_UPDATES")"

    if [ ${#labels[@]} -eq 0 ]; then
        echo "🟢 Your macOS version is up to date."
        return 0
    fi
    if $CHECK_ONLY; then
        mark_pending
        return 0
    fi
    echo "⬆️ Found system updates. This may require your password to proceed."
    sudo softwareupdate --install "${labels[@]}" --verbose || return 1
    # Updates marked "Action: restart" finish installing only after a restart.
    if $restart; then
        RESTART_NEEDED=true
    fi
}

# --- Weekly Check ---
# Installs a launchd job that runs 'fullupdate --check --notify' every Monday
# at 10:00 (or at the next wake, if the Mac was asleep then).
install_weekly_check() {
    local script
    script="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    mkdir -p "$(dirname "$WEEKLY_CHECK_PLIST")" "$(dirname "$WEEKLY_CHECK_LOG")" || return 1
    # launchd starts jobs with a minimal PATH, without brew, mas, npm or uv,
    # so the job gets the PATH you have now.
    cat > "$WEEKLY_CHECK_PLIST" <<EOF || return 1
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$WEEKLY_CHECK_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$script</string>
        <string>--check</string>
        <string>--notify</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$PATH</string>
    </dict>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Weekday</key>
        <integer>1</integer>
        <key>Hour</key>
        <integer>10</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>$WEEKLY_CHECK_LOG</string>
    <key>StandardErrorPath</key>
    <string>$WEEKLY_CHECK_LOG</string>
</dict>
</plist>
EOF
    # Unload an earlier version of the job first, so it picks up this one.
    launchctl bootout "gui/$(id -u)/$WEEKLY_CHECK_LABEL" 2> /dev/null
    launchctl bootstrap "gui/$(id -u)" "$WEEKLY_CHECK_PLIST" || return 1
    echo "✅ Weekly check installed: every Monday at 10:00. Its output goes to $WEEKLY_CHECK_LOG"
}

uninstall_weekly_check() {
    launchctl bootout "gui/$(id -u)/$WEEKLY_CHECK_LABEL" 2> /dev/null
    rm -f "$WEEKLY_CHECK_PLIST"
    echo "✅ Weekly check removed."
}

# Runs one step unless --only or --skip leave it out, and records the result
# for the summary.
run_step() {
    # $1 = step name (as used by --only and --skip), $2 = function that runs the step
    local name="$1" step_function="$2" start=$SECONDS result
    if { [ -n "$ONLY_STEPS" ] && ! in_list "$name" "$ONLY_STEPS"; } || in_list "$name" "$SKIP_STEPS"; then
        SUMMARY+=("$(printf '%-7s ⏭️  skipped' "$name")")
        return
    fi

    CURRENT_STEP="$name"
    "$step_function"
    case $? in
        0)
            if ! $CHECK_ONLY; then
                result="${COLOR_GREEN}✅ done${COLOR_NC}"
            elif in_list "$name" "$PENDING_STEPS"; then
                result="${COLOR_YELLOW}⬆️  updates available${COLOR_NC}"
            else
                result="${COLOR_GREEN}✅ up to date${COLOR_NC}"
            fi
            ;;
        "$STEP_SKIPPED") result="⏭️  not installed" ;;
        *)
            result="${COLOR_RED}❌ failed${COLOR_NC}"
            FAILED_STEPS="$FAILED_STEPS $name"
            ;;
    esac
    SUMMARY+=("$(printf '%-7s %b (%ds)' "$name" "$result" $((SECONDS - start)))")
}

parse_args() {
    local step
    while [ $# -gt 0 ]; do
        case "$1" in
            --check) CHECK_ONLY=true ;;
            --notify) NOTIFY=true ;;
            --only | --skip)
                # Accept a comma-separated list: --skip omz,system
                if [ -z "${2:-}" ]; then
                    echo "Missing step names after $1" >&2
                    usage >&2
                    exit 2
                fi
                for step in ${2//,/ }; do
                    case "$step" in
                        brew | mas | omz | dev | system) ;;
                        *)
                            echo "Unknown step for $1: '$step'" >&2
                            usage >&2
                            exit 2
                            ;;
                    esac
                done
                if [ "$1" = --only ]; then
                    ONLY_STEPS="$ONLY_STEPS ${2//,/ }"
                else
                    SKIP_STEPS="$SKIP_STEPS ${2//,/ }"
                fi
                shift
                ;;
            --install-weekly-check)
                install_weekly_check
                exit $?
                ;;
            --uninstall-weekly-check)
                uninstall_weekly_check
                exit $?
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                usage >&2
                exit 2
                ;;
        esac
        shift
    done
}

# --- Main Script Logic ---
main() {
    parse_args "$@"
    if $CHECK_ONLY; then
        echo -e "${COLOR_GREEN}🔎 Checking what is outdated. Nothing will be upgraded.${COLOR_NC}"
    else
        echo -e "${COLOR_GREEN}🚀 Starting the full macOS update process...${COLOR_NC}"
        # Keep the Mac awake until this script exits.
        caffeinate -i -w $$ &
    fi

    # Steps that never need your password run first. The ones that may need
    # it run back to back at the end, so sudo's cached password (5 minutes)
    # usually covers all of them after one prompt.
    run_step dev update_dev_tools
    run_step omz update_ohmyzsh
    run_step brew update_homebrew
    run_step mas update_mas
    run_step system update_system

    print_header "Summary" "📋"
    local line
    for line in "${SUMMARY[@]}"; do
        echo -e "  $line"
    done
    if $RESTART_NEEDED; then
        print_warning "Restart your Mac to finish installing the macOS updates."
    fi
    if [ -n "$FAILED_STEPS" ]; then
        echo -e "${COLOR_RED}❌ Some steps failed. Scroll up to see why.${COLOR_NC}"
        if $NOTIFY; then notify "Some steps failed:$FAILED_STEPS"; fi
        exit 1
    fi
    if ! $CHECK_ONLY; then
        print_header "All updates are complete!" "🎉"
        if $NOTIFY; then notify "All updates are complete."; fi
    elif [ -n "$PENDING_STEPS" ]; then
        print_header "Updates are available. Run fullupdate to install them." "🔎"
        if $NOTIFY; then notify "Updates available:$PENDING_STEPS. Run fullupdate to install them."; fi
    else
        print_header "Everything is up to date." "🔎"
    fi
    echo -e "🐗 Have a boarsome day! 🐗"
}

# Run the main function to start the script
main "$@"
