#!/system/bin/sh
#
# pixel_tune / uninstall.sh
#
# KernelSU calls this script when the module is removed. The KernelSU docs
# only say "executed when KernelSU removes your module" and, at the same time,
# that the `remove` flag means "the module will be removed next reboot" — in
# practice this can therefore run in TWO different contexts:
#
#   A) straight from the manager / `ksud module uninstall` on a fully booted
#      system => both `settings` and `cmd` are available,
#   B) in the post-fs-data phase of the following boot while modules are being
#      cleaned up => system_server IS NOT RUNNING, `settings put` and
#      `cmd game` will fail, and the phase is blocking (~10 s) => no waiting
#      and no sleep.
#
# The script therefore detects both variants via `sys.boot_completed` and in
# context B skips the parts that need system_server, reporting them to the log.
#
# The script never exits with a non-zero code and is idempotent (running it
# twice breaks nothing — both `revert` and `rm -f` are repeatable).

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
# the daemon keeps its own pidfile (pxtune-auto: PIDF="$STATE/pxtune-auto.pid")
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

# wr <path> <value> — write to a file without leaking an error message to stderr.
# Redirections are evaluated left to right, so `echo x >file 2>/dev/null` does
# not suppress the "Permission denied" message; hence the whole block is wrapped.
wr() {
	{ echo "$2" >"$1"; } 2>/dev/null
}

log INFO "uninstall: start (moddir=$MODDIR)"

BOOTED=0
[ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ] && BOOTED=1

# ---------------------------------------------------------------------------
# 1) Stop the adaptive daemon first — so nothing writes back into sysfs while
#    we revert.
#
#    Primarily via `pxtune-auto stop`: the daemon is started under `setsid` in
#    its own process group (logcat + grep + sleep), so `stop` can take down the
#    whole tree. If the binary is missing, we fall back to killing it manually
#    by its pidfile.
# ---------------------------------------------------------------------------
if [ -x "$AUTOD" ]; then
	"$AUTOD" stop >/dev/null 2>&1
	log INFO "uninstall: called 'pxtune-auto stop'"
fi
PID=$(cat "$PIDFILE" 2>/dev/null | tr -dc '0-9')
if [ -n "$PID" ] && [ -d "/proc/$PID" ]; then
	if tr -d '\000' <"/proc/$PID/cmdline" 2>/dev/null | grep -q 'pxtune-auto'; then
		kill -TERM "-$PID" 2>/dev/null || kill -TERM "$PID" 2>/dev/null
		log WARN "uninstall: pxtune-auto (pid $PID) was still running, SIGTERM sent"
	fi
fi
rm -f "$PIDFILE" "$STATE/pxtune-auto.fifo" 2>/dev/null
rm -rf "$STATE/pxtune-auto.lock" 2>/dev/null

# The metrics sampler — only runs if the user enabled it, but if it is running
# it must not outlive the module. The collected data STAYS (it is the user's
# measurements, not our state) — it is removed together with the rest of $STATE
# by the user, see the end of the script.
METRICSD="$MODDIR/bin/pxtune-metrics"
if [ -x "$METRICSD" ]; then
	"$METRICSD" stop >/dev/null 2>&1
	log INFO "uninstall: called 'pxtune-metrics stop'"
else
	MPID=$(cat "$STATE/pxtune-metrics.pid" 2>/dev/null | tr -dc '0-9')
	if [ -n "$MPID" ] && [ -d "/proc/$MPID" ]; then
		kill -TERM "$MPID" 2>/dev/null
		log WARN "uninstall: pxtune-metrics (pid $MPID) was still running, SIGTERM sent"
	fi
fi
rm -f "$STATE/pxtune-metrics.pid" "$STATE/metrics.on" 2>/dev/null

# Drop DISABLE straight away: if uninstall runs in context B, neither
# post-fs-data.sh nor service.sh may take hold during this boot.
wr "$STATE/DISABLE" "uninstall in progress"

