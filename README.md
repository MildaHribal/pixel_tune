# pixel_tune (Pixel Tune) v1.0

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
The `pxtune` CLI is version `1.1.0`.

---

## 1. What it is and what it does

`pixel_tune` is a KernelSU module that gives you **one place for a set of tuning
levers** that Android does not otherwise expose on this phone:

- **uclamp cgroups** (`/dev/cpuctl/*/cpu.uclamp.{min,max}`) — the main lever on
  CPU performance and power draw. It either lets processes ramp up to a higher
  frequency sooner (snappiness) or caps their utilisation (cooling).
- **The Mali GPU** — `scaling_max_freq`, `scaling_min_freq`, `power_policy`.
- **The thermal HAL profile** — `vendor.thermal.<SENSOR>.profile`.
- **vm tuning** — `swappiness`, `dirty_ratio`, `dirty_background_ratio`,
  `vfs_cache_pressure`, `page-cluster`.
- **I/O readahead** on `sda`-`sdd`.
- **The zram size** (optional, see section 9 — **the algorithm is never changed**).
- **The charge cap** — `charge_stop_level`.
- **Display resolution and density** — with a safeguard against being stuck on an
  unreadable screen.
- **Android Game Mode** — a wrapper around the system `cmd game` (per-app, no hacks).
- **State readout** — temperatures from the thermal zones, frequencies, the current
  throttling from the cooling devices, zram, the battery.

And above all: **everything is reversible.** On the first run a snapshot of the
stock values is taken into `backup/stock.conf`, and `pxtune revert` returns to it
at any time.

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
├── bin/pxtune                    # the CLI core (POSIX sh)
├── bin/pxtune-auto               # the adaptive daemon (event-driven, see section 6)
└── webroot/index.html            # the WebUI

