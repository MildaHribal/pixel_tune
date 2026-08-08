#!/system/bin/sh
#
# pixel_tune / service.sh
#
# POZDNÍ FÁZE (late_start service). Podle dokumentace KernelSU je NEBLOKUJÍCÍ —
# běží paralelně se zbytkem bootu. Chyba tady tedy nemůže způsobit bootloop,
# proto sem patří VŠECHNO ostatní kromě zramu.
#
# Zodpovědnosti:
#   - DISABLE check
#   - počkat na ustálení systému
#   - jednorázově vytvořit backup/stock.conf (delegováno na `pxtune`)
#   - aplikovat aktivní profil
#   - vyřešit rozlišení (nepotvrzená změna / perzistentní nastavení)
#   - nastartovat adaptivní démona, pokud je zapnutý
#   - NA KONCI vynulovat boot_count = "boot doběhl v pořádku"
#
# Skript NIKDY neskončí nenulovým kódem, nepoužívá `set -e` a je idempotentní.

MODDIR=${0%/*}
case "$MODDIR" in
/*) ;;
*) MODDIR=/data/adb/modules/pixel_tune ;;
esac
[ -x "$MODDIR/bin/pxtune" ] || MODDIR=/data/adb/modules/pixel_tune

BIN="$MODDIR/bin"
PXTUNE="$BIN/pxtune"
AUTOD="$BIN/pxtune-auto"

STATE=/data/adb/pixel_tune
LOG="$STATE/pxtune.log"
LOG_MAX=524288

BACKUP="$STATE/backup/stock.conf"

# Čekání na ustálení systému — ZDŮVODNĚNÍ:
#
#  a) BOOT_WAIT_MAX: aktivně čekáme na `sys.boot_completed=1` místo slepého
#     sleepu. Do té doby neběží system_server, takže `settings put` a `cmd game`
#     (SPEC: rozlišení, Game Mode) by tiše selhaly. Strop 180 s je horní pojistka
#     pro pomalý první boot po OTA/wipe; při běžném bootu Pixelu 8a se smyčka
#     ukončí mnohem dřív a nic se nezdrží.
#
#  b) SETTLE: po boot_completed ještě 20 s. Důvod z naměřených dat ve SPEC:
#     - thermal HAL přepisuje cooling devices v cyklu ~7 s a sám si nastavuje
#       `vendor.thermal.<SENZOR>.profile` (při probu byl už na `camera`),
#     - Googlí power-service.pixel-libperfmgr sahá na uclamp boost při startu.
#     Kdybychom psali dřív, HAL by naše hodnoty přepsal a profil by "nezabral".
#     20 s ~= 3 cykly HAL = konzervativní rezerva. Přesná doba doběhu HALů
#     ve SPEC naměřená NENÍ (viz OTEVŘENÉ OTÁZKY) — je to volená, nikoli
#     odvozená konstanta. Zdržení nikomu nevadí: skript je neblokující.
BOOT_WAIT_MAX=180
SETTLE=20

# ---------------------------------------------------------------------------
# log — formát dle SPEC (inline, ať skript nezávisí na dalších souborech)
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

# wr <cesta> <hodnota> — zápis do souboru bez úniku chybové hlášky na stderr.
# Redirekce se vyhodnocují zleva doprava, takže `echo x >soubor 2>/dev/null`
# hlášku "Permission denied" nepotlačí; proto se obaluje celý blok.
wr() {
	{ echo "$2" >"$1"; } 2>/dev/null
}

# vynulování počítadla bootloop ochrany. Volá se právě na jednom místě na konci.
clear_boot_count() {
	wr "$STATE/boot_count" 0
	sync 2>/dev/null
}

mkdir -p "$STATE" "$STATE/backup" "$STATE/profiles" 2>/dev/null

# ---------------------------------------------------------------------------
# Úklid běhových značek po předchozím bootu.
#
# `pxtune-auto.exiting` je značka "démon má skončit / watchdog ho nesmí
# restartovat". Leží ale v /data/adb, což reboot PŘEŽIJE — takže když se démon
# zastavil před restartem, po bootu se sice nastartoval, hned uviděl značku
# a zase se ukončil. Naměřeno: démon naběhl v 07:35:58 a v 07:36:23 skončil.
# Značka platí jen pro běh, ve kterém vznikla.
#
# `pxtune-auto.pid` po tvrdém vypnutí ukazuje na neexistující proces a mohl by
# zmást kontrolu "už běží".
rm -f "$STATE/pxtune-auto.exiting" "$STATE/pxtune-auto.pid" \
      "$STATE/pxtune-auto.fifo" 2>/dev/null
rmdir "$STATE/pxtune-auto.lock" 2>/dev/null

# ---------------------------------------------------------------------------
# 0) Doplnění profilů z modulu.
# Bez tohoto by čerstvá instalace neměla ŽÁDNÉ profily (CLI umí vytvořit jen
# prázdný balanced.conf) a démon by při každé události selhával na
# "profil neexistuje". Kopírují se JEN chybějící soubory — uživatelovy úpravy
# existujících profilů se nikdy nepřepisují. Zápis přes .tmp + mv, aby
# přerušený boot nenechal rozepsaný soubor.
# ---------------------------------------------------------------------------
if [ -d "$MODDIR/profiles" ]; then
	for _src in "$MODDIR/profiles"/*.conf; do
		[ -f "$_src" ] || continue
		_dst="$STATE/profiles/${_src##*/}"
		if [ ! -f "$_dst" ]; then
			cp "$_src" "$_dst.tmp" 2>/dev/null \
				&& mv "$_dst.tmp" "$_dst" 2>/dev/null \
				&& log INFO "service: profil ${_src##*/} doplněn z modulu"
		fi
	done
