# pixel_tune (Pixel Tune) v1.0

Kernel manager pro **Google Pixel 8a („akita", Tensor G3 „zuma")** s KernelSU-Next.

Podklad: kernel `6.1.145-android14-11`, Android 16, 8 GB RAM, `ksud 3.3.0`,
manager `com.rifsxd.ksunext`, SELinux **Enforcing**.
CLI `pxtune` verze `1.1.0`.

---

## 1. Co to je a co to dělá

`pixel_tune` je KernelSU modul, který dává **jedno místo pro sadu ladicích páček**,
které Android na tomhle telefonu jinak nemá vystavené:

- **uclamp cgroups** (`/dev/cpuctl/*/cpu.uclamp.{min,max}`) — hlavní páka na výkon
  a spotřebu CPU. Buď procesům dovolí naskočit na frekvenci rychleji (svižnost),
  nebo jim dá strop na utilizaci (chlazení).
- **GPU Mali** — `scaling_max_freq`, `scaling_min_freq`, `power_policy`.
- **thermal HAL profil** — `vendor.thermal.<SENZOR>.profile`.
- **vm ladění** — `swappiness`, `dirty_ratio`, `dirty_background_ratio`,
  `vfs_cache_pressure`, `page-cluster`.
- **I/O readahead** na `sda`–`sdd`.
- **Velikost zramu** (volitelně, viz sekci 9 — **algoritmus se nikdy nemění**).
- **Strop nabíjení** — `charge_stop_level`.
- **Rozlišení a hustotu displeje** — s pojistkou proti zamrznutí na nečitelném obrazu.
- **Android Game Mode** — obálka nad systémovým `cmd game` (per-app, žádný hack).
- **Čtení stavu** — teploty z thermal zón, frekvence, aktuální throttling z cooling
  devices, zram, baterie.

A hlavně: **všechno je reversibilní.** Při prvním spuštění se udělá snapshot stock
hodnot do `backup/stock.conf` a `pxtune revert` se k němu kdykoli vrátí.

### Proč to vzniklo — konkrétní naměřený problém

Telefon throttluje agresivně a preventivně. **Naměřeno při 150 s trvalé zátěže
na všech 9 jádrech:**

| Cluster | Strop | % HW maxima |
|---|---|---|
| Little (A510) | ~1036 MHz | **61 %** |
| Big (A715) | 910 MHz | **38 %** |
| Prime (X3) | 1164 MHz | **40 %** |

A to všechno při junction jen **58 °C** a skin **40,5 °C** — což není teplotní nouze,
ale konzervativní politika. Špička junction přitom v prvních ~40 s dosáhne **81 °C**.

**Zotavení je navíc pomalé** — thermal HAL má v konfiguraci `MaxReleaseStep=1`, takže
uvolňuje po jednom kroku: trvá to **~84 s** a **60 s po skončení zátěže se neuvolnilo
vůbec nic.**

Z toho plyne celý návrh modulu: nemá smysl honit špičkový výkon (ten je stejně
oříznutý), má smysl **nepouštět telefon do stavu, ze kterého se pak minutu a půl
hrabe zpátky.** Proto profily řežou teplotní špičku, ne ustálený výkon — viz sekci 3.

### Co to fyzicky je

```
/data/adb/modules/pixel_tune/     # modul — smaže se při odinstalaci
├── module.prop
├── post-fs-data.sh               # POUZE bootloop ochrana + volitelný zram
├── service.sh                    # všechno ostatní (pozdní fáze bootu, +20 s)
├── uninstall.sh                  # automatický revert při odinstalaci
├── bin/pxtune                    # CLI jádro (POSIX sh)
├── bin/pxtune-auto               # adaptivní démon (event-driven, viz sekci 6)
└── webroot/index.html            # WebUI

/data/adb/pixel_tune/             # stav — PŘEŽIJE odinstalaci i přeinstalaci
├── profiles/{powersave,balanced,performance,game,night}.conf
├── backup/stock.conf             # snapshot stock hodnot (vytvoří se 1×)
├── active                        # jméno aktivního profilu
├── auto                          # "on" / "off" — přepínač adaptivního automatu
├── auto.conf                     # volitelný, přepisuje konstanty démona
├── pxtune-auto.pid               # pid běžícího démona
├── pxtune-auto.fifo              # událostní roura démona
├── pxtune-auto.lock              # zámek proti dvěma instancím démona
├── appstats                      # naučená klasifikace aplikací (démon)
├── appstats.override             # ruční klasifikace aplikací, má přednost
├── manual_override               # existuje = automat nepřepisuje profil
├── boot_count                    # ochrana proti bootloopu
├── display_state                 # cache rozlišení pro `status --json` (bez binderu)
├── zram.conf                     # volitelný, jen ZRAM_DISKSIZE (viz sekci 9)
├── DISABLE                       # existuje = modul se při bootu vypne
├── res_pending                   # čeká na potvrzení změny rozlišení
├── PURGE                         # volitelný, viz sekci 12
└── pxtune.log  (+ pxtune.log.old)
```

Že jsou to dva oddělené adresáře, je záměr: **odinstaluješ-li modul, tvoje profily
a záloha stock hodnot zůstanou.** Úplně čistý stav viz sekci 12.

---

## 2. Instalace a odinstalace

### Instalace

1. KernelSU-Next manager → **Moduly** → **Instalovat z úložiště** → vyber ZIP modulu.
2. Restartuj telefon.
3. Ověř:

```sh
su -c 'pxtune selftest'
su -c 'pxtune status'
```

`selftest` projde všechny cesty, které modul používá, a vypíše, které existují
a jsou zapisovatelné. Návratový kód 2 = něco chybí.

Po bootu `service.sh` **čeká 20 sekund** (`SETTLE=20`), než začne cokoli dělat —
do té doby neběží `system_server` a `settings` ani `cmd game` by nefungovaly.
Nediv se, že se profil aplikuje až chvíli po odemčení.

> TODO: přesné jméno instalačního ZIPu. Ve SPEC ani v souborech modulu není uvedeno
> a `customize.sh` v modulu není.

### Souběh s ostatními moduly

Na zařízení už běží: NLSound, TA_utl, hma_oss_zygisk, meta-overlayfs, pgs,
playintegrityfix, susfs4ksu, tricky_store, zygisk-assistant, zygisksu.
`pixel_tune` **nemá žádný overlay** — nepřipojuje nic do `/system` ani `/vendor` —
takže s meta-overlayfs ani susfs si nelezou do zelí.

### Odinstalace

KernelSU-Next manager → **Moduly** → `Pixel Tune` → **Odinstalovat** → restart.

`uninstall.sh` se přitom postará o většinu úklidu **sám**:

1. zastaví adaptivního démona (`pxtune-auto stop`, náhradně `SIGTERM` podle
   `pxtune-auto.pid`) a uklidí po něm `pxtune-auto.{pid,fifo,lock}`,
2. položí `DISABLE`, aby se modul v tomhle bootu už nechytil,
3. spustí `pxtune revert` (uclamp, GPU, vm, I/O, thermal, nabíjení),
4. spustí `pxtune res reset` — **ale jen když už systém běží**,
5. **uživatelská data v `/data/adb/pixel_tune/` nemaže** (profily, `backup/stock.conf`,
   log). Maže jen běhové soubory: `boot_count`, `res_pending`, `manual_override`.

**Dva háčky, o kterých musíš vědět:**

- **Odinstalace může běžet ve fázi bootu, kde `settings` neexistuje.** Pak se
  rozlišení a DPI **nevrátí** a skript to napíše do logu. Proto je lepší spustit
  `su -c 'pxtune revert'` **ručně ještě před odinstalací**, na běžícím systému.
- **`pxtune res reset` nastaví DPI na 420, ne na tvých 353.** Viz sekci 7 —
  je to důležité a mate to.

Chceš-li při odinstalaci smazat úplně všechno včetně profilů a zálohy, vytvoř
předem soubor `PURGE`:

```sh
su -c 'touch /data/adb/pixel_tune/PURGE'
```

### Když se něco pokazí — čtyři úrovně nouzového vypnutí

Od nejjemnějšího po nejtvrdší:

#### a) `pxtune revert` — telefon běží, jen se chová divně

```sh
su -c 'pxtune revert'
```

Vrátí **všechno** na hodnoty z `backup/stock.conf` (a co v něm chybí, na výchozí
hodnoty ze SPEC). Nevypne modul, jen zruší jeho účinky. Nastaví `active=stock`
a položí `manual_override`, aby automat hned nezapsal jiný profil.
**Tohle zkus jako první.**

#### b) Soubor `DISABLE` — modul se nemá při dalším bootu vůbec spustit

```sh
su -c 'touch /data/adb/pixel_tune/DISABLE'
```

Když tenhle soubor existuje, `post-fs-data.sh` i `service.sh` **okamžitě skončí**
a neudělají nic. Modul zůstane nainstalovaný, ale je inertní.
`service.sh` navíc kontroluje `DISABLE` **ještě jednou** po svém 20sekundovém čekání —
takže ho stihneš položit i z WebUI těsně po bootu.

Zpět ho zapneš smazáním:

```sh
su -c 'rm /data/adb/pixel_tune/DISABLE'
```

#### c) KernelSU safe mode — telefon nenaběhne nebo nemáš jak spustit shell

Při startu **drž Volume Down**. KernelSU nabootuje v safe mode, což **vypne všechny
moduly** (nejen pixel_tune). Pak v manageru modul odinstaluj nebo polož `DISABLE`.

#### d) Automatická pojistka proti bootloopu (běží sama, nemusíš nic dělat)

- `post-fs-data.sh` při každém bootu **zvýší** čítač `boot_count`.
- `service.sh` ho po úspěšném doběhnutí **vynuluje**.
- Když `post-fs-data.sh` uvidí `boot_count ≥ 3` (tři boothy po sobě, kdy se
  `service.sh` nedostal do konce), **sám vytvoří `DISABLE`** a nic neudělá.
  Čítač přitom rovnou vynuluje, takže po ručním smazání `DISABLE` máš zase tři pokusy.
- Navíc už při `boot_count ≥ 2` **přeskočí změnu zramu** — to je nejrizikovější
  operace v rané fázi bootu, takže po jednom nepovedeném bootu se na ni nesahá.

**Tedy: i kdyby modul telefon shazoval, po třech restartech se sám vypne.**

