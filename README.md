# InterfaceX

A fast, beautiful CMD-based network interface configuration tool for Windows. Select interfaces, switch between DHCP and static IP, manage DNS, and save your configurations as reusable presets — all from the command line with a clean, color-coded interface.

![Windows 10/11](https://img.shields.io/badge/Windows-10%20%2F%2011-blue)
![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1%2B-blue)
![No dependencies](https://img.shields.io/badge/dependencies-none-green)

## Features

- **Interactive TUI** — color-coded menu with single-keypress navigation
- **DHCP / Static IP** — switch modes instantly, with pre-filled current values
- **Preset system** — save and load full network configs by name
- **CLI quick mode** — run commands directly without opening the TUI
- **Loading indicators** — spinner animation so you always know it's working
- **Locale-independent** — works regardless of Windows language settings
- **No external dependencies** — pure Batch + built-in PowerShell 5.1

## Requirements

- Windows 10 or Windows 11
- PowerShell 5.1 (included with Windows 10/11)
- Administrator privileges (prompted automatically)

## Installation

1. **Download or clone** this repository
2. **Run `install.bat`** — double-click it or run it from a terminal

```
install.bat
```

3. **Open a new terminal** — the `interfacex` command is now available globally

> The installer copies the files to `%LOCALAPPDATA%\InterfaceX\` and adds it to your user PATH. No system-level changes, no admin required for the install itself.

## Usage

### Interactive mode

Just type `interfacex` in any Command Prompt:

```
interfacex
```

You'll see a menu listing your network interfaces with their current status, IP, and mode. Use number keys to select an interface, then choose what to do:

```
+----------------------------------------------------------+
|                                                          |
|                  InterfaceX v1.0.0                       |
|         Network Interface Configuration Tool            |
|                                                          |
+----------------------------------------------------------+

  Interfaces:
  ------------------------------------------------------
  [1] Wi-Fi               172.27.1.12/24   DHCP    UP
  [2] Ethernet            --               --      DN

  [P] Presets    [A] Show all    [R] Refresh    [Q] Quit

  Select interface [1-2] or action >
```

From the interface detail screen you can:
- Switch to DHCP
- Set a static IP (IP, mask, gateway, DNS) — current values are pre-filled
- Save the current configuration as a named preset
- Load a previously saved preset

### CLI quick mode

Skip the TUI entirely for fast scripting or repeated tasks:

```bash
# List all interfaces
interfacex list

# Switch an interface to DHCP
interfacex dhcp "Wi-Fi"

# Set a static IP
interfacex static "Ethernet" 10.0.1.50 255.255.255.0 10.0.1.1 8.8.8.8 8.8.4.4

# Apply a saved preset
interfacex preset "Office" "Wi-Fi"

# List saved presets
interfacex presets

# Show help
interfacex --help
```

Subnet masks can be provided as dotted notation (`255.255.255.0`) or CIDR prefix (`/24` or `24`).

### Presets

Presets store a complete network configuration (DHCP or static IP, gateway, DNS) under a name. Save once, apply anywhere in seconds.

Presets are stored as a plain JSON file at `%LOCALAPPDATA%\InterfaceX\presets.json` and can be edited by hand if needed.

## Uninstallation

Run `uninstall.bat` from the original project folder, or from anywhere:

```
uninstall.bat
```

This removes all installed files and cleans the PATH entry. Your presets are deleted along with the installation directory.

## How it works

| File | Role |
|---|---|
| `interfacex.bat` | Entry point — checks for admin rights, auto-elevates if needed, launches the PowerShell core |
| `interfacex.ps1` | Main application — TUI rendering, network operations via `netsh`, preset management |
| `install.bat` | Copies files to `%LOCALAPPDATA%\InterfaceX\` and adds to user PATH |
| `uninstall.bat` | Removes installed files and cleans PATH |

Network discovery uses PowerShell cmdlets (`Get-NetAdapter`, `Get-NetIPAddress`, etc.) which return structured objects independent of the system locale. Configuration changes are applied via `netsh`, which works reliably across all Windows 10/11 versions.

## License

MIT
