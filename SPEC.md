# pixel_tune — the binding specification

This is the SINGLE source of truth. Every number below is **measured on this
specific device**, not estimated. Do not assume anything, do not guess, do not
invent. When you need something and it is not here, write it into your output as
an OPEN QUESTION — do not improvise.

## The device

Google Pixel 8a "akita", SoC Tensor G3 "zuma", kernel 6.1.145-android14-11,
Android 16, 8 GB RAM (7753832 kB), SELinux **Enforcing** (must not be changed).
KernelSU-Next, `ksud 3.3.0`, manager `com.rifsxd.ksunext`.

Existing modules (must not be conflicted with): NLSound, TA_utl, hma_oss_zygisk,
meta-overlayfs, pgs, playintegrityfix, susfs4ksu, tricky_store, zygisk-assistant,
zygisksu.

## HARD CONSTRAINTS

1. **Nothing is written into `/system` or `/vendor` at runtime.** The module adds
   no thermal/powerhint/vendor overlay. **The single known deliberate
   exception:** the module has a `system/bin/pxtune` overlay in its own `system/`
   directory (see "The known deliberate exception" below).
2. **SELinux stays Enforcing.** No `setenforce 0`.
3. **No undervolting** — on Tensor the voltage is controlled by the ACPM
   firmware and the kernel has no access to it.
4. **The refresh rate is not lowered globally.** The adaptive 60-120 Hz stays.
5. Everything must be reversible and backed up.

**The known deliberate exception to point 1 — `system/bin/pxtune`:**
The module contains a single file in the `system/` overlay: `system/bin/pxtune`.
Its ONLY purpose is to put the `pxtune` command in `PATH` from an ordinary
shell. **It is not `/vendor`, it is not a thermal or powerhint overlay, and it
affects neither the running system nor the boot** — it is just a wrapper to reach
the CLI. The risk is therefore minimal and the conflict with point 1 is
documented and accepted here. The alternative would be a symlink into a directory
that is already in `PATH`. In practice we **keep it as a documented exception —
the deployment is not changing.** No _further_ overlay is added.

## Paths

```
/data/adb/modules/pixel_tune/     # the module (metadata + code)
├── module.prop
├── post-fs-data.sh
├── service.sh
├── volkeys.sh                    # long-press volume keys (root, getevent)
├── bin/pxtune                    # the CLI core (POSIX sh, /system/bin/sh)
├── bin/pxtune-tweaks             # the tweak registry engine (sourced lazily)
├── bin/pxtune-perapp             # per-app rules
├── bin/pxtune-metrics            # the battery/power/temperature sampler
├── bin/pxtune-doze               # the sleep helper (releases a foreign wake lock)
├── tweaks/registry.def           # the tweak registry
├── profiles/*.conf               # the profiles shipped with the module
├── apps/*.conf                   # example per-app rules + a template
└── webroot/index.html            # the WebUI

/data/adb/pixel_tune/             # state, survives a module reinstall
├── profiles/{powersave,balanced,performance,game,night,pogo}.conf
├── apps/<package>.conf           # per-app rules
├── backup/stock.conf             # the snapshot of stock values (created once)
├── backup/tweaks.stock           # the stock values of touched tweaks
├── active                        # the name of the active profile
├── tweaks.conf                   # the tweaks that have been set
├── appmode.active                # per-app layer 3 currently deployed
├── manual_override               # exists = the profile was chosen by hand
├── boot_count                    # bootloop protection
├── DISABLE                       # exists = post-fs-data.sh and service.sh bail out
├── res_pending                   # waiting for a resolution change to be confirmed
├── doze.on, doze.conf
├── metrics/, metrics.conf, metrics.on
└── pxtune.log
```

**Note (v1.4.0):** the adaptive daemon `bin/pxtune-auto` was removed from the
module. Profiles are switched manually only. Passages below that describe what
"the daemon" does are kept for the record — the behaviour they describe is now
either manual or does not happen at all.

---

## VERIFIED HARDWARE FACTS

### Which levers survive normal use of the phone (measured 2026-08-08)

The most important table for designing profiles. Method: `powersave` was
applied, all nodes were read, three apps were started one after another
(Settings, Chrome, Clock), and after 5 s everything was read again. The check
that the LAUNCH hint really happened: `dvfs_headroom` changed.

| Node | Applied | After the app launches | Conclusion |
|---|---|---|---|
| `policy4/sched_pixel/limit_frequency` | 1418000 | 1418000 | **HOLDS** |
| `policy8/sched_pixel/limit_frequency` | 1557000 | 1557000 | **HOLDS** |
| `mali0/device/scaling_max_freq` | 649000 | 649000 | **HOLDS** |
| `devfreq_mif/interactive/target_load` | 40 80 | 40 80 | **HOLDS** |
| `lru_gen/min_ttl_ms` | 1000 | 1000 | **HOLDS** |
| `vendor_sched/groups/bg/uclamp_max` | 130 | 130 | **HOLDS** |
| `cpuctl/top-app/cpu.uclamp.max` | 60.00 | 60.00 | **HOLDS** |
| `vendor_sched/dvfs_headroom` | 1024 | **1100** | **OVERWRITTEN BY THE HAL** |