Návrh tomu jde naproti ještě jinak: v `post-fs-data.sh` (raná fáze bootu, kde by
chyba mohla znamenat bootloop) je **jen bootloop ochrana a volitelný zram**.
Všechno ostatní dělá `service.sh` až v pozdní fázi, kde chyba znamená nanejvýš
„nic se nenastavilo".

---

## 3. Profily

Profil je textový soubor `KEY=VALUE` v `/data/adb/pixel_tune/profiles/`.
Pravidla, která platí vždy:

- **Prázdná hodnota nebo chybějící klíč = na tu věc se nesáhne.**
- Neznámé klíče se ignorují (aby starší profil nerozbil novější `pxtune`).
- Soubory se **nesourcují** — `pxtune` je parsuje po řádcích, takže poškozený
  nebo podvržený profil nemůže nic spustit.
- Profily jsou tvoje, můžeš je editovat a **přežijí přeinstalaci modulu**.

### Přehled — co který profil konkrétně mění

Prázdná buňka „—" znamená, že profil na tu skupinu hodnot **nesahá** (zůstává stock).

| Profil | uclamp | GPU | thermal profil | nabíjení | vm / I/O |
|---|---|---|---|---|---|
| **balanced** *(default)* | — | — | — | — | — |
| **powersave** | `top-app.max=60`<br>`foreground.max=50`<br>`background.max=30`<br>`system-bg.max=40` | `max=580000` kHz | — | — | — |
| **performance** | `top-app.min=25` | — | — | — | — |
| **game** | `top-app.min=30`<br>`background.max=30`<br>`system-bg.max=40` | — | `game` na CPU-MID<br>i CPU-HIGH | — | — |
| **night** | `top-app.max=50`<br>`foreground.max=35`<br>`background.max=17`<br>`system-bg.max=35` | `max=419000` kHz | — | `charge_stop_level=80` | — |

**Žádný profil nemění vm, I/O readahead ani zram.** Ve všech pěti jsou tyhle klíče
prázdné — není pro ně naměřený podklad.

### Kdy který použít

| Profil | Popis | Kdy |
|---|---|---|
| **balanced** | „Vyvážený — čistý stock, žádné zásahy (default)" | Výchozí stav a referenční bod, se kterým porovnáváš ostatní. Použij, když nemáš konkrétní důvod na nic jiného. |
| **powersave** | „Chladný — ořezaná špička, priorita teploty a výdrže" | Když ti telefon hřeje v ruce nebo chceš vydržet den. Ořezává **teplotní špičku v prvních desítkách sekund zátěže**, ne ustálený výkon (ten je stejně sražený na ~40 %). |
| **performance** | „Svižnější balanced — rychlejší náběh, stropy beze změny" | Když telefon nepůsobí pomalu, ale „zpožděně" — drobný lag při prvním doteku. Nezvyšuje stropy (nemá jak), jen zkracuje ramp-up. |
| **game** | „Hry — stabilní frame-time, uklizené pozadí, GPU beze změny" | Hry, které běží desítky minut (Pokémon GO apod.). Cílí na stabilní frame-time a klid v pozadí, ne na špičkový výkon. **Kombinuj s Game Mode** — viz sekci 7. |
| **night** | „Noc — pozadí drženo mimo velká jádra, GPU srazená, nabíjení do 80 %" | Telefon leží na stole nebo na noční nabíječce. Jediný profil, který **sám nastaví strop nabíjení na 80 %.** |

### Proč je `balanced` prázdný

Není to nedodělek, je to výsledek. Autor profilu prošel všechny páky a u každé
zjistil, že v naměřených datech není důkaz, že by stock hodnota byla špatně:

- **uclamp** — stock je `min=0.00`, `max=max` všude (kromě `nnapi-hal`, které má
  `min=1.00`; na to se nesahá). Jakýkoli `uclamp.max < 100` je ztráta výkonu,
  jakýkoli `uclamp.min > 0` je vyšší spotřeba. U defaultu nechceš ani jedno.
- **CPU stropy** — nejde je nastavit, viz sekci 9.
- **thermal profil** — mechanismus **není ověřený** a systém si ten prop nastavuje
  sám (při měření byl už na `camera`, protože běžela kamera). Default do toho
  skákat nesmí.
- **GPU** — stock `scaling_max_freq` je 890000 kHz, což **je** hardwarové maximum.
  Nahoru není kam, dolů je ztráta výkonu bez důvodu.
- **vm** — stock `swappiness=60`, `dirty_ratio=20`, `dirty_background_ratio=10`,
  `vfs_cache_pressure=100`, `page-cluster=0` (to poslední je pro zram už optimální).
  Žádné měření neukazuje problém.
- **I/O readahead** — není známá ani stock hodnota, ani žádné I/O měření.
- **charge_stop_level** — je to tvoje rozhodnutí o dostupné kapacitě, ne oprava chyby.

### Jak jsou čísla v profilech odvozená

Stojí za to to vědět, protože z toho plyne, **co od profilů čekat a co ne**.

#### Výchozí měření

Naměřeno při 150 s trvalé zátěže na 9 jádrech: systém se sám sráží na
**Big 910 MHz (38 % HW maxima)** a **Prime 1164 MHz (40 %)** — a to už při junction
jen 58 °C a skin 40,5 °C. Špička junction v prvních ~40 s je ale **81 °C**.
Zotavení z throttlingu trvá **~84 s** a prvních 60 s se neuvolní nic.

Z toho plynou dvě pravidla, která profily dodržují:

1. **Trvalý výkon není co ořezávat — je už oříznutý.** Ořezává se **špička**
   v prvních desítkách sekund. Proto má `powersave` strop `top-app.max=60`, což
   leží **nad** naměřenými 40 % ustáleného stavu: dlouhodobý výkon nezhoršuje,
   ubírá jen špičku, která se stejně draze zaplatí 84 sekundami škrcení.
2. **Podlahy (`uclamp.min`) se drží POD 38 %.** `performance` má 25, `game` má 30.
   Vyšší podlaha by tlačila proti škrticí smyčce a výsledkem by byl **trvale
   zaškrcený, tedy pomalejší** telefon.

#### Co čísla uclampu fyzicky znamenají — naměřená capacity tabulka

Škála `uclamp` 0–100 je relativní ke kapacitě **nejsilnějšího** jádra, tedy 1024.
Kapacity clusterů jsou **naměřené na zařízení**:

| Cluster | Jádra | `cpu_capacity` |
|---|---|---|
| Little (4×A510) | cpu0–3 | **182** |
| Big (4×A715) | cpu4–7 | **725** |
| Prime (1×X3) | cpu8 | **1024** |

Z toho plynou **dva tvrdé prahy**, na kterých stojí všechny hodnoty v profilech:

| Práh | Důsledek |
|---|---|
| `uclamp.max ≤ 17,8` | util ≤ 182 ⇒ úloha se vejde do Little ⇒ **nikdy nesáhne na Big ani Prime** |
| `uclamp.max ≤ 70,8` | util ≤ 725 ⇒ úloha se vejde do Big ⇒ **nikdy nepotřebuje Prime (X3)** |
| `uclamp.max > 70,8` | úloha může vytáhnout Prime |

Uvnitř clusteru platí přibližně `frekvence ≈ (util / capacity_clusteru) × max_freq`.
Pro Big (max 2367 MHz) tedy `frekvence ≈ (uclamp / 725) × 2367 MHz`:

| `uclamp` | util | Big ≈ |
|---|---|---|
| 25 | 256 | ~836 MHz |
| 30 | 307 | ~1002 MHz |
| 35 | 358 | ~1170 MHz |
| 40 | 410 | ~1338 MHz |
| 50 | 512 | ~1672 MHz |
| 60 | 614 | ~2005 MHz |

**Tohle je hlavní důvod, proč jsou v profilech zrovna tahle čísla, a ne jiná.**

#### Odůvodnění každé nastavené hodnoty

