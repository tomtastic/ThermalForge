# ThermalForge

Fan control for Apple Silicon Macs (M1-M5), with a native menu bar app and CLI.

## What it does
- Reads live thermal sensors and fan state.
- Applies fan profiles (Silent, Balanced, Performance, Max, Smart).
- Provides a user rule in app settings:
  - IF temp >= trigger, THEN set fan to fixed %
  - ELSE when temp <= release, return to Apple auto
- Runs a privileged local daemon so the app can control fans without repeated sudo prompts.
- Includes safety override at high temperature.

## Security model
- Daemon socket path: `/var/run/thermalforge.sock`
- Socket permissions: `0600`
- Client authorization: root + active console user only (peer UID check)

## Requirements
- macOS 14+
- Apple Silicon

## Install

### Homebrew
```bash
brew install ProducerGuy/tap/thermalforge
sudo thermalforge install
```

### From source
```bash
git clone https://github.com/d37atm/ThermalForge.git
cd ThermalForge
./setup.sh
```

### Open app
```bash
open /Applications/ThermalForge.app
```

## CLI quickstart
```bash
thermalforge status
thermalforge max
thermalforge auto
thermalforge set 4000
thermalforge watch --profile balanced
thermalforge log --rate 1 --duration 10m
```

## Common operations

### Install or update daemon
```bash
sudo thermalforge install
```

### Reset fans to Apple defaults
```bash
thermalforge auto
```

### Full uninstall
```bash
sudo thermalforge uninstall
```

## Release artifacts
GitHub Releases include:
- `ThermalForge-<version>-macos-arm64-app.zip`
- `ThermalForge-<version>-macos-arm64-cli.tar.gz`
- `checksums.txt`

Use Releases page:
`https://github.com/d37atm/ThermalForge/releases`

## Compatibility
Tested on Apple Silicon Macs. If a model behaves differently, open an issue with:
```bash
thermalforge discover --output discover.txt
```

## Disclaimer
Fan control modifies hardware behavior. Use at your own risk.

## License
MIT
