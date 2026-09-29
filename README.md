# Mic → Speaker Bridge (OpenSL ES, API 21, no Android Studio/NDK download required)

A minimal native Android app that captures microphone audio and plays it
back out the speaker/headphones with as little added latency as the
OpenSL ES low-latency path allows, targeting Android 5.0 (API 21).

## How it's built

Everything is built from the command line with the 5 jars you uploaded,
plus [Zig](https://ziglang.org) (via `pip install ziglang`) standing in for
the native C/C++ compiler:

| Piece | Source | Used for |
|---|---|---|
| `android.jar` | uploaded (API 34) | Java compile classpath **and** aapt2's framework resource link |
| `apktool_3_0_2.jar` | uploaded | its bundled Linux **aapt2** binary is extracted and used directly |
| `r8lib.jar` | uploaded | `D8` dexer (Java `.class` → `classes.dex`) |
| `uber-apk-signer-*.jar` | uploaded | zipalign + v1/v2/v3 signing (auto-generated debug key) |
| `ziglang` (PyPI) | `pip install` | C/C++ **cross-compiler** for `aarch64/arm/x86/x86_64-linux-android` |
| `gradle-wrapper.jar` | *(uploaded, unused)* | see "Why not Gradle" below |

Run `./build.sh` to reproduce the whole pipeline end to end (it expects the
4 jars under `sdk/`, matching the paths at the top of the script).

### Why not the real Android NDK, and why not Gradle?

This container's network egress is limited to a small allow-list (GitHub,
PyPI, npm, crates.io, Ubuntu's package archives, etc.) and does **not**
include `dl.google.com`, `maven.google.com`, or Gradle's own distribution
servers — so neither the official NDK nor the Android Gradle Plugin (nor
even a bare Gradle distribution for `gradle-wrapper.jar` to bootstrap) can
be downloaded here. Everything below routes around that with tools that
*are* reachable, while keeping the actual native code and headers 100%
authentic.

### How the native side works without the NDK

Zig's `zig cc`/`zig c++` (built on real clang) already understands the
`*-linux-android` targets at the code-generation level. What it doesn't
bundle is the Android **sysroot** (Bionic libc headers/libs) — normally
supplied by the NDK. Two things stand in for it here:

1. **Real OpenSL ES headers.** `native/include/SLES/*.h` are transcribed
   directly from the authentic AOSP source
   (`android.googlesource.com/platform/frameworks/wilhelm`) and the
   Khronos registry, under their original Apache-2.0 / Khronos permissive
   licenses — not reconstructed from memory. `SLEngineItf`, `SLRecordItf`,
   `SLPlayItf`, `SLObjectItf`, the Android buffer-queue/configuration/AEC
   interfaces, and the exact `SLDataLocator_IODevice` / `SL_DEFAULTDEVICEID_*`
   values were all cross-checked against AOSP, Khronos, and independent
   NDK sample code before use.

2. **A tiny "link-time only" stub sysroot** (`build_fake_sysroot.sh`): three
   ~1-symbol-table `.so` files (`libc.so`, `libdl.so`, `liblog.so`) built
   just so the linker can resolve `memcpy`/`dlopen`/`dlsym`/`__android_log_print`
   and record the right `NEEDED` entries. This is the *exact same trick*
   the real NDK uses — Google's own NDK docs describe its sysroot's `.so`
   files as containing "no code, only linker metadata." These stub files
   are build-time-only scaffolding: they are never copied into the APK,
   and at runtime the app resolves those same symbol names against the
   real `libc.so`/`libdl.so`/`liblog.so` that Android itself provides.
   (Verified with `readelf`: the shipped `libaudiobridge.so` imports
   exactly `memcpy`, `memset`, `dlopen`, `dlsym`, `__android_log_print` —
   nothing else.)

3. **OpenSL ES itself is loaded with `dlopen("libOpenSLES.so")`**, not
   linked at compile time (the same approach the `miniaudio` library
   uses), so we never needed an OpenSL ES *stub library* at all — only
   `libdl.so`'s `dlopen`/`dlsym`.

Net effect: the compiled `.so` files are ordinary, valid Android JNI
shared libraries — `file`/`readelf` confirm correct ELF machine types
(AArch64 / ARM EABI5 / x86 / x86-64) and a clean, minimal dynamic-symbol
table — built without ever downloading Google's NDK package.

**Porting to a real NDK later is trivial**: install a normal NDK, delete
`native/include/{jni.h,dlfcn.h,SLES/OpenSLES_Platform.h}` (the NDK's real
versions replace these three; the `SLES/OpenSLES*.h` files are the
authentic sources already so they don't need to change), link the two
`.cpp` files against `libOpenSLES.so`/`liblog.so` normally instead of the
stub sysroot, and build with `ndk-build`/CMake as usual.

### Why not Gradle

`gradle-wrapper.jar` only bootstraps a full Gradle distribution download
(from `services.gradle.org`) on first run, and a real Android build also
needs the Android Gradle Plugin from Google's Maven — neither host is
reachable here. The script above drives `aapt2`/`D8`/`javac`/zig directly
instead, which is also a lot more transparent about exactly what's
happening at each step.

## Low-latency design

- The app asks `AudioManager` for `PROPERTY_OUTPUT_SAMPLE_RATE` and
  `PROPERTY_OUTPUT_FRAMES_PER_BUFFER` — the device's *native* mixer rate
  and buffer size — and configures both the OpenSL ES recorder and player
  with those exact values. Matching the hardware's own rate/buffer size is
  what lets Android's audio server route the stream through its "fast
  track" mixer path instead of the higher-latency default path.
- Both sides use a 4-buffer `SLAndroidSimpleBufferQueue`. The recorder's
  callback copies each just-filled buffer straight into a playback buffer
  and re-enqueues both queues immediately — no extra queueing/thread
  hand-off, so added latency is roughly 1–2 buffer periods (typically
  somewhere in the 10–40 ms range depending on the device; this is the
  realistic ceiling for OpenSL ES on API 21 hardware. Sub-10ms latency
  generally requires AAudio's MMAP path, which needs API 26+ and is out of
  scope for an API-21 target).

## The feedback/howling problem (please read before testing)

Playing the mic back out of the **same device's** speaker while still
recording will pick the sound back up — exactly like a PA system next to
its own microphone. To reduce this:
- The recorder is configured with `SL_ANDROID_RECORDING_PRESET_VOICE_COMMUNICATION`,
  which asks Android to apply its hardware/software Acoustic Echo
  Cancellation, and the app also explicitly enables the dedicated AEC
  effect interface when the device exposes one.
- AEC quality varies a lot by device and isn't guaranteed everywhere.

**For a clean test, use wired or Bluetooth headphones** (mic picks up your
voice, not the speaker) rather than the built-in speaker.

## Build & install

```bash
./build.sh                       # produces MicSpeakerBridge.apk
adb install -r MicSpeakerBridge.apk
adb logcat -s AudioBridge        # engine lifecycle / error logs
```

Tap **Start** to begin passthrough, **Stop** to end it.

## Changelog

- **Added a gain slider, level meter, and output routing (Loudspeaker /
  Earpiece-or-wired-headphones / Bluetooth).**
  - *Gain*: applied in the recorder callback as saturating Q8 fixed-point
    integer math (0-400%, i.e. up to +12 dB) - no floats cross the JNI
    boundary (float calling convention on 32-bit ARM depends on
    soft-float vs hard-float ABI, exactly the kind of mismatch this
    project avoids by using ints everywhere) and no float math risks a
    compiler-rt dependency this project's minimal stub sysroot doesn't
    provide. Saturates instead of wrapping on overflow, verified with a
    host-side unit test (`gcc -fsanitize=undefined`) covering every
    sample value at every 10% gain step from 0-400%.
  - *Level meter*: the same callback tracks the loudest sample since the
    UI last polled it; `MainActivity` polls every 80ms.
  - *Output routing*: Android 5.0 has no per-stream "preferred device"
    API, so this uses the platform's call-audio routing instead - the
    player is a `STREAM_VOICE_CALL` stream, the audio mode is set to
    `MODE_IN_COMMUNICATION` while the bridge runs, and
    `setSpeakerphoneOn()` / `startBluetoothSco()` steer it to the
    loudspeaker, earpiece-or-wired-headset, or a Bluetooth headset. A
    route change (including a wired headset being plugged/unplugged, or
    a Bluetooth SCO link connecting/dropping, both handled via
    broadcast receivers) tears down and recreates the native engine,
    since the recorder is bound to a specific input device at creation
    time. Bluetooth uses a restricted mono 8/16 kHz candidate list to
    match what a SCO link actually supports, and falls back to the
    previous local output (with an on-screen reason) if a headset never
    connects or disconnects mid-call. The previous audio mode and
    speakerphone state are restored on Stop.
  - The recorder's format sweep now also retries each candidate across a
    shrinking set of requested interfaces (buffer queue + config + AEC,
    then buffer queue + config, then buffer queue alone), so a device
    that rejects the optional interfaces still gets a working recorder
    instead of only trying format variations.

- **It's working - fixing "static" sounds.** With the locator-constant fix
  above, `CreateAudioRecorder` now succeeds on the very first candidate.
  Reported "static" during playback is a classic buffer-underrun symptom
  in real-time audio - two changes address it: (1) the buffer pool grew
  from 4 to **8** buffers (`kNumBuffers` in `audio_engine.cpp`), giving
  more slack against scheduling jitter without materially increasing
  steady-state latency, since audio is still forwarded the moment each
  buffer completes rather than waiting for the pool to fill; (2)
  `audiobridge_start()` now pre-rolls two silent (zeroed) buffers into the
  player's queue *before* setting it to `PLAYING`, so it's never left with
  an empty queue during the brief gap before the first real recorder
  callback arrives - a common source of an audible click/glitch at
  startup.

- **Fixed a launch crash.** The initial version called several OpenSL ES
  `Realize()`/`GetInterface()` functions without checking their result, and
  passed the (device-dependent, optional) `SLAndroidConfigurationItf`
  interface ID into `CreateAudioRecorder`/`CreateAudioPlayer`'s requested-
  interfaces array even on devices where it failed to resolve — a null
  entry there can crash the platform's own implementation. `audio_engine.cpp`
  now checks every `SLresult` and every `GetInterface()` output, treats
  `SLAndroidConfigurationItf` and the echo-canceller interface as properly
  optional (only including them in the request array when available), and
  logs a specific reason to `adb logcat -s AudioBridge` on any failure
  instead of continuing with a bad pointer.
- **Added a launcher icon** at `res/mipmap-{m,h,xh,xxh,xxxh}dpi/ic_launcher.png`
  (generated with Pillow — see `icon_gen/make_icon.py`), referenced from
  `AndroidManifest.xml` via `android:icon="@mipmap/ic_launcher"`.

- **Crash-diagnosis pass.** The crash persisted even after the checks above,
  which rules out a *checkable* OpenSL ES failure (those now degrade
  gracefully) and points at either a native-library **load** failure or a
  true native crash inside a call. Two changes narrow this down:
  - `MainActivity`'s `System.loadLibrary()` and `nativeInit()` calls are now
    wrapped in `catch (Throwable)`, so an `UnsatisfiedLinkError` (missing
    `.so` for the device's ABI, or a symbol that failed to resolve at load
    time) shows its exact message on screen instead of crashing silently.
    If the app still hard-crashes with this in place, the cause is a true
    native crash (segfault) rather than a catchable Java exception.
  - Native libraries are now linked with explicit `--hash-style=both`
    (confirmed already present by default, made explicit) and `-z lazy`
    (traditional lazy symbol binding instead of the eager `BIND_NOW`/full-RELRO
    default some modern linkers apply, which is a more conservative choice
    for a 2014-era OS).

- **Root cause found and fixed**: `UnsatisfiedLinkError: cannot locate symbol
  "__aeabi_memcpy"` on `armeabi-v7a` (32-bit ARM — the most common real
  Android 5.0 device architecture). LLVM's ARM32 backend emits calls to a
  family of `__aeabi_mem*` "Run-time ABI for the ARM Architecture" helpers
  for compiler-generated block copies (e.g. copying a local struct
  initializer onto the stack) — these are *separate* symbols from plain
  `memcpy`/`memset`, and the stub sysroot only declared the latter.
  Confirmed against AOSP bionic's own source (commit `bb5730e`,
  "Move `__aeabi_` which are not in libgcc.a to LIBC") that real devices'
  `libc.so` exports `__aeabi_memcpy[48]`, `__aeabi_memmove[48]`,
  `__aeabi_memset[48]`, `__aeabi_memclr[48]`, and `__aeabi_atexit` on ARM;
  `fake_sysroot/src/libc_stub.c` now declares the full set so the linker
  records them as normal `libc.so` imports, resolved for real at runtime
  exactly like `memcpy` already was.

- **On-screen diagnostics (no adb needed).** If `nativeInit()` fails, the
  app now shows exactly *which* OpenSL ES call failed and its `SLresult`
  code directly in the status text (e.g. `Failed at: CreateAudioRecorder` /
  `SL_RESULT_FEATURE_UNSUPPORTED (12)`), long-press-to-copy enabled. This
  is carried over JNI as two plain ints (a step id + the raw result code),
  not a string — returning a Java `String` from native code needs several
  real `JNIEnv` methods, which this project deliberately never calls
  (see the design note at the top of `audio_engine.cpp`); MainActivity's
  `STEP_NAMES`/`slResultName()` do the int→text mapping on the Java side
  instead, so no adb or logcat access is required to read a failure.

- **Root cause found and fixed**: `CreateAudioRecorder` failed with
  `SL_RESULT_CONTENT_UNSUPPORTED (9)`. `MainActivity` was querying
  `AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE` (the device's native *output*
  mixer rate, e.g. 44100 or 48000 Hz, sometimes an unusual value) and using
  that same rate for the *recorder* too. Per
  [Android's own OpenSL ES documentation](https://developer.android.com/ndk/guides/audio/opensl/opensl-for-android),
  OpenSL ES recording only reliably supports a fixed list of rates (8000,
  11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000 Hz) and does
  *not* follow the device's arbitrary native rate the way playback does —
  feeding it an output rate that isn't in that list (or isn't supported
  for recording on that specific device) is a well-documented cause of
  exactly this error. Since this app copies recorder buffers straight to
  the player with no resampling, both sides must share one rate anyway, so
  `MainActivity` now uses a fixed **16000 Hz / 320 frames (20ms) per
  buffer** — 16 kHz specifically called out as compatible with all
  devices — instead of querying the native output rate.

- **Root cause found and fixed (again narrowed to `CreateAudioRecorder` /
  `SL_RESULT_CONTENT_UNSUPPORTED (9)`, this time with the recording rate
  already fixed at a safe 16 kHz)**: the mono `SLDataFormat_PCM.channelMask`
  was set to `SL_SPEAKER_FRONT_CENTER`. Android's OpenSL ES implementation
  specifically expects `SL_SPEAKER_FRONT_LEFT` for a single channel - a
  deliberate, non-obvious convention documented directly in AOSP
  (`sles_channel_out_mask_from_count()` /
  `frameworks/wilhelm/src/android/channels.cpp`, with an explicit
  "see explanation in data.c re: default channel mask for mono" comment)
  and independently mirrored in Google's own Oboe library's OpenSL ES
  input-stream backend. Both the recorder's and player's PCM format now
  use `SL_SPEAKER_FRONT_LEFT`.

- **Strategy change: sweep instead of guess.** Two rounds of fixes based on
  documented AOSP behavior (sample rate, then channel mask) each addressed
  a real, confirmed issue but didn't resolve `CreateAudioRecorder` failing
  with `SL_RESULT_CONTENT_UNSUPPORTED (9)` on the test device — meaning its
  OEM audio HAL is pickier than the AOSP reference implementation in some
  way that isn't documented anywhere searchable. Rather than continue
  guessing single hardcoded configurations, `audiobridge_init()` now tries
  a prioritized list of 9 `(sample rate, channelMask)` combinations
  (`kFormatCandidates` in `audio_engine.cpp`: 44100/16000/8000/48000/22050/
  11025 Hz × `SL_SPEAKER_FRONT_LEFT`, plus 44100/16000/8000 Hz × mask `0`)
  against the real device at startup and keeps the first one
  `CreateAudioRecorder` actually accepts, logging every attempt. The
  player is created afterward using whichever rate won (recorder and
  player must match here, since buffers are copied through with no
  resampling). The on-screen status text shows which candidate (by index)
  was accepted on success, or how many were tried before giving up.

- **All 9 mono candidates failed identically.** Varying rate and channel
  mask across 9 combinations and getting the exact same
  `SL_RESULT_CONTENT_UNSUPPORTED` every time is itself a signal: whatever
  this device's audio HAL is rejecting is likely something held constant
  across all of them, not the specific rate/mask values - and the one
  major parameter never varied was channel count (always mono). The sweep
  now also tries **stereo** at each rate (`kFormatCandidates` grew from 9
  to 18 entries), with buffer sizing, the callback's byte-copy (already
  channel-count-agnostic - it only ever moves raw bytes), and the player's
  format all updated to follow whichever channel count actually gets
  accepted.