| Profil | Klíč | Hodnota | Proč právě tolik |
|---|---|---|---|
| `powersave` | `top-app.max` | 60 | 60 < 70,8 ⇒ popředí **nikdy nevytáhne Prime (X3)**, největší jednotlivý zdroj tepla. Zároveň ~2005 MHz na Big leží hluboko **nad** ustálenými 910 MHz, takže dlouhodobý výkon nezhoršuje — ubírá jen špičku, která stojí 84 s škrcení. |
| `powersave` | `foreground.max` | 50 | O stupeň níž než top-app (~1672 MHz), pořád nad ustálenými 910 MHz. U neinteraktivních úloh je ztráta špičky ještě míň znát. Rovněž pod 70,8 ⇒ bez Prime. |
| `powersave` | `background.max` | 30 | **Vědomý kompromis bez měření.** 30 je **nad** prahem 17,8, takže pozadí na Big smí — jen pomalu. Striktní ≤ 17 by ho zahnalo na Little, ale kvůli race-to-idle to může sežrat víc energie celkem a `powersave` je denní profil, kde má sync doběhnout. Kdo chce chladněji i ve dne, přepíše na 17. |
| `powersave` | `system-bg.max` | 40 | 40 % je přesně úroveň, kterou si systém pod zátěží sám drží (Prime 1164 MHz = 40 %). Neberu tedy systémovým službám nic, co by jim HAL stejně nenechal. Níž ne, aby neutrpěly wakeupy a probouzení displeje. |
| `powersave` | `GPU max` | 580000 | 5. krok shora, ~65 % stock maxima — odřezává tři napěťově nejdražší OPP. Konzervativní schválně: **měření GPU pod zátěží neexistuje**, takže se nejde na CPU-ekvivalent 40 % (~376000). |
| `performance` | `top-app.min` | 25 | util 256 > 182 ⇒ popředí se **nevejde do Little**, scheduler ho rovnou dá na Big (~836 MHz) — to je ta hledaná svižnost. A 25 ≪ 70,8 ⇒ podlaha **sama nikdy neprobudí Prime**. Navíc 25 < 38 % ustáleného stavu ⇒ **nebojuje s thermal HAL** a nezvyšuje trvalou spotřebu. |
| `game` | `top-app.min` | 30 | ~1002 MHz na Big ⇒ render vlákno mezi snímky nespadne na nízké OPP a další snímek nezačíná z nuly. Vyšší než `performance`, protože herní zátěž je trvalá a předvídatelná. Vědomě **ne 38–40+**: to už by tlačilo proti škrticí smyčce a skončilo trvale zaškrceným telefonem uprostřed hry. |
| `game` | `background.max` | 30 | Hlavní zisk během hry: Prime vyloučen (30 < 70,8) ⇒ nejdražší jádro nepálí na úlohy v pozadí a nepřidává teplo. Striktní ≤ 17 nezvoleno — chybí měření, že to nerozhodí pomocné herní procesy. |
| `game` | `system-bg.max` | 40 | Stejná logika jako v `powersave`. |
| `game` | `thermal profil` | `game` | **Jediná páka, která může posunout ustálený strop** (Big 38 % / Prime 40 % při pouhých 58 °C je zjevně hodně konzervativní). Nastavuje se **jen tady, jen dočasně** — a je to **neověřený mechanismus**, viz sekci 11. |
| `night` | `top-app.max` | 50 | Pojistka pro případ, že telefon vezmeš do ruky **dřív**, než automat přepne profil. ~1672 MHz na Big je pořád vysoko nad ustálenými 910 MHz, takže odemčení a pár doteků nepůsobí rozbitě. Prime vyloučen. |
| `night` | `foreground.max` | 35 | Viditelné-ale-neaktivní procesy při zhasnutém displeji reálně nic neobsluhují ⇒ ~1170 MHz bohatě stačí. |
| `night` | `background.max` | **17** | **Hlavní páka profilu.** 17 < 17,8 ⇒ sync, JobScheduler a údržba se vejdou do Little a scheduler je **nikdy nemusí přesunout na velká jádra**. Cena je malá: uvnitř Little to je ~1629 MHz ze 1704 MHz — omezuje se **umístění, ne takt**. |
| `night` | `system-bg.max` | 35 | Výrazně víc než obyčejné pozadí a **smí na Big** schválně — přes system-background jdou wakeupy, notifikace a probouzení displeje. Zahnat i je na Little by riskovalo pomalé probuzení telefonu. |
| `night` | `GPU max` | 419000 | ~47 % stock maxima. Při zhasnutém displeji se strop nedotkne ničeho, ale brání tomu, aby náhodné probuzení (widget, notifikace, AOD) vytáhlo GPU na nejvyšší OPP. Ne níž (302000/150000) ze stejného důvodu jako u top-app: odemykací animace při 300 MHz už by byla znát. **Kompromis, ne měření.** |
| `night` | `charge_stop_level` | 80 | Baterie má **602 cyklů**, noc je jediná situace, kdy telefon předvídatelně stojí hodiny na nabíječce s plnou baterií — přesně stav, který kapacitu ničí. Zápis ověřen (viz sekci 8). |

#### Že `uclamp.max` opravdu funguje, je ověřeno měřením

Měřeno se čtyřmi zátěžovými procesy v cgroup `top-app`, průměrné frekvence:

| `uclamp.max` | Little | Big | Prime |
|---|---|---|---|
| `max` | 1385 MHz | 1469 MHz | 2101 MHz |
| `50` | 1349 MHz | 1418 MHz | **1600 MHz** |
| `25` | 1134 MHz | 1333 MHz | 1277 MHz |

**Poctivá výhrada:** jednotlivé fáze běžely za sebou a telefon se během nich
zahříval, takže **část poklesu jde na vrub souběžnému thermal throttlingu**, ne
uclampu. Tohle měření samo o sobě tedy neříká, jak velký je efekt uclampu.

**Průkazné je něco jiného:** ve fázi 2 byl hardwarový strop Prime **1885 MHz**,
ale naměřený průměr byl jen **1600 MHz**. Governor tedy šel **pod strop sám od sebe** —
a to throttling vysvětlit nedokáže. Efekt uclampu je tím prokázaný jako reálný.

#### Zbylé výhrady k přesnosti

- Přepočet uclamp → frekvence je **přibližný**; vztah util↔freq není přesně lineární
  a governor `sched_pixel` má vlastní logiku.
- **Energy model v debugfs není na tomhle zařízení dostupný**, takže se nedá spočítat,
  jestli je zahnání úlohy na Little celkově úspornější — proti stojí race-to-idle
  (na Little poběží úloha déle). Proto je striktní hodnota `≤ 17` použita jen v `night`,
  kde na době doběhu nezáleží, a v `powersave` je ponecháno volnějších 30.
- **Pro GPU není žádné měření pod trvalou zátěží** (naměřených 150 s bylo CPU-only).
  Proto `powersave` nejde na GPU-ekvivalent 40 % (~376000 kHz), ale zůstává
  konzervativně na 580000 kHz.

### Klíče profilu — kompletní reference

```sh
# povinné
PROFILE_NAME="balanced"
PROFILE_DESC="Vyvážený — stock chování"

# uclamp (0-100, nebo "max"; prázdné = nesahat)
UCLAMP_TOPAPP_MIN=""     # /dev/cpuctl/top-app/cpu.uclamp.min
UCLAMP_TOPAPP_MAX=""     #                     .../cpu.uclamp.max
UCLAMP_FG_MIN=""         # /dev/cpuctl/foreground/
UCLAMP_FG_MAX=""
UCLAMP_BG_MIN=""         # /dev/cpuctl/background/
UCLAMP_BG_MAX=""
UCLAMP_SYSBG_MIN=""      # /dev/cpuctl/system-background/
UCLAMP_SYSBG_MAX=""

# GPU (kHz, MUSÍ být hodnota z povoleného seznamu níže; prázdné = nesahat)
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
IO_READAHEAD_KB=""       # aplikuje se na sda, sdb, sdc, sdd

# nabíjení
CHARGE_STOP_LEVEL=""     # 1-100
```

**Povolené GPU frekvence** (kHz, sestupně — jiná hodnota se odmítne):

```
890000  850000  807000  723000  649000  580000  521000
467000  419000  376000  337000  302000  150000
```

Stock: `scaling_max_freq=890000`, `scaling_min_freq=150000`, `power_policy=adaptive`.
GPU `scaling_max_freq` je **ověřeně zapisovatelné a drží** (zapsáno 649000, po 12 s
stále 649000) — na rozdíl od cooling devices, které thermal HAL přepisuje.

**Poznámka k `camera-daemon` a `nnapi-hal`:** `pxtune revert` je zná a vrací,
ale **kontrakt profilu je nevystavuje** — přes profil na ně nesáhneš. Je to záměr.

### Co znamená uclamp v praxi

| Nastavení | Efekt |
|---|---|
| `uclamp.max < 100` | Strop na utilizaci ⇒ governor sáhne po nižších frekvencích ⇒ **chlazení a úspora**, ale i pomalejší běh. |
| `uclamp.min > 0` | Podlaha ⇒ frekvence naskočí rychleji ⇒ **svižnost**, ale vyšší spotřeba. |

| cgroup | Co v ní běží |
|---|---|
| `top-app` | Aplikace, kterou máš právě na obrazovce. |
| `foreground` | Viditelné/aktivní věci, které nejsou top-app. |
| `background` | Věci na pozadí. Tady je strop nejlevnější — omezení skoro necítíš. |
| `system-background` | Systémové úlohy na pozadí. Přes ně jdou i wakeupy a probouzení displeje — proto mají profily strop vyšší než u obyčejného pozadí. |

---

## 4. WebUI

WebUI je `webroot/index.html`, otevře se z KernelSU-Next manageru
(Moduly → `Pixel Tune` → WebUI). Čte `pxtune status --json` a tlačítka volají
odpovídající `pxtune` příkazy — **WebUI neumí nic, co neumí CLI.**
Když ti něco nefunguje, zkus totéž z shellu; důvod bude v `pxtune log`.

### Hlavička

| Prvek | Co dělá |
|---|---|
| **⟳ Obnovit** | Ruční načtení stavu. |
| **⏱ 5 s** | Cykluje interval automatického obnovování: **vyp → 2 s → 5 s → 10 s → 30 s**. Výchozí je 5 s. Při skrytém okně se polling úplně zastaví. |
| Tečka + text pod nadpisem | Stav posledního volání (OK / provádím / chyba). |

### Banner „⚠ Změna rozlišení čeká na potvrzení"

Objeví se **jen když existuje `res_pending`**, s odpočtem od 60 s.

| Tlačítko | Volá | Co udělá |
|---|---|---|
| **✓ Potvrdit** | `pxtune res confirm` | Změna zůstane, automatický návrat se zruší. |
| **Vrátit hned** | `pxtune res reset` | Nečeká na odpočet, vrátí nativní rozlišení okamžitě. |

### Karta „Profil"

| Prvek | Volá | Co udělá |
|---|---|---|
| Dlaždice profilů | `pxtune profile <name>` | Přepne profil a **nastaví `manual_override`**. |
| **🤖 Auto** | `pxtune profile auto` | Zruší `manual_override` — profil zase řídí automat. |
| **Démon: on/off** | `pxtune auto on` / `pxtune auto off` | Zapne/vypne adaptivního démona. **Viz sekci 6.** |

Pozor na rozdíl: **🤖 Auto** vrací automatu *právo rozhodovat*, **Démon** zapíná/vypíná
*samotný proces*. Jsou to dvě různé věci.

### Karty pouze pro čtení

| Karta | Co ukazuje |
|---|---|
| **CPU — přiškrcení** | Aktuální strop vs. HW maximum pro každý cluster. Dopočítáno ze stavu cooling device. |
| **Teploty** | Hodnoty z thermal zón. |
| **GPU (Mali)** | Frekvence, utilizace, power policy. |
| **Paměť** | zram — velikost, algoritmus, obsazení. |

### Karta „Baterie"

Nahoře stav (kapacita, teplota, cykly, proud). Dole ovládání stropu nabíjení:

| Prvek | Volá | Poznámka |
|---|---|---|
| Posuvník | — | Rozsah **50–100 %, krok 5**. Samotné tažení nic nenastaví. |
| **Nastavit** | `pxtune charge <hodnota>` | Aktivní až po pohnutí posuvníkem. |
| **Vypnout limit (100 %)** | `pxtune charge off` | Zpět na stock. |

CLI umí i hodnoty pod 50 (rozsah 1–100), WebUI posuvník je schválně užší.

### Karta „Rozlišení"