/data/adb/pixel_tune/             # state — SURVIVES uninstall and reinstall
├── profiles/{powersave,balanced,performance,game,night}.conf
├── backup/stock.conf             # the snapshot of stock values (created once)
├── active                        # the name of the active profile
├── auto                          # "on" / "off" — the adaptive daemon switch
├── auto.conf                     # optional, overrides the daemon's constants
├── pxtune-auto.pid               # the pid of the running daemon
├── pxtune-auto.fifo              # the daemon's event pipe
├── pxtune-auto.lock              # a lock against two daemon instances
├── appstats                      # the learned app classification (the daemon)
├── appstats.override             # a manual app classification, takes precedence
├── manual_override               # exists = the daemon does not overwrite the profile
├── boot_count                    # bootloop protection
├── display_state                 # a resolution cache for `status --json` (no binder)
├── zram.conf                     # optional, only ZRAM_DISKSIZE (see section 9)
├── DISABLE                       # exists = the module turns itself off at boot
├── res_pending                   # waiting for a resolution change to be confirmed
├── PURGE                         # optional, see section 12
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
```

`selftest` walks every path the module uses and prints which ones exist and are
writable. Return code 2 = something is missing.

After a boot, `service.sh` **waits 20 seconds** (`SETTLE=20`) before doing
anything — until then `system_server` is not running and neither `settings` nor
`cmd game` would work. Do not be surprised that the profile is only applied a
little while after you unlock.

> TODO: the exact name of the installation ZIP. It is stated neither in the SPEC
> nor in the module files, and there is no `customize.sh` in the module.

### Coexistence with other modules

Already running on the device: NLSound, TA_utl, hma_oss_zygisk, meta-overlayfs,
pgs, playintegrityfix, susfs4ksu, tricky_store, zygisk-assistant, zygisksu.
`pixel_tune` **has no overlay** — it mounts nothing into `/system` or `/vendor` —
so it does not get in the way of meta-overlayfs or susfs.

### Uninstallation

KernelSU-Next manager → **Modules** → `Pixel Tune` → **Uninstall** → reboot.

`uninstall.sh` takes care of most of the cleanup **by itself**:

1. stops the adaptive daemon (`pxtune-auto stop`, alternatively `SIGTERM` by
   `pxtune-auto.pid`) and cleans up `pxtune-auto.{pid,fifo,lock}` after it,
2. drops `DISABLE` so the module cannot take hold again during this boot,
3. runs `pxtune revert` (uclamp, GPU, vm, I/O, thermal, charging),
4. runs `pxtune res reset` — **but only if the system is already up**,
5. **does not delete the user data in `/data/adb/pixel_tune/`** (the profiles,
   `backup/stock.conf`, the log). It only deletes the runtime files:
   `boot_count`, `res_pending`, `manual_override`.

**Two catches you need to know about:**

- **An uninstall may run in a boot phase where `settings` does not exist.** The
  resolution and DPI are then **not restored** and the script writes that into
  the log. It is therefore better to run `su -c 'pxtune revert'` **by hand before
  uninstalling**, on a running system.
- **`pxtune res reset` sets the DPI to 420, not to your 353.** See section 7 —
  this matters and it is confusing.

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
module, it only cancels its effects. It sets `active=stock` and drops
`manual_override` so the daemon does not immediately write another profile.
**Try this first.**

#### b) The `DISABLE` file — the module must not start at all on the next boot

```sh
su -c 'touch /data/adb/pixel_tune/DISABLE'
```

When this file exists, both `post-fs-data.sh` and `service.sh` **exit
immediately** and do nothing. The module stays installed but is inert.
`service.sh` additionally checks `DISABLE` **once more** after its 20-second
wait — so you can still drop it from the WebUI right after a boot.

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
- `service.sh` **zeroes** it after completing successfully.
- When `post-fs-data.sh` sees `boot_count ≥ 3` (three boots in a row in which
  `service.sh` did not reach its end), **it creates `DISABLE` itself** and does
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
  reinstall**.

### Overview — what each profile actually changes

An empty cell "—" means the profile **does not touch** that group of values (it
stays at stock).

| Profile | uclamp | GPU | thermal profile | charging | vm / I/O |
|---|---|---|---|---|---|
| **balanced** *(default)* | — | — | — | — | — |
| **powersave** | `top-app.max=60`<br>`foreground.max=50`<br>`background.max=30`<br>`system-bg.max=40` | `max=580000` kHz | — | — | — |
| **performance** | `top-app.min=25` | — | — | — | — |
| **game** | `top-app.min=30`<br>`background.max=30`<br>`system-bg.max=40` | — | `game` on CPU-MID<br>and CPU-HIGH | — | — |
| **night** | `top-app.max=50`<br>`foreground.max=35`<br>`background.max=17`<br>`system-bg.max=35` | `max=419000` kHz | — | `charge_stop_level=80` | — |

**No profile changes vm, the I/O readahead or zram.** In all five those keys are
empty — there is no measured basis for them.

### When to use which

| Profile | Description | When |
|---|---|---|
| **balanced** | "Balanced — pure stock, no interventions (default)" | The default state and the reference point you compare the others against. Use it when you have no specific reason for anything else. |
| **powersave** | "Cool — trimmed peak, temperature and battery life first" | When the phone is warm in your hand or you want it to last the day. It trims the **thermal peak in the first tens of seconds of load**, not the sustained performance (that is cut to ~40 % anyway). |
| **performance** | "Snappier balanced — faster ramp-up, ceilings unchanged" | When the phone does not feel slow but "delayed" — a small lag on the first touch. It does not raise ceilings (it cannot), it only shortens the ramp-up. |
| **game** | "Games — stable frame-time, tidy background, GPU unchanged" | Games that run for tens of minutes (Pokémon GO and the like). It aims at stable frame-time and quiet in the background, not at peak performance. **Combine it with Game Mode** — see section 7. |
| **night** | "Night — background kept off the big cores, GPU cut down, charge to 80 %" | The phone lies on a desk or on the night charger. The only profile that **sets the charge cap to 80 % by itself.** |

### Why `balanced` is empty

It is not unfinished, it is a result. The author of the profile went through
every lever and found that for each of them the measured data contains no
evidence that the stock value is wrong:

- **uclamp** — stock is `min=0.00`, `max=max` everywhere (except `nnapi-hal`,
  which has `min=1.00`; that is left alone). Any `uclamp.max < 100` is a loss of
  performance, any `uclamp.min > 0` is more power draw. In a default you want
  neither.
- **CPU caps** — they cannot be set, see section 9.
- **The thermal profile** — the mechanism is **unverified** and the system sets
  that prop itself (during the measurement it was already on `camera`, because
  the camera was running). A default must not cut across that.
- **GPU** — stock `scaling_max_freq` is 890000 kHz, which **is** the hardware
  maximum. There is nowhere up, and down is a loss of performance for no reason.
- **vm** — stock `swappiness=60`, `dirty_ratio=20`, `dirty_background_ratio=10`,
  `vfs_cache_pressure=100`, `page-cluster=0` (that last one is already optimal
  for zram). No measurement shows a problem.
- **I/O readahead** — neither the stock value nor any I/O measurement is known.
- **charge_stop_level** — that is your decision about available capacity, not a
  bug fix.

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
   `powersave` has a cap of `top-app.max=60`, which lies **above** the measured
   40 % steady state: it does not worsen long-term performance, it only removes
   a peak that would be paid for with 84 seconds of throttling anyway.
2. **Floors (`uclamp.min`) stay BELOW 38 %.** `performance` has 25, `game` has
   30. A higher floor would push against the throttling loop and the result would
   be a **permanently throttled, i.e. slower** phone.

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
| 25 | 256 | ~836 MHz |
| 30 | 307 | ~1002 MHz |
| 35 | 358 | ~1170 MHz |
| 40 | 410 | ~1338 MHz |
| 50 | 512 | ~1672 MHz |
| 60 | 614 | ~2005 MHz |

**This is the main reason why the profiles contain these numbers and not others.**

#### The reasoning behind every value that is set

| Profile | Key | Value | Why exactly this much |
|---|---|---|---|
| `powersave` | `top-app.max` | 60 | 60 < 70.8 ⇒ the foreground **never pulls in Prime (X3)**, the largest single heat source. At the same time ~2005 MHz on Big lies far **above** the steady 910 MHz, so it does not worsen long-term performance — it only removes the peak, which costs 84 s of throttling. |
| `powersave` | `foreground.max` | 50 | One step below top-app (~1672 MHz), still above the steady 910 MHz. For non-interactive work, losing the peak is even less noticeable. Also below 70.8 ⇒ no Prime. |
| `powersave` | `background.max` | 30 | **A deliberate compromise without measurements.** 30 is **above** the 17.8 threshold, so the background may use Big — just slowly. A strict ≤ 17 would drive it onto Little, but because of race-to-idle that may consume more energy overall, and `powersave` is a daytime profile where a sync should finish. Anyone wanting it cooler during the day can rewrite it to 17. |
| `powersave` | `system-bg.max` | 40 | 40 % is exactly the level the system holds by itself under load (Prime 1164 MHz = 40 %). So I take nothing from system services that the HAL would not leave them anyway. No lower, so that wakeups and display wake do not suffer. |
| `powersave` | `GPU max` | 580000 | The 5th step from the top, ~65 % of the stock maximum — it cuts off the three most voltage-expensive OPPs. Deliberately conservative: **there is no GPU measurement under load**, so it does not go to the CPU equivalent of 40 % (~376000). |
| `performance` | `top-app.min` | 25 | util 256 > 182 ⇒ the foreground **does not fit on Little**, so the scheduler puts it straight on Big (~836 MHz) — that is the snappiness being sought. And 25 ≪ 70.8 ⇒ the floor **never wakes Prime by itself**. On top of that 25 < the 38 % steady state ⇒ **it does not fight the thermal HAL** and does not raise sustained power draw. |
| `game` | `top-app.min` | 30 | ~1002 MHz on Big ⇒ between frames the render thread does not fall to a low OPP and the next frame does not start from zero. Higher than `performance`, because a gaming load is sustained and predictable. Deliberately **not 38-40+**: that would push against the throttling loop and end with a permanently throttled phone mid-game. |
| `game` | `background.max` | 30 | The main gain during a game: Prime is excluded (30 < 70.8) ⇒ the most expensive core does not burn on background work and does not add heat. A strict ≤ 17 was not chosen — there is no measurement that it would not disturb helper game processes. |
| `game` | `system-bg.max` | 40 | The same logic as in `powersave`. |
| `game` | `thermal profile` | `game` | **The only lever that can move the sustained ceiling** (Big 38 % / Prime 40 % at a mere 58 °C is clearly very conservative). It is set **only here, only temporarily** — and it is an **unverified mechanism**, see section 11. |
| `night` | `top-app.max` | 50 | Insurance for the case where you pick the phone up **before** the daemon switches profiles. ~1672 MHz on Big is still far above the steady 910 MHz, so unlocking and a few taps do not feel broken. Prime excluded. |
| `night` | `foreground.max` | 35 | With the screen off, visible-but-inactive processes are not really serving anything ⇒ ~1170 MHz is plenty. |
| `night` | `background.max` | **17** | **The main lever of the profile.** 17 < 17.8 ⇒ syncs, the JobScheduler and maintenance fit on Little and the scheduler **never has to move them to the big cores**. The cost is small: inside Little that is ~1629 MHz out of 1704 MHz — what is restricted is **placement, not the clock**. |
| `night` | `system-bg.max` | 35 | Considerably more than ordinary background work, and deliberately **allowed on Big** — wakeups, notifications and display wake go through system-background. Driving those onto Little as well would risk a slow phone wake. |
| `night` | `GPU max` | 419000 | ~47 % of the stock maximum. With the screen off the cap touches nothing, but it prevents a random wakeup (widget, notification, AOD) from pulling the GPU to its highest OPP. Not lower (302000/150000) for the same reason as with top-app: the unlock animation at 300 MHz would already be noticeable. **A compromise, not a measurement.** |
| `night` | `charge_stop_level` | 80 | The battery has **602 cycles**, and night is the only situation where the phone predictably sits on the charger for hours with a full battery — exactly the state that destroys capacity. The write is verified (see section 8). |

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
  it stands race-to-idle (on Little the task runs longer). That is why the strict
  `≤ 17` value is used only in `night`, where completion time does not matter, and
  a looser 30 is left in `powersave`.
- **There is no GPU measurement under sustained load** (the measured 150 s were
  CPU-only). That is why `powersave` does not go to the GPU equivalent of 40 %
  (~376000 kHz) but stays conservatively at 580000 kHz.

### Profile keys — the complete reference

```sh
# mandatory
PROFILE_NAME="balanced"
PROFILE_DESC="Balanced — stock behaviour"

