#!/bin/bash

# LinuxWave update commands — 4.4.0
#
# 这个文件由 LinuxWave 仓库的 scripts/build_update_commands.py 生成，请勿手工编辑。
# 它取代了以前的 files_info：不再由客户端解析「要下载哪些文件」，而是由这里自己
# 完成下载与落盘。好处是只列出真正变动的文件 —— 这次没碰 help.py，就不必再下一遍。
# 目录结构变更的迁移也写在这个脚本里。
#
# 客户端保证以下环境变量：
#
#   LINUXWAVE_INSTALL_DIR      安装根目录
#   LINUXWAVE_CORE_URL         LinuxWave 代码的地址前缀（不含分支）
#   LINUXWAVE_BRANCH           代码分支
#   LINUXWAVE_CURRENT_VERSION  当前已装版本；首次安装时为空
#   LINUXWAVE_FILE_TIMEOUT     单个文件的超时秒数
#   LINUXWAVE_NEED_SUDO        1 = 安装目录需要 sudo 才能写
#   LINUXWAVE_LANG             zh = 中文输出；未设置或其它值 = 英文
#
# 约定：
#   - 任何一步失败都要 exit 非零；客户端据此判定「什么都没更新」，不写 VERSION.json
#   - 必须幂等：重跑一次不能把已经就位的东西弄坏

set -u

: "${LINUXWAVE_INSTALL_DIR:?LINUXWAVE_INSTALL_DIR is required}"
: "${LINUXWAVE_CORE_URL:?LINUXWAVE_CORE_URL is required}"

# 语言：install.sh 通过 LINUXWAVE_LANG 传进来。老版本客户端不会传，所以默认英文。
# 与 lib/install.sh 用同一套约定（lw_say "<English>" "<中文>"），不引 gettext。
LW_LANG="${LINUXWAVE_LANG:-en}"
lw_strip_item() {
    # --raw（install.sh 传下来的 LINUXWAVE_RAW=1）：去掉行首的 🌊 与紧跟的一个空格。
    # 与 `wave install --raw` 同一条规则；本脚本的几条提示都带 🌊，落进日志会脏。
    # 🌊 用 printf 的字节写：$'\U0001F30A' 在 bash 3.2 上不支持。
    local line="$1" item
    [[ "${LINUXWAVE_RAW:-}" == "1" ]] || { printf '%s' "$line"; return 0; }
    item="$(printf '\xf0\x9f\x8c\x8a')"
    case "$line" in
        "$item "*) line="${line#"$item "}" ;;
        "$item"*) line="${line#"$item"}" ;;
    esac
    printf '%s' "$line"
}
lw_say() {
    if [[ "$LW_LANG" == "zh" ]]; then printf '%b\n' "$(lw_strip_item "$2")"; else printf '%b\n' "$(lw_strip_item "$1")"; fi
}
lw_say_err() {
    if [[ "$LW_LANG" == "zh" ]]; then printf '%b\n' "$(lw_strip_item "$2")" >&2; else printf '%b\n' "$(lw_strip_item "$1")" >&2; fi
}
: "${LINUXWAVE_BRANCH:?LINUXWAVE_BRANCH is required}"

VERSION="4.4.0"
BRANCH="4.4"
FILE_TIMEOUT="${LINUXWAVE_FILE_TIMEOUT:-180}"
ATTEMPTS=3

# 额外根证书（LINUXWAVE_CACERT）：企业网络里 TLS 会被重签，自建镜像也可能用私有 CA。
# 这个脚本是客户端调起来的，环境变量直接继承；没设时行为不变。
# 设了却读不到就报错退出 —— 静默忽略会让人以为已经信任了那家 CA。
CURL_CACERT=""
if [[ -n "${LINUXWAVE_CACERT:-}" ]]; then
    _cacert="${LINUXWAVE_CACERT/#\~/$HOME}"
    if [[ ! -f "$_cacert" || ! -r "$_cacert" ]]; then
        lw_say_err "🌊 Error: LINUXWAVE_CACERT is not a readable file: $_cacert" "🌊 错误：LINUXWAVE_CACERT 不是一个可读的文件：$_cacert"
        lw_say_err "🌊 Next      export LINUXWAVE_CACERT=/path/to/root.pem (or unset it)" "🌊 下一步     export LINUXWAVE_CACERT=/path/to/root.pem（或取消这个变量）"
        exit 1
    fi
    CURL_CACERT="$_cacert"