fi

# ---------------------------------------------------------------------------
# 1) DISABLE
#
# Pozor: boot_count se tu ZÁMĚRNĚ nenuluje. Když je modul vypnutý, nedělá nic,
# a post-fs-data.sh se stejně ukončí dřív, takže počítadlo neroste.
# ---------------------------------------------------------------------------
if [ -f "$STATE/DISABLE" ]; then
	log INFO "service: existuje DISABLE, nic se neaplikuje"
	exit 0
fi

# ---------------------------------------------------------------------------
# 2) Čekání na ustálení systému
# ---------------------------------------------------------------------------
i=0
while [ "$i" -lt "$BOOT_WAIT_MAX" ]; do
	[ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ] && break
	sleep 1
	i=$((i + 1))
done

if [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ]; then
	# Boot doslova doběhl → ochrana proti bootloopu splnila účel, nulujeme TEĎ.
	# Kdybychom čekali až na konec skriptu (SETTLE + profil + settings = desítky
	# sekund), tři restarty uživatele v tom okně by modul vypnuly, přestože
	# systém pokaždé nabootoval v pořádku. Počítadlo má hlídat bootloop,
	# ne rychlost uživatele. Volání na konci skriptu zůstává (je idempotentní
	# a pokrývá i větev, kde boot_completed nepřišlo).
	clear_boot_count
	log INFO "service: sys.boot_completed po ${i}s, boot_count vynulován, čekám dalších ${SETTLE}s na doběh HALů"
else
	log WARN "service: sys.boot_completed nepřišlo do ${BOOT_WAIT_MAX}s, pokračuji opatrně"
fi
sleep "$SETTLE"

# DISABLE mohl vzniknout během čekání (uživatel / WebUI). Zkontrolovat znovu.
if [ -f "$STATE/DISABLE" ]; then
	log INFO "service: DISABLE vzniklo během čekání, končím bez zásahu"
	exit 0
fi

if [ ! -x "$PXTUNE" ]; then
	log ERROR "service: $PXTUNE neexistuje nebo není spustitelný — nic neaplikuji"
	# boot ale proběhl v pořádku, počítadlo patří vynulovat
	clear_boot_count
	exit 0
fi

# ---------------------------------------------------------------------------
# 3) backup/stock.conf — jednorázově, delegováno na `pxtune`
#
# Snapshot stock hodnot smí umět jen jedno místo (CLI zná všechny cesty
# a jejich formát), tady se logika NEDUPLIKUJE.
#
# Jak se to deleguje: `bin/pxtune` volá ve svém `main()` bezpodmínečně
# `snapshot_stock` + `seed_profiles` PŘED rozskokem na podpříkaz, a
# `snapshot_stock` je idempotentní ("vytvori se JEDNOU, nikdy neprepisuje").
# Stačí tedy spustit libovolný neškodný podpříkaz. Používáme
# `profile current`, což jen vypíše jméno aktivního profilu a nic nemění.
# (Samostatný podpříkaz `pxtune backup` v CLI NEEXISTUJE — viz OTEVŘENÉ OTÁZKY.)
#
# TVRDÉ OMEZENÍ č. 5 ze SPEC: "vše musí být reversibilní a zálohované".
# Když se záloha nepodaří vytvořit, profil ZÁMĚRNĚ NEAPLIKUJEME — jinak by
# vznikl stav, ze kterého `pxtune revert` neumí zpátky.
# ---------------------------------------------------------------------------
APPLY_OK=1
if [ ! -s "$BACKUP" ]; then
	log INFO "service: backup/stock.conf chybí, nechávám ho vytvořit CLI (pxtune profile current)"
	"$PXTUNE" profile current >/dev/null 2>&1
	if [ ! -s "$BACKUP" ]; then
		APPLY_OK=0
		log ERROR "service: nevznikl $BACKUP — profil se NEAPLIKUJE (bez zálohy není revert)"
	else
		log INFO "service: backup/stock.conf vytvořen"
	fi
