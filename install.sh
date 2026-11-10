#!/bin/bash
# Installs the lidwake CLI, its sudoers rule, a login-time safety LaunchAgent,
# and — if Xcode command line tools are present — the remote control server
# (lidwaked + web UI) and the LidWake menu bar app.
#   RELAY_URL=https://x.onrender.com bash install.sh   permanent, end-to-end encrypted link via your relay
#   PUBLIC=tailscale bash install.sh  stable https://<mac>.ts.net address via Tailscale Funnel
#   PUBLIC=cloudflare bash install.sh quick tunnel (no account; address changes on restart)
#   PUBLIC=off bash install.sh        web page on the local network only
#   REMOTE=0 bash install.sh          skips the remote control server
# Default: the relay if RELAY_URL (or DEFAULT_RELAY_URL in ./lidwake) is set, else Cloudflare.
set -euo pipefail
cd "$(dirname "$0")"

USER_NAME=$(id -un)
UID_NUM=$(id -u)
BIN=/usr/local/bin
SHARE=/usr/local/share/lidwake
AGENTS="$HOME/Library/LaunchAgents"
APP="$HOME/Applications/LidWake.app"
STATE="$HOME/Library/Application Support/LidWake"
TARGET="$(uname -m)-apple-macos13.0"

load_agent() {  # load_agent LABEL PROGRAM ARGS... — (re)install a LaunchAgent
  local label=$1 plist="$AGENTS/$1.plist" keepalive=$2 args=""
  shift 2
  for a in "$@"; do args="$args<string>$a</string>"; done
  cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array>$args</array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><$keepalive/>
  <key>StandardErrorPath</key><string>$STATE/$label.log</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$UID_NUM" "$plist" 2>/dev/null || true
  launchctl bootstrap "gui/$UID_NUM" "$plist"
}

install_cloudflared() {  # for the zero-setup public tunnel
  local arch tmpd
  for c in cloudflared /opt/homebrew/bin/cloudflared /usr/local/bin/cloudflared; do
    command -v "$c" >/dev/null 2>&1 && return 0
  done
  echo "→ Installing cloudflared (Cloudflare's tunnel client)"
  if command -v brew >/dev/null 2>&1; then
    brew install cloudflared
  else
    arch=$(uname -m); [ "$arch" = x86_64 ] && arch=amd64
    tmpd=$(mktemp -d)
    curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-$arch.tgz" \
      | tar -xz -C "$tmpd" && sudo install -m 755 "$tmpd/cloudflared" "$BIN/cloudflared"
    local ok=$?
    rm -rf "$tmpd"
    return $ok
  fi
}

mkdir -p "$AGENTS" "$STATE"

echo "→ Installing CLI to $BIN/lidwake (you may be asked for your password)"
sudo mkdir -p "$BIN" "$SHARE"
sudo install -m 755 lidwake "$BIN/lidwake"

echo "→ Allowing $USER_NAME to toggle clamshell sleep without a password"
tmp=$(mktemp)
cat >"$tmp" <<EOF
# Installed by LidWake. Only these exact commands are allowed.
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1, /sbin/shutdown -h now
EOF
sudo visudo -cf "$tmp" >/dev/null
sudo install -m 440 -o root -g wheel "$tmp" /etc/sudoers.d/lidwake
rm -f "$tmp"

echo "→ Installing login safety check (re-enables sleep if a session died)"
load_agent com.lidwake.recover false "$BIN/lidwake" recover

if ! command -v swiftc >/dev/null 2>&1; then
  echo "! swiftc not found — skipped the remote server and menu bar app."
  echo "  Run 'xcode-select --install' and re-run this script to get them. The CLI works without them."
else
  if [ "${REMOTE:-1}" != 0 ]; then
    echo "→ Building remote control server (lidwaked)"
    swiftc -O -target "$TARGET" -o lidwaked.build remote/main.swift
    sudo install -m 755 lidwaked.build "$BIN/lidwaked"
    rm -f lidwaked.build
    sudo install -m 644 remote/index.html "$SHARE/index.html"
    "$BIN/lidwake" remote --url >/dev/null   # creates the access token
    load_agent com.lidwake.remote true "$BIN/lidwaked"

    relay_url=${RELAY_URL:-$(sed -n 's/^DEFAULT_RELAY_URL="\(.*\)"$/\1/p' lidwake)}
    if [ -n "${PUBLIC:-}" ]; then public_mode=$PUBLIC
    elif [ -n "$relay_url" ]; then public_mode=relay
    else public_mode=cloudflare
    fi
    if [ "$public_mode" = cloudflare ] && ! install_cloudflared; then
      echo "! couldn't install cloudflared — internet access stays off (LAN still works)"
      public_mode=off
    fi
    echo "→ Internet access: $public_mode"
    "$BIN/lidwake" remote --public "$public_mode" ${relay_url:+"$relay_url"} >/dev/null \
      || echo "! couldn't enable '$public_mode' — retry later with: lidwake remote --public $public_mode $relay_url"
  fi

  echo "→ Building menu bar app to $APP"
  pkill -x LidWake 2>/dev/null || true
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS"
  swiftc -O -parse-as-library -target "$TARGET" -o "$APP/Contents/MacOS/LidWake" app/LidWake.swift
  cp app/Info.plist "$APP/Contents/Info.plist"
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
  open "$APP"
  echo "   LidWake is in your menu bar (cup icon). Add it to Login Items if you like."
fi

echo
echo "Done. Try:  lidwake start --for 30m -b   then close the lid."
echo "Claude Code:  lidwake claude-hook --install"
[ -x "$BIN/lidwaked" ] && { echo; "$BIN/lidwake" remote; }
true