# uclamp (0-100, or "max"; empty = leave alone)
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

# the thermal HAL profile ("game" | "camera" | "" = default)
THERMAL_PROFILE_CPU_MID=""
THERMAL_PROFILE_CPU_HIGH=""

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
and restores them, but **the profile contract does not expose them** — you cannot
touch them through a profile. That is deliberate.

### What uclamp means in practice

| Setting | Effect |
|---|---|
| `uclamp.max < 100` | A cap on utilisation ⇒ the governor reaches for lower frequencies ⇒ **cooling and saving**, but also slower execution. |
| `uclamp.min > 0` | A floor ⇒ the frequency ramps up sooner ⇒ **snappiness**, but higher power draw. |

| cgroup | What runs in it |
|---|---|
| `top-app` | The app currently on your screen. |
| `foreground` | Visible/active things that are not top-app. |
| `background` | Things in the background. A cap is cheapest here — you hardly feel the restriction. |
| `system-background` | System tasks in the background. Wakeups and display wake go through them too — which is why the profiles give them a higher cap than ordinary background work. |

---

## 4. The WebUI

The WebUI is `webroot/index.html`; it opens from the KernelSU-Next manager
(Modules → `Pixel Tune` → WebUI). It reads `pxtune status --json` and the buttons
call the corresponding `pxtune` commands — **the WebUI cannot do anything the CLI
cannot.** When something does not work for you, try the same thing from a shell;
the reason will be in `pxtune log`.

### The header

| Element | What it does |
|---|---|
| **⟳ Refresh** | A manual state read. |
| **⏱ 5 s** | Cycles the automatic refresh interval: **off → 2 s → 5 s → 10 s → 30 s**. The default is 5 s. When the window is hidden, polling stops entirely. |
| The dot + text under the title | The state of the last call (OK / working / error). |

### The "⚠ A resolution change is waiting for confirmation" banner

It appears **only when `res_pending` exists**, with a countdown from 60 s.

| Button | Calls | What it does |
|---|---|---|
| **✓ Confirm** | `pxtune res confirm` | The change stays, the automatic revert is cancelled. |
| **Revert now** | `pxtune res reset` | Does not wait for the countdown, restores the native resolution immediately. |

### The "Profile" card

| Element | Calls | What it does |
|---|---|---|
| The profile tiles | `pxtune profile <name>` | Switches the profile and **sets `manual_override`**. |
| **🤖 Auto** | `pxtune profile auto` | Clears `manual_override` — the daemon controls the profile again. |
| **Daemon: on/off** | `pxtune auto on` / `pxtune auto off` | Starts/stops the adaptive daemon. **See section 6.** |

Mind the difference: **🤖 Auto** gives the daemon back the *right to decide*,
**Daemon** starts/stops the *process itself*. Those are two different things.

### The read-only cards

| Card | What it shows |
|---|---|
| **CPU — throttling** | The current cap vs. the HW maximum for each cluster. Computed from the cooling device state. |
| **Temperatures** | The values from the thermal zones. |
| **GPU (Mali)** | Frequency, utilisation, power policy. |
| **Memory** | zram — size, algorithm, occupancy. |

### The "Battery" card

At the top the state (capacity, temperature, cycles, current). At the bottom the
charge cap control:

| Element | Calls | Note |
|---|---|---|
| The slider | — | Range **50-100 %, step 5**. Dragging alone sets nothing. |
| **Apply** | `pxtune charge <value>` | Active only after you move the slider. |
| **Disable the limit (100 %)** | `pxtune charge off` | Back to stock. |

The CLI also accepts values below 50 (the range is 1-100); the WebUI slider is
deliberately narrower.

### The "Resolution" card

| Element | Calls | What it does |
|---|---|---|
| The preset buttons | `pxtune res <preset>` | Switches the resolution **and starts the 60 s safeguard**. |
| **⤺ Reset to native (1080 × 2400)** | `pxtune res reset` | Restores the native resolution. **It sets the DPI to 420, not to your 353** — see section 7. |

The presets come from `status --json`; when the JSON does not send them, the
WebUI shows the fallback trio `1080p / 900p / 720p`. **`pxtune` does not know
those names though** — the CLI presets are called `native`, `900x2000`,
`810x1800`, `720x1600` (and they also accept the shorthands `900` / `810` /
`720`). Clicking a fallback preset therefore ends with return code 1. See the
TODO at the end.

### The "Danger zone" card

| Element | Calls | What it does |
|---|---|---|
| **↺ Restore everything to stock** | `pxtune revert` | Asks for confirmation. Restores everything from `backup/stock.conf` and clears the active profile. |

### What is NOT in the WebUI

A log viewer and Game Mode controls. Both are CLI-only (`pxtune log`,
`pxtune game`).

---

## 5. The CLI — `pxtune`

`/data/adb/modules/pixel_tune/bin/pxtune`, POSIX sh, runs under
`/system/bin/sh`. **All commands require root** (`su -c '...'`).

### Overview