| Prvek | Volá | Co udělá |
|---|---|---|
| Tlačítka presetů | `pxtune res <preset>` | Přepne rozlišení **a spustí 60s pojistku**. |
| **⤺ Reset na nativní (1080 × 2400)** | `pxtune res reset` | Vrátí nativní rozlišení. **Nastaví přitom DPI na 420, ne na tvých 353** — viz sekci 7. |

Presety se berou ze `status --json`; když je JSON nepošle, WebUI zobrazí
záložní trojici `1080p / 900p / 720p`. **Ta jména ale `pxtune` nezná** — CLI presety
se jmenují `native`, `900x2000`, `810x1800`, `720x1600` (a přijímají i zkratky
`900` / `810` / `720`). Kliknutí na fallback preset tedy skončí návratovým kódem 1.
Viz TODO na konci.

### Karta „Nebezpečná zóna"

| Prvek | Volá | Co udělá |
|---|---|---|
| **↺ Vrátit vše na stock** | `pxtune revert` | Ptá se na potvrzení. Obnoví všechno z `backup/stock.conf` a zruší aktivní profil. |

### Co ve WebUI NENÍ

Zobrazovač logu a ovládání Game Mode. Obojí jen z CLI (`pxtune log`, `pxtune game`).

---

## 5. CLI — `pxtune`

`/data/adb/modules/pixel_tune/bin/pxtune`, POSIX sh, běží pod `/system/bin/sh`.
**Všechny příkazy vyžadují root** (`su -c '...'`).

### Přehled

| Příkaz | Co dělá |
|---|---|
| `pxtune status` | Stav: aktivní profil, teploty, frekvence, uclamp, zram, nabíjení, `auto`, `res_pending`. |
| `pxtune status --json` | Totéž jako validní JSON (parsuje WebUI). |
| `pxtune profile list` | Seznam profilů. |
| `pxtune profile current` | Jméno aktivního profilu. |
| `pxtune profile <name>` | Přepne profil. **Nastaví `manual_override`.** |
| `pxtune profile <name> --auto` | Totéž, ale **na `manual_override` nesahá** a když existuje, neudělá nic (kód 0). Tímhle přepíná profil démon; ručně to nepotřebuješ. |
| `pxtune profile auto` | Zruší `manual_override`, vrátí řízení automatu. Pošle démonovi `SIGHUP`, aby stav přehodnotil hned. |
| `pxtune revert` | Vrátí **VŠE** na stock z `backup/stock.conf`. |
| `pxtune res` \| `res status` \| `res current` | Vypíše aktuální rozlišení, DPI a stav `res_pending`. |
| `pxtune res list` | Vypíše presety. |
| `pxtune res <preset>` | Přepne rozlišení + spustí 60s pojistku. |
| `pxtune res confirm` | Potvrdí změnu, zruší pojistku. |
| `pxtune res reset` | Slepý návrat na nativní 1080×2400 **@ 420 dpi**. |
| `pxtune charge <1-100>` | Strop nabíjení v procentech. |
| `pxtune charge off` | Zpět na 100 %. |
| `pxtune game <package>` | Vypíše `list-modes` + `list-configs` daného balíčku. |
| `pxtune game <package> <mode> [--fps N] [--downscale 0.3..0.9\|disable]` | Nastaví Game Mode. |
| `pxtune auto on` \| `off` \| `status` | Adaptivní automat — zapíše stav do `auto` **a zároveň** spustí/zastaví démona (`pxtune-auto start`/`stop`). Viz sekci 6. |
| `pxtune log [-n N]` | Posledních N řádků logu (výchozí 50). |
| `pxtune selftest` | Ověří všechny cesty ze SPEC. |
| `pxtune -v` | Verze. |
| `pxtune -h` \| `--help` | Nápověda. |

### Presety rozlišení

| Preset | Rozlišení | DPI |
|---|---|---|
| `native` | 1080 × 2400 | **420** |
| `900x2000` | 900 × 2000 | 350 |
| `810x1800` | 810 × 1800 | 315 |
| `720x1600` | 720 × 1600 | 280 |

To jsou jména, která vypíše `pxtune res list`. Preset lze ale zadat i jen samotnou
šířkou — `pxtune res 900`, `810`, `720` fungují taky.
`native` se aplikuje **bez pojistky** (není proti čemu se jistit).

### Režimy Game Mode

| Hodnota | Význam |
|---|---|
| `1` / `standard` | Standardní |
| `2` / `performance` | Výkon |
| `3` / `battery` | Baterie |
| `4` / `custom` | Vlastní (kombinuje se s `--downscale` / `--fps`) |

### Návratové kódy

| Kód | Význam |
|---|---|
| `0` | OK |
| `1` | Chyba argumentů (neznámý příkaz, neznámý profil/preset, hodnota mimo rozsah) |
| `2` | Chyba běhu (zápis selhal, chybí `settings`/`cmd`, selftest našel chybějící cesty) |

`pxtune profile <name>` vrátí **2**, i když se aplikoval, ale aspoň jeden zápis selhal.
Kolik zápisů prošlo a kolik ne, ti vypíše přímo na konci.

### Jak se zapisuje

Každý zápis do sysfs jde přes jednu funkci `wr <cesta> <hodnota>`, která:

1. ověří existenci cesty,
2. ověří zapisovatelnost,
3. zaloguje `stará → nová` hodnota,
4. **při chybě pokračuje dál** — jeden nezapsatelný node nikdy neshodí skript.

Takže když se ti zdá, že se něco neaplikovalo, **odpověď je vždycky v logu**:

```sh
su -c 'pxtune log -n 50'
```

### Log

`/data/adb/pixel_tune/pxtune.log`, formát `[YYYY-MM-DD HH:MM:SS] [úroveň] zpráva`.
Rotuje při **512 kB** — starý se přejmenuje na `pxtune.log.old`. Historii tedy máš
maximálně dva soubory zpátky.

---

## 6. Adaptivní automat

### Jak je postavený

`bin/pxtune-auto` **existuje a je funkční.** Zdroj pravdy o zapnutí je jediný soubor
`/data/adb/pixel_tune/auto` — čte ho CLI, `service.sh` i sám démon.

Klíčová vlastnost návrhu: **žádný polling.** Démon visí zablokovaný na `read()`
z pojmenované roury a mezi událostmi **vůbec neběží**. Události bere z binárního
event bufferu logd (`logcat -b events`), ne z accessibility služby:

| Událost | Tag | K čemu |
|---|---|---|
| Změna aplikace v popředí | `wm_resume_activity` | klasifikace zátěže |
| Zhasnutí/rozsvícení displeje | `power_screen_state` | přepnutí do/z `night` |

Jméno tagu pro popředí si démon **zjišťuje za běhu** z `/system/etc/event-log-tags` —
od Androidu R se jmenuje `wm_resume_activity`, starší `am_resume_activity` na A16 už
neexistuje.

### Jak rozhoduje

Démon si o každé aplikaci vede statistiku v `appstats`: vzorkuje CPU čas hlavního
procesu (`/proc/<pid>/stat`) a počítá EWMA v procentech **jednoho** jádra.

| Třída | Podmínka | Profil |
|---|---|---|
| `game` | CPU ≥ 150 % **a zároveň** průměrná relace ≥ 90 s | `game` |
| `heavy` | CPU ≥ 80 % | `performance` |
| `normal` | CPU ≥ 20 % | `balanced` |
| `light` | zbytek | `powersave` |

Nad tím leží dvě tvrdší pravidla:

- **Zhasnutý displej ⇒ vždy `night`**, bez ohledu na klasifikaci.
- **Skin ≥ 43,0 °C ⇒ dočasně `powersave`.** Uvolní se až při ≤ 41,0 °C (2 °C hystereze)
  a nejdřív po 120 s. Práh je schválně **nad** naměřeným ustáleným stavem (skin 40,5 °C
  při plné zátěži 9 jader) — jinak by automat sepnul při každé normální zátěži.

Klasifikaci lze ručně přebít v `appstats.override` (`<balíček> <třída>`), konstanty
lze přepsat v `auto.conf`.

### Dopad na baterii — konkrétně

Tohle je to podstatné a je to naměřitelné z návrhu:

- **Mezi událostmi démon nespotřebuje nic.** Blokovaný `read()` není wakeup.
- **Jediný časovač v celém démonu je „tikař" s periodou 30 s** — a ten se zapíná
  **jen** když svítí displej **a zároveň** běží `game`/`heavy` aplikace, nebo je horko,
  nebo čeká odložené přepnutí. **Při zhasnutém displeji se okamžitě zabíjí, takže
  v suspendu neexistuje žádný budík.**
- Anti-flapping: profil se nepřepne častěji než jednou za **30 s**. To je schválně
  víc než 7sekundová regulační perioda thermal HALu — automat mu nemá skákat do řízení.
- Vzorkování se u aplikace zastaví po **20 vzorcích** (EWMA je dávno usazená), takže
  dlouhodobě ubývá i těch pár forků.

### Jak s ním zacházet

```sh
su -c 'pxtune auto status'    # on / off (chybějící soubor = "on")
su -c 'pxtune auto off'       # vypnout
su -c 'pxtune auto on'        # zapnout
```

### Manuální override

Když přepneš profil ručně (`pxtune profile <name>` nebo dlaždice ve WebUI),
vytvoří se `/data/adb/pixel_tune/manual_override` a **automat přestane profil měnit**.
Tvoje volba drží, dokud neřekneš jinak.

Vrátit řízení automatu:

```sh
su -c 'pxtune profile auto'
```

`pxtune auto off` **zakáže automatu přepínat**; `pxtune profile auto` **mu vrátí právo
rozhodovat**. To jsou dvě různé věci a WebUI je má jako dvě různá tlačítka.

Přesně vzato: `pxtune auto on|off` jen přepíše soubor `/data/adb/pixel_tune/auto`.
Démon si ho čte před každým přepnutím, takže při `off` dál pozoruje, ale nic nemění —
**proces ale běží dál.** Když ho chceš opravdu ukončit (nebo naopak nastartovat, aniž
bys rebootoval), použij přímo jeho binárku:

```sh
su -c '/data/adb/modules/pixel_tune/bin/pxtune-auto status'
su -c '/data/adb/modules/pixel_tune/bin/pxtune-auto stop'
su -c '/data/adb/modules/pixel_tune/bin/pxtune-auto start'
```

