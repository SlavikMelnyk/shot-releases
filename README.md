# CandleLab releases

The installers and archives of [CandleLab](https://github.com/SlavikMelnyk/shot), a local crypto strategy lab. This repository holds no source code.

**Install (one command, nothing to install first):**

macOS or Linux, in a terminal:

```sh
curl -fsSL https://github.com/SlavikMelnyk/shot-releases/releases/latest/download/install.sh | sh
```

Windows, in PowerShell:

```powershell
irm https://github.com/SlavikMelnyk/shot-releases/releases/latest/download/install.ps1 | iex
```

CandleLab opens in your browser at `127.0.0.1:3001/app`. Running the same command again updates it; your data and settings stay.

Releases are built automatically from the latest version and are **not signed**: the installer checks the SHA-256 checksum of the archive from `latest.json`.