fi

run() {
    if [ "${LINUXWAVE_NEED_SUDO:-}" = "1" ]; then
        sudo "$@"
    else
        "$@"
    fi
}

redact_url() {
    # 报错里的地址要打码：用镜像时 LINUXWAVE_CORE_URL 是
    # https://<用户>:<密码>@mirror/...，原样打印等于把密码写进终端滚屏、
    # CI 日志和用户贴出来的求助截图。
    #
    # 只在 // 之后、第一个 / 之前找最后一个 @ —— 路径里带 @ 是正常的
    # （jq@1.8.2.arm64），拿整条串找 @ 会把包名当成密码位置，地址就改坏了。
    local url="$1" rest authority path userinfo host user
    rest=${url#*://}
    [ "$rest" = "$url" ] && { printf '%s' "$url"; return; }
    authority=${rest%%/*}
    case "$rest" in
        */*) path="/${rest#*/}" ;;
        *)   path="" ;;
    esac
    if [[ "$authority" != *@* ]]; then
        printf '%s' "$url"
        return
    fi
    userinfo=${authority%@*}
    host=${authority##*@}
    user=${userinfo%%:*}
    if [[ "$userinfo" == *:* ]]; then
        printf '%s://%s:***@%s%s' "${url%%://*}" "$user" "$host" "$path"
    else
        printf '%s://***@%s%s' "${url%%://*}" "$host" "$path"
    fi
}

fetch() {
    # fetch <url> <目标>：先写 .linuxwave-part 再 mv，重试期间目标位置不会出现半个文件
    local url="$1" destination="$2" attempt status partial
    partial="$destination.linuxwave-part"

    run mkdir -p "$(dirname "$destination")"
    for ((attempt = 1; attempt <= ATTEMPTS; attempt++)); do
        status=0
        run curl -fsSL --max-time "$FILE_TIMEOUT" ${CURL_CACERT:+--cacert "$CURL_CACERT"} -o "$partial" "$url" || status=$?
        if [ "$status" -eq 0 ]; then
            # mv 失败也要报：权限不足（sudo 没拿到）时文件还在 .linuxwave-part 里，
            # 目标位置是旧的甚至不存在。以前这里不看返回值，于是「下载成功但没就位」
            # 会被当成这一步成功 —— 和 want 里那个 return/exit 是同一类问题。
            if ! run mv -f "$partial" "$destination"; then
                lw_say_err "🌊 Error: cannot move $partial into place" "🌊 错误：无法把 $partial 移动到目标位置"
                run rm -f "$partial" 2>/dev/null || true
                return 1
            fi
            return 0
        fi
        run rm -f "$partial" 2>/dev/null || true
        if ((attempt < ATTEMPTS)); then
            sleep 2
        fi
    done
    return 1
}

file_sha256() {
    # 用 openssl 而不是 sha256sum：install.sh / selfupdate.sh 里验签名已经要用它，
    # 少一个依赖就少一种「某台机器上没有那个命令」的失败。
    openssl dgst -sha256 -r "$1" 2>/dev/null | awk '{print $1}'
}

verify_hash() {
    # verify_hash <仓库内路径> <已下载的文件> <期望哈希>
    #
    # 4.0 是**实验期**：默认只警告，装还是照装。理由是老客户端拿不到这份判断
    # （它们跑的是自己那份老脚本），真正的强制要等客户端版本铺开。开关：
    #   LINUXWAVE_WANT_HASHES=1   客户端要求校验（由 install.sh / selfupdate.sh 置）
    #   LINUXWAVE_STRICT_HASHES=1 不符即失败（未来的默认，现在不设）
    local repo_path="$1" file="$2" expect="$3" got
    got="$(file_sha256 "$file")"
    [ -n "$expect" ] || return 0
    [ "$got" = "$expect" ] && return 0

    if [ "${LINUXWAVE_STRICT_HASHES:-}" = "1" ]; then
        lw_say_err "🌊 Error: $repo_path does not match the signed manifest" \
                   "🌊 错误：$repo_path 与已签名清单不符"
        lw_say_err "🌊   expected $expect" "🌊   期望 $expect"
        lw_say_err "🌊   got      ${got:-<unreadable>}" "🌊   实际 ${got:-读不到}"
        exit 1
    fi

    lw_say_err "🌊 Warning: $repo_path does not match the signed manifest (continuing)" \
               "🌊 警告：$repo_path 与已签名清单不符（继续安装）"
    lw_say_err "🌊   expected $expect" "🌊   期望 $expect"
    lw_say_err "🌊   got      ${got:-<unreadable>}" "🌊   实际 ${got:-读不到}"
    return 0
}

want() {
    # want <仓库内路径> <是否 +x> [期望的 sha256]
    local repo_path="$1" exec_flag="${2:-0}" expect_sha="${3:-}"
    local destination="$LINUXWAVE_INSTALL_DIR/$repo_path"
    local url="$LINUXWAVE_CORE_URL/$LINUXWAVE_BRANCH/$repo_path"

    if [ "${LINUXWAVE_SILENT:-}" != "1" ]; then
        lw_say "🌊 Downloading $repo_path..." "🌊 正在下载 ${repo_path}……"
    fi
    if ! fetch "$url" "$destination"; then
        lw_say_err "🌊 Error: cannot download $repo_path" "🌊 错误：无法下载 $repo_path"
        echo "🌊   $(redact_url "$url")" >&2
        # 404 有两种完全不同的原因：单个文件被删了，或者整棵 core/<分支>/ 压根没同步。
        # 后者是新分支上线当天的常态（镜像一天只跑一次），而且症状看起来一模一样 ——
        # 日志里只说某一个文件下不到。
        lw_say_err "🌊 If every file fails like this, the mirror has not synced branch $LINUXWAVE_BRANCH yet." \
                   "🌊 如果每个文件都这样，说明镜像还没同步 ${LINUXWAVE_BRANCH} 这个分支。"
        lw_say_err "🌊 Run scripts/mirror_sync.sh on the mirror (see docs/mirror.md)." \
                   "🌊 在镜像机上跑 scripts/mirror_sync.sh（见 docs/mirror.md）。"
        # 必须 exit 而不是 return：install_fresh / install_delta 是一串裸的
        # `want ...`，没有 `|| exit`，脚本也没有 set -e。用 return 1 的话
        # 调用方不看返回值，于是「有文件没下到」会被当成更新成功，客户端照旧
        # 写 VERSION.json —— 安装树缺文件但版本号已经前进了，这种状态最难查。
        exit 1
    fi
    # 校验放在 chmod 之前：先确认字节对不对，再决定要不要给它执行位
    if [ "${LINUXWAVE_WANT_HASHES:-}" = "1" ] && [ -n "$expect_sha" ]; then
        verify_hash "$repo_path" "$destination" "$expect_sha"
    fi
    if [ "$exec_flag" = "1" ]; then
        # 加不上 +x 的后果是「命令找不到」，比下载失败更难懂，所以这里也要拦住
        if ! run chmod +x "$destination"; then
            lw_say_err "🌊 Error: cannot make $repo_path executable" "🌊 错误：无法把 $repo_path 设为可执行"
            exit 1
        fi
    fi
    return 0
}

install_fresh() {
    # 首次安装（或修复一棵不完整的安装树）：所有文件都要。
    want Keys/D0E229FB.asc 0 f2852806fdd64f2df320e6446aa704455b4c85cfa27bead7d29ecf32e3d7647b
    want Keys/linuxwave-rsa.pub.pem 0 4b15601f77a302cc1ba2610cd3d96ff1e8982da98a401555eaa225fea6473c17
    want cli/commands.py 0 de76979dda463a96d1efd743c549463b9319f4e9e0a94bd6413e9017c4a50615
    want cli/common.py 0 0d3ef9bddacd6b8b27898efe134b975079bfa520e9e41ad62f2adc168d7e6816
    want cli/flags.py 0 e217efab397f6d3d700f7eeb97a84a248967d79185de804e285b6f051d308ea9
    want cli/help.py 0 04e940ce707a12f61b5501bf04690ea7b499c7edd192486098956988e0f48a42
    want cli/help_zh.py 0 46c5380202172ad520b34aeb0001bf800fe2ab46c12c2a754f853f472d0f0d82
    want cli/manual.py 0 0993d72f5c218bf803d6db0de1a2b198531915dd9af1b059053bac4ab6d38ca8
    want cli/silent.py 0 1b9b2e2f2003d2fba75b42df458bf34c6cf76f141f9bf09848204d9ab11fbc62
    want cli/suggest.py 0 1a4ead908dff2fe83917fbbf7d4fb47d144fb3a33d6319ec9349bf70b258a938
    want config/configerror.py 0 5357812ea1fe0ece0d3ef378564e5ab487da330b1221c85bf3e626d1b191fe28
    want config/configpaths.py 0 63699be24c82ac8a989fb7804ada3187279206e009f0bcb8fee3cac94fb09566
    want config/envvar.py 0 705298d69c6d7bb4bd43a57043b6daf67137a91bf8be1ca306d818767a282b88
    want info/wave-zh.info 0 d61a74e6f2b1e8ee17ad77a1a0b021919d65a7d94134ab57e10319695c05aec6
    want info/wave.info 0 ea1133a123efe1f5e143c2fc08d4b3871ad6c73047fef78d5417c47e03b7a263
    want lib/latest.py 0 c0af297fef60278c8710ad4b28e6956c580ffe8662e41057552c4c08dc299117
    want lib/mirrorinfo.py 0 fad0406c3aeb68cdc7456626d0e0b76b2db0496a9c4b83a7635fbc95b8edfa32
    want lib/selfupdate.py 0 8ef3776cfe82c4ea7b3ed327485e3de061f9a11217d7de3096c88ef85680f31d
    want lib/selfupdate.sh 1 77c2881a615dfd6edb75e363cd22acddf950f60ba414debd9330276a81ed5354
    want lib/shellenv.py 0 7c6e90809622c392cfd8286b6f28f631bae529075957f5bc3f03ecb44dfda945
    want lib/steplog.py 0 2e6d83137bfea0ba6e3772310567a456af99d1675fe401cf02c2ad12dc29491c
    want lib/versioncompare.py 0 9c93715c7bf5767adf6aa7f349f7f88810b9c1bd595121953d99445ed7d15bee
    want lib/wave.py 0 2aab7006a984a44660a05c683640458c4b4e99ce16357c43c4471007d9856c0c
    want man/man1/wave-info-zh.1 0 5da74667bd1dad745216bea7d27cc0925619741ddcd5d781b5ced23aa740defe
    want man/man1/wave-info.1 0 5acddd477a9c288413cf52e939449f92cf7541f4425a78b5319dc3710ce10468
    want man/man1/wave-install-zh.1 0 801b239e26ebd6b57841158eaaff1dd3300a741b20cf0e5eb80d25a3b1b44013
    want man/man1/wave-install.1 0 a7aa04ebc00dfda37852bd601ae1f61f9ecbb9d982fa49a0ee20b63b38165133
    want man/man1/wave-latest-zh.1 0 b125807d617a341a4efd4f12498124dc875054a05445f2d25f25c5de6feec881
    want man/man1/wave-latest.1 0 740a8dec459aa830e1e722531da1dfc22ada5b840b60b9b69ae9a3a33cf502ba
    want man/man1/wave-link-zh.1 0 6742758206dee8bc8fd9fee2e07e19e2e9a5269b6f07d4464007c38e910ffce3
    want man/man1/wave-link.1 0 1b1803b3cda73f6fd20a48c9828a1abee7b7d04ca9997656d024a2a59f8be765
    want man/man1/wave-linkquery-zh.1 0 bcd9174ce7affd45f96e53d41a030a86b857077bcc5ee40e57d934cb21152ea8
    want man/man1/wave-linkquery.1 0 9dd3faa79f4880f8dfb8b6db2bca3d942e8a24aab292e490f94f79d9a57397b0
    want man/man1/wave-list-zh.1 0 751bb9972c3532a4ba3977e5f9de74c646d66916d6d893b5f333cd1f31f4c3d0
    want man/man1/wave-list.1 0 569e832580c7dc20efbd01ad32ac207af11449db49f1c9b6fd5fe533cbd447f0
    want man/man1/wave-manual-zh.1 0 64818b3304ef67cf715d0bbf10360bc6e1a6469475b6b8e97a515ee3b97a0e52
    want man/man1/wave-manual.1 0 e44428475ecd1f55d28784e651c3bc3d3b1da020dbadf0dda3d96279a9f6bd3b
    want man/man1/wave-mirror-zh.1 0 9046422636a029c7b9129a976f4d1b814fa1dbfd95b12d4d6a10e1ccb5082bf3
    want man/man1/wave-mirror.1 0 82592f8c2d6892bae1e81adfbf1f8525efe62b7d29cc1f8ba4788ec93fe18559
    want man/man1/wave-search-zh.1 0 3672306db8f6b039d519beb810b5b455443d94985e01a140325e3304148a5dbe
    want man/man1/wave-search.1 0 6dcd4382c1ac8ee25066817c61d933eff30a6e377fc21f363f17df128a182564
    want man/man1/wave-selfupdate-zh.1 0 c4eaca3d9ab1a520d18b97e8c002e787ff120a1144c3f30ff1e1fccf166a6ce8
    want man/man1/wave-selfupdate.1 0 cd44471ccb5479697d6fc7a2558a8e1f14a384a41ac3d2e4b6924f9b8520572c
    want man/man1/wave-shellenv-zh.1 0 acfea31d0b76d5cb6672729df7c4e21311ae9477dad957152d72586f1fb24316
    want man/man1/wave-shellenv.1 0 c0c0b867c87ac085fdac77332cfc16215397e900dfb2e425d001e09280a1f707
    want man/man1/wave-uninstall-zh.1 0 8671396df6d9e1b861eb63c5e391218a8fa64e1a3d84dc91628e48c865e750c2
    want man/man1/wave-uninstall.1 0 9ede0499881b35a03613a33d6a2273d3d3e5c7273b6a19d4b05b2294bf327b22
    want man/man1/wave-unlink-zh.1 0 acda2637a9a1f43c0379593811e87b9d9c184e91fe9d4a424bd0789f9062453f
    want man/man1/wave-unlink.1 0 47ab338df34c874586622bf4ccbcddf53ef5fc86fcd83adafc232db1eda46e1e
    want man/man1/wave-upgrade-zh.1 0 ea052c9493931dbf0277ec1cb145dcd59cab1fcf1278f543b12412bc3d643c5f
    want man/man1/wave-upgrade.1 0 cecdbfb8fa9ad099c29db6e43b288af2939fedad86046fa7232f7974b0ee3b26
    want man/man1/wave-version-zh.1 0 f024a2653ac979ada713d99861cf93d622e32efe9da7e912073cd6916e78ec49
    want man/man1/wave-version.1 0 497a0bf02192ccdf915c5851a6a0e82023643a40fe03b075eca86fe147a89141
    want man/man1/wave-zh.1 0 c377b4816644838a9909c608b0942e8b9d5d87ae825da2bcbeed7c559ec3f478
    want man/man1/wave.1 0 2ab7a5e2f00e72d02e49062da7be232c0867b8d704e6c87501269bc726333512
    want net/domains.py 0 fac5439e5470ff026b500cfeb6b8f9990ca9f5d947f54999e14ae4a6e06ee933
    want net/signature.py 0 2a84baf21b952da6d7c20a31eea977a21059c60b6acb2151e7b6cf1d8e1992b2
    want net/timeouts.py 0 5fb423ff10eef581faa6dc55eed66062377b6d6d274fccd7a427217c87209ed6
    want net/tls.py 0 8e28a5075612d3f989ce13c354996adbe3616f68ace2182921a8a91398ef169e
    want pkg/linker.py 0 89b1f8e45c88792ed51afdaa46f9e93c0aa3bf84dafb7ccc303264287a022d5f
    want pkg/pkginfohelper.py 0 098f2682af25776d2b6680f232df5412be511286e56660ea62ed42010a7fb33d
    want pkg/pkginstaller.py 0 0007d9452dca18404f07da6847b9fc1800f2df188c7a93616187fc1f8fa81ab7
    want pkg/pkginstaller.sh 1 308475976c6cbdeb79f85bfbf65e2ba8c87a252e4ebef7141675bee8e5ca00a8
    want pkg/pkgunzip.sh 1 2a9af3a61049be356e6d4d9e5be44277aae667690806723300806df9cc755b20
    want pkg/uninstaller.py 0 2c31ca678718685cb47b41e77b3e3d364071210624f46a358d193da46ba3d36e
    want pkg/upgrader.py 0 b54866e6dd6c32dc045546aa6a9a495f3a431951c5c937f1f280edb387367c38
    want surfboard/depsinstaller.py 0 bdb536458cd0c47cd0eb9d1ee6bfd8ec725fd1ac1a1a61e48c2da6ddfd480fcc
    want surfboard/depsinstaller.sh 1 cec1a4ae5085f114db28de034fea220df8dfcad89eb835ffff7d11e1574cc49a
    want surfboard/depsmanager.sh 1 00ca91b452389e679c46284e8c5a6664dad01706d4e7892fb6b32c3eeb64aac0
    want surfboard/querier.py 0 6f85ea17174e5c80ceb5ca442374ff48fdaf1eaf7cb6e77118c59abbc6c76107
    want surfboard/tagger.sh 1 978937bc30829f8333aedbc23ea87cc39499f8d2401a0605345b1a7be36530c5
    want surfboard/transfer.sh 1 372fe62fe760e85e9534f015ba89ed19ff462f4c8ac99318149430a54cdc1748
}

install_delta() {
    # 从上一版升级：只取这一版变动过的文件。
    # 没列出的文件保持不变 —— 它们的字节和上一版相同。
    want cli/common.py 0 0d3ef9bddacd6b8b27898efe134b975079bfa520e9e41ad62f2adc168d7e6816
    want config/configpaths.py 0 63699be24c82ac8a989fb7804ada3187279206e009f0bcb8fee3cac94fb09566
    want lib/latest.py 0 c0af297fef60278c8710ad4b28e6956c580ffe8662e41057552c4c08dc299117
    want lib/selfupdate.py 0 8ef3776cfe82c4ea7b3ed327485e3de061f9a11217d7de3096c88ef85680f31d
    want lib/selfupdate.sh 1 77c2881a615dfd6edb75e363cd22acddf950f60ba414debd9330276a81ed5354
    want lib/shellenv.py 0 7c6e90809622c392cfd8286b6f28f631bae529075957f5bc3f03ecb44dfda945
    want lib/versioncompare.py 0 9c93715c7bf5767adf6aa7f349f7f88810b9c1bd595121953d99445ed7d15bee
    want net/domains.py 0 fac5439e5470ff026b500cfeb6b8f9990ca9f5d947f54999e14ae4a6e06ee933
    want pkg/pkginfohelper.py 0 098f2682af25776d2b6680f232df5412be511286e56660ea62ed42010a7fb33d
    want pkg/pkginstaller.py 0 0007d9452dca18404f07da6847b9fc1800f2df188c7a93616187fc1f8fa81ab7
    want pkg/uninstaller.py 0 2c31ca678718685cb47b41e77b3e3d364071210624f46a358d193da46ba3d36e
    want pkg/upgrader.py 0 b54866e6dd6c32dc045546aa6a9a495f3a431951c5c937f1f280edb387367c38
    want surfboard/depsinstaller.py 0 bdb536458cd0c47cd0eb9d1ee6bfd8ec725fd1ac1a1a61e48c2da6ddfd480fcc
    want surfboard/querier.py 0 6f85ea17174e5c80ceb5ca442374ff48fdaf1eaf7cb6e77118c59abbc6c76107
}

# 本版安装树应有的全部文件（与 install_fresh 同一份清单，见生成器里的 list_lines）。
FULL_FILES="
Keys/D0E229FB.asc
Keys/linuxwave-rsa.pub.pem
cli/commands.py
cli/common.py
cli/flags.py
cli/help.py
cli/help_zh.py
cli/manual.py
cli/silent.py
cli/suggest.py
config/configerror.py
config/configpaths.py
config/envvar.py
info/wave-zh.info
info/wave.info
lib/latest.py
lib/mirrorinfo.py
lib/selfupdate.py
lib/selfupdate.sh
lib/shellenv.py
lib/steplog.py
lib/versioncompare.py
lib/wave.py
man/man1/wave-info-zh.1
man/man1/wave-info.1
man/man1/wave-install-zh.1
man/man1/wave-install.1
man/man1/wave-latest-zh.1
man/man1/wave-latest.1
man/man1/wave-link-zh.1
man/man1/wave-link.1
man/man1/wave-linkquery-zh.1
man/man1/wave-linkquery.1
man/man1/wave-list-zh.1
man/man1/wave-list.1
man/man1/wave-manual-zh.1
man/man1/wave-manual.1
man/man1/wave-mirror-zh.1
man/man1/wave-mirror.1
man/man1/wave-search-zh.1
man/man1/wave-search.1
man/man1/wave-selfupdate-zh.1
man/man1/wave-selfupdate.1
man/man1/wave-shellenv-zh.1
man/man1/wave-shellenv.1
man/man1/wave-uninstall-zh.1
man/man1/wave-uninstall.1
man/man1/wave-unlink-zh.1
man/man1/wave-unlink.1
man/man1/wave-upgrade-zh.1
man/man1/wave-upgrade.1
man/man1/wave-version-zh.1
man/man1/wave-version.1
man/man1/wave-zh.1
man/man1/wave.1
net/domains.py
net/signature.py
net/timeouts.py
net/tls.py
pkg/linker.py
pkg/pkginfohelper.py
pkg/pkginstaller.py
pkg/pkginstaller.sh
pkg/pkgunzip.sh
pkg/uninstaller.py
pkg/upgrader.py
surfboard/depsinstaller.py
surfboard/depsinstaller.sh
surfboard/depsmanager.sh
surfboard/querier.py
surfboard/tagger.sh
surfboard/transfer.sh
"

tree_complete() {
    # 判断这棵安装树是不是「本版应有的文件一个不缺」。
    #
    # 为什么不能只看 lib/wave.py 在不在：那种判据会把三种坏树当成好树 ——
    #   1. 上一版留下的一半升级（下到第 20 个文件时断网 / Ctrl-C）
    #   2. 跨版本跳级升级：增量只含「上一版 → 本版」的差异，中间的版本没算
    #   3. 文件被手工删过
    # 缺一个就走全量，代价是多重下几个文件，换的是「永远能自愈」。
    local path
    for path in $FULL_FILES; do
        [ -e "$LINUXWAVE_INSTALL_DIR/$path" ] || return 1
    done
    return 0
}

main() {
    # 「已经是这个版本」也要先确认树是完整的。VERSION.json 只证明「上次跑完过」，
    # 不证明文件还在 —— 只信版本号的话，一棵坏树会永远停在 "Already at"，
    # 无论跑多少次都不会修好。
    if [ "${LINUXWAVE_FULL_INSTALL:-}" != "1" ] \
       && [ "${LINUXWAVE_CURRENT_VERSION:-}" = "$VERSION" ] \
       && tree_complete; then
        lw_say "🌊 Already at $VERSION; nothing to download." "🌊 已经是 ${VERSION}，无需下载。"
        return 0
    fi

    if [ "${LINUXWAVE_FULL_INSTALL:-}" = "1" ] || [ ! -f "$LINUXWAVE_INSTALL_DIR/lib/wave.py" ]; then
        lw_say "🌊 Installing LinuxWave $VERSION" "🌊 正在安装 LinuxWave $VERSION"
        install_fresh || return 1
    elif ! tree_complete; then
        # 树在那儿但不完整：增量的前提（「没变动的文件都是对的」）不成立，
        # 直接全量补齐。这里不先跑 delta —— 缺的文件正好可能就是它要留着的那些。
        lw_say "🌊 The installed tree is incomplete; reinstalling all of LinuxWave $VERSION" \
            "🌊 安装树不完整，正在重新安装 LinuxWave ${VERSION} 的全部文件"
        install_fresh || return 1
    else
        lw_say "🌊 Updating LinuxWave ${LINUXWAVE_CURRENT_VERSION:-unknown} -> $VERSION" "🌊 正在更新 LinuxWave ${LINUXWAVE_CURRENT_VERSION:-unknown} -> $VERSION"
        install_delta || return 1
        # 增量之后再确认一次：delta 只含「上一版 → 本版」的差异，跨版本跳级时
        # 会漏掉中间那些版本改过的文件。补全比报错好 —— 用户什么也没做错。
        if ! tree_complete; then
            lw_say "🌊 Some files are still missing after the update; fetching all of LinuxWave $VERSION" \
                "🌊 更新后仍有文件缺失，正在补齐 LinuxWave ${VERSION} 的全部文件"
            install_fresh || return 1
        fi
    fi

    # ── 目录结构变更的迁移写在这里 ──
    # 约束：以当前用户身份执行，需要管理员权限时自己 sudo，失败要 exit 非零，
    # 且必须幂等。

    # 4.0.0：程序分层从 lib/ 摊平改成组件目录。新位置的文件已经由上面的
    # install_fresh / install_delta 下好（`want` 会先 mkdir -p），这里清掉
    # lib/ 下的旧副本。
    #
    # 这一条**不能省**：sys.path 的顺序是 cli → config → lib → net → pkg →
    # surfboard（见 lib/wave.py），也就是 lib/ **排在 net/ 前面**。留着
    # lib/domains.py，`import domains` 就永远命中旧那份，net/domains.py
    # 成了摆设 —— 症状是「改了半天没生效」，而不是报错。
    for stale in "$LINUXWAVE_INSTALL_DIR/lib/domains.py" \
                 "$LINUXWAVE_INSTALL_DIR/lib/configpaths.py" \
                 "$LINUXWAVE_INSTALL_DIR/lib/configerror.py" \
                 "$LINUXWAVE_INSTALL_DIR/lib/help.py" \
                 "$LINUXWAVE_INSTALL_DIR/lib/silent.py" \
                 "$LINUXWAVE_INSTALL_DIR/lib/quiet.py" \
                 "$LINUXWAVE_INSTALL_DIR/lib/tls.py" \
                 "$LINUXWAVE_INSTALL_DIR/lib/timeouts.py" \
                 "$LINUXWAVE_INSTALL_DIR/surfboard/depsversionparser.py"; do
        if [ -f "$stale" ]; then
            run rm -f "$stale" || exit 1
        fi
    done

    # 4.4.0：依赖解析并入 surfboard/querier.py，depsversionparser.py 不再被
    # import。不清掉也不算错（它只占一个文件的位置），但安装树里留一个没人用
    # 的模块会让人以为「它在生效」，而且 `components.txt` 的清单比对会报多文件。
    # 与上面同一条循环，只是注释按版本分开写，免得下一个人以为这条是 4.0 的。

    return 0
}

main "$@"