Démon se jinak startuje **jen při bootu**, z `service.sh`, podle obsahu souboru `auto`
(chybějící soubor = zapnuto).

Ještě jedna drobnost: `pxtune profile auto` démonovi **neposílá SIGHUP**, takže stav
nepřehodnotí okamžitě — udělá to až při nejbližší události (přepnutí aplikace,
zhasnutí displeje) nebo tiku.

Pěkný detail: `service.sh` při bootu aplikuje uložený profil, ale **`manual_override`
si předtím zapamatuje a po aplikaci obnoví do původního stavu.** Bez toho by tě
každý reboot přehodil do ručního režimu — protože `pxtune profile <name>` ten příznak
z definice nastavuje.

### Kamera

Systém si prop `vendor.thermal.<SENZOR>.profile` **nastavuje sám** — při měření byl
už na `camera`, protože běžela kamera. Automat s tím počítá: dokud je prop na `camera`,
**přepnutí profilu odloží** a napíše to do logu.

Pojistka pro opačný případ: prop na `camera` může **zůstat viset** i po zavření
fotoaparátu (přesně to se při měření stalo). Kdyby v tom stavu vydržel déle než
**600 s**, démon ho začne ignorovat a přepíná dál — jinak by se sám natrvalo umlčel.

Když ti automat přesto dělá vylomeniny při focení, `pxtune auto off` je legitimní
odpověď.

### Proč automat neovládá cooling devices

**Cooling devices přepisuje thermal HAL zhruba každých 7 sekund.** Kdyby je chtěl
automat používat jako *páku* (a ne jen ke čtení), musel by běžet ve smyčce rychlejší
než 7 s — a taková smyčka baterii měřitelně žere, čímž by padla celá bezpollingová
konstrukce popsaná výš. Přesně proto se cooling devices v pixel_tune používají
**výhradně ke čtení** a ovládá se přes uclamp, které thermal HAL nepřepisuje
a watchdog nevyžaduje.

**Praktické doporučení:** jestli chceš hlavně výdrž a jsi ochotný si profil přepnout
ručně, **automat můžeš nechat vypnutý**. Ruční profil + `manual_override` má **nulovou
režii** — zapíše se jednou a dál nic neběží. Automat má smysl tehdy, když ti vadí
na profily myslet, nebo když chceš teplotní pojistku na 43 °C.

> TODO: **dopad automatu na výdrž není změřený.** Z návrhu plyne, že je malý
> (žádný polling, tikař 30 s jen při rozsvíceném displeji u náročné aplikace),
> ale srovnávací měření výdrže s démonem a bez něj zatím nikdo neudělal.

---

## 7. Rozlišení displeje

> **Přečti si celou tuhle sekci PŘEDTÍM, než rozlišení poprvé změníš.**
> Je to jediná věc v modulu, která tě může nechat koukat na nepoužitelnou obrazovku.

### Výchozí stav

| Věc | Hodnota |
|---|---|
| Fyzický panel | 1080 × 2400 |
| `ro.sf.lcd_density` | 420 |
| **Tvůj aktuální override density** | **353** |
| `settings global display_size_forced` | **prázdné** |
| `settings secure display_density_forced` | **353** |
| Obnovovací frekvence | adaptivní 60–120 Hz, mode 2 = 120 Hz |

### ⚠ Číslo 353 vs. 420 — tohle je ta záludnost

Tvůj telefon má vlastní override hustoty **353**. Firmware hodnota je 420.

