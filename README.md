# pixel_tune (Pixel Tune) v1.4.0

A kernel manager for the **Google Pixel 8a ("akita", Tensor G3 "zuma")** with
KernelSU-Next.

> ### ⚠ THIS IS A CUSTOM MODULE FOR ONE PHONE
>
> pixel_tune was written **specifically for the Google Pixel 8a (akita /
> Tensor G3)** and every number in it comes from measurements on that device.
> **Other devices are not supported and are not compatible.** The sysfs paths,
> the frequency tables, the thermal thresholds, the cooling-device indices, the
> zram accelerator and the vendor scheduler nodes are all Tensor-G3-specific;
> on another SoC they either do not exist or mean something different. Do not
> install this on anything else.

Basis: kernel `6.1.145-android14-11`, Android 16, 8 GB RAM, `ksud 3.3.0`,
manager `com.rifsxd.ksunext`, SELinux **Enforcing**.

Component versions: `pxtune` **1.3.0**, `pxtune-tweaks` 1.0.0,
`pxtune-perapp` 1.0.0, `pxtune-metrics` 1.0.0.

---

## What changed in v1.4.0

If you know an older version of this module, these are the differences that
matter:

| Change | Consequence |
|---|---|
| **The adaptive daemon (`bin/pxtune-auto`) was removed.** | Profiles are switched **manually only** — from the WebUI, the CLI or a per-app rule. Nothing runs in the background and nothing decides for you. |
| **The read-only entries were removed from the tweak registry.** | `pxtune tweak` now offers only what can genuinely be set on this build. |
| **`scaling_max_freq` turned out to be writable after all.** | On this A16 build it has permissions `664 system:system` and a write holds (verified for 40 s on policy0/4/8). Older versions of this document claimed `0444`; that is no longer true. The cleaner lever is still `sched_pixel/limit_frequency` — see section 9. |
| **`balanced` is no longer an empty profile.** | It now carries a small uclamp floor, a longer clock hold and working-set protection — see section 3. |
| **`powersave` was retuned for maximum battery life** (2026-08-13). | Lower CPU/GPU/memory-bus ceilings, while keeping 120 Hz and Pokémon GO smooth. |
| **`volkeys.sh` was added.** | A long press on Volume UP opens the WebUI, on Volume DOWN toggles the torch — both work with the screen off. |
| **`pxtune doze` was added.** | Optional. Releases a foreign wake lock (Termux) once the screen has been off long enough, so the phone can suspend at all — see section 8. |

Leftovers of the daemon that are deliberately still present: `pxtune auto
<on|off|status>` is still in the CLI, and `uninstall.sh` still tries to stop a
daemon. Both are harmless no-ops now — the binary is not shipped, so
`pxtune auto on` only reports that the daemon was not found.

---

## 1. What it is and what it does

`pixel_tune` is a KernelSU module that gives you **one place for a set of tuning
levers** that Android does not otherwise expose on this phone:

- **uclamp cgroups** (`/dev/cpuctl/*/cpu.uclamp.{min,max}`) — the main lever on
  CPU performance and power draw. It either lets processes ramp up to a higher
  frequency sooner (snappiness) or caps their utilisation (cooling).
- **The vendor scheduler** (`/proc/vendor_sched/*`) — a second, independent
  uclamp interface plus `dvfs_headroom` and `prefer_idle`.
- **The `sched_pixel` governor** — `limit_frequency` and `down_rate_limit_us`
  per cluster.
- **The Mali GPU** — `scaling_max_freq`, `scaling_min_freq`, `power_policy`,
  `dvfs_period`.
- **devfreq** — the MIF memory bus and the DSU shared cache.
- **MGLRU** — `min_ttl_ms`, i.e. protection of the working set from zram.
- **The thermal HAL profile** — `vendor.thermal.<SENSOR>.profile`.
- **vm tuning** and **I/O readahead** on `sda`-`sdd`.
- **The zram size** (optional, see section 9 — **the algorithm is never changed**).
- **The charge cap** — `charge_stop_level`.
- **Display resolution and density** — with a safeguard against being stuck on an
  unreadable screen.
- **Android Game Mode** — a wrapper around the system `cmd game` (per-app, no hacks).
- **Individual tweaks** — a registry of 90 kernel/system knobs with a
  description, a risk level and a stock snapshot (section 5).
- **Per-app rules** — Game Mode, refresh rate and a profile overlay per package
  (section 6).
- **Metrics** — optional sampling of battery, power draw and temperatures
  (section 7).
- **A sleep helper** — releases a foreign wake lock so the SoC can actually
  suspend (section 8).
- **State readout** — temperatures from the thermal zones, frequencies, the
  current throttling from the cooling devices, zram, the battery.

And above all: **everything is reversible.** On the first run a snapshot of the
stock values is taken into `backup/stock.conf`, and `pxtune revert` returns to it
at any time. Tweaks have their own snapshot in `backup/tweaks.stock`, captured
the first time each one is touched.

### Why it exists — a specific measured problem

The phone throttles aggressively and pre-emptively. **Measured during 150 s of
sustained load on all 9 cores:**

| Cluster | Cap | % of HW maximum |
|---|---|---|
| Little (A510) | ~1036 MHz | **61 %** |
| Big (A715) | 910 MHz | **38 %** |
| Prime (X3) | 1164 MHz | **40 %** |

And all that at a junction temperature of only **58 °C** and a skin of
**40.5 °C** — which is not a thermal emergency but a conservative policy. The
junction peak reaches **81 °C** in the first ~40 s.

**Recovery is slow on top of that** — the thermal HAL has `MaxReleaseStep=1` in
its configuration, so it releases one step at a time: it takes **~84 s**, and
**60 s after the load ended nothing at all had been released.**

The whole design of the module follows from that: there is no point chasing peak
performance (it gets cut anyway), the point is **not to let the phone into a
state it then spends a minute and a half crawling back from.** That is why the
profiles trim the thermal peak rather than the sustained performance — see
section 3.

### What it physically is

```
/data/adb/modules/pixel_tune/     # the module — deleted on uninstall
├── module.prop
├── post-fs-data.sh               # ONLY bootloop protection + optional zram
├── service.sh                    # everything else (late boot phase, +20 s)
├── uninstall.sh                  # automatic revert on uninstall
├── volkeys.sh                    # long-press volume keys (section 8)
├── icon.png                      # the WebUI icon (module.prop: webuiIcon)
├── bin/pxtune                    # the CLI core (POSIX sh)
├── bin/pxtune-tweaks             # the tweak registry engine (sourced lazily)
├── bin/pxtune-perapp             # per-app rules
├── bin/pxtune-metrics            # the battery/power/temperature sampler
├── bin/pxtune-doze               # the sleep helper (section 8)
├── tweaks/registry.def           # the tweak registry itself (one line = one tweak)
├── profiles/*.conf               # the profiles shipped with the module
├── apps/*.conf                   # example per-app rules + a template
├── assets/                       # the WebUI icon sources
├── widget/install-widget.sh      # an optional home-screen shortcut
└── webroot/index.html            # the WebUI

/data/adb/pixel_tune/             # state — SURVIVES uninstall and reinstall
├── profiles/{powersave,balanced,performance,game,night,pogo}.conf
├── apps/<package>.conf           # your per-app rules
├── backup/stock.conf             # the snapshot of stock values (created once)
├── backup/tweaks.stock           # the stock values of touched tweaks
├── active                        # the name of the active profile
├── tweaks.conf                   # the tweaks you have set
├── appmode.active                # per-app layer 3 currently deployed
├── manual_override               # exists = the profile was chosen by hand
├── boot_count                    # bootloop protection
├── display_state                 # a resolution cache for `status --json` (no binder)
├── metrics/, metrics.conf, metrics.on, pxtune-metrics.pid
├── doze.on, doze.conf, pxtune-doze.pid
├── zram.conf                     # optional, only ZRAM_DISKSIZE (see section 9)
├── DISABLE                       # exists = the module turns itself off at boot
├── res_pending                   # waiting for a resolution change to be confirmed
├── PURGE                         # optional, see section 12
├── volkeys.log, webui.out
└── pxtune.log  (+ pxtune.log.old)
```

The two separate directories are deliberate: **if you uninstall the module, your
profiles and the backup of the stock values stay.** For a completely clean state
see section 12.

---

## 2. Installation and uninstallation

### Installation

1. KernelSU-Next manager → **Modules** → **Install from storage** → pick the
   module ZIP.
2. Reboot the phone.
3. Verify:

```sh
su -c 'pxtune selftest'
su -c 'pxtune status'
su -c 'pxtune tweak selftest'
```

`selftest` walks every path the module uses and prints which ones exist and are
writable. Return code 2 = something is missing. `tweak selftest` does the same
for the registry (targets, types, state consistency).

After a boot, `service.sh` **waits 20 seconds** (`SETTLE=20`) before doing
anything — until then `system_server` is not running and neither `settings` nor
`cmd game` would work. Do not be surprised that the profile is only applied a
little while after you unlock.

### Coexistence with other modules

