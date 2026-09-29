#!/bin/bash
# End-to-end build: native C++ (OpenSL ES) -> APK, using ONLY:
#   - the 5 jars Anthropic/you provided (android.jar, r8lib.jar, apktool jar,
#     uber-apk-signer jar) -- gradle-wrapper.jar is NOT used, see README.
#   - zig (pip) as the C/C++ cross-compiler, in place of a full Google NDK
#
# Usage: place the 4 jars in ./sdk/ (see paths below) and run this script
# from the project root.
set -euo pipefail

ANDROID_JAR="sdk/android.jar"
R8_JAR="sdk/r8lib.jar"
APKTOOL_JAR="sdk/apktool.jar"
SIGNER_JAR="sdk/uber-apk-signer.jar"
PKG_PATH="com/example/miclink"
OUT_APK="MicSpeakerBridge.apk"

echo "== 0. toolchain =="
command -v javac >/dev/null || { echo "Need a JDK (e.g. apt install openjdk-21-jdk-headless)"; exit 1; }
python3 -m ziglang version >/dev/null 2>&1 || pip3 install --break-system-packages ziglang
mkdir -p tools build classes dexout apk_build stage signed_out
[ -x tools/aapt2 ] || { unzip -o -q "$APKTOOL_JAR" prebuilt/linux/aapt2 -d /tmp/_apktool_x; cp /tmp/_apktool_x/prebuilt/linux/aapt2 tools/aapt2; chmod +x tools/aapt2; }

echo "== 1. fake link-time-only sysroot (see build_fake_sysroot.sh) =="
bash build_fake_sysroot.sh

echo "== 2. cross-compile native/*.cpp for every ABI =="
declare -A TRIPLES=( [arm64-v8a]=aarch64-linux-android [armeabi-v7a]=arm-linux-androideabi [x86_64]=x86_64-linux-android [x86]=x86-linux-android )
for abi in "${!TRIPLES[@]}"; do
  t=${TRIPLES[$abi]}
  LIBDIR=fake_sysroot/lib/$abi
  mkdir -p build/$abi
  python3 -m ziglang c++ -target $t -D__ANDROID_API__=21 -Wno-macro-redefined \
    -std=c++17 -O2 -fno-exceptions -fno-rtti -fno-threadsafe-statics -fvisibility=hidden \
    -Inative/include -nostdlib -shared -fPIC -Wl,-soname,libaudiobridge.so \
    -o build/$abi/libaudiobridge.so \
    native/src/audio_engine.cpp native/src/jni_bridge.cpp \
    $LIBDIR/libc.so $LIBDIR/libdl.so $LIBDIR/liblog.so
  echo "  built $abi: $(file -b build/$abi/libaudiobridge.so)"
done

echo "== 3. compile + dex Java =="
javac -source 8 -target 8 -classpath "$ANDROID_JAR" -d classes java/$PKG_PATH/MainActivity.java
java -cp "$R8_JAR" com.android.tools.r8.D8 --release --min-api 21 --output dexout \
  --lib "$ANDROID_JAR" classes/$PKG_PATH/MainActivity.class classes/$PKG_PATH/MainActivity\$1.class

echo "== 4. compile resources (icon) + manifest with aapt2 =="
tools/aapt2 compile --dir res -o apk_build/compiled_res.zip
tools/aapt2 link -I "$ANDROID_JAR" --manifest AndroidManifest.xml \
  --min-sdk-version 21 --target-sdk-version 21 -o apk_build/base.apk --auto-add-overlay \
  -R apk_build/compiled_res.zip

echo "== 5. assemble unsigned apk =="
cp apk_build/base.apk apk_build/app-unsigned.apk
rm -rf stage && mkdir -p stage/lib
for abi in "${!TRIPLES[@]}"; do
  mkdir -p stage/lib/$abi
  cp build/$abi/libaudiobridge.so stage/lib/$abi/
done
( cd dexout && zip -j -X ../apk_build/app-unsigned.apk classes.dex )
( cd stage && zip -r -X ../apk_build/app-unsigned.apk lib )

echo "== 6. sign + zipalign =="
java -jar "$SIGNER_JAR" -a apk_build/app-unsigned.apk --out signed_out --allowResign
cp signed_out/app-aligned-debugSigned.apk "$OUT_APK"

echo ""
echo "Done: $OUT_APK"
echo "Install on a connected device/emulator with: adb install -r $OUT_APK"