# ---------------------------------------------------------------------------
# 2) Restore everything to stock
# ---------------------------------------------------------------------------
if [ -x "$PXTUNE" ]; then
	"$PXTUNE" revert >/dev/null 2>&1
	RC=$?
	if [ "$RC" = "0" ]; then
		log INFO "uninstall: 'pxtune revert' OK — uclamp, GPU, vm, I/O, thermal and charging back at stock"
	else
		log ERROR "uninstall: 'pxtune revert' exited with code $RC — check $STATE/backup/stock.conf"
	fi

	# Resolution/DPI live in `settings`, which cannot be restored without system_server.
	if [ "$BOOTED" = "1" ]; then
		"$PXTUNE" res reset >/dev/null 2>&1 &&
			log INFO "uninstall: resolution and DPI restored to native" ||
			log WARN "uninstall: 'pxtune res reset' failed"
	else
		log WARN "uninstall: running before sys.boot_completed, 'settings' is unavailable — if you had a custom resolution/DPI, restore them by hand: 'settings delete global display_size_forced' and 'settings put secure display_density_forced 353' (the stock value from the SPEC)"
	fi
else
	log ERROR "uninstall: $PXTUNE is not available, the revert DID NOT RUN — a reboot will restore the values (uclamp/GPU/vm/thermal are not persistent), but CHARGE_STOP_LEVEL and settings will remain; fix them by hand"
fi

# ---------------------------------------------------------------------------
# 3) zram
#
# SPEC: "a swapoff at runtime is DANGEROUS (risk of OOM) => zram changes only
# in post-fs-data.sh". So we DELIBERATELY DO NOT touch zram here. There is no
# need to: the zram size is not persistent, post-fs-data.sh will no longer run
# after uninstalling, and the very next boot creates the vendor stock
# 3969961984 B / lz77eh.
# ---------------------------------------------------------------------------
if [ -f "$STATE/zram.conf" ]; then
	log INFO "uninstall: zram is deliberately not changed at runtime (risk of OOM); the stock size restores itself on the next boot"
fi

# ---------------------------------------------------------------------------
# 4) Cleaning up /data/adb/pixel_tune/
#
# DECISION: user data is NOT DELETED.
#
# Reasons:
#   1. For this path the SPEC explicitly says "state, SURVIVES A MODULE
#      REINSTALL". Deleting it on uninstall would break that contract.
#   2. In the Magisk/KernelSU world uninstall.sh also runs during an upgrade or
#      a reinstall, not only on a final departure. Deleting profiles would mean
#      the user loses the settings they tuned themselves on every module
#      update.
#   3. `backup/stock.conf` is the last safety net. If the revert in step 2
#      failed (or only partly completed in context B), it is the only record of
#      the stock values. Deleting it at the moment it may be needed is wrong.
#   4. `pxtune.log` holds the evidence of what uninstall did. Deleting
#      diagnostics at the very moment of uninstalling defeats the point of a
#      log.
#   5. Deleting user data should always be an explicit choice, not a side
#      effect of uninstalling a module. The user can remove the directory with
#      a single `rm -rf`, but lost profiles cannot be recovered.
#
# Only EPHEMERAL files are therefore deleted — the ones that make no sense
# without the module and would be confusing on a reinstall:
#   boot_count        — bootloop protection state of the previous install
#   res_pending       — a resolution watchdog nobody will confirm any more
#   manual_override   — a flag for a daemon that no longer runs
#   pxtune-auto.pid   — the pid of a dead process (deleted above)
#   pxtune-auto.fifo  — the daemon's named pipe (deleted above)
#   pxtune-auto.lock  — the daemon's lock (deleted above)
#
# What stays (user data and diagnostics):
#   profiles/  backup/  active  auto  zram.conf  appstats  appstats.override
#   pxtune.log  pxtune.log.old
#
# Opt-in for a hard wipe: create /data/adb/pixel_tune/PURGE before uninstalling.
# ---------------------------------------------------------------------------
rm -f "$STATE/boot_count" "$STATE/res_pending" "$STATE/manual_override" 2>/dev/null

if [ -f "$STATE/PURGE" ]; then
	log WARN "uninstall: PURGE found — deleting all of $STATE including profiles and the backup"
	sync 2>/dev/null
	rm -rf "$STATE" 2>/dev/null
else
	# DISABLE from step 1 is of no use any more (the module is going away) and on
	# a possible reinstall it would kill it outright. Remove it at the very end.
	rm -f "$STATE/DISABLE" 2>/dev/null
	log INFO "uninstall: done. User data in $STATE preserved (profiles, backup/stock.conf, log). To delete it all: rm -rf $STATE"
fi

sync 2>/dev/null
exit 0