Already running on the device: NLSound, TA_utl, hma_oss_zygisk, meta-overlayfs,
pgs, playintegrityfix, susfs4ksu, tricky_store, zygisk-assistant, zygisksu.
`pixel_tune` **has no overlay** — it mounts nothing into `/system` or `/vendor` —
so it does not get in the way of meta-overlayfs or susfs.

### Uninstallation

KernelSU-Next manager → **Modules** → `Pixel Tune` → **Uninstall** → reboot.

`uninstall.sh` takes care of most of the cleanup **by itself**:

1. cleans up any daemon leftovers (`pxtune-auto.{pid,fifo,lock}`) — a no-op on
   v1.4.0, where no daemon is shipped,
2. drops `DISABLE` so the module cannot take hold again during this boot,
3. runs `pxtune revert` (uclamp, GPU, vm, I/O, thermal, charging),
4. runs `pxtune res reset` — **but only if the system is already up**,
5. **does not delete the user data in `/data/adb/pixel_tune/`** (the profiles,
   `backup/stock.conf`, the log). It only deletes the runtime files:
   `boot_count`, `res_pending`, `manual_override`.

**Three catches you need to know about:**

- **An uninstall may run in a boot phase where `settings` does not exist.** The
  resolution and DPI are then **not restored** and the script writes that into
  the log. It is therefore better to run `su -c 'pxtune revert'` **by hand before
  uninstalling**, on a running system.
- **`pxtune res reset` sets the DPI to 420, not to your 353.** See section 10 —
  this matters and it is confusing.
- **Tweaks are not part of `pxtune revert`.** Run `su -c 'pxtune tweak reset-all'`
  as well if you have set any.

If you want the uninstall to delete absolutely everything including the profiles
and the backup, create a `PURGE` file first:

```sh
su -c 'touch /data/adb/pixel_tune/PURGE'
```

### When something goes wrong — four levels of emergency shutdown

From the gentlest to the harshest:

#### a) `pxtune revert` — the phone runs, it just behaves oddly

```sh
su -c 'pxtune revert'
```

Restores **everything** to the values from `backup/stock.conf` (and whatever is
missing from it, to the default values from the SPEC). It does not disable the
module, it only cancels its effects. It sets `active=stock`.
**Try this first.**

#### b) The `DISABLE` file — the module must not start at all on the next boot

```sh
su -c 'touch /data/adb/pixel_tune/DISABLE'
```

When this file exists, both `post-fs-data.sh` and `service.sh` **exit
immediately** and do nothing. The module stays installed but is inert.
`service.sh` additionally checks `DISABLE` **once more** after its 20-second
wait — so you can still drop it right after a boot.

You re-enable it by deleting the file:

```sh
su -c 'rm /data/adb/pixel_tune/DISABLE'
```

#### c) KernelSU safe mode — the phone does not boot or you cannot get a shell

**Hold Volume Down** during startup. KernelSU boots into safe mode, which
**disables all modules** (not just pixel_tune). Then uninstall the module in the
manager or drop `DISABLE`.

#### d) The automatic bootloop safeguard (runs by itself, nothing to do)

- `post-fs-data.sh` **increments** the `boot_count` counter on every boot.
- `service.sh` **zeroes** it as soon as `sys.boot_completed` arrives.
- When `post-fs-data.sh` sees `boot_count ≥ 3` (three boots in a row in which
  `service.sh` did not get that far), **it creates `DISABLE` itself** and does
  nothing. It zeroes the counter at the same time, so after you delete `DISABLE`
  by hand you have three attempts again.
- On top of that, at `boot_count ≥ 2` it already **skips the zram change** — that
  is the riskiest operation in the early boot phase, so after a single failed
  boot it is left alone.

**In other words: even if the module were crashing the phone, it disables itself
after three restarts.**

The design meets that halfway in another way too: `post-fs-data.sh` (the early
boot phase, where an error could mean a bootloop) contains **only the bootloop
protection and the optional zram**. Everything else is done by `service.sh` in
the late phase, where an error means at most "nothing got set".

---

## 3. Profiles

A profile is a `KEY=VALUE` text file in `/data/adb/pixel_tune/profiles/`.
Rules that always apply:

- **An empty value or a missing key = that thing is left alone.**
- Unknown keys are ignored (so an older profile does not break a newer `pxtune`).
- The files are **not sourced** — `pxtune` parses them line by line, so a
  corrupted or planted profile cannot execute anything.
- The profiles are yours, you can edit them and **they survive a module
  reinstall**. The module only seeds the ones that are missing.
- **Switching is manual.** There is no automatic switching in v1.4.0.

### Overview — what each profile actually sets

An empty cell "—" means the profile **does not touch** that group of values (it
stays at stock).

| Profile | uclamp (0-100) | GPU | sched_pixel / vendor_sched | memory | charging |
|---|---|---|---|---|---|
| **balanced** *(default)* | `top-app.min=20` | — | `down_rate mid/big=3000 µs`<br>`ta/prefer_idle=1` | `min_ttl=1500 ms` | — |
| **powersave** | `top-app.max=52`<br>`foreground.max=42`<br>`system-bg.max=33` | `max=580000` kHz<br>`dvfs_period=20 ms` | `limit_freq mid=1328000`<br>`limit_freq big=1298000`<br>`dvfs_headroom=1024` | `min_ttl=1000 ms`<br>`MIF target_load="50 90"` | — |
| **performance** | `top-app.min=25` | — | `down_rate mid/big=3000 µs`<br>`ta/prefer_idle=1`<br>`dvfs_headroom=1280` | `min_ttl=1000 ms` | — |
| **game** | `top-app.min=30`<br>`system-bg.max=40` | `dvfs_period=10 ms` | `down_rate mid/big=3000 µs` | `min_ttl=1000 ms` | — |
| **pogo** | `top-app.min=30`<br>`top-app.max=50`<br>`system-bg.max=40` | `max=723000` kHz<br>`dvfs_period=20 ms` | `limit_freq mid=1418000`<br>`limit_freq big=1557000`<br>`dvfs_headroom=1024` | `min_ttl=1000 ms`<br>`MIF target_load="40 80"` | — |
| **night** | `top-app.max=50`<br>`foreground.max=35`<br>`system-bg.max=35` | `max=419000` kHz<br>`dvfs_period=20 ms` | `limit_freq mid=910000`<br>`limit_freq big=1164000`<br>`bg/uclamp_max=100`<br>`dvfs_headroom=1024` | — | `charge_stop_level=80` |

**No profile changes vm, the I/O readahead or zram.** Those keys are empty
everywhere — there is no measured basis for them. **No profile sets a thermal
profile or a cooling-device bypass either**; those keys exist in the contract but
are left empty (see section 9).

### When to use which

| Profile | Description | When |
|---|---|---|
| **balanced** | "Balanced — smooth and quick to switch, still battery-leaning (default)" | The default. Everyday use: a small foreground floor and a longer clock hold buy smoothness, not peak performance. |
| **powersave** | "Maximum battery life — trimmed CPU/GPU peaks, 120 Hz and PoGO preserved" | When you want the phone to last. It trims the **thermal peak in the first tens of seconds of load**, not the sustained performance (that is cut to ~40 % anyway). 120 Hz stays on. |
| **performance** | "Snappier balanced — faster ramp-up, ceilings unchanged" | When the phone does not feel slow but "delayed" — a small lag on the first touch. It does not raise ceilings, it only shortens the ramp-up. |
| **game** | "Games — stable frame-time, tidy background, GPU unchanged" | Games that run for tens of minutes. It aims at stable frame-time, not at peak performance. **Combine it with Game Mode** — see section 6. |
| **pogo** | "Outdoor gaming — a ceiling instead of a peak, surface temperature first" | Pokémon GO and similar outdoor play, where the phone is in the sun and the surface temperature is the binding constraint. |
| **night** | "Night — background kept off the big cores, GPU cut down, charge to 80 %" | The phone lies on a desk or on the night charger. The only profile that **sets the charge cap to 80 % by itself.** |

### Why `balanced` is what it is

In earlier versions `balanced` was deliberately empty ("pure stock"). The
2026-08-13 revision changed that, for one specific reason: **the levers it now
uses do not raise the performance ceiling at all.** They only remove latency:

1. **A uclamp floor of 20 for the foreground** — the render thread does not fall
   to the lowest OPP mid-interaction. This is the only permanent cost of the
   profile, and it is deliberately small.
2. **`down_rate_limit_us=3000`** on Big and Prime — the clock survives the gap
   between two touches (stock is 500 µs = it collapses every half millisecond).
   3 ms is still inside the 120 Hz frame budget of 8.3 ms.
3. **`min_ttl_ms=1500`** — apps you switch between are not pushed into zram, so
   they do not reload from scratch.
4. **`prefer_idle`** for `top-app` — a switch gets an idle core instead of
   queueing behind running work.

Little is left alone on purpose (it runs almost constantly, so any surcharge
there is permanent), and no ceiling is raised, because on this phone **no
ceiling can be raised in a way the thermal HAL would respect**.

### How the numbers in the profiles were derived

It is worth knowing, because it determines **what to expect from the profiles
and what not**.

