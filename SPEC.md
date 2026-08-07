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

1. **Nic se nezapisuje do `/system` ani `/vendor`.** pixel_tune nemá žádný overlay.
2. **SELinux zůstává Enforcing.** Žádné `setenforce 0`.
3. **Žádný undervolting** — na Tensoru řídí napětí ACPM firmware, kernel k tomu nemá přístup.
4. **Refresh rate se globálně nesnižuje.** Adaptivní 60–120 Hz zůstává.
5. Vše musí být reversibilní a zálohované.

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
- `scaling_max_freq` má práva **0444, nejde zapsat ani jako root**. Ověřeno. Nepokoušej se o to.
- Číst lze: `scaling_cur_freq`, `scaling_max_freq`, `stats/time_in_state`, `stats/trans_table`.

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
V profilu `game` mají CPU cdev vazby `"Disabled": true` ⇒ **méně CPU throttlingu**.
Prázdný řetězec = default profil.
POZOR: systém si tento prop nastavuje sám (při probu byl už na `camera`). Automat s tím
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
