#!/bin/bash

# LinuxWave update commands — 3.2.1
#
# 由 scripts/build_update_commands.py 生成，请勿手工编辑。
#
# 客户端（`wave selfupdate`）保证以下环境变量：
#
#   LINUXWAVE_INSTALL_DIR      安装根目录
#   LINUXWAVE_CONFIG_DIR       配置目录
#   LINUXWAVE_CORE_URL         代码地址前缀（不含分支）
#   LINUXWAVE_BRANCH           代码分支
#   LINUXWAVE_TARGET_VERSION   目标版本（本脚本所属的版本）
#   LINUXWAVE_CURRENT_VERSION  当前已装版本；首次安装时为空
#   LINUXWAVE_FILE_TIMEOUT     单个文件的超时秒数
#   LINUXWAVE_NEED_SUDO        1 = 安装目录需要 sudo 才能写
#   LINUXWAVE_SILENT           1 = 少打印
#   LINUXWAVE_DRY_RUN          1 = 只报告将要做什么，不落盘
#
# 约定：
#   - 任何一步失败都要 exit 非零；客户端据此判定「什么都没更新」，不写 VERSION.json
#   - 必须幂等：重跑一次不能把已经就位的东西弄坏

set -u

: "${LINUXWAVE_INSTALL_DIR:?LINUXWAVE_INSTALL_DIR is required}"
: "${LINUXWAVE_CORE_URL:?LINUXWAVE_CORE_URL is required}"
: "${LINUXWAVE_BRANCH:?LINUXWAVE_BRANCH is required}"

TARGET_VERSION="3.2.1"
TIMEOUT="${LINUXWAVE_FILE_TIMEOUT:-180}"

# 真正干活的脚本认的是 UPDATE_* 这两个名字，这里做一次映射
export LINUXWAVE_UPDATE_VERSION="${LINUXWAVE_TARGET_VERSION:-$TARGET_VERSION}"
export LINUXWAVE_UPDATE_BRANCH="${LINUXWAVE_BRANCH}"
export LINUXWAVE_MAX_TIME="$TIMEOUT"

url="$LINUXWAVE_CORE_URL/$LINUXWAVE_BRANCH/lib/selfupdate.sh"

# 先完整落到临时文件再执行，两个原因：
#   1. `bash -c "$(curl …)"` 里 curl 失败时 bash 仍然返回 0，会被误判成更新成功；
#   2. selfupdate.sh 自身就在这次更新要覆盖的文件里 —— 边读边覆盖同一个文件不安全。
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

if ! curl -fsSL --max-time "$TIMEOUT" -o "$tmp" "$url"; then
    echo "🌊 Error: cannot fetch $url" >&2
    echo "🌊 Nothing was updated." >&2
    exit 1
fi

/bin/bash "$tmp"