#### The baseline measurement

Measured during 150 s of sustained load on 9 cores: the system cuts itself down
to **Big 910 MHz (38 % of the HW maximum)** and **Prime 1164 MHz (40 %)** — and
that already at a junction of only 58 °C and a skin of 40.5 °C. The junction peak
in the first ~40 s is however **81 °C**. Recovery from throttling takes **~84 s**
and nothing is released during the first 60 s.

Two rules follow from that, which the profiles obey:

1. **There is no sustained performance left to trim — it is already trimmed.**
   What gets trimmed is the **peak** in the first tens of seconds. That is why
   the `powersave` ceilings lie **above** the measured steady state: they do not
   worsen long-term performance, they only remove a peak that would be paid for
   with 84 seconds of throttling anyway.
2. **Floors (`uclamp.min`) stay BELOW 38 %.** `balanced` has 20, `performance`
   25, `game` and `pogo` 30. A higher floor would push against the throttling
   loop and the result would be a **permanently throttled, i.e. slower** phone.

#### What the uclamp numbers physically mean — the measured capacity table

The `uclamp` scale 0-100 is relative to the capacity of the **strongest** core,
i.e. 1024. The cluster capacities are **measured on the device**:

| Cluster | Cores | `cpu_capacity` |
|---|---|---|
| Little (4×A510) | cpu0-3 | **182** |
| Big (4×A715) | cpu4-7 | **725** |
| Prime (1×X3) | cpu8 | **1024** |

That gives **two hard thresholds** on which all the values in the profiles rest:

| Threshold | Consequence |
|---|---|
| `uclamp.max ≤ 17.8` | util ≤ 182 ⇒ the task fits on Little ⇒ **it never touches Big or Prime** |
| `uclamp.max ≤ 70.8` | util ≤ 725 ⇒ the task fits on Big ⇒ **it never needs Prime (X3)** |
| `uclamp.max > 70.8` | the task may pull in Prime |

Inside a cluster, roughly `frequency ≈ (util / cluster_capacity) × max_freq`
applies. For Big (max 2367 MHz) that is `frequency ≈ (uclamp / 725) × 2367 MHz`:

| `uclamp` | util | Big ≈ |
|---|---|---|
| 20 | 205 | ~669 MHz |
| 25 | 256 | ~836 MHz |
| 30 | 307 | ~1002 MHz |
| 42 | 430 | ~1404 MHz |
| 50 | 512 | ~1672 MHz |
| 52 | 532 | ~1736 MHz |

**This is the main reason why the profiles contain these numbers and not others.**

#### The reasoning behind the key values

| Profile | Key | Value | Why exactly this much |
|---|---|---|---|
| `powersave` | `top-app.max` | 52 | 52 < 70.8 ⇒ the foreground **never pulls in Prime (X3)**, the largest single heat source. ~1736 MHz on Big is still almost twice the steady 910 MHz, so nothing is taken from sustained performance; PoGO holds 60 fps and 120 Hz scrolling keeps headroom. |
| `powersave` | `foreground.max` | 42 | Visible but inactive apps are not rendering at 120 Hz, so they can live one step lower. |
| `powersave` | `system-bg.max` | 33 | Background system services, kept under the Little threshold; the HAL would not give them much more anyway. |
| `powersave` | `GPU max` | 580000 | One step down from 649000. The GPU was never hot under load, but a lower clock is a direct saving while scrolling and in PoGO. 580 MHz still carries 120 Hz composition. |
| `powersave` | `limit_freq big` | 1298000 | Prime settles around 1164 MHz under sustained load anyway, so this ceiling costs almost nothing and is the single most effective lever on both heat and draw. |
| `powersave` | `dvfs_headroom` | 1024 | "Pick exactly the frequency needed" (stock 1100 = +7.4 %). It pays off in idle gaps and with the screen off. |
| `powersave` | `MIF target_load` | `50 90` | The memory bus stays low until it is genuinely busy. One of the few levers that saves power with the display off as well. |
| `balanced` | `top-app.min` | 20 | Enough to keep the render thread off the lowest OPPs, far below the 38 % steady state ⇒ it never fights the thermal HAL. |
| `performance` | `top-app.min` | 25 | util 256 > 182 ⇒ the foreground **does not fit on Little**, so the scheduler puts it straight on Big (~836 MHz). Still ≪ 70.8 ⇒ the floor never wakes Prime by itself. |
| `game` | `top-app.min` | 30 | ~1002 MHz on Big ⇒ between frames the render thread does not fall to a low OPP. Deliberately **not 38-40+**: that would push against the throttling loop and end with a permanently throttled phone mid-game. |
| `pogo` | `top-app.max` | 50 | A ceiling instead of a peak: outdoors the binding constraint is the surface temperature, not the frame rate. |
| `night` | `top-app.max` | 50 | Insurance for picking the phone up while `night` is active — ~1672 MHz on Big means unlocking and a few taps do not feel broken. |
| `night` | `bg/uclamp_max` | 100 | The **vendor** background ceiling (scale 0-1024, stock 130). This is the one that actually binds — `/dev/cpuctl` is overridden by it, because the stricter of the two wins. |
| `night` | `GPU max` | 419000 | With the screen off the cap touches nothing, but it stops a random wakeup (widget, notification, AOD) from pulling the GPU to its highest OPP. **A compromise, not a measurement.** |
| `night` | `charge_stop_level` | 80 | The battery has **602 cycles**, and night is the only situation where the phone predictably sits on the charger for hours with a full battery. |

#### That `uclamp.max` really works is verified by measurement

Measured with four load processes in the `top-app` cgroup, average frequencies:

| `uclamp.max` | Little | Big | Prime |
|---|---|---|---|
| `max` | 1385 MHz | 1469 MHz | 2101 MHz |
| `50` | 1349 MHz | 1418 MHz | **1600 MHz** |
| `25` | 1134 MHz | 1333 MHz | 1277 MHz |

**An honest caveat:** the individual phases ran one after another and the phone
was heating up during them, so **part of the drop is down to concurrent thermal
throttling**, not to uclamp. This measurement on its own therefore does not say
how large the uclamp effect is.

**Something else is conclusive:** in phase 2 the hardware cap on Prime was
**1885 MHz**, yet the measured average was only **1600 MHz**. The governor
therefore went **below the cap of its own accord** — and throttling cannot
explain that. The uclamp effect is thereby proven to be real.

#### The remaining caveats about accuracy

- The uclamp → frequency conversion is **approximate**; the util↔freq relation is
  not exactly linear and the `sched_pixel` governor has logic of its own.
- **The energy model in debugfs is not available on this device**, so it cannot be
  computed whether driving a task onto Little is more economical overall — against
  it stands race-to-idle (on Little the task runs longer).
- **There is no GPU measurement under sustained load** (the measured 150 s were
  CPU-only). That is why the GPU caps in `powersave`/`night` are conservative.

### Profile keys — the complete reference

```sh
# mandatory
PROFILE_NAME="balanced"
PROFILE_DESC="Balanced — smooth and quick to switch, still battery-leaning (default)"

# uclamp via /dev/cpuctl (0-100, or "max"; empty = leave alone)
UCLAMP_TOPAPP_MIN=""     # /dev/cpuctl/top-app/cpu.uclamp.min
UCLAMP_TOPAPP_MAX=""     #                     .../cpu.uclamp.max
UCLAMP_FG_MIN=""         # /dev/cpuctl/foreground/
UCLAMP_FG_MAX=""
UCLAMP_BG_MIN=""         # /dev/cpuctl/background/
UCLAMP_BG_MAX=""
UCLAMP_SYSBG_MIN=""      # /dev/cpuctl/system-background/
UCLAMP_SYSBG_MAX=""

# GPU (kHz, MUST be a value from the allowed list below; empty = leave alone)
GPU_MAX_FREQ=""
GPU_MIN_FREQ=""
GPU_POWER_POLICY=""      # coarse_demand | adaptive | always_on
GPU_DVFS_PERIOD=""       # 10 | 20 (ms)

# the thermal HAL profile ("game" | "camera" | "" = default)
THERMAL_PROFILE_CPU_MID=""
THERMAL_PROFILE_CPU_HIGH=""
THERMAL_CDEV_BYPASS=""   # user_vote_bypass — DANGEROUS, no profile uses it
THERMAL_PROFILE_MAX_SKIN=""

# vendor_sched (scale 0-1024, NOT 0-100)
VS_TA_UCLAMP_MIN=""      # /proc/vendor_sched/groups/ta/uclamp_min
VS_FG_UCLAMP_MIN=""      #                    groups/fg/uclamp_min
VS_BG_UCLAMP_MAX=""      #                    groups/bg/uclamp_max   (stock 130)
VS_TA_PREFER_IDLE=""     #                    groups/ta/prefer_idle  (0 | 1)
VS_DVFS_HEADROOM=""      #                    dvfs_headroom          (stock 1100)

# sched_pixel governor (kHz / µs)
SCHED_LIMIT_FREQ_LITTLE=""   # policy0/sched_pixel/limit_frequency
SCHED_LIMIT_FREQ_MID=""      # policy4  (stock 1836000)
SCHED_LIMIT_FREQ_BIG=""      # policy8  (stock 2363000)
SCHED_DOWN_RATE_MID=""       # policy4/sched_pixel/down_rate_limit_us (stock 500)
SCHED_DOWN_RATE_BIG=""       # policy8

# devfreq
DEVFREQ_MIF_TARGET_LOAD=""   # e.g. "50 90"  (stock "20 40")
DEVFREQ_MIF_MIN=""           # kHz (stock 421000)
DEVFREQ_DSU_MIN=""           # kHz (stock 324000)

# idle residency (µs, stock 10000)
CPUPM_CL1_RESIDENCY=""
CPUPM_CL2_RESIDENCY=""

# memory — MGLRU working-set protection (ms, stock 0)
MEM_LRU_MIN_TTL=""

# vm
VM_SWAPPINESS=""
VM_DIRTY_RATIO=""
VM_DIRTY_BG_RATIO=""
VM_VFS_CACHE_PRESSURE=""

# I/O
IO_READAHEAD_KB=""       # applied to sda, sdb, sdc, sdd

# charging
CHARGE_STOP_LEVEL=""     # 1-100
```

