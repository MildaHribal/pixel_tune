#!/system/bin/sh
# volkeys - root daemon: long-press on the volume keys (works with the screen off)
#   Volume UP long-press   -> opens the pixel_tune WebUI
#   Volume DOWN long-press -> toggles the torch (termux-torch, works screen-off)
#
# getevent reads raw input (works even when the display is off). It monitors,
# it does not consume - the volume may change while holding (a side effect).

TERMUX_UID=10384          # Termux uid (u0_a384) - changes when Termux is reinstalled
PREFIX=/data/data/com.termux/files/usr
HOME_T=/data/data/com.termux/files/home
LONG_MS=550               # long-press threshold
STATE=/data/adb/pixel_tune
LOG=$STATE/volkeys.log
mkdir -p $STATE 2>/dev/null
log(){ echo "[$(date '+%H:%M:%S')] $*" >> $LOG 2>/dev/null; }

# torch state (tracked here; termux-torch has no "toggle")
TORCH_FILE=$STATE/.torch_on

torch_toggle(){
  if [ -f "$TORCH_FILE" ]; then _st=off; rm -f "$TORCH_FILE"; else _st=on; : > "$TORCH_FILE"; fi
  su -G 3003 $TERMUX_UID -c "export PREFIX=$PREFIX HOME=$HOME_T PATH=$PREFIX/bin:$PREFIX/bin/applets:/system/bin LD_LIBRARY_PATH=$PREFIX/lib TMPDIR=$PREFIX/tmp; termux-torch $_st" >/dev/null 2>&1 &
  log "torch $_st"
}
open_pixeltune(){
  am start -n com.rifsxd.ksunext/.ui.webui.WebUIActivity --es id pixel_tune --ez from_webui_shortcut true >/dev/null 2>&1
  log "pixel_tune WebUI"
}

# find the input devices that carry the volume keys
DEVS=$(getevent -lp 2>/dev/null | awk '/^add device/{d=$4} /KEY_VOLUME/{print d}' | sort -u | tr '\n' ' ')
[ -z "$DEVS" ] && DEVS="/dev/input/event0 /dev/input/event1"
log "start, devs=$DEVS torch_uid=$TERMUX_UID"

now_ms(){ n=$(date +%s%N 2>/dev/null); echo $((n/1000000)); }

UP_T=0; DN_T=0
getevent -l $DEVS 2>/dev/null | while read a b c rest; do
  # lines look like "EV_KEY KEY_VOLUMEUP DOWN" (with several devices the first
  # field may be the device path with a colon -> the key is then in $b/$c/$rest).
  line="$a $b $c $rest"
  case "$line" in
    *KEY_VOLUMEUP*DOWN*)   [ "$UP_T" = 0 ] && UP_T=$(now_ms) ;;
    *KEY_VOLUMEUP*UP*)     if [ "$UP_T" != 0 ]; then d=$(( $(now_ms) - UP_T )); [ "$d" -ge "$LONG_MS" ] && open_pixeltune; UP_T=0; fi ;;
    *KEY_VOLUMEDOWN*DOWN*) [ "$DN_T" = 0 ] && DN_T=$(now_ms) ;;
    *KEY_VOLUMEDOWN*UP*)   if [ "$DN_T" != 0 ]; then d=$(( $(now_ms) - DN_T )); [ "$d" -ge "$LONG_MS" ] && torch_toggle; DN_T=0; fi ;;
  esac
done