**`pxtune res reset` (i preset `native`, i 60sekundová pojistka, i tlačítko „Vrátit hned")
nastaví DPI na 420, ne na 353.** Vrátí ti tedy správné *rozlišení*, ale **jiné DPI,
než jsi měl** — všechno bude o něco menší.

Tvých 353 ti vrátí:

- `pxtune revert` (bere hodnotu z `backup/stock.conf`), nebo
- ruční `settings put secure display_density_forced 353`.

**Pravidlo: `res reset` použij, když nevidíš. `revert` použij, když chceš přesně
původní stav.**

### Jak rozlišení změnit

```sh
su -c 'pxtune res list'      # vypíše presety
su -c 'pxtune res 900'       # 900 × 2000 @ 350 dpi
```

| Preset | Rozlišení | DPI |
|---|---|---|
| `native` | 1080 × 2400 | 420 |
| `900x2000` (nebo `900`) | 900 × 2000 | 350 |
| `810x1800` (nebo `810`) | 810 × 1800 | 315 |
| `720x1600` (nebo `720`) | 720 × 1600 | 280 |

Perzistence jde přes systémová nastavení, ne přes zásah do `/system`:

```sh
settings put global display_size_forced "<W>,<H>"
settings put secure display_density_forced <dpi>
```

### 60sekundová pojistka — jak funguje

1. `pxtune res <preset>` změní rozlišení **a zároveň** vytvoří `res_pending`
   s jednorázovým tokenem.
2. Na pozadí se spustí watchdog, který **za 60 sekund vrátí nativní rozlišení**.
3. Když do 60 s potvrdíš:

   ```sh
   su -c 'pxtune res confirm'
   ```

   `res_pending` zmizí, watchdog při probuzení zjistí, že jeho token už neplatí,
   a **nic neudělá**. Změna zůstane.
4. **Když nepotvrdíš** — protože nevidíš na displej nebo se ti UI rozsypalo —
   po 60 sekundách se rozlišení **samo vrátí na 1080×2400 @ 420 dpi**.
   Nemusíš dělat nic. Jen počkat minutu.

Celý trik je: **když si nejsi jistý, nepotvrzuj.** Neúspěch se sám vyléčí.

Preset `native` pojistku nespouští — není proti čemu se jistit.

### Vrácení naslepo přes ADB (když UI nevidíš)

Připoj telefon USB kabelem k počítači s `adb` a piš naslepo.

**Krok 0 — počkej minutu.** Vážně. Pokud jsi změnu nepotvrdil, pojistka to vyřeší sama.

**Krok 1 — nejjednodušší cesta, žádný root:**

```sh
adb shell wm size reset
adb shell settings put secure display_density_forced 353
```

První řádek zruší vynucené rozlišení. Druhý vrátí **tvoji** hustotu 353.
Tyhle příkazy **nevyžadují root** — projdou z běžného `adb shell`, takže nemusíš
na displeji odklikávat žádnou root výzvu (což bys stejně neviděl).

**`wm density reset` NEPOUŽÍVEJ** — vrátil by 420, ne tvých 353.

**Krok 2 — když to nestačilo, vyčisti perzistentní override přímo:**

```sh
adb shell settings delete global display_size_forced
adb shell settings put secure display_density_forced 353
adb reboot
```

**Krok 3 — nouzová brzda:**

```sh
adb reboot
```

a při startu **drž Volume Down** → KernelSU safe mode → všechny moduly vypnuté.
Pak vyřeš zbytek z klidného stavu.

> **Upozornění k `adb shell su -c '...'`:** KernelSU má pro root allowlist a shell
> v něm ve výchozím stavu být nemusí. Když si `su` z ADB vyžádá schválení, musíš ho
> odklikat **na displeji** — což je přesně to, co v tomhle scénáři nemůžeš.
> Proto jsou kroky 1 a 2 schválně napsané tak, aby root **nepotřebovaly**.

### Poctivě: snížení rozlišení ti mimo hry pravděpodobně nic nepřinese

Tohle je nejčastější mýtus a je fér ho rozbít.

V naměřeném zátěžovém testu — **150 sekund plné zátěže CPU na všech 9 jádrech** —
zůstal **`cdev_gpu` (`cooling_device24`, `thermal-gpufreq-0`) celou dobu na hodnotě 0.**
Ani jednou. To znamená, že **GPU nebyla během celého testu ani na okamžik termálně
přiškrcená.**

Závěr: **GPU není na tomhle telefonu teplotní úzké hrdlo pro ne-herní zátěž.**
Když GPU není to, co telefon brzdí ani hřeje, ubráním pixelů, které má vykreslit,
si nic nekoupíš. Čekej, že úspora bude **neměřitelná**, zatímco obraz bude o poznání
horší. Zdrojem tepla i brzdy jsou tady CPU clustery — v tomtéž testu spadl strop na
Little ~1036 MHz (61 % HW maxima), Big 910 MHz (38 %) a Prime 1164 MHz (40 %).

**Pro hry je to jinak — a na hry je lepší nástroj Android Game Mode.**
Ten škáluje rozlišení **per-app**, takže si nekazíš systémové UI ani ostatní aplikace:

```sh
su -c 'pxtune game com.priklad.hra custom --downscale 0.7 --fps 60'
su -c 'pxtune game com.priklad.hra battery'
su -c 'pxtune game com.priklad.hra'          # vypíše aktuální režimy a konfigy
```

Je to systémová funkce, zdarma, bez hacků. **Globální snížení rozlišení kvůli jedné
hře nedává smysl.**

### Refresh rate

Modul obnovovací frekvenci **globálně nesnižuje** a nebude. Viz sekci 9.

---

## 8. Nabíjení

Tvoje baterie má **602 nabíjecích cyklů**. To už je slušný nájezd a je to hlavní
důvod, proč tahle funkce v modulu je.

### Omezení stropu

```sh
su -c 'pxtune charge 80'     # nabíjet jen do 80 %
su -c 'pxtune charge off'    # zpět na 100 %
```

Zapisuje se do `/sys/devices/platform/google,charger/charge_stop_level`.
Ten node má práva `0660 system:system`, ale **root do něj zapsat může** —
ověřeno zápisem `80` a návratem na `100`.

Ve WebUI je posuvník **50–100 %, krok 5**. CLI bere celý rozsah 1–100.

Nebo přes profil — **`night` to dělá sám**:

```sh
CHARGE_STOP_LEVEL="80"
```

Pozor: **profil ti strop nastaví znovu při každém přepnutí.** Když si dáš
`pxtune charge off` a pak přepneš na `night`, bude zase 80.

### Proč to dělat

Lithiové články stárnou rychleji, když se drží na vysokém napětí. Držet telefon
v pásmu okolo 80 % místo 100 % zpomaluje degradaci kapacity. Užitečné hlavně tehdy,
když telefon **nabíjíš přes noc** nebo ho máš dlouho v dokovací stanici — tam se to
jinak celé hodiny drží na 100 %. Přesně proto je 80 % v profilu `night` a nikde jinde.

Cena je přímočará: **strop 80 % znamená, že máš k dispozici 80 % kapacity.**
Když víš, že tě čeká dlouhý den, dej `pxtune charge off`.

### Související stock hodnoty

| Node | Stock | Poznámka |
|---|---|---|
| `charge_stop_level` | 100 | Tohle měníme. |
| `charge_start_level` | 0 | Kdy začít znovu nabíjet. Profily na to nesahají (`revert` ho vrací). |
| `bd_trigger_temp` | 350 | Battery-defender: teplotní práh (35,0 °C). |
| `bd_trigger_time` | 21600 | 6 hodin. |
| `bd_recharge_soc` | 79 | |
| `bd_temp_enable` | 1 | |

Google už má vlastní „battery defender", který dlouhé nabíjení na 100 % částečně
řeší sám. `pxtune charge` je explicitnější a tvrdší varianta téhož.

### Čtení stavu baterie

```
/sys/class/power_supply/battery/capacity      # %
/sys/class/power_supply/battery/status
/sys/class/power_supply/battery/temp
/sys/class/power_supply/battery/cycle_count   # 602
/sys/class/power_supply/battery/current_now
```

---

## 9. Co to NEDĚLÁ a proč

Tahle sekce je stejně důležitá jako všechny předchozí. Většina „kernel tuning" modulů
slibuje věci, které na Tensoru **fyzicky nejdou** nebo jsou aktivně škodlivé.

### Žádný undervolting

Na Tensoru řídí napětí **ACPM firmware**. **Kernel k tomu nemá přístup.**
Neexistuje sysfs node, do kterého by šlo napětí zapsat.

Jakýkoli modul, který ti na tomhle SoC slibuje undervolting, buď lže, nebo mění něco
jiného a říká tomu undervolting. `pixel_tune` to nedělá a dělat nebude.

### `scaling_max_freq` se nenastavuje — protože nejde

`/sys/devices/system/cpu/cpufreq/policy*/scaling_max_freq` má práva **0444**.
To je read-only **i pro root**. Ověřeno.

Proto se stropy CPU řeší přes **uclamp**, ne přes frekvence. Je to nepřímější páka
(omezuješ požadovanou utilizaci, ne frekvenci), ale je to jediná, která funguje
a kterou nikdo nepřepisuje.

Číst z cpufreq lze normálně: `scaling_cur_freq`, `scaling_max_freq`,
`stats/time_in_state`, `stats/trans_table`.

### Cooling devices se nepoužívají jako páka

`/sys/class/thermal/cooling_deviceN/cur_state` sice **zapisovatelné je** (0644), ale
vlastníkem je thermal HAL a ten **hodnoty přepisuje zhruba každých 7 sekund**.
Držet je proti němu by znamenalo watcher smyčku rychlejší než 7 s — a to žere baterii.

Modul je používá **jen ke čtení**, aby ti ukázal aktuální throttling:

| Typ | max_state | Cluster | Index při jednom bootu |
|---|---|---|---|
| `thermal-cpufreq-0` | 9 | policy0 (Little, 4×A510) | `cooling_device8` |
| `thermal-cpufreq-1` | 14 | policy4 (Big, 4×A715) | `cooling_device10` |
| `thermal-cpufreq-2` | 14 | policy8 (Prime, 1×X3) | `cooling_device12` |
| `thermal-gpufreq-0` | 12 | GPU | `cooling_device24` |

> **Poslední sloupec neber jako platné číslo.** Číselné indexy `cooling_deviceN`
> **nejsou stabilní přes reboot** — podrobně v sekci 11. `pxtune` si je proto
> dohledává za běhu podle pole `type`.

Převod na frekvenci: `cur_state = N` ⇒ strop je frekvence na indexu
`(počet_frekvencí − 1 − N)` ve vzestupném seznamu frekvencí daného clusteru.
Příklad pro policy8 (15 frekvencí): `cur_state=2` ⇒ index 12 ⇒ 2687000 kHz;
`cur_state=12` ⇒ index 2 ⇒ 1164000 kHz.

**Tenhle převod je ověřený na zařízení**, a to na třech nezávislých bodech —
dopočtená frekvence se pokaždé shodovala se skutečně naměřeným stropem:

| Cooling device | `cur_state` | Dopočteno | Naměřený strop | Shoda |
|---|---|---|---|---|
| `thermal-cpufreq-0` | 8 / 9 | 610 MHz | `610000` | ✓ |
| `thermal-cpufreq-1` | 10 / 14 | 910 MHz | `910000` | ✓ |
| `thermal-cpufreq-2` | 12 / 14 | 1164 MHz | `1164000` | ✓ |

Proto se dá kartě „CPU — přiškrcení" ve WebUI věřit: není to odhad, je to
ověřený přepočet.

### Governor se nemění

Všechny tři clustery jedou na `sched_pixel` — Googlem laděný governor integrovaný
se schedulerem a s `power-service.pixel-libperfmgr`. Přepnutí na `schedutil`
nebo cokoli jiného rozbíjí věci, které na něm stojí. **Nesahá se na něj.**

### `sched_util_clamp_min` zůstává na 1024

`/proc/sys/kernel/sched_util_clamp_min` je **globální strop na to, jakou `uclamp.min`
smí kdokoli v systému požádat.** **Není to vynucená podlaha frekvence** — je to limit
požadavků. Stock hodnota **1024 znamená, že je tenhle strop naplno otevřený.**

Občas se dá poradit „nastav to na 0, ušetříš baterii". **To je špatně a je to škodlivé:**
nastavení na 0 by **zakázalo uclamp boost v celém systému**, včetně Googlího
`power-service.pixel-libperfmgr`, který ho používá k tomu, aby UI reagovalo.
Výsledek je celkově trhaný telefon.

`pixel_tune` na tuhle hodnotu **nesahá.**

### zram algoritmus se nemění

zram0 má po bootu **3969961984 B (3,70 GiB / 3,97 GB)** a algoritmus **`lz77eh`**.

`lz77eh` používá **hardwarový kompresní akcelerátor Emerald Hill** zabudovaný v Tensoru
(`/sys/devices/platform/16d00000.eh`, driver `google,eh`). Komprese proto stojí
**~0 CPU a ~0 tepla.**

`zstd` i `lz4` běží **na CPU** a jsou tu jednoznačně horší — vyšší spotřeba, víc tepla,
žádná kompenzující výhoda. **Modul algoritmus nikdy nemění.** Je to zapsané i v kódu:
při resetu zramu se původní algoritmus přečte a po resetu **obnoví zpátky**.

(Mimochodem je to i důvod, proč nemá smysl snižovat `swappiness`: swap je na tomhle
telefonu neobvykle levný. Proto ho nemění ani jeden z pěti profilů.)

**Velikost zramu měnit lze** — volitelně, přes `/data/adb/pixel_tune/zram.conf`:

```sh
ZRAM_DISKSIZE=3969961984      # v bajtech
```

Soubor **standardně neexistuje** a bez něj se na zram nesáhne vůbec. Když existuje:

- povolený rozsah je **268435456 B (256 MiB) až 7939923968 B** (fyzická RAM);
- mění se **jen v `post-fs-data.sh`**, kde je swap prázdný — `swapoff` za běhu je
  nebezpečný (riziko OOM);
- před `swapoff` se kontroluje, jestli se obsah swapu vejde do volné RAM
  (s rezervou); když ne, změna se **přeskočí**;
- při `boot_count ≥ 2` se změna přeskočí úplně;
- selže-li kterýkoli krok, provede se **rollback** na původní velikost i algoritmus.

### Pozor na jiné „optimalizátory" paměti

Řada kernel managerů nabízí přepnutí zram algoritmu na `lz4` nebo `zstd` a zmenšení
zramu, a prodává to jako optimalizaci. **Na tomhle telefonu je to krok zpátky**
a stojí za to vědět proč:

| Věc | Stock na tomhle zařízení |
|---|---|
| zram velikost | **3969961984 B (3,70 GiB / 3,97 GB)** |
| zram algoritmus | **`lz77eh`** |
| `vm.swappiness` | **60** (píše `/vendor/etc/init/init.pixel-mm-gs.rc`) |

`lz77eh` běží na **hardwarovém kompresním akcelerátoru Emerald Hill** zabudovaném
v Tensoru (`/sys/devices/platform/16d00000.eh`, driver `google,eh`), takže komprese
stojí **skoro nula CPU a nula tepla**. `lz4` i `zstd` běží **na CPU**. Přepnutí na ně
tedy odpojí kompresi od hardwarové jednotky a přesune ji na procesor — víc spotřeby,
víc tepla, žádná kompenzující výhoda. A zmenšení zramu k tomu ubere swap, který je
na tomhle zařízení neobvykle levný.

`pixel_tune` proto:

- **algoritmus nikdy nemění** (a při resetu zramu ho výslovně obnovuje zpátky),
- velikost zramu mění **jen** když si o to výslovně řekneš přes `zram.conf`,
- `swappiness` nemá nastavený **ani v jednom z pěti profilů**.

Jestli jsi na telefonu dřív používal jiný kernel manager, zkontroluj po jeho
odinstalaci, že jsou obě hodnoty zpátky na stocku:

```sh
su -c 'cat /sys/block/zram0/comp_algorithm'   # aktivní musí být [lz77eh]
su -c 'cat /sys/block/zram0/disksize'         # 3969961984
su -c 'cat /proc/sys/vm/swappiness'           # 60
```

### Refresh rate se globálně nesnižuje

Adaptivní 60–120 Hz zůstává (mode 2 = 120 Hz). Snížení na fixních 60 Hz je zásah,
který cítíš na každém swipu, a jeho přínos není na tomhle zařízení naměřený.
Jestli to chceš, Android má vlastní přepínač „Plynulý displej" v Nastavení.

### Nesahá se na thermal trip pointy

Zóny `BIG`, `MID`, `LITTLE`, `G3D`, `ISP`, `TPU`, `AUR` mají `mode=disabled` —
jejich sysfs trip pointy jsou **mrtvé**, zápis do nich nemá žádný efekt.
Reálně throttluje userspace HAL `android.hardware.thermal-service.pixel`
podle `/vendor/etc/thermal_info_config.json`, který **neměníme**.

Teploty se odtud jen čtou (`/sys/class/thermal/thermal_zoneN/temp`, milicelsia):

| Zóna (`type`) | Význam | Index při jednom bootu |
|---|---|---|
| `BIG` | junction Big clusteru | 0 |
| `MID` | junction Mid | 1 |
| `LITTLE` | junction Little | 2 |
| `G3D` | junction GPU | 3 |
| `quiet_therm` | **skin (povrch)** — tohle je zóna, kterou hlídá automat | 8 |
| `soc_therm` | SoC board | 11 |
| `charger_therm` | nabíječka | 12 |
| `display_therm` | displej | 13 |
| `battery` | baterie | 16 |

> **Zase: poslední sloupec není platné číslo.** Indexy `thermal_zoneN` se mění
> při každém rebootu — viz sekci 11. Zóna se identifikuje podle `type`, ne podle čísla.

### Jak telefon throttluje ve stocku

Aby bylo jasné, s čím pracuješ — naměřeno při 150 s trvalé zátěže na 9 jádrech:

| Věc | Naměřeno |
|---|---|
| Strop Little | ~1036 MHz = **61 %** HW maxima |
| Strop Big | 910 MHz = **38 %** |
| Strop Prime | 1164 MHz = **40 %** |
| Junction při tom | jen **58 °C** |
| Skin při tom | **40,5 °C** |
| Špička junction v prvních ~40 s | **81 °C** |
| GPU throttling (`cdev_gpu`) | **0 po celou dobu — vůbec** |
| Zotavení (`MaxReleaseStep=1`) | **~84 s**; 60 s po konci zátěže se **nic** neuvolnilo |

Tři věci, které stojí za zapamatování:

1. **Google throttluje agresivně a preventivně**, ne až když je horko. 38 % maxima
   při 58 °C junction není teplotní nouze, to je konzervativní politika.
2. **GPU tohle vůbec neřeší.** `cdev_gpu` zůstal celých 150 s na nule — GPU nebyla ani
   jednou přiškrcená. Zdroj tepla i brzdy jsou CPU clustery, ne grafika. Proto profily
   cílí na **teplotní špičku CPU**, ne na rozlišení nebo GPU (viz sekci 7).
3. **Zotavení je pomalé.** `MaxReleaseStep=1` v HAL configu znamená uvolňování po
   jednom kroku: po konci zátěže trvá ~84 s, než se stropy uvolní, a prvních
   60 s se nestane nic. Když měříš efekt profilu benchmarkem, **nech mezi běhy aspoň
   dvě minuty klidu**, jinak měříš zbytkový throttling, ne svůj profil.

---

## 10. Integrity a bankovnictví

Věcně, bez strašení a bez ujišťování.

### Co pixel_tune dělá a nedělá

| | |
|---|---|
| Zapisuje do `/system` nebo `/vendor` | **Ne.** Žádný overlay ani bind mount. |
| Mění SELinux | **Ne.** Zůstává **Enforcing**. Žádné `setenforce 0`. |
| Používá accessibility službu | **Ne.** |
| Mění build props / fingerprint (`ro.*`) | **Ne.** Jediný prop, na který sahá, je `vendor.thermal.<SENZOR>.profile` — runtime prop thermal HALu, ne identita zařízení. |
| Instaluje aplikaci | **Ne.** UI je WebUI uvnitř KernelSU manageru. |
| Kam zapisuje | `sysfs`, `/dev/cpuctl`, `/proc/sys`, `settings` (rozlišení a hustota) a vlastní `/data/adb/pixel_tune/`. |

### Co z toho plyne

Kromě `charge_stop_level` a nastavení displeje jsou všechny zásahy modulu
**runtime hodnoty v `sysfs`, které restart smaže.** Nezanechávají v systémovém obrazu
žádnou stopu.

**Ale buď realistický:** to, co detekce hledá, je **odemčený bootloader a root jako
takový**, ne tenhle konkrétní modul. Ten na tvém telefonu už dávno je. Že `pixel_tune`
nezapisuje do `/system`, znamená, že **nepřidává novou detekční plochu** — neznamená to,
že by cokoli schovával.

Skrývání řeší úplně jiné moduly, které už máš nainstalované: `playintegrityfix`,
`tricky_store`, `susfs4ksu`, `zygisk-assistant`, `hma_oss_zygisk`.
`pixel_tune` s nimi **nesoupeří ani je nenahrazuje** — nedělá nic, co by potřebovalo
skrývat, ani nic, co by jejich práci narušilo.

Když ti bankovní aplikace přestane fungovat po instalaci pixel_tune, **první podezřelý
je něco jiného** (aktualizace Play Integrity, změna v `tricky_store`, aktualizace té
aplikace). Ale ověř si to: `pxtune revert`, odinstaluj modul, restartuj, zkus znovu.
Pokud problém zmizí, je to nález — podle návrhu by k tomu dojít nemělo.

---

## 11. Řešení problémů

| Symptom | Co s tím |
|---|---|
| **Telefon nenaběhne / bootloop** | Drž **Volume Down** při startu → KernelSU safe mode. Pozn.: po **třech** neúspěšných bootech se modul vypne **sám** přes `boot_count`. |
| **Nevidím na displej po změně rozlišení** | **Počkej 60 sekund** — pojistka vrátí nativní rozlišení sama. Když ne: `adb shell wm size reset` + `adb shell settings put secure display_density_forced 353`. Viz sekci 7. |
| **Rozlišení se vrátilo, ale písmo je menší než dřív** | To je očekávané. `res reset` a pojistka nastaví DPI **420**, ne tvých **353**. Oprav: `su -c 'pxtune revert'` nebo `settings put secure display_density_forced 353`. |
| **Profil se „neaplikoval"** | `su -c 'pxtune log -n 50'`. Každý zápis se loguje jako `stará → nová`; při chybě se pokračuje dál, takže důvod je v logu vždycky. Pak `su -c 'pxtune selftest'`. |
| **Po bootu se profil aplikuje se zpožděním** | Tak to má být. `service.sh` čeká **20 s** (`SETTLE=20`), protože dřív neběží `system_server`. |
| **`pxtune: not found`** | Modul není aktivní. Zkontroluj, že existuje `/data/adb/modules/pixel_tune/`, že tam **není** `DISABLE`, a že telefon není v safe mode. |
| **Adaptivní automat nefunguje / nespustí se** | `su -c 'pxtune auto status'` → musí říct `on` **a** vypsat pid. Když neběží, hledej v logu řádky s `[auto]`. Nejčastější příčina: v `/system/etc/event-log-tags` nenašel tag pro popředí ani pro obrazovku — to démon loguje jako `ERROR` a bez tagů opravdu nic nepřepne. |
| **Automat přepíná profily, i když nechci** | `su -c 'pxtune profile <name>'` (bez `--auto`) položí `manual_override` a automat se stáhne. Úplné vypnutí: `pxtune auto off`. |
| **Automat mi zařadil aplikaci špatně** | Klasifikace je naučená v `appstats`. Přebij ji ručně: do `appstats.override` zapiš řádek `<balíček> <game\|heavy\|normal\|light>`. Override má přednost před měřením. |
| **Ručně zvolený profil „nedrží"** | Zkontroluj, že existuje `/data/adb/pixel_tune/manual_override`. Když ne, spustil jsi někdy `pxtune profile auto`. |
| **Telefon je horký / škube se při focení** | Systém si `vendor.thermal.*.profile` přepíná sám (kamera na `camera`). Nepoužívej profil `game`, který ten prop nastavuje. |
| **Profil `game` nic nezměnil** | Očekávatelné. Thermal profil `game` je **neověřený mechanismus**. Ověření: po ~150 s zátěže porovnej `scaling_cur_freq` policy4/policy8 proti naměřeným 910000 / 1164000. Když se neliší, mechanismus nefunguje a `THERMAL_PROFILE_*` v `game.conf` vyprázdni. |
| **Modul mi žere baterii** | Zkontroluj profil: `UCLAMP_*_MIN > 0` znamená vyšší spotřebu z definice (má ho `performance` a `game`). Přepni na `balanced`, `powersave` nebo `night`. |
| **Benchmark ukazuje horší čísla než minule** | Zotavení z throttlingu trvá **~84 s** a prvních 60 s se neuvolní nic. Nech mezi běhy aspoň 2 minuty klidu. |
| **Nabíjí se jen do 80 %** | `su -c 'pxtune charge off'`. Zkontroluj i profil — **`night` nastavuje 80 % sám** a udělá to znovu při každém přepnutí. |
| **zram má jinou velikost, než čekám** | Zkontroluj `/data/adb/pixel_tune/zram.conf`. Bez něj se na zram nesahá. Důvod přeskočení (OOM guard, `boot_count ≥ 2`, hodnota mimo rozsah) je v logu. |
| **`pxtune` skončil s kódem 1** | Chyba argumentů: neznámý příkaz, profil, preset, nebo hodnota mimo rozsah (např. GPU frekvence mimo povolený seznam). |
| **`pxtune` skončil s kódem 2** | Chyba běhu: zápis selhal, chybí `settings`/`cmd`, nebo selftest našel chybějící cesty. Podrobnost v logu. |
| **Něco je rozbité a nevím co** | `su -c 'pxtune revert'`. Vrátí všechno na stock a nic nesmaže. |
| **Bankovní aplikace přestala fungovat** | Viz sekci 10. `pxtune revert` → odinstalovat → restart → otestovat. |

### Dvě pasti, do kterých spadneš, když si budeš psát vlastní skript

Obojí je ověřené na tomhle zařízení a obojí vypadá jako fungující kód.

#### 1. Číselné indexy `thermal_zoneN` a `cooling_deviceN` se mění při každém rebootu

Tohle není teoretická možnost, je to naměřené:

| Co | Před rebootem | Po rebootu |
|---|---|---|
| `soc_therm` | `thermal_zone11` | `thermal_zone13` |
| `battery` | `thermal_zone16` | `thermal_zone12` |
| `thermal-cpufreq-2` | `cooling_device12` | `cooling_device11` |

**Zadrátovaný index tedy po restartu čte úplně jiné čidlo** — a nijak se to neprojeví,
skript dál vesele vypisuje čísla. Jen jsou to čísla něčeho jiného.

`pxtune` proto čísla **nezadrátovává**: při startu projde `/sys/class/thermal/*`
a rozpozná zóny i cooling devices **za běhu podle pole `type`**. Zadrátované indexy
v kódu existují jen jako fallback pro případ, že by scan selhal.

Když si píšeš vlastní skript, **musíš dělat totéž** — nebo použít stabilní symlinky
od Googlu, což je jednodušší:

```sh
/dev/thermal/tz-by-name/quiet_therm/temp
/dev/thermal/cdev-by-name/thermal-cpufreq-2/cur_state
```

#### 2. `read -r v < /proc/sys/vm/swappiness` vrátí `4` místo `40`

Ano, opravdu. **Useknuté na první bajt.**

```sh
cat  /proc/sys/vm/swappiness   # 40
read -r v < /proc/sys/vm/swappiness; echo "$v"   # 4   ← ŠPATNĚ
```

> Pozn.: v době tohohle měření byla hodnota 40, ne stock 60 (viz sekci 9) — něco ji
> na zařízení přepisovalo. Na podstatu pasti to nemá vliv: useknutí na první bajt
> nastane u jakékoli hodnoty.

Příčina: procfs systl hlásí `st_size=0`, takže mksh nemá jak zjistit délku a čte
**po jednom bajtu**, přičemž skončí dřív, než by měl.

**Postižené je jen `/proc/sys/*`.** Na `/sys/...`, `/proc/uptime` i `/proc/<pid>/stat`
funguje `read` správně — proto to tak snadno unikne pozornosti:

| Cesta | `cat` | `read` |
|---|---|---|
| `/proc/sys/vm/swappiness` | `40` | `4` ✗ |
| `/proc/sys/kernel/sched_util_clamp_min` | `1024` | `1` ✗ |
| `/sys/class/thermal/.../temp` | `63000` | `63000` ✓ |

**Používej `cat` nebo `head -n1`.** V `pxtune` jde proto veškeré čtení přes funkci
`rd()`, která používá `head -n1`. Je to tam schválně jednotné pro všechny cesty:
z těchhle hodnot se generuje `backup/stock.conf` a useknutá hodnota by při revertu
zapsala třeba `swappiness=4` místo `40`.

---

## 12. Kompletní revert do původního stavu

Pořadí je důležité — modul se odinstaluje **až nakonec**, a to na **plně
nabootovaném systému** (jinak se rozlišení nevrátí).

### 1. Vrať runtime hodnoty na stock

```sh
su -c 'pxtune revert'
```

Přehraje zpět snapshot z `backup/stock.conf`: uclamp (včetně `camera-daemon`
a `nnapi-hal`), GPU (min → max → policy, v tomhle pořadí, aby se hodnoty nebránily),
vm, I/O readahead, thermal profily, `charge_stop_level` i `charge_start_level`,
a **displej včetně DPI 353**.

### 2. Vypni automat

```sh
su -c 'pxtune auto off'
```

### 3. Zkontroluj displej

`revert` už ho vrátil, ale ověř si to:

```sh
adb shell settings get global display_size_forced      # očekáváno: null / prázdné
adb shell settings get secure display_density_forced   # očekáváno: 353
```

Když nesedí, dorovnej ručně:

```sh
adb shell settings delete global display_size_forced
adb shell settings put secure display_density_forced 353
```

**Nepoužívej `pxtune res reset`** — ten nastaví 420.

### 4. Zkontroluj nabíjení

```sh
su -c 'cat /sys/devices/platform/google,charger/charge_stop_level'   # 100
su -c 'cat /sys/devices/platform/google,charger/charge_start_level'  # 0
```

### 5. Vrať Game Mode u aplikací, kterým jsi ho měnil

`pxtune revert` **tohle nevrací** — Game Mode je systémové per-app nastavení mimo modul.
Pro každý balíček zvlášť:

```sh
su -c 'pxtune game <PACKAGE>'                              # co je nastaveno
cmd game set --downscale disable <PACKAGE>
cmd game mode standard <PACKAGE>
```

### 6. Rozhodni se o zramu a profilech

`uninstall.sh` **nemaže** `/data/adb/pixel_tune/`. Zůstanou ti profily,
`backup/stock.conf`, `auto`, `zram.conf`, naučené `appstats` a log — schválně, abys
o ně nepřišel při přeinstalaci nebo aktualizaci modulu.

Chceš-li opravdu nulu, vytvoř **před** odinstalací:

```sh
su -c 'touch /data/adb/pixel_tune/PURGE'
```

Pak `uninstall.sh` smaže celý `/data/adb/pixel_tune/` včetně profilů a zálohy.

> **Varování:** tím smažeš i `backup/stock.conf`. Dokud existuje, můžeš se ke stocku
> vrátit i po přeinstalaci. Bez něj si nový `pixel_tune` udělá snapshot
> **z aktuálního stavu** — a když ten aktuální stav nebude stock, uloží si jako „stock"
> něco, co jím není. **Používej `PURGE` až tehdy, když víš, že je všechno v pořádku.**

### 7. Odinstaluj modul

KernelSU-Next manager → Moduly → `Pixel Tune` → Odinstalovat → **restart**.

`uninstall.sh` sám zabije démona, položí `DISABLE`, spustí `revert` a `res reset`
a uklidí běhové soubory (`boot_count`, `res_pending`, `manual_override`).
Kroky 1–5 jsi udělal proto, abys nebyl závislý na tom, v jaké fázi se `uninstall.sh`
spustí — v post-fs-data fázi mu `settings` ani `cmd` nefungují.

**Pozor:** `uninstall.sh` volá `pxtune res reset`, takže ti po odinstalaci může
zůstat **DPI 420**. Zkontroluj krok 3 znovu po restartu.

### 8. Ověření po restartu

```sh
adb shell getenforce                              # Enforcing
adb shell cat /sys/block/zram0/comp_algorithm     # aktivní musí být [lz77eh]
adb shell cat /sys/block/zram0/disksize           # 3969961984  (3,70 GiB)
adb shell cat /proc/sys/vm/swappiness             # 60   (cat, ne read — viz sekci 11)
adb shell settings get secure display_density_forced   # 353
adb shell cat /sys/class/power_supply/battery/cycle_count
```

zram se vrátí na vendor stock **sám při prvním bootu bez modulu** — velikost není
perzistentní a `post-fs-data.sh` už neběží.

---

## Otevřené body v této verzi

Věci, které v dokumentaci zůstaly nedořešené, protože je nemám z čeho ověřit:

1. **`pxtune res reset` nastaví DPI 420 místo tvých 353.** Sekce 7. Týká se i
   60sekundové pojistky, tlačítek ve WebUI a `uninstall.sh`.
2. **Jména presetů ve WebUI** (`1080p`/`900p`/`720p`) neodpovídají CLI
   (`native`/`900x2000`/`810x1800`/`720x1600`). Fallback ve WebUI se použije jen tehdy,
   když je `status --json` nepošle — ale když se použije, kliknutí skončí chybou. Sekce 4.
3. **Jméno instalačního ZIPu** není nikde uvedeno. Sekce 2.
4. **Thermal profil `game` je neověřený** — profil `game.conf` ho nastavuje s výslovným
   varováním a postupem, jak ho ověřit. Sekce 11.
5. **Dopad automatu na výdrž není změřený.** Z návrhu plyne, že je malý, ale srovnávací
   měření (démon zapnutý vs. vypnutý) chybí. Sekce 6.
6. **Stock hodnota I/O readahead není známá** a žádné I/O měření neexistuje. Proto
   `IO_READAHEAD_KB` nenastavuje ani jeden z pěti profilů. Sekce 3.
7. **Dopad `GPU_POWER_POLICY`** (`coarse_demand` vs. `adaptive` vs. `always_on`)
   **na spotřebu není změřený.** Tematicky by `coarse_demand` seděl do profilu `night`,
   ale bez měření se nehádá. Dá se změřit. Sekce 3.
8. **Není měření GPU pod trvalou zátěží** — naměřených 150 s bylo CPU-only. Proto jsou
   GPU stropy v `powersave`/`night` konzervativní odhad, ne odvozené číslo. Sekce 3.
9. **Není změřeno, jestli je zahnání pozadí na Little celkově úspornější** —
   proti stojí race-to-idle a energy model v debugfs není na zařízení dostupný.
   Proto má `night` `background.max=17`, ale `powersave` volnějších `30`. Sekce 3.
10. **`pxtune auto on|off` proces démona nestartuje ani nezastavuje** — jen přepíše
    soubor `auto`. Funkčně to stačí (démon ho respektuje), ale proces běží dál.
    Startovat/zastavovat se musí přes `pxtune-auto start|stop`. Sekce 6.
11. **`pxtune profile auto` neposílá démonovi SIGHUP**, takže stav nepřehodnotí
    okamžitě, ale až při nejbližší události nebo tiku. Sekce 6.
12. **Konkrétní dvojice indexů thermal zón před/po rebootu** (např. `soc_therm`
    `zone11` → `zone13`) **není ve SPEC.md.** Samotné pravidlo — že se indexy nesmí
    zadrátovat a zóna se hledá podle `type` — **je ověřené v kódu** (`resolve_thermal_ids`
    v `bin/pxtune`), takže na doporučení to nic nemění. Sekce 11.

### Vyřešeno oproti dřívější verzi tohoto dokumentu

- `bin/pxtune-auto` **už existuje a funguje** (dřív bylo uvedeno, že chybí). Sekce 6.
- **Neshoda jména stavového souboru automatu je pryč** — CLI, `service.sh` i démon
  dnes čtou tentýž `/data/adb/pixel_tune/auto`. Sekce 6.
- **Efekt uclampu na Little cluster už není neznámý** — capacity tabulka je naměřená
  (Little 182 / Big 725 / Prime 1024). Sekce 3.
- **Velikost zramu opravena** na 3969961984 B = 3,70 GiB / 3,97 GB (dřívější
  „3,79 GB" byl chybný údaj). Sekce 9.
- **Verze CLI opravena** na `1.1.0` (`PXTUNE_VERSION` v `bin/pxtune`); modul samotný
  je podle `module.prop` dál `v1.0`.
- **Odstraněny údaje, které nejdou ověřit ve SPEC.md ani v souborech modulu** —
  jmenovitě tabulka „přiškrcení v nečinnosti při skin 44,6 °C" (sekce 1 a 9)
  a konkrétní hodnoty připisované dřívějšímu kernel manageru (sekce 9).
  Technický závěr obou pasáží zůstal, protože ten ověřitelný je.
