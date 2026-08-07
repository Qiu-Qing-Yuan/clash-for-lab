#!/usr/bin/env bash
# shellcheck disable=SC1091
SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_SOURCE")" && pwd -P)"
cd "$SCRIPT_DIR" || exit 1
. "${SCRIPT_DIR}/script/common.sh"
. "${SCRIPT_DIR}/script/upgrade.sh"
. "${SCRIPT_DIR}/script/clashctl.sh"
. "${SCRIPT_DIR}/script/install-lib.sh"

INSTALL_OWNS_BASE=false
INSTALL_LOCK_HELD=false
INSTALL_RC_TOUCHED=false
INSTALL_SERVICE_TOUCHED=false
MIHOMO_OPERATION_LOCK_HELD=false

_install_generate_api_secret() {
    local secret
    [ -r /dev/urandom ] || return 1
    secret=$(LC_ALL=C od -An -N 32 -tx1 /dev/urandom 2>/dev/null | tr -d '[:space:]') || return 1
    case "$secret" in
    ''|*[!0-9a-f]*) return 1 ;;
    esac
    [ "${#secret}" -eq 64 ] || return 1
    printf '%s\n' "$secret"
}

_install_secure_mixin() {
    local mixin=$1 secret candidate
    secret=$(_install_generate_api_secret) || return 1
    candidate=$(mktemp "${mixin}.secure.XXXXXX") || return 1
    if ! LC_ALL=C awk -v secret="$secret" '
        /^secret:[[:space:]]*$/ && !replaced {
            print "secret: \"" secret "\""
            replaced = 1
            next
        }
        { print }
        END { if (!replaced) exit 1 }
    ' "$mixin" > "$candidate"; then
        rm -f "$candidate"
        return 1
    fi
    chmod 0600 "$candidate" || {
        rm -f "$candidate"
        return 1
    }
    mv -f "$candidate" "$mixin"
}

_install_cleanup() {
    local exit_status=$1 cleanup_ok=true
    trap - EXIT HUP INT TERM
    if [ "$INSTALL_OWNS_BASE" = true ]; then
        _stop_convert >/dev/null 2>&1 || cleanup_ok=false
        if [ "$INSTALL_SERVICE_TOUCHED" = true ]; then
            stop_mihomo >/dev/null 2>&1 || cleanup_ok=false
        fi
        if [ "$INSTALL_RC_TOUCHED" = true ]; then
            _set_rc unset >/dev/null 2>&1 || cleanup_ok=false
        fi
        if [ "$cleanup_ok" = true ]; then
            case "$MIHOMO_BASE_DIR" in
            "$HOME"/tools/mihomo) rm -rf -- "$MIHOMO_BASE_DIR" ;;
            *) cleanup_ok=false ;;
            esac
        fi
        [ "$cleanup_ok" = true ] ||
            _failcat "安装失败，自动清理未完成，请检查：$MIHOMO_BASE_DIR" || true
    fi
    if [ "$INSTALL_LOCK_HELD" = true ]; then
        _upgrade_release_lock
    fi
    exit "$exit_status"
}