| Command | What it does |
|---|---|
| `pxtune status` | The state: active profile, temperatures, frequencies, uclamp, zram, charging, `auto`, `res_pending`. |
| `pxtune status --json` | The same as valid JSON (parsed by the WebUI). |
| `pxtune profile list` | List the profiles. |
| `pxtune profile current` | The name of the active profile. |
| `pxtune profile <name>` | Switch profile. **Sets `manual_override`.** |
| `pxtune profile <name> --auto` | The same, but **does not touch `manual_override`**, and when it exists, does nothing (code 0). This is how the daemon switches profiles; you do not need it by hand. |
| `pxtune profile auto` | Clears `manual_override`, hands control back to the daemon. Sends the daemon `SIGHUP` so it re-evaluates the state at once. |
| `pxtune revert` | Restores **EVERYTHING** to stock from `backup/stock.conf`. |
| `pxtune res` \| `res status` \| `res current` | Prints the current resolution, DPI and the `res_pending` state. |
| `pxtune res list` | Lists the presets. |
| `pxtune res <preset>` | Switches the resolution + starts the 60 s safeguard. |
| `pxtune res confirm` | Confirms the change, cancels the safeguard. |
| `pxtune res reset` | A blind return to native 1080×2400 **@ 420 dpi**. |
| `pxtune charge <1-100>` | The charge cap in percent. |
| `pxtune charge off` | Back to 100 %. |
| `pxtune game <package>` | Prints `list-modes` + `list-configs` for the given package. |
| `pxtune game <package> <mode> [--fps N] [--downscale 0.3..0.9\|disable]` | Sets Game Mode. |
| `pxtune auto on` \| `off` \| `status` | The adaptive daemon — writes the state into `auto` **and at the same time** starts/stops the daemon (`pxtune-auto start`/`stop`). See section 6. |
| `pxtune log [-n N]` | The last N lines of the log (default 50). |
| `pxtune selftest` | Verifies all the paths from the SPEC. |
| `pxtune -v` | The version. |
| `pxtune -h` \| `--help` | Help. |

### Resolution presets

| Preset | Resolution | DPI |
|---|---|---|
| `native` | 1080 × 2400 | **420** |
| `900x2000` | 900 × 2000 | 350 |
| `810x1800` | 810 × 1800 | 315 |
| `720x1600` | 720 × 1600 | 280 |

Those are the names `pxtune res list` prints. A preset can also be given by width
alone though — `pxtune res 900`, `810`, `720` work too.
`native` is applied **without a safeguard** (there is nothing to guard against).

### Game Mode modes

| Value | Meaning |
|---|---|
| `1` / `standard` | Standard |
| `2` / `performance` | Performance |
| `3` / `battery` | Battery |
| `4` / `custom` | Custom (combined with `--downscale` / `--fps`) |

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

## 6. The adaptive daemon

### How it is built

`bin/pxtune-auto` **exists and works.** The single source of truth about it being
enabled is the file `/data/adb/pixel_tune/auto` — the CLI, `service.sh` and the
daemon itself all read it.

The key property of the design: **no polling.** The daemon hangs blocked on a
`read()` from a named pipe and **does not run at all** between events. It takes
the events from logd's binary event buffer (`logcat -b events`), not from an
accessibility service:

| Event | Tag | What for |
|---|---|---|
| A foreground app change | `wm_resume_activity` | load classification |
| The display going off/on | `power_screen_state` | switching into/out of `night` |

The daemon **looks the foreground tag name up at runtime** in
`/system/etc/event-log-tags` — since Android R it is called
`wm_resume_activity`; the older `am_resume_activity` no longer exists on A16.

### How it decides

The daemon keeps statistics about every app in `appstats`: it samples the CPU
time of the main process (`/proc/<pid>/stat`) and computes an EWMA in percent of
**one** core.

| Class | Condition | Profile |
|---|---|---|
| `game` | CPU ≥ 150 % **and at the same time** an average session ≥ 90 s | `game` |
| `heavy` | CPU ≥ 80 % | `performance` |
| `normal` | CPU ≥ 20 % | `balanced` |
| `light` | the rest | `powersave` |

Two harder rules sit on top of that:

- **A screen that is off ⇒ always `night`**, regardless of the classification.
- **Skin ≥ 43.0 °C ⇒ temporarily `powersave`.** It is released only at ≤ 41.0 °C
  (2 °C of hysteresis) and no sooner than after 120 s. The threshold is
  deliberately **above** the measured steady state (a skin of 40.5 °C at full load
  on 9 cores) — otherwise the daemon would trip on every normal load.

The classification can be overridden by hand in `appstats.override`
(`<package> <class>`), and the constants can be overridden in `auto.conf`.

### The effect on battery — concretely

This is the important part and it follows from the design:

- **Between events the daemon consumes nothing.** A blocked `read()` is not a
  wakeup.
- **The only timer in the whole daemon is a "ticker" with a 30 s period** — and it
  is enabled **only** when the display is on **and at the same time** a
  `game`/`heavy` app is running, or it is hot, or a postponed switch is pending.
  **When the display goes off it is killed immediately, so there is no alarm at
  all during suspend.**
- Anti-flapping: the profile is never switched more often than once every **30 s**.
  That is deliberately more than the thermal HAL's 7-second control period — the
  daemon should not cut across its control.
- Sampling of an app stops after **20 samples** (the EWMA has long settled), so
  even those few forks diminish over time.

### How to work with it

```sh
su -c 'pxtune auto status'    # on / off (a missing file = "on")
su -c 'pxtune auto off'       # disable
su -c 'pxtune auto on'        # enable
```

### The manual override

When you switch the profile by hand (`pxtune profile <name>` or a tile in the
WebUI), `/data/adb/pixel_tune/manual_override` is created and **the daemon stops
changing the profile**. Your choice holds until you say otherwise.

To hand control back to the daemon:

```sh
su -c 'pxtune profile auto'
```

`pxtune auto off` **forbids the daemon to switch**; `pxtune profile auto` **gives
it back the right to decide**. Those are two different things and the WebUI has
them as two different buttons.

Strictly speaking: `pxtune auto on|off` only rewrites the file
`/data/adb/pixel_tune/auto`. The daemon reads it before every switch, so with
`off` it keeps observing but changes nothing — **the process however keeps
running.** When you want to really stop it (or conversely start it without
rebooting), use its binary directly:

```sh
su -c '/data/adb/modules/pixel_tune/bin/pxtune-auto status'
su -c '/data/adb/modules/pixel_tune/bin/pxtune-auto stop'
su -c '/data/adb/modules/pixel_tune/bin/pxtune-auto start'
```

Otherwise the daemon is started **only at boot**, from `service.sh`, according to
the contents of the `auto` file (a missing file = enabled).

