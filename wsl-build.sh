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
    grep -R "192.168.1.1" feeds/ package/ | grep uci-defaults | while read -r file; do
        log "检测到 UCI 默认脚本含默认IP：$file"
        sed -i 's/192\.168\.1\.1/10.0.0.1/g' "$file"
    done

    log "默认 LAN IP 修改完成！"
}


compile_firmware() {
    log "开始编译固件..."
    cd "$BUILD_DIR"

	make menuconfig
    
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
    #clean_feeds_cache
    update_feeds
    update_feeds_index
    
    download_packages
	fix_default_ip
    compile_firmware
    organize_files
    
    log "编译流程全部完成！"
    log "固件位置: $FIRMWARE_DIR"
}

# 运行主函数
main
