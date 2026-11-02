#!/bin/bash
# Runs a shell command inside the logged-in GUI session (as a one-shot launchd job) and relays its
# output and exit code. Over SSH the login keychain is locked per security session, so codesign and
# notarytool fail there with errSecInternalComponent; in the GUI session it is already unlocked.
set -uo pipefail
label=com.aist.gui-run.$$
log=$(mktemp /tmp/aist-gui-run.XXXXXX)
script=$(mktemp /tmp/aist-gui-run.XXXXXX)
printf 'cd %q\n%s\n' "$PWD" "$1" > "$script"
cat > /tmp/$label.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array>
  <string>/bin/sh</string><string>-c</string>
  <string>/bin/bash $script &gt;$log 2&gt;&amp;1; echo "exit=\$?" &gt;&gt;$log</string>
</array>
<key>RunAtLoad</key><true/>
</dict></plist>
EOF
launchctl bootstrap "gui/$(id -u)" /tmp/$label.plist
# Notarization can take minutes.
for _ in $(seq 1 1800); do grep -q '^exit=' "$log" 2>/dev/null && break; /bin/sleep 0.5; done
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
rm -f /tmp/$label.plist "$script"
grep -v '^exit=' "$log"
code=$(sed -n 's/^exit=//p' "$log"); rm -f "$log"
exit "${code:-1}"
