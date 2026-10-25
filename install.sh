#!/bin/bash
# Build Phonon Voice and install it into /Applications (or ~/Applications).
#
#   ./install.sh
#
# Optional environment:
#   SIGN_IDENTITY     code-signing identity (default "-", ad-hoc: no Apple developer account needed)
#   DEVELOPMENT_TEAM  team ID to sign with, together with SIGN_IDENTITY="Apple Development"
#   INSTALL_DIR       where to put the app (default /Applications, else ~/Applications)
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$PWD

PTTS_TAG=v0.4.1
MODEL_REPO=gradium/phonon-40m-multilingual
MODEL_REV=1537ce46c64f42903e0d608b132ccb073dac46d2
VOICES_REPO=gradium/phonon-voices
VOICES_REV=da6c9ec0d47be8df5c87c730a3aa97187f3229c3
LANGUAGES="en es fr de pt"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
step() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

step "Checking requirements"
[[ $(uname -m) == arm64 ]] || fail "Phonon Voice needs a Mac with Apple silicon."
major=$(sw_vers -productVersion | cut -d. -f1)
(( major >= 15 )) || fail "Phonon Voice needs macOS 15 or later (this Mac has $(sw_vers -productVersion))."
xcodebuild -version >/dev/null 2>&1 || fail "Xcode is required (the full app, not just the Command Line Tools). Install it from the App Store, open it once, then run this again."
command -v xcodegen >/dev/null || fail "XcodeGen is required: brew install xcodegen"
for dir in "$HOME/.cargo/bin" /opt/homebrew/opt/rustup/bin; do [[ -d $dir ]] && PATH="$dir:$PATH"; done
command -v cargo >/dev/null || fail "Rust is required to export the model: brew install rustup && rustup default stable (or see https://rustup.rs)"

HF_HOME=${HF_HOME:-$HOME/.cache/huggingface}
token=${HF_TOKEN:-}
[[ -z $token && -f $HF_HOME/token ]] && token=$(<"$HF_HOME/token")
status=$(curl -s -o /dev/null -w '%{http_code}' ${token:+-H "Authorization: Bearer $token"} \
  "https://huggingface.co/$MODEL_REPO/resolve/$MODEL_REV/config.json")
if [[ $status != 200 ]]; then
  fail "Can't download the Phonon model (HTTP $status). It is free but gated:
  1. Sign in at https://huggingface.co and accept the terms at https://huggingface.co/$MODEL_REPO
  2. Create a Read token at https://huggingface.co/settings/tokens
  3. Log in on this Mac:  uvx --from huggingface_hub hf auth login   (or set HF_TOKEN)"
fi
echo "Xcode, XcodeGen, Rust and Hugging Face access: OK"

step "Fetching the Phonon source ($PTTS_TAG)"
if [[ ! -d vendor/xn-ptts ]]; then
  git -c advice.detachedHead=false clone -q --depth 1 --branch $PTTS_TAG https://github.com/gradium-ai/xn-ptts vendor/xn-ptts 2>/dev/null \
    || fail "couldn't download the Phonon source from GitHub"
fi
echo "vendor/xn-ptts"

step "Downloading voices"
rm -rf vendor/voices && mkdir -p vendor/voices
for lang in $LANGUAGES; do
  name=$(plutil -extract "$lang.name" raw -o - voices.json 2>/dev/null) || continue
  id=$(plutil -extract "$lang.id" raw -o - voices.json 2>/dev/null || true)
  if [[ -n $id ]]; then
    url="https://huggingface.co/$VOICES_REPO/resolve/$VOICES_REV/voices/$id.safetensors"
    curl -fsSL "$url" -o "vendor/voices/$name.safetensors" || fail "couldn't download voice $name ($id)"
  else
    curl -fsSL -H "Authorization: Bearer $token" \
      "https://huggingface.co/$MODEL_REPO/resolve/$MODEL_REV/default-voice.safetensors" -o "vendor/voices/$name.safetensors" \
      || fail "couldn't download the model's default voice"
  fi
  echo "$lang: $name"
done

step "Exporting the model for the Neural Engine"
stamp="$MODEL_REPO@$MODEL_REV $(shasum -a 256 vendor/voices/* | shasum -a 256 | cut -c1-16)"
if [[ -f vendor/Models/bundle.json && $(cat vendor/Models/.stamp 2>/dev/null) == "$stamp" ]]; then
  echo "Up to date"
else
  echo "This compiles the exporter first, which takes a few minutes the first time."
  rm -rf vendor/Models vendor/Models.partial
  (cd vendor/xn-ptts && HF_TOKEN=$token cargo run --quiet --release -p ptts --example export_coreml --features hub -- \
    --model "hf://$MODEL_REPO@$MODEL_REV" --voices ../voices ../Models.partial)
  mv vendor/Models.partial vendor/Models
  echo "$stamp" > vendor/Models/.stamp
  du -sh vendor/Models | cut -f1 | sed 's/^/Model bundle: /'
fi

step "Building the app"
xcodegen generate --quiet
mkdir -p build
sign=(CODE_SIGN_IDENTITY="${SIGN_IDENTITY:--}")
[[ -n ${DEVELOPMENT_TEAM:-} ]] && sign+=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM")
if ! xcodebuild -project PhononVoice.xcodeproj -scheme PhononVoice -configuration Release \
    -derivedDataPath build -destination 'platform=macOS,arch=arm64' "${sign[@]}" build > build/build.log 2>&1; then
  grep -E 'error:' build/build.log | head -20 >&2
  fail "the build failed; the full log is in build/build.log"
fi
APP=build/Build/Products/Release/PhononVoice.app
echo "Built $APP"

step "Installing"
dest=${INSTALL_DIR:-/Applications}
[[ -w $dest ]] || dest=$HOME/Applications
mkdir -p "$dest"
pkill -x PhononVoice 2>/dev/null || true
pkill -x PhononVoiceExtension 2>/dev/null || true
rm -rf "$dest/Phonon Voice.app"
ditto "$APP" "$dest/Phonon Voice.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$dest/Phonon Voice.app"
open -g "$dest/Phonon Voice.app"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pluginkit -m -i com.mauriciabad.PhononVoiceExtension | grep -q PhononVoiceExtension && break
  sleep 1
done
pluginkit -m -i com.mauriciabad.PhononVoiceExtension | grep -q PhononVoiceExtension \
  || fail "macOS didn't register the voice. Open \"$dest/Phonon Voice.app\" once and try again."
echo "Installed $dest/Phonon Voice.app"

step "Done"
cat <<EOF
Phonon is installed as a system voice. To use it for Speak Selection (⌥Esc):

  1. Open System Settings → Accessibility → Read & Speak
     (called "Spoken Content" before macOS 27).
  2. Set System voice to Phonon Voice → Phonon, under English (United States).
  3. Turn off "Detect languages", so Phonon picks the voice for each language itself.

Then select text in any app and press ⌥Esc.
EOF
