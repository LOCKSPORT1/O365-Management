# OOBE Wi-Fi Kit

Get ethernet-less laptops onto Wi-Fi **during Windows OOBE** — for Autopilot
deployments, hash capture, or any provisioning flow that needs network before
first sign-in — from a USB stick, with one command.

## The scenario

You're deploying laptops with Windows Autopilot (or capturing hardware hashes
at OOBE). Autopilot needs internet the moment OOBE starts so it can pull the
deployment profile. Your usual answer is an ethernet cable — but modern
ultrabooks shipped without ethernet ports, you have five machines to provision,
and two USB-C adapters between them.

Every one of those machines has a Wi-Fi radio. This kit gets it connected at
the OOBE region-select screen in about ten seconds, no adapter required.

## Three ways to do it (pick the lightest that works)

### Tier 1 — the built-in OOBE network page (nothing needed)

On a device with no wired connection detected, OOBE inserts a
**"Let's connect you to a network"** page right after region/keyboard. Pick
the SSID, type the key, continue. If your flow reaches that page and a human
is sitting there anyway, you don't need this kit.

### Tier 2 — the network flyout on demand (one command, no files)

At any OOBE screen: press **Shift+F10** to open a command prompt, then:

```
start ms-availablenetworks:
```

The network flyout appears on top of OOBE — even on screens that don't
normally offer networking. Useful when you need network *earlier* than OOBE
offers it (e.g., before running a hash-capture script).

### Tier 3 — this kit: fully scripted (zero typing of passphrases)

For batches, long passphrases, or techs who shouldn't know the Wi-Fi key by
heart. Stage the profile once, then every deployment is:

```
Shift+F10  →  D:  →  Connect-WiFi.cmd
```

## Kit contents

| File | Runs where | Purpose |
|---|---|---|
| `Export-WiFiProfile.ps1` | Any machine already on the target Wi-Fi (once, elevated) | Exports the Wi-Fi profile **with the key in clear** onto the USB stick |
| `Connect-WiFi.cmd` | The new device, at OOBE via Shift+F10 | Launcher — auto-detects its own drive letter, hands off to the worker |
| `Connect-WiFi.ps1` | (called by the .cmd) | Imports every staged profile, connects, verifies, reports |

## Setup (once per network)

1. Insert the USB kit into any machine already connected to the target Wi-Fi.
2. Run elevated:
   ```powershell
   .\Export-WiFiProfile.ps1 -SsidName 'YOUR-SSID' -KitPath 'E:\'
   ```
   (Run with no parameters to get a list of local profiles and prompts.)
3. Done. The profile XML now lives beside `Connect-WiFi.cmd` on the stick.

Multiple networks? Export each — the connector imports all of them and
connects to the first that associates.

## Use (every deployment)

1. Boot the new device to OOBE (region/keyboard screen is fine).
2. Insert the USB kit.
3. **Shift+F10** to open the command prompt.
4. Switch to the stick and run the connector:
   ```
   D:
   Connect-WiFi.cmd
   ```
   Not sure of the drive letter? `wmic logicaldisk get name,volumename`
5. Wait for **CONNECTED**, close the prompt, continue OOBE. Autopilot pulls
   its profile over the Wi-Fi link like it never noticed the missing port.

## Security note — read this one

`key=clear` is **required**: netsh encrypts exported keys per-machine, so an
encrypted export only re-imports on the machine that created it. The
consequence: **the XML on this stick contains your Wi-Fi passphrase in plain
text.**

Treat the kit like a written-down password:

- Technician possession only — never a shared drive, never a repo
- Add the profile XML pattern to `.gitignore` if you publish your kit scripts
- If the stick is lost, rotate the PSK
- Consider a dedicated provisioning SSID/VLAN so the exposed key isn't your
  primary network's

(This repository ships **no** profile XML — you generate your own.)

## Caveats that will save you a bad afternoon

**Hybrid Azure AD join needs more than internet.** If your Autopilot profile
is hybrid-join, the device must reach a **domain controller** to complete the
join and for first user logon. Connect it to the corporate Wi-Fi (or one with
routing/VPN to the DCs) — a guest network or phone hotspot will enroll the
device in Intune and then stall at the domain-join step. Entra-join-only
profiles don't care; any internet works.

**WPA2/WPA3-PSK assumed.** 802.1X/EAP (RADIUS, certificate, or
username-based) networks are painful at OOBE — there's no user or machine
identity yet to authenticate with. For enterprise-auth-only environments,
options are: a PSK provisioning SSID, certificate pre-staging (advanced), or
falling back to those USB-C ethernet adapters after all.

**Radio switches.** If `Connect-WiFi` reports no wireless interface, check
the physical airplane-mode/radio toggle some laptops have, and that the OEM
image includes the Wi-Fi driver (rare miss, but it happens on very new
silicon with old install media).

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `No wireless interface found` | Radio off, airplane mode, or missing driver | Toggle the radio key; check Device Manager via `devmgmt.msc` from the same Shift+F10 prompt |
| Imports fine, never associates | Out of range / wrong band / stale PSK | Move closer; confirm the passphrase is current; try Tier 2 flyout to see what the radio sees |
| Connected but Autopilot profile never downloads | Captive portal or filtered network | Open `start ms-availablenetworks:` and check for a sign-in banner; use a network without a portal |
| Connected, enrolls, but domain join stalls | Wi-Fi has no route to a domain controller (hybrid join) | Use corporate Wi-Fi with DC line-of-sight — see caveats |
| `Connect-WiFi.cmd` not found at `D:` | Different drive letter | `wmic logicaldisk get name,volumename` and use the right letter |

## License

MIT. Adapt freely; attribution appreciated.
