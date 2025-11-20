#!/bin/bash
# =========================================
# 作者: jinqians
# 日期: 2025年2月
# 网站：jinqians.com
# 描述: 这个脚本用于安装、卸载、查看和更新 Snell 代理
# =========================================

# 定义颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# 系统/包管理器相关变量
PACKAGE_MANAGER=""
APT_UPDATED=false
PACMAN_DB_UPDATED=false
SNELL_USER="nobody"
SNELL_GROUP="nogroup"
IPTABLES_RULES_PATH="/etc/iptables/rules.v4"

# 检测包管理器
detect_package_manager() {
    if [ -n "$PACKAGE_MANAGER" ]; then
        return 0
    fi

    if command -v apt >/dev/null 2>&1; then
        PACKAGE_MANAGER="apt"
    elif command -v yum >/dev/null 2>&1; then
        PACKAGE_MANAGER="yum"
    elif command -v pacman >/dev/null 2>&1; then
        PACKAGE_MANAGER="pacman"
    else
        echo -e "${RED}未检测到受支持的包管理器 (apt/yum/pacman)。${RESET}"
        return 1
    fi
}

# 通用依赖安装函数
install_packages() {
    local packages=("$@")
    if [ ${#packages[@]} -eq 0 ]; then
        return 0
    fi

    if ! detect_package_manager; then
        return 1
    fi

    case "$PACKAGE_MANAGER" in
        apt)
            wait_for_apt
            if [ "$APT_UPDATED" = false ]; then
                apt update || return 1
                APT_UPDATED=true
            fi
            DEBIAN_FRONTEND=noninteractive apt install -y "${packages[@]}"
            ;;
        yum)
            yum install -y "${packages[@]}"
            ;;
        pacman)
            if [ "$PACMAN_DB_UPDATED" = false ]; then
                pacman -Sy --noconfirm || return 1
                PACMAN_DB_UPDATED=true
            fi
            pacman -S --noconfirm --needed "${packages[@]}"
            ;;
        *)
            echo -e "${RED}未知的包管理器，无法安装依赖。${RESET}"
            return 1
            ;;
    esac
}

# 设置运行用户和用户组
set_service_user_group() {
    SNELL_USER="nobody"
    SNELL_GROUP="nogroup"

    if command -v getent >/dev/null 2>&1; then
        if ! getent group "$SNELL_GROUP" >/dev/null 2>&1; then
            if getent group "$SNELL_USER" >/dev/null 2>&1; then
                SNELL_GROUP="$SNELL_USER"
            else
                SNELL_GROUP="root"
            fi
        fi
    else
        SNELL_GROUP="$SNELL_USER"
    fi
}

# 根据系统推断 iptables 规则文件路径
determine_iptables_rules_path() {
    if command -v pacman >/dev/null 2>&1; then
        IPTABLES_RULES_PATH="/etc/iptables/iptables.rules"
    elif [ -f "/etc/sysconfig/iptables" ]; then
        IPTABLES_RULES_PATH="/etc/sysconfig/iptables"
    else
        IPTABLES_RULES_PATH="/etc/iptables/rules.v4"
    fi
}

is_numeric() {
    case "$1" in
        ''|*[!0-9]*)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

set_service_user_group
determine_iptables_rules_path

# 静默安装参数默认值
AUTO_INSTALL=false
AUTO_UNINSTALL=false
AUTO_UNINSTALL_PORT=""
AUTO_UPDATE=false
AUTO_PORT=""
AUTO_PSK=""
AUTO_IPV6="false"
AUTO_DNS_DEFAULT="1.1.1.1,1.0.0.1,8.8.8.8,8.8.4.4"
AUTO_DNS="$AUTO_DNS_DEFAULT"

#当前版本号
current_version="4.6"

# 全局变量：选择的 Snell 版本
SNELL_VERSION_CHOICE="v5"
SNELL_VERSION=""

# === 新增：版本选择函数 ===
# 选择 Snell 版本
select_snell_version() {
    SNELL_VERSION_CHOICE="v5"
    if [ "$AUTO_INSTALL" = true ]; then
        echo -e "${GREEN}静默模式：Snell v5 已默认启用，并且兼容 v4 客户端配置。${RESET}"
    else
        echo -e "${GREEN}Snell v5 与 v4 客户端兼容，已默认选择 Snell v5。${RESET}"
    fi
}

# 获取 Snell v4 最新版本
get_latest_snell_v4_version() {
    latest_version=$(curl -s https://manual.nssurge.com/others/snell.html | grep -oP 'snell-server-v\K4\.[0-9]+\.[0-9]+' | head -n 1)
    if [ -z "$latest_version" ]; then
        latest_version=$(curl -s https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell | grep -oP 'snell-server-v\K4\.[0-9]+\.[0-9]+' | head -n 1)
    fi
    if [ -n "$latest_version" ]; then
        echo "v${latest_version}"
    else
        echo "v4.1.1"
    fi
}

# 获取 Snell v5 最新版本
get_latest_snell_v5_version() {
    # 先抓 beta 版
    v5_beta=$(curl -s https://manual.nssurge.com/others/snell.html | grep -oP 'snell-server-v\K5\.[0-9]+\.[0-9]+b[0-9]+' | head -n 1)
    if [ -z "$v5_beta" ]; then
        v5_beta=$(curl -s https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell | grep -oP 'snell-server-v\K5\.[0-9]+\.[0-9]+b[0-9]+' | head -n 1)
    fi
    if [ -n "$v5_beta" ]; then
        echo "v${v5_beta}"
        return
    fi
    # 再抓正式版，过滤掉带 b 的 beta 版本
    v5_release=$(curl -s https://manual.nssurge.com/others/snell.html | grep -oP 'snell-server-v\K5\.[0-9]+\.[0-9]+[a-z0-9]*' | grep -v b | head -n 1)
    if [ -z "$v5_release" ]; then
        v5_release=$(curl -s https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell | grep -oP 'snell-server-v\K5\.[0-9]+\.[0-9]+[a-z0-9]*' | grep -v b | head -n 1)
    fi
    if [ -n "$v5_release" ]; then
        echo "v${v5_release}"
    else
        echo "v5.0.0"
    fi
}

# 获取 Snell 最新版本（根据选择的版本）
get_latest_snell_version() {
    if [ "$SNELL_VERSION_CHOICE" = "v5" ]; then
        SNELL_VERSION=$(get_latest_snell_v5_version)
    else
        SNELL_VERSION=$(get_latest_snell_v4_version)
    fi
}

# 获取 Snell 下载 URL
get_snell_download_url() {
    local version=$1
    local arch=$(uname -m)

    if [ "$version" = "v5" ]; then
        # v5 版本自动拼接下载链接
        case ${arch} in
            "x86_64"|"amd64")
                echo "https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-amd64.zip"
                ;;
            "i386"|"i686")
                echo "https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-i386.zip"
                ;;
            "aarch64"|"arm64")
                echo "https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-aarch64.zip"
                ;;
            "armv7l"|"armv7")
                echo "https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-armv7l.zip"
                ;;
            *)
                echo -e "${RED}不支持的架构: ${arch}${RESET}"
                exit 1
                ;;
        esac
    else
        # v4 版本使用 zip 格式
        case ${arch} in
            "x86_64"|"amd64")
                echo "https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-amd64.zip"
                ;;
            "i386"|"i686")
                echo "https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-i386.zip"
                ;;
            "aarch64"|"arm64")
                echo "https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-aarch64.zip"
                ;;
            "armv7l"|"armv7")
                echo "https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-armv7l.zip"
                ;;
            *)
                echo -e "${RED}不支持的架构: ${arch}${RESET}"
                exit 1
                ;;
        esac
    fi
}

print_usage() {
    cat <<'EOF'
用法: ./snell.sh [选项]
  --silent-install        静默安装 Snell v5（兼容 v4 客户端，无需交互）
  --silent-uninstall      静默卸载 Snell（无需交互）
  --silent-update         静默更新 Snell v5（无需交互）
  --uninstall-port <端口> 静默卸载指定端口的 Snell 服务
  --port <端口>           设置 Snell 监听端口（必填，静默模式）
  --psk <密钥>            设置 Snell PSK（省略则自动生成）
  --ipv6 <true|false>     设置 IPv6 开关，静默模式默认 false
  --dns <dns列表>         自定义 DNS，默认 1.1.1.1,1.0.0.1,8.8.8.8,8.8.4.4
  -h, --help              显示此帮助信息
EOF
}

