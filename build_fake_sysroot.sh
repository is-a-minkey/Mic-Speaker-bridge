#!/bin/bash
# Builds tiny link-time-only stub .so's (libc.so/libdl.so/liblog.so) per Android ABI.
# These are NEVER shipped in the APK and NEVER executed - purely to give the linker
# a symbol table + SONAME to resolve against, exactly like the real NDK's own stub
# libraries do. At runtime the app process gets the OS's real libc.so/libdl.so/liblog.so.
set -e
cd /home/claude/project
declare -A TRIPLES=( [arm64-v8a]=aarch64-linux-android [armeabi-v7a]=arm-linux-androideabi [x86_64]=x86_64-linux-android [x86]=x86-linux-android )
for abi in "${!TRIPLES[@]}"; do
  t=${TRIPLES[$abi]}
  outdir=fake_sysroot/lib/$abi
  mkdir -p "$outdir"
  for lib in libc libdl liblog; do
    python3 -m ziglang cc -target $t -D__ANDROID_API__=21 -nostdlib -shared -fPIC \
      -Wl,-soname,$lib.so -o "$outdir/$lib.so" fake_sysroot/src/${lib}_stub.c 2>&1 | grep -v "macro redefined\|previous definition\|warning generated\|command line" || true
  done
done
echo "done"
