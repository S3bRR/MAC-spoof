# MAC-spoof

`MAC-spoof` is a lightweight zsh command-line tool for changing a network interface MAC address on macOS and Linux.

The project is intentionally small and transparent:

- one shell script
- no GUI
- no compiled binaries
- no telemetry
- no network calls
- no third-party packages
- no backend fallbacks

## Requirements

macOS:

- zsh
- `ifconfig`
- `networksetup`

Linux:

- zsh
- `ip`

Network-changing commands require root privileges, so run them with `sudo`.

## Quick Start

```bash
chmod +x ./macspoof.sh

./macspoof.sh list
./macspoof.sh status en0
./macspoof.sh generate

./macspoof.sh save-original en0
sudo ./macspoof.sh random en0
sudo ./macspoof.sh restore en0
```

Replace `en0` with the interface you want to test. Use `./macspoof.sh list` to see available interfaces.

## Commands

```text
./macspoof.sh list
./macspoof.sh list-raw
./macspoof.sh status <interface>
./macspoof.sh current <interface>
./macspoof.sh generate
./macspoof.sh save-original <interface>
sudo ./macspoof.sh set <interface> <mac>
sudo ./macspoof.sh random <interface>
sudo ./macspoof.sh rotate <interface> <minutes> [count]
sudo ./macspoof.sh restore <interface>
./macspoof.sh forget <interface>
```

`rotate` changes the MAC address repeatedly until stopped, or until the optional count is reached:

```bash
sudo ./macspoof.sh rotate en0 30
sudo ./macspoof.sh rotate en0 30 4
```

## How It Works

`macspoof.sh` uses the primary OS network tools directly.

On macOS:

- compact listing: `networksetup -listallhardwareports` plus `ifconfig`
- raw listing: `ifconfig -a`
- current MAC/IP/status: `ifconfig <interface>`
- MAC change: `ifconfig <interface> ether <mac>`

On Linux:

- listing, current MAC/IP/status, and MAC change: `ip`

The script does not silently fall back to alternate backends. If the primary method is unavailable or rejected by the adapter, the command fails.

For every MAC change, the script:

1. validates the interface name
2. validates or generates a unicast MAC address
3. saves the original MAC if none is saved yet
4. changes the MAC with the OS primary command
5. reads the live MAC again
6. reports success only if the live MAC matches the requested MAC

## Restore State

Restore state is local to your machine and is not written into this repository.

Default location:

```text
~/.macspoof/originals.tsv
```

Use a temporary state directory when experimenting:

```bash
tmpdir=$(mktemp -d)
MACSPOOF_STATE_DIR="$tmpdir" ./macspoof.sh save-original en0
MACSPOOF_STATE_DIR="$tmpdir" sudo -E ./macspoof.sh random en0
MACSPOOF_STATE_DIR="$tmpdir" sudo -E ./macspoof.sh restore en0
rm -rf "$tmpdir"
```

## Boot Automation

Automation is opt-in. The example service files are templates that you should edit before installing.

macOS launchd examples:

```text
examples/launchd/org.macspoof.random-on-boot.plist
examples/launchd/org.macspoof.rotate.plist
```

Linux systemd examples:

```text
examples/systemd/macspoof-random-on-boot.service
examples/systemd/macspoof-rotate.service
```

Each template contains placeholder paths and interface names. Read the file first, then replace the placeholders for your machine.

This project does not install persistent services automatically.

## Manual Verification

```bash
zsh -n ./macspoof.sh
./macspoof.sh list
./macspoof.sh generate
```

Do not test first on an active Wi-Fi or Ethernet connection unless you are okay with being disconnected.

## Notes

MAC changes are usually temporary. They can reset after reboot, adapter restart, Wi-Fi reconnect, or driver policy changes. Some adapters and OS versions reject MAC changes.

Use only on devices and networks you own or have permission to test. Do not use MAC spoofing to bypass authentication, bans, access controls, or network policy.

You are responsible for how you use this software. The authors and contributors are not responsible for network disruption, policy violations, damages, or misuse.
