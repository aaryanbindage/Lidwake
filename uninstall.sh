#!/bin/bash
# Removes everything install.sh added and makes sure normal sleep is back.
set -u

if [ -x /usr/local/bin/lidwake ]; then
  /usr/local/bin/lidwake stop
  /usr/local/bin/lidwake remote --public off >/dev/null 2>&1   # also turns off Tailscale Funnel
fi
pkill -x LidWake 2>/dev/null
sudo pmset -a disablesleep 0

for label in com.lidwake.recover com.lidwake.remote; do
  launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/$label.plist" 2>/dev/null
  rm -f "$HOME/Library/LaunchAgents/$label.plist"
done
rm -rf "$HOME/Applications/LidWake.app" "$HOME/Library/Application Support/LidWake"
sudo rm -rf /usr/local/bin/lidwake /usr/local/bin/lidwaked /usr/local/share/lidwake /etc/sudoers.d/lidwake

echo "LidWake removed. If you installed the Claude Code Stop hook, delete it from ~/.claude/settings.json"
echo "(a backup from before it was added is at ~/.claude/settings.json.lidwake-backup)."
