#!/system/bin/sh
#
# install-widget.sh - installs home screen shortcuts for switching profiles.
#
# Usage (as root):
#   su -c "sh /data/adb/modules/pixel_tune/widget/install-widget.sh"
#
# WHAT IT NEEDS
#   The "Termux:Widget" app from F-Droid (same signature as Termux).
#   Without it there is nowhere to put the shortcuts.
#
# HOW IT WORKS
#   Termux:Widget shows scripts from ~/.shortcuts/ inside Termux on the home
#   screen. Each script = one icon. The script calls
#   `su -c pxtune profile <name>`.
#
# MIND THE ROOT PROMPT
#   The first run from Termux triggers a KernelSU prompt to grant root to
#   Termux. You have to confirm it, otherwise the shortcuts will do nothing.

set -u

TERMUX_HOME=/data/data/com.termux/files/home
SHORTCUTS="$TERMUX_HOME/.shortcuts"
PX=/data/adb/modules/pixel_tune/bin/pxtune

# The Termux UID - the shortcuts must belong to it, otherwise Termux cannot read them
TERMUX_UID=$(stat -c %u "$TERMUX_HOME" 2>/dev/null)

if [ ! -d "$TERMUX_HOME" ]; then
	echo "ERROR: Termux not found ($TERMUX_HOME)."
	echo "       Install Termux + Termux:Widget from F-Droid and run it at least once."
	exit 1
fi
if [ -z "$TERMUX_UID" ]; then
	echo "ERROR: could not determine the Termux UID."
	exit 1
fi

mkdir -p "$SHORTCUTS" 2>/dev/null

mk() {
	# mk <file> <body>
	_f="$SHORTCUTS/$1"
	printf '%s\n' "$2" > "$_f" 2>/dev/null || { echo "  WRITE ERROR: $_f"; return 1; }
	chmod 0700 "$_f" 2>/dev/null
	chown "$TERMUX_UID:$TERMUX_UID" "$_f" 2>/dev/null
	echo "  created: $1"
}

echo "Installing shortcuts into $SHORTCUTS"

for p in powersave balanced performance game night; do
	case "$p" in
		powersave)   name="1-Powersave"   ;;
		balanced)    name="2-Balanced"    ;;
		performance) name="3-Performance" ;;
		game)        name="4-Game"        ;;
		night)       name="5-Night"       ;;
	esac
	mk "$name" "#!/data/data/com.termux/files/usr/bin/sh
OUT=\$(su -c '$PX profile $p' 2>&1)
echo \"\$OUT\"
# quick feedback right on the home screen
su -c 'cmd notification post -S bigtext -t \"pixel_tune\" px \"Profile: $p\"' >/dev/null 2>&1
sleep 1"
done

# Handing control back to the daemon
mk "6-Auto" "#!/data/data/com.termux/files/usr/bin/sh
su -c '$PX profile auto'
su -c 'cmd notification post -S bigtext -t \"pixel_tune\" px \"The daemon is in charge of the profile\"' >/dev/null 2>&1
sleep 1"

# Quick status
mk "7-Status" "#!/data/data/com.termux/files/usr/bin/sh
su -c '$PX status' | head -40
echo
echo '(tap to close)'
read _"

chown "$TERMUX_UID:$TERMUX_UID" "$SHORTCUTS" 2>/dev/null

echo
echo "Done. Now:"
echo "  1) Long-press on the home screen -> Widgets -> Termux:Widget"
echo "  2) Drag the widget onto the home screen, pick a shortcut"
echo "  3) On the first tap, grant KernelSU root to Termux"
echo
echo "Shortcuts:"
ls -1 "$SHORTCUTS" 2>/dev/null | sed 's/^/  /'