- **All 18 candidates (mono+stereo × 6 rates × mask variants) failed
  identically too.** Uniform failure across every varied format field is
  itself informative: it's consistent with something *format-independent*
  being rejected, not the specific values tried. Two changes address this:
  - `MainActivity` now checks `RECORD_AUDIO` directly via
    `PackageManager.checkPermission()` before attempting `nativeInit()` at
    all, rather than assuming `targetSdkVersion 21`'s install-time
    auto-grant actually took effect on this device/ROM - if it's not
    granted, that's now shown on screen immediately with no native call
    attempted.
  - `SLAndroidConfigurationItf` is no longer requested in
    `CreateAudioRecorder`/`CreateAudioPlayer`'s interface list (it was the
    one non-format constant present, marked "not required", across every
    failed attempt in both sweeps). Only the mandatory buffer-queue
    interface is requested at creation time now; the config interface is
    still fetched afterward, best-effort, for the voice-communication
    preset and echo cancellation.

- **On-screen logcat self-capture (still no adb needed).** The step/code
  diagnostic is precise about *where* things fail but can't carry the
  underlying implementation's own detailed error text (e.g. AOSP's OpenSL
  ES code logs specific messages like "unsupported sample rate" via
  `SL_LOGE` before returning a plain numeric `SLresult`). Since OpenSL ES
  runs in-process on Android (loaded via `dlopen` into this app, not a
  separate system service), those log lines are tagged with our own
  process id - which a regular app can read for itself via `logcat`
  without any special permission (unlike reading other apps'/system
  logs). `MainActivity` now runs `logcat -c` immediately before
  `nativeInit()` and `logcat -d` immediately after, filters the output to
  lines containing our own PID, and appends them to the on-screen failure
  message.

