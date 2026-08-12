#!/bin/sh
# check.sh - read-only pre-purchase inspection for a used Apple silicon Mac.
# Reports config, Activation Lock, MDM/DEP enrollment, security posture, battery.
# Makes no changes. Requires no sudo. Safe to review before running:
#   curl -fsSL <url>/check.sh | less
#   curl -fsSL <url>/check.sh | sh

[ "$(uname -s)" = "Darwin" ] || { echo "This script only works on macOS - run it on the Mac you are inspecting."; exit 0; }

if [ -t 1 ]; then
  RED=$(printf '\033[31m'); YLW=$(printf '\033[33m'); GRN=$(printf '\033[32m')
  DIM=$(printf '\033[2m'); BLD=$(printf '\033[1m'); RST=$(printf '\033[0m')
else
  RED=; YLW=; GRN=; DIM=; BLD=; RST=
fi
FLAGS=0

hdr()  { printf '\n%s== %s ==%s\n' "$BLD" "$1" "$RST"; }
ok()   { printf '  %s[ ok ]%s %s\n' "$GRN" "$RST" "$1"; }
warn() { printf '  %s[warn]%s %s\n' "$YLW" "$RST" "$1"; FLAGS=$((FLAGS+1)); }
bad()  { printf '  %s[STOP]%s %s\n' "$RED" "$RST" "$1"; FLAGS=$((FLAGS+1)); }
cont() { printf '         %s\n' "$1"; }  # continuation line, aligns under ok/warn/bad text
info() { printf '  %s\n' "$1"; }
note() { printf '  %s%s%s\n' "$DIM" "$1" "$RST"; }

printf '%smaccheck%s  %s  %s\n' "$BLD" "$RST" "$(date '+%Y-%m-%d %H:%M')" \
  "$(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion))"

# ---------------------------------------------------------------- hardware
hdr "Hardware"
HW=$(system_profiler SPHardwareDataType 2>/dev/null)
SERIAL=$(printf '%s' "$HW" | awk -F': ' '/Serial Number/{print $2; exit}')
CHIP=$(printf '%s' "$HW"   | awk -F': ' '/Chip/{print $2; exit}')
MODEL=$(printf '%s' "$HW"  | awk -F': ' '/Model Name/{print $2; exit}')
MODELID=$(printf '%s' "$HW"| awk -F': ' '/Model Identifier/{print $2; exit}')
CORES=$(printf '%s' "$HW"  | awk -F': ' '/Total Number of Cores/{print $2; exit}')
MEMB=$(sysctl -n hw.memsize 2>/dev/null)
MEMGB=$((MEMB / 1024 / 1024 / 1024))

info "Model     : $MODEL ($MODELID)"
info "Chip      : $CHIP"
info "CPU cores : $CORES"
info "Memory    : ${MEMGB} GB  (${MEMB} bytes)"
info "Serial    : $SERIAL"

GPUC=$(ioreg -l 2>/dev/null | sed -n 's/.*"gpu-core-count" = \([0-9]*\).*/\1/p' | head -1)
[ -n "$GPUC" ] && info "GPU cores : $GPUC" \
  || note "GPU cores : could not detect - see Apple menu > About This Mac"

DISKB=$(diskutil info -plist disk0 2>/dev/null \
  | awk '/<key>Size<\/key>/{getline; gsub(/[^0-9]/,""); print; exit}')
[ -n "$DISKB" ] && info "Storage   : $((DISKB / 1000 / 1000 / 1000)) GB internal disk"

note "Memory and storage cannot be upgraded on Apple silicon Macs, so the"
note "sizes shown above are exactly what you would be buying."
note "Look up the serial at https://checkcoverage.apple.com/ to confirm the model"
note "and warranty. (It won't show the original memory/storage config - only Apple"
note "staff at a Genius Bar or authorized repair shop can look that up.)"

# --------------------------------------------------------- activation lock
hdr "Activation Lock / Find My"
AL=$(printf '%s' "$HW" | awk -F': ' '/Activation Lock Status/{print $2; exit}')
case "$AL" in
  Disabled) ok "Activation Lock is off - no previous owner's Apple ID blocks this Mac" ;;
  Enabled)  bad "Activation Lock is ON - the Mac is tied to the previous owner's Apple ID."
            cont "It will become unusable after an erase unless THEY remove it (by signing"
            cont "out of iCloud on the Mac, or removing it at icloud.com/find)."
            cont "Do not pay until this check shows 'off'." ;;
  *)        warn "Activation Lock status could not be read (reported: ${AL:-nothing})" ;;
esac