fi

# ---------------------------------------------------------------------------
# 4) Aktivní profil
#
# POZOR na kontrakt CLI: `pxtune profile <name>` podle SPEC (a podle skutečné
# implementace v bin/pxtune, funkce profile_apply) nastavuje `manual_override`.
# Při bootu je to nežádoucí vedlejší efekt — uživatel, který běží v režimu
# `auto`, by se po každém rebootu ocitl v ručním režimu a automat by se už
# nikdy nechytl. Proto si stav manual_override před voláním zapamatujeme
# a po aplikaci ho vrátíme přesně do původní podoby.
#
# Proč ne `pxtune profile <name> --auto` (příznak, který si žádá pxtune-auto):
#   1. v bin/pxtune zatím NENÍ implementovaný (viz hlavička pxtune-auto:
#      "CO JE POTREBA DOPLNIT DO bin/pxtune (jeste to tam neni)"),
#   2. i až bude, jeho kontrakt je "když manual_override existuje, neudělej nic"
#      — což je pro boot špatně: aktivní profil se má obnovit VŽDY, i v ručním
#      režimu. Uložit a vrátit příznak je tedy správnější řešení i do budoucna.
# ---------------------------------------------------------------------------
if [ "$APPLY_OK" = "1" ]; then
	ACTIVE=$(cat "$STATE/active" 2>/dev/null | tr -d ' \t\r\n')

	if [ -z "$ACTIVE" ]; then
		# SPEC popisuje 'balanced' jako "Vyvážený — stock chování", takže je to
		# bezpečný default pro čerstvou instalaci. Nastavíme ho jen když profil
		# opravdu existuje; nic si nevymýšlíme.
		if [ -f "$STATE/profiles/balanced.conf" ]; then
			ACTIVE=balanced
			wr "$STATE/active" "$ACTIVE"
			log INFO "service: 'active' chybělo, nastaven default profil balanced"
		else
			log WARN "service: 'active' chybí a profiles/balanced.conf neexistuje — neaplikuji žádný profil"
		fi
	fi

	# sanitizace jména (soubor je uživatelsky zapisovatelný, jde do argumentu)
	case "$ACTIVE" in
	'') ;;
	*[!A-Za-z0-9_-]*)
		log ERROR "service: neplatné jméno profilu '$ACTIVE' v $STATE/active, ignoruji"
		ACTIVE=''
		;;
	esac

	if [ -n "$ACTIVE" ] && [ ! -f "$STATE/profiles/$ACTIVE.conf" ]; then
		log ERROR "service: profil '$ACTIVE' neexistuje ($STATE/profiles/$ACTIVE.conf), neaplikuji"
		ACTIVE=''
	fi

	if [ -n "$ACTIVE" ]; then
		HAD_OVERRIDE=0
		[ -f "$STATE/manual_override" ] && HAD_OVERRIDE=1

		"$PXTUNE" profile "$ACTIVE" >/dev/null 2>&1
		RC=$?

		# obnovení původního stavu manual_override (viz komentář výše)
		if [ "$HAD_OVERRIDE" = "0" ]; then
			rm -f "$STATE/manual_override" 2>/dev/null
		else
			[ -f "$STATE/manual_override" ] || wr "$STATE/manual_override" ""
		fi

		if [ "$RC" = "0" ]; then
			log INFO "service: aplikován profil '$ACTIVE' (manual_override=$HAD_OVERRIDE zachován)"
		else
			log ERROR "service: 'pxtune profile $ACTIVE' skončil s kódem $RC"
		fi
	fi
fi