**The consequence for the profiles:** the only lever the power HAL takes back is
`dvfs_headroom`. It belongs in a profile only as a bonus for the idle state (and
in `night`, where LAUNCH hints do not arrive at all) — never as a load-bearing
lever. Everything else including `limit_frequency` holds even during full use.

*(Not tested: the CPU `scaling_max_freq` — the module does not write it, so these
measurements say nothing about its behaviour under LAUNCH.)*

> **REVISION 2026-08-12 — the table and the conclusion above only hold for app
> launches.** The 08-08 method started apps with the screen **already on** and
> therefore missed the real trigger. A snapshot of all 24 nodes before and after
> `input keyevent KEYCODE_SLEEP` + `KEYCODE_WAKEUP` (without touching a single
> app) showed that **waking the display** returns three nodes to stock:
>
> | Node | Applied | After the display wake | Conclusion |
> |---|---|---|---|
> | `vendor_sched/dvfs_headroom` | 1024 | **1100** | OVERWRITTEN BY THE HAL |
> | `policy4/sched_pixel/limit_frequency` | 1418000 | **1836000** | OVERWRITTEN BY THE HAL |
> | `policy8/sched_pixel/limit_frequency` | 1557000 | **2363000** | OVERWRITTEN BY THE HAL |
>
> The other rows of the original table (uclamp, mali `scaling_max_freq`, mif
> `target_load`, `min_ttl_ms`, cpupm residency, `down_rate_limit_us`) still
> hold — those survive a screen cycle.
>
> The timing of the HAL's writes (sampled ~150 ms after `KEYCODE_WAKEUP`):
> `1418000 → 1328000 → 1836000` and then settled, all within **~600 ms**. An
> immediate reapply sometimes loses that race, which is why a reapply should
> happen twice: at once and again a few seconds later.
>
> **Impact:** until 2026-08-12 both clock ceilings of the `powersave` profile —
> described in the profile's own comment as "the single most effective value" —
> had been dead from the first unlock of the phone.

### CPU clusters

| Policy | Cluster | CPU | Frequencies (ascending, kHz) |
|---|---|---|---|
| policy0 | Little 4×A510 | 0-3 | 324000 610000 820000 955000 1098000 1197000 1328000 1425000 1548000 1704000 |
| policy4 | Big 4×A715 | 4-7 | 402000 578000 697000 712000 910000 1065000 1221000 1328000 1418000 1572000 1836000 1945000 2130000 2245000 2367000 |
| policy8 | Prime 1×X3 | 8 | 500000 880000 1164000 1298000 1557000 1745000 1885000 2049000 2147000 2294000 2363000 2556000 2687000 2850000 2914000 |

- The `sched_pixel` governor on all of them — **DO NOT CHANGE**.
- `scaling_max_freq` — **on this A16 build (akita:16/CP1A.260505.005, verified
  2026-08-07) it is writable**: permissions `-rw-rw-r-- system system` (664) and
  **a write HOLDS** even after 40 s in the steady state. Verified with a
  reversible holds-test: policy4 was written 1418000, policy8 1557000 — both
  held; then restored to the stock 2367000 / 2914000.
  **BUT the node is owned by the power HAL** and it overwrites it on a `LAUNCH`
  hint (and others) — so it belongs in a profile only **with the reapply flag**
  (like the cooling devices). It is not a quiet "set and forget" lever.
  *(A historical note: previously / on other builds `scaling_max_freq` had
  permissions 0444 and a write did not go through even as root. That is NO LONGER
  TRUE ON THIS BUILD. The original claim in the SPEC was true for that build, not
  for this one.)*
- Reading always works: `scaling_cur_freq`, `scaling_max_freq`,
  `stats/time_in_state`, `stats/trans_table`.

**`sched_pixel/limit_frequency` — a direct writable clock ceiling (verified
2026-08-07).** Next to the read-only detour through uclamp, this is the **first
direct lever on the clock.**

| Path | Cluster | Stock (kHz) | Permissions |
|---|---|---|---|
| `…/policy0/sched_pixel/limit_frequency` | Little | 1328000 | 644 root:root |
| `…/policy4/sched_pixel/limit_frequency` | Big/Mid | 1836000 | 644 root:root |
| `…/policy8/sched_pixel/limit_frequency` | Prime | 2363000 | 644 root:root |

