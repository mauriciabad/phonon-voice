#!/bin/bash
# Remove Phonon Voice and the models it installed. System Settings falls back to an Apple voice.
set -uo pipefail

pkill -x PhononVoice 2>/dev/null
pkill -x PhononVoiceExtension 2>/dev/null
for dir in /Applications "$HOME/Applications"; do
  if [[ -d "$dir/Phonon Voice.app" ]]; then
    rm -rf "$dir/Phonon Voice.app" && echo "Removed $dir/Phonon Voice.app"
  fi
done
# The compiled models live in the extension's sandbox container.
for c in "$HOME/Library/Containers/com.mauriciabad.PhononVoiceExtension" "$HOME/Library/Containers/com.mauriciabad.PhononVoice"; do
  [[ -d $c ]] && rm -rf "$c" 2>/dev/null && echo "Removed $c"
done
echo "Done. If Phonon was your System voice, pick another one in System Settings → Accessibility → Read & Speak."
