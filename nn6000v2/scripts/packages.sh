#!/usr/bin/env bash

GITHUB_BASE="https://github.com/"
OPENWRT_PACKAGES_DIR="$BUILD_DIR/feeds/openwrt_packages"

# ---- M12: 第三方包 commit pin（B2 不可复现清单中的可控项）----
# 固定到具体 commit，构建可复现；上游更新时手动 bump:
#   git ls-remote https://github.com/<owner>/<repo>.git HEAD
# 获取失败时自动回退分支最新并打印警告（不会中断构建）。
# 仍为滚动源（B2 已知接受，不在 pin 范围）:
#   kenzok8/openwrt_packages(feed)、sbwml golang(27.x 分支)、VIKINGYFY/immortalwrt 本体。
PIN_LUCKY="20a30abcb05f6c778460faa36a3dd15e95145118"          # gdy666/luci-app-lucky @2026-10-11
PIN_EASYTIER="79b2b01ded627a634e4bea8d60c7be0f00b708b0"        # EasyTier/luci-app-easytier @2026-10-11
PIN_QUICKFILE="13f1a61d962e3a7790f7ab9898543be2ee5835cb"       # sbwml/luci-app-quickfile @2026-10-11
PIN_TAILSCALE="d9a3954213a09e428643db84cce4a2a232727f13"       # Tokisaki-Galaxy/luci-app-tailscale-community @2026-10-11

# 将已克隆仓库切到指定 commit（$1=名称 $2=目录 $3=SHA，空 SHA 直接过）
apply_pin() {
    local _name="$1" _dir="$2" _sha="$3"
    [ -n "$_sha" ] || return 0
    if git -C "$_dir" cat-file -e "${_sha}^{commit}" 2>/dev/null; then
        if git -C "$_dir" checkout --quiet "$_sha"; then
            echo "✓ $_name pinned @ ${_sha:0:12}"
            return 0
        fi
    fi
    if git -C "$_dir" fetch --quiet --depth 1 origin "$_sha" 2>/dev/null && \
       git -C "$_dir" checkout --quiet "$_sha" 2>/dev/null; then
        echo "✓ $_name pinned @ ${_sha:0:12} (fetched)"
        return 0
    fi
    echo "警告: $_name 固定 commit ${_sha:0:12} 获取失败，回退为分支最新（本次该项不可复现，请检查 pin 是否已失效）" >&2
    return 0
}

update_golang() {
    if [[ -d ./feeds/packages/lang/golang ]]; then
        \rm -rf ./feeds/packages/lang/golang
        if ! git clone --depth 1 -b $GOLANG_BRANCH $GOLANG_REPO ./feeds/packages/lang/golang; then
            echo "错误：克隆 golang 仓库 $GOLANG_REPO 失败" >&2
            exit 1
        fi
        echo "✓ golang 软件包更新完成"
    fi
}

clone_packages() {
    local name="$1"
    local repo_url="$2"
    local target_dir="$3"
    local sparse_pattern="${4:-}"
    local pre_cmd="${5:-}"
    local post_cmd="${6:-}"
    local move_from="${7:-}"
    local move_to="${8:-}"
    local pin_sha="${9:-}"
    
    if [ -n "$pre_cmd" ]; then
        (cd "$BUILD_DIR" && eval "$pre_cmd") || exit 1
    fi
    
    rm -rf "$target_dir" 2>/dev/null || true
    
    if [ -n "$sparse_pattern" ]; then
        if ! git clone --filter=blob:none --no-checkout "$repo_url" "$target_dir"; then
            echo "错误：从 $repo_url 克隆 $name 仓库失败" >&2
            exit 1
        fi
        
        pushd "$target_dir" >/dev/null
        git sparse-checkout init --cone
        # L3: 用数组显式分词 —— 旧写法依赖裸 $sparse_pattern 的隐式分词，
        # 且 target_dir/sparse 路径含空格时会碎裂。
        local -a sparse_args
        read -r -a sparse_args <<< "$sparse_pattern"
        if ! git sparse-checkout set "${sparse_args[@]}"; then
            echo "错误：稀疏检出 $sparse_pattern 失败" >&2
            popd >/dev/null
            exit 1
        fi
        git checkout --quiet
        popd >/dev/null
        
        # M12: pin 必须在目录搬移之前（搬移的内容才与 pin 一致）
        apply_pin "$name" "$target_dir" "$pin_sha"
        
        if [ -n "$move_from" ] && [ -n "$move_to" ]; then
            rm -rf "$move_to" 2>/dev/null || true
            mv "$move_from" "$move_to" || exit 1
        fi
    else
        if ! git clone --depth=1 "$repo_url" "$target_dir"; then
            echo "错误：从 $repo_url 克隆 $name 仓库失败" >&2
            exit 1
        fi
        # M12: pin（depth=1 只有 tip，按需单独 fetch 目标 SHA）
        apply_pin "$name" "$target_dir" "$pin_sha"
    fi
    
    if [ -n "$post_cmd" ]; then
        (cd "$BUILD_DIR" && eval "$post_cmd") || exit 1
    fi
    
    echo "✓ $name 克隆完成"
}