**Allowed GPU frequencies** (kHz, descending — any other value is rejected):

```
890000  850000  807000  723000  649000  580000  521000
467000  419000  376000  337000  302000  150000
```

Stock: `scaling_max_freq=890000`, `scaling_min_freq=150000`,
`power_policy=adaptive`. The GPU `scaling_max_freq` is **verifiably writable and
holds** (649000 was written and was still 649000 after 12 s) — unlike the cooling
devices, which the thermal HAL overwrites.

**A note on `camera-daemon` and `nnapi-hal`:** `pxtune revert` knows about them
and restores them, but **the profile contract does not expose them** — you can
only reach them through the tweak registry (`cpu.uclamp_camera_*`,
`cpu.uclamp_nnapi_*`). That is deliberate.

### What uclamp means in practice

| Setting | Effect |
|---|---|
| `uclamp.max < 100` | A cap on utilisation ⇒ the governor reaches for lower frequencies ⇒ **cooling and saving**, but also slower execution. |
| `uclamp.min > 0` | A floor ⇒ the frequency ramps up sooner ⇒ **snappiness**, but higher power draw. |

| cgroup | What runs in it |
|---|---|
| `top-app` | The app currently on your screen. |
| `foreground` | Visible/active things that are not top-app. |
| `background` | Things in the background. On this device the **vendor** ceiling of 130/1024 already keeps them off the big cores, so `UCLAMP_BG_MAX` in `/dev/cpuctl` has no effect. |
| `system-background` | System tasks in the background. Wakeups and display wake go through them too — which is why the profiles give them a higher cap than ordinary background work. |

---

## 4. The WebUI

The WebUI is `webroot/index.html`; it opens from the KernelSU-Next manager
(Modules → `Pixel Tune` → WebUI), from the home-screen shortcut
(`widget/install-widget.sh`) or with a long press on Volume UP (section 8). It
reads `pxtune status --json` and the controls call the corresponding `pxtune`
commands — **the WebUI cannot do anything the CLI cannot.** When something does
not work for you, try the same thing from a shell; the reason will be in
`pxtune log`.

It has three tabs:

### 📊 Overview

| Card | What it shows / does |
|---|---|
| **Profile** | Five tiles (powersave, balanced, performance, game, night — `pogo` is only offered inside a per-app rule). A tap calls `pxtune profile <name>`. |
| **CPU** | The current and capped frequency per cluster against the HW maximum. |
| **GPU Mali** | Frequency, utilisation, power policy. |
| **Temperatures** | Eight zones, colour-coded by threshold (junction / skin / battery have different scales). |
| **Battery** | Level, temperature, status, cycles + a **charge-limit slider** (60-100 %, step 5) with an **Apply** button that calls `pxtune charge`. |

The overview refreshes itself every 4 s while the tab is visible.

### 🎮 Games (per-app)

One card per rule from `/data/adb/pixel_tune/apps/`. Per package you can set:
the on/off switch, the profile, the resolution downscale, the FPS cap, the
refresh rate and a GPU ceiling overlay. Every change calls
`pxtune app set <pkg> KEY=VALUE`.

**What that actually does immediately** is Game Mode (layer 1) — see section 6
for what the other layers need.

### 🎛️ Tuning (tweaks)

The whole registry from `tweaks/registry.def`, filtered by category, with a
**"Show risky ones too (advanced)"** switch that reveals items of risk ≥ 2. Each
item shows its name, a description (tap to expand), the current value and the
stock value, plus a control matching its type (a switch, a select, a number).
Changes call `pxtune tweak set`, the **↺ revert to stock** button calls
`pxtune tweak reset`.

### What is NOT in the WebUI

The log viewer, resolution presets, metrics and `revert`. All of those are
CLI-only (`pxtune log`, `pxtune res`, `pxtune metrics`, `pxtune revert`).

---

## 5. The CLI — `pxtune`

`/data/adb/modules/pixel_tune/bin/pxtune`, POSIX sh, runs under
`/system/bin/sh`. **All commands require root** (`su -c '...'`).

### Overview

| Command | What it does |
|---|---|
| `pxtune status` | The state: active profile, temperatures, frequencies, uclamp, zram, charging, `res_pending`. |
| `pxtune status --json` | The same as valid JSON (parsed by the WebUI). Reads **sysfs exclusively** — no binder. |
| `pxtune profile list` | List the profiles. |
| `pxtune profile current` | The name of the active profile. |
| `pxtune profile <name>` | Switch profile. **Sets `manual_override`.** |
| `pxtune reapply [--overlay P]` | Rewrite the nodes the power HAL has overwritten (`dvfs_headroom`, `sched_pixel/limit_frequency`). Useful after a launch burst. |
| `pxtune revert` | Restores **EVERYTHING** to stock from `backup/stock.conf`. |
| `pxtune res` \| `res list` \| `res <preset>` \| `res confirm` \| `res reset` | The resolution — see section 10. |
| `pxtune dpi <value\|show\|confirm\|reset>` | The density on its own. |
| `pxtune charge <1-100\|off>` | The charge cap in percent. |
| `pxtune game <package> [mode] [--fps N] [--downscale …]` | A wrapper around `cmd game`. |
| `pxtune app …` | Per-app rules — section 6. |
| `pxtune tweak …` | The tweak registry — below. |
| `pxtune metrics …` | The sampler — section 7. |
| `pxtune doze <on\|off\|status>` | The sleep helper — section 8. |
| `pxtune zram writeback [sec]` | Push idle zram pages out to disk (default 3600 s). |
| `pxtune dexopt <package>` | `pm compile -m speed -f <pkg>` (full AOT compilation). |
| `pxtune thermal explain` | The skin temperature against the VIRTUAL-SKIN thresholds, and what happens when they are crossed. |
| `pxtune auto <on\|off\|status>` | A leftover of the removed daemon. It only rewrites `/data/adb/pixel_tune/auto`; there is nothing to start. |
| `pxtune log [-n N]` | The last N lines of the log (default 50). |
| `pxtune selftest` | Verifies all the paths from the SPEC. |
| `pxtune -v` \| `-h` | Version / help. |

### The tweak registry — `pxtune tweak`

```sh
su -c 'pxtune tweak categories'          # the categories and how many items each has
su -c 'pxtune tweak list net'            # one category
su -c 'pxtune tweak info net.tcp_slow_start_after_idle'
su -c 'pxtune tweak set  net.tcp_slow_start_after_idle 0'
su -c 'pxtune tweak reset net.tcp_slow_start_after_idle'
su -c 'pxtune tweak reset-all'
su -c 'pxtune tweak selftest'
```

How it works:

- The registry is `tweaks/registry.def` — one line per tweak:
  `id|cat|mech|target|type|risk|flags|name|description`.
- **The stock value is not written in the registry.** It is captured **the first
  time the tweak is touched** into `backup/tweaks.stock`, so a revert always
  returns what was really there.
- `risk` is 0-3; the WebUI hides everything ≥ 2 behind the "advanced" switch.
- The `boot` flag means the value does not survive a reboot → `service.sh`
  redeploys it via `tweak apply-boot`. The `reapply` flag means the profile
  overwrites it → it is reapplied at the end of `profile_apply`.
- `mech=bootcfg` writes into a config file rather than to the device (today only
  the zram size, which is deployed by `post-fs-data.sh` at the next boot).
- Since v1.4.0 the registry contains **only knobs that can actually be set**; the
  purely informational read-only entries are gone.

Both a profile and a tweak can touch the same node (for example the GPU ceiling
or the charge cap). The order is fixed: **the profile first, the tweak second**,
so the tweak has the final say.

### Return codes

| Code | Meaning |
|---|---|
| `0` | OK |
| `1` | An argument error (unknown command, unknown profile/preset, a value out of range) |
| `2` | A runtime error (a write failed, `settings`/`cmd` is missing, the selftest found missing paths) |

`pxtune profile <name>` returns **2** even when it was applied but at least one
write failed. How many writes went through and how many did not is printed right
at the end.