One more detail: `pxtune profile auto` **does not send the daemon SIGHUP**, so it
does not re-evaluate the state immediately — it does so at the next event (an app
switch, the display going off) or at a tick.

A nice detail: at boot `service.sh` applies the stored profile, but **remembers
`manual_override` beforehand and restores it to its original state afterwards.**
Without that, every reboot would throw you into manual mode — because
`pxtune profile <name>` sets that flag by definition.

### The camera

The system sets the `vendor.thermal.<SENSOR>.profile` prop **by itself** — during
the measurement it was already on `camera`, because the camera was running. The
daemon accounts for that: while the prop is on `camera`, it **postpones the
profile switch** and writes that into the log.

A safeguard for the opposite case: the prop can **stay stuck** on `camera` even
after the camera app is closed (which is exactly what happened during the
measurement). Should it stay that way for longer than **600 s**, the daemon
starts ignoring it and switches anyway — otherwise it would silence itself
permanently.

If the daemon still misbehaves while you take photos, `pxtune auto off` is a
legitimate answer.

### Why the daemon does not control the cooling devices

**The thermal HAL rewrites the cooling devices roughly every 7 seconds.** If the
daemon wanted to use them as a *lever* (and not just to read), it would have to
run in a loop faster than 7 s — and such a loop measurably eats the battery,
which would defeat the whole no-polling construction described above. That is
precisely why the cooling devices are used in pixel_tune **for reading only**,
and control goes through uclamp, which the thermal HAL does not overwrite and
which needs no watchdog.

**A practical recommendation:** if what you mainly want is battery life and you
are willing to switch profiles by hand, **you can leave the daemon off**. A
manual profile + `manual_override` has **zero overhead** — it is written once and
nothing runs afterwards. The daemon makes sense when you do not want to think
about profiles, or when you want the 43 °C thermal safeguard.

> TODO: **the daemon's effect on battery life is not measured.** From the design
> it follows that it is small (no polling, a 30 s ticker only with the display on
> and a demanding app), but nobody has yet done a comparative battery measurement
> with and without it.

---

## 7. Display resolution

> **Read this whole section BEFORE you change the resolution for the first
> time.** It is the one thing in the module that can leave you staring at an
> unusable screen.

### The default state

| Thing | Value |
|---|---|
| The physical panel | 1080 × 2400 |
| `ro.sf.lcd_density` | 420 |
| **Your current density override** | **353** |
| `settings global display_size_forced` | **empty** |
| `settings secure display_density_forced` | **353** |
| Refresh rate | adaptive 60-120 Hz, mode 2 = 120 Hz |

### ⚠ The number 353 vs. 420 — this is the catch

Your phone has its own density override of **353**. The firmware value is 420.

**`pxtune res reset` (and the `native` preset, and the 60-second safeguard, and
the "Revert now" button) sets the DPI to 420, not to 353.** So it gives you back
the right *resolution*, but **a different DPI than you had** — everything will be
a bit smaller.

Your 353 is restored by:

- `pxtune revert` (it takes the value from `backup/stock.conf`), or
- a manual `settings put secure display_density_forced 353`.

**The rule: use `res reset` when you cannot see. Use `revert` when you want
exactly the original state.**

### How to change the resolution

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

### The 60-second safeguard — how it works

1. `pxtune res <preset>` changes the resolution **and at the same time** creates
   `res_pending` with a one-off token.
2. A watchdog starts in the background that **restores the native resolution
   after 60 seconds**.
3. When you confirm within 60 s:

   ```sh
   su -c 'pxtune res confirm'
   ```

   `res_pending` disappears, the watchdog wakes up, finds its token is no longer
   valid and **does nothing**. The change stays.
4. **When you do not confirm** — because you cannot see the display or the UI
   fell apart — after 60 seconds the resolution **returns to 1080×2400 @ 420 dpi
   by itself**. You do not have to do anything. Just wait a minute.

The whole trick is: **when you are not sure, do not confirm.** A failure heals
itself.

The `native` preset does not start the safeguard — there is nothing to guard
against.

### A blind restore over ADB (when you cannot see the UI)

Connect the phone to a computer with `adb` over USB and type blind.

**Step 0 — wait a minute.** Seriously. If you did not confirm the change, the
safeguard solves it by itself.

**Step 1 — the simplest route, no root:**

```sh
adb shell wm size reset
adb shell settings put secure display_density_forced 353
```

The first line cancels the forced resolution. The second restores **your** density
of 353. These commands **do not require root** — they work from an ordinary
`adb shell`, so you do not have to tap through any root prompt on the display
(which you would not see anyway).

**DO NOT USE `wm density reset`** — it would restore 420, not your 353.

**Step 2 — when that was not enough, clear the persistent override directly:**

```sh
adb shell settings delete global display_size_forced
adb shell settings put secure display_density_forced 353
adb reboot
```

**Step 3 — the emergency brake:**

```sh
adb reboot
```

and **hold Volume Down** during startup → KernelSU safe mode → all modules
disabled. Then sort the rest out from a calm state.

> **A warning about `adb shell su -c '...'`:** KernelSU has an allowlist for root
> and the shell need not be on it by default. When `su` from ADB asks for
> approval, you have to tap it **on the display** — which is exactly what you
> cannot do in this scenario. That is why steps 1 and 2 are deliberately written
> so that they do **not need** root.

### Honestly: outside games, lowering the resolution will probably gain you nothing

This is the most common myth and it is fair to break it.

In the measured load test — **150 seconds of full CPU load on all 9 cores** —
**`cdev_gpu` (`cooling_device24`, `thermal-gpufreq-0`) stayed at 0 the whole
time.** Not once did it move. That means **the GPU was not thermally throttled
for a single moment during the entire test.**

The conclusion: **the GPU is not the thermal bottleneck on this phone for
non-gaming loads.** When the GPU is not what slows the phone down or heats it up,
taking pixels away from it buys you nothing. Expect the saving to be
**unmeasurable**, while the image will be noticeably worse. The source of both
heat and the brake here are the CPU clusters — in the same test the cap dropped
to Little ~1036 MHz (61 % of the HW maximum), Big 910 MHz (38 %) and Prime
1164 MHz (40 %).

**For games it is different — and for games, Android Game Mode is the better
tool.** It scales the resolution **per app**, so you do not spoil the system UI or
other apps:

```sh
su -c 'pxtune game com.example.game custom --downscale 0.7 --fps 60'
su -c 'pxtune game com.example.game battery'
su -c 'pxtune game com.example.game'          # prints the current modes and configs
```

It is a system feature, free, with no hacks. **Lowering the global resolution
because of one game makes no sense.**

### Refresh rate