Verified by a direct write (policy8 tested live). The path is
`/sys/devices/system/cpu/cpufreq/policyN/sched_pixel/limit_frequency`.

**CORRECTION 2026-08-08 — `limit_frequency` SURVIVES the LAUNCH hint.** The
earlier claim "also owned by the power HAL, raised on LAUNCH ⇒ only with the
reapply flag" was **wrong** and is hereby withdrawn. Measured live: the
`powersave` profile was applied (policy4=1418000, policy8=1557000), then three
apps were started one after another (Settings, Chrome, Clock) and the values were
read again — **both ceilings held unchanged.** That the LAUNCH hint really
occurred in that window is proven by `dvfs_headroom` in the same sample:
1024 → 1100. A controlled proof, not the absence of an event.

**CORRECTION 2026-08-12 — the previous paragraph is only half true.** The write
really does hold indefinitely as long as the display is not touched; the trigger
is not an app launch but **a display wake**, and the 08-08 test never tried that
(it started apps with the screen already on). Measured with a clean
`KEYCODE_SLEEP` + `KEYCODE_WAKEUP` cycle without touching an app: policy4
`1418000 → 1836000`, policy8 `1557000 → 2363000`. Details and timing in the
revision note next to the "Which levers survive normal use" table.
`limit_frequency` therefore **belongs among the reapply keys** (`V2_VOLATILE` in
`bin/pxtune`) — it is a reliable lever, but not a "set and forget" one.

### Cooling devices (writable 0644, BUT owned by the thermal HAL)

| Node | Type | max_state | Cluster |
|---|---|---|---|
| `/sys/class/thermal/cooling_device8` | thermal-cpufreq-0 | 9 | policy0 |
| `/sys/class/thermal/cooling_device10` | thermal-cpufreq-1 | 14 | policy4 |
| `/sys/class/thermal/cooling_device12` | thermal-cpufreq-2 | 14 | policy8 |
| `/sys/class/thermal/cooling_device24` | thermal-gpufreq-0 | 12 | GPU |

**The verified conversion:** `cur_state = N` ⇒ the cap is the frequency at index
`(frequency_count - 1 - N)` in the ascending list above.
Example: policy8, `cur_state=2` ⇒ index 12 ⇒ 2687000 kHz. `cur_state=12` ⇒
index 2 ⇒ 1164000 kHz.

**IMPORTANT: the thermal HAL rewrites these values roughly every 7 s.**
**DO NOT USE** them as the main lever for profiles — that would require a watcher
loop, and such a loop eats the battery. Use them for READING only (to display the
current throttling).

The numeric `thermal_zoneN` / `cooling_deviceN` indices are **not stable across a
reboot** — always resolve them at runtime by the `type` field, or use the stable
symlinks under `/dev/thermal/`.

### uclamp cgroups — THIS IS THE MAIN LEVER

Writable 0644, **the thermal HAL does not overwrite them**. The scale is 0-100
(float, `max` = 100).

```
/dev/cpuctl/top-app/cpu.uclamp.{min,max}
/dev/cpuctl/foreground/cpu.uclamp.{min,max}
/dev/cpuctl/background/cpu.uclamp.{min,max}
/dev/cpuctl/system-background/cpu.uclamp.{min,max}
/dev/cpuctl/camera-daemon/cpu.uclamp.{min,max}
/dev/cpuctl/nnapi-hal/cpu.uclamp.{min,max}
```

Stock values: `min=0.00`, `max=max` everywhere, except `nnapi-hal`, which has
`min=1.00`.

- `uclamp.max < 100` = a cap on utilisation ⇒ the governor reaches for lower
  frequencies ⇒ **cooling**
- `uclamp.min > 0` = a floor ⇒ a faster frequency ramp-up ⇒ **snappiness** (at
  the cost of power draw)

**CAREFUL:** `/proc/sys/kernel/sched_util_clamp_min` is the global CEILING on how
high a `uclamp.min` anyone may request. Stock is 1024 and **it must stay that
way**. Setting it to 0 would disable the uclamp boost across the whole system,
including Google's `power-service.pixel-libperfmgr`. DO NOT TOUCH.

### /proc/vendor_sched — a SECOND, independent uclamp interface (verified 2026-08-07)

Next to `/dev/cpuctl` there is a second uclamp interface, `/proc/vendor_sched/`,
on a **0-1024 scale** (not 0-100 like cpuctl!). **Values from both sources are
AGGREGATED and the STRICTER one applies.**

The actual set of **13 groups** (from the probe): `bg cam cam_power dex2oat fg
fg_wi nnapi ota rt sf sys sys_bg ta`. Each has `groups/<group>/uclamp_min`,
`uclamp_max`, `prefer_idle`, `prefer_high_cap`.

Key stock values (verified):

