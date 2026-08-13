#!/system/bin/sh
#
# pixel_tune / service.sh
#
# LATE PHASE (late_start service). Per the KernelSU docs this is NON-BLOCKING —
# it runs in parallel with the rest of the boot. A failure here therefore cannot
# cause a bootloop, which is why EVERYTHING except zram belongs here.
#
# Responsibilities:
#   - the DISABLE check
#   - wait for the system to settle
#   - create backup/stock.conf once (delegated to `pxtune`)
#   - apply the active profile
#   - deal with the resolution (unconfirmed change / persistent setting)
#   - start the adaptive daemon if it is enabled
#   - AT THE END zero boot_count = "the boot completed fine"
#
# The script NEVER exits with a non-zero code, does not use `set -e` and is
# idempotent.

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

# Waiting for the system to settle — THE REASONING:
#
#  a) BOOT_WAIT_MAX: we actively wait for `sys.boot_completed=1` instead of a
#     blind sleep. Until then system_server is not running, so `settings put`
#     and `cmd game` (SPEC: resolution, Game Mode) would fail silently. The
#     180 s ceiling is an upper safeguard for a slow first boot after an
#     OTA/wipe; on a normal Pixel 8a boot the loop ends far sooner and nothing
#     is delayed.
#
#  b) SETTLE: another 20 s after boot_completed. The reason comes from the
#     measured data in the SPEC:
#     - the thermal HAL rewrites the cooling devices on a ~7 s cycle and sets
#       `vendor.thermal.<SENSOR>.profile` itself (during the probe it was
#       already on `camera`),
#     - Google power-service.pixel-libperfmgr touches the uclamp boost at
#       startup.
#     If we wrote sooner, the HAL would overwrite our values and the profile
#     would appear not to take. 20 s ~= 3 HAL cycles = a conservative margin.
#     The exact settling time of the HALs is NOT measured in the SPEC (see OPEN
#     QUESTIONS) — it is a chosen constant, not a derived one. The delay bothers
#     nobody: the script is non-blocking.
BOOT_WAIT_MAX=180
SETTLE=20

# ---------------------------------------------------------------------------
# log — format per the SPEC (inline, so the script does not depend on other files)
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

# wr <path> <value> — write to a file without leaking an error message to stderr.
# Redirections are evaluated left to right, so `echo x >file 2>/dev/null` does
# not suppress the "Permission denied" message; hence the whole block is wrapped.
wr() {
	{ echo "$2" >"$1"; } 2>/dev/null
}

# zeroing the bootloop protection counter. Called from exactly one place at the end.
clear_boot_count() {
	wr "$STATE/boot_count" 0
	sync 2>/dev/null
}

mkdir -p "$STATE" "$STATE/backup" "$STATE/profiles" 2>/dev/null

# ---------------------------------------------------------------------------
# Cleaning up runtime markers from the previous boot.
#
# `pxtune-auto.exiting` is the "the daemon should stop / the watchdog must not
# restart it" marker. It lives in /data/adb though, which SURVIVES a reboot — so
# when the daemon was stopped before a restart, after the boot it did start, saw
# the marker immediately and quit again. Measured: the daemon came up at
# 07:35:58 and was gone at 07:36:23. The marker only applies to the run it was
# created in.
#
# After a hard shutdown `pxtune-auto.pid` points at a non-existent process and
# could confuse the "already running" check.
rm -f "$STATE/pxtune-auto.exiting" "$STATE/pxtune-auto.pid" \
      "$STATE/pxtune-auto.fifo" 2>/dev/null
rmdir "$STATE/pxtune-auto.lock" 2>/dev/null

# ---------------------------------------------------------------------------
# 0) Seeding profiles from the module.
# Without this a fresh install would have NO profiles at all (the CLI can only
# create an empty balanced.conf) and the daemon would fail on every event with
# "profile does not exist". ONLY missing files are copied — the user's edits to
# existing profiles are never overwritten. Written via .tmp + mv so an
# interrupted boot does not leave a half-written file.
# ---------------------------------------------------------------------------
if [ -d "$MODDIR/profiles" ]; then
	for _src in "$MODDIR/profiles"/*.conf; do
		[ -f "$_src" ] || continue
		_dst="$STATE/profiles/${_src##*/}"
		if [ ! -f "$_dst" ]; then
			cp "$_src" "$_dst.tmp" 2>/dev/null \
				&& mv "$_dst.tmp" "$_dst" 2>/dev/null \
				&& log INFO "service: profile ${_src##*/} seeded from the module"
		fi
	done
fi