The module **does not lower the refresh rate globally** and will not. See
section 9.

---

## 8. Charging

Your battery has **602 charge cycles**. That is a decent mileage and it is the
main reason this feature is in the module.

### Limiting the cap

```sh
su -c 'pxtune charge 80'     # charge only to 80 %
su -c 'pxtune charge off'    # back to 100 %
```

It is written into
`/sys/devices/platform/google,charger/charge_stop_level`. That node has
permissions `0660 system:system`, but **root can write to it** — verified by
writing `80` and returning to `100`.

In the WebUI the slider is **50-100 %, step 5**. The CLI takes the whole 1-100
range.

Or through a profile — **`night` does it by itself**:

```sh
CHARGE_STOP_LEVEL="80"
```

Careful: **a profile sets the cap again on every switch.** If you run
`pxtune charge off` and then switch to `night`, it will be 80 again.

### Why do it

Lithium cells age faster when held at a high voltage. Keeping the phone in a band
around 80 % instead of 100 % slows the degradation of capacity. It is useful
above all when you **charge the phone overnight** or keep it in a dock for a long
time — otherwise it sits at 100 % for hours. That is exactly why 80 % is in the
`night` profile and nowhere else.

The price is straightforward: **a cap of 80 % means you have 80 % of the capacity
available.** When you know a long day is ahead, run `pxtune charge off`.

### Related stock values

| Node | Stock | Note |
|---|---|---|
| `charge_stop_level` | 100 | This is what we change. |
| `charge_start_level` | 0 | When to start charging again. The profiles do not touch it (`revert` does restore it). |
| `bd_trigger_temp` | 350 | Battery Defender: the temperature threshold (35.0 °C). |
| `bd_trigger_time` | 21600 | 6 hours. |
| `bd_recharge_soc` | 79 | |
| `bd_temp_enable` | 1 | |

Google already has its own "battery defender", which partly handles long charging
at 100 % by itself. `pxtune charge` is a more explicit and harder variant of the
same thing.

### Reading the battery state

```
/sys/class/power_supply/battery/capacity      # %
/sys/class/power_supply/battery/status
/sys/class/power_supply/battery/temp
/sys/class/power_supply/battery/cycle_count   # 602
/sys/class/power_supply/battery/current_now
```

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

### `scaling_max_freq` is not set — because it cannot be

`/sys/devices/system/cpu/cpufreq/policy*/scaling_max_freq` has permissions
**0444**. That is read-only **even for root**. Verified.

That is why CPU caps are handled through **uclamp** rather than through
frequencies. It is a more indirect lever (you limit the requested utilisation,
not the frequency), but it is the only one that works and that nobody overwrites.

Reading from cpufreq works normally: `scaling_cur_freq`, `scaling_max_freq`,
`stats/time_in_state`, `stats/trans_table`.

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

That is why the "CPU — throttling" card in the WebUI can be trusted: it is not an
estimate, it is a verified conversion.

### The governor is not changed

All three clusters run `sched_pixel` — a governor tuned by Google and integrated
with the scheduler and with `power-service.pixel-libperfmgr`. Switching to
`schedutil` or anything else breaks the things built on it. **It is left alone.**

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
unusually cheap on this phone. Which is why none of the five profiles changes it.)

**The zram size can be changed** — optionally, via
`/data/adb/pixel_tune/zram.conf`:

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
backwards** and it is worth knowing why:

| Thing | Stock on this device |
|---|---|
| zram size | **3969961984 B (3.70 GiB / 3.97 GB)** |
| zram algorithm | **`lz77eh`** |
| `vm.swappiness` | **60** (written by `/vendor/etc/init/init.pixel-mm-gs.rc`) |

`lz77eh` runs on the **Emerald Hill hardware compression accelerator** built into
Tensor (`/sys/devices/platform/16d00000.eh`, driver `google,eh`), so compression
costs **almost zero CPU and zero heat**. Both `lz4` and `zstd` run **on the CPU**.
Switching to them therefore disconnects compression from the hardware unit and
moves it onto the processor — more power draw, more heat, no compensating
advantage. And shrinking zram on top of that takes away swap, which is unusually
cheap on this device.

`pixel_tune` therefore:

- **never changes the algorithm** (and explicitly restores it after a zram reset),
- changes the zram size **only** when you explicitly ask for it via `zram.conf`,
- has `swappiness` set in **none of the five profiles**.

If you used another kernel manager on the phone before, check after uninstalling
it that both values are back at stock:

```sh
su -c 'cat /sys/block/zram0/comp_algorithm'   # the active one must be [lz77eh]
su -c 'cat /sys/block/zram0/disksize'         # 3969961984
su -c 'cat /proc/sys/vm/swappiness'           # 60
```

### The refresh rate is not lowered globally

The adaptive 60-120 Hz stays (mode 2 = 120 Hz). Dropping to a fixed 60 Hz is a
change you feel on every swipe, and its benefit is not measured on this device.
If you want it, Android has its own "Smooth display" switch in Settings.

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
| `quiet_therm` | **the skin (surface)** — this is the zone the daemon watches | 8 |
| `soc_therm` | the SoC board | 11 |
| `charger_therm` | the charger | 12 |
| `display_therm` | the display | 13 |
| `battery` | the battery | 16 |

> **Again: the last column is not a valid number.** The `thermal_zoneN` indices
> change on every reboot — see section 11. A zone is identified by its `type`,
> not by its number.

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
   150 s — the GPU was not throttled even once. The source of both heat and the
   brake are the CPU clusters, not the graphics. That is why the profiles target
   the **CPU thermal peak**, not the resolution or the GPU (see section 7).
3. **Recovery is slow.** `MaxReleaseStep=1` in the HAL config means releasing one
   step at a time: after the load ends it takes ~84 s before the caps are
   released, and for the first 60 s nothing happens. When measuring the effect of
   a profile with a benchmark, **leave at least two minutes of quiet between
   runs**, otherwise you are measuring residual throttling, not your profile.

---

## 10. Integrity and banking

Factually, without scaremongering and without reassurance.

### What pixel_tune does and does not do

| | |
|---|---|
| Writes into `/system` or `/vendor` | **No.** No overlay and no bind mount. |
| Changes SELinux | **No.** It stays **Enforcing**. No `setenforce 0`. |
| Uses an accessibility service | **No.** |
| Changes build props / the fingerprint (`ro.*`) | **No.** The only prop it touches is `vendor.thermal.<SENSOR>.profile` — a runtime prop of the thermal HAL, not the device identity. |
| Installs an app | **No.** The UI is a WebUI inside the KernelSU manager. |
| Where it writes | `sysfs`, `/dev/cpuctl`, `/proc/sys`, `settings` (resolution and density) and its own `/data/adb/pixel_tune/`. |

