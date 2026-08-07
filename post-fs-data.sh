#!/system/bin/sh
#
# pixel_tune / post-fs-data.sh
#
# RANÁ FÁZE BOOTU. Podle dokumentace KernelSU je post-fs-data BLOKUJÍCÍ:
# boot čeká, dokud skript neskončí, nejvýše ~10 s. Proto tady NENÍ:
#   - žádný sleep, žádné čekání na prop, žádná smyčka
#   - žádný setprop (dokumentace: "setprop will deadlock the boot process")
#   - nic z profilů (uclamp, GPU, thermal, charging, resolution) -> to dělá service.sh
#
# Tenhle skript dělá POUZE dvě věci:
#   1) bezpečnostní logiku bootloop ochrany (boot_count / DISABLE)
#   2) volitelnou změnu velikosti zram (jediné místo, kde je swapoff bezpečný,
#      protože swap je v této fázi prázdný — viz SPEC "Paměť")
#
# Skript NIKDY neskončí nenulovým kódem a nikdy nepoužívá `set -e`.
# Je idempotentní: opakované spuštění se stejným configem neudělá nic
# (velikost už sedí -> early return).

STATE=/data/adb/pixel_tune
LOG="$STATE/pxtune.log"
LOG_MAX=524288                 # 512 kB, rotace dle SPEC "KONTRAKT: log"

ZRAM_CONF="$STATE/zram.conf"   # volitelný, viz OTEVŘENÉ OTÁZKY v reportu
ZSYS=/sys/block/zram0

BOOT_FAIL_LIMIT=3              # >= 3 neúspěšné boty -> DISABLE (SPEC "Bezpečnost")
BOOT_ZRAM_SKIP=2               # >= 2 neúspěšné boty -> zram raději nesahat
SWAP_HEADROOM_KB=307200        # 300 MB rezerva pro guard před swapoff

# ---------------------------------------------------------------------------
# log — formát dle SPEC: [YYYY-MM-DD HH:MM:SS] [úroveň] zpráva
# Záměrně je inline (a ne v sdílené knihovně): post-fs-data.sh musí být plně
# soběstačný. Kdyby závisel na dalším souboru modulu, jeho chybějící/poškozená
# kopie by shodila ranou fázi bootu — tedy přesně to, čemu se vyhýbáme.
# ---------------------------------------------------------------------------
log() {
	_lvl="$1"
	shift
	[ -d "$STATE" ] || return 0
	if [ -f "$LOG" ]; then
		_sz=$(stat -c %s "$LOG" 2>/dev/null)
		case "$_sz" in
		'' | *[!0-9]*) _sz=0 ;;
		esac
		[ "$_sz" -gt "$LOG_MAX" ] && mv -f "$LOG" "$LOG.old" 2>/dev/null
	fi
	{ echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$_lvl] $*" >>"$LOG"; } 2>/dev/null
	return 0
}

# wr <cesta> <hodnota> — zápis do souboru, vrací úspěch/neúspěch.
#
# Redirekce se vyhodnocují zleva doprava, takže `echo x >soubor 2>/dev/null`
# hlášku "Permission denied" NEPOTLAČÍ — v tu chvíli ještě stderr přesměrované
# není a hláška uteče do bootlogu. Proto se celý blok obaluje složenými
# závorkami a stderr se přesměrovává až na něm.
#
# (Plná verze `wr` s logováním "stará → nová" žije v CLI `pxtune`; tady je
# záměrně minimální, aby post-fs-data.sh nezávisel na dalších souborech.)
wr() {
	{ echo "$2" >"$1"; } 2>/dev/null
}

# přečte celé číslo ze souboru, jinak vrátí prázdno
read_int() {
	[ -f "$1" ] || return 0
	_v=$(cat "$1" 2>/dev/null)
	case "$_v" in
	'' | *[!0-9]*) return 0 ;;
	esac
	echo "$_v"
}