### How writing works

Every write into sysfs goes through a single function `wr <path> <value>`, which:

1. verifies that the path exists,
2. verifies that it is writable,
3. logs the `old → new` value,
4. **carries on after an error** — one unwritable node never takes the script
   down.

So when it seems something was not applied, **the answer is always in the log**:

```sh
su -c 'pxtune log -n 50'
```

### The log

`/data/adb/pixel_tune/pxtune.log`, in the format
`[YYYY-MM-DD HH:MM:SS] [level] message`. It rotates at **512 kB** — the old one
is renamed to `pxtune.log.old`. You therefore have at most two files of history.

---

## 6. Per-app rules — `pxtune app`

One file per package: `/data/adb/pixel_tune/apps/<package>.conf`. The module
ships two working examples (Pokémon GO, Instagram) and
`apps/example.conf.template` with every key documented.

```sh
su -c 'pxtune app list'
su -c 'pxtune app show com.nianticlabs.pokemongo'
su -c 'pxtune app set com.nianticlabs.pokemongo GAME_FPS=60 GAME_DOWNSCALE=0.7'
su -c 'pxtune app preset com.example.game game'      # game|game-max|video|social|saver
su -c 'pxtune app rm com.example.game'
```

### The three layers — and what actually happens in v1.4.0

| Layer | What | Per app? | Who applies it now |
|---|---|---|---|
| **1** | Android Game Mode (`cmd game set/mode`) | **yes** | `app set` / `app sync` — **immediately, and the system keeps it** |
| **2** | A pixel_tune profile / overlay (uclamp, GPU, …) | no | only `pxtune app enter <pkg>`, run by hand |
| **3** | Refresh rate and resolution (`settings`) | no | only `pxtune app enter <pkg>`, run by hand; `app leave` takes it back down |

**This is the honest state of v1.4.0:** `app enter` / `app leave` used to be
called by the adaptive daemon on every foreground change. With the daemon gone,
**nothing calls them automatically**, so of the whole rule set only **layer 1
(Game Mode) is really live**. Layers 2 and 3 remain available as manual
commands.

`service.sh` still calls `pxtune app leave` on every boot. That is deliberate and
still useful: it is the path that recovers you from a phone that died mid-game
and would otherwise stay locked at 60 Hz or at a game's resolution.

Key rule keys:

```
APP_PKG APP_DESC APP_ENABLED
GAME_MODE GAME_FPS GAME_DOWNSCALE GAME_APPLY(once|enter)
APP_PROFILE APP_OVERLAY_<profile key>
APP_REFRESH_MIN APP_REFRESH_PEAK APP_RES APP_RES_ENABLE
APP_MIN_FG_SEC APP_STICKY_SEC APP_THERMAL_CAP APP_PRIORITY
```

### Game Mode modes

| Value | Meaning |
|---|---|
| `1` / `standard` | Standard |
| `2` / `performance` | Performance |
| `3` / `battery` | Battery |
| `4` / `custom` | Custom (combined with `--downscale` / `--fps`) |

**For games, Game Mode is the better tool than a global resolution change.** It
scales the resolution per app, so it does not spoil the system UI or other apps:

```sh
su -c 'pxtune game com.example.game custom --downscale 0.7 --fps 60'
su -c 'pxtune game com.example.game battery'
su -c 'pxtune game com.example.game'          # prints the current modes and configs
```

---

## 7. Metrics — `pxtune metrics`

An optional sampler of battery level, power draw and temperatures. It is **off by
default**; when it is on it survives a reboot (`metrics.on`) and `service.sh`
starts it.

```sh
su -c 'pxtune metrics start'      # start sampling (every 60 s by default)
su -c 'pxtune metrics status'     # is it running, how much data is there
su -c 'pxtune metrics summary'    # a per-profile summary, from discharge only
su -c 'pxtune metrics stop'
su -c 'pxtune metrics purge'
adb shell 'su -c "pxtune metrics dump"' > metrics.csv
```

Data lands in `/data/adb/pixel_tune/metrics/m-YYYYMMDD.csv`, settings in
`metrics.conf` (`INTERVAL_SEC`, `KEEP_DAYS=7`). The summary deliberately only
counts periods of **discharge** — while charging, the numbers say nothing about
consumption.

This is the tool to use if you want to answer "does this profile actually save
anything on my usage" instead of guessing.

---

## 8. Sleeping, volkeys and the home-screen shortcut

### `pxtune doze` — letting the phone actually suspend

This does **not** implement Android Doze. Android already has that and it works.
What this removes is the thing that *blocks* it: a permanent
`PARTIAL_WAKE_LOCK` held by an app you run on purpose.

Measured on this device while Termux held `termux:service-wakelock`
continuously (a remote-control bot plus an SSH tunnel):

| | measured |
|---|---|
| `/sys/power/suspend_stats/success` | **0** — the SoC never suspended, not once, in a whole boot |
| idle drain, screen off | **133 mA median** (207 mA mean) |
| skin temperature at rest | 33-34 °C instead of ambient |
| for comparison, real suspend | roughly 15-30 mA |

No third-party "doze module" fixes that, because nothing overrides a partial
wake lock held by a running app — the only thing that helps is releasing it.

```sh
su -c 'pxtune doze status'    # suspends so far, who holds a wake lock, config
su -c 'pxtune doze on'        # enable
su -c 'pxtune doze off'       # disable AND re-acquire the wake lock
```

How it behaves:

| Situation | What it does |
|---|---|
| Screen on | Holds the wake lock, polls every `POLL_ON` s |
| Screen off, less than `DELAY_SEC` | Still holds it — short screen-offs do not cut a running session |
| Screen off, charging, `KEEP_WHEN_CHARGING=1` | Stays awake: there is no battery to save and the phone stays reachable |
| Screen off past `DELAY_SEC` | **Releases** the wake lock → the phone can suspend |
| Screen back on | Re-acquires it and logs how many suspend cycles happened |

The poll loop is a plain `sleep` on purpose: a plain sleep arms no RTC alarm, so
it cannot wake the device. While the phone is suspended the loop is frozen along
with everything else and costs nothing.

Configuration in `/data/adb/pixel_tune/doze.conf` (read through a whitelist, not
sourced):

```sh
DELAY_SEC=300          # screen off for this long before the lock is released
KEEP_WHEN_CHARGING=1   # 1 = stay awake while charging
POLL_ON=30             # poll period with the screen on
POLL_OFF=60            # poll period with the screen off
WAKELOCK=termux        # which foreign lock to manage: termux | none
TERMUX_UID=10384       # changes when Termux is reinstalled
```

**The trade-off is real and you should know it:** while the wake lock is
released, anything that depends on the phone being awake — a polling bot, an SSH
tunnel — only responds once something else wakes the device. That is why the
release is delayed, why charging can keep it awake, and why `off`, a SIGTERM and
`uninstall.sh` all re-acquire the lock.

### volkeys

`volkeys.sh` is a small root daemon started by `service.sh`:

| Action | Result |
|---|---|
| **Long press Volume UP** (≥ 550 ms) | Opens the pixel_tune WebUI |
| **Long press Volume DOWN** (≥ 550 ms) | Toggles the torch (via `termux-torch`) |

Both work **with the screen off** — it reads raw input through `getevent`, which
does not need the display. It only monitors, it does not consume events, so the
volume may also change while you hold the key. That is a known side effect.

Two things it depends on:

- **Termux** for the torch (`TERMUX_UID` at the top of `volkeys.sh` — the uid
  changes if you reinstall Termux, and it has to be edited there),
- the KernelSU-Next manager for the WebUI intent.

Its log is `/data/adb/pixel_tune/volkeys.log`.

`widget/install-widget.sh` installs a home-screen shortcut that opens the same
WebUI.

---

## 9. What it does NOT do, and why

This section is as important as all the previous ones. Most "kernel tuning"
modules promise things that on Tensor are **physically impossible** or actively
harmful.

### No undervolting

On Tensor, voltage is controlled by the **ACPM firmware**. **The kernel has no
access to it.** There is no sysfs node a voltage could be written to.

Any module that promises you undervolting on this SoC is either lying or changing
something else and calling it undervolting. `pixel_tune` does not do it and will
not.

### `scaling_max_freq` is writable — but it is not the lever the profiles use

Older versions of this document claimed the node was `0444` and unwritable. **On
this A16 build that is no longer true:**
`/sys/devices/system/cpu/cpufreq/policy*/scaling_max_freq` has permissions
**`664 system:system`** and a write **holds** — verified on policy0, policy4 and
policy8, where a cap survived 40 s and was then restored.

It is still **not** what the profiles use, for two reasons:

1. **The power HAL owns the node.** On a `LAUNCH` hint it drops the cap back to
   the maximum. Anything set there needs the `reapply` flag.
2. **`sched_pixel/limit_frequency` is cleaner.** The governor works with it
   directly, it does not pretend to be a hardware limit, and the power HAL writes
   into it itself, so the two are at least talking about the same thing.

