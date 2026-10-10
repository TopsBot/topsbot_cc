# Cross-compile host images

One Dockerfile, two tags. Target sysroot stays outside the image (`/sysroot` mount).
Host `protoc` (package `protobuf-compiler`) matches the suite: jammy 3.12, noble 3.21.

```bash
./topsbot_ws/tools/docker/build.sh jammy    # topsbot_riscv64_cross_build:jammy  (Ubuntu 22.04 / gcc 11)
./topsbot_ws/tools/docker/build.sh noble    # topsbot_riscv64_cross_build:noble  (Ubuntu 24.04 / gcc 13)
```

`lunch` picks JSON `image` (or auto `topsbot_riscv64_cross_build:{variant}`). If that tag is missing: JSON `remote_image` set -> pull and tag (no local fallback); unset -> build from `topsbot_ws/tools/docker/`.
