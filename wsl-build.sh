#!/bin/bash

# WSL 专用 OpenWrt 编译脚本
# 配置变量 - 根据你的需求修改
REPO_URL="https://github.com/coolsnowwolf/lede"
REPO_BRANCH="master"
FEEDS_CONF="feeds.conf.default"
REMOTE_FEEDS_CONF="https://raw.githubusercontent.com/ddouweb/build-lede/refs/heads/main/feeds.conf.default"
CONFIG_FILE="config"
REMOTE_CONFIG_FILE="https://raw.githubusercontent.com/ddouweb/build-lede/refs/heads/main/config"
DIY_P1_SH="diy-part1.sh"
DIY_P2_SH="diy-part2.sh"
WORK_DIR="$HOME"  # 使用用户目录，避免权限问题
BUILD_DIR="$WORK_DIR/lede"
TZ="Asia/Shanghai"

SCRIPT_DIR="$WORK_DIR"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

clone_source() {
    log "克隆源代码..."
    if [ -d "$BUILD_DIR" ]; then
        log "源码已存在，拉取更新..."
        cd "$BUILD_DIR"
        # 丢弃本地修改
        git checkout .
        git pull
    else
        git clone $REPO_URL -b $REPO_BRANCH "$BUILD_DIR"
    fi
}


# 下载远程文件
download_remote_file() {
    local url="$1"
    local output="$2"
    local description="$3"
    
    if [ -z "$url" ] || [[ "$url" == "https://example.com/"* ]]; then
        warn "未配置 $description URL，跳过下载"
        return 1
    fi
    
    log "下载 $description..."
    if command -v curl >/dev/null 2>&1; then
        if curl -fsSL -o "$output" "$url"; then
            log "$description 下载成功"
            return 0
        else
            warn "$description 下载失败: $url"
            return 1
        fi
    elif command -v wget >/dev/null 2>&1; then
        if wget -q -O "$output" "$url"; then
            log "$description 下载成功"
            return 0
        else
            warn "$description 下载失败: $url"
            return 1
        fi
    else
        warn "未找到 curl 或 wget，无法下载远程文件"
        return 1
    fi
}

download_remote_configs() {
    log "下载远程配置文件..."
    if [ -f "$SCRIPT_DIR/$CONFIG_FILE" ]; then
        download_remote_file "$REMOTE_FEEDS_CONF" "$SCRIPT_DIR/$FEEDS_CONF" "远程 feeds 配置"
    fi
    if [ -f "$SCRIPT_DIR/$CONFIG_FILE" ]; then
        download_remote_file "$REMOTE_CONFIG_FILE" "$SCRIPT_DIR/$CONFIG_FILE" "远程编译配置"
    fi
}

load_custom_feeds() {
    download_remote_configs
    log "加载自定义配置..."
    cd "$BUILD_DIR"
    # 复制文件目录
    if [ -d "$SCRIPT_DIR/files" ]; then
        log "复制自定义文件"
        cp -r "$SCRIPT_DIR/files" .
    fi

    # 复制配置文件
    if [ -f "$SCRIPT_DIR/$CONFIG_FILE" ]; then
        log "使用自定义配置文件"
        cp "$SCRIPT_DIR/$CONFIG_FILE" .config
    fi

    # 执行自定义脚本2
    if [ -f "$SCRIPT_DIR/$DIY_P2_SH" ]; then
        log "执行自定义脚本2"
        chmod +x "$SCRIPT_DIR/$DIY_P2_SH"
        "$SCRIPT_DIR/$DIY_P2_SH"
    fi
}

# 新增：交互式 menuconfig 并备份 .config 到 $SCRIPT_DIR/$CONFIG_FILE
run_menuconfig_and_backup() {
    log "准备进入交互式 make menuconfig（如果终端支持）..."
    cd "$BUILD_DIR" || return 1

    # 如果用户仓库里有 config，先复制到源码以便 menuconfig 读取；否则生成默认
    if [ -f "$SCRIPT_DIR/$CONFIG_FILE" ]; then
        log "检测到 $SCRIPT_DIR/$CONFIG_FILE，复制到源码目录作为初始 .config"
        cp "$SCRIPT_DIR/$CONFIG_FILE" .config
    else
        log "未找到用户配置片段，生成默认配置: make defconfig"
        make defconfig
    fi

    # 判断是不是交互式终端（有 tty）
    if [ -t 0 ]; then
        log "检测到交互式终端，启动 make menuconfig。请在界面中编辑并保存退出。"
        # 运行 menuconfig（ncurses），失败不致命
        if ! make menuconfig; then
            warn "make menuconfig 以非0码退出（可能被手动中断）"
        fi

        # 保存并备份到 $SCRIPT_DIR/$CONFIG_FILE
        if [ -f .config ]; then
            local timestamp
            timestamp=$(date +%Y%m%d-%H%M%S)
            if [ -f "$SCRIPT_DIR/$CONFIG_FILE" ]; then
                cp "$SCRIPT_DIR/$CONFIG_FILE" "$SCRIPT_DIR/$CONFIG_FILE.bak.$timestamp" 2>/dev/null || true
                log "已备份旧配置为 $SCRIPT_DIR/$CONFIG_FILE.bak.$timestamp"
            fi
            cp .config "$SCRIPT_DIR/$CONFIG_FILE"
            log "已将 .config 复制/覆盖到 $SCRIPT_DIR/$CONFIG_FILE"
        else
            warn "menuconfig 退出后未生成 .config，未执行备份"
        fi

        # 为了防止后续自动化步骤被交互项卡住，尝试非交互式运行 oldconfig 接受默认
        if command -v yes >/dev/null 2>&1; then
            log "运行 non-interactive make oldconfig（接受默认选项）以确保构建不会卡住"
            yes '' | make oldconfig >/dev/null 2>&1 || warn "make oldconfig 返回非0（可忽略）"
        else
            log "系统未安装 yes，尝试直接 make oldconfig"
            make oldconfig >/dev/null 2>&1 || warn "make oldconfig 返回非0（可忽略）"
        fi
    else
        warn "当前不是交互式终端，跳过 make menuconfig。如果想手动运行，请进入 WSL 终端执行 make menuconfig 并在保存后脚本会备份 .config。"
    fi
}