Both are available in the tweak registry (`cpu.max_freq_*` vs `sched.limit_freq_*`,
the former flagged `adv`), and the profiles use `SCHED_LIMIT_FREQ_*`.

### Cooling devices are not used as a lever

`/sys/class/thermal/cooling_deviceN/cur_state` **is** writable (0644), but its
owner is the thermal HAL and it **overwrites the values roughly every 7 seconds**.
Holding them against it would mean a watcher loop faster than 7 s — and that eats
battery.

The module uses them **for reading only**, to show you the current throttling:

| Type | max_state | Cluster | The index during one boot |
|---|---|---|---|
| `thermal-cpufreq-0` | 9 | policy0 (Little, 4×A510) | `cooling_device8` |
| `thermal-cpufreq-1` | 14 | policy4 (Big, 4×A715) | `cooling_device10` |
| `thermal-cpufreq-2` | 14 | policy8 (Prime, 1×X3) | `cooling_device12` |
| `thermal-gpufreq-0` | 12 | GPU | `cooling_device24` |

> **Do not take the last column as a valid number.** The numeric
> `cooling_deviceN` indices **are not stable across a reboot** — details in
> section 11. `pxtune` therefore looks them up at runtime by the `type` field.

The conversion to a frequency: `cur_state = N` ⇒ the cap is the frequency at
index `(frequency_count − 1 − N)` in the ascending frequency list of that cluster.
An example for policy8 (15 frequencies): `cur_state=2` ⇒ index 12 ⇒ 2687000 kHz;
`cur_state=12` ⇒ index 2 ⇒ 1164000 kHz.

**This conversion is verified on the device**, at three independent points — the
computed frequency matched the actually measured cap every time:

| Cooling device | `cur_state` | Computed | Measured cap | Match |
|---|---|---|---|---|
| `thermal-cpufreq-0` | 8 / 9 | 610 MHz | `610000` | ✓ |
| `thermal-cpufreq-1` | 10 / 14 | 910 MHz | `910000` | ✓ |
| `thermal-cpufreq-2` | 12 / 14 | 1164 MHz | `1164000` | ✓ |

There **is** a `user_vote_bypass` node on `thermal-cpufreq-0/1/2` that would make
a cooling device ignore the HAL's votes, and it is in the registry as
`thermal.cdev_bypass_*` — at risk **3**, flagged `unverified`, and **no profile
uses it**. It removes the phone's thermal brake; nothing then stops it getting
hot.

### The governor is not changed

All three clusters run `sched_pixel` — a governor tuned by Google and integrated
with the scheduler and with `power-service.pixel-libperfmgr`. Switching to
`schedutil` or anything else breaks the things built on it. **It is left alone.**
Its *tunables* (`limit_frequency`, `down_rate_limit_us`) are used; the governor
itself is not swapped.

### `sched_util_clamp_min` stays at 1024

`/proc/sys/kernel/sched_util_clamp_min` is the **global ceiling on how high a
`uclamp.min` anyone in the system may request.** **It is not an enforced frequency
floor** — it is a limit on requests. The stock value of **1024 means that ceiling
is fully open.**

You will sometimes be advised to "set it to 0, you will save battery". **That is
wrong and harmful:** setting it to 0 would **disable the uclamp boost across the
whole system**, including Google's `power-service.pixel-libperfmgr`, which uses it
to keep the UI responsive. The result is a generally stuttery phone.

`pixel_tune` **does not touch** this value.

### The zram algorithm is not changed

After a boot, zram0 has **3969961984 B (3.70 GiB / 3.97 GB)** and the algorithm
**`lz77eh`**.

`lz77eh` uses the **Emerald Hill hardware compression accelerator** built into
Tensor (`/sys/devices/platform/16d00000.eh`, driver `google,eh`). Compression
therefore costs **~0 CPU and ~0 heat.**

Both `zstd` and `lz4` run **on the CPU** and are clearly worse here — more power
draw, more heat, no compensating advantage. **The module never changes the
algorithm.** That is written into the code too: when zram is reset, the original
algorithm is read and **restored** afterwards.

(Incidentally that is also why lowering `swappiness` makes no sense: swap is
unusually cheap on this phone. Which is why no profile changes it.)

**The zram size can be changed** — optionally, via
`/data/adb/pixel_tune/zram.conf` (or the `zram.disksize` tweak, which writes the
same file):

```sh
ZRAM_DISKSIZE=3969961984      # in bytes
```

The file **does not exist by default** and without it zram is not touched at all.
When it does exist:

- the allowed range is **268435456 B (256 MiB) to 7939923968 B** (the physical
  RAM);
- it is changed **only in `post-fs-data.sh`**, where swap is empty — a `swapoff`
  at runtime is dangerous (risk of OOM);
- before the `swapoff` it is checked whether the contents of swap fit into free
  RAM (with a margin); when they do not, the change is **skipped**;
- at `boot_count ≥ 2` the change is skipped entirely;
- if any step fails, a **rollback** to the original size and algorithm is
  performed.

### Beware of other memory "optimisers"

A number of kernel managers offer switching the zram algorithm to `lz4` or `zstd`
and shrinking zram, and sell it as an optimisation. **On this phone that is a step
backwards:**

| Thing | Stock on this device |
|---|---|
| zram size | **3969961984 B (3.70 GiB / 3.97 GB)** |
| zram algorithm | **`lz77eh`** (hardware accelerated) |
| `vm.swappiness` | **60** (written by `/vendor/etc/init/init.pixel-mm-gs.rc`) |

If you used another kernel manager on the phone before, check after uninstalling
it that all three values are back at stock:

```sh
su -c 'cat /sys/block/zram0/comp_algorithm'   # the active one must be [lz77eh]
su -c 'cat /sys/block/zram0/disksize'         # 3969961984
su -c 'cat /proc/sys/vm/swappiness'           # 60
```

### The refresh rate is not lowered globally

The adaptive 60-120 Hz stays (mode 2 = 120 Hz). Dropping to a fixed 60 Hz is a
change you feel on every swipe, and its benefit is not measured on this device.
A per-app refresh rate is available through a per-app rule; globally, Android has
its own "Smooth display" switch in Settings.

### The thermal trip points are not touched

The zones `BIG`, `MID`, `LITTLE`, `G3D`, `ISP`, `TPU`, `AUR` have
`mode=disabled` — their sysfs trip points are **dead**, writing to them has no
effect. The actual throttling is done by the userspace HAL
`android.hardware.thermal-service.pixel` according to
`/vendor/etc/thermal_info_config.json`, which **we do not change**.

The temperatures are only read from there
(`/sys/class/thermal/thermal_zoneN/temp`, millicelsius):

| Zone (`type`) | Meaning | The index during one boot |
|---|---|---|
| `BIG` | the Big cluster junction | 0 |
| `MID` | the Mid junction | 1 |
| `LITTLE` | the Little junction | 2 |
| `G3D` | the GPU junction | 3 |
| `quiet_therm` | **the skin (surface)** — the zone that decides the throttling | 8 |
| `soc_therm` | the SoC board | 11 |
| `charger_therm` | the charger | 12 |
| `display_therm` | the display | 13 |
| `battery` | the battery | 16 |

> **Again: the last column is not a valid number.** The `thermal_zoneN` indices
> change on every reboot — see section 11. A zone is identified by its `type`,
> not by its number.

`pxtune thermal explain` prints the current skin temperature against the
VIRTUAL-SKIN thresholds and says what crossing each one does.

### How the phone throttles at stock

So that it is clear what you are working with — measured during 150 s of
sustained load on 9 cores:

| Thing | Measured |
|---|---|
| The Little cap | ~1036 MHz = **61 %** of the HW maximum |
| The Big cap | 910 MHz = **38 %** |
| The Prime cap | 1164 MHz = **40 %** |
| The junction at that point | only **58 °C** |
| The skin at that point | **40.5 °C** |
| The junction peak in the first ~40 s | **81 °C** |
| GPU throttling (`cdev_gpu`) | **0 the whole time — none at all** |
| Recovery (`MaxReleaseStep=1`) | **~84 s**; 60 s after the load ended **nothing** had been released |

Three things worth remembering:

1. **Google throttles aggressively and pre-emptively**, not only once it is hot.
   38 % of maximum at a 58 °C junction is not a thermal emergency, it is a
   conservative policy.
2. **The GPU has nothing to do with this.** `cdev_gpu` stayed at zero for all
   150 s. The source of both heat and the brake are the CPU clusters, not the
   graphics. That is why the profiles target the **CPU thermal peak**.
3. **Recovery is slow.** After the load ends it takes ~84 s before the caps are
   released, and for the first 60 s nothing happens. When measuring the effect of
   a profile with a benchmark, **leave at least two minutes of quiet between
   runs**, otherwise you are measuring residual throttling, not your profile.

---

## 10. Display resolution and charging

### Resolution

> **Read this whole part BEFORE you change the resolution for the first time.**
> It is the one thing in the module that can leave you staring at an unusable
> screen.

| Thing | Value |
|---|---|
| The physical panel | 1080 × 2400 |
| `ro.sf.lcd_density` | 420 |
| **The current density override on this phone** | **353** |
| `settings global display_size_forced` | **empty** |
| `settings secure display_density_forced` | **353** |
| Refresh rate | adaptive 60-120 Hz, mode 2 = 120 Hz |