# ---------------------------------------------------------------------------
# 1) DISABLE
#
# Note: boot_count is DELIBERATELY not zeroed here. When the module is off it
# does nothing, and post-fs-data.sh exits earlier anyway, so the counter does
# not grow.
# ---------------------------------------------------------------------------
if [ -f "$STATE/DISABLE" ]; then
	log INFO "service: DISABLE exists, nothing is applied"
	exit 0
fi

# ---------------------------------------------------------------------------
# 2) Waiting for the system to settle
# ---------------------------------------------------------------------------
i=0
while [ "$i" -lt "$BOOT_WAIT_MAX" ]; do
	[ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ] && break
	sleep 1
	i=$((i + 1))
done

if [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ]; then
	# The boot literally completed → the bootloop protection has served its
	# purpose, so we zero it NOW. If we waited until the end of the script
	# (SETTLE + profile + settings = tens of seconds), three user restarts in that
	# window would disable the module even though the system booted fine every
	# time. The counter is there to catch a bootloop, not the user's speed. The
	# call at the end of the script stays (it is idempotent and also covers the
	# branch where boot_completed never arrived).
	clear_boot_count
	log INFO "service: sys.boot_completed after ${i}s, boot_count zeroed, waiting another ${SETTLE}s for the HALs to settle"
else
	log WARN "service: sys.boot_completed did not arrive within ${BOOT_WAIT_MAX}s, continuing carefully"
fi
sleep "$SETTLE"

# DISABLE may have appeared while waiting (user / WebUI). Check again.
if [ -f "$STATE/DISABLE" ]; then
	log INFO "service: DISABLE appeared while waiting, exiting without intervening"
	exit 0
fi

if [ ! -x "$PXTUNE" ]; then
	log ERROR "service: $PXTUNE does not exist or is not executable — applying nothing"
	# the boot itself went fine though, so the counter should be zeroed
	clear_boot_count
	exit 0
fi

# ---------------------------------------------------------------------------
# 3) backup/stock.conf — once, delegated to `pxtune`
#
# Only one place may know how to snapshot the stock values (the CLI knows all
# the paths and their formats); the logic is NOT DUPLICATED here.
#
# How the delegation works: `bin/pxtune` unconditionally calls `snapshot_stock`
# + `seed_profiles` in its `main()` BEFORE dispatching to a subcommand, and
# `snapshot_stock` is idempotent ("created ONCE, never overwritten"). Running
# any harmless subcommand is therefore enough. We use `profile current`, which
# only prints the name of the active profile and changes nothing.
# (There is NO separate `pxtune backup` subcommand in the CLI — see OPEN
# QUESTIONS.)
#
# HARD CONSTRAINT #5 from the SPEC: "everything must be reversible and backed
# up". When the backup cannot be created, we DELIBERATELY DO NOT APPLY the
# profile — otherwise we would create a state `pxtune revert` cannot undo.
# ---------------------------------------------------------------------------
APPLY_OK=1
if [ ! -s "$BACKUP" ]; then
	log INFO "service: backup/stock.conf is missing, letting the CLI create it (pxtune profile current)"
	"$PXTUNE" profile current >/dev/null 2>&1
	if [ ! -s "$BACKUP" ]; then
		APPLY_OK=0
		log ERROR "service: $BACKUP was not created — the profile is NOT APPLIED (no revert without a backup)"
	else
		log INFO "service: backup/stock.conf created"
	fi
fi

