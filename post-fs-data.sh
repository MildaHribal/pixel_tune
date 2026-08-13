#!/system/bin/sh
#
# pixel_tune / post-fs-data.sh
#
# EARLY BOOT PHASE. Per the KernelSU docs, post-fs-data is BLOCKING: the boot
# waits until the script finishes, for at most ~10 s. That is why there is NO:
#   - sleep, no waiting on a prop, no loop
#   - setprop (the docs: "setprop will deadlock the boot process")
#   - anything from the profiles (uclamp, GPU, thermal, charging, resolution)
#     -> service.sh does that
#
# This script does ONLY two things:
#   1) the safety logic of the bootloop protection (boot_count / DISABLE)
#   2) an optional zram resize (the only place where a swapoff is safe,
#      because swap is empty in this phase — see SPEC "Memory")
#
# The script NEVER exits with a non-zero code and never uses `set -e`.
# It is idempotent: running it again with the same config does nothing
# (the size already matches -> early return).

STATE=/data/adb/pixel_tune
LOG="$STATE/pxtune.log"
LOG_MAX=524288                 # 512 kB, rotation per SPEC "CONTRACT: log"

ZRAM_CONF="$STATE/zram.conf"   # optional, see OPEN QUESTIONS in the report
ZSYS=/sys/block/zram0

BOOT_FAIL_LIMIT=3              # >= 3 failed boots -> DISABLE (SPEC "Safety")
BOOT_ZRAM_SKIP=2               # >= 2 failed boots -> better not to touch zram
SWAP_HEADROOM_KB=307200        # a 300 MB reserve for the pre-swapoff guard

# ---------------------------------------------------------------------------
# log — format per the SPEC: [YYYY-MM-DD HH:MM:SS] [level] message
# Deliberately inline (rather than in a shared library): post-fs-data.sh has to
# be fully self-contained. If it depended on another module file, a missing or
# corrupted copy of that file would take down the early boot phase — exactly
# what we are avoiding.
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

# wr <path> <value> — write to a file, returns success/failure.
#
# Redirections are evaluated left to right, so `echo x >file 2>/dev/null` DOES
# NOT suppress the "Permission denied" message — at that point stderr is not
# redirected yet and the message escapes into the boot log. That is why the
# whole block is wrapped in braces and stderr is redirected on the block.
#
# (The full version of `wr` with "old → new" logging lives in the `pxtune` CLI;
# here it is deliberately minimal so post-fs-data.sh does not depend on other
# files.)
wr() {
	{ echo "$2" >"$1"; } 2>/dev/null
}

# read a whole number from a file, otherwise return empty
read_int() {
	[ -f "$1" ] || return 0
	_v=$(cat "$1" 2>/dev/null)
	case "$_v" in
	'' | *[!0-9]*) return 0 ;;
	esac
	echo "$_v"
}

# num_gt A B -> true (0) when the decimal integer A > B.
#
# DELIBERATELY without $(( )) and without `[ -gt ]`: /system/bin/sh on Android
# is mksh and it computes in 32-bit signed ints. The zram size (stock
# 3969961984 B) does not fit into them and the comparison would silently
# overflow. We therefore compare as strings: after stripping leading zeros the
# length decides first, and for equal lengths lexicographic order (which for
# numbers of equal length is identical to numeric order).
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

# the value of a /proc/meminfo key in kB
meminfo_kb() {
	_v=$(grep -m1 "^$1:" /proc/meminfo 2>/dev/null | tr -dc '0-9')
	case "$_v" in
	'' | *[!0-9]*) return 0 ;;
	esac
	echo "$_v"
}

mkdir -p "$STATE" 2>/dev/null

# ---------------------------------------------------------------------------
# 1) DISABLE — a user or automatic kill switch. Stop immediately.
# ---------------------------------------------------------------------------
if [ -f "$STATE/DISABLE" ]; then
	log INFO "post-fs-data: DISABLE exists, module inactive (delete it to re-enable)"
	exit 0
fi

# ---------------------------------------------------------------------------
# 2) Bootloop protection
#
#    The contract: post-fs-data.sh INCREMENTS the counter, service.sh ZEROES it
#    at the end. A non-zero counter therefore means "the last boot did not make
#    it all the way through service.sh". Three such boots in a row = the module
#    turns itself off.
# ---------------------------------------------------------------------------
BOOT_COUNT=$(read_int "$STATE/boot_count")
[ -n "$BOOT_COUNT" ] || BOOT_COUNT=0