# num_gt A B -> pravda (0), když desítkové celé číslo A > B.
#
# ZÁMĚRNĚ bez $(( )) a bez `[ -gt ]`: /system/bin/sh je na Androidu mksh a to
# počítá v 32bitových signed intech. Velikost zramu (stock 3969961984 B) se do
# nich nevejde a porovnání by tiše přeteklo. Porovnáváme proto jako řetězce:
# po odstranění vodících nul rozhoduje nejdřív délka, při shodné délce
# lexikografické pořadí (u čísel stejné délky je totožné s číselným).
num_gt() {
	_a=$(echo "$1" | sed 's/^0*//')
	_b=$(echo "$2" | sed 's/^0*//')
	[ -n "$_a" ] || _a=0
	[ -n "$_b" ] || _b=0
	_la=${#_a}
	_lb=${#_b}
	if [ "$_la" -ne "$_lb" ]; then
		[ "$_la" -gt "$_lb" ]
		return $?
	fi
	[ "$_a" \> "$_b" ]
}

# hodnota klíče z /proc/meminfo v kB
meminfo_kb() {
	_v=$(grep -m1 "^$1:" /proc/meminfo 2>/dev/null | tr -dc '0-9')
	case "$_v" in
	'' | *[!0-9]*) return 0 ;;
	esac
	echo "$_v"
}

mkdir -p "$STATE" 2>/dev/null

# ---------------------------------------------------------------------------
# 1) DISABLE — uživatelský nebo automatický kill switch. Okamžitý konec.
# ---------------------------------------------------------------------------
if [ -f "$STATE/DISABLE" ]; then
	log INFO "post-fs-data: existuje DISABLE, modul neaktivní (smaž ho pro znovuzapnutí)"
	exit 0
fi

# ---------------------------------------------------------------------------
# 2) Bootloop ochrana
#
#    Kontrakt: post-fs-data.sh počítadlo INKREMENTUJE, service.sh ho na konci
#    NULUJE. Nenulové počítadlo tedy znamená "minulý boot nedoběhl až do konce
#    service.sh". Tři takové boty za sebou = modul se sám vypne.
# ---------------------------------------------------------------------------
BOOT_COUNT=$(read_int "$STATE/boot_count")
[ -n "$BOOT_COUNT" ] || BOOT_COUNT=0

if [ "$BOOT_COUNT" -ge "$BOOT_FAIL_LIMIT" ]; then
	{
		echo "auto-disabled by post-fs-data.sh"
		echo "date=$(date '+%Y-%m-%d %H:%M:%S')"
		echo "boot_count=$BOOT_COUNT"
		echo "reason=$BOOT_FAIL_LIMIT po sobe jdoucich bootu nedobehlo service.sh"
	} 2>/dev/null >"$STATE/DISABLE"
	# počítadlo hned nulujeme: po ručním smazání DISABLE má uživatel plný
	# rozpočet 3 pokusů, ne okamžité znovu-vypnutí.
	wr "$STATE/boot_count" 0
	sync 2>/dev/null
	log ERROR "post-fs-data: boot_count=$BOOT_COUNT >= $BOOT_FAIL_LIMIT -> vytvořen DISABLE, modul se vypnul"
	exit 0
fi

BOOT_COUNT=$((BOOT_COUNT + 1))
wr "$STATE/boot_count" "$BOOT_COUNT"
# sync je tu POVINNÝ: kdyby zápis zůstal jen v page cache a zařízení se pak
# zaseklo/rebootovalo, počítadlo by se neposunulo a ochrana by nikdy nesepnula.
sync 2>/dev/null
log INFO "post-fs-data: start, boot_count=$BOOT_COUNT/$BOOT_FAIL_LIMIT"

# ---------------------------------------------------------------------------
# 3) zram
#
#    SPEC: stock je 3969961984 B / lz77eh a je SPRÁVNÝ — lz77eh jede na HW
#    akcelerátoru Emerald Hill (~0 CPU, ~0 tepla). ALGORITMUS SE NIKDY NEMĚNÍ.
#    Měníme výhradně velikost a jen tehdy, když si ji uživatel explicitně
#    vyžádal v $ZRAM_CONF. Když soubor neexistuje nebo je hodnota prázdná,
#    nesaháme na zram vůbec (kontrakt "prázdné = nesahat").
# ---------------------------------------------------------------------------

ZDEV=''
ZPRIO=''
ORIG_SIZE=''
ORIG_ALG=''

# vybraný algoritmus z "lzo lz4 [lz77eh] zstd"
zram_alg() {
	cat "$ZSYS/comp_algorithm" 2>/dev/null |
		tr ' ' '\n' | grep -m1 '^\[' | tr -d ']['
}

# obnoví přesně to, co bylo před naším zásahem
zram_rollback() {
	wr "$ZSYS/reset" 1
	[ -n "$ORIG_ALG" ] && wr "$ZSYS/comp_algorithm" "$ORIG_ALG"
	wr "$ZSYS/disksize" "$ORIG_SIZE"
	mkswap "$ZDEV" >/dev/null 2>&1
	if [ -n "$ZPRIO" ]; then
		swapon -p "$ZPRIO" "$ZDEV" >/dev/null 2>&1 || swapon "$ZDEV" >/dev/null 2>&1
	else
		swapon "$ZDEV" >/dev/null 2>&1
	fi
	if grep -q "^$ZDEV[[:space:]]" /proc/swaps 2>/dev/null; then
		log WARN "zram: rollback OK, obnoveno disksize=$ORIG_SIZE alg=$ORIG_ALG"
		return 0
	fi
	log ERROR "zram: ROLLBACK SELHAL — zařízení běží BEZ swapu, po rebootu se obnoví stock"
	return 1
}

zram_apply() {
	[ -f "$ZRAM_CONF" ] || return 0
	[ -d "$ZSYS" ] || {
		log WARN "zram: $ZSYS neexistuje, přeskakuji"
		return 0
	}

	# poslední dva boty nedoběhly -> jediná riziková věc v rané fázi se vynechá
	if [ "$BOOT_COUNT" -ge "$BOOT_ZRAM_SKIP" ]; then
		log WARN "zram: boot_count=$BOOT_COUNT, předchozí boot nedoběhl -> změna zram přeskočena"
		return 0
	fi

	# Config se ZÁMĚRNĚ neparsuje přes `. "$ZRAM_CONF"`. Syntaktická chyba
	# v sourcovaném souboru shodí celý neinteraktivní shell — a to je v rané,
	# BLOKUJÍCÍ fázi bootu přesně to, co si nemůžeme dovolit. Navíc by šlo
	# o spuštění libovolného kódu z datového souboru.
	ZRAM_DISKSIZE=$(grep -m1 '^[ 	]*ZRAM_DISKSIZE[ 	]*=' "$ZRAM_CONF" 2>/dev/null |
		cut -d= -f2- | tr -d " \\t\\r\"'")

	[ -n "$ZRAM_DISKSIZE" ] || return 0
	case "$ZRAM_DISKSIZE" in
	*[!0-9]*)
		log ERROR "zram: ZRAM_DISKSIZE='$ZRAM_DISKSIZE' není celé číslo v bajtech, ignoruji"
		return 0
		;;
	esac

	# Meze:
	#   ZMIN = 256 MiB — pod tím zram nemá smysl.
	#   ZMAX = fyzická RAM zařízení = 7753832 kB * 1024 = 7939923968 B
	#          (SPEC, sekce "Zařízení": 8 GB RAM / MemTotal 7753832 kB).
	# Hodnota je pevný řetězec právě proto, že násobení 1024 by v mksh
	# přeteklo 32bitový int (viz num_gt).
	ZMIN=268435456
	ZMAX=7939923968
	if num_gt "$ZMIN" "$ZRAM_DISKSIZE" || num_gt "$ZRAM_DISKSIZE" "$ZMAX"; then
		log ERROR "zram: ZRAM_DISKSIZE=$ZRAM_DISKSIZE mimo povolený rozsah $ZMIN..$ZMAX B, ignoruji"
		return 0
	fi

	MEM_TOTAL_KB=$(meminfo_kb MemTotal)
	[ -n "$MEM_TOTAL_KB" ] || MEM_TOTAL_KB='?'

	ORIG_SIZE=$(read_int "$ZSYS/disksize")
	[ -n "$ORIG_SIZE" ] || {
		log WARN "zram: nelze přečíst disksize, přeskakuji"
		return 0
	}

	# IDEMPOTENCE: požadovaná velikost už platí -> nic nedělat
	if [ "$ORIG_SIZE" = "$ZRAM_DISKSIZE" ]; then
		log INFO "zram: disksize už je $ZRAM_DISKSIZE B, beze změny"
		return 0
	fi

	ORIG_ALG=$(zram_alg)
	[ -n "$ORIG_ALG" ] || ORIG_ALG=''

	# aktivní swap zařízení + jeho priorita (zachováme ji, ať nepřepíšeme
	# pořadí zadané vendorem)
	ZDEV=$(grep -m1 '^/dev/[a-z/]*zram0[[:space:]]' /proc/swaps 2>/dev/null | cut -d' ' -f1)
	[ -n "$ZDEV" ] || ZDEV=/dev/block/zram0
	ZPRIO=$(grep -m1 "^$ZDEV[[:space:]]" /proc/swaps 2>/dev/null |
		tr -s ' \t' ' ' | cut -d' ' -f5)
	case "$ZPRIO" in
	'' | *[!0-9-]*) ZPRIO='' ;;
	esac

	# -----------------------------------------------------------------
	# GUARD: swapoff nasype všechna odswapovaná data zpět do RAM.
	# Když je ve swapu víc dat, než kolik je volné RAM minus 300 MB rezerva,
	# swapoff by skončil OOM killerem. Radši nic neděláme.
	# V post-fs-data je swap prakticky prázdný, takže guard normálně projde;
	# je tu pro případ ručního spuštění skriptu za běhu systému.
	# -----------------------------------------------------------------
	SWAP_TOTAL=$(meminfo_kb SwapTotal)
	SWAP_FREE=$(meminfo_kb SwapFree)
	MEM_AVAIL=$(meminfo_kb MemAvailable)
	[ -n "$SWAP_TOTAL" ] || SWAP_TOTAL=0
	[ -n "$SWAP_FREE" ] || SWAP_FREE=0
	[ -n "$MEM_AVAIL" ] || MEM_AVAIL=$(meminfo_kb MemFree)
	[ -n "$MEM_AVAIL" ] || MEM_AVAIL=0

	SWAP_USED=$((SWAP_TOTAL - SWAP_FREE))
	[ "$SWAP_USED" -lt 0 ] && SWAP_USED=0
	BUDGET=$((MEM_AVAIL - SWAP_HEADROOM_KB))

	if [ "$SWAP_USED" -gt "$BUDGET" ]; then
		log WARN "zram: guard — ve swapu $SWAP_USED kB, volná RAM $MEM_AVAIL kB minus rezerva ${SWAP_HEADROOM_KB} kB = $BUDGET kB; swapoff by hrozil OOM, přeskakuji"
		return 0
	fi

	log INFO "zram: měním disksize $ORIG_SIZE -> $ZRAM_DISKSIZE B (MemTotal=${MEM_TOTAL_KB} kB, dev=$ZDEV, prio=${ZPRIO:-auto}, alg=$ORIG_ALG zůstává)"

	if ! swapoff "$ZDEV" >/dev/null 2>&1; then
		log ERROR "zram: swapoff $ZDEV selhal, nechávám stock konfiguraci"
		return 0
	fi

	wr "$ZSYS/reset" 1

	# Reset vynuluje disksize. comp_algorithm se dá zapsat jen když je
	# disksize == 0, takže pokud reset algoritmus shodil na default,
	# TEĎ ho vrátíme na původní hodnotu. Není to změna algoritmu — je to
	# jeho obnova. lz77eh (Emerald Hill) musí zůstat.
	NOW_ALG=$(zram_alg)
	if [ -n "$ORIG_ALG" ] && [ "$NOW_ALG" != "$ORIG_ALG" ]; then
		wr "$ZSYS/comp_algorithm" "$ORIG_ALG"
		log INFO "zram: comp_algorithm po resetu byl '$NOW_ALG', obnoven na '$ORIG_ALG'"
	fi

	if ! wr "$ZSYS/disksize" "$ZRAM_DISKSIZE"; then
		log ERROR "zram: zápis disksize=$ZRAM_DISKSIZE selhal, rollback"
		zram_rollback
		return 0
	fi

	if ! mkswap "$ZDEV" >/dev/null 2>&1; then
		log ERROR "zram: mkswap $ZDEV selhal, rollback"
		zram_rollback
		return 0
	fi

	if [ -n "$ZPRIO" ]; then
		swapon -p "$ZPRIO" "$ZDEV" >/dev/null 2>&1 || swapon "$ZDEV" >/dev/null 2>&1
	else
		swapon "$ZDEV" >/dev/null 2>&1
	fi

	# ověřujeme přes /proc/swaps, ne přes exit kód — je to jediný spolehlivý
	# důkaz, že swap opravdu běží
	if ! grep -q "^$ZDEV[[:space:]]" /proc/swaps 2>/dev/null; then
		log ERROR "zram: swapon $ZDEV selhal, obnovuji původní konfiguraci"
		zram_rollback
		return 0
	fi

	NEW_SIZE=$(read_int "$ZSYS/disksize")
	NEW_ALG=$(zram_alg)
	log INFO "zram: hotovo — disksize=$NEW_SIZE B, comp_algorithm=$NEW_ALG"
	return 0
}

zram_apply

exit 0