# ---------------------------------------------------------------------------
# 4) The active profile
#
# MIND the CLI contract: per the SPEC (and per the actual implementation in
# bin/pxtune, function profile_apply) `pxtune profile <name>` sets
# `manual_override`. During a boot that is an undesirable side effect — a user
# running in `auto` mode would end up in manual mode after every reboot and the
# daemon would never take over again. We therefore remember the manual_override
# state before the call and restore it exactly afterwards.
#
# Why not `pxtune profile <name> --auto` (the flag pxtune-auto asks for):
#   1. it is not implemented in bin/pxtune yet (see the pxtune-auto header:
#      "WHAT NEEDS TO BE ADDED TO bin/pxtune (not there yet)"),
#   2. and even once it is, its contract is "when manual_override exists, do
#      nothing" — which is wrong for a boot: the active profile should ALWAYS be
#      restored, including in manual mode. Saving and restoring the flag is
#      therefore the better solution going forward as well.
# ---------------------------------------------------------------------------
if [ "$APPLY_OK" = "1" ]; then
	ACTIVE=$(cat "$STATE/active" 2>/dev/null | tr -d ' \t\r\n')

	if [ -z "$ACTIVE" ]; then
		# The SPEC describes 'balanced' as "Balanced — stock behaviour", so it is a
		# safe default for a fresh install. We set it only when the profile really
		# exists; we do not invent anything.
		if [ -f "$STATE/profiles/balanced.conf" ]; then
			ACTIVE=balanced
			wr "$STATE/active" "$ACTIVE"
			log INFO "service: 'active' was missing, default profile balanced set"
		else
			log WARN "service: 'active' is missing and profiles/balanced.conf does not exist — applying no profile"
		fi
	fi

	# sanitise the name (the file is user-writable and goes into an argument)
	case "$ACTIVE" in
	'') ;;
	*[!A-Za-z0-9_-]*)
		log ERROR "service: invalid profile name '$ACTIVE' in $STATE/active, ignoring"
		ACTIVE=''
		;;
	esac

	if [ -n "$ACTIVE" ] && [ ! -f "$STATE/profiles/$ACTIVE.conf" ]; then
		log ERROR "service: profile '$ACTIVE' does not exist ($STATE/profiles/$ACTIVE.conf), not applying"
		ACTIVE=''
	fi

	if [ -n "$ACTIVE" ]; then
		HAD_OVERRIDE=0
		[ -f "$STATE/manual_override" ] && HAD_OVERRIDE=1

		"$PXTUNE" profile "$ACTIVE" >/dev/null 2>&1
		RC=$?

		# restore the original manual_override state (see the comment above)
		if [ "$HAD_OVERRIDE" = "0" ]; then
			rm -f "$STATE/manual_override" 2>/dev/null
		else
			[ -f "$STATE/manual_override" ] || wr "$STATE/manual_override" ""
		fi

		if [ "$RC" = "0" ]; then
			log INFO "service: applied profile '$ACTIVE' (manual_override=$HAD_OVERRIDE preserved)"
		else
			log ERROR "service: 'pxtune profile $ACTIVE' exited with code $RC"
		fi
	fi
fi

# ---------------------------------------------------------------------------
# 4b) Per-app: layer 3 from the previous run
#
# `appmode.active` lives in /data, so it survives a reboot — but the settings it
# describes (refresh rate, display_size_forced, display_density_forced) were
# loaded by Android from its own storage before this script even ran. State and
# reality therefore have to be reconciled: the stored "old" values are exactly
# what should apply when no app with a rule is running.
#
# This is the 5th of the SIX independent paths that must call `app leave` (the
# list and the reasons are at cmd_leave() in bin/pxtune-perapp). Without it, a
# user whose phone crashed mid-game would stay locked at 60 Hz or at someone
# else's resolution, and a reboot would not help them.
#
# `app leave` is IDEMPOTENT — when nothing is deployed it quietly exits with
# code 0, so it may be called blindly here. It must come BEFORE section 5
# (resolution): leave writes the stored display values, so it would otherwise
# overwrite what `pxtune res reset` does.
# ---------------------------------------------------------------------------
if [ -f "$STATE/appmode.active" ]; then
	log WARN "service: appmode.active found from the previous run — restoring layer 3 of the per-app rule"
fi
"$PXTUNE" app leave >/dev/null 2>&1 ||
	log ERROR "service: 'pxtune app leave' failed — the refresh rate / resolution may be left over from a per-app rule"

# ---------------------------------------------------------------------------
# 4c) Tweaks
#
# Most tweaks live in sysfs/procfs, which DOES NOT SURVIVE a reboot — they have
# to be deployed again on every start. They are deployed ONLY HERE (after
# boot_completed + SETTLE), because some use the `prop` mechanism and would not
# take earlier.
# Tweaks with the `settings` mechanism are deliberately skipped — Android keeps
# those itself and calling into binder for them during a boot is a needless
# risk.
#
# The order matters: only AFTER the profile is applied. The profile calls
# restore_stock_values(), which also restores keys that tweaks touch
# (readahead, charge levels, vm.*). If tweaks were deployed earlier, the
# profile would overwrite them.
# ---------------------------------------------------------------------------
if [ -s "$STATE/tweaks.conf" ]; then
	if "$PXTUNE" tweak apply-boot >/dev/null 2>&1; then
		log INFO "service: tweaks deployed (tweak apply-boot)"
	else
		log ERROR "service: 'pxtune tweak apply-boot' failed"
	fi
else
	log INFO "service: no tweaks to deploy"
fi

# ---------------------------------------------------------------------------
# 5) Resolution
#
#  a) `res_pending` exists => the last resolution change was not confirmed via
#     `pxtune res confirm` and the device rebooted in the meantime. That is
#     exactly the scenario the resolution watchdog is for (the user could not
#     see the screen; the watchdog in the CLI is a `sleep 60` in a process that
#     does not survive a reboot).
#     => a hard return to native via `pxtune res reset`.
#
#  b) otherwise: a persistent resolution does NOT need restoring and is
#     deliberately not overwritten. `pxtune res` stores it in `settings put
#     global display_size_forced` / `settings put secure display_density_forced`
#     (SPEC, section "Display") and that is Android persistent storage —
#     WindowManager applies it itself when system_server starts, long before
#     service.sh gets here. Any write of ours would either be a no-op or would
#     overwrite the user's later change. We therefore only log the state.
#     (There is NO `pxtune res restore` subcommand in the CLI — see OPEN
#     QUESTIONS.)
# ---------------------------------------------------------------------------
if [ -f "$STATE/res_pending" ]; then
	log WARN "service: res_pending found — an unconfirmed resolution change survived a reboot, returning to native"
	"$PXTUNE" res reset >/dev/null 2>&1 ||
		log ERROR "service: 'pxtune res reset' failed"
	rm -f "$STATE/res_pending" 2>/dev/null
