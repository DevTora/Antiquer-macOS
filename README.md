# Antiquer-macOS

[English](README.md) | [中文](README-zh-CN.md)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow?style=flat)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-lightgrey?style=flat)](https://www.apple.com/macos)

macOS file/folder timestamp viewer and modifier. When organizing old files, timestamps are often inconsistent. macOS `touch` only handles modification and access times; changing birth time requires Xcode's `SetFile` with a 12-hour AM/PM format. This script wraps all three into one command.

## 🚀 Quick Start

```bash
Antiquer.sh ~/Downloads 2000-01-01
```

Set birth & modification time of everything under `~/Downloads` to `2000-01-01`.

## 📦 Install

```bash
git clone https://github.com/DevTora/Antiquer-macOS.git
cd Antiquer-macOS
chmod +x Antiquer.sh Antiquer-zh-CN.sh
xcode-select --install
```

Update with `git pull`.

## ⌨️ Usage

```
Antiquer.sh                                       TUI mode
Antiquer.sh <path>                                View timestamps
Antiquer.sh <path> <date> [time]                  Modify timestamps (default)
Antiquer.sh <flags> <path> <date> [time]          Modify timestamps (flags)
```

### Flags

| Flag | Aliases | Description |
|------|---------|-------------|
| `-h` | `--help` | Show help (must be sole argument) |
| `-V` | `--version` | Show version (must be sole argument) |
| `-H` | `--hidden` | Include dotfiles |
| `-A` | `--all` | All three timestamps set to user value |
| `-b` | `--birth`, `-c`, `--create` | Birth time only |
| `-m` | `--modify` | Modification time only |
| `-a` | `--access` | Access time only |

### Ordering

```
-H  <  -A or -b/-m/-a  <  path  <  date  <  time
```

- `-H` must be the first flag
- `-A` cannot combine with `-b`/`-c`/`-m`/`-a`
- Flags before path; short options merge (`-bm` = `-b -m`)
- `-b` and `-c` are aliases (duplicates warn, no error)
- No flags: birth+mod → user value, access → `1980-01-01`

### Behavior

| Mode | Condition | Birth | Modify | Access |
|------|-----------|:-----:|:------:|:------:|
| **Default** | path + date | user value | user value | `1980-01-01` |
| **`-A`** | `-A` | user value | user value | user value |
| **`-b`** | `-b` | user value | — | — |
| **`-m`** | `-m` | — | user value | — |
| **`-a`** | `-a` | — | — | user value |
| **`-b -m -a`** | `-b -m -a` | user value | user value | user value |

> **Folders**: always reset all three to `1980-01-01`, regardless of flags.

### Examples

```bash
Antiquer.sh /path/to/file
Antiquer.sh /path/to/file 2017-03-03
Antiquer.sh -b -m -a /path/to/file 2017-03-03 12:00:00
Antiquer.sh -bma /path/to/file 2017-03-03
Antiquer.sh -H -A /path/to/file 2017-03-03 12:00:00
Antiquer.sh -H /path/to/file
Antiquer.sh --hidden --all /path/to/file 2017-03-03
Antiquer.sh --hidden --create -ma /path/to/file 2017-03-03
```

## 💻 TUI

Run without arguments.

```
[1] View → scan → tree → stats → optional fix
[2] Modify → set time → preview → confirm → execute → result
```

## 📋 Requirements

- bash 3.2+
- Filesystem: HFS+, APFS, exFAT
- macOS 10.9+ (`xcode-select --install`); 10.7.3+ with manual CLI tools
- Xcode Command Line Tools (`xcode-select --install`)

## ❓ FAQ

**2038 date limit?** SetFile uses 32-bit timestamps, only supporting dates from `1970-01-01` to `2038-01-18`. This affects birth time only; modification and access times (via `touch`) have no such limit.

**No confirmation prompt?** CLI mode (with args) skips prompts. TUI mode (no args) always prompts.

**SetFile deprecated?** SetFile was deprecated in Xcode 6 (2014) but remains available in current Xcode Command Line Tools.

**SetFile not found?** Run `xcode-select --install`.

**What does `-H` do?** By default `.` files are skipped. `-H` includes them.

**Which filesystems?** HFS+, APFS, exFAT (all confirmed working).

**Why are folders forced to 1980?** Finder sorts folders by creation time. A uniform reset prevents mixed ordering.

## 📜 License

MIT License — see [LICENSE](LICENSE).
