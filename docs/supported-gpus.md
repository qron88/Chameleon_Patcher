# Supported GPUs

The full list of what the patcher unlocks. Part of the [Chameleon Patcher](../README.md) documentation.

Everything `Add-ExtraGpuSupport.ps1` adds comes from `Scripts\whitelist.json`: **61 entries, 51
unique PCI device IDs**, 58 in `nv_dispi.inf` and 3 in `nvami.inf`. Each entry is one
`%NVIDIA_DEV.xxxx...%` device line in every `[NVIDIA_Devices*]` block of its INF, pointing at an
install section (a freshly spliced `SectionExtraGPU*` built from the captured template, or an existing
stock section when one already fits that chip).

How to read the tables:

- **Subsystem** is the `SUBSYS_` part of the hardware ID, written `<subsystem device><subsystem
  vendor>`. *any* means the entry has no subsystem qualifier and matches every subsystem of that
  device. `10DE` is NVIDIA's own generic vendor ID, `44494D50` and `00000000` are generic/null IDs
  that mobile cores often report on an adapter board. The four rows with a named vendor are real OEM
  subsystem IDs.
- **GPU** is the label in `whitelist.json` (an `m` suffix = mobile part). It is a description, not a
  guarantee: the INF matches on the PCI ID alone.
- Entries NVIDIA already whitelists upstream in a given release are skipped by the patcher and count
  as present under NVIDIA's own line.
- Where a device ID appears more than once, each row is a separate INF line (different subsystem).

Subsystem breakdown of the 61 entries: 35 `SUBSYS_000010DE`, 16 with no subsystem qualifier, 3
`SUBSYS_44494D50`, 3 `SUBSYS_00000000`, 4 specific OEM IDs (MSI, ASUS x2, Lenovo).

## Turing (RTX 20-series) - 20 entries, `nv_dispi.inf`

| Device ID | GPU | Subsystem |
|---|---|---|
| `DEV_1E90` | GeForce RTX 2080 | any |
| `DEV_1E90` | GeForce RTX 2080m | 10DE |
| `DEV_1E91` | GeForce RTX 2070 Super | any |
| `DEV_1E93` | GeForce RTX 2080 Super | any |
| `DEV_1E93` | GeForce RTX 2080m Super | 10DE |
| `DEV_1ED0` | GeForce RTX 2080 | any |
| `DEV_1ED1` | GeForce RTX 2070 Super | any |
| `DEV_1ED3` | GeForce RTX 2080 Super | any |
| `DEV_1F10` | GeForce RTX 2070 | any |
| `DEV_1F11` | GeForce RTX 2060 | any |
| `DEV_1F12` | GeForce RTX 2060 | any |
| `DEV_1F14` | GeForce RTX 2070 | any |
| `DEV_1F14` | GeForce RTX 2070m | 10DE |
| `DEV_1F15` | GeForce RTX 2060 | any |
| `DEV_1F36` | Quadro RTX 3000 | 10DE |
| `DEV_1F50` | GeForce RTX 2070 | any |
| `DEV_1F51` | GeForce RTX 2060 | any |
| `DEV_1F52` | GeForce RTX 2060 | any |
| `DEV_1F54` | GeForce RTX 2070 | any |
| `DEV_1F55` | GeForce RTX 2060 | any |

## Turing GTX 16-series - 1 entry, `nv_dispi.inf`

| Device ID | GPU | Subsystem |
|---|---|---|
| `DEV_2191` | GeForce GTX 1660m Ti | 10DE |

## Ampere (RTX 30-series and RTX A-series mobile) - 23 entries, `nv_dispi.inf`

| Device ID | GPU | Subsystem |
|---|---|---|
| `DEV_2420` | GeForce RTX 3080m Ti | 10DE |
| `DEV_2438` | RTX A5500m | 10DE |
| `DEV_249C` | GeForce RTX 3080m | 00000000 |
| `DEV_249C` | GeForce RTX 3080m | 10DE |
| `DEV_249C` | GeForce RTX 3080m | 44494D50 |
| `DEV_249D` | GeForce RTX 3070m | 00000000 |
| `DEV_249D` | GeForce RTX 3070m | 10DE |
| `DEV_249D` | GeForce RTX 3070m | 44494D50 |
| `DEV_24A0` | GeForce RTX 3070m Ti | 10DE |
| `DEV_24BA` | RTX A4500m | 10DE |
| `DEV_2501` | GeForce RTX 3060 SUPER | 397E1462 (MSI) |
| `DEV_2501` | GeForce RTX 3060m | 87E81043 (ASUS) |
| `DEV_2520` | GeForce RTX 3060m | 10DE |
| `DEV_2520` | GeForce RTX 3060m | 44494D50 |
| `DEV_25A0` | GeForce RTX 3050m Ti | 10DE |
| `DEV_25A2` | GeForce RTX 3050m | 10DE |
| `DEV_25A5` | GeForce RTX 3050m | 10DE |
| `DEV_25AD` | GeForce RTX 2050 | 3AF817AA (Lenovo) |
| `DEV_25B8` | RTX A2000m | 10DE |
| `DEV_25B8` | RTX A2000m | 106C1043 (ASUS) |
| `DEV_25BA` | RTX A2000m | 10DE |
| `DEV_25BC` | RTX A1000m | 10DE |
| `DEV_25FA` | RTX A2000m | 10DE |