_error_quit() {
    [ $# -gt 0 ] && _failcat "$1" || true
    exit 1
}

trap '_install_cleanup $?' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [ "${1:-}" = "--refresh" ]; then
    _valid_upgrade_env || exit 1
    _upgrade_acquire_lock || _error_quit "另一个 mihomo 操作正在运行"
    INSTALL_LOCK_HELD=true
    MIHOMO_OPERATION_LOCK_HELD=true
    if [ ! -x "${MIHOMO_BASE_DIR}/bin/mihomo" ] || [ ! -f "${MIHOMO_SCRIPT_DIR}/common.sh" ]; then
        _error_quit "未检测到完整安装，无法刷新管理脚本：$MIHOMO_BASE_DIR"
    fi
    if [ ! -x "${MIHOMO_BASE_DIR}/bin/yq" ]; then
        _error_quit "已安装环境缺少 yq，无法启用内核升级：${MIHOMO_BASE_DIR}/bin/yq"
    fi
    _install_script_release || _error_quit "刷新管理脚本失败"
    _upgrade_release_lock
    INSTALL_LOCK_HELD=false
    MIHOMO_OPERATION_LOCK_HELD=false
    _okcat '✅' '管理脚本已刷新'
    _okcat '💡' '重新登录后可使用 clash upgrade'
    exit 0
fi

# 用于检查环境是否有效
_valid_install_env || exit 1
_upgrade_acquire_lock || _error_quit "另一个 mihomo 操作正在运行"
INSTALL_LOCK_HELD=true
MIHOMO_OPERATION_LOCK_HELD=true

[ ! -e "$MIHOMO_BASE_DIR" ] && [ ! -L "$MIHOMO_BASE_DIR" ] ||
    _error_quit "请先执行卸载脚本,以清除安装路径：$MIHOMO_BASE_DIR"

# 创建用户目录结构
mkdir -p "$(dirname "$MIHOMO_BASE_DIR")" || _error_quit "创建安装父目录失败：$(dirname "$MIHOMO_BASE_DIR")"
mkdir "$MIHOMO_BASE_DIR" || _error_quit "无法原子创建安装目录：$MIHOMO_BASE_DIR"
INSTALL_OWNS_BASE=true
mkdir -p "$MIHOMO_BASE_DIR"/{bin,config,logs,state,tmp} || _error_quit "创建安装子目录失败：$MIHOMO_BASE_DIR"

# 先安装管理依赖，再安装经过 CI 校验的稳定版 mihomo。
if ! tar -xf "$ZIP_SUBCONVERTER" -C "${MIHOMO_BASE_DIR}/bin"; then
    _error_quit "解压 subconverter 失败: $ZIP_SUBCONVERTER"
fi

if ! tar -xf "$ZIP_YQ" -C "${MIHOMO_BASE_DIR}/bin"; then
    _error_quit "解压 yq 失败: $ZIP_YQ"
fi

# 重命名 yq 二进制文件（yq_linux_amd64 -> yq）
for yq_file in "${MIHOMO_BASE_DIR}/bin"/yq_*; do
    if [ -f "$yq_file" ]; then
        mv "$yq_file" "${MIHOMO_BASE_DIR}/bin/yq"
        break
    fi
done
chmod +x "${MIHOMO_BASE_DIR}/bin/yq" || _error_quit "设置 yq 权限失败"

if ! _install_bundled_mihomo "$MIHOMO_BUNDLE_LOCK" "$ZIP_BASE_DIR" "${MIHOMO_BASE_DIR}/bin/mihomo"; then
    _error_quit "安装 mihomo 稳定版失败，请检查 resources/mihomo.lock.tsv 和内核包"
fi

# 设置二进制文件路径
_set_bin

install_validation_home="${MIHOMO_BASE_DIR}/tmp/install-validation-home"
install_data_manifest="${MIHOMO_BASE_DIR}/tmp/install-validation-data.manifest"

# Mihomo resolves GEO databases and relative provider paths from its HomeDir.
# Install local data before validating a candidate stored under tmp/.
for resource_data in "$RESOURCES_BASE_DIR"/*.mmdb "$RESOURCES_BASE_DIR"/*.dat; do
    [ -f "$resource_data" ] || continue
    cp "$resource_data" "$MIHOMO_BASE_DIR/" ||
        _error_quit "安装配置数据失败：$resource_data"
done

# 仓库配置只作为只读输入；校验和下载在安装目录的临时文件中进行。
install_config_candidate=$(mktemp "${MIHOMO_BASE_DIR}/tmp/install-config.XXXXXX") ||
    _error_quit "创建配置暂存文件失败"
url=""
repo_config_usable=false
if [ -f "$RESOURCES_CONFIG" ] &&
    cp "$RESOURCES_CONFIG" "$install_config_candidate" &&
    _valid_config "$install_config_candidate" "$MIHOMO_BASE_DIR" \
        "$install_validation_home"; then
    repo_config_usable=true
fi

if [ "$repo_config_usable" != true ]; then
    rm -f "$install_config_candidate" || _error_quit "清理无效配置暂存文件失败"
    echo -n "$(_okcat '✈️ ' '输入订阅：')"
    read -r url
    _is_valid_subscription_url "$url" ||
        _error_quit "订阅地址无效，必须是完整的小写 http:// 或 https:// URL"
    _okcat '⏳' '正在下载...'

    if ! TMPDIR="${MIHOMO_BASE_DIR}/tmp" \
        TMP="${MIHOMO_BASE_DIR}/tmp" \
        TEMP="${MIHOMO_BASE_DIR}/tmp" \
        _download_config "$install_config_candidate" "$url" "$MIHOMO_BASE_DIR" \
        "$install_validation_home"; then
        _error_quit "下载失败，请检查订阅地址后重试"
    fi
fi
_okcat '✅' '配置可用'

_publish_new_config_validation_data "$install_validation_home" "$MIHOMO_BASE_DIR" \
    "$install_data_manifest" ||
    _error_quit "发布配置所需的离线数据失败"
rm -rf "$install_validation_home" ||
    _error_quit "清理配置验证目录失败"
rm -f "$install_data_manifest" ||
    _error_quit "清理配置数据发布记录失败"

_config_atomic_copy "$install_config_candidate" "$MIHOMO_CONFIG_RAW" ||
    _error_quit "发布配置失败：$MIHOMO_CONFIG_RAW"
rm -f "$install_config_candidate" || _error_quit "清理配置暂存文件失败"

if [ -n "$url" ]; then
    _config_atomic_write "$MIHOMO_CONFIG_URL" "$url" || _error_quit "保存订阅地址失败"
fi

_install_script_release false || _error_quit "安装管理脚本失败"
for resource_yaml in "$RESOURCES_BASE_DIR"/*.yaml; do
    [ -f "$resource_yaml" ] || continue
    [ "$resource_yaml" = "$RESOURCES_CONFIG" ] && continue
    cp "$resource_yaml" "$MIHOMO_BASE_DIR/" || _error_quit "安装配置资源失败：$resource_yaml"
done
_install_secure_mixin "$MIHOMO_CONFIG_MIXIN" ||
    _error_quit "生成本机 Web 控制台密钥失败"

# 解压 zashboard UI
if ! unzip -q -o "$ZIP_UI" -d "$MIHOMO_BASE_DIR"; then
    _error_quit "解压 UI 文件失败: $ZIP_UI"
fi
[ -d "${MIHOMO_BASE_DIR}/dist" ] || _error_quit "UI 压缩包中缺少 dist 目录"
mv "${MIHOMO_BASE_DIR}/dist" "${MIHOMO_BASE_DIR}/ui" || _error_quit "安装 UI 失败"

# 启动代理服务（会自动合并配置和检查端口冲突）
INSTALL_SERVICE_TOUCHED=true
mihomoctl on || _error_quit "mihomo 启动失败，安装已回滚"

# 最后才发布 shell 入口。此时所有大文件、配置和服务均已就绪，避免
# 后续安装失败时留下指向已删除目录的 RC 行。
INSTALL_RC_TOUCHED=true
_set_rc || _error_quit "写入 shell 配置失败"

# 显示 Web UI 信息（启动后显示实际端口）
clashui

INSTALL_OWNS_BASE=false
_upgrade_release_lock
INSTALL_LOCK_HELD=false
MIHOMO_OPERATION_LOCK_HELD=false

_okcat '🎉' 'mihomo 用户空间代理已安装完成！'
_okcat '📝' '使用说明：'
_okcat '💡' '命令前缀: clash | mihomo | mihomoctl'
_okcat '  • 开启/关闭: clash on/off'
_okcat '  • 重启服务: clash restart'
_okcat '  • 查看状态: clash status'
_okcat '  • Web控制台: clash ui'
_okcat '  • TUI控制台: clash tui'
_okcat '  • 更新订阅: clash update [URL|log]'
_okcat '  • 设置订阅: clash subscribe [URL]'
_okcat '  • 升级内核: clash upgrade'
_okcat '  • 回滚内核: clash upgrade rollback'
_okcat '  • 系统代理: clash proxy [on|off|status]'
_okcat '  • 局域网访问: clash lan [on|off|status]'
_okcat ''
_okcat '🏠' "安装目录: $MIHOMO_BASE_DIR"
_okcat '📁' "配置目录: $MIHOMO_BASE_DIR/config/"
_okcat '📋' "日志目录: $MIHOMO_BASE_DIR/logs/"

_quit