| Node | Stock | Note |
|---|---|---|
| `groups/bg/uclamp_max` | **130** | = 12.7 % (0-1024). Already below the Little threshold of 182/1024 = 17.8 % ⇒ **`UCLAMP_BG_MAX` in /dev/cpuctl is a no-op** (the vendor value already holds the background more strictly). |
| `groups/ta/uclamp_min` | 1 | the top-app floor |
| `groups/fg/uclamp_min` | 0 | the foreground floor |
| `groups/nnapi/uclamp_min` | 225 | |
| `groups/ta/prefer_idle` | false (0) | |
| `/proc/vendor_sched/dvfs_headroom` | **1100** | a per-CPU vector `×9`; writing a scalar returns a vector. 1100/1024 = 107.4 % of governor overshoot. |
| `/proc/vendor_sched/util_threshold` | `2048 2048 2048 2048 1280 1280 1280 1280 1280` | per-CPU |
| `/proc/vendor_sched/reduce_prefer_idle` | **true** | (the v2 registry wrongly claimed 0) |
| `/proc/vendor_sched/tapered_dvfs_headroom_enable` | 0 | |
| `/proc/vendor_sched/uclamp_max_filter_enable` | 1 | |

All of the above are writable. `groups/bg/uclamp_max` and `dvfs_headroom` are
**owned by the power HAL** (it raises them on LAUNCH: bg→512, headroom→1280) ⇒
reapply, or safe only for `night` (screen off, no LAUNCH hints).

### The Mali GPU

`/sys/class/misc/mali0/device/`

- `scaling_max_freq` — **writable and it HOLDS** (verified: 649000 was written
  and after 12 s it was still 649000). This is the safe GPU lever, unlike the
  cooling device.
- `scaling_min_freq`, `hint_max_freq`, `power_policy`
  (`coarse_demand`/`adaptive`/`always_on`)
- `cur_freq`, `utilization`, `time_in_state`
- Frequencies (**descending**, kHz): 890000 850000 807000 723000 649000 580000
  521000 467000 419000 376000 337000 302000 150000
- Stock `scaling_max_freq` = 890000, `scaling_min_freq` = 150000,
  `power_policy` = adaptive

### Thermal

- 28 zones. The zones `BIG/MID/LITTLE/G3D/ISP/TPU/AUR` have `mode=disabled` ⇒
  their sysfs trip points are **dead**; do not touch them, it has no effect.
- The actual throttling is done by the userspace HAL
  `android.hardware.thermal-service.pixel` according to
  `/vendor/etc/thermal_info_config.json` (which we DO NOT change).

**Throttling is driven EXCLUSIVELY by the SKIN (surface) temperature, NOT by the
junction (verified from /vendor 2026-08-07).** The junction zones
(`BIG/MID/LITTLE`) have `mode=disabled` precisely for that reason — they are not
used for throttling. What decides is the set of VIRTUAL-SKIN sensors, each with
`TriggerSensor: soc_therm`. The real thresholds read from `/vendor` on THIS
device (°C):

| Sensor | HotThreshold (°C) | Hysteresis |
|---|---|---|
| `VIRTUAL-SKIN-CPU-MID` | 39.0 / 41.0 | 1.9 |
| `VIRTUAL-SKIN-CPU-HIGH` | 41.0 / 43.0 / 52.0 | 1.9 |
| `VIRTUAL-SKIN-CPU-LIGHT-ODPM` | 37.0 / 39.0 | 1.9 |
| `VIRTUAL-SKIN-GPU` | 43 / 45 / 46.5 / 52 | 1.9 |

The trigger sensor `soc_therm`: `HotThreshold 36.0`, `PollingDelay 60000` (ms),
`PassiveDelay 7000` (ms).

**The consequence for the "5-minute blind spot" (a popular XDA myth):** the
VIRTUAL-SKIN sensors do have `PollingDelay 300000`, but they are recomputed
every time `soc_therm` speaks up. And under any load `soc_therm` is above 36 °C
within moments ⇒ it switches from 60 s to 7 s polling. **The real exposure to
throttling is therefore the first ~60 s from a cold start, not 5 minutes.** The
300 s value almost never applies in practice. Lowering `PollingDelay` only makes
sense for `soc_therm` — and that requires an overlay into `/vendor` (hard
constraint 1) ⇒ WE DO NOT DO IT.

Zone indices for reading temperatures (`/sys/class/thermal/thermal_zoneN/temp`,
millicelsius):

| Zone | Index | Meaning |
|---|---|---|
| BIG | 0 | the Big cluster junction |
| MID | 1 | the Mid junction |
| LITTLE | 2 | the Little junction |
| G3D | 3 | the GPU junction |
| quiet_therm | 8 | the skin |
| soc_therm | 11 | the SoC board |
| charger_therm | 12 | the charger |
| display_therm | 13 | the display |
| battery | 16 | the battery |