if [ "$BOOT_COUNT" -ge "$BOOT_FAIL_LIMIT" ]; then
	{
		echo "auto-disabled by post-fs-data.sh"
		echo "date=$(date '+%Y-%m-%d %H:%M:%S')"
		echo "boot_count=$BOOT_COUNT"
		echo "reason=$BOOT_FAIL_LIMIT consecutive boots did not reach the end of service.sh"
	} 2>/dev/null >"$STATE/DISABLE"
	# zero the counter straight away: after manually deleting DISABLE the user
	# gets the full budget of 3 attempts, not an immediate re-disable.
	wr "$STATE/boot_count" 0
	sync 2>/dev/null
	log ERROR "post-fs-data: boot_count=$BOOT_COUNT >= $BOOT_FAIL_LIMIT -> DISABLE created, module turned itself off"
	exit 0
fi

BOOT_COUNT=$((BOOT_COUNT + 1))
wr "$STATE/boot_count" "$BOOT_COUNT"
# the sync here is MANDATORY: if the write stayed only in the page cache and
# the device then hung or rebooted, the counter would not advance and the
# protection would never trigger.
sync 2>/dev/null
log INFO "post-fs-data: start, boot_count=$BOOT_COUNT/$BOOT_FAIL_LIMIT"

# ---------------------------------------------------------------------------
# 3) zram
#
#    SPEC: stock is 3969961984 B / lz77eh and it is CORRECT — lz77eh runs on
#    the Emerald Hill HW accelerator (~0 CPU, ~0 heat). THE ALGORITHM IS NEVER
#    CHANGED. We change the size exclusively, and only when the user explicitly
#    asked for it in $ZRAM_CONF. When the file does not exist or the value is
#    empty, we do not touch zram at all (the "empty = leave it alone" contract).
# ---------------------------------------------------------------------------

ZDEV=''
ZPRIO=''
ORIG_SIZE=''
ORIG_ALG=''

# the selected algorithm from "lzo lz4 [lz77eh] zstd"
zram_alg() {
	cat "$ZSYS/comp_algorithm" 2>/dev/null |
		tr ' ' '\n' | grep -m1 '^\[' | tr -d ']['
}

# restores exactly what was there before we intervened
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
		log WARN "zram: rollback OK, restored disksize=$ORIG_SIZE alg=$ORIG_ALG"
		return 0
	fi
	log ERROR "zram: ROLLBACK FAILED — the device is running WITHOUT swap, stock will be restored after a reboot"
	return 1
}

