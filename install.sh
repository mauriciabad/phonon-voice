#!/bin/zsh
# Build Phonon Voice and install it into /Applications (or ~/Applications).
#
#   zsh -c "$(curl -fsSL https://raw.githubusercontent.com/mauriciabad/phonon-voice/main/install.sh)"
#
# or, from a clone of the repository (to customize voices.json):
#
#   ./install.sh
#
# Optional environment:
#   SIGN_IDENTITY     code-signing identity (default "-", ad hoc: no Apple developer account needed)
#   DEVELOPMENT_TEAM  team ID to sign with, together with SIGN_IDENTITY="Apple Development"
#   INSTALL_DIR       where to put the app (default /Applications, else ~/Applications)
set -euo pipefail

REPO_URL=https://github.com/mauriciabad/phonon-voice
PTTS_TAG=v0.4.1
MODEL_REPO=gradium/phonon-40m-multilingual
MODEL_REV=1537ce46c64f42903e0d608b132ccb073dac46d2
VOICES_REPO=gradium/phonon-voices
VOICES_REV=da6c9ec0d47be8df5c87c730a3aa97187f3229c3
LANGUAGES=(en es fr de pt)

step() { print -P "\n%B%F{blue}==>%f $*%b" }
fail() { print -P "\n%B%F{red}Error:%f%b $*" >&2; exit 1 }
ask()  { print -n -- "$* "; read -r </dev/tty || true }

step "Checking requirements"
[[ $(uname -m) == arm64 ]] || fail "Phonon Voice needs a Mac with Apple silicon."
(( ${$(sw_vers -productVersion)%%.*} >= 15 )) || fail "Phonon Voice needs macOS 15 or later."
xcodebuild -version >/dev/null 2>&1 \
  || fail "Xcode is required (the full app, not just the Command Line Tools). Install it from the App Store, open it once, then run this again."

path=($HOME/.cargo/bin /opt/homebrew/opt/rustup/bin /opt/homebrew/bin $path)
missing=()
(( $+commands[xcodegen] )) || missing+=(xcodegen)
(( $+commands[rustup] || $+commands[cargo] )) || missing+=(rustup)
(( $+commands[hf] || $+commands[uvx] )) || missing+=(uv)
if (( $#missing )); then
  (( $+commands[brew] )) || fail "Missing: $missing. Install Homebrew (https://brew.sh) and run this again, or install them yourself."
  echo "Installing with Homebrew: $missing"
  brew install --quiet $missing
  rehash
fi
if ! cargo --version >/dev/null 2>&1; then
  echo "Installing the Rust toolchain"
  rustup default stable
fi
echo "OK"

step "Getting Phonon Voice"
if [[ -f ${0:A:h}/project.yml ]]; then
  cd ${0:A:h}
else
  src=$HOME/Library/Caches/phonon-voice
  if [[ -d $src/.git ]]; then
    git -C $src pull -q --ff-only || fail "couldn't update $src; delete it and run this again"
  else
    git clone -q --depth 1 $REPO_URL $src || fail "couldn't download $REPO_URL"
  fi
  cd $src
fi
echo $PWD

step "Checking access to the Phonon model"
HF_HOME=${HF_HOME:-$HOME/.cache/huggingface}
hf() { if (( $+commands[hf] )); then command hf "$@"; else uvx -q --from huggingface_hub hf "$@"; fi }
load_token() {
  token=${HF_TOKEN:-}
  if [[ -z $token && -f $HF_HOME/token ]]; then token=$(<$HF_HOME/token); fi
}
# Prints the HTTP status of a gated file; runs in a subshell, so callers reload the token after.
access() {
  load_token
  local auth=()
  [[ -n $token ]] && auth=(-H "Authorization: Bearer $token")
  curl -s -o /dev/null -w '%{http_code}' $auth "https://huggingface.co/$MODEL_REPO/resolve/$MODEL_REV/config.json"
}
for attempt in 1 2 3; do
  case $(access) in
    200) break ;;
    401)
      echo "The model is free, but you need a Hugging Face account to download it."
      hf auth login </dev/tty || true ;;
    *)
      echo "Accept the model's terms on Hugging Face (one click, approved instantly)."
      open "https://huggingface.co/$MODEL_REPO"
      ask "Press Return once you've accepted them…" ;;
  esac
