# ClaudeBrowserTray

_Built by [VARO Industries](https://varo.industries/apps#github)_

A Windows system tray tool that tells you which Chrome profile is which when Claude asks you to pick a browser.

If you run the Claude in Chrome extension in more than one browser profile, Claude lists the connected browsers as "Browser 1", "Browser 2", and so on. Those numbers follow connection order, so they change between sessions and say nothing about which profile is behind each one. What does not change is each profile's **device ID**. ClaudeBrowserTray shows every profile that has the extension, with its ID, and copies a ready-to-paste line so you can tell Claude exactly which browser to use.

![Platform Windows](https://img.shields.io/badge/Platform-Windows-lightgrey)
![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1-blue)
![License MIT](https://img.shields.io/badge/License-MIT-green)

> Unofficial. Not affiliated with or endorsed by Anthropic.

---

## What it shows

Click the tray icon to get one line per profile:

```
Work        |   Chrome: Work profile      |   1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed
Personal    |   Chrome: Person 1          |   6ec0bd7f-11c0-43da-975e-2a8ad9ebae0b
MACHINE     |   Edge: Profile 1           |   3f2504e0-4f89-41d3-9a0c-0305e82c3301
```

- **Claude name** - the display name set in the extension (falls back to the machine name)
- **Browser and profile** - the profile name as the browser shows it
- **Device ID** - the ID Claude uses to select that browser

Click a line and this is copied to the clipboard:

```
Use the Claude in Chrome browser with deviceId 1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed ("Work" - Chrome profile "Work profile")
```

Paste it into your Claude chat. **Copy full list** copies every line at once. Profiles that share an ID (it can happen when a profile is copied or imported between browsers) are flagged, because Claude cannot tell them apart.

## Install

No build step and no dependencies. It is a single PowerShell script.

```
git clone https://github.com/VAROIndustries/ClaudeBrowserTray.git
cd ClaudeBrowserTray
```

| Command | What it does |
|---|---|
| `powershell -ExecutionPolicy Bypass -File ClaudeBrowserTray.ps1` | Run the tray tool |
| `powershell -ExecutionPolicy Bypass -File ClaudeBrowserTray.ps1 -Dump` | Print the table to the console, no tray |
| `powershell -ExecutionPolicy Bypass -File ClaudeBrowserTray.ps1 -Install` | Start with Windows, and start now |
| `powershell -ExecutionPolicy Bypass -File ClaudeBrowserTray.ps1 -Uninstall` | Remove the startup shortcut |

`-Install` adds a shortcut to your Startup folder that points at wherever the script is, so put the script somewhere permanent first.

Tested on Windows 11 with Windows PowerShell 5.1.

## How it works

The Claude in Chrome extension keeps its device ID and display name in its own extension storage, which Chromium stores as a LevelDB database inside each browser profile:

```
<User Data>\<profile>\Local Extension Settings\fcoeoabgfenejglbffodgkkbkcdhcgfn
```

The script contains a small read-only LevelDB reader (table files, write-ahead log, Snappy decompression) and pulls three keys: `bridgeDeviceId`, `bridgeDisplayName`, and `bridgeDefaultDisplayName`. Profile names come from each browser's `Local State` file. It looks in Chrome, Chrome Beta, Edge, Brave, and Island; add more to `$Roots` at the top of the script.

## Privacy

- Read-only. It never writes to a browser profile.
- It reads only storage keys that start with `bridge`. Nothing else in the extension's storage is decoded.
- No network access. Nothing leaves your machine unless you paste it somewhere.

## Limitations

- It shows every profile that has the extension, not only the ones connected right now, and it cannot show the current "Browser N" number. That number exists only on Claude's side. Match on the ID instead.
- It only sees browsers on the computer it runs on.
- The storage keys are internal to the extension and undocumented. An extension update could rename them and break this tool.

## License

MIT
