#!/bin/sh
# Window 9: makes MLX (mlx-swift, Qwen) buildable when `xcodebuild -downloadComponent MetalToolchain`
# does not complete (it stalled at 118 MB on the development Mac).
#
# What it does (no root needed):
#   1. downloads Apple's own Metal toolchain asset (the file `xcodebuild -downloadComponent` would fetch)
#      from Apple's CDN with curl (resumable), using the URL and key from the local asset catalog;
#   2. decrypts and unpacks it (aea / pbzx / aa), mounts the contained disk image read-only, and
#      copies `Metal.xctoolchain` to ~/Library/Developer/Toolchains;
#   3. composes `HSMetalSwift.xctoolchain`: Xcode's own Swift tools (symlinks) plus the real Metal compiler.
#
# Xcode's `metal` is only a stub that needs the system-managed toolchain; builds that use
#   xcodebuild ... -toolchain org.hearingsense.toolchain.metalswift
# find the real compiler through TOOLCHAIN_DIR. Where `xcodebuild -downloadComponent MetalToolchain`
# works, none of this is needed and no `-toolchain` flag is needed.
#
#   tools/setup_metal_toolchain.sh <work dir>
set -eu
work="${1:?work directory (about 5 GB while unpacking)}"
mkdir -p "$work"
catalog=/System/Library/AssetsV2/com_apple_MobileAsset_MetalToolchain/com_apple_MobileAsset_MetalToolchain.xml
[ -f "$catalog" ] || { echo "run 'xcodebuild -downloadComponent MetalToolchain' once so the catalog exists"; exit 1; }
eval "$(python3 -I - "$catalog" <<'E'
import plistlib, sys
a = plistlib.load(open(sys.argv[1], 'rb'))['Assets'][0]
print('url="%s%s"' % (a['__BaseURL'], a['__RelativePath']))
print('key="%s"' % a['ArchiveDecryptionKey'])
print('size=%d' % a['_DownloadSize'])
E
)"
if [ "$(stat -f %z "$work/metal.aar" 2>/dev/null || echo 0)" != "$size" ]; then
  curl -L -C - --retry 5 --retry-delay 5 -o "$work/metal.aar" "$url"
fi
aea decrypt -i "$work/metal.aar" -o "$work/metal.aa" -key-value "base64:$key"
python3 -I - "$work/metal.aa" "$work/payload.aa" <<'E'
import lzma, struct, sys
d = open(sys.argv[1], 'rb').read()
pos = d.index(b'pbzx') + 4
pos += 8
out = open(sys.argv[2], 'wb')
while pos + 16 <= len(d):
    flags, length = struct.unpack('>QQ', d[pos:pos + 16]); pos += 16
    if length > len(d) - pos: break
    chunk = d[pos:pos + length]; pos += length
    out.write(lzma.decompress(chunk) if chunk[:6] == b'\xfd7zXZ\x00' else chunk)
E
mkdir -p "$work/out" "$work/mnt"
aa extract -i "$work/payload.aa" -d "$work/out" 2>/dev/null || true   # the trailing bytes of the stream are not an entry
dmg="$(find "$work/out" -name '*.dmg' | head -1)"
hdiutil attach -readonly -nobrowse -noverify -mountpoint "$work/mnt" "$dmg" >/dev/null
tools="$HOME/Library/Developer/Toolchains"
mkdir -p "$tools"
rm -rf "$tools/Metal.xctoolchain" "$tools/HSMetalSwift.xctoolchain"
cp -R "$work/mnt/Metal.xctoolchain" "$tools/Metal.xctoolchain"
hdiutil detach "$work/mnt" >/dev/null
xd=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain
t="$tools/HSMetalSwift.xctoolchain"
mkdir -p "$t/usr/bin"
cp "$xd/ToolchainInfo.plist" "$t/ToolchainInfo.plist"
plutil -replace Identifier -string org.hearingsense.toolchain.metalswift "$t/ToolchainInfo.plist"
for d in lib libexec share include; do ln -s "$xd/usr/$d" "$t/usr/$d"; done
for f in "$xd"/usr/bin/*; do ln -s "$f" "$t/usr/bin/$(basename "$f")"; done
for f in "$tools"/Metal.xctoolchain/usr/bin/*; do ln -sf "$f" "$t/usr/bin/$(basename "$f")"; done
ln -s "$tools/Metal.xctoolchain/usr/metal" "$t/usr/metal"
cat > "$t/Info.plist" <<'E'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.hearingsense.toolchain.metalswift</string>
<key>CFBundleName</key><string>HSMetalSwift</string>
</dict></plist>
E
echo "ready: xcodebuild ... -toolchain org.hearingsense.toolchain.metalswift"
