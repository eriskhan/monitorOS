# Third-party notices

Except where otherwise noted, source code authored for monitorOS is licensed
under the repository's MIT License.

The components below retain their upstream copyright notices and license terms.

## Apple NullAudio AudioServerPlugIn sample

Location:

```text
apps/audio-driver-macos/
```

`MonitorOSAudio.c` is an adapted copy of Apple's NullAudio AudioServerPlugIn
sample.

Upstream copyright:

```text
Copyright © 2020 Apple Inc.
```

License: MIT.

The complete upstream license notice is preserved in:

```text
apps/audio-driver-macos/LICENSE.apple-null-audio.txt
```

monitorOS-specific changes to this component are distributed under the same
MIT terms.

## Qualified iMac hardware-support checkout used by the installer

`install-imac` downloads a pinned checkout of:

```text
https://github.com/ahmadtv/omarchy-imac18-3
```

at revision:

```text
43e7ccd851d5c53d2d66bd4ee163bb8da6a6c047
```

That checkout supplies the native-5K and audio kernel support required by the
iMac18,3 target. It is an external build/install dependency; its files and any
third-party components it retrieves or patches retain their own upstream
licenses. The monitorOS MIT License does not relicense them.

### CS8409 audio driver

The qualified audio path in that checkout uses:

```text
https://github.com/jackdanyell/imac18-3-cs8409-linux-audio
```

at revision:

```text
be90113
```

and applies an iMac18,3-specific patch on top. That driver is based on
`davidjo/snd_hda_macbookpro`. Relevant Linux driver source files identify
themselves with the SPDX expression:

```text
GPL-2.0-or-later
```

The driver source is not vendored into monitorOS. It is downloaded and built by
the external hardware-support tooling, and remains under its upstream GPL
terms.

## Rust dependencies

The monitorOS Rust workspace currently has two direct third-party crate
dependencies:

- `libc` — MIT OR Apache-2.0.
- `mdns-sd` 0.21.4 — MIT OR Apache-2.0.

The direct `mdns-sd` dependency is pinned to 0.21.4 in the workspace
manifest. Cargo resolves its transitive dependency graph when the workspace is
built; those dependencies retain their respective upstream licenses.

## System-provided native libraries

The iMac userspace video/audio worker dynamically links libraries supplied by
the target operating system, including libdrm, GBM/EGL/GLES, ALSA and
libsamplerate. These libraries are not vendored by this repository and retain
the licenses of the packages supplied by the target distribution.

A binary or appliance distributor is responsible for satisfying the license
and notice requirements of the exact system packages it redistributes.
