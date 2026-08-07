#!/system/bin/sh
#
# install-widget.sh - nainstaluje zastupce na plochu pro prepinani profilu.
#
# Pouziti (jako root):
#   su -c "sh /data/adb/modules/pixel_tune/widget/install-widget.sh"
#
# CO TO POTREBUJE
#   Aplikaci "Termux:Widget" z F-Droidu (stejny podpis jako Termux).
#   Bez ni to nema kam zastupce dat.
#
# JAK TO FUNGUJE
#   Termux:Widget zobrazuje na plose skripty z ~/.shortcuts/ uvnitr Termuxu.
#   Kazdy skript = jedna ikona. Skript zavola `su -c pxtune profile <jmeno>`.
#
# POZOR NA ROOT PROMPT
#   Prvni spusteni z Termuxu vyvola dotaz KernelSU na povoleni rootu pro Termux.
#   Musis ho odklepnout, jinak zastupci nic neudelaji.

set -u

TERMUX_HOME=/data/data/com.termux/files/home
SHORTCUTS="$TERMUX_HOME/.shortcuts"
PX=/data/adb/modules/pixel_tune/bin/pxtune

# UID Termuxu - zastupci musi patrit jemu, jinak je Termux neprecte
TERMUX_UID=$(stat -c %u "$TERMUX_HOME" 2>/dev/null)

if [ ! -d "$TERMUX_HOME" ]; then
	echo "CHYBA: Termux nenalezen ($TERMUX_HOME)."
	echo "       Nainstaluj Termux + Termux:Widget z F-Droidu a spust ho aspon jednou."
	exit 1
fi
if [ -z "$TERMUX_UID" ]; then
	echo "CHYBA: nepodarilo se zjistit UID Termuxu."
	exit 1
fi

mkdir -p "$SHORTCUTS" 2>/dev/null

mk() {
	# mk <soubor> <telo>
	_f="$SHORTCUTS/$1"
	printf '%s\n' "$2" > "$_f" 2>/dev/null || { echo "  CHYBA zapisu: $_f"; return 1; }
	chmod 0700 "$_f" 2>/dev/null
	chown "$TERMUX_UID:$TERMUX_UID" "$_f" 2>/dev/null
	echo "  vytvoreno: $1"
}

echo "Instaluji zastupce do $SHORTCUTS"

for p in powersave balanced performance game night; do
	case "$p" in
		powersave)   nazev="1-Usporny"    ;;
		balanced)    nazev="2-Vyvazeny"   ;;
		performance) nazev="3-Vykon"      ;;
		game)        nazev="4-Hry"        ;;
		night)       nazev="5-Nocni"      ;;
	esac
	mk "$nazev" "#!/data/data/com.termux/files/usr/bin/sh
OUT=\$(su -c '$PX profile $p' 2>&1)
echo \"\$OUT\"
# kratka zpetna vazba primo na plose
su -c 'cmd notification post -S bigtext -t \"pixel_tune\" px \"Profil: $p\"' >/dev/null 2>&1
sleep 1"
done

# Navrat rizeni automatu
mk "6-Automat" "#!/data/data/com.termux/files/usr/bin/sh
su -c '$PX profile auto'
su -c 'cmd notification post -S bigtext -t \"pixel_tune\" px \"Profil ridi automat\"' >/dev/null 2>&1
sleep 1"

# Rychly stav
mk "7-Stav" "#!/data/data/com.termux/files/usr/bin/sh
su -c '$PX status' | head -40
echo
echo '(zavri klepnutim)'
read _"

chown "$TERMUX_UID:$TERMUX_UID" "$SHORTCUTS" 2>/dev/null

echo
echo "Hotovo. Ted:"
echo "  1) Na plose dlouze podrz prst -> Widgety -> Termux:Widget"
echo "  2) Pretahni widget na plochu, vyber si zastupce"
echo "  3) Pri prvnim klepnuti povol KernelSU root pro Termux"
echo
echo "Zastupci:"
ls -1 "$SHORTCUTS" 2>/dev/null | sed 's/^/  /'