parse_arguments() {
    local positional=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --silent-install|--auto-install)
                AUTO_INSTALL=true
                shift
                ;;
            --silent-uninstall|--auto-uninstall)
                AUTO_UNINSTALL=true
                shift
                ;;
            --silent-update|--auto-update)
                AUTO_UPDATE=true
                shift
                ;;
            --port)
                AUTO_PORT="$2"
                shift 2
                ;;
            --psk)
                AUTO_PSK="$2"
                shift 2
                ;;
            --uninstall-port)
                AUTO_UNINSTALL_PORT="$2"
                shift 2
                ;;
            --ipv6)
                AUTO_IPV6="$(echo "$2" | tr '[:upper:]' '[:lower:]')"
                shift 2
                ;;
            --dns)
                AUTO_DNS="$2"
                shift 2
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            --)
                shift
                break
                ;;
            *)
                positional+=("$1")
                shift
                ;;
        esac
    done

    if [ "$AUTO_INSTALL" = true ]; then
        if [ -z "$AUTO_PORT" ]; then
            echo -e "${RED}静默安装需要指定 --port 参数。${RESET}"
            exit 1
        fi
        if ! is_numeric "$AUTO_PORT" || [ "$AUTO_PORT" -lt 1 ] || [ "$AUTO_PORT" -gt 65535 ]; then
            echo -e "${RED}端口号必须在 1-65535 之间。${RESET}"
            exit 1
        fi
        case "$AUTO_IPV6" in
            true|false) ;;
            *)
                echo -e "${RED}--ipv6 仅支持 true 或 false。${RESET}"
                exit 1
                ;;
        esac
        if [ -z "$AUTO_DNS" ]; then
            AUTO_DNS="$AUTO_DNS_DEFAULT"
        fi
    fi

    if [ -n "$AUTO_UNINSTALL_PORT" ]; then
        if ! is_numeric "$AUTO_UNINSTALL_PORT" || [ "$AUTO_UNINSTALL_PORT" -lt 1 ] || [ "$AUTO_UNINSTALL_PORT" -gt 65535 ]; then
            echo -e "${RED}--uninstall-port 参数必须是 1-65535 之间的端口号。${RESET}"
            exit 1
        fi
    fi

    if [ "$AUTO_INSTALL" = true ] && { [ "$AUTO_UNINSTALL" = true ] || [ -n "$AUTO_UNINSTALL_PORT" ]; }; then
        echo -e "${RED}不能同时执行安装与卸载操作。${RESET}"
        exit 1
    fi
    if [ "$AUTO_UNINSTALL" = true ] && [ -n "$AUTO_UNINSTALL_PORT" ]; then
        echo -e "${RED}不能同时卸载全部和卸载指定端口。${RESET}"
        exit 1
    fi
    if [ "$AUTO_UPDATE" = true ] && { [ "$AUTO_INSTALL" = true ] || [ "$AUTO_UNINSTALL" = true ] || [ -n "$AUTO_UNINSTALL_PORT" ]; }; then
        echo -e "${RED}静默更新不能与安装/卸载操作同时执行。${RESET}"
        exit 1
    fi

    if [ ${#positional[@]} -gt 0 ]; then
        set -- "${positional[@]}"
    fi
}

# 生成 Surge 配置格式
generate_surge_config() {
    local ip_addr=$1
    local port=$2
    local psk=$3
    local version=$4
    local country=$5
    local installed_version=$6   # 新增参数

    if [ "$installed_version" = "v5" ]; then
        # v5 版本输出 v4 和 v5 两种配置
        echo -e "${GREEN}${country} = snell, ${ip_addr}, ${port}, psk = ${psk}, version = 4, reuse = true, tfo = true${RESET}"
        echo -e "${GREEN}${country} = snell, ${ip_addr}, ${port}, psk = ${psk}, version = 5, reuse = true, tfo = true${RESET}"
    else
        # v4 版本只输出 v4 配置
        echo -e "${GREEN}${country} = snell, ${ip_addr}, ${port}, psk = ${psk}, version = 4, reuse = true, tfo = true${RESET}"
    fi
}

# 检测当前安装的 Snell 版本
detect_installed_snell_version() {
    if command -v snell-server &> /dev/null; then
        # 尝试获取版本信息
        local version_output=$(snell-server --v 2>&1)
        if echo "$version_output" | grep -q "v5"; then
            echo "v5"
        else
            echo "v4"
        fi
    else
        echo "unknown"
    fi
}

print_install_summary() {
    local port="$1"
    local psk="$2"
    local ipv6="$3"
    local dns="$4"
    local version_choice="${5:-$SNELL_VERSION_CHOICE}"

    echo -e "\n${GREEN}安装完成！以下是您的配置信息：${RESET}"
    echo -e "${CYAN}--------------------------------${RESET}"
    echo -e "${YELLOW}监听端口: ${port}${RESET}"
    echo -e "${YELLOW}PSK 密钥: ${psk}${RESET}"
    echo -e "${YELLOW}IPv6: ${ipv6}${RESET}"
    echo -e "${YELLOW}DNS 服务器: ${dns}${RESET}"
    echo -e "${CYAN}--------------------------------${RESET}"

    echo -e "\n${GREEN}服务器地址信息：${RESET}"
    local ipv4_addr ipv6_addr ip_country_ipv4 ip_country_ipv6

    ipv4_addr=$(curl -s4 https://api.ipify.org)
    if [ $? -eq 0 ] && [ -n "$ipv4_addr" ]; then
        ip_country_ipv4=$(curl -s http://ipinfo.io/${ipv4_addr}/country)
        echo -e "${GREEN}IPv4 地址: ${RESET}${ipv4_addr} ${GREEN}所在国家: ${RESET}${ip_country_ipv4}"
    fi

    ipv6_addr=$(curl -s6 https://api64.ipify.org)
    if [ $? -eq 0 ] && [ -n "$ipv6_addr" ]; then
        ip_country_ipv6=$(curl -s https://ipapi.co/${ipv6_addr}/country/)
        echo -e "${GREEN}IPv6 地址: ${RESET}${ipv6_addr} ${GREEN}所在国家: ${RESET}${ip_country_ipv6}"
    fi

    echo -e "\n${GREEN}Surge 配置格式：${RESET}"
    local installed_version
    installed_version=$(detect_installed_snell_version)
    if [ -n "$ipv4_addr" ]; then
        generate_surge_config "$ipv4_addr" "$port" "$psk" "$version_choice" "$ip_country_ipv4" "$installed_version"
    fi
    if [ -n "$ipv6_addr" ]; then
        generate_surge_config "$ipv6_addr" "$port" "$psk" "$version_choice" "$ip_country_ipv6" "$installed_version"
    fi
}

# === 新增：备份和还原配置函数 ===
# 备份 Snell 配置
backup_snell_config() {
    local backup_dir="/etc/snell/backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    cp -a /etc/snell/users/*.conf "$backup_dir"/ 2>/dev/null
    echo "$backup_dir"
}

# 恢复 Snell 配置
restore_snell_config() {
    local backup_dir="$1"
    if [ -d "$backup_dir" ]; then
        cp -a "$backup_dir"/*.conf /etc/snell/users/
        echo -e "${GREEN}配置已从备份恢复。${RESET}"
    else
        echo -e "${RED}未找到备份目录，无法恢复配置。${RESET}"
    fi
}

# 检查 bc 是否安装
check_bc() {
    if ! command -v bc &> /dev/null; then
        echo -e "${YELLOW}未检测到 bc，正在安装...${RESET}"
        if ! install_packages bc; then
            echo -e "${RED}安装 bc 失败，请手动安装后重试。${RESET}"
            exit 1
        fi
    fi
}

# 检查 curl 是否安装
check_curl() {
    if ! command -v curl &> /dev/null; then
        echo -e "${YELLOW}未检测到 curl，正在安装...${RESET}"
        if ! install_packages curl; then
            echo -e "${RED}安装 curl 失败，请手动安装后重试。${RESET}"
            exit 1
        fi
    fi
}

# 定义系统路径
INSTALL_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
SNELL_CONF_DIR="/etc/snell"
SNELL_CONF_FILE="${SNELL_CONF_DIR}/users/snell-main.conf"
SYSTEMD_SERVICE_FILE="${SYSTEMD_DIR}/snell.service"

# 旧的配置文件路径（用于兼容性检查）
OLD_SNELL_CONF_FILE="${SNELL_CONF_DIR}/snell-server.conf"
OLD_SYSTEMD_SERVICE_FILE="/lib/systemd/system/snell.service"

# 检查并迁移旧配置
check_and_migrate_config() {
    local need_migration=false
    local old_files_exist=false

    # 检查旧的配置文件是否存在
    if [ -f "$OLD_SNELL_CONF_FILE" ] || [ -f "$OLD_SYSTEMD_SERVICE_FILE" ]; then
        old_files_exist=true
        echo -e "\n${YELLOW}检测到旧版本的 Snell 配置文件${RESET}"
        echo -e "旧配置位置："
        [ -f "$OLD_SNELL_CONF_FILE" ] && echo -e "- 配置文件：${OLD_SNELL_CONF_FILE}"
        [ -f "$OLD_SYSTEMD_SERVICE_FILE" ] && echo -e "- 服务文件：${OLD_SYSTEMD_SERVICE_FILE}"

        # 检查用户目录是否存在
        if [ ! -d "${SNELL_CONF_DIR}/users" ]; then
            need_migration=true
            mkdir -p "${SNELL_CONF_DIR}/users"
            # 设置正确的目录权限
            chown -R "${SNELL_USER}:${SNELL_GROUP}" "${SNELL_CONF_DIR}"
            chmod -R 755 "${SNELL_CONF_DIR}"
        fi
    fi

    # 如果需要迁移，询问用户
    if [ "$old_files_exist" = true ]; then
        if [ "$AUTO_INSTALL" = true ] || [ "$AUTO_UNINSTALL" = true ]; then
            echo -e "${YELLOW}检测到旧 Snell 配置，静默模式默认跳过迁移，请手动处理。${RESET}"
            return
        fi
        echo -e "\n${YELLOW}是否要迁移旧的配置文件？[y/N]${RESET}"
        read -r choice
        if [ "$choice" = "y" ] || [ "$choice" = "Y" ]; then
            echo -e "${CYAN}开始迁移配置文件...${RESET}"

            # 停止服务
            systemctl stop snell 2>/dev/null

            # 迁移配置文件
            if [ -f "$OLD_SNELL_CONF_FILE" ]; then
                cp "$OLD_SNELL_CONF_FILE" "${SNELL_CONF_FILE}"
                # 设置正确的文件权限
                chown "${SNELL_USER}:${SNELL_GROUP}" "${SNELL_CONF_FILE}"
                chmod 644 "${SNELL_CONF_FILE}"
                echo -e "${GREEN}已迁移配置文件${RESET}"
            fi

            # 迁移服务文件
            if [ -f "$OLD_SYSTEMD_SERVICE_FILE" ]; then
                # 更新服务文件中的配置文件路径
                sed -e "s|${OLD_SNELL_CONF_FILE}|${SNELL_CONF_FILE}|g" "$OLD_SYSTEMD_SERVICE_FILE" > "$SYSTEMD_SERVICE_FILE"
                chmod 644 "$SYSTEMD_SERVICE_FILE"
                echo -e "${GREEN}已迁移服务文件${RESET}"
            fi

            # 询问是否删除旧文件
            echo -e "${YELLOW}是否删除旧的配置文件？[y/N]${RESET}"
            read -r del_choice
            if [ "$del_choice" = "y" ] || [ "$del_choice" = "Y" ]; then
                [ -f "$OLD_SNELL_CONF_FILE" ] && rm -f "$OLD_SNELL_CONF_FILE"
                [ -f "$OLD_SYSTEMD_SERVICE_FILE" ] && rm -f "$OLD_SYSTEMD_SERVICE_FILE"
                echo -e "${GREEN}已删除旧的配置文件${RESET}"
            fi

            # 重新加载服务
            systemctl daemon-reload
            systemctl start snell

            # 验证服务状态
            if systemctl is-active --quiet snell; then
                echo -e "${GREEN}配置迁移完成，服务已成功启动${RESET}"
            else
                echo -e "${RED}警告：服务启动失败，请检查配置文件和权限${RESET}"
                systemctl status snell
            fi
        else
            echo -e "${YELLOW}跳过配置迁移${RESET}"
        fi
    fi
}

# 自动更新脚本
auto_update_script() {
    echo -e "${CYAN}正在检查脚本更新...${RESET}"

    # 创建临时文件
    TMP_SCRIPT=$(mktemp)

    # 下载最新版本
    if curl -sL https://raw.githubusercontent.com/jinqians/snell.sh/main/snell.sh -o "$TMP_SCRIPT"; then
        # 获取新版本号
        new_version=$(grep "current_version=" "$TMP_SCRIPT" | cut -d'"' -f2)

        # 比较版本号
        if [ "$new_version" != "$current_version" ]; then
            echo -e "${GREEN}发现新版本：${new_version}${RESET}"
            echo -e "${YELLOW}当前版本：${current_version}${RESET}"

            # 备份当前脚本
            cp "$0" "${0}.backup"

            # 更新脚本
            mv "$TMP_SCRIPT" "$0"
            chmod +x "$0"

            echo -e "${GREEN}脚本已更新到最新版本${RESET}"
            echo -e "${YELLOW}已备份原脚本到：${0}.backup${RESET}"

            # 提示用户重新运行脚本
            echo -e "${CYAN}请重新运行脚本以使用新版本${RESET}"
            exit 0
        else
            echo -e "${GREEN}当前已是最新版本 (${current_version})${RESET}"
            rm -f "$TMP_SCRIPT"
        fi
    else
        echo -e "${RED}检查更新失败，请检查网络连接${RESET}"
        rm -f "$TMP_SCRIPT"
    fi
}

# 等待其他 apt 进程完成
wait_for_apt() {
    while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
        echo -e "${YELLOW}等待其他 apt 进程完成...${RESET}"
        sleep 1
    done
}

# 检查是否以 root 权限运行
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}请以 root 权限运行此脚本.${RESET}"
        exit 1
    fi
}
parse_arguments "$@"
check_root

# 检查 jq 是否安装
check_jq() {
    if ! command -v jq &> /dev/null; then
        echo -e "${YELLOW}未检测到 jq，正在安装...${RESET}"
        if ! install_packages jq; then
            echo -e "${RED}安装 jq 失败，请手动安装后重试。${RESET}"
            exit 1
        fi
    fi
}
check_jq

# 检查 Snell 是否已安装
check_snell_installed() {
    if command -v snell-server &> /dev/null; then
        return 0
    else
        return 1
    fi
}

# 比较版本号
version_greater_equal() {
    local ver1=$1
    local ver2=$2

    # 移除 'v' 或 'V' 前缀，并转换为小写
    ver1=$(echo "${ver1#[vV]}" | tr '[:upper:]' '[:lower:]')
    ver2=$(echo "${ver2#[vV]}" | tr '[:upper:]' '[:lower:]')

    # 处理 beta 版本号（如 5.0.0b1, 5.0.0b2）
    # 将 beta 版本转换为可比较的格式
    ver1=$(echo "$ver1" | sed 's/b\([0-9]*\)/\.999\1/g')
    ver2=$(echo "$ver2" | sed 's/b\([0-9]*\)/\.999\1/g')

    # 将版本号分割为数组
    IFS='.' read -ra VER1 <<< "$ver1"
    IFS='.' read -ra VER2 <<< "$ver2"

    # 确保数组长度相等
    while [ ${#VER1[@]} -lt 4 ]; do
        VER1+=("0")
    done
    while [ ${#VER2[@]} -lt 4 ]; do
        VER2+=("0")
    done

    # 比较版本号
    for i in {0..3}; do
        local val1=${VER1[i]:-0}
        local val2=${VER2[i]:-0}

        # 如果是数字，直接比较
        if is_numeric "$val1" && is_numeric "$val2"; then
            if [ "$val1" -gt "$val2" ]; then
                return 0
            elif [ "$val1" -lt "$val2" ]; then
                return 1
            fi
        else
            # 如果是字符串（如 beta 版本），按字典序比较
            if [ "$val1" \> "$val2" ]; then
                return 0
            elif [ "$val1" \< "$val2" ]; then
                return 1
            fi
        fi
    done
    return 0
}

# 用户输入端口号，范围 1-65535
get_user_port() {
    if [ "$AUTO_INSTALL" = true ]; then
        PORT="$AUTO_PORT"
        echo -e "${GREEN}静默模式：使用端口 $PORT${RESET}"
        return
    fi
    while true; do
        read -rp "请输入要使用的端口号 (1-65535): " PORT
        if is_numeric "$PORT" && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; then
            echo -e "${GREEN}已选择端口: $PORT${RESET}"
            break
        else
            echo -e "${RED}无效端口号，请输入 1 到 65535 之间的数字。${RESET}"
        fi
    done
}

# 获取系统DNS
get_system_dns() {
    # 尝试从resolv.conf获取系统DNS
    if [ -f "/etc/resolv.conf" ]; then
        system_dns=$(grep -E '^nameserver' /etc/resolv.conf | awk '{print $2}' | tr '\n' ',' | sed 's/,$//')
        if [ ! -z "$system_dns" ]; then
            echo "$system_dns"
            return 0
        fi
    fi

    # 如果无法从resolv.conf获取，尝试使用公共DNS
    echo "1.1.1.1,8.8.8.8"
}

# 获取用户输入的 DNS 服务器
get_dns() {
    if [ "$AUTO_INSTALL" = true ]; then
        DNS="$AUTO_DNS"
        echo -e "${GREEN}静默模式：使用预设 DNS ${DNS}${RESET}"
        return
    fi
    read -rp "请输入 DNS 服务器地址 (直接回车使用系统DNS): " custom_dns
    if [ -z "$custom_dns" ]; then
        DNS=$(get_system_dns)
        echo -e "${GREEN}使用系统 DNS 服务器: $DNS${RESET}"
    else
        DNS=$custom_dns
        echo -e "${GREEN}使用自定义 DNS 服务器: $DNS${RESET}"
    fi
}

generate_random_psk() {
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20
}

# 开放端口 (ufw 和 iptables)
open_port() {
    local PORT=$1
    # 检查 ufw 是否已安装
    if command -v ufw &> /dev/null; then
        echo -e "${CYAN}在 UFW 中开放端口 $PORT${RESET}"
        ufw allow "$PORT"/tcp
    fi

    # 检查 iptables 是否已安装
    if command -v iptables &> /dev/null; then
        echo -e "${CYAN}在 iptables 中开放端口 $PORT${RESET}"
        iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT

        # 创建 iptables 规则保存目录（如果不存在）
        local rules_dir
        rules_dir=$(dirname "$IPTABLES_RULES_PATH")
        mkdir -p "$rules_dir"

        # 尝试保存规则，如果失败则不中断脚本
        iptables-save > "$IPTABLES_RULES_PATH" || true
    fi
}

remove_existing_port_config() {
    local target_port=$1
    local removed_any=false

    if [ -z "$target_port" ]; then
        return
    fi

    if [ -d "${SNELL_CONF_DIR}/users" ]; then
        for conf_file in "${SNELL_CONF_DIR}/users"/*.conf; do
            [ -f "$conf_file" ] || continue
            local conf_port
            conf_port=$(grep -E '^listen' "$conf_file" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
            if [ "$conf_port" = "$target_port" ]; then
                removed_any=true
                if [ "$conf_file" = "$SNELL_CONF_FILE" ]; then
                    systemctl stop snell 2>/dev/null
                    echo -e "${YELLOW}检测到主配置已使用端口 ${target_port}，即将覆盖。${RESET}"
                else
                    local svc_name="snell-${target_port}"
                    systemctl stop "$svc_name" 2>/dev/null
                    systemctl disable "$svc_name" 2>/dev/null
                    rm -f "${SYSTEMD_DIR}/${svc_name}.service"
                    rm -f "$conf_file"
                    echo -e "${YELLOW}已移除端口 ${target_port} 的多用户配置 ${conf_file}${RESET}"
                fi
            fi
        done
    fi

    if [ "$removed_any" = false ]; then
        echo -e "${CYAN}端口 ${target_port} 没有现有配置，将直接创建。${RESET}"
    fi
}

ensure_snell_binary_installed() {
    if command -v snell-server &> /dev/null; then
        return
    fi

    echo -e "${CYAN}未检测到 Snell 二进制，正在执行基础安装...${RESET}"

    SNELL_VERSION_CHOICE="v5"
    if [ -x "$(command -v apt)" ]; then
        wait_for_apt
        apt update >/dev/null 2>&1
        apt install -y wget unzip >/dev/null 2>&1
    elif [ -x "$(command -v yum)" ]; then
        yum install -y wget unzip >/dev/null 2>&1
    else
        echo -e "${RED}未检测到受支持的包管理器，无法安装依赖。${RESET}"
        exit 1
    fi

    get_latest_snell_version
    local SNELL_URL
    SNELL_URL=$(get_snell_download_url "$SNELL_VERSION_CHOICE")

    echo -e "${CYAN}下载 Snell ${SNELL_VERSION_CHOICE} (${SNELL_VERSION})...${RESET}"
    wget -q ${SNELL_URL} -O snell-server.zip
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载 Snell 失败，请检查网络连接。${RESET}"
        exit 1
    fi

    unzip -qo snell-server.zip -d ${INSTALL_DIR}
    if [ $? -ne 0 ]; then
        echo -e "${RED}解压 Snell 失败。${RESET}"
        exit 1
    fi

    rm -f snell-server.zip
    chmod +x ${INSTALL_DIR}/snell-server
    mkdir -p "${SNELL_CONF_DIR}/users"

    echo -e "${GREEN}Snell 二进制已准备完成。${RESET}"
}

ensure_control_script_installed() {
    if [ ! -x /usr/local/bin/snell ]; then
        install_control_script
    fi
}

silent_apply_port_config() {
    local target_port=$1
    local target_psk=$2
    local target_ipv6=$3
    local target_dns=$4

    mkdir -p "${SNELL_CONF_DIR}/users"

    local main_conf_exists=false
    local main_port=""
    if [ -f "${SNELL_CONF_FILE}" ]; then
        main_conf_exists=true
        main_port=$(grep -E '^listen' "${SNELL_CONF_FILE}" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
    fi

    if [ "$main_conf_exists" = true ] && [ "$target_port" = "$main_port" ]; then
        cat > ${SNELL_CONF_FILE} << EOF
[snell-server]
listen = ::0:${target_port}
psk = ${target_psk}
ipv6 = ${target_ipv6}
dns = ${target_dns}
EOF
        if systemctl list-unit-files | grep -q '^snell.service'; then
            systemctl restart snell
        fi
        open_port "$target_port"
        echo -e "${GREEN}已更新主 Snell 服务 (端口 ${target_port}) 的配置。${RESET}"
        echo -e "${YELLOW}PSK: ${target_psk}${RESET}"
        echo -e "${YELLOW}IPv6: ${target_ipv6}${RESET}"
        echo -e "${YELLOW}DNS: ${target_dns}${RESET}"
        return 0
    fi

    local user_conf="${SNELL_CONF_DIR}/users/snell-${target_port}.conf"
    local service_name="snell-${target_port}"
    local service_file="${SYSTEMD_DIR}/${service_name}.service"
    local existed=false
    if [ -f "$user_conf" ] || [ -f "$service_file" ]; then
        existed=true
    fi

    cat > "$user_conf" << EOF
[snell-server]
listen = ::0:${target_port}
psk = ${target_psk}
ipv6 = ${target_ipv6}
dns = ${target_dns}
EOF

    cat > "$service_file" << EOF
[Unit]
Description=Snell Proxy Service (Port ${target_port})
After=network.target

[Service]
Type=simple
User=nobody
Group=nogroup
LimitNOFILE=32768
ExecStart=${INSTALL_DIR}/snell-server -c ${user_conf}
AmbientCapabilities=CAP_NET_BIND_SERVICE
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=snell-server-${target_port}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$service_name" >/dev/null 2>&1
    systemctl restart "$service_name"
    open_port "$target_port"

    if [ "$existed" = true ]; then
        echo -e "${GREEN}已更新端口 ${target_port} 的 Snell 多用户配置。${RESET}"
    else
        echo -e "${GREEN}已新增端口 ${target_port} 的 Snell 多用户配置。${RESET}"
    fi
    echo -e "${YELLOW}PSK: ${target_psk}${RESET}"
    echo -e "${YELLOW}IPv6: ${target_ipv6}${RESET}"
    echo -e "${YELLOW}DNS: ${target_dns}${RESET}"
}

find_snell_conf_by_port() {
    local port=$1
    local search_dirs=()
    [ -d "${SNELL_CONF_DIR}" ] && search_dirs+=("${SNELL_CONF_DIR}")
    [ -d "${SNELL_CONF_DIR}/users" ] && search_dirs+=("${SNELL_CONF_DIR}/users")

    for dir in "${search_dirs[@]}"; do
        for conf_file in "$dir"/snell*.conf "$dir"/snell-server.conf; do
            [ -f "$conf_file" ] || continue
            local conf_port
            conf_port=$(grep -E '^listen' "$conf_file" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
            if [ "$conf_port" = "$port" ]; then
                echo "$conf_file"
                return 0
            fi
        done
    done
    return 1
}

uninstall_port_service() {
    local target_port=$1
    local quiet=${2:-false}

    if [ -z "$target_port" ]; then
        echo -e "${RED}未指定端口，无法卸载。${RESET}"
        return 1
    fi

    if ! is_numeric "$target_port" || [ "$target_port" -lt 1 ] || [ "$target_port" -gt 65535 ]; then
        echo -e "${RED}端口号必须在 1-65535 之间。${RESET}"
        return 1
    fi

    local target_conf
    if ! target_conf=$(find_snell_conf_by_port "$target_port"); then
        echo -e "${YELLOW}未找到端口 ${target_port} 对应的 Snell 配置文件。${RESET}"
        return 1
    fi

    local service_name="snell-${target_port}"
    local is_main=false
    if [ "$target_conf" = "$SNELL_CONF_FILE" ] || [ "$target_conf" = "${SNELL_CONF_DIR}/snell-main.conf" ] || [ "$target_conf" = "${SNELL_CONF_DIR}/snell-server.conf" ]; then
        is_main=true
        service_name="snell"
    fi

    systemctl stop "$service_name" 2>/dev/null
    systemctl disable "$service_name" 2>/dev/null
    rm -f "${SYSTEMD_DIR}/${service_name}.service" "/lib/systemd/system/${service_name}.service"
    rm -f "$target_conf"
    systemctl daemon-reload

    if [ "$is_main" = true ]; then
        echo -e "${GREEN}已移除主 Snell 服务 (端口 ${target_port}) 配置。${RESET}"
    else
        echo -e "${GREEN}已成功卸载端口 ${target_port} 的 Snell 服务。${RESET}"
    fi
    return 0
}

install_control_script() {
    echo -e "${CYAN}正在安装管理脚本...${RESET}"
    mkdir -p /usr/local/bin
    cat > /usr/local/bin/snell << 'EOFSCRIPT'
#!/bin/bash

# 定义颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# 检查是否以 root 权限运行
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}请以 root 权限运行此脚本${RESET}"
    exit 1
fi

# 下载并执行最新版本的脚本
echo -e "${CYAN}正在获取最新版本的管理脚本...${RESET}"
TMP_SCRIPT=$(mktemp)
if curl -sL https://raw.githubusercontent.com/jinqians/snell.sh/main/snell.sh -o "$TMP_SCRIPT"; then
    bash "$TMP_SCRIPT"
    rm -f "$TMP_SCRIPT"
else
    echo -e "${RED}下载脚本失败，请检查网络连接。${RESET}"
    rm -f "$TMP_SCRIPT"
    exit 1
fi
EOFSCRIPT

    if [ $? -eq 0 ]; then
        chmod +x /usr/local/bin/snell
        if [ $? -eq 0 ]; then
            echo -e "\n${GREEN}管理脚本安装成功！${RESET}"
            echo -e "${YELLOW}您可以在终端输入 'snell' 进入管理菜单。${RESET}"
            echo -e "${YELLOW}注意：需要使用 sudo snell 或以 root 身份运行。${RESET}\n"
        else
            echo -e "\n${RED}设置脚本执行权限失败。${RESET}"
            echo -e "${YELLOW}您可以通过直接运行原脚本来管理 Snell。${RESET}\n"
        fi
    else
        echo -e "\n${RED}创建管理脚本失败。${RESET}"
        echo -e "${YELLOW}您可以通过直接运行原脚本来管理 Snell。${RESET}\n"
    fi
}

# 安装 Snell
install_snell() {
    echo -e "${CYAN}正在安装 Snell${RESET}"

    if [ "$AUTO_INSTALL" = true ]; then
        ensure_snell_binary_installed

        PORT="$AUTO_PORT"
        DNS="$AUTO_DNS"
        PSK="$AUTO_PSK"
        IPV6_ENABLED="$AUTO_IPV6"

        if [ -z "$PSK" ]; then
            PSK=$(generate_random_psk)
            echo -e "${YELLOW}未指定 PSK，已自动生成随机密钥：${PSK}${RESET}"
        fi

        silent_apply_port_config "$PORT" "$PSK" "$IPV6_ENABLED" "$DNS"
        print_install_summary "$PORT" "$PSK" "$IPV6_ENABLED" "$DNS" "$SNELL_VERSION_CHOICE"
        ensure_control_script_installed
        return 0
    fi

    if check_snell_installed; then
        echo -e "${YELLOW}检测到系统已安装 Snell。${RESET}"
        echo -e "${CYAN}请选择操作：${RESET}"
        echo -e "${GREEN}1.${RESET} 重新安装并覆盖现有配置"
        echo -e "${GREEN}2.${RESET} 仅更新控制脚本"
        echo -e "${GREEN}3.${RESET} 取消${RESET}"
        while true; do
            read -rp "请选择 [1-3]: " reinstall_choice
            case "$reinstall_choice" in
                1|"")
                    echo -e "${YELLOW}将覆盖现有配置并重新安装。${RESET}"
                    break
                    ;;
                2)
                    install_control_script
                    echo -e "${GREEN}已更新控制脚本。${RESET}"
                    return 0
                    ;;
                3)
                    echo -e "${CYAN}已取消操作。${RESET}"
                    return 0
                    ;;
                *)
                    echo -e "${RED}请输入正确选项 [1-3]${RESET}"
                    ;;
            esac
        done
        systemctl stop snell 2>/dev/null
    fi

    # 选择 Snell 版本
    select_snell_version

    if ! install_packages wget unzip; then
        echo -e "${RED}安装 wget/unzip 失败，请手动安装依赖后重试。${RESET}"
        exit 1
    fi

    get_latest_snell_version
    ARCH=$(uname -m)
    SNELL_URL=$(get_snell_download_url "$SNELL_VERSION_CHOICE")

    echo -e "${CYAN}正在下载 Snell ${SNELL_VERSION_CHOICE} (${SNELL_VERSION})...${RESET}"
    echo -e "${YELLOW}下载链接: ${SNELL_URL}${RESET}"

    # v4 和 v5 版本都使用 zip 格式，统一处理
    wget ${SNELL_URL} -O snell-server.zip
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载 Snell ${SNELL_VERSION_CHOICE} 失败。${RESET}"
        exit 1
    fi

    unzip -o snell-server.zip -d ${INSTALL_DIR}
    if [ $? -ne 0 ]; then
        echo -e "${RED}解压缩 Snell 失败。${RESET}"
        exit 1
    fi

    rm snell-server.zip
    chmod +x ${INSTALL_DIR}/snell-server

    get_user_port  # 获取用户输入的端口
    remove_existing_port_config "$PORT"
    get_dns # 获取用户输入的 DNS 服务器
    PSK=$(generate_random_psk)
    IPV6_ENABLED="true"

    # 创建用户配置目录
    mkdir -p ${SNELL_CONF_DIR}/users

    # 将主用户配置存储在 users 目录下
    cat > ${SNELL_CONF_FILE} << EOF
[snell-server]
listen = ::0:${PORT}
psk = ${PSK}
ipv6 = ${IPV6_ENABLED}
dns = ${DNS}
EOF

    cat > ${SYSTEMD_SERVICE_FILE} << EOF
[Unit]
Description=Snell Proxy Service (Main)
After=network.target

[Service]
Type=simple
User=${SNELL_USER}
Group=${SNELL_GROUP}
LimitNOFILE=32768
ExecStart=${INSTALL_DIR}/snell-server -c ${SNELL_CONF_FILE}
AmbientCapabilities=CAP_NET_BIND_SERVICE
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=snell-server

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    if [ $? -ne 0 ]; then
        echo -e "${RED}重载 Systemd 配置失败。${RESET}"
        exit 1
    fi

    systemctl enable snell
    if [ $? -ne 0 ]; then
        echo -e "${RED}开机自启动 Snell 失败。${RESET}"
        exit 1
    fi

    systemctl start snell
    if [ $? -ne 0 ]; then
        echo -e "${RED}启动 Snell 服务失败。${RESET}"
        exit 1
    fi

    # 开放端口
    open_port "$PORT"

    print_install_summary "$PORT" "$PSK" "$IPV6_ENABLED" "$DNS" "$SNELL_VERSION_CHOICE"
    install_control_script
}

# 只更新 Snell 二进制文件，不覆盖配置
update_snell_binary() {
    echo -e "${CYAN}=============== Snell 更新 ===============${RESET}"
    echo -e "${YELLOW}注意：这是更新操作，不是重新安装${RESET}"
    echo -e "${GREEN}✓ 所有现有配置将被保留${RESET}"
    echo -e "${GREEN}✓ 端口、密码、用户配置都不会改变${RESET}"
    echo -e "${GREEN}✓ 服务会自动重启${RESET}"
    echo -e "${CYAN}============================================${RESET}"

    echo -e "${CYAN}正在备份当前配置...${RESET}"
    local backup_dir
    backup_dir=$(backup_snell_config)
    echo -e "${GREEN}配置已备份到: $backup_dir${RESET}"

    echo -e "${CYAN}正在更新 Snell 二进制文件...${RESET}"

    # 获取最新版本信息（版本已在 check_snell_update 中确定）
    get_latest_snell_version
    ARCH=$(uname -m)
    SNELL_URL=$(get_snell_download_url "$SNELL_VERSION_CHOICE")

    echo -e "${CYAN}正在下载 Snell ${SNELL_VERSION_CHOICE} (${SNELL_VERSION})...${RESET}"

    # v4 和 v5 版本都使用 zip 格式，统一处理
    wget ${SNELL_URL} -O snell-server.zip
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载 Snell ${SNELL_VERSION_CHOICE} 失败。${RESET}"
        restore_snell_config "$backup_dir"
        exit 1
    fi

    echo -e "${CYAN}正在替换 Snell 二进制文件...${RESET}"
    unzip -o snell-server.zip -d ${INSTALL_DIR}
    if [ $? -ne 0 ]; then
        echo -e "${RED}解压缩 Snell 失败。${RESET}"
        restore_snell_config "$backup_dir"
        exit 1
    fi

    rm snell-server.zip
    chmod +x ${INSTALL_DIR}/snell-server

    echo -e "${CYAN}正在重启 Snell 服务...${RESET}"
    # 重启主服务
    systemctl restart snell
    if [ $? -ne 0 ]; then
        echo -e "${RED}主服务重启失败，尝试恢复配置...${RESET}"
        restore_snell_config "$backup_dir"
        systemctl restart snell
    fi

    # 重启所有多用户服务
    if [ -d "${SNELL_CONF_DIR}/users" ]; then
        for user_conf in "${SNELL_CONF_DIR}/users"/*; do
            if [ -f "$user_conf" ]; then
                case "$user_conf" in
                    *snell-main.conf) continue ;;
                esac
                local port=$(grep -E '^listen' "$user_conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
                if [ ! -z "$port" ]; then
                    systemctl restart "snell-${port}" 2>/dev/null
                fi
            fi
        done
    fi

    echo -e "${CYAN}============================================${RESET}"
    echo -e "${GREEN}✅ Snell 更新完成！${RESET}"
    echo -e "${GREEN}✓ 版本已更新到: ${SNELL_VERSION_CHOICE} (${SNELL_VERSION})${RESET}"
    echo -e "${GREEN}✓ 所有配置已保留${RESET}"
    echo -e "${GREEN}✓ 服务已重启${RESET}"
    echo -e "${YELLOW}配置备份目录: $backup_dir${RESET}"
    echo -e "${CYAN}============================================${RESET}"
}

# 卸载 Snell
uninstall_snell() {
    echo -e "${CYAN}正在卸载 Snell${RESET}"

    if ! check_snell_installed && [ ! -d "${SNELL_CONF_DIR}" ]; then
        echo -e "${YELLOW}未检测到 Snell 安装，跳过卸载操作。${RESET}"
        return 0
    fi

    # 停止并禁用主服务
    if systemctl list-unit-files | grep -q '^snell.service'; then
        systemctl stop snell 2>/dev/null
        systemctl disable snell 2>/dev/null
    fi

    # 停止并禁用所有多用户服务
    if [ -d "${SNELL_CONF_DIR}/users" ]; then
        for user_conf in "${SNELL_CONF_DIR}/users"/*; do
            if [ -f "$user_conf" ]; then
                local port=$(grep -E '^listen' "$user_conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
                if [ ! -z "$port" ]; then
                    echo -e "${YELLOW}正在停止用户服务 (端口: $port)${RESET}"
                    systemctl stop "snell-${port}" 2>/dev/null
                    systemctl disable "snell-${port}" 2>/dev/null
                    rm -f "${SYSTEMD_DIR}/snell-${port}.service"
                fi
            fi
        done
    fi

    # 删除服务文件
    rm -f /lib/systemd/system/snell.service

    # 删除可执行文件和配置目录
    rm -f /usr/local/bin/snell-server
    rm -rf ${SNELL_CONF_DIR}
    rm -f /usr/local/bin/snell  # 删除管理脚本

    # 重载 systemd 配置
    systemctl daemon-reload

    echo -e "${GREEN}Snell 及其所有多用户配置已成功卸载${RESET}"
}

# 重启 Snell
restart_snell() {
    echo -e "${YELLOW}正在重启所有 Snell 服务...${RESET}"

    # 重启主服务
    systemctl restart snell
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}主 Snell 服务已成功重启。${RESET}"
    else
        echo -e "${RED}重启主 Snell 服务失败。${RESET}"
    fi

    # 重启所有多用户服务
    if [ -d "${SNELL_CONF_DIR}/users" ]; then
        for user_conf in "${SNELL_CONF_DIR}/users"/*; do
            if [ -f "$user_conf" ]; then
                case "$user_conf" in
                    *snell-main.conf) continue ;;
                esac
                local port=$(grep -E '^listen' "$user_conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
                if [ ! -z "$port" ]; then
                    echo -e "${YELLOW}正在重启用户服务 (端口: $port)${RESET}"
                    systemctl restart "snell-${port}" 2>/dev/null
                    if [ $? -eq 0 ]; then
                        echo -e "${GREEN}用户服务 (端口: $port) 已成功重启。${RESET}"
                    else
                        echo -e "${RED}重启用户服务 (端口: $port) 失败。${RESET}"
                    fi
                fi
            fi
        done
    fi
}
# 检查服务状态并显示
check_and_show_status() {
    echo -e "\n${CYAN}=============== 服务状态检查 ===============${RESET}"

    # 检查 Snell 状态
    if command -v snell-server &> /dev/null; then
        # 初始化计数器和资源使用变量
        local user_count=0
        local running_count=0
        local total_snell_memory=0
        local total_snell_cpu=0

        local main_service_exists=false
        if systemctl list-unit-files | grep -q '^snell.service'; then
            main_service_exists=true
        fi

        # 检查主服务状态
        if [ "$main_service_exists" = true ]; then
            if systemctl is-active snell &> /dev/null; then
                user_count=$((user_count + 1))
                running_count=$((running_count + 1))

                # 获取主服务资源使用情况
                local main_pid=$(systemctl show -p MainPID snell | cut -d'=' -f2)
                if [ ! -z "$main_pid" ] && [ "$main_pid" != "0" ]; then
                    local mem=$(ps -o rss= -p $main_pid 2>/dev/null)
                    local cpu=$(ps -o %cpu= -p $main_pid 2>/dev/null)
                    if [ ! -z "$mem" ]; then
                        total_snell_memory=$((total_snell_memory + mem))
                    fi
                    if [ ! -z "$cpu" ]; then
                        total_snell_cpu=$(echo "$total_snell_cpu + $cpu" | bc -l)
                    fi
                fi
            else
                user_count=$((user_count + 1))
            fi
        fi

        # 检查多用户状态
        if [ -d "${SNELL_CONF_DIR}/users" ]; then
        for user_conf in "${SNELL_CONF_DIR}/users"/*; do
            if [ -f "$user_conf" ]; then
                case "$user_conf" in
                    *snell-main.conf) continue ;;
                esac
                local port=$(grep -E '^listen' "$user_conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
                if [ ! -z "$port" ]; then
                        user_count=$((user_count + 1))
                        if systemctl is-active --quiet "snell-${port}"; then
                            running_count=$((running_count + 1))

                            # 获取用户服务资源使用情况
                            local user_pid=$(systemctl show -p MainPID "snell-${port}" | cut -d'=' -f2)
                            if [ ! -z "$user_pid" ] && [ "$user_pid" != "0" ]; then
                                local mem=$(ps -o rss= -p $user_pid 2>/dev/null)
                                local cpu=$(ps -o %cpu= -p $user_pid 2>/dev/null)
                                if [ ! -z "$mem" ]; then
                                    total_snell_memory=$((total_snell_memory + mem))
                                fi
                                if [ ! -z "$cpu" ]; then
                                    total_snell_cpu=$(echo "$total_snell_cpu + $cpu" | bc -l)
                                fi
                            fi
                        fi
                    fi
                fi
            done
        fi

        # 显示 Snell 状态
        local total_snell_memory_mb=$(echo "scale=2; $total_snell_memory/1024" | bc)
        printf "${GREEN}Snell 已安装${RESET}  ${YELLOW}CPU：%.2f%%${RESET}  ${YELLOW}内存：%.2f MB${RESET}  ${GREEN}运行中：${running_count}/${user_count}${RESET}\n" "$total_snell_cpu" "$total_snell_memory_mb"
    else
        echo -e "${YELLOW}Snell 未安装${RESET}"
    fi

    # 检查 ShadowTLS 状态
    if [ -f "/usr/local/bin/shadow-tls" ]; then
        # 初始化 ShadowTLS 服务计数器和资源使用
        local stls_total=0
        local stls_running=0
        local total_stls_memory=0
        local total_stls_cpu=0
        declare -A processed_ports

        # 检查 Snell 的 ShadowTLS 服务
        local snell_services=$(find /etc/systemd/system -name "shadowtls-snell-*.service" 2>/dev/null | sort -u)
        if [ ! -z "$snell_services" ]; then
            while IFS= read -r service_file; do
                local port=$(basename "$service_file" | sed 's/shadowtls-snell-\([0-9]*\)\.service/\1/')

                # 检查是否已处理过该端口
                if [ -z "${processed_ports[$port]}" ]; then
                    processed_ports[$port]=1
                    stls_total=$((stls_total + 1))
                    if systemctl is-active "shadowtls-snell-${port}" &> /dev/null; then
                        stls_running=$((stls_running + 1))

                        # 获取 ShadowTLS 服务资源使用情况
                        local stls_pid=$(systemctl show -p MainPID "shadowtls-snell-${port}" | cut -d'=' -f2)
                        if [ ! -z "$stls_pid" ] && [ "$stls_pid" != "0" ]; then
                            local mem=$(ps -o rss= -p $stls_pid 2>/dev/null)
                            local cpu=$(ps -o %cpu= -p $stls_pid 2>/dev/null)
                            if [ ! -z "$mem" ]; then
                                total_stls_memory=$((total_stls_memory + mem))
                            fi
                            if [ ! -z "$cpu" ]; then
                                total_stls_cpu=$(echo "$total_stls_cpu + $cpu" | bc -l)
                            fi
                        fi
                    fi
                fi
            done <<< "$snell_services"
        fi

        # 显示 ShadowTLS 状态
        if [ $stls_total -gt 0 ]; then
            local total_stls_memory_mb=$(echo "scale=2; $total_stls_memory/1024" | bc)
            printf "${GREEN}ShadowTLS 已安装${RESET}  ${YELLOW}CPU：%.2f%%${RESET}  ${YELLOW}内存：%.2f MB${RESET}  ${GREEN}运行中：${stls_running}/${stls_total}${RESET}\n" "$total_stls_cpu" "$total_stls_memory_mb"
        else
            echo -e "${YELLOW}ShadowTLS 未安装${RESET}"
        fi
    else
        echo -e "${YELLOW}ShadowTLS 未安装${RESET}"
    fi

    echo -e "${CYAN}============================================${RESET}\n"
}

# 查看配置
view_snell_config() {
    echo -e "${GREEN}Snell 配置信息:${RESET}"
    echo -e "${CYAN}================================${RESET}"

    # 检测当前安装的 Snell 版本
    local installed_version=$(detect_installed_snell_version)
    if [ "$installed_version" != "unknown" ]; then
        echo -e "${YELLOW}当前安装版本: Snell ${installed_version}${RESET}"
    fi

    # 获取 IPv4 地址
    IPV4_ADDR=$(curl -s4 https://api.ipify.org)
    if [ $? -eq 0 ] && [ ! -z "$IPV4_ADDR" ]; then
        IP_COUNTRY_IPV4=$(curl -s http://ipinfo.io/${IPV4_ADDR}/country)
        echo -e "${GREEN}IPv4 地址: ${RESET}${IPV4_ADDR} ${GREEN}所在国家: ${RESET}${IP_COUNTRY_IPV4}"
    fi

    # 获取 IPv6 地址
    IPV6_ADDR=$(curl -s6 https://api64.ipify.org)
    if [ $? -eq 0 ] && [ ! -z "$IPV6_ADDR" ]; then
        IP_COUNTRY_IPV6=$(curl -s https://ipapi.co/${IPV6_ADDR}/country/)
        echo -e "${GREEN}IPv6 地址: ${RESET}${IPV6_ADDR} ${GREEN}所在国家: ${RESET}${IP_COUNTRY_IPV6}"
    fi

    # 检查是否获取到 IP 地址
    if [ -z "$IPV4_ADDR" ] && [ -z "$IPV6_ADDR" ]; then
        echo -e "${RED}无法获取到公网 IP 地址，请检查网络连接。${RESET}"
        return
    fi

    echo -e "\n${YELLOW}=== 用户配置列表 ===${RESET}"

    # 显示主用户配置
    local main_conf="${SNELL_CONF_DIR}/users/snell-main.conf"
    if [ -f "$main_conf" ]; then
        echo -e "\n${GREEN}主用户配置：${RESET}"
        local main_port=$(grep -E '^listen' "$main_conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
        local main_psk=$(grep -E '^psk' "$main_conf" | awk -F'=' '{print $2}' | tr -d ' ')
        local main_ipv6=$(grep -E '^ipv6' "$main_conf" | awk -F'=' '{print $2}' | tr -d ' ')
        local main_dns=$(grep -E '^dns' "$main_conf" | awk -F'=' '{print $2}' | tr -d ' ')

        echo -e "${YELLOW}端口: ${main_port}${RESET}"
        echo -e "${YELLOW}PSK: ${main_psk}${RESET}"
        echo -e "${YELLOW}IPv6: ${main_ipv6}${RESET}"
        echo -e "${YELLOW}DNS: ${main_dns}${RESET}"

        echo -e "\n${GREEN}Surge 配置格式：${RESET}"
        if [ ! -z "$IPV4_ADDR" ]; then
            generate_surge_config "$IPV4_ADDR" "$main_port" "$main_psk" "$installed_version" "$IP_COUNTRY_IPV4" "$installed_version"
        fi
        if [ ! -z "$IPV6_ADDR" ]; then
            generate_surge_config "$IPV6_ADDR" "$main_port" "$main_psk" "$installed_version" "$IP_COUNTRY_IPV6" "$installed_version"
        fi
    fi

    # 显示其他用户配置
    if [ -d "${SNELL_CONF_DIR}/users" ]; then
        for user_conf in "${SNELL_CONF_DIR}/users"/*; do
            if [ -f "$user_conf" ]; then
                case "$user_conf" in
                    *snell-main.conf) continue ;;
                esac
                local user_port=$(grep -E '^listen' "$user_conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
                local user_psk=$(grep -E '^psk' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
                local user_ipv6=$(grep -E '^ipv6' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
                local user_dns=$(grep -E '^dns' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')

                echo -e "\n${GREEN}用户配置 (端口: ${user_port}):${RESET}"
                echo -e "${YELLOW}PSK: ${user_psk}${RESET}"
                echo -e "${YELLOW}IPv6: ${user_ipv6}${RESET}"
                echo -e "${YELLOW}DNS: ${user_dns}${RESET}"

                echo -e "\n${GREEN}Surge 配置格式：${RESET}"
                if [ ! -z "$IPV4_ADDR" ]; then
                    generate_surge_config "$IPV4_ADDR" "$user_port" "$user_psk" "$installed_version" "$IP_COUNTRY_IPV4" "$installed_version"
                fi
                if [ ! -z "$IPV6_ADDR" ]; then
                    generate_surge_config "$IPV6_ADDR" "$user_port" "$user_psk" "$installed_version" "$IP_COUNTRY_IPV6" "$installed_version"
                fi
            fi
        done
    fi

    # 如果 ShadowTLS 已安装，显示组合配置
    local snell_version=$(detect_installed_snell_version)
    local snell_services=$(find /etc/systemd/system -name "shadowtls-snell-*.service" 2>/dev/null | sort -u)
    if [ ! -z "$snell_services" ]; then
        echo -e "\n${YELLOW}=== ShadowTLS 组合配置 ===${RESET}"
        declare -A processed_ports
        while IFS= read -r service_file; do
            local exec_line=$(grep "ExecStart=" "$service_file")
            local stls_port=$(echo "$exec_line" | grep -oP '(?<=--listen ::0:)\d+')
            local stls_password=$(echo "$exec_line" | grep -oP '(?<=--password )[^ ]+')
            local stls_domain=$(echo "$exec_line" | grep -oP '(?<=--tls )[^ ]+')
            local snell_port=$(echo "$exec_line" | grep -oP '(?<=--server 127.0.0.1:)\d+')
            # 查找 psk
            local psk=""
            if [ -f "${SNELL_CONF_DIR}/users/snell-${snell_port}.conf" ]; then
                psk=$(grep -E '^psk' "${SNELL_CONF_DIR}/users/snell-${snell_port}.conf" | awk -F'=' '{print $2}' | tr -d ' ')
            elif [ -f "${SNELL_CONF_DIR}/users/snell-main.conf" ] && [ "$snell_port" = "$(get_snell_port)" ]; then
                psk=$(grep -E '^psk' "${SNELL_CONF_DIR}/users/snell-main.conf" | awk -F'=' '{print $2}' | tr -d ' ')
            fi
            # 避免重复
            if [ -z "$snell_port" ] || [ -z "$psk" ] || [ -n "${processed_ports[$snell_port]}" ]; then
                continue
            fi
            processed_ports[$snell_port]=1
            if [ "$snell_port" = "$(get_snell_port)" ]; then
                echo -e "\n${GREEN}主用户 ShadowTLS 配置：${RESET}"
            else
                echo -e "\n${GREEN}用户 ShadowTLS 配置 (端口: ${snell_port})：${RESET}"
            fi
            echo -e "  - Snell 端口：${snell_port}"
            echo -e "  - PSK：${psk}"
            echo -e "  - ShadowTLS 监听端口：${stls_port}"
            echo -e "  - ShadowTLS 密码：${stls_password}"
            echo -e "  - ShadowTLS SNI：${stls_domain}"
            echo -e "  - 版本：3"
            echo -e "\n${GREEN}Surge 配置格式：${RESET}"
            if [ ! -z "$IPV4_ADDR" ]; then
                if [ "$snell_version" = "v5" ]; then
                    echo -e "${GREEN}${IP_COUNTRY_IPV4} = snell, ${IPV4_ADDR}, ${stls_port}, psk = ${psk}, version = 4, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                    echo -e "${GREEN}${IP_COUNTRY_IPV4} = snell, ${IPV4_ADDR}, ${stls_port}, psk = ${psk}, version = 5, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                else
                    echo -e "${GREEN}${IP_COUNTRY_IPV4} = snell, ${IPV4_ADDR}, ${stls_port}, psk = ${psk}, version = 4, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                fi
            fi
            if [ ! -z "$IPV6_ADDR" ]; then
                if [ "$snell_version" = "v5" ]; then
                    echo -e "${GREEN}${IP_COUNTRY_IPV6} = snell, ${IPV6_ADDR}, ${stls_port}, psk = ${psk}, version = 4, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                    echo -e "${GREEN}${IP_COUNTRY_IPV6} = snell, ${IPV6_ADDR}, ${stls_port}, psk = ${psk}, version = 5, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                else
                    echo -e "${GREEN}${IP_COUNTRY_IPV6} = snell, ${IPV6_ADDR}, ${stls_port}, psk = ${psk}, version = 4, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                fi
            fi
        done <<< "$snell_services"
    fi

    echo -e "\n${YELLOW}注意：${RESET}"
    echo -e "1. Snell 仅支持 Surge 客户端"
    echo -e "2. 请将配置中的服务器地址替换为实际可用的地址"
    read -p "按任意键返回主菜单..."
}

# 获取当前安装的 Snell 版本
get_current_snell_version() {
    # 检测当前安装的 Snell 版本
    local current_installed_version=$(detect_installed_snell_version)

    if [ "$current_installed_version" = "v5" ]; then
        # v5 版本获取完整版本号
        CURRENT_VERSION=$(snell-server --v 2>&1 | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+[a-z0-9]*')
        if [ -z "$CURRENT_VERSION" ]; then
            # 如果无法获取，使用默认的 v5 版本
            CURRENT_VERSION="v5.0.0b3"
        fi
    else
        # v4 版本获取完整版本号
        CURRENT_VERSION=$(snell-server --v 2>&1 | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+')
        if [ -z "$CURRENT_VERSION" ]; then
            echo -e "${RED}无法获取当前 Snell 版本。${RESET}"
            exit 1
        fi
    fi
}

# 检查 Snell 更新
check_snell_update() {
    echo -e "\n${CYAN}=============== 检查 Snell 更新 ===============${RESET}"

    # 检测当前安装的 Snell 版本
    local current_installed_version=$(detect_installed_snell_version)
    if [ "$current_installed_version" = "unknown" ]; then
        echo -e "${RED}无法检测当前 Snell 版本${RESET}"
        return 1
    fi

    echo -e "${YELLOW}当前安装版本: Snell ${current_installed_version}${RESET}"

    # 所有更新统一使用 Snell v5（兼容 v4 客户端）
    SNELL_VERSION_CHOICE="v5"
    if [ "$current_installed_version" = "v4" ]; then
        echo -e "\n${CYAN}Snell v5 与 v4 客户端配置兼容，将升级到 Snell v5。${RESET}"
    else
        echo -e "${GREEN}当前为 Snell v5，将检查 v5 最新版本。${RESET}"
    fi

    # 获取最新版本信息
    get_latest_snell_version
    get_current_snell_version

    echo -e "${YELLOW}当前 Snell 版本: ${CURRENT_VERSION}${RESET}"
    echo -e "${YELLOW}最新 Snell 版本: ${SNELL_VERSION}${RESET}"

    # 检查是否需要更新
    if ! version_greater_equal "$CURRENT_VERSION" "$SNELL_VERSION"; then
        echo -e "\n${CYAN}发现新版本，更新说明：${RESET}"
        echo -e "${GREEN}✓ 这是更新操作，不是重新安装${RESET}"
        echo -e "${GREEN}✓ 所有现有配置将被保留（端口、密码、用户配置）${RESET}"
        echo -e "${GREEN}✓ 服务会自动重启${RESET}"
        echo -e "${GREEN}✓ 配置文件会自动备份${RESET}"
        echo -e "${CYAN}是否更新 Snell? [y/N]${RESET}"
        read -r choice
        if [ "$choice" = "y" ] || [ "$choice" = "Y" ]; then
            update_snell_binary
        else
            echo -e "${CYAN}已取消更新。${RESET}"
        fi
    else
        echo -e "${GREEN}当前已是最新版本 (${CURRENT_VERSION})。${RESET}"
    fi
}

# 强制更新 Snell 二进制并重启所有服务
force_refresh_snell_server() {
    if ! check_snell_installed; then
        echo -e "${YELLOW}当前系统未安装 Snell，无法执行更新操作。${RESET}"
        return 1
    fi

    echo -e "\n${CYAN}=============== Snell 强制更新 ===============${RESET}"
    echo -e "${GREEN}Snell v5 与 v4 配置兼容，将重新下载最新的 Snell v5 并重启所有服务。${RESET}"
    SNELL_VERSION_CHOICE="v5"
    update_snell_binary
}

silent_update_snell() {
    echo -e "\n${CYAN}=============== 静默更新 Snell ===============${RESET}"
    if ! check_snell_installed; then
        echo -e "${RED}未检测到 Snell 安装，无法执行静默更新。${RESET}"
        exit 1
    fi

    SNELL_VERSION_CHOICE="v5"
    get_latest_snell_version
    get_current_snell_version

    echo -e "${YELLOW}当前版本: ${CURRENT_VERSION}${RESET}"
    echo -e "${YELLOW}最新版本: ${SNELL_VERSION}${RESET}"

    if version_greater_equal "$CURRENT_VERSION" "$SNELL_VERSION"; then
        echo -e "${GREEN}当前已是最新版本，无需更新。${RESET}"
    else
        update_snell_binary
    fi
}

# 获取最新 GitHub 版本
get_latest_github_version() {
    local api_url="https://api.github.com/repos/jinqians/snell.sh/releases/latest"
    local response

    response=$(curl -s "$api_url")
    if [ $? -ne 0 ] || [ -z "$response" ]; then
        echo -e "${RED}无法获取 GitHub 上的最新版本信息。${RESET}"
        return 1
    fi

    GITHUB_VERSION=$(echo "$response" | grep -o '"tag_name": "[^"]*"' | cut -d'"' -f4)
    if [ -z "$GITHUB_VERSION" ]; then
        echo -e "${RED}解析 GitHub 版本信息失败。${RESET}"
        return 1
    fi
}

# 更新脚本
update_script() {
    echo -e "${CYAN}正在检查脚本更新...${RESET}"

    # 创建临时文件
    TMP_SCRIPT=$(mktemp)

    # 下载最新版本
    if curl -sL https://raw.githubusercontent.com/jinqians/snell.sh/main/snell.sh -o "$TMP_SCRIPT"; then
        # 获取新版本号
        new_version=$(grep "current_version=" "$TMP_SCRIPT" | cut -d'"' -f2)

        if [ -z "$new_version" ]; then
            echo -e "${RED}无法获取新版本信息${RESET}"
            rm -f "$TMP_SCRIPT"
            return 1
        fi

        echo -e "${YELLOW}当前版本：${current_version}${RESET}"
        echo -e "${YELLOW}最新版本：${new_version}${RESET}"

        # 比较版本号
        if [ "$new_version" != "$current_version" ]; then
            echo -e "${CYAN}是否更新到新版本？[y/N]${RESET}"
            read -r choice
            if [ "$choice" = "y" ] || [ "$choice" = "Y" ]; then
                # 获取当前脚本的完整路径
                SCRIPT_PATH=$(readlink -f "$0")

                # 备份当前脚本
                cp "$SCRIPT_PATH" "${SCRIPT_PATH}.backup"

                # 更新脚本
                mv "$TMP_SCRIPT" "$SCRIPT_PATH"
                chmod +x "$SCRIPT_PATH"

                echo -e "${GREEN}脚本已更新到最新版本${RESET}"
                echo -e "${YELLOW}已备份原脚本到：${SCRIPT_PATH}.backup${RESET}"
                echo -e "${CYAN}请重新运行脚本以使用新版本${RESET}"
                exit 0
            else
                echo -e "${YELLOW}已取消更新${RESET}"
                rm -f "$TMP_SCRIPT"
            fi
        else
            echo -e "${GREEN}当前已是最新版本${RESET}"
            rm -f "$TMP_SCRIPT"
        fi
    else
        echo -e "${RED}下载新版本失败，请检查网络连接${RESET}"
        rm -f "$TMP_SCRIPT"
    fi
}

# 检查是否安装的函数
check_installation() {
    local service=$1
    if systemctl list-unit-files | grep -q "^$service.service"; then
        echo -e "${GREEN}已安装${RESET}"
    else
        echo -e "${RED}未安装${RESET}"
    fi
}

# 获取 ShadowTLS 配置
get_shadowtls_config() {
    # 获取主 Snell 端口
    local main_port=$(get_snell_port)
    if [ -z "$main_port" ]; then
        return 1
    fi

    # 检查对应端口的 ShadowTLS 服务
    local service_name="shadowtls-snell-${main_port}"
    if ! systemctl is-active --quiet "$service_name"; then
        return 1
    fi

    local service_file="/etc/systemd/system/${service_name}.service"
    if [ ! -f "$service_file" ]; then
        return 1
    fi

    # 从服务文件中读取配置行
    local exec_line=$(grep "ExecStart=" "$service_file")
    if [ -z "$exec_line" ]; then
        return 1
    fi

    # 提取配置信息
    local tls_domain=$(echo "$exec_line" | grep -o -- "--tls [^ ]*" | cut -d' ' -f2)
    local password=$(echo "$exec_line" | grep -o -- "--password [^ ]*" | cut -d' ' -f2)
    local listen_part=$(echo "$exec_line" | grep -o -- "--listen [^ ]*" | cut -d' ' -f2)
    local listen_port=$(echo "$listen_part" | grep -o '[0-9]*$')

    if [ -z "$tls_domain" ] || [ -z "$password" ] || [ -z "$listen_port" ]; then
        return 1
    fi

    echo "${password}|${tls_domain}|${listen_port}"
    return 0
}

# 初始检查
initial_check() {
    check_root
    check_curl
    check_bc
    check_and_migrate_config
    check_and_show_status
}

if [ -n "$AUTO_UNINSTALL_PORT" ]; then
    if uninstall_port_service "$AUTO_UNINSTALL_PORT" true; then
        exit 0
    else
        exit 1
    fi
fi

if [ "$AUTO_UNINSTALL" = true ]; then
    uninstall_snell
    exit 0
fi

if [ "$AUTO_UPDATE" = true ]; then
    check_curl
    check_bc
    silent_update_snell
    exit 0
fi

# 运行初始检查
initial_check

if [ "$AUTO_INSTALL" = true ]; then
    install_snell
    exit 0
fi

# 多用户管理
setup_multi_user() {
    echo -e "${CYAN}正在执行多用户管理脚本...${RESET}"
    bash <(curl -sL https://raw.githubusercontent.com/jinqians/snell.sh/main/multi-user.sh)

    # 多用户管理脚本执行完毕后会自动返回这里
    echo -e "${GREEN}多用户管理操作完成${RESET}"
    sleep 1  # 给用户一点时间看到提示
}

# 主菜单
show_menu() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}          Snell 管理脚本 v${current_version}${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${GREEN}作者: jinqian${RESET}"
    echo -e "${GREEN}网站：https://jinqians.com${RESET}"
    echo -e "${CYAN}============================================${RESET}"

    # 显示服务状态
    check_and_show_status

    echo -e "${YELLOW}=== 基础功能 ===${RESET}"
    echo -e "${GREEN}1.${RESET} 安装 Snell"
    echo -e "${GREEN}2.${RESET} 卸载 Snell"
    echo -e "${GREEN}3.${RESET} 查看配置"
    echo -e "${GREEN}4.${RESET} 重启服务"

    echo -e "\n${YELLOW}=== 增强功能 ===${RESET}"
    echo -e "${GREEN}5.${RESET} ShadowTLS 管理"
    echo -e "${GREEN}6.${RESET} BBR 管理"
    echo -e "${GREEN}7.${RESET} 多用户管理"

    echo -e "\n${YELLOW}=== 系统功能 ===${RESET}"
    echo -e "${GREEN}8.${RESET} 更新Snell"
    echo -e "${GREEN}9.${RESET} 更新脚本"
    echo -e "${GREEN}10.${RESET} 查看服务状态"
    echo -e "${GREEN}11.${RESET} 卸载指定端口"
    echo -e "${GREEN}12.${RESET} 强制更新 Snell Server 并重启服务"
    echo -e "${GREEN}0.${RESET} 退出脚本"

    echo -e "${CYAN}============================================${RESET}"
    read -rp "请输入选项 [0-12]: " num
}

#开启bbr
setup_bbr() {
    echo -e "${CYAN}正在获取并执行 BBR 管理脚本...${RESET}"

    # 直接从远程执行BBR脚本
    bash <(curl -sL https://raw.githubusercontent.com/jinqians/snell.sh/main/bbr.sh)

    # BBR 脚本执行完毕后会自动返回这里
    echo -e "${GREEN}BBR 管理操作完成${RESET}"
    sleep 1  # 给用户一点时间看到提示
}

# ShadowTLS管理
setup_shadowtls() {
    echo -e "${CYAN}正在执行 ShadowTLS 管理脚本...${RESET}"
    bash <(curl -sL https://raw.githubusercontent.com/jinqians/snell.sh/main/shadowtls.sh)

    # ShadowTLS 脚本执行完毕后会自动返回这里
    echo -e "${GREEN}ShadowTLS 管理操作完成${RESET}"
    sleep 1  # 给用户一点时间看到提示
}

uninstall_port_prompt() {
    read -rp "请输入要卸载的端口: " target_port
    if [ -z "$target_port" ]; then
        echo -e "${RED}未输入端口，操作已取消。${RESET}"
        return 1
    fi
    uninstall_port_service "$target_port"
}

# 获取 Snell 端口
get_snell_port() {
    if [ -f "${SNELL_CONF_DIR}/users/snell-main.conf" ]; then
        grep -E '^listen' "${SNELL_CONF_DIR}/users/snell-main.conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p'
    fi
}

# 获取所有 Snell 用户配置
get_all_snell_users() {
    # 检查用户配置目录是否存在
    if [ ! -d "${SNELL_CONF_DIR}/users" ]; then
        return 1
    fi

    # 首先获取主用户配置
    local main_port=""
    local main_psk=""
    if [ -f "${SNELL_CONF_DIR}/users/snell-main.conf" ]; then
        main_port=$(grep -E '^listen' "${SNELL_CONF_DIR}/users/snell-main.conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
        main_psk=$(grep -E '^psk' "${SNELL_CONF_DIR}/users/snell-main.conf" | awk -F'=' '{print $2}' | tr -d ' ')
        if [ ! -z "$main_port" ] && [ ! -z "$main_psk" ]; then
            echo "${main_port}|${main_psk}"
        fi
    fi

    # 获取其他用户配置
        for user_conf in "${SNELL_CONF_DIR}/users"/snell-*.conf; do
            if [ -f "$user_conf" ]; then
                case "$user_conf" in
                    *snell-main.conf) continue ;;
                esac
                local port=$(grep -E '^listen' "$user_conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
                local psk=$(grep -E '^psk' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
            if [ ! -z "$port" ] && [ ! -z "$psk" ]; then
                echo "${port}|${psk}"
            fi
        fi
    done
}

# 主循环
while true; do
    show_menu
    case "$num" in
        1)
            install_snell
            ;;
        2)
            uninstall_snell
            ;;
        3)
            view_snell_config
            ;;
        4)
            restart_snell
            ;;
        5)
            setup_shadowtls
            ;;
        6)
            setup_bbr
            ;;
        7)
            setup_multi_user
            ;;
        8)
            check_snell_update
            ;;
        9)
            update_script
            ;;
        10)
            check_and_show_status
            read -p "按任意键继续..."
            ;;
        11)
            uninstall_port_prompt
            ;;
        12)
            force_refresh_snell_server
            ;;
        0)
            echo -e "${GREEN}感谢使用，再见！${RESET}"
            exit 0
            ;;
        *)
            echo -e "${RED}请输入正确的选项 [0-12]${RESET}"
            ;;
    esac
    echo -e "\n${CYAN}按任意键返回主菜单...${RESET}"
    read -n 1 -s -r
done