zram_apply() {
	[ -f "$ZRAM_CONF" ] || return 0
	[ -d "$ZSYS" ] || {
		log WARN "zram: $ZSYS does not exist, skipping"
		return 0
	}

	# the last two boots did not finish -> skip the one risky thing in the early phase
	if [ "$BOOT_COUNT" -ge "$BOOT_ZRAM_SKIP" ]; then
		log WARN "zram: boot_count=$BOOT_COUNT, the previous boot did not finish -> zram change skipped"
		return 0
	fi

	# The config is DELIBERATELY not parsed via `. "$ZRAM_CONF"`. A syntax error
	# in a sourced file takes down the whole non-interactive shell — and in the
	# early, BLOCKING boot phase that is exactly what we cannot afford. It would
	# also mean executing arbitrary code from a data file.
	ZRAM_DISKSIZE=$(grep -m1 '^[ 	]*ZRAM_DISKSIZE[ 	]*=' "$ZRAM_CONF" 2>/dev/null |
		cut -d= -f2- | tr -d " \\t\\r\"'")

	[ -n "$ZRAM_DISKSIZE" ] || return 0
	case "$ZRAM_DISKSIZE" in
	*[!0-9]*)
		log ERROR "zram: ZRAM_DISKSIZE='$ZRAM_DISKSIZE' is not a whole number of bytes, ignoring"
		return 0
		;;
	esac

	# Bounds:
	#   ZMIN = 256 MiB — below that zram makes no sense.
	#   ZMAX = the device's physical RAM = 7753832 kB * 1024 = 7939923968 B
	#          (SPEC, section "Device": 8 GB RAM / MemTotal 7753832 kB).
	# The value is a fixed string precisely because multiplying by 1024 would
	# overflow a 32-bit int in mksh (see num_gt).
	ZMIN=268435456
	ZMAX=7939923968
	if num_gt "$ZMIN" "$ZRAM_DISKSIZE" || num_gt "$ZRAM_DISKSIZE" "$ZMAX"; then
		log ERROR "zram: ZRAM_DISKSIZE=$ZRAM_DISKSIZE outside the allowed range $ZMIN..$ZMAX B, ignoring"
		return 0
	fi

	MEM_TOTAL_KB=$(meminfo_kb MemTotal)
	[ -n "$MEM_TOTAL_KB" ] || MEM_TOTAL_KB='?'

	ORIG_SIZE=$(read_int "$ZSYS/disksize")
	[ -n "$ORIG_SIZE" ] || {
		log WARN "zram: cannot read disksize, skipping"
		return 0
	}

	# IDEMPOTENCE: the requested size already applies -> do nothing
	if [ "$ORIG_SIZE" = "$ZRAM_DISKSIZE" ]; then
		log INFO "zram: disksize is already $ZRAM_DISKSIZE B, no change"
		return 0
	fi

	ORIG_ALG=$(zram_alg)
	[ -n "$ORIG_ALG" ] || ORIG_ALG=''

	# the active swap device + its priority (we preserve it so we do not overwrite
	# the order set by the vendor)
	ZDEV=$(grep -m1 '^/dev/[a-z/]*zram0[[:space:]]' /proc/swaps 2>/dev/null | cut -d' ' -f1)
	[ -n "$ZDEV" ] || ZDEV=/dev/block/zram0
	ZPRIO=$(grep -m1 "^$ZDEV[[:space:]]" /proc/swaps 2>/dev/null |
		tr -s ' \t' ' ' | cut -d' ' -f5)
	case "$ZPRIO" in
	'' | *[!0-9-]*) ZPRIO='' ;;
	esac

	# -----------------------------------------------------------------
	# GUARD: a swapoff dumps all swapped-out data back into RAM.
	# When there is more data in swap than there is free RAM minus the 300 MB
	# reserve, the swapoff would end with the OOM killer. We would rather do
	# nothing. In post-fs-data the swap is practically empty, so the guard
	# normally passes; it is here for the case of running the script by hand on
	# a running system.
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
		log WARN "zram: guard — $SWAP_USED kB in swap, free RAM $MEM_AVAIL kB minus the ${SWAP_HEADROOM_KB} kB reserve = $BUDGET kB; a swapoff would risk OOM, skipping"
		return 0
	fi

	log INFO "zram: changing disksize $ORIG_SIZE -> $ZRAM_DISKSIZE B (MemTotal=${MEM_TOTAL_KB} kB, dev=$ZDEV, prio=${ZPRIO:-auto}, alg=$ORIG_ALG stays)"

	if ! swapoff "$ZDEV" >/dev/null 2>&1; then
		log ERROR "zram: swapoff $ZDEV failed, keeping the stock configuration"
		return 0
	fi

	wr "$ZSYS/reset" 1

	# The reset zeroes disksize. comp_algorithm can only be written while
	# disksize == 0, so if the reset dropped the algorithm back to the default,
	# we restore it to the original value NOW. This is not a change of algorithm —
	# it is a restore. lz77eh (Emerald Hill) must stay.
	NOW_ALG=$(zram_alg)
	if [ -n "$ORIG_ALG" ] && [ "$NOW_ALG" != "$ORIG_ALG" ]; then
		wr "$ZSYS/comp_algorithm" "$ORIG_ALG"
		log INFO "zram: comp_algorithm after the reset was '$NOW_ALG', restored to '$ORIG_ALG'"
	fi

	if ! wr "$ZSYS/disksize" "$ZRAM_DISKSIZE"; then
		log ERROR "zram: writing disksize=$ZRAM_DISKSIZE failed, rolling back"
		zram_rollback
		return 0
	fi

	if ! mkswap "$ZDEV" >/dev/null 2>&1; then
		log ERROR "zram: mkswap $ZDEV failed, rolling back"
		zram_rollback
		return 0
	fi

	if [ -n "$ZPRIO" ]; then
		swapon -p "$ZPRIO" "$ZDEV" >/dev/null 2>&1 || swapon "$ZDEV" >/dev/null 2>&1
	else
		swapon "$ZDEV" >/dev/null 2>&1
	fi

	# we verify via /proc/swaps rather than the exit code — it is the only
	# reliable proof that swap is really running
	if ! grep -q "^$ZDEV[[:space:]]" /proc/swaps 2>/dev/null; then
		log ERROR "zram: swapon $ZDEV failed, restoring the original configuration"
		zram_rollback
		return 0
	fi

	NEW_SIZE=$(read_int "$ZSYS/disksize")
	NEW_ALG=$(zram_alg)
	log INFO "zram: done — disksize=$NEW_SIZE B, comp_algorithm=$NEW_ALG"
	return 0
}

zram_apply

exit 0
