# Autopilot Hash Capture Kit

Capture Windows Autopilot hardware hashes from a USB stick at OOBE — batch
CSV by default, direct-to-Intune upload optional. Pairs with the
[OOBE Wi-Fi Kit](../OOBE-WiFi-Kit) for laptops without ethernet ports.

## The scenario

New (or repurposed) devices need to be registered with Windows Autopilot
before the deployment profile will apply. If your OEM injects hashes at the
factory, you never think about this. Until that's set up — or for existing
stock, one-offs, and repurposed hardware — someone has to harvest the
hardware hash from each machine.

This kit makes that a 30-second stop at the OOBE region-select screen:
`Shift+F10`, run one command, hash lands on the stick. Do five machines,
import one CSV.

## Kit contents

| File | Runs where | Purpose |
|---|---|---|
| `Initialize-Kit.ps1` | Internet-connected machine, once | Stages the official `Get-WindowsAutopilotInfo` script onto the stick so capture works fully offline |
| `Capture-Hash.cmd` | The new device, at OOBE via Shift+F10 | Launcher — auto-detects its drive letter, runs the worker |
| `Capture-Hash.ps1` | (called by the .cmd) | Captures the hash: appends to the batch CSV (default) or uploads direct (`online`) |
| `AutopilotHWID.csv` | (created on first capture) | The accumulating batch — one row per device |

## Setup (once)

1. Insert the stick into any internet-connected machine.
2. From the kit folder, run elevated:
   ```powershell
   .\Initialize-Kit.ps1
   ```
   This downloads `Get-WindowsAutopilotInfo.ps1` from the PowerShell Gallery
   onto the stick. Answer Yes to any NuGet/repository-trust prompts.
3. Done — the kit is now offline-capable.

## Use (every device)

At the OOBE region/keyboard screen:

```
Shift+F10
D:                      (your stick's letter; wmic logicaldisk get name if unsure)
Capture-Hash.cmd
```

The hash appends to `AutopilotHWID.csv` on the stick. A duplicate guard
skips serials already captured, so re-running on the same machine is safe.

Group tags (for tag-based dynamic groups): run the worker directly with the
tag —

```
powershell -ep bypass -File D:\Capture-Hash.ps1 -GroupTag "SALES"
```

### Direct upload instead of CSV

If the device has network at OOBE and you'd rather skip the CSV round-trip:

```
Capture-Hash.cmd online
```

This invokes the `-Online` path: an Intune-admin sign-in prompt appears on
the device, and the hash registers immediately. Batch CSV remains the
default because it needs no credentials on the target machine and captures
work with zero network.

## After capture: import the batch

Intune admin center → **Devices → Enrollment → Windows Autopilot → Devices →
Import**, select `AutopilotHWID.csv` from the stick. Import takes a few
minutes; devices then pick up their deployment profile assignment (dynamic
group membership may add a short delay in tag-based setups).

Then reboot the captured machines back to OOBE (or reset them) and the
Autopilot flow takes over.

## No ethernet port? (the companion kit)

Capture itself is offline — but the deployment that follows needs network at
OOBE. For laptops with no ethernet port and no adapter available, use the
companion **OOBE Wi-Fi Kit** on the same stick. Field order of operations:

1. `Connect-WiFi.cmd` — get the radio associated (Wi-Fi kit)
2. `Capture-Hash.cmd` — harvest the hash (this kit)
3. Import the CSV, assign, let the profile land
4. Reboot to OOBE → Autopilot deploys over the Wi-Fi link

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Get-WindowsAutopilotInfo.ps1 is not staged` | Initializer never run | Run `Initialize-Kit.ps1` from an internet-connected machine |
| `Save-Script` fails during init | NuGet provider / gallery trust not accepted | Re-run and answer Yes; or `Install-Script Get-WindowsAutopilotInfo` and copy from `$env:ProgramFiles\WindowsPowerShell\Scripts` |
| Serial reported as already captured | Duplicate guard working as designed | Delete that serial's row from the CSV to force re-capture |
| Online mode sign-in loops or fails | Conditional Access blocking the OOBE browser session | Use offline CSV mode — it exists precisely for this |
| Imported CSV but no profile assigned | Dynamic group hasn't evaluated / wrong group tag | Verify the tag on the Autopilot device record; give membership evaluation a few minutes |
| Device already Intune-enrolled from a past life | Stale identity records | Clean the old Entra/Intune/Autopilot records for that serial before re-importing (identity sweep) |

## License

MIT. Adapt freely; attribution appreciated.