### What follows from that

Apart from `charge_stop_level` and the display settings, all the module's
interventions are **runtime values in `sysfs` that a restart wipes.** They leave
no trace in the system image.

**But be realistic:** what detection looks for is **an unlocked bootloader and
root as such**, not this particular module. Those have been on your phone for a
long time. The fact that `pixel_tune` does not write into `/system` means it
**adds no new detection surface** — it does not mean it hides anything.

Hiding is handled by entirely different modules you already have installed:
`playintegrityfix`, `tricky_store`, `susfs4ksu`, `zygisk-assistant`,
`hma_oss_zygisk`. `pixel_tune` **neither competes with them nor replaces them** —
it does nothing that would need hiding, and nothing that would disrupt their work.

When a banking app stops working after installing pixel_tune, **the first suspect
is something else** (a Play Integrity update, a change in `tricky_store`, an
update of that app). But do verify it: `pxtune revert`, uninstall the module,
reboot, try again. If the problem disappears, that is a finding — by design it
should not happen.

---

## 11. Troubleshooting

| Symptom | What to do |
|---|---|
| **The phone does not boot / bootloop** | Hold **Volume Down** during startup → KernelSU safe mode. Note: after **three** failed boots the module disables **itself** via `boot_count`. |
| **I cannot see the display after a resolution change** | **Wait 60 seconds** — the safeguard restores the native resolution by itself. If not: `adb shell wm size reset` + `adb shell settings put secure display_density_forced 353`. See section 7. |
| **The resolution came back, but the text is smaller than before** | That is expected. `res reset` and the safeguard set the DPI to **420**, not to your **353**. Fix: `su -c 'pxtune revert'` or `settings put secure display_density_forced 353`. |
| **A profile "was not applied"** | `su -c 'pxtune log -n 50'`. Every write is logged as `old → new`; on an error it carries on, so the reason is always in the log. Then `su -c 'pxtune selftest'`. |
| **The profile is applied late after a boot** | That is how it should be. `service.sh` waits **20 s** (`SETTLE=20`), because `system_server` is not running before that. |
| **`pxtune: not found`** | The module is not active. Check that `/data/adb/modules/pixel_tune/` exists, that there is **no** `DISABLE` in it, and that the phone is not in safe mode. |
| **The adaptive daemon does not work / does not start** | `su -c 'pxtune auto status'` → it must say `on` **and** print a pid. When it is not running, look for `[auto]` lines in the log. The most common cause: it did not find the foreground or the screen tag in `/system/etc/event-log-tags` — the daemon logs that as `ERROR`, and without the tags it really switches nothing. |
| **The daemon switches profiles when I do not want it to** | `su -c 'pxtune profile <name>'` (without `--auto`) drops `manual_override` and the daemon backs off. To disable it entirely: `pxtune auto off`. |
| **The daemon classified an app wrongly** | The classification is learned in `appstats`. Override it by hand: write a line `<package> <game\|heavy\|normal\|light>` into `appstats.override`. The override takes precedence over the measurement. |
| **A manually chosen profile "does not stick"** | Check that `/data/adb/pixel_tune/manual_override` exists. If not, you ran `pxtune profile auto` at some point. |
| **The phone is hot / stutters while taking photos** | The system switches `vendor.thermal.*.profile` by itself (the camera to `camera`). Do not use the `game` profile, which sets that prop. |
| **The `game` profile changed nothing** | Expected. The `game` thermal profile is an **unverified mechanism**. To verify: after ~150 s of load, compare `scaling_cur_freq` on policy4/policy8 against the measured 910000 / 1164000. If they do not differ, the mechanism does not work and you should empty `THERMAL_PROFILE_*` in `game.conf`. |
| **The module is eating my battery** | Check the profile: `UCLAMP_*_MIN > 0` means higher power draw by definition (`performance` and `game` have it). Switch to `balanced`, `powersave` or `night`. |
| **A benchmark shows worse numbers than last time** | Recovery from throttling takes **~84 s** and nothing is released during the first 60 s. Leave at least 2 minutes of quiet between runs. |
| **It only charges to 80 %** | `su -c 'pxtune charge off'`. Check the profile too — **`night` sets 80 % by itself** and does so again on every switch. |
| **zram has a different size than I expect** | Check `/data/adb/pixel_tune/zram.conf`. Without it zram is not touched. The reason for a skip (the OOM guard, `boot_count ≥ 2`, a value out of range) is in the log. |
| **`pxtune` exited with code 1** | An argument error: an unknown command, profile or preset, or a value out of range (e.g. a GPU frequency not on the allowed list). |
| **`pxtune` exited with code 2** | A runtime error: a write failed, `settings`/`cmd` is missing, or the selftest found missing paths. Details are in the log. |
| **Something is broken and I do not know what** | `su -c 'pxtune revert'`. It restores everything to stock and deletes nothing. |
| **A banking app stopped working** | See section 10. `pxtune revert` → uninstall → reboot → test. |

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
runtime by the `type` field**. The hard-coded indices in the code exist only as a
fallback in case the scan fails.

When writing your own script, **you have to do the same** — or use Google's
stable symlinks, which is simpler:

```sh
/dev/thermal/tz-by-name/quiet_therm/temp
/dev/thermal/cdev-by-name/thermal-cpufreq-2/cur_state
```

#### 2. `read -r v < /proc/sys/vm/swappiness` returns `4` instead of `40`

Yes, really. **Truncated at the first byte.**

```sh
cat  /proc/sys/vm/swappiness   # 40
read -r v < /proc/sys/vm/swappiness; echo "$v"   # 4   ← WRONG
```

> Note: at the time of this measurement the value was 40, not the stock 60 (see
> section 9) — something on the device was overwriting it. That does not affect
> the substance of the trap: the truncation at the first byte happens with any
> value.

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

---

## 12. A complete revert to the original state

The order matters — the module is uninstalled **last**, and on a **fully booted
system** (otherwise the resolution will not be restored).

### 1. Restore the runtime values to stock

```sh
su -c 'pxtune revert'
```

It replays the snapshot from `backup/stock.conf`: uclamp (including
`camera-daemon` and `nnapi-hal`), the GPU (min → max → policy, in that order so
the values do not block each other), vm, the I/O readahead, the thermal profiles,
`charge_stop_level` and `charge_start_level`, and **the display including DPI
353**.

### 2. Turn the daemon off

```sh
su -c 'pxtune auto off'
```

### 3. Check the display

`revert` has already restored it, but verify:

