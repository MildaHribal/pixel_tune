# pixel_tune — závazná specifikace

Toto je JEDINÝ zdroj pravdy. Všechna čísla níže jsou **naměřená na konkrétním zařízení**,
ne odhadnutá. Nic si nedomýšlej, nic nehádej, nic si nevymýšlej. Když něco potřebuješ
a není to tady, napiš to do svého výstupu jako OTEVŘENOU OTÁZKU — neimprovizuj.

## Zařízení

Google Pixel 8a „akita", SoC Tensor G3 „zuma", kernel 6.1.145-android14-11, Android 16,
8 GB RAM (7753832 kB), SELinux **Enforcing** (nesmí se měnit).
KernelSU-Next, `ksud 3.3.0`, manager `com.rifsxd.ksunext`.

Existující moduly (nesmí se s nimi kolidovat): NLSound, TA_utl, hma_oss_zygisk,
meta-overlayfs, pgs, playintegrityfix, susfs4ksu, tricky_store, zygisk-assistant, zygisksu.

## TVRDÁ OMEZENÍ

1. **Nic se nezapisuje do `/system` ani `/vendor` za běhu.** Modul nepřidává žádný
   thermal/powerhint/vendor overlay. **Jediná vědomá známá výjimka:** modul má
   `system/bin/pxtune` overlay v modulovém `system/` (viz „Vědomá známá výjimka" níže).
2. **SELinux zůstává Enforcing.** Žádné `setenforce 0`.
3. **Žádný undervolting** — na Tensoru řídí napětí ACPM firmware, kernel k tomu nemá přístup.
4. **Refresh rate se globálně nesnižuje.** Adaptivní 60–120 Hz zůstává.
5. Vše musí být reversibilní a zálohované.

**Vědomá známá výjimka k bodu 1 — `system/bin/pxtune`:**
Modul obsahuje jediný soubor v `system/` overlay: `system/bin/pxtune`. Slouží POUZE k tomu,
aby byl příkaz `pxtune` v `PATH` z běžného shellu. **Není to `/vendor`, není to thermal ani
powerhint overlay, neovlivňuje běh systému ani boot** — je to jen wrapper na dosažení CLI.
Riziko je proto minimální a rozpor s bodem 1 je zde dokumentovaný a přijatý.
Alternativa: symlink do adresáře, který už v `PATH` je. Prakticky to ale **teď ponecháme
jako dokumentovanou výjimku — deployment neměníme.** Žádný _další_ overlay se nepřidává.

## Cesty

```
/data/adb/modules/pixel_tune/     # modul (metadata + kód)
├── module.prop
├── post-fs-data.sh
├── service.sh
├── bin/pxtune                    # CLI jádro (POSIX sh, /system/bin/sh)
├── bin/pxtune-auto               # adaptivní démon
└── webroot/index.html            # WebUI

/data/adb/pixel_tune/             # stav, přežívá reinstalaci modulu
├── profiles/{powersave,balanced,performance,game,night}.conf
├── backup/stock.conf             # snapshot stock hodnot (vytvoří se 1×)
├── active                        # jméno aktivního profilu
├── manual_override               # existuje = automat neplete profil
├── boot_count                    # ochrana proti bootloopu
├── DISABLE                       # existuje = service.sh se vypne
├── res_pending                   # čeká na potvrzení změny rozlišení
└── pxtune.log
```

---

## OVĚŘENÁ HARDWAROVÁ FAKTA

### CPU clustery

| Policy | Cluster | CPU | Frekvence (vzestupně, kHz) |
|---|---|---|---|
| policy0 | Little 4×A510 | 0–3 | 324000 610000 820000 955000 1098000 1197000 1328000 1425000 1548000 1704000 |
| policy4 | Big 4×A715 | 4–7 | 402000 578000 697000 712000 910000 1065000 1221000 1328000 1418000 1572000 1836000 1945000 2130000 2245000 2367000 |
| policy8 | Prime 1×X3 | 8 | 500000 880000 1164000 1298000 1557000 1745000 1885000 2049000 2147000 2294000 2363000 2556000 2687000 2850000 2914000 |

- Governor `sched_pixel` na všech — **NEMĚNIT**.
- `scaling_max_freq` — **na tomhle A16 buildu (akita:16/CP1A.260505.005, ověřeno 2026-08-07)
  je zapisovatelný**: práva `-rw-rw-r-- system system` (664) a **zápis DRŽÍ** i po 40 s
  v ustáleném stavu. Ověřeno reverzibilním holds-testem: policy4 zapsáno 1418000,
  policy8 1557000 — oba drží; vráceno na stock 2367000 / 2914000.
  **ALE uzel vlastní power HAL** a přepíše ho při hintu `LAUNCH` (a dalších) — do profilu
  tedy patří jen **s flagem reapply** (jako cooling devices). Není to tichá páka „nastav a zapomeň".
  *(Historická poznámka: dřív / na jiných buildech měl `scaling_max_freq` práva 0444 a zápis
  neprošel ani pod rootem. To NA TOMHLE buildu už NEPLATÍ. Původní tvrzení SPEC bylo pravdivé
  pro tehdejší build, ne pro tenhle.)*
- Číst lze vždy: `scaling_cur_freq`, `scaling_max_freq`, `stats/time_in_state`, `stats/trans_table`.

**`sched_pixel/limit_frequency` — přímý zapisovatelný strop taktu (ověřeno 2026-08-07).**
Vedle read-only obchvatu přes uclamp je tohle **první přímá páka na takt.**

| Path | Cluster | Stock (kHz) | Práva |
|---|---|---|---|
| `…/policy0/sched_pixel/limit_frequency` | Little | 1328000 | 644 root:root |
| `…/policy4/sched_pixel/limit_frequency` | Big/Mid | 1836000 | 644 root:root |
| `…/policy8/sched_pixel/limit_frequency` | Prime | 2363000 | 644 root:root |

Ověřeno přímým zápisem (policy8 testováno naživo). Cesta:
`/sys/devices/system/cpu/cpufreq/policyN/sched_pixel/limit_frequency`.
**Také vlastněno power HALem** (zvedá při LAUNCH) ⇒ do profilu jen **s flagem reapply.**

### Cooling devices (zapisovatelné 0644, ALE vlastní je thermal HAL)

| Node | Typ | max_state | Cluster |
|---|---|---|---|
| `/sys/class/thermal/cooling_device8` | thermal-cpufreq-0 | 9 | policy0 |
| `/sys/class/thermal/cooling_device10` | thermal-cpufreq-1 | 14 | policy4 |
| `/sys/class/thermal/cooling_device12` | thermal-cpufreq-2 | 14 | policy8 |
| `/sys/class/thermal/cooling_device24` | thermal-gpufreq-0 | 12 | GPU |

**Ověřený převod:** `cur_state = N` ⇒ strop je frekvence na indexu `(počet_frekvencí - 1 - N)`
ve vzestupném seznamu výše.
Příklad: policy8, `cur_state=2` ⇒ index 12 ⇒ 2687000 kHz. `cur_state=12` ⇒ index 2 ⇒ 1164000 kHz.

**DŮLEŽITÉ: thermal HAL tyto hodnoty přepisuje zhruba každých 7 s.**
Proto je **NEPOUŽÍVEJ** jako hlavní páku pro profily — vyžadovalo by to watcher smyčku,
která žere baterii. Používej je jen pro ČTENÍ (zobrazení aktuálního throttlingu).

### uclamp cgroups — TOHLE JE HLAVNÍ PÁKA

Zapisovatelné 0644, **thermal HAL je nepřepisuje**. Škála 0–100 (float, `max` = 100).

```
/dev/cpuctl/top-app/cpu.uclamp.{min,max}
/dev/cpuctl/foreground/cpu.uclamp.{min,max}
/dev/cpuctl/background/cpu.uclamp.{min,max}
/dev/cpuctl/system-background/cpu.uclamp.{min,max}
/dev/cpuctl/camera-daemon/cpu.uclamp.{min,max}
/dev/cpuctl/nnapi-hal/cpu.uclamp.{min,max}
```

Stock hodnoty: všude `min=0.00`, `max=max`, kromě `nnapi-hal` které má `min=1.00`.

- `uclamp.max < 100` = strop na utilizaci ⇒ governor sáhne po nižších frekvencích ⇒ **chlazení**
- `uclamp.min > 0` = podlaha ⇒ rychlejší náběh frekvence ⇒ **svižnost** (za cenu spotřeby)

**POZOR:** `/proc/sys/kernel/sched_util_clamp_min` je globální STROP na to, jakou
`uclamp.min` smí kdokoli požádat. Stock je 1024 a **musí tak zůstat**. Nastavení na 0
by zakázalo uclamp boost v celém systému včetně Googlího `power-service.pixel-libperfmgr`.
NESAHAT.

### /proc/vendor_sched — DRUHÉ, nezávislé uclamp rozhraní (ověřeno 2026-08-07)

Vedle `/dev/cpuctl` existuje druhé uclamp rozhraní `/proc/vendor_sched/`, **škála 0–1024**
(ne 0–100 jako cpuctl!). **Hodnoty z obou zdrojů se AGREGUJÍ a platí ta PŘÍSNĚJŠÍ.**

Skutečná sada **13 skupin** (probe): `bg cam cam_power dex2oat fg fg_wi nnapi ota rt sf sys
sys_bg ta`. Každá má `groups/<skupina>/uclamp_min`, `uclamp_max`, `prefer_idle`, `prefer_high_cap`.

Klíčové stock hodnoty (ověřeno):

| Uzel | Stock | Poznámka |
|---|---|---|
| `groups/bg/uclamp_max` | **130** | = 12,7 % (0–1024). Už pod prahem Little 182/1024 = 17,8 % ⇒ **`UCLAMP_BG_MAX` v /dev/cpuctl je no-op** (vendor už drží pozadí přísněji). |
| `groups/ta/uclamp_min` | 1 | top-app podlaha |
| `groups/fg/uclamp_min` | 0 | foreground podlaha |
| `groups/nnapi/uclamp_min` | 225 | |
| `groups/ta/prefer_idle` | false (0) | |
| `/proc/vendor_sched/dvfs_headroom` | **1100** | per-CPU vektor `×9`; zápis skaláru vrací vektor. 1100/1024 = 107,4 % přestřelení governoru. |
| `/proc/vendor_sched/util_threshold` | `2048 2048 2048 2048 1280 1280 1280 1280 1280` | per-CPU |
| `/proc/vendor_sched/reduce_prefer_idle` | **true** | (registr v2 mylně tvrdil 0) |
| `/proc/vendor_sched/tapered_dvfs_headroom_enable` | 0 | |
| `/proc/vendor_sched/uclamp_max_filter_enable` | 1 | |

Všechny výše jsou zapisovatelné. `groups/bg/uclamp_max` a `dvfs_headroom` **vlastní power HAL**
(zvedá při LAUNCH: bg→512, headroom→1280) ⇒ reapply, resp. bezpečné jen pro `night`
(zhasnutý displej, žádné LAUNCH hinty).

### GPU Mali

`/sys/class/misc/mali0/device/`

- `scaling_max_freq` — **zapisovatelné a DRŽÍ** (ověřeno: zapsáno 649000, po 12 s stále 649000).
  Tohle je bezpečná páka pro GPU, na rozdíl od cooling device.
- `scaling_min_freq`, `hint_max_freq`, `power_policy` (`coarse_demand`/`adaptive`/`always_on`)
- `cur_freq`, `utilization`, `time_in_state`
- Frekvence (**sestupně**, kHz): 890000 850000 807000 723000 649000 580000 521000 467000 419000 376000 337000 302000 150000
- Stock `scaling_max_freq` = 890000, `scaling_min_freq` = 150000, `power_policy` = adaptive

### Thermal

- 28 zón. Zóny `BIG/MID/LITTLE/G3D/ISP/TPU/AUR` mají `mode=disabled` ⇒ jejich sysfs
  trip pointy jsou **mrtvé**, nesahat na ně, nemá to efekt.
- Reálně throttluje userspace HAL `android.hardware.thermal-service.pixel`
  podle `/vendor/etc/thermal_info_config.json` (ten NEMĚNÍME).

**Škrcení řídí VÝHRADNĚ teplota POVRCHU (skin), NE junction (ověřeno z /vendor 2026-08-07).**
Junction zóny (`BIG/MID/LITTLE`) mají `mode=disabled` právě proto — pro throttling se nepoužívají.
Rozhoduje sada VIRTUAL-SKIN senzorů, každý s `TriggerSensor: soc_therm`. Reálné prahy čtené
z `/vendor` na TOMHLE zařízení (°C):

| Senzor | HotThreshold (°C) | Hystereze |
|---|---|---|
| `VIRTUAL-SKIN-CPU-MID` | 39,0 / 41,0 | 1,9 |
| `VIRTUAL-SKIN-CPU-HIGH` | 41,0 / 43,0 / 52,0 | 1,9 |
| `VIRTUAL-SKIN-CPU-LIGHT-ODPM` | 37,0 / 39,0 | 1,9 |
| `VIRTUAL-SKIN-GPU` | 43 / 45 / 46,5 / 52 | 1,9 |

Trigger senzor `soc_therm`: `HotThreshold 36,0`, `PollingDelay 60000` (ms), `PassiveDelay 7000` (ms).

**Důsledek pro „5minutový slepý bod" (populární XDA mýtus):** VIRTUAL-SKIN senzory sice mají
`PollingDelay 300000`, ale přepočítají se pokaždé, když se ozve `soc_therm`. A `soc_therm` je
při jakékoli zátěži nad 36 °C během chvilky ⇒ přepíná z 60 s na 7 s pollingu. **Reálná expozice
throttlingu je tedy prvních ~60 s od studeného startu, ne 5 minut.** 300s hodnota se v praxi
skoro nikdy neuplatní. Snižovat `PollingDelay` má smysl jen u `soc_therm` — a to vyžaduje
overlay do `/vendor` (tvrdé omezení č. 1) ⇒ NEDĚLÁME.

Indexy zón pro čtení teplot (`/sys/class/thermal/thermal_zoneN/temp`, milicelsia):

| Zóna | Index | Význam |
|---|---|---|
| BIG | 0 | junction Big clusteru |
| MID | 1 | junction Mid |
| LITTLE | 2 | junction Little |
| G3D | 3 | junction GPU |
| quiet_therm | 8 | skin |
| soc_therm | 11 | SoC board |
| charger_therm | 12 | nabíječka |
| display_therm | 13 | displej |
| battery | 16 | baterie |

Virtuální senzory (VIRTUAL-SKIN*) se čtou přes `dumpsys thermalservice` — musí se volat
jako `shell`, **ne přes `su`** (pod su visí na binderu).

**Přepínání thermal profilů:** `setprop vendor.thermal.<SENZOR>.profile <game|camera|"">`
Profily `game` a `camera` existují pro `VIRTUAL-SKIN-CPU-MID` a `VIRTUAL-SKIN-CPU-HIGH`.
Prázdný řetězec = default profil.

**Profil `game` je DOLOŽENÝ i na tomhle A16 buildu (ověřeno z /vendor 2026-08-07 — zavírá
otevřenou otázku č. 4).** V thermal configu má u obou senzorů (`VIRTUAL-SKIN-CPU-MID`
i `-CPU-HIGH`) blok `"Mode":"game"` s `"Disabled":true` na `thermal-cpufreq-0/1/2`:

```
"Profile": [ { "Mode": "game", "BindedCdevInfo": [
    { "CdevRequest": "thermal-cpufreq-0", "Disabled": true },
    { "CdevRequest": "thermal-cpufreq-1", "Disabled": true },
    { "CdevRequest": "thermal-cpufreq-2", "Disabled": true } ] } ]
```

Nastavením obou propů na `game` tedy **vypneš CPU škrcení ze 2 ze 4 senzorů**, které ho
způsobují. Zbývají aktivní: `VIRTUAL-SKIN-CPU-LIGHT-ODPM` (37/39 °C) a `VIRTUAL-SKIN-GPU`
(43/45/46,5/52 °C). `game` tedy neznamená „žádné škrcení", ale „škrcení jen podle
LIGHT-ODPM a GPU" — což je výrazně volnější než stock.

POZOR: vypnutím dvou senzorů se telefon **skutečně ohřeje víc** — teplotní pojistka ze skinu
se stává zodpovědností modulu (viz `THERMAL_PROFILE_MAX_SKIN` v kontraktu v2 níže).
POZOR 2: systém si tento prop nastavuje sám (při probu byl už na `camera`). Automat s tím
musí počítat a nesmí systému skákat do řízení, když běží kamera.

**Naměřené stock chování při trvalé zátěži** (150 s, 9 jader):
- Little strop ~1036 MHz (61 % HW maxima), Big 910 MHz (38 %), Prime 1164 MHz (40 %)
- při junction jen 58 °C a skin 40,5 °C
- špička junction v prvních ~40 s: 81 °C
- **zotavení: `MaxReleaseStep=1` ⇒ ~84 s; 60 s po konci zátěže se NIC neuvolnilo**

### Nabíjení

`/sys/devices/platform/google,charger/`
- `charge_stop_level` (0660 system:system, **root zapsat MŮŽE** — ověřeno zápisem 80, vráceno na 100)
- `charge_start_level` (stock 0)
- Stock: stop=100, start=0
- Další: `bd_trigger_temp` (350), `bd_trigger_time` (21600), `bd_recharge_soc` (79), `bd_temp_enable` (1)
- Stav baterie: `/sys/class/power_supply/battery/{capacity,status,temp,cycle_count,current_now}`
- Baterie má **602 cyklů**.

### Paměť

- zram0: **stock po bootu = 3969961984 B (3,70 GiB / 3,97 GB) s algoritmem `lz77eh`**
  `lz77eh` používá **hardwarový kompresní akcelerátor Emerald Hill** v Tensoru
  (`/sys/devices/platform/16d00000.eh`, driver `google,eh`) ⇒ komprese stojí ~0 CPU a ~0 tepla.
  **NIKDY nepřepínat na zstd ani lz4** — ty běží na CPU a jsou horší.
- `/sys/block/zram0/{disksize,comp_algorithm,reset,mm_stat}`
- `swapoff` za běhu je **nebezpečný** (riziko OOM) ⇒ změny zramu jen v `post-fs-data.sh`,
  kde je swap prázdný.
- vm stock: `swappiness=60` (píše `/vendor/etc/init/init.pixel-mm-gs.rc`), `dirty_ratio=20`,
  `dirty_background_ratio=10`, `vfs_cache_pressure=100`, `page-cluster=0` (už optimální pro zram).

### Displej

- Fyzicky 1080×2400, `ro.sf.lcd_density=420`, aktuální override density **353**
- Perzistence: `settings put global display_size_forced "<W>,<H>"`,
  `settings put secure display_density_forced <dpi>`
- `global display_size_forced` je teď **prázdný**, `secure display_density_forced` = 353
- Adaptivní 60–120 Hz, mode 2 = 120 Hz. **Globálně nesnižovat.**

### Game Mode (systémový, per-app, zdarma)

```
cmd game mode [1|2|3|4|standard|performance|battery|custom] <PACKAGE>
cmd game set --downscale [0.3..0.9|disable] --fps <N> <PACKAGE>
cmd game list-modes <PACKAGE>
cmd game list-configs <PACKAGE>
```

---

## VÝKON — naměřené ceny operací (POVINNÉ ČÍST PŘED ÚPRAVOU KÓDU)

WebUI volá modul přes **synchronní** most, takže každá zbytečná milisekunda je vidět
jako zamrznutí. Naměřeno přímo na tomhle zařízení (Little přiškrcený na 610 MHz):

| operace | cena | poznámka |
|---|---|---|
| `printf` | **17,0 ms** | ⚠️ **NENÍ builtin** — je to `/system/bin/printf`, tedy fork! |
| `$(...)` subshell | 7,7 ms | každá substituce |
| `head`/`sed`/`grep`/`wc`/`date` | ~7–8 ms | fork |
| `echo` | ~0 ms | builtin |
| `print -r --` | ~0,25 ms | builtin, raw (neinterpretuje `\`) |
| akumulace do proměnné | ~0 ms | |
| builtin `read` ze sysfs | 0,44 ms | |
| **zápis** do sysfs | 27–31 ms | inherentní, kernel |

**Z toho plynou závazná pravidla:**

1. **Nikdy `printf` v horké cestě.** Používej `print -r --` (s novým řádkem) nebo
   `print -rn --` (bez). `echo` je taky builtin, ale interpretuje zpětná lomítka.
2. **JSON a delší výstupy akumuluj do proměnné** a vypiš jedním `print`.
3. **Nečti přes `$(...)`.** Používej helpery, které nastavují globální proměnnou:
   `rdv <cesta> <default>` → `V`, `nv` (normalizace na JSON číslo), `tempv`, `capv`,
   `bracketv`, `strv`, `stock_getv` → `SV`, `uclamp_keyv` → `UK`, `kvload <soubor> <prefix>`.
4. **Konfiguráky načítej jednou** přes `kvload` do proměnných, ne opakovaným `sed`/`grep`.

**Dosažený výsledek** (před → po):

| | před | po |
|---|---|---|
| `status --json` | 9 700 ms | **200 ms** |
| `profile <name>` | 13 250 ms | **610 ms** |
| `revert` | 8 350 ms | **810 ms** |

## KONTRAKT: formát profilu

Profil je soubor `KEY=VALUE`, sourcovatelný v POSIX sh. Neznámé klíče se **ignorují**
(dopředná kompatibilita). Prázdná hodnota nebo chybějící klíč = **nesahat na to**.

```sh
# povinné
PROFILE_NAME="balanced"
PROFILE_DESC="Vyvážený — stock chování"

# uclamp (0-100, nebo "max"; prázdné = nesahat)
UCLAMP_TOPAPP_MIN=""
UCLAMP_TOPAPP_MAX=""
UCLAMP_FG_MIN=""
UCLAMP_FG_MAX=""
UCLAMP_BG_MIN=""
UCLAMP_BG_MAX=""
UCLAMP_SYSBG_MIN=""
UCLAMP_SYSBG_MAX=""

# GPU (kHz, musí být z povoleného seznamu; prázdné = nesahat)
GPU_MAX_FREQ=""
GPU_MIN_FREQ=""
GPU_POWER_POLICY=""      # coarse_demand | adaptive | always_on

# thermal HAL profil ("game" | "camera" | "" = default)
THERMAL_PROFILE_CPU_MID=""
THERMAL_PROFILE_CPU_HIGH=""

# vm
VM_SWAPPINESS=""
VM_DIRTY_RATIO=""
VM_DIRTY_BG_RATIO=""
VM_VFS_CACHE_PRESSURE=""

# I/O
IO_READAHEAD_KB=""       # aplikuje se na sda..sdd

# nabíjení
CHARGE_STOP_LEVEL=""     # 1-100
```

### KONTRAKT v2 — nové klíče (ověřený stock z probe 2026-08-07, build akita:16/CP1A.260505.005)

Stejná sémantika jako v1: **prázdná hodnota / chybějící klíč = nesahat.** Neznámé klíče se
ignorují (dopředná kompatibilita). Uzly označené „reapply" vlastní power HAL (přepíše je při
LAUNCH ap.), takže je profil musí periodicky obnovovat, ne nastavit jednou.

```sh
# --- /proc/vendor_sched (škála 0–1024, prázdné = nesahat) ---
VS_TA_UCLAMP_MIN=""     # /proc/vendor_sched/groups/ta/uclamp_min          stock 1
VS_FG_UCLAMP_MIN=""     # /proc/vendor_sched/groups/fg/uclamp_min          stock 0
VS_BG_UCLAMP_MAX=""     # /proc/vendor_sched/groups/bg/uclamp_max          stock 130   (reapply; jediná reálná páka na pozadí — cpuctl BG je no-op)
VS_TA_PREFER_IDLE=""    # /proc/vendor_sched/groups/ta/prefer_idle         stock false/0
VS_DVFS_HEADROOM=""     # /proc/vendor_sched/dvfs_headroom                 stock 1100  (per-CPU vektor; reapply)

# --- sched_pixel governor (reapply — vlastní power HAL) ---
SCHED_LIMIT_FREQ_LITTLE="" # policy0/sched_pixel/limit_frequency          stock 1328000
SCHED_LIMIT_FREQ_MID=""    # policy4/sched_pixel/limit_frequency          stock 1836000
SCHED_LIMIT_FREQ_BIG=""    # policy8/sched_pixel/limit_frequency          stock 2363000
SCHED_DOWN_RATE_MID=""     # policy4/sched_pixel/down_rate_limit_us        stock 500   (POZOR: NE 20000, jak tvrdil registr/research)
SCHED_DOWN_RATE_BIG=""     # policy8/sched_pixel/down_rate_limit_us        stock 500   (POZOR: NE 20000)

# --- devfreq ---
DEVFREQ_MIF_TARGET_LOAD="" # /sys/class/devfreq/…devfreq_mif/interactive/target_load  stock "20 40"  (POZOR: NE "20 80")
DEVFREQ_DSU_MIN=""         # …devfreq_dsu/…/min_freq                       stock 324000 (POZOR: NE 0)
DEVFREQ_MIF_MIN=""         # …devfreq_mif/…/min_freq                       stock 421000 (POZOR: NE 0)

# --- idle (klidová spotřeba) ---
CPUPM_CL1_RESIDENCY=""     # …/cpupm/cpupm/cpd_cl1_target_residency        stock 10000  (POZOR: NE 750000 — klidová residency je z výroby agresivní 10 ms)
CPUPM_CL2_RESIDENCY=""     # …/cpupm/cpupm/cpd_cl2_target_residency        stock 10000  (POZOR: NE 750000; night=100000 by uspával POZDĚJI, opak záměru)

# --- GPU ---
GPU_DVFS_PERIOD=""         # /sys/devices/platform/…mali/dvfs_period       stock 20     (10 = svižnější, 20 = úspornější)

# --- thermal, TVRDĚ HLÍDANÉ ---
THERMAL_CDEV_BYPASS=""     # user_vote_bypass na 3 CPU cdev                stock 0      (riziko 3 — runtime vypínač skin-throttlingu; nikdy default, jen s pojistkou)
                           #   /dev/thermal/cdev-by-name/thermal-cpufreq-{0,1,2}/user_vote_bypass
THERMAL_PROFILE_MAX_SKIN="" # °C — NOVÁ POJISTKA: nad touhle teplotou skinu se THERMAL_PROFILE_*
                           #   NEnasadí a pokud už běží, za běhu se sundá. Chrání před přehřátím,
                           #   když profil `game` vypne 2 ze 4 skin senzorů.
```

**Pozn. ke stock hodnotám:** probe opravil několik dřívějších tvrzení registru/researche —
`down_rate_limit_us` je 500 (ne 20000), `mif target_load` je „20 40" (ne „20 80"),
`dsu/mif min_freq` nejsou 0 (324000 / 421000) a `cpd_clN_target_residency` je **už z výroby
10000 (10 ms)**, ne 750000. To mění záměr night profilu: snižovat residency nemá smysl,
protože je nízká už teď; night by ji naopak měl nechat, nebo řešit jinou pákou.

## KONTRAKT: CLI `pxtune`

POSIX sh, shebang `#!/system/bin/sh`. Musí běžet pod `busybox`/`toybox` na Androidu.
Žádné bashismy (`[[ ]]`, pole, `local` je OK v toyboxu ale radši ne).

```
pxtune status [--json]        # stav: profil, teploty, frekvence, uclamp, zram, nabíjení
pxtune profile list           # seznam profilů
pxtune profile current        # jméno aktivního
pxtune profile <name>         # přepnout (nastaví manual_override)
pxtune profile auto           # zrušit manual_override, vrátit řízení automatu
pxtune revert                 # vrátit VŠE na stock z backup/stock.conf
pxtune res <preset|confirm|reset>
pxtune charge <1-100|off>
pxtune game <package> <mode>  # obálka nad cmd game
pxtune auto <on|off|status>
pxtune log [-n N]
pxtune selftest               # ověří že všechny cesty existují a jsou zapisovatelné
```

- **Každý zápis** jde přes jednu funkci `wr <path> <value>`, která: ověří existenci,
  ověří zapisovatelnost, zaloguje `stará → nová`, a při chybě pokračuje (nikdy neshodí skript).
- `--json` výstup musí být validní JSON (WebUI ho parsuje).
- Exit kód 0 = OK, 1 = chyba argumentů, 2 = chyba běhu.

## KONTRAKT: log

`/data/adb/pixel_tune/pxtune.log`, formát `[YYYY-MM-DD HH:MM:SS] [úroveň] zpráva`.
Rotace při > 512 kB (přejmenovat na `.old`, začít nový).

## Bezpečnost — POVINNÉ

- `post-fs-data.sh` obsahuje **jen zram**. Nic jiného. (Rizikové věci nepatří do rané fáze bootu.)
- `service.sh` dělá zbytek. Pozdní fáze = případná chyba nemůže způsobit bootloop.
- **boot_count**: `post-fs-data.sh` inkrementuje `/data/adb/pixel_tune/boot_count`.
  `service.sh` ho po úspěšném doběhnutí vynuluje. Když `post-fs-data.sh` uvidí hodnotu **≥ 3**,
  vytvoří `DISABLE` a nic neudělá.
- Když existuje `/data/adb/pixel_tune/DISABLE`, `post-fs-data.sh` i `service.sh` **okamžitě skončí**.
- Rozlišení: po změně se vytvoří `res_pending` a naplánuje se návrat na nativní za 60 s,
  pokud nepřijde `pxtune res confirm`.