# Find My Mac leaves two local traces: the daemon's own setting (world-readable
# plist) and an Apple ID token in NVRAM. On Apple silicon the token sits in the
# protected system NVRAM partition that plain `nvram -p` cannot list without
# root, but the NVRAM stats in the device registry (ioreg) still reveal whether
# it exists; Intel Macs list the token directly.
FMM=$(defaults read /Library/Preferences/com.apple.FindMyMac FMMEnabled 2>/dev/null)
TOKEN=$( { ioreg -l 2>/dev/null \
             | grep -o '"0[0-9]:fmm-mobileme-token-FMM"={[^}]*"Present"=Yes[^}]*}'
           nvram -p 2>/dev/null | grep -i 'fmm-mobileme-token-FMM'
         } | head -1 )
if [ "$FMM" = "1" ] || [ -n "$TOKEN" ]; then
  bad "Find My Mac is turned ON - an Apple ID is still signed in and can locate"
  cont "or lock this Mac remotely. Ask the seller to turn it off (System Settings"
  cont "> [their name] > Find My Mac) or sign out of iCloud, then re-run this check."
elif [ "$FMM" = "0" ]; then
  ok "Find My Mac is turned off"
else
  note "Find My Mac: no setting recorded (normal after an erase or clean install)"
fi

if [ "$AL" = "Disabled" ] && { [ "$FMM" = "1" ] || [ -n "$TOKEN" ]; }; then
  note "Find My Mac is on, yet Activation Lock reads disabled. That combination"
  note "means the signed-in Apple ID lacks two-factor authentication, or the lock"
  note "status has not synced yet - it could turn on later. Still have the seller"
  note "sign out before you pay."
fi

# ------------------------------------------------------------------- mdm
hdr "MDM / Device Enrollment"
ENR=$(profiles status -type enrollment 2>/dev/null)
if [ -z "$ENR" ]; then
  warn "Could not read the enrollment status. Re-run with admin rights to see it:"
  cont "sudo sh check.sh"
else
  printf '%s\n' "$ENR" | sed 's/^/  /'
  if printf '%s' "$ENR" | grep -qi 'DEP: *Yes'; then
    bad "This Mac's serial number is registered to a company or school (via Apple"
    cont "Business Manager, sometimes called DEP). Erasing or restoring the Mac"
    cont "does NOT remove this - it can re-lock itself to that organization at any"
    cont "time. Only the organization can release it. Do not buy unless the seller"
    cont "gets it released first."
  else
    ok "Not registered to any company or school (no Apple Business Manager record)"
  fi
  if printf '%s' "$ENR" | grep -qi 'MDM enrollment: *Yes'; then
    warn "A remote-management (MDM) profile is installed. If the line above says"
    cont "'Not registered', a full erase of the Mac will remove it. If the Mac IS"
    cont "registered to an organization, it will come back after an erase."
  else
    ok "No remote management (MDM) is active"
  fi
fi

PROF=$(profiles list 2>/dev/null | grep -c 'attribute: profileIdentifier')
if [ "${PROF:-0}" -gt 0 ]; then
  warn "$PROF configuration profile(s) installed - these can enforce restrictions."
  cont "See what they do with: sudo profiles list"
else
  ok "No configuration profiles installed"
fi

# A known trick for hiding DEP registration or dodging activation checks is to
# block Apple's enrollment/activation servers in /etc/hosts. A stock Mac never
# has such entries, so any hit means the enrollment answers above may be fake.
HOSTSHIT=$(grep -iE '^[[:space:]]*(127\.|0\.0\.0\.0|::)[^#]*(deviceenrollment|mdmenrollment|iprofiles|acmdm|albert|gdmf)\.apple\.com' /etc/hosts 2>/dev/null)
if [ -n "$HOSTSHIT" ]; then
  bad "Apple's enrollment/activation servers are BLOCKED in this Mac's hosts file."
  cont "No Mac ships this way - someone set it up deliberately, usually to hide"
  cont "that the Mac belongs to an organization or to dodge Apple's checks."
  cont "Do not trust the enrollment results above. Blocked entries:"
  printf '%s\n' "$HOSTSHIT" | sed 's/^/         > /'
else
  ok "Apple's enrollment/activation servers are not blocked in the hosts file"
fi

# Management agents from MDM vendors survive profile removal and reveal a
# corporate past even when the enrollment checks above look clean.
MDMAGENTS=$(find /Library/LaunchDaemons /Library/LaunchAgents -maxdepth 1 -name '*.plist' 2>/dev/null \
  | grep -iE '(jamf|mosyle|kandji|simplemdm|hexnode|addigy|fleetsmith|filewave|airwatch|vmware\.hub|microsoft\.intune|manageengine)')
