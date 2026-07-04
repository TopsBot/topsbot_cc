# Changelog

## unreleased

- 转为 GitLab 内部维护项目，移除 GitHub 同步与 CI（`.gitlab-ci.yml`、`release.yaml`、`ci/`）
- sysroot 以 `topsbot_sysroot.tar.gz`（Git LFS）存储，新增 `extract_sysroot.sh` 解压脚本
- 启动 Docker 容器前自动检查并解压 sysroot

## release-0.1.0 (2026-06-03)

- 交叉编译工具链说明与 `topsbot_ws/tools/`（不含 `topsbot_sysroot`）
