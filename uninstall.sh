#!/bin/bash
# Removal failures retain recovery and are reported to the caller.
set -euo pipefail
CANONICAL="/Library/PrivilegedHelperTools/com.thermalforge/thermalforge"
if [ -x "$CANONICAL" ]; then
  sudo "$CANONICAL" uninstall
else
  sudo /usr/local/bin/thermalforge uninstall
fi