- **Actual root cause, found via the logcat capture above**:
  `libOpenSLES: pAudioSnk: data locator type 0x800007be not allowed`. This
  project's `SLES/OpenSLES_Android.h` defined
  `SL_DATALOCATOR_ANDROIDSIMPLEBUFFERQUEUE` as `0x800007BE` - one hex
  digit off from the real value, `0x800007BD`. `0x800007BE` is actually
  `SL_DATALOCATOR_ANDROIDBUFFERQUEUE`, an unrelated locator for
  compressed/streamed data (a completely different Android extension
  interface, `SLAndroidBufferQueueItf`, not the raw-PCM
  `SLAndroidSimpleBufferQueueItf` this project uses). Confirmed against
  four independent AOSP/NDK sources. Since this locator-type constant was
  used, unchanged, by *every* recorder/player buffer queue in both format
  sweeps (9, then 18 candidates), it explains the uniform
  `SL_RESULT_CONTENT_UNSUPPORTED` across all of them at once - none of it
  was ever a sample-rate, channel-count, or channel-mask problem. Fixed
  to `0x800007BD`; this single constant is shared by both the recorder's
  and player's buffer queue locators, so one fix corrects both.

## Known limitations / things to verify on a real device

- **Not runtime-tested on-device** — this sandbox has no Android
  device/emulator, so everything above was verified statically (ELF
  structure, symbol tables, `aapt2 dump badging` manifest validation,
  clean compiles for all 4 ABIs) but the actual audio path has not been
  heard. If something doesn't behave, `adb logcat -s AudioBridge` is the
  first place to look — every lifecycle step and failure path logs there.
- `targetSdkVersion` is pinned to 21, so Android grants `RECORD_AUDIO` at
  install time on every OS version (no runtime permission prompt). Raising
  `targetSdkVersion` means adding a normal runtime permission request
  before the first `nativeInit()` call.
- Mono, 16-bit PCM only; no explicit handling of audio focus/interruptions
  (phone calls, other apps) or headset-plug events.
- `.so` files are built unstripped (`-g`-ish debug info retained) so any
  crash log has readable symbol names; add `-s` to the zig link line in
  `build.sh` for a smaller release build once you've tested it.