#暂不使用
clean_feeds_cache() {
    log "清理旧的 feeds 缓存..."
    cd "$BUILD_DIR"
    rm -rf feeds/*
    rm -rf tmp dl feeds/*.tmp
    rm -rf feeds/argon.tmp
}

#  更新和安装 feeds
update_feeds() {
    log "Updating and installing feeds..."
    cd "$BUILD_DIR"
    #./scripts/feeds clean
    ./scripts/feeds update -a
    ./scripts/feeds install -a
    log "Feeds updated and installed"
}

update_feeds_index() {
    log "Creating feed index files..."
    cd "$BUILD_DIR"
    make package/symlinks
    make package/feeds/luci/index
    make package/feeds/packages/index
    make package/feeds/routing/index
    make package/feeds/telephony/index
    echo "Feed index built successfully"
}

load_custom_config() {
    log "加载自定义配置..."
    cd "$BUILD_DIR"    
    
    # 复制文件目录
    if [ -d "$SCRIPT_DIR/files" ]; then
        log "复制自定义文件"
        cp -r "$SCRIPT_DIR/files" .
    fi
    
    # 复制配置文件
    if [ -f "$SCRIPT_DIR/$CONFIG_FILE" ]; then
        log "使用自定义配置文件"
        cp "$SCRIPT_DIR/$CONFIG_FILE" .config
    fi
    
    # 执行自定义脚本2
    if [ -f "$SCRIPT_DIR/$DIY_P2_SH" ]; then
        log "执行自定义脚本2"
        chmod +x "$SCRIPT_DIR/$DIY_P2_SH"
        "$SCRIPT_DIR/$DIY_P2_SH"
    fi
}

# 新增：（可选）自动合并 .config 片段（此前 assistant 给出的非交互式方案）
update_dot_config() {
    log "开始更新 .config（以源码默认配置为基础并合并自定义 config）..."
    cd "$BUILD_DIR"

    if make defconfig; then
        log "已生成当前源码默认 .config"
    else
        warn "make defconfig 失败，继续尝试合并现有配置"
    fi

    if [ -f "$SCRIPT_DIR/$CONFIG_FILE" ]; then
        if [ -f "./scripts/merge_config.sh" ]; then
            log "使用 scripts/merge_config.sh 合并自定义 config 片段"
            chmod +x ./scripts/merge_config.sh || true
            ./scripts/merge_config.sh .config "$SCRIPT_DIR/$CONFIG_FILE" || warn "merge_config.sh 返回非零，可能有失效的选项"
        else
            warn "源码中缺少 scripts/merge_config.sh，直接复制 config 到 .config"
            cp "$SCRIPT_DIR/$CONFIG_FILE" .config || warn "复制 config 失败"
        fi
    else
        log "未检测到自定义 config 片段，保留默认 .config"
    fi

    if command -v yes >/dev/null 2>&1; then
        log "执行 non-interactive 的 make oldconfig（接受默认）"
        yes '' | make oldconfig >/dev/null 2>&1 || warn "make oldconfig 退出码非0（可忽略）"
    else
        log "系统无 yes 命令，直接尝试 make oldconfig"
        make oldconfig >/dev/null 2>&1 || warn "make oldconfig 退出码非0（可忽略）"
    fi

    log ".config 更新/合并完成"
}

download_packages() {
    log "下载软件包..."
    cd "$BUILD_DIR"
    
    # 先检查配置
    if [ ! -f .config ]; then
        make defconfig
    fi
    
    # 并行下载
    local cpu_cores=$(nproc)
    local download_jobs=$((cpu_cores > 8 ? 8 : cpu_cores))
    
    log "使用 $download_jobs 个线程下载"
    make download -j$download_jobs
    
    # 清理无效的小文件
    find dl -size -1024c -delete 2>/dev/null || true
    
    # 检查下载完整性
    local broken_files=$(find dl -size 0 2>/dev/null | wc -l)
    if [ $broken_files -gt 0 ]; then
        warn "发现 $broken_files 个空文件，重新下载..."
        find dl -size 0 -delete
        make download -j1 V=s
    fi
}

fix_default_ip() {
    cd "$BUILD_DIR"
    log "最后修改默认 LAN IP 为 10.0.0.1..."

    # 修改 base-files
    if [ -f package/base-files/files/bin/config_generate ]; then
        sed -i 's/192\.168\.1\.1/10.0.0.1/g' package/base-files/files/bin/config_generate
        sed -i 's/192\.168\./10.0./g' package/base-files/files/bin/config_generate || true
        log "已修改 package/base-files/files/bin/config_generate"
    fi
    
    if [ -f package/base-files/luci/bin/config_generate ]; then
        sed -i 's/192\.168\.1\.1/10.0.0.1/g' package/base-files/luci/bin/config_generate
        sed -i 's/192\.168\./10.0./g' package/base-files/luci/bin/config_generate || true
        log "已修改 package/base-files/luci/bin/config_generate"
    fi

    # 修改 luci-base 可能的版本
    find feeds/luci -type f -path "*/luci-base/*/config_generate" -exec \
        sed -i 's/192\.168\.1\.1/10.0.0.1/g' {} \; 2>/dev/null || true

    # 额外检查可能存在的 uci-defaults 脚本
    # 1) 查找包含 192.168.1.1 的文件，并且路径中包含 uci-defaults，再替换为 10.0.0.1
    grep -RIl "192\.168\.1\.1" feeds/ package/ 2>/dev/null | grep 'uci-defaults' || true | while IFS= read -r file; do
        # grep pipeline 可能输出空行，跳过
        [ -z "${file:-}" ] && continue
        echo "检测到 UCI 默认脚本含默认IP：$file"
        if sed -i 's/192\.168\.1\.1/10.0.0.1/g' "$file"; then
            echo "已修改 $file"
        else
            echo "WARN: 无法修改 $file" >&2
        fi
    done

    # 2) 可选：把形如 192.168.xxx. 的网段替换为 10.0.xxx.
    grep -RIl "192\.168\." feeds/ package/ 2>/dev/null | grep 'uci-defaults' || true | while IFS= read -r file; do
        [ -z "${file:-}" ] && continue
        if sed -i 's/192\.168\./10.0./g' "$file" 2>/dev/null; then
            echo "已替换 192.168. -> 10.0. 在 $file"
        fi
    done

    log "处理完成。建议检查是否还有遗留的 192.168 字符串："
    grep -Rn "192\.168\." feeds/ package/ || echo "未找到残留匹配"
    

    log "默认 LAN IP 修改完成！"
}


compile_firmware() {
    log "开始编译固件..."
    cd "$BUILD_DIR"
    
    local cpu_cores=$(nproc)
    log "使用 $cpu_cores 个CPU核心编译"
    
    # WSL 内存检查
    local available_mem=$(free -g | awk 'NR==2 {print $7}')
    if [ $available_mem -lt 4 ]; then
        warn "可用内存不足4GB，建议关闭其他程序"
        local compile_jobs=$((cpu_cores > 2 ? 2 : cpu_cores))
    else
        local compile_jobs=$cpu_cores
    fi
    
    log "使用 $compile_jobs 个线程编译"
    
    # 编译策略
    if ! make -j$compile_jobs V=s; then
        warn "多线程编译失败，尝试单线程编译..."
        #if ! make -j1; then
        #    warn "单线程编译失败，尝试详细模式..."
        make -j1 V=s
        #fi
    fi
    
    log "编译完成！"
}

organize_files() {
    log "整理输出文件..."
    
    if [ -d "$BUILD_DIR/bin/targets" ]; then
        cd "$BUILD_DIR/bin/targets"/*/*
        
        # 删除 packages 目录（可选）
        rm -rf packages 2>/dev/null || true
        
        FIRMWARE_DIR=$(pwd)
        log "固件输出目录: $FIRMWARE_DIR"
        
        # 显示生成的文件
        echo "生成的固件文件:"
        find . -type f \( -name "*.bin" -o -name "*.img" -o -name "*.gz" -o -name "*.vhdx" \) -exec ls -lh {} \; | sort
    else
        error "编译输出目录不存在，编译可能失败"
    fi
}


# 主执行流程
main() {
    log "开始在 WSL 中编译 OpenWrt..."
    log "工作目录: $WORK_DIR"
    
    # 设置错误处理
    set -euo pipefail
    
    # 执行各个步骤
    clone_source
    load_custom_feeds
    load_custom_config
    
    clean_feeds_cache
    update_feeds
    update_feeds_index

    # 交互式步骤：如果是交互式终端，会打开 menuconfig 并在保存后把 .config 备份回脚本目录
    run_menuconfig_and_backup

    # 可选：如果你希望自动合并片段，也可以调用 update_dot_config（非交互场景）
    # update_dot_config

    download_packages
    fix_default_ip
    compile_firmware
    organize_files
    
    log "编译流程全部完成！"
    log "固件位置: $FIRMWARE_DIR"
}

# 运行主函数
main
