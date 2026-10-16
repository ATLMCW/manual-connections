#!/usr/bin/env bash
# Copyright (C) 2020 Private Internet Access, Inc.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# This script keeps a WireGuard connection established by these scripts alive
# past PIA's ~24 hour token/key lifetime. It re-runs get_token.sh and
# connect_to_wireguard_with_token.sh (unmodified) against the same server
# whenever a self-maintained renewal timer says it's due. It is safe to
# invoke repeatedly (e.g. from cron); it only acts when renewal is due.
#
# It does NOT renew port forwarding. If you use PIA_PF=true, you must restart
# port_forwarding.sh yourself after a renewal recreates the WireGuard
# interface, since the old process is bound to a tunnel that no longer exists.
# PIA_PF is always forced to false for the reconnect this script performs,
# regardless of what's configured, so it can never block on
# connect_to_wireguard_with_token.sh's own port_forwarding.sh hand-off.

# This function allows you to check if the required tools have been installed.
check_tool() {
  cmd=$1
  pkg=$2
  if ! command -v "$cmd" >/dev/null; then
    echo "$cmd could not be found"
    echo "Please install $pkg"
    exit 1
  fi
}

check_tool wg-quick wireguard-tools
check_tool curl curl
check_tool jq jq

# Check if terminal allows output, if yes, define colors for output
if [[ -t 1 ]]; then
  ncolors=$(tput colors)
  if [[ -n $ncolors && $ncolors -ge 8 ]]; then
    red=$(tput setaf 1) # ANSI red
    green=$(tput setaf 2) # ANSI green
    nc=$(tput sgr0) # No Color
  else
    red=''
    green=''
    nc='' # No Color
  fi
fi

# Only allow script to run as root
if (( EUID != 0 )); then
  echo -e "${red}This script needs to be run as root. Try again with 'sudo $0'${nc}"
  exit 1
fi

: "${PIA_RENEW_CONF:=/opt/piavpn-manual/renew_wireguard.conf}"
: "${PIA_RENEW_STATE_FILE:=/opt/piavpn-manual/renew_wireguard.state}"
: "${PIA_RENEW_INTERVAL_HOURS:=20}"
: "${PIA_RENEW_CHECK_INTERVAL_SECONDS:=3600}"
: "${PIA_RENEW_CREDENTIALS_FILE:=/opt/piavpn-manual/renew_wireguard_credentials}"
: "${PIA_WG_SERVER_FILE:=/opt/piavpn-manual/wg_server}"

mkdir -p "$(dirname "$PIA_RENEW_STATE_FILE")"

# Load WG_SERVER_IP/WG_HOSTNAME (and optional passthroughs, e.g. PIA_DNS)
# from a config file if present. Env vars set before invoking this script
# always take precedence over the file, since we only fill in what's unset.
# This file is NOT where credentials go -- see PIA_RENEW_CREDENTIALS_FILE
# below.
if [[ -f $PIA_RENEW_CONF ]]; then
  confPerms=$(stat -L -c '%a' "$PIA_RENEW_CONF")
  if [[ $confPerms != "600" && $confPerms != "400" ]]; then
    echo -e "${red}Warning: $PIA_RENEW_CONF is readable by non-root users (mode $confPerms)."
    echo -e "Run: chmod 600 $PIA_RENEW_CONF${nc}"
  fi
  set -a
  # shellcheck source=/dev/null
  source "$PIA_RENEW_CONF"
  set +a
fi

# If WG_SERVER_IP/WG_HOSTNAME weren't set via env or the conf file above,
# fall back to the server get_region.sh/run_setup.sh last connected to
# WireGuard with, recorded in $PIA_WG_SERVER_FILE (line 1 = IP, line 2 =
# hostname). An explicit env var or conf-file value always wins per-field.
if [[ -f $PIA_WG_SERVER_FILE ]]; then
  : "${WG_SERVER_IP:=$(awk 'NR == 1' "$PIA_WG_SERVER_FILE")}"
  : "${WG_HOSTNAME:=$(awk 'NR == 2' "$PIA_WG_SERVER_FILE")}"
