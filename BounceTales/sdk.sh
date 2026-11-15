#!/usr/bin/env bash
set -euo pipefail

URL="https://archive.org/download/nokia_sdks_n_dev_tools2/Series_40_5th_Edition_SDK_Feature_Pack_1_1_0.zip"
SHA256="1318ec9f3f1a8c837b8f9661166aa8b14ce79d833c597a277b39e2dbc0305b5d"
SIZE=50704554

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="$ROOT/sdk"
ZIP_NAME="Series_40_5th_Edition_SDK_Feature_Pack_1_1_0.zip"
ZIP="$WORKDIR/$ZIP_NAME"
PARTIAL="$ZIP.partial"
DEST="$WORKDIR/extracted"
PARTS="$WORKDIR/parts"
UNSHIELD_DIR="$WORKDIR/unshield"
LIBDIR="$ROOT/lib/s40"
EXE_NAME="S40_5th_Edition_SDK_Feature_Pack_1_installer_em.exe"

# Fixed for this zip SHA-256
DATA1_CAB_OFF=450603
DATA1_CAB_SIZE=14384234
DATA1_HDR_OFF=14834878
DATA1_HDR_SIZE=186111
DATA2_CAB_OFF=15021032
DATA2_CAB_SIZE=34436443

EXPECTED_NAMES=(
  "InstallationGuide.zip"
  "S40_5th_Edition_SDK_Feature_Pack_1_Release_Notes.txt"
  "S40_5th_Edition_SDK_Feature_Pack_1_installer_em.exe"
)
EXPECTED_SIZES=(
  672134
  7565
  51193119
)

MIDP_SHA256="bd5e421308448a939cc23134873882ad61577c94d77c313498f7ce7ea9011d50"
NOKIAUI_SHA256="93b3182c58307d3fcddb82bd4d80c884ffb584340f2318596988cb9a897fcb14"