else
	# CAUTION: `settings` is binder. Without a timeout, a hung system_server would
	# stall service.sh and clear_boot_count would NEVER be reached -> three such
	# boots and the bootloop protection disables the module even though nothing
	# actually went wrong.
	RES_NOW=$(timeout 10 settings get global display_size_forced 2>/dev/null | tr -d ' \t\r\n')
	DPI_NOW=$(timeout 10 settings get secure display_density_forced 2>/dev/null | tr -d ' \t\r\n')
	case "$RES_NOW" in null | '') RES_NOW='(native)' ;; esac
	case "$DPI_NOW" in null | '') DPI_NOW='(default)' ;; esac
	log INFO "service: the persistent resolution is kept by Android itself — display_size_forced=$RES_NOW, display_density_forced=$DPI_NOW"
fi

# ---------------------------------------------------------------------------
# 6) The adaptive daemon
#
# The state is read from `$STATE/auto` so that there is a single source of
# truth. We MIRROR the semantics of `auto_state()` in bin/pxtune:
# 'off'/'OFF'/'0'/'false' mean off, anything else INCLUDING A MISSING FILE
# means on.
#
# Starting is delegated to `pxtune-auto start` — the daemon detaches itself via
# setsid, keeps its own `$STATE/pxtune-auto.pid` and its `do_start()` already
# contains an "already running (pid N)" check. Idempotence is therefore its
# job; service.sh does not duplicate it and keeps no pidfile of its own.
# ---------------------------------------------------------------------------
AUTO_STATE=$(cat "$STATE/auto" 2>/dev/null | tr -d ' \t\r\n')
case "$AUTO_STATE" in
off | OFF | 0 | false)
	log INFO "service: adaptive daemon disabled ($STATE/auto='$AUTO_STATE')"
	;;
*)
	if [ ! -x "$AUTOD" ]; then
		log WARN "service: auto is enabled, but $AUTOD does not exist or is not executable — daemon not started"
	else
		"$AUTOD" start >/dev/null 2>&1
		RC=$?
		AUTO_PID=$(cat "$STATE/pxtune-auto.pid" 2>/dev/null | tr -dc '0-9')
		if [ -n "$AUTO_PID" ] && [ -d "/proc/$AUTO_PID" ]; then
			log INFO "service: pxtune-auto is running (pid $AUTO_PID)"
		else
			log ERROR "service: 'pxtune-auto start' exited with code $RC and the daemon is not running"
		fi
	fi
	;;
esac

# ---------------------------------------------------------------------------
# 6b) The metrics sampler (battery / power draw / temperatures).
#
# Started ONLY when the user enabled it (`pxtune metrics start` creates
# $STATE/metrics.on). Without that it does not start at all — it is a
# diagnostic tool, not part of normal operation, and there is no point in it
# sampling for everyone all the time.
#
# A failure is NON-FATAL and deliberately only logged: data collection must not
# endanger the boot.
# ---------------------------------------------------------------------------
METRICSD="$BIN/pxtune-metrics"
if [ -f "$STATE/metrics.on" ]; then
	if [ ! -x "$METRICSD" ]; then
		log WARN "service: metrics.on exists, but $METRICSD is not executable — sampler not started"
	else
		"$METRICSD" start >/dev/null 2>&1
		MET_PID=$(cat "$STATE/pxtune-metrics.pid" 2>/dev/null | tr -dc '0-9')
		if [ -n "$MET_PID" ] && [ -d "/proc/$MET_PID" ]; then
			log INFO "service: pxtune-metrics is running (pid $MET_PID)"
		else
			log WARN "service: the metrics sampler could not be started"
		fi
	fi
fi

# ---------------------------------------------------------------------------
# 7) The boot completed fine -> zero the counter.
#
# It is DELIBERATELY zeroed even when one of the steps above failed. The counter
# watches for a bootloop, not for the success of a profile: if we got this far,
# the system booted. If a failed step did not zero it, three merely
# unsuccessful profile applications would disable the module for no reason.
# ---------------------------------------------------------------------------
clear_boot_count
log INFO "service: done, boot_count zeroed"

exit 0