#### ⚠ The number 353 vs. 420 — this is the catch

This phone has its own density override of **353**. The firmware value is 420.

**`pxtune res reset` (and the `native` preset, and the 60-second safeguard) sets
the DPI to 420, not to 353.** So it gives you back the right *resolution*, but
**a different DPI than you had** — everything will be a bit smaller.

The 353 is restored by:

- `pxtune revert` (it takes the value from `backup/stock.conf`), or
- a manual `settings put secure display_density_forced 353`.

**The rule: use `res reset` when you cannot see. Use `revert` when you want
exactly the original state.**

#### Presets

```sh
su -c 'pxtune res list'      # lists the presets
su -c 'pxtune res 900'       # 900 × 2000 @ 350 dpi
```

| Preset | Resolution | DPI |
|---|---|---|
| `native` | 1080 × 2400 | 420 |
| `900x2000` (or `900`) | 900 × 2000 | 350 |
| `810x1800` (or `810`) | 810 × 1800 | 315 |
| `720x1600` (or `720`) | 720 × 1600 | 280 |

Persistence goes through the system settings, not through a change to `/system`:

```sh
settings put global display_size_forced "<W>,<H>"
settings put secure display_density_forced <dpi>
```

#### The 60-second safeguard — how it works

1. `pxtune res <preset>` changes the resolution **and at the same time** creates
   `res_pending` with a one-off token.
2. A watchdog starts in the background that **restores the native resolution
   after 60 seconds**.
3. When you confirm within 60 s (`pxtune res confirm`), `res_pending` disappears,
   the watchdog finds its token is no longer valid and **does nothing**.
4. **When you do not confirm** — because you cannot see the display — after
   60 seconds the resolution **returns to 1080×2400 @ 420 dpi by itself**.

The whole trick is: **when you are not sure, do not confirm.** A failure heals
itself. The `native` preset does not start the safeguard — there is nothing to
guard against.

If the phone reboots with `res_pending` still present, `service.sh` treats that
as "the change was never confirmed" and returns to native on the next boot.

#### A blind restore over ADB (when you cannot see the UI)

**Step 0 — wait a minute.** Seriously. If you did not confirm the change, the
safeguard solves it by itself.

**Step 1 — the simplest route, no root:**

```sh
adb shell wm size reset
adb shell settings put secure display_density_forced 353
```

**DO NOT USE `wm density reset`** — it would restore 420, not the 353.

**Step 2 — when that was not enough, clear the persistent override directly:**

```sh
adb shell settings delete global display_size_forced
adb shell settings put secure display_density_forced 353
adb reboot
```

**Step 3 — the emergency brake:** `adb reboot` and **hold Volume Down** during
startup → KernelSU safe mode → all modules disabled.

> **A warning about `adb shell su -c '...'`:** KernelSU has an allowlist for root
> and the shell need not be on it by default. When `su` from ADB asks for
> approval, you have to tap it **on the display** — which is exactly what you
> cannot do in this scenario. That is why steps 1 and 2 are deliberately written
> so that they do **not need** root.

#### Honestly: outside games, lowering the resolution will probably gain you nothing

In the measured load test — **150 seconds of full CPU load on all 9 cores** —
**`cdev_gpu` stayed at 0 the whole time.** The GPU was not thermally throttled
for a single moment.

The conclusion: **the GPU is not the thermal bottleneck on this phone for
non-gaming loads.** Taking pixels away from it buys you nothing measurable, while
the image is noticeably worse. For games, use Game Mode (section 6) — it scales
per app.

### Charging

The battery has **602 charge cycles**. That is a decent mileage and it is the
main reason this feature is in the module.

```sh
su -c 'pxtune charge 80'     # charge only to 80 %
su -c 'pxtune charge off'    # back to 100 %
```

It is written into
`/sys/devices/platform/google,charger/charge_stop_level`. That node has
permissions `0660 system:system`, but **root can write to it** — verified by
writing `80` and returning to `100`.

In the WebUI the slider is **60-100 %, step 5**. The CLI takes the whole 1-100
range. The `night` profile sets 80 % by itself:

```sh
CHARGE_STOP_LEVEL="80"
```

Careful: **a profile sets the cap again on every switch.** If you run
`pxtune charge off` and then switch to `night`, it will be 80 again.

Lithium cells age faster when held at a high voltage. Keeping the phone in a band
around 80 % instead of 100 % slows the degradation of capacity — above all when
you **charge overnight**. The price is straightforward: a cap of 80 % means you
have 80 % of the capacity available.

| Node | Stock | Note |
|---|---|---|
| `charge_stop_level` | 100 | This is what we change. |
| `charge_start_level` | 0 | When to start charging again (`revert` restores it). |
| `bd_trigger_temp` | 350 | Battery Defender: the temperature threshold (35.0 °C). |
| `bd_trigger_time` | 21600 | 6 hours. |
| `bd_recharge_soc` | 79 | |
| `bd_temp_enable` | 1 | |

All the Battery Defender nodes are also in the tweak registry (`batt.*`) — with
the warning that turning the protection **off** shortens the life of a cell that
already has 602 cycles.

---

## 11. Integrity, banking and troubleshooting

### What pixel_tune does and does not do

| | |
|---|---|
| Writes into `/system` or `/vendor` | **No.** No overlay and no bind mount. |
| Changes SELinux | **No.** It stays **Enforcing**. No `setenforce 0`. |
| Uses an accessibility service | **No.** |
| Changes build props / the fingerprint (`ro.*`) | **No.** The props it can touch are `vendor.thermal.<SENSOR>.profile`, `debug.sf.*`, `debug.hwui.*` and `persist.vendor.vibrator.hal.context.*` — runtime and vendor tuning props, not the device identity. |
| Installs an app | **No.** The UI is a WebUI inside the KernelSU manager. |
| Where it writes | `sysfs`, `/dev/cpuctl`, `/proc/*`, `settings` (resolution and density) and its own `/data/adb/pixel_tune/`. |

Apart from `charge_stop_level`, the display settings and a handful of `persist.*`
tweaks, all the module's interventions are **runtime values that a restart
wipes.** They leave no trace in the system image.

**But be realistic:** what detection looks for is **an unlocked bootloader and
root as such**, not this particular module. The fact that `pixel_tune` does not
write into `/system` means it **adds no new detection surface** — it does not
mean it hides anything. Hiding is handled by entirely different modules
(`playintegrityfix`, `tricky_store`, `susfs4ksu`, …); `pixel_tune` neither
competes with them nor replaces them.

### Troubleshooting

| Symptom | What to do |
|---|---|
| **The phone does not boot / bootloop** | Hold **Volume Down** during startup → KernelSU safe mode. Note: after **three** failed boots the module disables **itself** via `boot_count`. |
| **I cannot see the display after a resolution change** | **Wait 60 seconds** — the safeguard restores the native resolution by itself. If not: `adb shell wm size reset` + `adb shell settings put secure display_density_forced 353`. Section 10. |
| **The resolution came back, but the text is smaller than before** | Expected. `res reset` and the safeguard set the DPI to **420**, not to **353**. Fix: `pxtune revert` or `settings put secure display_density_forced 353`. |
| **A profile "was not applied"** | `su -c 'pxtune log -n 50'`. Every write is logged as `old → new`; on an error it carries on, so the reason is always in the log. Then `su -c 'pxtune selftest'`. |
| **A profile value gets undone after a few seconds** | The power HAL rewrites `dvfs_headroom` and `sched_pixel/limit_frequency` on app launches. `su -c 'pxtune reapply'` puts them back. |
| **The profile is applied late after a boot** | That is how it should be. `service.sh` waits **20 s** (`SETTLE=20`), because `system_server` is not running before that. |
| **`pxtune: not found`** | The module is not active. Check that `/data/adb/modules/pixel_tune/` exists, that there is **no** `DISABLE` in it, and that the phone is not in safe mode. |
| **`pxtune auto on` says the daemon was not found** | Correct. The daemon was removed in v1.4.0; the command is a leftover. |
| **A per-app profile or refresh rate does nothing** | Also correct — see section 6. Only Game Mode (layer 1) is applied automatically now. |
| **A tweak reverts itself after a reboot** | That is what the `boot` flag is for: `service.sh` redeploys it after `SETTLE`. If it does not, check `pxtune tweak selftest` and the log. |
| **The phone is hot / stutters while taking photos** | The system switches `vendor.thermal.*.profile` by itself (the camera to `camera`). Do not set `THERMAL_PROFILE_*` in a profile. |
| **The module is eating my battery** | Check the profile: `UCLAMP_*_MIN > 0` means higher power draw by definition (`balanced`, `performance`, `game`, `pogo` have it). Switch to `powersave` or `night`. Better still, measure it: `pxtune metrics`. |
| **A benchmark shows worse numbers than last time** | Recovery from throttling takes **~84 s** and nothing is released during the first 60 s. Leave at least 2 minutes of quiet between runs. |
| **It only charges to 80 %** | `su -c 'pxtune charge off'`. Check the profile too — **`night` sets 80 % by itself** and does so again on every switch. |
| **zram has a different size than I expect** | Check `/data/adb/pixel_tune/zram.conf`. Without it zram is not touched. The reason for a skip (the OOM guard, `boot_count ≥ 2`, a value out of range) is in the log. |
| **The phone is warm all the time and never cools down** | `su -c 'pxtune doze status'`. If `suspends OK` is 0, something holds a permanent wake lock and the SoC never sleeps — the list of holders is printed right underneath. Section 8. |
| **Termux (or another terminal app) gets killed at random** | Android kills apps that spawn too many "phantom" child processes. The `power.phantom_procs` tweak turns that monitoring off. |
| **The volume long-press does nothing** | `volkeys.log`. The torch needs Termux and the right `TERMUX_UID` in `volkeys.sh` — that uid changes when Termux is reinstalled. |
| **`pxtune` exited with code 1 / 2** | 1 = an argument error (unknown command, profile or preset, a value out of range). 2 = a runtime error (a write failed, `settings`/`cmd` is missing, the selftest found missing paths). |
| **Something is broken and I do not know what** | `su -c 'pxtune revert'` and `su -c 'pxtune tweak reset-all'`. Both restore stock and delete nothing. |
| **A banking app stopped working** | `pxtune revert` → uninstall → reboot → test. By design it should not happen; the first suspect is something else. |