fi

# Credentials come from a dedicated 2-line file (line 1 = PIA username,
# line 2 = password -- same raw, unlabeled format OpenVPN's own
# auth-user-pass files use), not from the conf file above, and not unless
# PIA_USER/PIA_PASS aren't already set via env.
if [[ -z $PIA_USER || -z $PIA_PASS ]] && [[ -f $PIA_RENEW_CREDENTIALS_FILE ]]; then
  credPerms=$(stat -L -c '%a' "$PIA_RENEW_CREDENTIALS_FILE")
  if [[ $credPerms != "600" && $credPerms != "400" ]]; then
    echo -e "${red}Warning: $PIA_RENEW_CREDENTIALS_FILE is readable by non-root users (mode $credPerms)."
    echo -e "It contains your PIA password. Run: chmod 600 $PIA_RENEW_CREDENTIALS_FILE${nc}"
  fi
  : "${PIA_USER:=$(awk 'NR == 1' "$PIA_RENEW_CREDENTIALS_FILE")}"
  : "${PIA_PASS:=$(awk 'NR == 2' "$PIA_RENEW_CREDENTIALS_FILE")}"
fi

if [[ -z $PIA_USER || -z $PIA_PASS || -z $WG_SERVER_IP || -z $WG_HOSTNAME ]]; then
  echo "This script requires 4 values, resolved from env vars and/or files:"
  echo "PIA_USER/PIA_PASS - your PIA username/password, from env vars or"
  echo "  line 1/line 2 of \$PIA_RENEW_CREDENTIALS_FILE"
  echo "  (default /opt/piavpn-manual/renew_wireguard_credentials)"
  echo "WG_SERVER_IP/WG_HOSTNAME - the server to reconnect to, from env vars,"
  echo "  \$PIA_RENEW_CONF, or the server get_region.sh/run_setup.sh last"
  echo "  connected to WireGuard with (\$PIA_WG_SERVER_FILE, default"
  echo "  /opt/piavpn-manual/wg_server -- written automatically on connect)"
  echo
  echo "Optional env vars: PIA_DNS, PIA_CONF_PATH, DIP_TOKEN,"
  echo "PIA_RENEW_INTERVAL_HOURS (default 20), PIA_RENEW_CHECK_INTERVAL_SECONDS (default 3600),"
  echo "PIA_RENEW_LOG_MODE (auto/quiet/verbose, default auto)."
  echo
  echo "Flags: --loop (run persistently instead of a single check),"
  echo "--quiet / --verbose (override the auto-detected log format)."
  exit 1
fi

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

# --- Argument / log-mode resolution --------------------------------------
# Priority: explicit flag > explicit env var > auto-detect via [[ -t 1 ]],
# the same tty-based convention already used above for color output. This
# means cron (stdout never a tty) gets the compact "quiet" format with no
# crontab change needed, while an interactive shell keeps today's full,
# unredirected output automatically.
loopMode=false
logMode=${PIA_RENEW_LOG_MODE:-auto}
for arg in "$@"; do
  case $arg in
    --loop) loopMode=true ;;
    --quiet) logMode=quiet ;;
    --verbose) logMode=verbose ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done
[[ $PIA_RENEW_LOOP == "true" ]] && loopMode=true
if [[ $logMode == "auto" ]]; then
  if [[ -t 1 ]]; then
    logMode=verbose
  else
    logMode=quiet
  fi
fi

tsPrefix() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
redactToken() { sed -E 's/PIA_TOKEN=[^[:space:]"]+/PIA_TOKEN=[REDACTED]/g'; }

