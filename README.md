# macOS System Update Script

A comprehensive Bash script to automate updates for your macOS system, Homebrew packages, Mac App Store apps, and Oh My Zsh configuration.

## Features

- Updates Homebrew formulas and casks
- Upgrades Mac App Store applications (using `mas-cli`)
- Installs macOS system software updates
- Uupdates Oh My Zsh (if installed)
- Safe: exits on errors, checks for required tools

## Prerequisites

- macOS (tested on recent versions)
- Bash shell
- Homebrew
- `mas-cli` (Mac App Store CLI, auto-installed if missing)
- Oh My Zsh (optional, for Zsh config updates)
- Administrator privileges (for system updates)

## Setup

To run the script from anywhere in your terminal using the `fullupdate` command:

Download or clone this repository:

  ```zsh
  git clone https://github.com/patrykwiener/macOS-system-update.git
  cd macOS-system-update
  ```
Add an alias to your `.zshrc`:

  ```zsh
  echo "alias fullupdate='$(pwd)/fullupdate.sh'" >> ~/.zshrc
  source ~/.zshrc
  ```

Now you can run `fullupdate` from any location in your terminal:

  ```zsh
  fullupdate
  ```

You might be prompted for your password to allow system updates.

## What Gets Updated?

- **Homebrew:** Updates and upgrades all installed packages and casks, cleans up old versions, and runs diagnostics.
- **Mac App Store:** Upgrades all outdated apps using `mas-cli`.
- **macOS System:** Installs all available system software updates.
- **Oh My Zsh:** Updates your Zsh configuration if Oh My Zsh is installed.

## Troubleshooting

- If Homebrew or `mas-cli` is missing, the script will prompt you to install them.
- For system updates, administrator privileges are required.
- The script exits on errors to prevent partial updates.

### Common Issues

- **Permission Denied:**
  - Make sure the script is executable: `chmod +x fullupdate.sh`
  - Run with sufficient privileges for system updates (use `sudo` if needed).
- **Command Not Found:**
  - Ensure Homebrew and `mas` are installed and in your PATH.

## Contributing

Contributions are welcome! Please open issues!

## FAQ

**Q: Can I run this script on Linux or Windows?**
A: No, this script is designed for macOS only.

**Q: Will this update all my apps?**
A: It updates Homebrew packages, Mac App Store apps, zsh configurations, and macOS system software. Other apps may require manual updates.

**Q: Is it safe to run?**
A: The script exits on errors and checks for required tools, but always review scripts before running.

## License

See [LICENSE](LICENSE) for details.
