# Antiquer-macOS

[English](README.md) | [中文](README-zh-CN.md)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow?style=flat)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-lightgrey?style=flat)](https://www.apple.com/macos)

macOS 文件/文件夹时间戳查看与修改工具。整理旧文件时，时间戳常常混乱不一致。macOS 自带的 `touch` 只能改修改和访问时间，修改创建时间需要 Xcode 的 `SetFile`，还要用 12 小时 AM/PM 格式。这个脚本把三种时间戳的统一修改封装成一个命令。

## 🚀 快速开始

```bash
Antiquer.sh ~/Downloads 2000-01-01
```

将 `~/Downloads` 下所有文件的创建/修改时间设为 `2000-01-01`。

## 📦 安装

```bash
git clone https://github.com/DevTora/Antiquer-macOS.git
cd Antiquer-macOS
chmod +x Antiquer.sh Antiquer-zh-CN.sh
xcode-select --install
```

使用 `git pull` 更新。

## ⌨️ 用法

```
Antiquer.sh                                       TUI 模式
Antiquer.sh <路径>                                 查看时间戳
Antiquer.sh <路径> <日期> [时间]                     修改时间戳（默认模式）
Antiquer.sh <选项> <路径> <日期> [时间]               修改时间戳（选项模式）
```

### 选项

| 旗标 | 别名 | 说明 |
|------|------|------|
| `-h` | `--help` | 显示帮助（必须是唯一参数） |
| `-V` | `--version` | 显示版本号（必须是唯一参数） |
| `-H` | `--hidden` | 包含隐藏文件（`.` 开头） |
| `-A` | `--all` | 所有三个时间戳全改为用户指定值 |
| `-b` | `--birth`, `-c`, `--create` | 仅修改创建时间 |
| `-m` | `--modify` | 仅修改修改时间 |
| `-a` | `--access` | 仅修改访问时间 |

### 排序规则

```
-H  <  -A or -b/-m/-a  <  路径  <  日期  <  时间
```

- `-H` 必须是第一个选项
- `-A` 不能与 `-b`/`-c`/`-m`/`-a` 同时使用
- 选项在路径之前；短选项可合并（`-bm` = `-b -m`）
- `-b` 和 `-c` 是别名（重复仅警告，不报错）
- 无选项：创建+修改→用户值，访问→`1980-01-01`

### 行为对照

| 模式 | 条件 | 创建时间 | 修改时间 | 访问时间 |
|------|------|:--------:|:--------:|:--------:|
| **默认** | 路径 + 日期 | 用户值 | 用户值 | `1980-01-01` |
| **`-A`** | `-A` | 用户值 | 用户值 | 用户值 |
| **`-b`** | `-b` | 用户值 | — | — |
| **`-m`** | `-m` | — | 用户值 | — |
| **`-a`** | `-a` | — | — | 用户值 |
| **`-b -m -a`** | `-b -m -a` | 用户值 | 用户值 | 用户值 |

> **文件夹**：无论使用什么选项，始终将三个时间戳全部重置为 `1980-01-01`。

### 示例

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

不带参数运行。

```
[1] 查看 → 扫描 → 树状视图 → 统计 → 可选修复
[2] 修改 → 设置时间 → 预览 → 确认 → 执行 → 结果
```

## 📋 环境要求

- bash 3.2+
- 文件系统：HFS+、APFS、exFAT
- macOS 10.9+（`xcode-select --install`）；10.7.3+（手动安装命令行工具）
- Xcode 命令行工具（`xcode-select --install`）

## ❓ 常见问题

**2038 年日期限制？** SetFile 使用 32 位时间戳，仅支持 `1970-01-01` 至 `2038-01-18` 范围。此限制只影响创建时间，修改时间和访问时间（通过 `touch`）无此限制。

**SetFile 找不到？** 运行 `xcode-select --install`。

**SetFile 已废弃？** SetFile 自 Xcode 6 (2014) 起被标记为废弃，但仍包含在当前的 Xcode 命令行工具中。

**`-H` 有什么作用？** 默认跳过 `.` 开头文件，`-H` 包含它们。

**支持哪些文件系统？** HFS+、APFS、exFAT（均实测可用）。

**没有确认提示？** CLI 模式（带参数）跳过确认。TUI 模式（不带参数）始终提示。

**为什么文件夹强制为 1980？** Finder 按创建时间排序，统一重置避免混乱。

## 📜 许可证

MIT 许可证 — 详见 [LICENSE](LICENSE) 文件。
