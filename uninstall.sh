#!/bin/zsh
# Remove Phonon Voice, the models it installed and the cached build.
#
#   zsh -c "$(curl -fsSL https://raw.githubusercontent.com/mauriciabad/phonon-voice/main/uninstall.sh)"

pkill -x PhononVoice 2>/dev/null
pkill -x PhononVoiceExtension 2>/dev/null
for item in "/Applications/Phonon Voice.app" "$HOME/Applications/Phonon Voice.app" \
    $HOME/Library/Containers/com.mauriciabad.PhononVoiceExtension $HOME/Library/Containers/com.mauriciabad.PhononVoice \
    $HOME/Library/Caches/phonon-voice; do
  [[ -e $item ]] && rm -rf $item 2>/dev/null && echo "Removed $item"
done
echo "Done. If Phonon was your System voice, pick another one in System Settings → Accessibility → Read & Speak."
