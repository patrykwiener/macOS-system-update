# macOS System Update Script

[![Tests](https://github.com/patrykwiener/macOS-system-update/actions/workflows/test.yml/badge.svg)](https://github.com/patrykwiener/macOS-system-update/actions/workflows/test.yml)

A Bash script that updates your Mac with one command: Homebrew packages and apps, Mac App Store apps, Oh My Zsh with its plugins, global npm packages and uv tools, and macOS itself.

## Features

- Upgrades Homebrew formulae and casks, **including apps that have their own updater** (Outlook, Teams, Rectangle, browsers, …). Homebrew skips those by default, so an app whose updater breaks can silently fall months behind.
- Leaves alone apps that already updated themselves, so they are not quit and downloaded again for nothing
- Upgrades Mac App Store apps (using `mas`)
- Updates Oh My Zsh and the plugins and themes you cloned into its `custom` folder
- Upgrades global npm packages, uv tools and uv-managed Python versions
- Installs macOS updates, but never a new major macOS version: it only tells you one is available
- Keeps going when one step fails, then shows a summary of every step
- `--check` shows what is outdated without upgrading anything
- Optional weekly check that notifies you when something is outdated

## Prerequisites

- macOS (tested on macOS 27 with Homebrew 7 and mas 7)
- [Homebrew](https://brew.sh/)
- `mas` (installed automatically with Homebrew if missing)
- Optional: Oh My Zsh, npm, uv (each step runs only if its tool is installed)
- An administrator password (for App Store apps, some Homebrew apps and macOS updates)

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

Do not run it with `sudo`: Homebrew refuses to run as root. The script asks for your password itself when a step needs it, usually once per run (see [Password prompts](#password-prompts)).

## Usage

```zsh
fullupdate                        # update everything
fullupdate --check                # only show what is outdated
fullupdate --only brew,mas        # run only these steps
fullupdate --skip system          # run everything except macOS updates
fullupdate --notify               # also show a macOS notification at the end
```

Steps, in the order they run: `dev`, `omz`, `brew`, `mas`, `system`.

To keep `fullupdate` away from some apps, list their cask names in `~/.zshrc`:

```zsh
export FULLUPDATE_SKIP_CASKS="docker-desktop"
```

### Weekly check

```zsh
fullupdate --install-weekly-check     # every Monday at 10:00
fullupdate --uninstall-weekly-check
```

The weekly check is a launchd job (macOS's scheduler) that runs `fullupdate --check --notify`: it upgrades nothing and shows a notification only when something is outdated. If the Mac is asleep at 10:00, the check runs when it wakes. The job uses the `PATH` you had when you installed it, so run `--install-weekly-check` again after you change your `PATH`. Its output goes to `~/Library/Logs/fullupdate-check.log`.

## What Gets Updated?

The steps run in this order:

| Step | What it does |
|---|---|
| `dev` | `npm update --global` for outdated global packages (except npm itself and packages added with `npm link`), `uv tool upgrade --all` and `uv python upgrade`. |
| `omz` | Runs Oh My Zsh's own upgrade script, then `git pull --ff-only` in every git repository under `custom/plugins` and `custom/themes`. |
| `brew` | `brew update` and `brew upgrade --formula`. Then one `brew upgrade --cask` call for every outdated cask from `brew outdated --cask --greedy-auto-updates`, except apps that already report the latest version (read from the app, or from its installer receipt for apps installed from a `.pkg`). A cask that fails, for example with "It seems there is already an App at …", is retried once with `--force`. Finally `brew cleanup -s` and `brew doctor`. |
| `mas` | Upgrades the App Store apps that `mas outdated` reports. |
| `system` | Installs the updates `softwareupdate --list` reports, except a new major macOS version (for example 27 → 28): a major upgrade can break developer tools for weeks, so the script only tells you it is available and you start it from System Settings. If an update needs a restart, the summary tells you; the script never restarts your Mac. |

Homebrew quits a running app before upgrading it and reopens it afterwards.

### Password prompts

Three steps may need your administrator password: `brew` (for apps installed from a `.pkg`, such as Outlook and Teams), `mas` and `system`. They run back to back at the end, so after you type the password once, sudo remembers it for 5 minutes and the later steps reuse it. Homebrew makes sudo forget the password each time a `brew` command first needs it, which is why the script upgrades all apps in a single `brew` call.

To confirm with Touch ID instead of typing the password, enable it for `sudo` once:

```zsh
sed 's/^#auth/auth/' /etc/pam.d/sudo_local.template | sudo tee /etc/pam.d/sudo_local
```

**Allow your terminal app (Terminal, iTerm, …) in System Settings → Privacy & Security → App Management.** Without that permission Homebrew upgrades an app by deleting and reinstalling it, and macOS then forgets the app's Dock position and the permissions you granted it, such as Accessibility for Rectangle ([Homebrew FAQ](https://docs.brew.sh/FAQ#why-do-my-cask-apps-lose-their-dock-position--launchpad-position--permission-settings-when-i-run-brew-upgrade)).

## Troubleshooting

- **A step shows ❌ in the summary:** scroll up to that step's output. The other steps still ran.
- **An app keeps failing with "It seems there is already an App at …":** check the App Management permission above, then run `fullupdate` again.
- **Permission denied:** make sure the script is executable: `chmod +x fullupdate.sh`.
- **Command not found:** make sure Homebrew is installed and in your `PATH`.

## Testing

```zsh
bash tests/run_tests.sh
```

The tests replace `brew`, `mas`, `softwareupdate`, `sudo` and the other tools with a stub that only records how it was called, so nothing on your Mac changes. GitHub Actions runs them, plus a syntax check with macOS's bash 3.2 and [ShellCheck](https://www.shellcheck.net/), on every push.

## Contributing

Contributions are welcome! Please open issues!

## FAQ

**Q: Can I run this script on Linux or Windows?**
A: No, this script is designed for macOS only.

**Q: Will this update all my apps?**
A: It updates apps installed with Homebrew or the App Store. Apps you installed by hand (downloaded from a website) are not updated; they rely on their own updaters.

**Q: Is it safe to run?**
A: It only runs each tool's standard update commands, and `--check` shows what would change first. As with any script, review it before running.

## License

See [LICENSE](LICENSE) for details.