if [ -n "$MDMAGENTS" ]; then
  warn "Management software from an MDM vendor is installed - this Mac was"
  cont "set up by a company or school, even if the checks above look clean."
  cont "Files found:"
  printf '%s\n' "$MDMAGENTS" | sed 's/^/         > /'
else
  ok "No MDM vendor software found (Jamf, Kandji, Mosyle, Intune, ...)"
fi

note "IMPORTANT: everything above is local evidence only. Organization registration"
note "lives on Apple's servers, keyed to the serial - the only definitive test is an"
note "erase + online setup. A registered Mac shows an unskippable 'Remote Management'"
note "screen during setup. Before paying, have the seller erase the Mac and click"
note "through setup while you watch, connected to YOUR phone's hotspot (a seller's"
note "network could block Apple's servers to hide the screen)."
note "To ask Apple's servers directly without erasing, run:"
note "  sudo profiles show -type enrollment    (fetches the record, read-only)"
note "Do NOT use 'profiles renew -type enrollment' for this - despite the name,"
note "it doesn't just check: on a registered Mac it downloads the enrollment"
note "config and STARTS the enrollment, which only an erase can back out of."

# -------------------------------------------------------------- security
hdr "Security posture"
SIP=$(csrutil status 2>/dev/null | sed 's/^.*status: //; s/\.$//')
case "$SIP" in
  enabled) ok "System Integrity Protection (SIP): enabled - the normal setting" ;;
  "")      warn "System Integrity Protection (SIP): could not read (should be 'enabled')" ;;
  *)       warn "System Integrity Protection (SIP): $SIP - this built-in security"
           cont "feature has been turned off or weakened. Not dangerous to buy, but"
           cont "plan to erase and reinstall macOS before using the Mac." ;;
esac

FV=$(fdesetup status 2>/dev/null | head -1)
case "$FV" in
  *"Off"*) ok "FileVault disk encryption: off - normal for a Mac prepared for sale" ;;
  *"On"*)  warn "FileVault disk encryption: on - the disk is locked to an existing"
           cont "user account. Make sure you get a working login and password, or"
           cont "have the seller erase the Mac while you watch." ;;
  *)       note "FileVault disk encryption: ${FV:-could not read}" ;;
esac

if command -v bputil >/dev/null 2>&1; then
  BP=$(bputil -d 2>/dev/null)
  if [ -z "$BP" ]; then
    note "Boot security: reading it needs admin rights - run 'sudo bputil -d' to see it"
  elif printf '%s' "$BP" | grep -qi 'Full Security'; then
    ok "Boot security: Full Security - the factory-default setting"
  else
    warn "Boot security has been lowered from the factory default (often done to"
    cont "run modified software). Erasing and reinstalling macOS restores it."
    printf '%s' "$BP" | grep -i 'Security Mode' | sed 's/^/    /'
  fi
fi

# --------------------------------------------------------------- battery
hdr "Battery"
PW=$(system_profiler SPPowerDataType 2>/dev/null)
CYC=$(printf '%s' "$PW" | awk -F': ' '/Cycle Count/{print $2; exit}')
CON=$(printf '%s' "$PW" | awk -F': ' '/Condition/{print $2; exit}')
MXC=$(printf '%s' "$PW" | awk -F': ' '/Maximum Capacity/{print $2; exit}')
if [ -n "$CYC$CON$MXC" ]; then
  info "Cycle count      : ${CYC:-unknown}"
  info "Condition        : ${CON:-unknown}"
  info "Maximum capacity : ${MXC:-unknown}"
  if [ -n "$CYC" ] && [ "$CYC" -gt 300 ] 2>/dev/null; then
    warn "Over 300 charge cycles - more use than 'like new' or 'open-box' implies."
    cont "Fine for a used Mac, but factor it into the price."
  fi
  case "$CON" in
    Normal|"") : ;;
    *) warn "Battery condition is '$CON' (should be 'Normal') - the battery may need service" ;;
  esac
else
  note "No battery found - normal for a desktop Mac (mini, iMac, Studio, Pro)"
fi

# --------------------------------------------------------------- summary
hdr "Summary"
if [ "$FLAGS" -eq 0 ]; then
  printf '  %sAll checks passed - no problems found.%s\n' "$GRN" "$RST"
else
  printf '  %s%d potential issue(s) found - look for [STOP] and [warn] lines above before paying.%s\n' \
    "$YLW" "$FLAGS" "$RST"
fi
printf '  Last step: check the warranty for serial %s at\n' "$SERIAL"
printf '  https://checkcoverage.apple.com/\n\n'