# ---------------------------------------------------------------------------
# 4b) Per-app: vrstva 3 z minulého běhu
#
# `appmode.active` leží v /data, takže reboot přežije — ale nastavení, které
# popisuje (refresh rate, display_size_forced, display_density_forced), si
# Android načetl ze svého vlastního úložiště ještě před tímto skriptem.
# Stav a skutečnost se proto musí srovnat: uložené „staré" hodnoty jsou
# přesně to, co má platit, když žádná aplikace s pravidlem neběží.
#
# Tohle je 5. ze ŠESTI nezávislých cest, které musí volat `app leave`
# (výčet a důvody jsou u cmd_leave() v bin/pxtune-perapp). Bez ní by
# uživatel po pádu telefonu uprostřed hry zůstal zamčený na 60 Hz nebo
# na cizím rozlišení a reboot by mu nepomohl.
#
# `app leave` je IDEMPOTENTNÍ — když nic nasazeno není, tiše skončí s kódem 0,
# takže se sem smí volat naslepo. Musí to být PŘED sekcí 5 (rozlišení):
# leave zapisuje uložený displej, takže by jinak přepsal to, co udělá
# `pxtune res reset`.
# ---------------------------------------------------------------------------
if [ -f "$STATE/appmode.active" ]; then
	log WARN "service: nalezen appmode.active z minulého běhu — vracím vrstvu 3 per-app pravidla"
fi
"$PXTUNE" app leave >/dev/null 2>&1 ||
	log ERROR "service: 'pxtune app leave' selhal — refresh rate / rozlišení může zůstat po per-app pravidle"

# ---------------------------------------------------------------------------
# 4c) Tweaky
#
# Většina tweaků žije v sysfs/procfs, což reboot NEPŘEŽIJE — musí se nasadit
# znovu při každém startu. Nasazují se AŽ TADY (po boot_completed + SETTLE),
# protože některé mají mechanismus `prop` a ty by dřív nezabraly.
# Tweaky s mechanismem `settings` se záměrně přeskakují — ty si Android drží
# sám a volat kvůli nim binder při bootu je zbytečné riziko.
#
# Pořadí je důležité: až PO aplikaci profilu. Profil totiž volá
# restore_stock_values(), které vrací i klíče, na které sahají tweaky
# (readahead, charge levels, vm.*). Kdyby se tweaky nasadily dřív, profil
# by je přepsal.
# ---------------------------------------------------------------------------
if [ -s "$STATE/tweaks.conf" ]; then
	if "$PXTUNE" tweak apply-boot >/dev/null 2>&1; then
		log INFO "service: tweaky nasazeny (tweak apply-boot)"
	else
		log ERROR "service: 'pxtune tweak apply-boot' selhal"
	fi
else
	log INFO "service: žádné tweaky k nasazení"
fi

# ---------------------------------------------------------------------------
# 5) Rozlišení
#
#  a) existuje `res_pending` => minulá změna rozlišení nebyla potvrzena přes
#     `pxtune res confirm` a zařízení se mezitím rebootovalo. To je přesně ten
#     scénář, proti kterému watchdog na rozlišení je (uživatel neviděl obraz;
#     watchdog v CLI je `sleep 60` v procesu, který reboot nepřežije).
#     => tvrdý návrat na nativní přes `pxtune res reset`.
#
#  b) jinak: perzistentní rozlišení obnovovat NENÍ potřeba a záměrně se
#     nepřepisuje. `pxtune res` ho ukládá do `settings put global
#     display_size_forced` / `settings put secure display_density_forced`
#     (SPEC, sekce "Displej") a to je perzistentní úložiště Androidu —
#     WindowManager ho aplikuje sám při startu system_serveru, dřív než sem
#     service.sh vůbec dojde. Jakýkoli náš zápis by byl buď no-op, nebo by
#     přepsal uživatelovu pozdější změnu. Stav proto jen zalogujeme.
#     (Podpříkaz `pxtune res restore` v CLI NEEXISTUJE — viz OTEVŘENÉ OTÁZKY.)
# ---------------------------------------------------------------------------
if [ -f "$STATE/res_pending" ]; then
	log WARN "service: nalezen res_pending — nepotvrzená změna rozlišení přežila reboot, vracím nativní"
	"$PXTUNE" res reset >/dev/null 2>&1 ||
		log ERROR "service: 'pxtune res reset' selhal"
	rm -f "$STATE/res_pending" 2>/dev/null