### Two traps you will fall into when writing your own script

Both are verified on this device and both look like working code.

#### 1. The numeric `thermal_zoneN` and `cooling_deviceN` indices change on every reboot

This is not a theoretical possibility, it is measured:

| What | Before the reboot | After the reboot |
|---|---|---|
| `soc_therm` | `thermal_zone11` | `thermal_zone13` |
| `battery` | `thermal_zone16` | `thermal_zone12` |
| `thermal-cpufreq-2` | `cooling_device12` | `cooling_device11` |

**A hard-coded index therefore reads a completely different sensor after a
restart** — and nothing about it shows: the script happily keeps printing
numbers. They are just numbers of something else.

`pxtune` therefore **does not hard-code the numbers**: at startup it walks
`/sys/class/thermal/*` and recognises both the zones and the cooling devices **at
runtime by the `type` field**. When writing your own script, **do the same** — or
use Google's stable symlinks, which is simpler:

```sh
/dev/thermal/tz-by-name/quiet_therm/temp
/dev/thermal/cdev-by-name/thermal-cpufreq-2/cur_state
```

#### 2. `read -r v < /proc/sys/vm/swappiness` returns `4` instead of `40`

Yes, really. **Truncated at the first byte.**

```sh
cat  /proc/sys/vm/swappiness                    # 40
read -r v < /proc/sys/vm/swappiness; echo "$v"  # 4   ← WRONG
```

The cause: procfs sysctl reports `st_size=0`, so mksh has no way to determine the
length and reads **byte by byte**, stopping sooner than it should.

**Only `/proc/sys/*` is affected.** On `/sys/...`, `/proc/uptime` and
`/proc/<pid>/stat` the `read` works correctly — which is why it escapes attention
so easily:

| Path | `cat` | `read` |
|---|---|---|
| `/proc/sys/vm/swappiness` | `40` | `4` ✗ |
| `/proc/sys/kernel/sched_util_clamp_min` | `1024` | `1` ✗ |
| `/sys/class/thermal/.../temp` | `63000` | `63000` ✓ |

**Use `cat` or `head -n1`.** In `pxtune` all reading therefore goes through the
`rd()` function, which uses `head -n1`. It is deliberately uniform for all paths:
`backup/stock.conf` is generated from these values and a truncated value would
write e.g. `swappiness=4` instead of `40` during a revert.

Two more measured constants that shape the code: **a fork costs ~7.7 ms**, a
builtin read from sysfs 0.44 ms and a write to sysfs 27-31 ms. That is why the
hot paths avoid forks, why `pxtune-tweaks` is sourced lazily and why the tweak
JSON for the WebUI is emitted without escaping.

---

## 12. A complete revert to the original state

The order matters — the module is uninstalled **last**, and on a **fully booted
system** (otherwise the resolution will not be restored).

### 1. Restore the runtime values to stock

```sh
su -c 'pxtune revert'
su -c 'pxtune tweak reset-all'
```

`revert` replays the snapshot from `backup/stock.conf`: uclamp (including
`camera-daemon` and `nnapi-hal`), the GPU (min → max → policy, in that order so
the values do not block each other), the vendor scheduler, the governor
tunables, vm, the I/O readahead, the thermal profiles, `charge_stop_level` and
`charge_start_level`, and **the display including DPI 353**.
`tweak reset-all` replays `backup/tweaks.stock` — tweaks are **not** part of
`revert`.

### 2. Check the display

```sh
adb shell settings get global display_size_forced      # expected: null / empty
adb shell settings get secure display_density_forced   # expected: 353
```

If it does not match:

```sh
adb shell settings delete global display_size_forced
adb shell settings put secure display_density_forced 353
```

**Do not use `pxtune res reset`** — that one sets 420.

### 3. Check charging

```sh
su -c 'cat /sys/devices/platform/google,charger/charge_stop_level'   # 100
su -c 'cat /sys/devices/platform/google,charger/charge_start_level'  # 0
```

### 4. Restore Game Mode for the apps you changed it for

`pxtune revert` **does not restore this** — Game Mode is a system per-app setting
outside the module. For each package separately:

```sh
su -c 'pxtune game <PACKAGE>'                              # what is set
cmd game set --downscale disable <PACKAGE>
cmd game mode standard <PACKAGE>
```

### 5. Decide about zram, the profiles and the rules

`uninstall.sh` **does not delete** `/data/adb/pixel_tune/`. You keep the profiles,
`backup/stock.conf`, `backup/tweaks.stock`, the per-app rules, `zram.conf`, the
metrics and the log — deliberately, so you do not lose them on a reinstall or a
module update.

If you really want zero, create this **before** uninstalling:

```sh
su -c 'touch /data/adb/pixel_tune/PURGE'
```

> **Warning:** that also deletes `backup/stock.conf`. While it exists you can
> return to stock even after a reinstall. Without it a new `pixel_tune` takes its
> snapshot **from the current state** — and when that current state is not stock,
> it stores as "stock" something that is not. **Only use `PURGE` when you know
> everything is in order.**

### 6. Uninstall the module

KernelSU-Next manager → Modules → `Pixel Tune` → Uninstall → **reboot**.

`uninstall.sh` drops `DISABLE`, runs `revert` and `res reset` and cleans up the
runtime files (`boot_count`, `res_pending`, `manual_override`). You did steps 1-4
so as not to depend on which phase `uninstall.sh` runs in — in the post-fs-data
phase neither `settings` nor `cmd` works for it.

**Careful:** `uninstall.sh` calls `pxtune res reset`, so you may be left with
**DPI 420** after the uninstall. Check step 2 again after the reboot.

### 7. Verification after a reboot

```sh
adb shell getenforce                                   # Enforcing
adb shell cat /sys/block/zram0/comp_algorithm          # the active one must be [lz77eh]
adb shell cat /sys/block/zram0/disksize                # 3969961984  (3.70 GiB)
adb shell cat /proc/sys/vm/swappiness                  # 60   (cat, not read — see section 11)
adb shell settings get secure display_density_forced   # 353
adb shell cat /sys/class/power_supply/battery/cycle_count
```

zram returns to the vendor stock **by itself on the first boot without the
module** — the size is not persistent and `post-fs-data.sh` no longer runs.

---

## Open points in this version

Things that remain unresolved, because there is nothing to verify them against:

1. **The name of the installation ZIP** is stated nowhere in the module files and
   there is no `customize.sh`.
2. **Per-app layers 2 and 3 have no trigger** since the daemon was removed —
   `app enter` / `app leave` exist but nothing calls them on a foreground change.
   Either something has to call them, or those keys should go. Section 6.
3. **`pxtune auto` and the daemon cleanup in `uninstall.sh` are dead code.**
   Harmless, but misleading.
4. **The thermal `game` profile is unverified** and no profile sets it. The
   verification procedure: after ~150 s of load, compare `scaling_cur_freq` on
   policy4/policy8 against the measured 910000 / 1164000.
5. **The effect of `GPU_POWER_POLICY`** (`coarse_demand` vs `adaptive` vs
   `always_on`) **on power draw is not measured.**
6. **There is no GPU measurement under sustained load** — the measured 150 s were
   CPU-only, so the GPU caps in `powersave`/`night`/`pogo` are conservative
   estimates, not derived numbers.
7. **It is not measured whether driving the background onto Little is more
   economical overall** — race-to-idle argues against it and the energy model in
   debugfs is not available on the device.
8. **The stock I/O readahead value is not known** and no I/O measurement exists.
   That is why no profile sets `IO_READAHEAD_KB`.
9. **The 2026-08-13 profile revisions (`powersave`, `balanced`) have not been
   measured over a full day yet.** `pxtune metrics` exists precisely so that they
   can be.