```sh
adb shell settings get global display_size_forced      # expected: null / empty
adb shell settings get secure display_density_forced   # expected: 353
```

If it does not match, fix it by hand:

```sh
adb shell settings delete global display_size_forced
adb shell settings put secure display_density_forced 353
```

**Do not use `pxtune res reset`** — that one sets 420.

### 4. Check charging

```sh
su -c 'cat /sys/devices/platform/google,charger/charge_stop_level'   # 100
su -c 'cat /sys/devices/platform/google,charger/charge_start_level'  # 0
```

### 5. Restore Game Mode for the apps you changed it for

`pxtune revert` **does not restore this** — Game Mode is a system per-app setting
outside the module. For each package separately:

```sh
su -c 'pxtune game <PACKAGE>'                              # what is set
cmd game set --downscale disable <PACKAGE>
cmd game mode standard <PACKAGE>
```

### 6. Decide about zram and the profiles

`uninstall.sh` **does not delete** `/data/adb/pixel_tune/`. You keep the profiles,
`backup/stock.conf`, `auto`, `zram.conf`, the learned `appstats` and the log —
deliberately, so you do not lose them on a reinstall or a module update.

If you really want zero, create this **before** uninstalling:

```sh
su -c 'touch /data/adb/pixel_tune/PURGE'
```

`uninstall.sh` then deletes all of `/data/adb/pixel_tune/` including the profiles
and the backup.

> **Warning:** that also deletes `backup/stock.conf`. While it exists you can
> return to stock even after a reinstall. Without it a new `pixel_tune` takes its
> snapshot **from the current state** — and when that current state is not stock,
> it stores as "stock" something that is not. **Only use `PURGE` when you know
> everything is in order.**

### 7. Uninstall the module

KernelSU-Next manager → Modules → `Pixel Tune` → Uninstall → **reboot**.

`uninstall.sh` kills the daemon itself, drops `DISABLE`, runs `revert` and
`res reset` and cleans up the runtime files (`boot_count`, `res_pending`,
`manual_override`). You did steps 1-5 so as not to depend on which phase
`uninstall.sh` runs in — in the post-fs-data phase neither `settings` nor `cmd`
works for it.

**Careful:** `uninstall.sh` calls `pxtune res reset`, so you may be left with
**DPI 420** after the uninstall. Check step 3 again after the reboot.

### 8. Verification after a reboot

```sh
adb shell getenforce                              # Enforcing
adb shell cat /sys/block/zram0/comp_algorithm     # the active one must be [lz77eh]
adb shell cat /sys/block/zram0/disksize           # 3969961984  (3.70 GiB)
adb shell cat /proc/sys/vm/swappiness             # 60   (cat, not read — see section 11)
adb shell settings get secure display_density_forced   # 353
adb shell cat /sys/class/power_supply/battery/cycle_count
```

zram returns to the vendor stock **by itself on the first boot without the
module** — the size is not persistent and `post-fs-data.sh` no longer runs.

---

## Open points in this version

Things that remain unresolved in the documentation, because there is nothing to
verify them against:

1. **`pxtune res reset` sets DPI 420 instead of your 353.** Section 7. It also
   affects the 60-second safeguard, the WebUI buttons and `uninstall.sh`.
2. **The preset names in the WebUI** (`1080p`/`900p`/`720p`) do not match the CLI
   (`native`/`900x2000`/`810x1800`/`720x1600`). The WebUI fallback is only used
   when `status --json` does not send them — but when it is used, a click ends in
   an error. Section 4.
3. **The name of the installation ZIP** is stated nowhere. Section 2.
4. **The `game` thermal profile is unverified** — the `game.conf` profile sets it
   with an explicit warning and a procedure for verifying it. Section 11.
5. **The daemon's effect on battery life is not measured.** From the design it
   follows that it is small, but a comparative measurement (daemon on vs. off) is
   missing. Section 6.
6. **The stock I/O readahead value is not known** and no I/O measurement exists.
   That is why none of the five profiles sets `IO_READAHEAD_KB`. Section 3.
7. **The effect of `GPU_POWER_POLICY`** (`coarse_demand` vs. `adaptive` vs.
   `always_on`) **on power draw is not measured.** Thematically `coarse_demand`
   would fit the `night` profile, but without a measurement there is no guessing.
   It can be measured. Section 3.
8. **There is no GPU measurement under sustained load** — the measured 150 s were
   CPU-only. That is why the GPU caps in `powersave`/`night` are a conservative
   estimate, not a derived number. Section 3.
9. **It is not measured whether driving the background onto Little is more
   economical overall** — race-to-idle argues against it and the energy model in
   debugfs is not available on the device. That is why `night` has
   `background.max=17` but `powersave` a looser `30`. Section 3.
10. **`pxtune auto on|off` neither starts nor stops the daemon process** — it only
    rewrites the `auto` file. Functionally that is enough (the daemon respects
    it), but the process keeps running. Starting/stopping has to go through
    `pxtune-auto start|stop`. Section 6.
11. **`pxtune profile auto` does not send the daemon SIGHUP**, so it does not
    re-evaluate the state immediately but only at the next event or tick.
    Section 6.
12. **The specific pairs of thermal zone indices before/after a reboot** (e.g.
    `soc_therm` `zone11` → `zone13`) **are not in SPEC.md.** The rule itself —
    that the indices must not be hard-coded and a zone is found by its `type` —
    **is verified in the code** (`resolve_thermal_ids` in `bin/pxtune`), so it
    changes nothing about the recommendation. Section 11.

### Resolved compared to an earlier version of this document

- `bin/pxtune-auto` **now exists and works** (it used to say it was missing).
  Section 6.
- **The mismatch in the name of the daemon's state file is gone** — the CLI,
  `service.sh` and the daemon all read the same `/data/adb/pixel_tune/auto`
  today. Section 6.
- **The effect of uclamp on the Little cluster is no longer unknown** — the
  capacity table is measured (Little 182 / Big 725 / Prime 1024). Section 3.
- **The zram size was corrected** to 3969961984 B = 3.70 GiB / 3.97 GB (the
  earlier "3.79 GB" was wrong). Section 9.
- **The CLI version was corrected** to `1.1.0` (`PXTUNE_VERSION` in
  `bin/pxtune`); the module itself is still `v1.0` per `module.prop`.
- **Figures that cannot be verified in SPEC.md or in the module files were
  removed** — namely the "throttling while idle at a skin of 44.6 °C" table
  (sections 1 and 9) and the specific values attributed to an earlier kernel
  manager (section 9). The technical conclusion of both passages stayed, because
  that part is verifiable.