else
	# POZOR: `settings` je binder. Bez timeoutu by zatuhly system_server zasekl
	# service.sh a NIKDY by se nedoslo na clear_boot_count -> tri takove boty
	# a bootloop ochrana modul vypne, ackoli se nic nepokazilo.
	RES_NOW=$(timeout 10 settings get global display_size_forced 2>/dev/null | tr -d ' \t\r\n')
	DPI_NOW=$(timeout 10 settings get secure display_density_forced 2>/dev/null | tr -d ' \t\r\n')
	case "$RES_NOW" in null | '') RES_NOW='(nativní)' ;; esac
	case "$DPI_NOW" in null | '') DPI_NOW='(výchozí)' ;; esac
	log INFO "service: perzistentní rozlišení drží Android sám — display_size_forced=$RES_NOW, display_density_forced=$DPI_NOW"
fi

# ---------------------------------------------------------------------------
# 6) Adaptivní démon
#
# Stav se čte z `$STATE/auto`, ať je zdroj pravdy jen jeden. Sémantiku
# ZRCADLÍME z funkce `auto_state()` v bin/pxtune: 'off'/'OFF'/'0'/'false'
# znamená vypnuto, cokoli jiného VČETNĚ CHYBĚJÍCÍHO SOUBORU znamená zapnuto.
#
# Start se deleguje na `pxtune-auto start` — démon se sám odpojí přes setsid,
# sám si vede `$STATE/pxtune-auto.pid` a jeho `do_start()` už obsahuje kontrolu
# "uz bezi (pid N)". Idempotence je tedy jeho, service.sh ji neduplikuje
# a žádný vlastní pidfile nedrží.
# ---------------------------------------------------------------------------
AUTO_STATE=$(cat "$STATE/auto" 2>/dev/null | tr -d ' \t\r\n')
case "$AUTO_STATE" in
off | OFF | 0 | false)
	log INFO "service: adaptivní démon vypnutý ($STATE/auto='$AUTO_STATE')"
	;;
*)
	if [ ! -x "$AUTOD" ]; then
		log WARN "service: auto je zapnuté, ale $AUTOD neexistuje nebo není spustitelný — démon nespuštěn"
	else
		"$AUTOD" start >/dev/null 2>&1
		RC=$?
		AUTO_PID=$(cat "$STATE/pxtune-auto.pid" 2>/dev/null | tr -dc '0-9')
		if [ -n "$AUTO_PID" ] && [ -d "/proc/$AUTO_PID" ]; then
			log INFO "service: pxtune-auto běží (pid $AUTO_PID)"
		else
			log ERROR "service: 'pxtune-auto start' skončil s kódem $RC a démon neběží"
		fi
	fi
	;;
esac

# ---------------------------------------------------------------------------
# 6b) Vzorkovač metrik (baterie / příkon / teploty).
#
# Spouští se JEN když si ho uživatel zapnul (`pxtune metrics start` založí
# $STATE/metrics.on). Bez toho se nespustí vůbec — je to diagnostický nástroj,
# ne součást běžného provozu, a nemá smysl, aby něco vzorkoval každému pořád.
#
# Selhání je NEFATÁLNÍ a záměrně se jen zaloguje: sběr dat nesmí ohrozit boot.
# ---------------------------------------------------------------------------
METRICSD="$BIN/pxtune-metrics"
if [ -f "$STATE/metrics.on" ]; then
	if [ ! -x "$METRICSD" ]; then
		log WARN "service: metrics.on existuje, ale $METRICSD není spustitelný — vzorkovač nespuštěn"
	else
		"$METRICSD" start >/dev/null 2>&1
		MET_PID=$(cat "$STATE/pxtune-metrics.pid" 2>/dev/null | tr -dc '0-9')
		if [ -n "$MET_PID" ] && [ -d "/proc/$MET_PID" ]; then
			log INFO "service: pxtune-metrics běží (pid $MET_PID)"
		else
			log WARN "service: vzorkovač metrik se nepodařilo spustit"
		fi
	fi
fi

# ---------------------------------------------------------------------------
# 7) Boot doběhl v pořádku -> vynulovat počítadlo.
#
# Nuluje se ZÁMĚRNĚ i tehdy, když některý krok výše selhal. Počítadlo hlídá
# bootloop, ne úspěšnost profilu: pokud jsme se dostali až sem, systém
# nabootoval. Kdyby ho selhaný krok nenuloval, tři "jen" neúspěšné aplikace
# profilu by modul zbytečně vypnuly.
# ---------------------------------------------------------------------------
clear_boot_count
log INFO "service: hotovo, boot_count vynulován"

exit 0
