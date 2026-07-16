#!/bin/bash

# fullupdate - A comprehensive macOS update script.
#
# This script updates:
# 1. Homebrew formulas and casks.
# 2. Mac App Store applications (via mas-cli).
# 3. Oh My Zsh (if installed).
# 4. macOS system software.

# Best Practice: Exit immediately if a command exits with a non-zero status.
set -e

# --- Homebrew non-interactive behaviour ---
# Auto-confirm upgrades so we never get stuck on the "Do you want to proceed? [y/n]" prompt.
export HOMEBREW_NO_ASK=1
# Skip casks that update themselves (e.g. Rectangle). This avoids the
# "It seems there is already an App at ..." conflict on those upgrades.
export HOMEBREW_NO_UPGRADE_AUTO_UPDATES_CASKS=1
# Silence the extra environment hints Homebrew prints during upgrades.
export HOMEBREW_NO_ENV_HINTS=1

# Define some colors for output to make it more readable
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_BLUE='\033[0;34m'
COLOR_NC='\033[0m' # No Color

# Helper function for printing styled headers for each section, now with emoji support
print_header() {
    # $1 = message, $2 = emoji (optional)
    local emoji="${2:-}"
    echo -e "\n${COLOR_BLUE}==> ${emoji} $1${COLOR_NC}"
}

# --- Homebrew Updates ---
update_homebrew() {
    print_header "Updating Homebrew..." "🍺"
    # Check if the 'brew' command exists
    if ! command -v brew &> /dev/null; then
        echo -e "${COLOR_YELLOW}⚠️ Homebrew not found. Please install it from https://brew.sh/${COLOR_NC}"
        # Exit the function if brew isn't installed
        return
    fi
    echo "🔄 Updating formulas..."
    brew update
    echo "⬆️  Upgrading installed packages..."
    # Don't let a single stubborn package (e.g. a self-updating cask) abort the
    # whole script via 'set -e' — log it and keep going.
    brew upgrade || echo -e "${COLOR_YELLOW}⚠️  Some packages failed to upgrade. Continuing with the rest.${COLOR_NC}"
    echo "🧹 Cleaning up old versions and cache..."
    brew cleanup -s
    echo "🔍 Checking for potential issues..."
    brew doctor || true
    echo -e "${COLOR_GREEN}✅ Homebrew update complete.${COLOR_NC}"
}

# --- Mac App Store Updates ---
update_mas() {
    print_header "Updating Mac App Store Apps..." "🛍️"
    # Check if the 'mas' command-line interface is installed
    if ! command -v mas &> /dev/null; then
        echo -e "${COLOR_YELLOW}⚠️ 'mas-cli' not found. Attempting to install with Homebrew...${COLOR_NC}"
        # If brew is available, install mas automatically
        if command -v brew &> /dev/null; then
            brew install mas
        else
            echo -e "${COLOR_YELLOW}⚠️ Homebrew is required to install 'mas-cli'. Skipping App Store updates.${COLOR_NC}"
            return
        fi
    fi
    echo "🔄 Checking for App Store updates..."
    # Check if there are any outdated apps before running the upgrade command
    if mas outdated | grep -q '.'; then
        echo "⬆️ Upgrading apps..."
        mas upgrade
    else
        echo "🟢 All App Store apps are up to date."
    fi
    echo -e "${COLOR_GREEN}✅ Mac App Store update complete.${COLOR_NC}"
}

# --- macOS System Updates ---
update_system() {
    print_header "Checking for macOS System Updates..." "🖥️"
    # Capture both stdout and stderr
    system_updates=$(softwareupdate -l 2>&1)
    
    echo "$system_updates" # Print the output of the command for the user to see
    
    # Check if the output contains the "No new software available." phrase.
    if echo "$system_updates" | grep -q "No new software available."; then
        echo "🟢 Your system is up to date."
    else
        echo "⬆️ Found system updates. This may require your password to proceed."
        sudo softwareupdate -ia --verbose
    fi
    echo -e "${COLOR_GREEN}✅ macOS System Update check complete.${COLOR_NC}"
}

# --- Oh My Zsh Update (Optional Bonus) ---
update_ohmyzsh() {
    # Check if the Oh My Zsh directory exists
    if [ -d "$HOME/.oh-my-zsh" ]; then
        print_header "Updating Oh My Zsh..." "🦄"
        # Oh My Zsh provides its own upgrade script. We just need to call it.
        # This command is aliased to `omz update` if you run it manually.
        zsh "$HOME/.oh-my-zsh/tools/upgrade.sh"
        echo -e "${COLOR_GREEN}✅ Oh My Zsh update complete.${COLOR_NC}"
    fi
}

# --- Main Script Logic ---
main() {
    echo -e "${COLOR_GREEN}🚀 Starting the full macOS update process...${COLOR_NC}"

    update_homebrew
    update_mas
    update_ohmyzsh
    update_system

    print_header "All updates are complete!" "🎉"
    echo -e "🐗 Have a boarsome day! 🐗"
}

# Run the main function to start the script
main