done
load_token
[[ $(access) == 200 ]] || fail "still can't download the model. Log in with \`hf auth login\` and accept the terms at https://huggingface.co/$MODEL_REPO, then run this again."
echo "OK"

step "Fetching the Phonon source ($PTTS_TAG)"
if [[ ! -d vendor/xn-ptts ]]; then
  git -c advice.detachedHead=false clone -q --depth 1 --branch $PTTS_TAG https://github.com/gradium-ai/xn-ptts vendor/xn-ptts 2>/dev/null \
    || fail "couldn't download the Phonon source from GitHub"
fi
echo "OK"

step "Downloading voices"
rm -rf vendor/voices && mkdir -p vendor/voices
for lang in $LANGUAGES; do
  name=$(plutil -extract $lang.name raw -o - voices.json 2>/dev/null) || continue
  id=$(plutil -extract $lang.id raw -o - voices.json 2>/dev/null || true)
  if [[ -n $id ]]; then
    curl -fsSL "https://huggingface.co/$VOICES_REPO/resolve/$VOICES_REV/voices/$id.safetensors" -o vendor/voices/$name.safetensors \
      || fail "couldn't download voice $name ($id)"
  else
    curl -fsSL -H "Authorization: Bearer $token" "https://huggingface.co/$MODEL_REPO/resolve/$MODEL_REV/default-voice.safetensors" \
      -o vendor/voices/$name.safetensors || fail "couldn't download the model's default voice"
  fi
  echo "$lang: $name"
done

step "Exporting the model for the Neural Engine"
stamp="$MODEL_REPO@$MODEL_REV $(cat vendor/voices/* | shasum -a 256 | cut -c1-16)"
if [[ -f vendor/Models/bundle.json && $(cat vendor/Models/.stamp 2>/dev/null) == $stamp ]]; then
  echo "Up to date"
else
  echo "This compiles the exporter first, which takes a few minutes the first time."
  rm -rf vendor/Models vendor/Models.partial
  (cd vendor/xn-ptts && HF_TOKEN=$token cargo run --quiet --release -p ptts --example export_coreml --features hub -- \
    --model "hf://$MODEL_REPO@$MODEL_REV" --voices ../voices ../Models.partial 2>&1 | { grep -v 'INFO' || true; })
  mv vendor/Models.partial vendor/Models
  echo $stamp > vendor/Models/.stamp
fi

step "Building the app"
xcodegen generate --quiet
mkdir -p build
sign=(CODE_SIGN_IDENTITY=${SIGN_IDENTITY:--})
[[ -n ${DEVELOPMENT_TEAM:-} ]] && sign+=(DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM)
if ! xcodebuild -project PhononVoice.xcodeproj -scheme PhononVoice -configuration Release \
    -derivedDataPath build -destination 'platform=macOS,arch=arm64' $sign build > build/build.log 2>&1; then
  grep 'error:' build/build.log | head -20 >&2
  fail "the build failed; the full log is in $PWD/build/build.log"
fi
echo "OK"

step "Installing"
dest=${INSTALL_DIR:-/Applications}
[[ -w $dest ]] || dest=$HOME/Applications
mkdir -p $dest
app="$dest/Phonon Voice.app"
pkill -x PhononVoice 2>/dev/null || true
pkill -x PhononVoiceExtension 2>/dev/null || true
rm -rf $app
ditto build/Build/Products/Release/PhononVoice.app $app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f $app
open -g $app
registered() { pluginkit -m -i com.mauriciabad.PhononVoiceExtension | grep -q PhononVoiceExtension }
for _ in {1..10}; do registered && break; sleep 1; done
registered || fail "macOS didn't register the voice. Open \"$app\" once and try again."
echo $app

step "Done"
cat <<EOF
One last step, in the System Settings window that just opened (Accessibility → Read & Speak):

  1. Set System voice to Phonon Voice → Phonon, under English (United States).
  2. Turn off "Detect languages", so Phonon picks the voice for each language itself.

Then select text in any app and press ⌥Esc.
EOF
open "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent"