The virtual sensors (VIRTUAL-SKIN*) are read through `dumpsys thermalservice` —
which has to be called as `shell`, **not through `su`** (under su it hangs on
binder).

**Switching thermal profiles:**
`setprop vendor.thermal.<SENSOR>.profile <game|camera|"">`
The `game` and `camera` profiles exist for `VIRTUAL-SKIN-CPU-MID` and
`VIRTUAL-SKIN-CPU-HIGH`. An empty string = the default profile.

**The `game` profile is DOCUMENTED on this A16 build too (verified from /vendor
2026-08-07 — this closes open question 4).** In the thermal config both sensors
(`VIRTUAL-SKIN-CPU-MID` and `-CPU-HIGH`) have a `"Mode":"game"` block with
`"Disabled":true` on `thermal-cpufreq-0/1/2`:

```
"Profile": [ { "Mode": "game", "BindedCdevInfo": [
    { "CdevRequest": "thermal-cpufreq-0", "Disabled": true },
    { "CdevRequest": "thermal-cpufreq-1", "Disabled": true },
    { "CdevRequest": "thermal-cpufreq-2", "Disabled": true } ] } ]
```

Setting both props to `game` therefore **disables CPU throttling from 2 of the 4
sensors** that cause it. Still active: `VIRTUAL-SKIN-CPU-LIGHT-ODPM`
(37/39 °C) and `VIRTUAL-SKIN-GPU` (43/45/46.5/52 °C). So `game` does not mean "no
throttling", it means "throttling only from LIGHT-ODPM and the GPU" — which is
considerably looser than stock.

CAREFUL: disabling two sensors really does make the phone **hotter** — the
thermal safety net from the skin becomes the module's responsibility (see
`THERMAL_PROFILE_MAX_SKIN` in the v2 contract below).
CAREFUL 2: the system sets this prop by itself (during the probe it was already
on `camera`). Anything automated must account for that and must not cut across
the system while the camera is running.

**The measured stock behaviour under sustained load** (150 s, 9 cores):
- the Little cap ~1036 MHz (61 % of the HW maximum), Big 910 MHz (38 %),
  Prime 1164 MHz (40 %)
- at a junction of only 58 °C and a skin of 40.5 °C
- the junction peak in the first ~40 s: 81 °C
- **recovery: `MaxReleaseStep=1` ⇒ ~84 s; 60 s after the load ended NOTHING had
  been released**

### Charging

`/sys/devices/platform/google,charger/`
- `charge_stop_level` (0660 system:system, **root CAN write it** — verified by
  writing 80 and returning to 100)
- `charge_start_level` (stock 0)
- Stock: stop=100, start=0
- Others: `bd_trigger_temp` (350), `bd_trigger_time` (21600),
  `bd_recharge_soc` (79), `bd_temp_enable` (1)
- The battery state:
  `/sys/class/power_supply/battery/{capacity,status,temp,cycle_count,current_now}`
- The battery has **602 cycles**.

### Memory

- zram0: **stock after a boot = 3969961984 B (3.70 GiB / 3.97 GB) with the
  `lz77eh` algorithm**. `lz77eh` uses the **Emerald Hill hardware compression
  accelerator** in Tensor (`/sys/devices/platform/16d00000.eh`, driver
  `google,eh`) ⇒ compression costs ~0 CPU and ~0 heat.
  **NEVER switch to zstd or lz4** — those run on the CPU and are worse.
- `/sys/block/zram0/{disksize,comp_algorithm,reset,mm_stat}`
- A `swapoff` at runtime is **dangerous** (risk of OOM) ⇒ zram changes only in
  `post-fs-data.sh`, where swap is empty.
- vm stock: `swappiness=60` (written by
  `/vendor/etc/init/init.pixel-mm-gs.rc`), `dirty_ratio=20`,
  `dirty_background_ratio=10`, `vfs_cache_pressure=100`, `page-cluster=0`
  (already optimal for zram).

### Display

- Physically 1080×2400, `ro.sf.lcd_density=420`, the current density override is
  **353**
- Persistence: `settings put global display_size_forced "<W>,<H>"`,
  `settings put secure display_density_forced <dpi>`
- `global display_size_forced` is currently **empty**,
  `secure display_density_forced` = 353
- Adaptive 60-120 Hz, mode 2 = 120 Hz. **Do not lower it globally.**

### Game Mode (a system feature, per-app, free)

```
cmd game mode [1|2|3|4|standard|performance|battery|custom] <PACKAGE>
cmd game set --downscale [0.3..0.9|disable] --fps <N> <PACKAGE>
cmd game list-modes <PACKAGE>
cmd game list-configs <PACKAGE>
```