# Verifies the "pia" interface is actually up and has handshaked recently,
# independent of connect_to_wireguard_with_token.sh's exit code (known to
# exit 1 on a benign condition -- PIA_PF unset/false -- even after a fully
# successful `wg-quick up pia`; see connect_to_wireguard_with_token.sh's own
# "If you want to also enable port forwarding..." branch). A handshake
# recency threshold guards against a stale, pre-existing "pia" interface
# being misread as evidence of THIS renewal's success.
# Returns: 0 = verified up, 1 = verified down/stale, 2 = unknown (no `wg`).
verifyWireguardUp() {
  local maxAge=${1:-120} handshake age

  command -v wg >/dev/null || return 2
  wg show pia >/dev/null 2>&1 || return 1

  handshake=$(wg show pia latest-handshakes 2>/dev/null | awk '{print $2}')
  [[ $handshake =~ ^[0-9]+$ ]] || handshake=0
  (( handshake == 0 )) && return 1

  age=$(( $(date +%s) - handshake ))
  (( age >= 0 && age <= maxAge ))
}

# Checks the self-maintained renewal timer and, if due, mints a fresh token
# and reconnects to the same server. Never trusts a subprocess's exit code
# alone: get_token.sh can return 0 even on an authentication failure (its own
# auth-failure path ends in a bare `exit`, which preserves the prior
# command's success status), so success there is only recognized once a
# non-empty token has actually been read back. connect_to_wireguard_with_token.sh
# can return 1 even after a fully successful connect (see verifyWireguardUp
# above), so success there is determined by directly checking the interface,
# not by its exit code.
renewIfDue() {
  local now lastRenewal renewIntervalSeconds

  now=$(date +%s)
  renewIntervalSeconds=$(( PIA_RENEW_INTERVAL_HOURS * 3600 ))

  lastRenewal=0
  if [[ -f $PIA_RENEW_STATE_FILE ]]; then
    lastRenewal=$(cat "$PIA_RENEW_STATE_FILE")
  fi
  [[ $lastRenewal =~ ^[0-9]+$ ]] || lastRenewal=0

  if (( now - lastRenewal < renewIntervalSeconds )); then
    local nextDue=$(( lastRenewal + renewIntervalSeconds ))
    if [[ $logMode == "quiet" ]]; then
      echo "$(tsPrefix) renew_wireguard: not due until $(date -u -d "@$nextDue" +"%Y-%m-%dT%H:%M:%SZ")."
    else
      echo "$(tsPrefix) Last renewed $(date -d "@$lastRenewal"). Not due until $(date -d "@$nextDue")."
    fi
    return 0
  fi

  if [[ $logMode != "quiet" ]]; then
    echo "$(tsPrefix) Renewal is due. Requesting a fresh token..."
  fi

  rm -f /opt/piavpn-manual/token

  local getTokenOutput="" getTokenRc
  if [[ $logMode == "quiet" ]]; then
    getTokenOutput=$(PIA_USER=$PIA_USER PIA_PASS=$PIA_PASS ./get_token.sh 2>&1)
    getTokenRc=$?
  else
    PIA_USER=$PIA_USER PIA_PASS=$PIA_PASS ./get_token.sh
    getTokenRc=$?
  fi

  if (( getTokenRc != 0 )); then
    if [[ $logMode == "quiet" ]]; then
      echo "$(tsPrefix) renew_wireguard: FAILED at get_token.sh (exit $getTokenRc). Will retry on the next check."
      [[ -n $getTokenOutput ]] && echo "$getTokenOutput" | redactToken | sed 's/^/  /'
    else
      echo -e "${red}get_token.sh exited with an error. Will retry on the next check.${nc}"
    fi
    return 1
  fi

  if [[ ! -s /opt/piavpn-manual/token ]]; then
    if [[ $logMode == "quiet" ]]; then
      echo "$(tsPrefix) renew_wireguard: FAILED at get_token.sh (no token file produced -- check PIA_USER/PIA_PASS). Will retry on the next check."
      [[ -n $getTokenOutput ]] && echo "$getTokenOutput" | redactToken | sed 's/^/  /'
    else
      echo -e "${red}get_token.sh did not produce a token file. Check your PIA_USER/PIA_PASS. Will retry on the next check.${nc}"
    fi
    return 1
  fi

  local freshToken
  freshToken=$(awk 'NR == 1' /opt/piavpn-manual/token)
  if [[ -z $freshToken ]]; then
    if [[ $logMode == "quiet" ]]; then
      echo "$(tsPrefix) renew_wireguard: FAILED (could not authenticate with the configured PIA_USER/PIA_PASS). Will retry on the next check."
    else
      echo -e "${red}Could not authenticate with the configured PIA_USER/PIA_PASS. Will retry on the next check.${nc}"
    fi
    return 1
  fi
  rm -f /opt/piavpn-manual/token

  if [[ $logMode != "quiet" ]]; then
    echo "$(tsPrefix) Got a fresh token. Reconnecting to $WG_HOSTNAME ($WG_SERVER_IP)..."
  fi

  if [[ $PIA_PF == "true" ]]; then
    echo -e "${red}Warning: PIA_PF=true is set, but renew_wireguard.sh does not renew" \
      "port forwarding. Forcing PIA_PF=false for this reconnect -- restart" \
      "port_forwarding.sh yourself afterward if you need it.${nc}"
  fi

  local connectOutput="" connectRc
  if [[ $logMode == "quiet" ]]; then
    connectOutput=$(
      PIA_TOKEN=$freshToken \
        WG_SERVER_IP=$WG_SERVER_IP \
        WG_HOSTNAME=$WG_HOSTNAME \
        PIA_PF=false \
        PIA_DNS=${PIA_DNS:-false} \
        PIA_CONF_PATH=${PIA_CONF_PATH:-} \
        DIP_TOKEN=${DIP_TOKEN:-} \
        ./connect_to_wireguard_with_token.sh 2>&1
    )
    connectRc=$?
  else
    PIA_TOKEN=$freshToken \
      WG_SERVER_IP=$WG_SERVER_IP \
      WG_HOSTNAME=$WG_HOSTNAME \
      PIA_PF=false \
      PIA_DNS=${PIA_DNS:-false} \
      PIA_CONF_PATH=${PIA_CONF_PATH:-} \
      DIP_TOKEN=${DIP_TOKEN:-} \
      ./connect_to_wireguard_with_token.sh
    connectRc=$?
  fi

  verifyWireguardUp
  local verifyRc=$?

  if (( verifyRc == 0 )) || { (( verifyRc == 2 )) && (( connectRc == 0 )); }; then
    echo "$now" > "$PIA_RENEW_STATE_FILE"
    if [[ $logMode == "quiet" ]]; then
      echo "$(tsPrefix) renew_wireguard: renewed OK (connect exit $connectRc, verify $verifyRc)."
    else
      echo -e "$(tsPrefix) ${green}Renewed OK at $(date -d "@$now") (connect exit $connectRc, verify $verifyRc).${nc}"
    fi
    return 0
  fi

  if [[ $logMode == "quiet" ]]; then
    echo "$(tsPrefix) renew_wireguard: FAILED (connect exit $connectRc, verify $verifyRc -- tunnel not confirmed up). Will retry on the next check."
    [[ -n $connectOutput ]] && echo "$connectOutput" | redactToken | sed 's/^/  /'
  else
    echo -e "${red}connect_to_wireguard_with_token.sh exited $connectRc and the pia interface"
    echo -e "could not be verified up (verify exit $verifyRc). The tunnel may now be down."
    echo -e "Will retry on the next check.${nc}"
  fi
  return 1
}

if [[ $loopMode == "true" ]]; then
  echo "$(tsPrefix) Starting renew_wireguard.sh in loop mode (check interval: ${PIA_RENEW_CHECK_INTERVAL_SECONDS}s, log mode: $logMode)..."
  while true; do
    renewIfDue || true
    sleep "$PIA_RENEW_CHECK_INTERVAL_SECONDS"
  done
else
  renewIfDue
  exit $?
fi