fail() {
  echo "Error: $*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

use_bsdtar() {
  tar --version 2>&1 | grep -qi bsdtar
}

list_archive() {
  local zip="$1"
  if have unzip; then
    unzip -Z1 "$zip"
  elif use_bsdtar; then
    tar -tf "$zip"
  else
    fail "Cannot list the zip. Install unzip"
  fi
}

extract_archive() {
  local zip="$1"
  local dest="$2"
  if have unzip; then
    unzip -q -o "$zip" -d "$dest"
  elif use_bsdtar; then
    tar -xf "$zip" -C "$dest"
  else
    fail "Cannot extract the zip. Install unzip"
  fi
}

file_size() {
  local path="$1"
  local size
  size="$(wc -c < "$path")"
  echo "$((size))"
}

sha256_file() {
  sha256sum -b "$1" | awk '{print $1}'
}

carve() {
  local offset="$1"
  local size="$2"
  local dest="$3"
  dd if="$EXE" of="$dest" bs=1048576 iflag=skip_bytes,count_bytes skip="$offset" count="$size" status=none
  local got sig
  got="$(file_size "$dest")"
  if [[ "$got" -ne "$size" ]]; then
    fail "Carve of $(basename "$dest") produced $got bytes, expected $size"
  fi
  sig="$(od -An -N 4 -t x1 "$dest" | tr -d '[:space:]')"
  if [[ "$sig" != "49536328" ]]; then
    fail "Carve of $(basename "$dest") is not an InstallShield cabinet (ISc()"
  fi
}

require_jar_bytes() {
  local path="$1"
  local class_name="$2"
  if have jar; then
    jar tf "$path" | grep -Fxq "$class_name"
  elif have unzip; then
    unzip -l "$path" | awk '{print $4}' | grep -Fxq "$class_name"
  else
    fail "Need jar or unzip to check $class_name inside $(basename "$path")"
  fi
}

if ! have curl; then
  fail "curl is required"
fi
if ! have sha256sum; then
  fail "sha256sum is required"
fi
if ! have unshield; then
  fail "unshield is required"
fi
if ! have dd || ! have od; then
  fail "dd and od are required"
fi

mkdir -p "$WORKDIR"

if [[ -f "$ZIP" ]] && [[ "$(file_size "$ZIP")" -eq "$SIZE" ]] && [[ "$(sha256_file "$ZIP")" == "$SHA256" ]]; then
  echo "Using existing $ZIP"
  echo "Checking size and SHA-256"
else
  echo "Fetching $URL"
  if ! curl -fL --retry 3 --retry-delay 2 -A "Mozilla/5.0" -o "$PARTIAL" "$URL"; then
    rm -f "$PARTIAL"
    fail "Download failed"
  fi

  echo "Checking size and SHA-256"
  got_size="$(file_size "$PARTIAL")"
  if [[ "$got_size" -ne "$SIZE" ]]; then
    rm -f "$PARTIAL"
    fail "Size mismatch: expected $SIZE bytes, got $got_size"
  fi

  got_sha="$(sha256_file "$PARTIAL")"
  if [[ "$got_sha" != "$SHA256" ]]; then
    rm -f "$PARTIAL"
    fail "SHA-256 mismatch: expected $SHA256, got $got_sha"
  fi
  mv -f "$PARTIAL" "$ZIP"
fi

echo "Listing archive members"
if ! names="$(list_archive "$ZIP")"; then
  fail "Could not list archive members"
fi
names="${names//$'\r'/}"
if [[ -z "$names" ]]; then
  fail "Archive member list is empty"
fi

printf '%s\n' "$names"

expected="$(printf '%s\n' "${EXPECTED_NAMES[@]}")"
if [[ "$names" != "$expected" ]]; then
  fail "Archive member list does not match the Series 40 SDK zip"
fi

echo "Extracting into $DEST"
rm -rf "$DEST"
mkdir -p "$DEST"
if ! extract_archive "$ZIP" "$DEST"; then
  fail "Extract failed"
fi

echo "Checking extracted files"
i=0
for name in "${EXPECTED_NAMES[@]}"; do
  path="$DEST/$name"
  if [[ ! -f "$path" ]]; then
    fail "Missing extracted file: $name"
  fi
  got="$(file_size "$path")"
  want="${EXPECTED_SIZES[$i]}"
  if [[ "$got" -ne "$want" ]]; then
    fail "Size mismatch for $name: expected $want bytes, got $got"
  fi
  i=$((i + 1))
done

EXE="$DEST/$EXE_NAME"
echo "Carving InstallShield cabinets from $EXE_NAME"
rm -rf "$PARTS"
mkdir -p "$PARTS"
carve "$DATA1_CAB_OFF" "$DATA1_CAB_SIZE" "$PARTS/data1.cab"
carve "$DATA1_HDR_OFF" "$DATA1_HDR_SIZE" "$PARTS/data1.hdr"
carve "$DATA2_CAB_OFF" "$DATA2_CAB_SIZE" "$PARTS/data2.cab"

echo "Extracting cabinets with unshield"
rm -rf "$UNSHIELD_DIR"
mkdir -p "$UNSHIELD_DIR"
if ! unshield -d "$UNSHIELD_DIR" x "$PARTS/data1.cab"; then
  fail "unshield failed"
fi

mkdir -p "$LIBDIR"
for spec in "midp20.jar:$MIDP_SHA256" "nokiaui.jar:$NOKIAUI_SHA256"; do
  base="${spec%%:*}"
  want="${spec#*:}"
  found="$(find "$UNSHIELD_DIR" -type f -name "$base" -print -quit)"
  if [[ -z "$found" ]]; then
    fail "unshield did not produce $base"
  fi
  cp -f "$found" "$LIBDIR/$base"
  got="$(sha256_file "$LIBDIR/$base")"
  if [[ "$got" != "$want" ]]; then
    fail "SHA-256 mismatch for $base: expected $want, got $got"
  fi
done

require_jar_bytes "$LIBDIR/midp20.jar" "javax/microedition/midlet/MIDlet.class"
require_jar_bytes "$LIBDIR/nokiaui.jar" "com/nokia/mid/ui/DirectUtils.class"
require_jar_bytes "$LIBDIR/nokiaui.jar" "com/nokia/mid/ui/DeviceControl.class"
if require_jar_bytes "$LIBDIR/midp20.jar" "java/lang/Object.class"; then
  fail "midp20.jar contains java.lang.Object and cannot be used as a referenced library"
fi

echo "OK: $LIBDIR/midp20.jar"
echo "OK: $LIBDIR/nokiaui.jar"
