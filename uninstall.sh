#!/system/bin/sh
#
# pixel_tune / uninstall.sh
#
# KernelSU tenhle skript volá při odstranění modulu. Dokumentace KernelSU říká
# jen "executed when KernelSU removes your module" a zároveň, že příznak
# `remove` znamená "the module will be removed next reboot" — v praxi to tedy
# může běžet ve DVOU různých kontextech:
#
#   A) hned z managera / `ksud module uninstall` na plně nabootovaném systému
#      => `settings` i `cmd` jsou dostupné,
#   B) v post-fs-data fázi následujícího bootu při úklidu modulů
#      => system_server NEBĚŽÍ, `settings put` a `cmd game` selžou,
#         a navíc je fáze blokující (~10 s) => žádné čekání ani sleep.
#
# Skript proto obě varianty detekuje přes `sys.boot_completed` a v kontextu B
# ty části, které potřebují system_server, přeskočí a nahlásí je do logu.
#
# Skript nikdy neskončí nenulovým kódem a je idempotentní (dvojí spuštění
# nic nerozbije — `revert` i `rm -f` jsou opakovatelné).

MODDIR=${0%/*}
case "$MODDIR" in
/*) ;;
*) MODDIR=/data/adb/modules/pixel_tune ;;
esac
[ -x "$MODDIR/bin/pxtune" ] || MODDIR=/data/adb/modules/pixel_tune

PXTUNE="$MODDIR/bin/pxtune"
AUTOD="$MODDIR/bin/pxtune-auto"
STATE=/data/adb/pixel_tune
LOG="$STATE/pxtune.log"
LOG_MAX=524288
# pidfile si vede sám démon (pxtune-auto: PIDF="$STATE/pxtune-auto.pid")
PIDFILE="$STATE/pxtune-auto.pid"

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

# wr <cesta> <hodnota> — zápis do souboru bez úniku chybové hlášky na stderr.
# Redirekce se vyhodnocují zleva doprava, takže `echo x >soubor 2>/dev/null`
# hlášku "Permission denied" nepotlačí; proto se obaluje celý blok.
wr() {
	{ echo "$2" >"$1"; } 2>/dev/null
}

log INFO "uninstall: start (moddir=$MODDIR)"

BOOTED=0
[ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ] && BOOTED=1

# ---------------------------------------------------------------------------
# 1) Zastavit adaptivního démona jako první — ať nám nic nepíše zpátky do sysfs
#    během revertu.
#
#    Primárně přes `pxtune-auto stop`: démon se startuje pod `setsid` ve vlastní
#    procesní skupině (logcat + grep + sleep), takže `stop` umí sejmout celý
#    strom. Když binárka chybí, spadneme na ruční kill podle jeho pidfile.
# ---------------------------------------------------------------------------
if [ -x "$AUTOD" ]; then
	"$AUTOD" stop >/dev/null 2>&1
	log INFO "uninstall: zavolán 'pxtune-auto stop'"
fi
PID=$(cat "$PIDFILE" 2>/dev/null | tr -dc '0-9')
if [ -n "$PID" ] && [ -d "/proc/$PID" ]; then
	if tr -d '\000' <"/proc/$PID/cmdline" 2>/dev/null | grep -q 'pxtune-auto'; then
		kill -TERM "-$PID" 2>/dev/null || kill -TERM "$PID" 2>/dev/null
		log WARN "uninstall: pxtune-auto (pid $PID) ještě běžel, poslán SIGTERM"
	fi
fi
rm -f "$PIDFILE" "$STATE/pxtune-auto.fifo" 2>/dev/null
rm -rf "$STATE/pxtune-auto.lock" 2>/dev/null

# Vzorkovač metrik — běží jen když si ho uživatel zapnul, ale kdyby běžel,
# nesmí modul přežít. Nasbíraná data ZŮSTÁVAJÍ (jsou to jeho měření, ne náš
# stav) — spolu se zbytkem $STATE si je uživatel smaže sám, viz konec skriptu.
METRICSD="$MODDIR/bin/pxtune-metrics"
if [ -x "$METRICSD" ]; then
	"$METRICSD" stop >/dev/null 2>&1
	log INFO "uninstall: zavolán 'pxtune-metrics stop'"
else
	MPID=$(cat "$STATE/pxtune-metrics.pid" 2>/dev/null | tr -dc '0-9')
	if [ -n "$MPID" ] && [ -d "/proc/$MPID" ]; then
		kill -TERM "$MPID" 2>/dev/null
		log WARN "uninstall: pxtune-metrics (pid $MPID) ještě běžel, poslán SIGTERM"
	fi
fi
rm -f "$STATE/pxtune-metrics.pid" "$STATE/metrics.on" 2>/dev/null

# DISABLE položíme hned: kdyby uninstall běžel v kontextu B, post-fs-data.sh
# ani service.sh se v tomhle bootu už nesmí chytit.
wr "$STATE/DISABLE" "uninstall in progress"

# ---------------------------------------------------------------------------
# 2) Vrátit vše na stock
# ---------------------------------------------------------------------------
if [ -x "$PXTUNE" ]; then
	"$PXTUNE" revert >/dev/null 2>&1
	RC=$?
	if [ "$RC" = "0" ]; then
		log INFO "uninstall: 'pxtune revert' OK — uclamp, GPU, vm, I/O, thermal a nabíjení zpět na stock"
	else
		log ERROR "uninstall: 'pxtune revert' skončil s kódem $RC — zkontroluj $STATE/backup/stock.conf"
	fi

	# Rozlišení/DPI se drží v `settings`, což bez system_serveru nejde vrátit.
	if [ "$BOOTED" = "1" ]; then
		"$PXTUNE" res reset >/dev/null 2>&1 &&
			log INFO "uninstall: rozlišení a DPI vráceny na nativní" ||
			log WARN "uninstall: 'pxtune res reset' selhal"
	else
		log WARN "uninstall: běžím před sys.boot_completed, 'settings' není dostupné — pokud jsi měl vlastní rozlišení/DPI, vrať je ručně: 'settings delete global display_size_forced' a 'settings put secure display_density_forced 353' (stock hodnota ze SPEC)"
	fi
else
	log ERROR "uninstall: $PXTUNE není dostupný, revert NEPROBĚHL — hodnoty vrátí až reboot (uclamp/GPU/vm/thermal nejsou perzistentní), ale CHARGE_STOP_LEVEL a settings zůstanou; oprav ručně"
fi

# ---------------------------------------------------------------------------
# 3) zram
#
# SPEC: "swapoff za běhu je NEBEZPEČNÝ (riziko OOM) => změny zramu jen
# v post-fs-data.sh". Tady tedy na zram VĚDOMĚ NESAHÁME. Není to potřeba:
# velikost zramu není perzistentní, po odinstalaci už post-fs-data.sh
# nepoběží a hned příští boot vytvoří vendor stock 3969961984 B / lz77eh.
# ---------------------------------------------------------------------------
if [ -f "$STATE/zram.conf" ]; then
	log INFO "uninstall: zram se záměrně nemění za běhu (riziko OOM); stock velikost se obnoví sama při příštím bootu"
fi

# ---------------------------------------------------------------------------
# 4) Úklid /data/adb/pixel_tune/
#
# ROZHODNUTÍ: uživatelská data se NEMAŽOU.
#
# Důvody:
#   1. SPEC u téhle cesty výslovně říká "stav, PŘEŽÍVÁ REINSTALACI MODULU".
#      Smazat ji při uninstallu by ten kontrakt porušilo.
#   2. uninstall.sh se v Magisk/KernelSU světě spouští i při upgradu nebo
#      přeinstalaci modulu, ne jen při definitivním odchodu. Mazání profilů by
#      znamenalo, že si uživatel při každé aktualizaci modulu přijde o
#      nastavení, které si sám vyladil.
#   3. `backup/stock.conf` je poslední záchranná síť. Kdyby revert v bodě 2
#      selhal (nebo doběhl jen částečně v kontextu B), je to jediný záznam
#      stock hodnot. Smazat ho v okamžiku, kdy může být potřeba, je špatně.
#   4. `pxtune.log` obsahuje důkaz, co uninstall udělal. Mazat diagnostiku
#      právě ve chvíli odinstalace je proti smyslu logu.
#   5. Mazání uživatelských dat má být vždy explicitní volba, ne vedlejší
#      efekt odinstalace modulu. Uživatel může adresář smazat jedním `rm -rf`,
#      ale ztracené profily už zpátky nedostane.
#
# Mažou se proto jen BĚHOVÉ (ephemeral) soubory, které bez modulu nemají smysl
# a při reinstalaci by mátly:
#   boot_count        — stav bootloop ochrany minulé instalace
#   res_pending       — watchdog rozlišení, který už nikdo nepotvrdí
#   manual_override   — příznak řízení automatem, který už neběží
#   pxtune-auto.pid   — pid mrtvého procesu (smazáno výše)
#   pxtune-auto.fifo  — pojmenovaná roura démona (smazána výše)
#   pxtune-auto.lock  — zámek démona (smazán výše)
#
# Zůstává (uživatelská data a diagnostika):
#   profiles/  backup/  active  auto  zram.conf  appstats  appstats.override
#   pxtune.log  pxtune.log.old
#
# Opt-in pro tvrdé smazání: vytvoř před odinstalací /data/adb/pixel_tune/PURGE.
# ---------------------------------------------------------------------------
rm -f "$STATE/boot_count" "$STATE/res_pending" "$STATE/manual_override" 2>/dev/null

if [ -f "$STATE/PURGE" ]; then
	log WARN "uninstall: nalezen PURGE — mažu celý $STATE včetně profilů a zálohy"
	sync 2>/dev/null
	rm -rf "$STATE" 2>/dev/null
else
	# DISABLE z bodu 1 už není k ničemu (modul mizí) a při případné reinstalaci
	# by ji rovnou umrtvil. Odstranit až úplně na konci.
	rm -f "$STATE/DISABLE" 2>/dev/null
	log INFO "uninstall: hotovo. Uživatelská data v $STATE zachována (profily, backup/stock.conf, log). Pro úplné smazání: rm -rf $STATE"
fi

sync 2>/dev/null
exit 0