---

## PERFORMANCE — the measured cost of operations (REQUIRED READING BEFORE EDITING THE CODE)

The WebUI calls the module over a **synchronous** bridge, so every wasted
millisecond shows up as a freeze. Measured directly on this device (with Little
throttled to 610 MHz):

| operation | cost | note |
|---|---|---|
| `printf` | **17.0 ms** | ⚠️ **NOT a builtin** — it is `/system/bin/printf`, i.e. a fork! |
| `$(...)` subshell | 7.7 ms | per substitution |
| `head`/`sed`/`grep`/`wc`/`date` | ~7-8 ms | a fork |
| `echo` | ~0 ms | a builtin |
| `print -r --` | ~0.25 ms | a builtin, raw (does not interpret `\`) |
| accumulating into a variable | ~0 ms | |
| a builtin `read` from sysfs | 0.44 ms | |
| **a write** to sysfs | 27-31 ms | inherent, the kernel |

**The binding rules that follow:**

1. **Never `printf` in a hot path.** Use `print -r --` (with a newline) or
   `print -rn --` (without). `echo` is a builtin too, but it interprets
   backslashes.
2. **Accumulate JSON and longer output into a variable** and print it with a
   single `print`.
3. **Do not read through `$(...)`.** Use the helpers that set a global variable:
   `rdv <path> <default>` → `V`, `nv` (normalisation to a JSON number), `tempv`,
   `capv`, `bracketv`, `strv`, `stock_getv` → `SV`, `uclamp_keyv` → `UK`,
   `kvload <file> <prefix>`.
4. **Load config files once** via `kvload` into variables, not with repeated
   `sed`/`grep`.

**The result achieved** (before → after):

| | before | after |
|---|---|---|
| `status --json` | 9 700 ms | **200 ms** |
| `profile <name>` | 13 250 ms | **610 ms** |
| `revert` | 8 350 ms | **810 ms** |

## CONTRACT: the profile format

A profile is a `KEY=VALUE` file, sourceable in POSIX sh. Unknown keys are
**ignored** (forward compatibility). An empty value or a missing key = **leave it
alone**.

```sh
# mandatory
PROFILE_NAME="balanced"
PROFILE_DESC="Balanced — stock behaviour"

# uclamp (0-100, or "max"; empty = leave alone)
UCLAMP_TOPAPP_MIN=""
UCLAMP_TOPAPP_MAX=""
UCLAMP_FG_MIN=""
UCLAMP_FG_MAX=""
UCLAMP_BG_MIN=""
UCLAMP_BG_MAX=""
UCLAMP_SYSBG_MIN=""
UCLAMP_SYSBG_MAX=""

# GPU (kHz, must come from the allowed list; empty = leave alone)
GPU_MAX_FREQ=""
GPU_MIN_FREQ=""
GPU_POWER_POLICY=""      # coarse_demand | adaptive | always_on

# the thermal HAL profile ("game" | "camera" | "" = default)
THERMAL_PROFILE_CPU_MID=""
THERMAL_PROFILE_CPU_HIGH=""

# vm
VM_SWAPPINESS=""
VM_DIRTY_RATIO=""
VM_DIRTY_BG_RATIO=""
VM_VFS_CACHE_PRESSURE=""

# I/O
IO_READAHEAD_KB=""       # applied to sda..sdd

# charging
CHARGE_STOP_LEVEL=""     # 1-100
```

### CONTRACT v2 — the new keys (stock verified by the probe 2026-08-07, build akita:16/CP1A.260505.005)

The same semantics as v1: **an empty value / a missing key = leave it alone.**
Unknown keys are ignored (forward compatibility). Nodes marked "reapply" are
owned by the power HAL (it overwrites them on LAUNCH etc.), so a profile has to
restore them periodically rather than set them once.

```sh
# --- /proc/vendor_sched (scale 0-1024, empty = leave alone) ---
VS_TA_UCLAMP_MIN=""     # /proc/vendor_sched/groups/ta/uclamp_min          stock 1
VS_FG_UCLAMP_MIN=""     # /proc/vendor_sched/groups/fg/uclamp_min          stock 0
VS_BG_UCLAMP_MAX=""     # /proc/vendor_sched/groups/bg/uclamp_max          stock 130   (reapply; the only real lever on the background — cpuctl BG is a no-op)
VS_TA_PREFER_IDLE=""    # /proc/vendor_sched/groups/ta/prefer_idle         stock false/0
VS_DVFS_HEADROOM=""     # /proc/vendor_sched/dvfs_headroom                 stock 1100  (a per-CPU vector; reapply)

# --- the sched_pixel governor (reapply — owned by the power HAL) ---
SCHED_LIMIT_FREQ_LITTLE="" # policy0/sched_pixel/limit_frequency           stock 1328000
SCHED_LIMIT_FREQ_MID=""    # policy4/sched_pixel/limit_frequency           stock 1836000
SCHED_LIMIT_FREQ_BIG=""    # policy8/sched_pixel/limit_frequency           stock 2363000
SCHED_DOWN_RATE_MID=""     # policy4/sched_pixel/down_rate_limit_us        stock 500   (CAREFUL: NOT 20000, as the registry/research claimed)
SCHED_DOWN_RATE_BIG=""     # policy8/sched_pixel/down_rate_limit_us        stock 500   (CAREFUL: NOT 20000)

# --- devfreq ---
DEVFREQ_MIF_TARGET_LOAD="" # /sys/class/devfreq/…devfreq_mif/interactive/target_load  stock "20 40"  (CAREFUL: NOT "20 80")
DEVFREQ_DSU_MIN=""         # …devfreq_dsu/…/min_freq                       stock 324000 (CAREFUL: NOT 0)
DEVFREQ_MIF_MIN=""         # …devfreq_mif/…/min_freq                       stock 421000 (CAREFUL: NOT 0)

# --- idle (idle power draw) ---
CPUPM_CL1_RESIDENCY=""     # …/cpupm/cpupm/cpd_cl1_target_residency        stock 10000  (CAREFUL: NOT 750000 — the idle residency is an aggressive 10 ms out of the box)
CPUPM_CL2_RESIDENCY=""     # …/cpupm/cpupm/cpd_cl2_target_residency        stock 10000  (CAREFUL: NOT 750000; night=100000 would sleep LATER, the opposite of the intent)

# --- GPU ---
GPU_DVFS_PERIOD=""         # /sys/devices/platform/…mali/dvfs_period       stock 20     (10 = snappier, 20 = more economical)

# --- memory ---
MEM_LRU_MIN_TTL=""         # /sys/kernel/mm/lru_gen/min_ttl_ms             stock 0      (ms; protects the working set from being pushed into zram, rw verified by the probe)
                           #   CAREFUL about the duplicate with the `mem.lru_gen_min_ttl` tweak in registry.def — set
                           #   only one of them, otherwise the profile and the tweak overwrite each other. The owner is the profile.

# --- thermal, TIGHTLY GUARDED ---
THERMAL_CDEV_BYPASS=""     # user_vote_bypass on the 3 CPU cdevs           stock 0      (risk 3 — a runtime switch that disables skin throttling; never a default, only with a safety net)
                           #   /dev/thermal/cdev-by-name/thermal-cpufreq-{0,1,2}/user_vote_bypass
THERMAL_PROFILE_MAX_SKIN="" # °C — A SAFETY NET: above this skin temperature THERMAL_PROFILE_*
                           #   is NOT applied, and if it is already active it is taken down at runtime.
                           #   It protects against overheating when the `game` profile disables 2 of the 4 skin sensors.
```

**A note on the stock values:** the probe corrected several earlier claims of the
registry/research — `down_rate_limit_us` is 500 (not 20000), the mif
`target_load` is "20 40" (not "20 80"), the `dsu/mif min_freq` are not 0
(324000 / 421000) and `cpd_clN_target_residency` is **already 10000 (10 ms) out
of the box**, not 750000. That changes the intent of the night profile: lowering
the residency makes no sense because it is already low; night should leave it
alone or use a different lever.

## CONTRACT: the `pxtune` CLI

POSIX sh, shebang `#!/system/bin/sh`. It must run under `busybox`/`toybox` on
Android. No bashisms (`[[ ]]`, arrays; `local` is fine in toybox but better
avoided).

```
pxtune status [--json]        # state: profile, temperatures, frequencies, uclamp, zram, charging
pxtune profile list           # list the profiles
pxtune profile current        # the name of the active one
pxtune profile <name>         # switch (sets manual_override)
pxtune reapply                # restore the nodes the power HAL overwrote
pxtune revert                 # restore EVERYTHING to stock from backup/stock.conf
pxtune res <preset|confirm|reset>
pxtune charge <1-100|off>
pxtune game <package> <mode>  # a wrapper around cmd game
pxtune app <list|show|set|rm|sync|json>
pxtune tweak <list|info|get|set|reset|reset-all|json|apply-boot|selftest>
pxtune metrics <start|stop|status|dump|summary|purge>
pxtune doze <on|off|status>
pxtune log [-n N]
pxtune selftest               # verifies that all the paths exist and are writable
```

- **Every write** goes through a single `wr <path> <value>` function, which:
  verifies existence, verifies writability, logs `old → new`, and carries on
  after an error (it never brings the script down).
- The `--json` output must be valid JSON (the WebUI parses it).
- Exit code 0 = OK, 1 = an argument error, 2 = a runtime error.

## CONTRACT: the metrics sampler (`pxtune metrics`)

Diagnostic data collection from which **the effect of the profiles can be
computed after the fact**. The profiles were designed from measured hardware
facts, but their impact on power draw and temperature is not measured — this is
the tool meant to document it.

- **Off until somebody turns it on.** `pxtune metrics start` creates
  `$STATE/metrics.on`; `service.sh` starts it after a boot solely based on that
  file existing. Without it, it does not start at all.
- **Data:** `$STATE/metrics/m-YYYYMMDD.csv`, one line per sample, a header on the
  first line. Kept for `KEEP_DAYS` days (default 7); one day's file is ~210 kB at
  the default interval.
- **Settings:** `$STATE/metrics.conf`, the keys `INTERVAL_SEC` (5-3600, default
  60) and `KEEP_DAYS`. It is read through a whitelist, **not sourced**. An
  interval change applies from the next sample; no restart is needed.
- **The cost of a sample:** ~20 reads from sysfs through the builtin `read` plus
  one `date` and one `sleep`. No `dumpsys`, no binder.
- **A collection failure must not endanger the boot** — in `service.sh` it is a
  non-fatal branch.

Columns: `ts_epoch, time, profile, backlight, status, battery_pct, current_ua,
voltage_uv, power_mw, charge_counter_uah, battery_dc, skin_mc, big_mc, mid_mc,
little_mc, g3d_mc, cd_cpu0, cd_cpu1, cd_cpu2, cd_gpu, f_little, f_big, f_prime,
f_gpu, perapp`.

**THE SIGN OF THE CURRENT — not settled.** All that is verified is that while
charging `current_now` is **positive** (+1.3 A). That it is negative while
discharging is the usual Android convention, but nobody has seen it on this unit
yet: charging cannot be turned off over adb (the device has no `charge_disable`
node, and a `charge_stop_level` below the current battery level does not force a
discharge — verified: with a cap of 70 % and a level of 77 % the phone kept
charging). `pxtune metrics summary` therefore computes the drop from
`charge_counter`, which falls monotonically regardless of the sign, and
distinguishes the mode by the `status` field, not by the sign of the current.

**`perapp` is taken from `appmode.active`, not from `appmode.gamestamp`** —
gamestamp is a rate limit for `GAME_APPLY=enter` and keeps the last game in it
long after you have left it (without this, `pogo` kept sticking to the CSV even
when no rule was running).

## CONTRACT: the sleep helper (`pxtune doze`)

Measured on this device 2026-08-14: with Termux holding
`termux:service-wakelock` permanently, `/sys/power/suspend_stats/success` was
**0** for a whole boot - the SoC never suspended once. The idle drain with the
screen off was **133 mA median / 207 mA mean** (401 intervals from
`pxtune metrics`), against roughly 15-30 mA for a Pixel 8a in real suspend, and
the skin sat at 33-34 C instead of ambient.

- **Off until somebody turns it on.** `pxtune doze on` creates `$STATE/doze.on`;
  `service.sh` starts it after a boot solely based on that file existing.
- It manages a **foreign** wake lock (an app's, not its own). Every exit path -
  `off`, SIGTERM, the flag disappearing, `uninstall.sh` - **re-acquires** it.
  Leaving the phone without a lock somebody else took is not acceptable.
- The wake lock is released only after the screen has been off for `DELAY_SEC`
  and, with `KEEP_WHEN_CHARGING=1`, only off the charger.
- **The poll loop must use a plain `sleep`, never an RTC alarm.** A plain sleep
  does not wake the device; during suspend the loop is frozen and costs nothing.
  Anything that arms `/sys/class/rtc/rtc0/wakealarm` would defeat the purpose.
- Configuration `$STATE/doze.conf` is read through a whitelist, **not sourced**.

## CONTRACT: the log

`/data/adb/pixel_tune/pxtune.log`, format `[YYYY-MM-DD HH:MM:SS] [level] message`.
Rotation above 512 kB (rename to `.old`, start a new one).

## Safety — MANDATORY

- `post-fs-data.sh` contains **only zram** (plus the bootloop logic). Nothing
  else. (Risky things do not belong in the early boot phase.)
- `service.sh` does the rest. The late phase = a possible error cannot cause a
  bootloop.
- **boot_count**: `post-fs-data.sh` increments
  `/data/adb/pixel_tune/boot_count`. `service.sh` zeroes it once the boot has
  completed. When `post-fs-data.sh` sees a value **≥ 3**, it creates `DISABLE`
  and does nothing.
- When `/data/adb/pixel_tune/DISABLE` exists, both `post-fs-data.sh` and
  `service.sh` **exit immediately**.
- Resolution: after a change, `res_pending` is created and a return to native is
  scheduled in 60 s unless `pxtune res confirm` arrives.