`DEV_25AD` is an Ampere-based RTX 2050 mobile part, listed here for its device ID range.

## Ampere (RTX A-series mobile) - 3 entries, `nvami.inf`

These three go into `nvami.inf` instead of the main desktop INF. That INF is NVIDIA's per-OEM INF for
ASUS: every one of its 537 device lines in stock 582.78 has subsystem vendor `1043`. In stock 621.24 it
is also the only INF that lists these chips at all (ASUS-specific lines such as
`DEV_24B8&SUBSYS_19A21043`, installing through `Section139` / `Section141`); `nv_dispi.inf` has no line for
`DEV_24B8` / `24B9` / `24BB`. The added `SUBSYS_000010DE` lines sit next to those and reuse the same install
sections. Placement in this file is a convention of `whitelist.json`, not a requirement of Windows: PnP
matches a hardware ID against any INF in the package, so a generic line would also work in
`nv_dispi.inf` given a suitable install section.

| Device ID | GPU | Subsystem |
|---|---|---|
| `DEV_24B8` | RTX A3000m | 10DE |
| `DEV_24B9` | RTX A3000m | 10DE |
| `DEV_24BB` | RTX A3000m | 10DE |

## Ada Lovelace (RTX 40-series and RTX Ada mobile) - 13 entries, `nv_dispi.inf`

| Device ID | GPU | Subsystem |
|---|---|---|
| `DEV_24B7` | RTX 4000 Ada Generation Laptop GPU | 10DE |
| `DEV_2717` | GeForce RTX 4090m | 10DE |
| `DEV_2730` | RTX 5000 Ada Generation Laptop GPU | 10DE |
| `DEV_2757` | GeForce RTX 4090m | 10DE |
| `DEV_27A0` | GeForce RTX 4080m | 10DE |
| `DEV_27BA` | RTX 4000 Ada Generation Laptop GPU | 10DE |
| `DEV_27BB` | RTX 3500 Ada Generation Laptop GPU | 10DE |
| `DEV_27E0` | GeForce RTX 4080m | 10DE |
| `DEV_2820` | GeForce RTX 4070m | 10DE |
| `DEV_2860` | GeForce RTX 4070m | 10DE |
| `DEV_28A0` | GeForce RTX 4060m | 10DE |
| `DEV_28A1` | GeForce RTX 4050m | 10DE |
| `DEV_28B8` | RTX 2000 Ada Generation Laptop GPU | 10DE |

## Blackwell (RTX 50-series) - 1 entry, `nv_dispi.inf`

| Device ID | GPU | Subsystem |
|---|---|---|
| `DEV_2D00` | GeForce RTX 5060m | 00000000 |

This single entry sits under a null subsystem ID that real hardware is unlikely to report; Blackwell
is effectively out of scope - see [Coverage and limits](pipeline.md#coverage-and-limits).

## What else changes for these GPUs

Besides the device line itself, every whitelisted GPU gets:

- the **RM override** `RM1457588=1` through the `nv_miscBase_addreg__NN` section its install section
  uses (and, since it is applied to all of them, through every other section too);
- the **PhysX / NVIDIA App flags** (`NVSupportPhysx = 1`, `NVSupportGFExperienceUDA = 1`) on its
  install section, so `setup.exe` offers both components - see
  [PhysX and the NVIDIA App](pipeline.md#physx-and-the-nvidia-app);
- the full set of install directives of the closest stock section of that release (copy files,
  services, registry, feature scores), so a section captured from 595.79 does not miss jobs that later
  releases added.

To see whether the GPU in *this* PC is one of the above:

```powershell
.\Scripts\Invoke-DriverPatchPipeline.ps1 -CheckLocalGpuSupport
```