install_openwrt_packages() {
    ./scripts/feeds install -p openwrt_packages -f \
        taskd luci-lib-xterm luci-lib-taskd \
        luci-app-store quickstart luci-app-quickstart luci-app-istorex \
        smartdns luci-app-smartdns luci-theme-argon \
        luci-app-quickfile \
        luci-app-lucky luci-app-easytier \
        luci-app-tailscale-community
}

clone_lucky() {
    local LUCKY_REPO="${GITHUB_BASE}gdy666/luci-app-lucky.git"
    local LUCKY_DIR="$OPENWRT_PACKAGES_DIR/lucky"
    local LUCI_APP_LUCKY_DIR="$OPENWRT_PACKAGES_DIR/luci-app-lucky"
    local TEMP_DIR="$OPENWRT_PACKAGES_DIR/lucky-temp"

    rm -rf "$LUCKY_DIR" "$LUCI_APP_LUCKY_DIR" "$TEMP_DIR" 2>/dev/null || true

    clone_packages "luci-app-lucky" \
        "$LUCKY_REPO" \
        "$TEMP_DIR" \
        "lucky luci-app-lucky" \
        "" "" "" "" \
        "$PIN_LUCKY"

    mv "$TEMP_DIR/lucky" "$LUCKY_DIR"
    mv "$TEMP_DIR/luci-app-lucky" "$LUCI_APP_LUCKY_DIR"
    rm -rf "$TEMP_DIR"
    
    local lucky_conf="$LUCKY_DIR/files/luckyuci"
    if [ -f "$lucky_conf" ]; then
        sed -i "s/option enabled '1'/option enabled '0'/g" "$lucky_conf"
        sed -i "s/option logger '1'/option logger '0'/g" "$lucky_conf"
    fi
}


install_extra_feed_deps() {
    (cd "$BUILD_DIR" && ./scripts/feeds install -f luci-lib-jsonc kmod-ipt-conntrack kmod-ipt-nat)
}

clone_easytier() {
    local EASYTIER_DIR="$OPENWRT_PACKAGES_DIR/luci-app-easytier"
    local TEMP_DIR="$OPENWRT_PACKAGES_DIR/easytier-temp"

    clone_packages "luci-app-easytier" \
        "${GITHUB_BASE}EasyTier/luci-app-easytier.git" \
        "$TEMP_DIR" \
        "luci-app-easytier" \
        "" \
        "" \
        "$TEMP_DIR/luci-app-easytier" \
        "$EASYTIER_DIR" \
        "$PIN_EASYTIER"

    rm -rf "$TEMP_DIR"
}


clone_quickfile() {
    local QUICKFILE_DIR="$OPENWRT_PACKAGES_DIR/luci-app-quickfile"
    local TEMP_DIR="$OPENWRT_PACKAGES_DIR/quickfile-temp"

    clone_packages "luci-app-quickfile" \
        "${GITHUB_BASE}sbwml/luci-app-quickfile.git" \
        "$TEMP_DIR" \
        "luci-app-quickfile quickfile" \
        "" \
        "mkdir -p \"$QUICKFILE_DIR\" && rm -rf \"$QUICKFILE_DIR/luci-app-quickfile\" \"$QUICKFILE_DIR/quickfile\" && mv \"$TEMP_DIR/luci-app-quickfile\" \"$TEMP_DIR/quickfile\" \"$QUICKFILE_DIR/\"" \
        "" "" \
        "$PIN_QUICKFILE"

    rm -rf "$TEMP_DIR"
}

remove_attendedsysupgrade() {
    find "$BUILD_DIR/feeds/luci/collections" -name "Makefile" | while read -r makefile; do
        if grep -q "luci-app-attendedsysupgrade" "$makefile"; then
            sed -i "/luci-app-attendedsysupgrade/d" "$makefile"
            echo "Removed luci-app-attendedsysupgrade from $makefile"
        fi
    done
}

clone_luci_tailscale() {
    local TEMP_DIR="$OPENWRT_PACKAGES_DIR/luci-app-tailscale-community-temp"
    local TARGET_DIR="$OPENWRT_PACKAGES_DIR/luci-app-tailscale-community"
    
    clone_packages "luci-app-tailscale-community" \
        "${GITHUB_BASE}Tokisaki-Galaxy/luci-app-tailscale-community.git" \
        "$TEMP_DIR" \
        "" \
        "" \
        "rm -rf \"$TARGET_DIR\" 2>/dev/null || true; mv \"$TEMP_DIR/luci-app-tailscale-community\" \"$TARGET_DIR\"; rm -rf \"$TEMP_DIR\"" \
        "" "" \
        "$PIN_TAILSCALE"
}
