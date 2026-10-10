# Changelog

## 0.5.0-rc2 (2026-10-09)

- Centralize GitLab→GitHub sync in `ci/release-sync-all.sh` driven by `topsbot_ws/configs/ros2_release.repos` (`publish:github-all`: web/main manual + `release-*` tag triggers; per-package whitelists stay in each repo's `release.yaml`).
- Update `topsbot_ws/configs/ros2_release.repos` to the v0.5 source-release set (drop `topsbot_yolo_det`; add `topsbot_yolo`, `topsbot_segformer`, `topsbot_gesture`, `topsbot_whisper`, `BerxelSDK_ROS2_riscv64`); `version` is the `release-*` GitHub tag consumed by `vcs import`, the GitLab source ref is derived from it at sync time, and re-running the sync is idempotent (an existing tag with an identical tree is skipped).

- Cross-build jammy and noble side by side: per-variant docker image, sysroot and `debsrc/<distro>/` output.
- Reorganize build scripts into `topsbot_ws/tools/scripts/` and configs into `topsbot_ws/configs/`; per-board target dirs (`configs/target/mes20/`) with sysroot package lists and a simplified `tb update`.
- Resolve sysroot dependencies automatically via rosdep and inject them into the sysroot.
- Fix riscv64 cross-build failures and sysroot dpkg status drift / usr-merge on injection.
- Vendor the Berxel SDK into the deb source so OBS builds work offline; append the remaining ta SDK rosdep keys.
- `topsbot-ros` meta: Depends now mirror the v0.5 release checklist — 24 tbros deps (new yolo / segformer / gesture / whisper, fastdds, orbbec / berxel / tanway / yesense drivers, `tb_seg_msgs`, `python3-mediapipe-topsbot`); drop the deleted `topsbot_yolo_det`.
- Fix rosdep resolution: the generated ROS overlay no longer shadows the project `topsbot.yaml` mapping (`orbbec_camera_msgs` resolved to a stock `ros-humble-*` deb), the project overlay now sorts before rosdistro `base.yaml`, and the overlay is regenerated when `topsbot.yaml` itself changes.
- Add the internal v0.5 publish manifest (`topsbot_ws/configs/ros2_internal_publish.repos`).
- Disable the tag-driven `obs:topsbot-ros` CI release job; the meta deb is uploaded manually via `osc` to `tbros-humble-noble`.

## 0.4.0-rc1 (2026-09-04)

- Rework the CLI as Python `tb.py`: `update` (code / sysroot / docker-image / all), `build`, `clean`, `shell`, `exec`, `config`, `package`; strict `lunch` target selection with `*.override.json` overrides.
- Persistent `tb-build` build container with Ctrl-C cleanup; `TB_ONESHOT` for throwaway runs.
- Sysroot update: `--download-only` / `--extract-only`, layout-aware extraction into a fixed place dir.
- `tb package`: bloom-debianize workspace packages into `tbros-humble-*` deb sources, with the source commit ID recorded in the `.dsc` / `debian/control`.
- OBS packaging CI for ROS package repos: `ci/obs-package.sh` + includeable `ci/obs-package.gitlab-ci.yml` (tag → bloom → osc upload).
- Add the `topsbot_ros` meta package and its tag-driven release job (`ci/pin-topsbot-ros.py`): version from the cc tag, `version_gte` pins from the release repos manifest.
- Add `validate:repos-tags` CI: `vcs import` check that every pin in the repos manifest actually clones.
- Import the sysroot builder (`topsbot_ros_base`) via `ros2.repos`; sysroot packing moved there.
- Pin subrepos to pre-release rc tags in the repos manifests.

## 0.3.1 (2026-08-21)

- Update sysroot download link.

## 0.3.0 (2026-08-20)

- Switch GitHub sync to release2github demo scripts (`alpine-fu:3.20`, append-only push, no `push -f`).
- Update sysroot to 0.4.0.
- Update `topsbot_ws/configs/ros2_release.repos`.

## 0.2.0 (2026-07-09)

- Add release2github export gates (`.gitlab-ci.yml`, `release.yaml`, `ci/release-sync.sh`).
- Add `topsbot_ws/configs/ros2_release.repos` for importing public TopsBot packages from GitHub.
- Rewrite bilingual README for GitHub users (`README.md`, `README.zh-CN.md`).
- Update sysroot on `dev`.

## 0.1.0 (2026-06-03)

- 交叉编译工具链说明与 `topsbot_ws/tools/`（不含 `topsbot_sysroot`）
