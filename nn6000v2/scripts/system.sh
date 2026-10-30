#!/usr/bin/env bash
# 2026-10-30 移除 change_dnsmasq2full：上游 include/target.mk 的 DEFAULT_PACKAGES
# 早已是 dnsmasq-full（f9b0ce7 target.mk:53），旧函数被自身 grep 守卫永久跳过，
# 属死代码。若将来需要 dnsmasq 变体，改用 .config 的 CONFIG_PACKAGE_dnsmasq* 选择。

fix_default_set() {
    if [ -d "$BUILD_DIR/feeds/luci/collections/" ]; then
        find "$BUILD_DIR/feeds/luci/collections/" -type f -name "Makefile" -exec sed -i "s/luci-theme-bootstrap/luci-theme-$THEME_SET/g" {} \;
        # M8: sed 后核验，上游改名时立刻暴露而不是静默失效
        if ! grep -rq "luci-theme-$THEME_SET" "$BUILD_DIR/feeds/luci/collections/" 2>/dev/null; then
            echo "警告: 主题替换 luci-theme-$THEME_SET 未命中任何 collections Makefile（上游可能改名），LuCI 主题可能不是 $THEME_SET" >&2
        fi
    fi

    install -Dm544 "$BASE_PATH/patches/990_set_argon_primary" "$BUILD_DIR/package/base-files/files/etc/uci-defaults/990_set_argon_primary"
    install -Dm544 "$BASE_PATH/patches/991_custom_settings" "$BUILD_DIR/package/base-files/files/etc/uci-defaults/991_custom_settings"
    install -Dm544 "$BASE_PATH/patches/992_network_config.sh" "$BUILD_DIR/package/base-files/files/etc/uci-defaults/992_network_config.sh"
    install -Dm544 "$BASE_PATH/patches/994_set_opkg_repos" "$BUILD_DIR/package/base-files/files/etc/uci-defaults/994_set_opkg_repos"
    # 996/997/998 已固化为构建期产物（2026-10-20）：
    #   - wwan.js stub、quickstart_icons.locations 直接写入 rootfs（静态文件，
    #     不再由首启脚本生成；/rom 中确认无同名文件，不会被包覆盖）
    #     注意后缀必须是 .locations（复数）：/etc/config/nginx 的 include 是
    #     conf.d/*.locations，单数文件通配不中、从未被加载（2026-10-20 设备实测）
    #   - uhttpd 自启禁用移入 system_tune（每次开机幂等，抗备份还原）
    #   - nss_freq high 由 nss_tune 运行期强制（998 删除，避免一次性脚本被白化）
    install -Dm644 "$BASE_PATH/patches/wwan.js" "$BUILD_DIR/package/base-files/files/www/luci-static/resources/protocol/wwan.js"
    install -Dm644 "$BASE_PATH/patches/quickstart_icons.locations" "$BUILD_DIR/package/base-files/files/etc/nginx/conf.d/quickstart_icons.locations"
    # 999_harden_firewall 已移除：与 fix_firewall_harden (init.d, START=18) 完全重复，
    # fix_firewall_harden 每次开机检查并恢复加固状态，已覆盖对抗备份还原场景。
    # LuCI 登录故障诊断脚本（刷机后 SSH 执行: luci_diag）
    install -Dm755 "$BASE_PATH/patches/luci_diag" "$BUILD_DIR/package/base-files/files/usr/bin/luci_diag"
    # sysctl 网络调优：构建期打入 rootfs (/etc/sysctl.d/)，每次开机由 init.d/sysctl 应用，
    # 随固件 sysupgrade 自动保留（不再依赖 uci-defaults 一次性写入 /etc/sysctl.conf）
    # 用 zz-custom.conf 而非 99-custom.conf：字典序排在 qca-nss-ecm.conf (q) 之后，
    # 在 START=11 阶段 sysctl 加载时自动覆盖 qca-nss-ecm.conf 的 nf_conntrack_max=65535，
    # 无需运行时 init.d 重新应用。移除 sysctl_custom init.d 脚本。
    install -Dm644 "$BASE_PATH/patches/sysctl_custom.conf" "$BUILD_DIR/package/base-files/files/etc/sysctl.d/zz-custom.conf"
    
    if [ -f "$BUILD_DIR/package/emortal/autocore/files/tempinfo" ]; then
        if [ -f "$BASE_PATH/patches/tempinfo" ]; then
            \cp -f "$BASE_PATH/patches/tempinfo" "$BUILD_DIR/package/emortal/autocore/files/tempinfo"
        fi
    fi
}

fix_mk_def_depends() {
    # 2026-10-30: 原 `sed 's/libustream-mbedtls/libustream-openssl/' target.mk` 已删除 ——
    # 上游 f9b0ce7 的 include/target.mk:28 本就是 libustream-openssl，sed 恒为空操作。
    if [ -f $BUILD_DIR/target/linux/qualcommax/Makefile ]; then
        sed -i 's/wpad-openssl/wpad-mesh-openssl/g' $BUILD_DIR/target/linux/qualcommax/Makefile
        # M8: 核验 wpad 替换生效（build.sh nowifi 段的 sed 依赖此包名，
        #     见 build.sh:297 注释 —— 替换失败会导致 nowifi 仍带 wpad）
        if ! grep -q "wpad-mesh-openssl" $BUILD_DIR/target/linux/qualcommax/Makefile; then
            echo "警告: wpad-openssl -> wpad-mesh-openssl 未命中 qualcommax/Makefile（上游包名可能变化）" >&2
        fi
    fi
}

fix_libffi_missing() {
    # 2026-10-19 上游把 libffi 从 packages feed 迁入 core：
    #   core 侧 openwrt/openwrt@9b835ec（新增 package/libs/libffi/Makefile）
    #   feed 侧 immortalwrt/packages@70ac3a8（删除 libs/libffi）
    # 但 VIKINGYFY core 尚未合并该提交 → glib2 的 DEPENDS "+libffi" 在 .config
    # 求值时找不到同名包被静默丢弃，打包阶段 apk 报 "libffi (no such package)"。
    # 兜底：core 缺失时注入本地 vendored 包（与上游 9b835ec 逐字节一致）。
    # 上游合并后 [ -d ] 判据自动跳过，本函数成为空操作 → 可整段删除。
    local dst="$BUILD_DIR/package/libs/libffi"
    if [ -d "$dst" ]; then
        return 0
    fi
    local src="$BASE_PATH/packages/libffi/Makefile"
    if [ ! -f "$src" ]; then
        echo "错误: $src 不存在，libffi 依赖将无法解析（glib2 打包会失败）" >&2
        return 1
    fi
    echo "=== libffi: 上游 core 缺失，注入本地包 ==="
    install -Dm644 "$src" "$dst/Makefile"
}

fix_kconfig_recursive_dependency() {
    local file="$BUILD_DIR/scripts/package-metadata.pl"
    if [ -f "$file" ]; then
        sed -i 's/<PACKAGE_\$pkgname/!=y/g' "$file"
        echo "已修复 package-metadata.pl 的 Kconfig 递归依赖生成逻辑。"
    fi
}

fix_nss_conn_limit() {
    # NSS 连接表 IPv4/IPv6 份额再平衡（总量不变 8192，仅倾斜给 IPv4）
    # 机制: 官方 hook — include/kernel.mk ModuleAutoLoad 读取 MODPARAMS.<module>
    #       生成 /etc/modules.d/32-qca-nss-drv 的 "module arg=value" 行，
    #       kmodloader/modprobe 加载时传入 module_param。
    # 依据: QSDK nss_hlos_if.h: NSS_DEFAULT_NUM_CONN=4096（真机实测 4096/4096）、
    #       NSS_MAX_TOTAL_NUM_CONN_IPV4_IPV6=8196 → 4096+4096=8192 已是实际天花板，
    #       故只重新分配不抬总量: 6144+2048=8192（与现网已验证总量完全相同，零越界风险）。
    # 参数为 S_IRUGO 只读，不能运行时热改，只能加载时传入。
    # 回滚: 删除本函数新增的 MODPARAMS 行即可恢复默认 4096/4096。
    local mk="$BUILD_DIR/package/qca-nss/qca-nss-drv/Makefile"
    if [ ! -f "$mk" ]; then
        echo "qca-nss-drv Makefile not found, skip nss conn limit fix"
        return 0
    fi
    if grep -q 'MODPARAMS.qca-nss-drv' "$mk"; then
        echo "qca-nss-drv MODPARAMS already set, skip"
        return 0
    fi
    sed -i '/AUTOLOAD:=$(call AutoLoad,32,qca-nss-drv)/a\  MODPARAMS.qca-nss-drv:=max_ipv4_conn=6144 max_ipv6_conn=2048' "$mk"
    echo "qca-nss-drv MODPARAMS 已设置: max_ipv4_conn=6144 max_ipv6_conn=2048 (总量 8192 不变)"
}

update_default_lan_addr() {
    local CFG_PATH="$BUILD_DIR/package/base-files/files/bin/config_generate"
    if [ -f $CFG_PATH ]; then
        sed -i 's/192\.168\.[0-9]*\.[0-9]*/'$LAN_ADDR'/g' $CFG_PATH
        # M8: 核验 LAN 地址写入（失败 = 设备仍拿 192.168.x，属高影响静默失效）
        if ! grep -q "$LAN_ADDR" $CFG_PATH; then
            echo "警告: update_default_lan_addr 未在 config_generate 中找到 $LAN_ADDR（sed 未命中）" >&2
        fi
    fi
}

update_affinity_script() {
    local affinity_script_dir="$BUILD_DIR/target/linux/qualcommax"

    if [ -d "$affinity_script_dir" ]; then
        find "$affinity_script_dir" -name "set-irq-affinity" -exec rm -f {} \;
        find "$affinity_script_dir" -name "smp_affinity" -exec rm -f {} \;
        install -Dm755 "$BASE_PATH/patches/smp_affinity" "$affinity_script_dir/base-files/etc/init.d/smp_affinity"
    fi
}

# 说明（2026-10-20 P2）：原 fix_luci_ucode 运行期脚本已删除。
# luci ucode 核心文件改为登记到 fix_overlay_shadow 的 MANAGED_FILES，
# 由「rom 内容优先」的统一机制处理（内容不同即删除 overlay 副本），
# 语义与原先 cp 覆盖等价，但少一个启动脚本且能自动覆盖新增文件。

# 部署 uhttpd 适配器（nginx→uhttpd 密码哈希桥接）+ rpcd 空密码哈希初始化。
# START=11（luci ucode 已改由 fix_overlay_shadow 在 S01 统一处理）。
# 解决: set_new_pwd/check_oldpwd 依赖 uhttpd -m 生成 crypt hash，
#       但固件用 nginx 导致密码修改失败（复杂密码返回空哈希）。
install_luci_rpcd_fix() {
    local target_dir="$BUILD_DIR/target/linux/qualcommax"

    if [ -d "$target_dir" ]; then
        install -Dm755 "$BASE_PATH/patches/fix_luci_rpcd" "$target_dir/base-files/etc/init.d/fix_luci_rpcd"
        echo "已安装 fix_luci_rpcd 启动修复脚本 (uhttpd 适配器 + rpcd 密码初始化)"
    fi
}

# 修复 istorex 首页温度拿不到 / 系统信息 404：
#  1) luci-app-istorex 0.6.6 前端调用 /cgi-bin/luci/linkease/api/，
#     而 luci-app-quickstart 0.12.8 只注册 /cgi-bin/luci/istore/ 路由 → 404；
#  2) quickstart 的 AutocoreTemperature 依赖 /sbin/cpuinfo 输出含 "xx.x°C"，
#     但 ImmortalWrt/VIKINGYFY 的 autocore 把温度分离在 /sbin/tempinfo，
#     导致温度恒为 0（接口返回 {"result":{}}）。
# 均以 patches/ 下的修复版写入 /rom；运行期由 fix_overlay_shadow 统一守护。
# 移除条件: kenzok8 feed 的 luci-app-quickstart 原生提供 /linkease/api 路由，
#           且其配套 autocore cpuinfo 输出自带温度后，可删除本函数与相关 patches。
install_istorex_fixes() {
    # 1. autocore cpuinfo：追加 CPU 温度（供 quickstart AutocoreTemperature 解析）
    local cpuinfo="$BUILD_DIR/package/emortal/autocore/files/cpuinfo"
    if [ -f "$cpuinfo" ] && [ -f "$BASE_PATH/patches/cpuinfo" ]; then
        \cp -f "$BASE_PATH/patches/cpuinfo" "$cpuinfo"
        echo "已替换 autocore cpuinfo（追加 CPU 温度，兼容 quickstart）"
    fi

    # 2. luci-app-quickstart 的 istore_backend.lua：增加 linkease/api 路由
    local backend_file
    backend_file="$(find "$BUILD_DIR/feeds" "$BUILD_DIR/package" \
        -path "*luci-app-quickstart*" -name "istore_backend.lua" 2>/dev/null | head -1)"
    if [ -n "$backend_file" ] && [ -f "$BASE_PATH/patches/istore_backend.lua" ]; then
        \cp -f "$BASE_PATH/patches/istore_backend.lua" "$backend_file"
        echo "已替换 istore_backend.lua（增加 /linkease/api 路由）"
    else
        echo "警告: 未找到 luci-app-quickstart 的 istore_backend.lua，跳过路由修复"
    fi

    # 3.（2026-10-20 P2）原 fix_istorex 运行期自愈脚本已删除：
    #     /sbin/cpuinfo 与 istore_backend.lua 已登记到 fix_overlay_shadow 的
    #     MANAGED_FILES，由统一的「rom 内容优先」机制保证不被旧副本遮蔽。
}

# 修复 NN6000 的 WPS/reset 按键失效（gpio-keys probe -EINVAL）:
#   ipq6018-common.dtsi 启用 blsp1_i2c3 (i2c@78b7000)，其 pinctrl i2c_1_pins
#   占用 GPIO_42/43；而 ipq6000-link.dtsi 的 WPS 键也用 GPIO_42，冲突导致
#   gpio-keys 整个节点 probe 失败（连 reset 键一起失效）。
#   实测 i2c3 总线空置（无任何从设备），禁用之即可释放 GPIO_42。
# 注: ipq6018-common.dtsi 为多设备共享，不动它；只改设备侧 ipq6000-link.dtsi
#     （被 nn6000-v1/v2 共同 include，两者同源冲突）。
# 移除条件: 上游在 ipq6000-link.dtsi 中自行处理该冲突（或上游内核改用
#           gpio-reserved-ranges）后，可删除本函数。
fix_nn6000_gpio_conflict() {
    local dts="$BUILD_DIR/target/linux/qualcommax/dts/ipq6000-link.dtsi"

    if [ ! -f "$dts" ]; then
        # M10: 打印"跳过"就必须真的跳过（旧版 return 1 在 set -e/errexit 下会中止整个构建，
        # 消息与行为矛盾）。dts 缺失属上游改名/裁剪，降级为警告: 设备仅失去 WPS/reset 键修复。
        echo "警告: 未找到 $dts，跳过 NN6000 按键 GPIO 冲突修复（WPS/reset 按键在本构建中可能失效）" >&2
        return 0
    fi

    if grep -q 'blsp1_i2c3' "$dts"; then
        echo "ipq6000-link.dtsi 的 blsp1_i2c3 冲突已处理，跳过"
        return 0
    fi

    cat >> "$dts" <<'EOF'

/* GPIO_42 被 blsp1_i2c3 (i2c@78b7000) 的 pinctrl i2c_1_pins 占用，
 * 与 WPS 键 (gpios = <&tlmm 42 GPIO_ACTIVE_LOW>) 冲突，导致 gpio-keys
 * probe 失败 (-EINVAL)、WPS/reset 键全部失效。实测该 i2c 总线空置
 * （无任何从设备），禁用之释放 GPIO_42 供按键使用。 */
&blsp1_i2c3 {
	status = "disabled";
};
EOF
    echo "已禁用 ipq6000-link.dtsi 中与 WPS 键冲突的 blsp1_i2c3 (GPIO_42)"
}

# 安装 NSS / sysctl 调优脚本：
#  - nss_tune (START=27): 纯有线场景的 NSS n2h/pbuf 调优（官方
#    qca-nss-pbuf.init 受 CONFIG_ATH11K_NSS_SUPPORT + ath11k 运行时检查限制，
#    nowifi 设备不生效）
#  - sysctl_custom 已移除：zz-custom.conf 字典序在 qca-nss-ecm.conf 之后，
#    START=11 阶段自动覆盖，无需运行时重新应用
install_tuning_scripts() {
    local target_dir="$BUILD_DIR/target/linux/qualcommax"

    if [ ! -d "$target_dir" ]; then
        # M10: 缺 qualcommax target 意味着整棵树不完整，errexit 下 return 1 必中止 —— 消息如实标注
        echo "错误: 未找到 qualcommax target ($target_dir)，无法安装调优脚本，中止构建" >&2
        return 1
    fi

    install -Dm755 "$BASE_PATH/patches/nss_tune" \
        "$target_dir/base-files/etc/init.d/nss_tune"
    install -Dm755 "$BASE_PATH/patches/fix_firewall_harden" \
        "$target_dir/base-files/etc/init.d/fix_firewall_harden"
    install -Dm755 "$BASE_PATH/patches/system_tune" \
        "$target_dir/base-files/etc/init.d/system_tune"
    echo "已安装 nss_tune / fix_firewall_harden / system_tune 脚本（sysctl_custom 已移除）"
}

# H3+H4: overlay 遮蔽修复（START=01，早于全部被托管脚本）
#   - 托管文件白名单: 旧 overlay 副本让位于 /rom，新 overlay 副本保留
#   - apk db: kernel V 与 rom 不一致（旧固件库）时以 rom 底重建
install_overlay_shadow() {
    local target_dir="$BUILD_DIR/target/linux/qualcommax"

    if [ ! -d "$target_dir" ]; then
        echo "错误: 未找到 qualcommax target ($target_dir)，无法安装 fix_overlay_shadow，中止构建" >&2
        return 1
    fi

    install -Dm755 "$BASE_PATH/patches/fix_overlay_shadow" \
        "$target_dir/base-files/etc/init.d/fix_overlay_shadow"
    echo "已安装 fix_overlay_shadow (START=01, overlay 遮蔽修复)"
}

# M1: eMMC I/O 错误启动期监测（START=96）
install_emmc_health() {
    local target_dir="$BUILD_DIR/target/linux/qualcommax"

    if [ ! -d "$target_dir" ]; then
        echo "错误: 未找到 qualcommax target ($target_dir)，无法安装 emmc_health，中止构建" >&2
        return 1
    fi

    install -Dm755 "$BASE_PATH/patches/emmc_health" \
        "$target_dir/base-files/etc/init.d/emmc_health"
    echo "已安装 emmc_health (START=96, mmcblk0 I/O 错误监测)"
}

# uwsgi 启动优先级改为 93（quickstart S92 之后）
# 解决: uwsgi(S79) 构建 LuCI 路由缓存时 quickstart(S92) 尚未启动，
#       缓存中注册 redirect_fallback(→ /admin/status) 的竞态问题。
# 方案: 直接用 patches/uwsgi.init 覆盖上游文件，不依赖 sed 匹配。
fix_uwsgi_start_priority() {
    local target_dir="$BUILD_DIR/feeds/packages/net/uwsgi/files"
    if [ -d "$target_dir" ] && [ -f "$BASE_PATH/patches/uwsgi.init" ]; then
        \cp -f "$BASE_PATH/patches/uwsgi.init" "$target_dir/uwsgi.init"
        echo "已覆盖 uwsgi/files/uwsgi.init（START=93，quickstart 之后）"
    else
        echo "警告: 未找到 uwsgi/files/ 目录或 patches/uwsgi.init，跳过"
    fi
}

change_cpuusage() {
    local luci_rpc_path="$BUILD_DIR/feeds/luci/modules/luci-base/root/usr/share/rpcd/ucode/luci"

    if [ -f "$luci_rpc_path" ]; then
        sed -i "s#const fd = popen('top -n1 | awk \\\'/^CPU/ {printf(\"%d%\", 100 - \$8)}\\\'')#const cpuUsageCommand = access('/sbin/cpuusage') ? '/sbin/cpuusage' : 'top -n1 | awk \\\'/^CPU/ {printf(\"%d%\", 100 - \$8)}\\\''#g" "$luci_rpc_path"
        sed -i '/cpuUsageCommand/a \\t\t\tconst fd = popen(cpuUsageCommand);' "$luci_rpc_path"
    fi

    local old_script_path="$BUILD_DIR/package/base-files/files/sbin/cpuusage"
    if [ -f "$old_script_path" ]; then
        rm -f "$old_script_path"
    fi

    if [ -d "$BUILD_DIR/target/linux/qualcommax" ]; then
        install -Dm755 "$BASE_PATH/patches/cpuusage" "$BUILD_DIR/target/linux/qualcommax/base-files/sbin/cpuusage"
    fi
}

# 构建时直接写入 cron 任务到 base-files，不再依赖运行时 init.d 脚本
set_custom_task() {
    local cron_dir="$BUILD_DIR/package/base-files/files/etc/crontabs"
    local cron_file="$cron_dir/root"
    mkdir -p "$cron_dir"
    # M11: 追加而非整文件覆盖 —— 若上游 root crontab 已有条目则保留
    touch "$cron_file"
    if ! grep -qF "nginx-util 'check_ssl'" "$cron_file" 2>/dev/null; then
        echo "3 3 12 12 * /usr/bin/nginx-util 'check_ssl'" >>"$cron_file"
    fi
    chmod 600 "$cron_file"
    echo "已写入 cron 任务到 base-files（构建时，追加模式）"
}

update_nss_diag() {
    local file="$BUILD_DIR/package/base-files/files/usr/bin/nss_diag.sh"
    mkdir -p "$(dirname "$file")"
    install -Dm755 "$BASE_PATH/patches/nss_diag.sh" "$file"
    echo "已安装 nss_diag.sh 到 /usr/bin/"
}

# 2026-10-30 移除 fix_compile_coremark：上游 coremark Makefile 的 Build/Compile
# 已是 `mkdir -p $(PKG_BUILD_DIR)/$(ARCH)`（packages feed master 48f60904:72），
# 旧 sed（`mkdir $` → `mkdir -p $`）恒不命中，属死代码。

update_dnsmasq_conf() {
    local file="$BUILD_DIR/package/network/services/dnsmasq/files/dhcp.conf"
    if [ -d "$(dirname "$file")" ] && [ -f "$file" ]; then
        sed -i '/dns_redirect/d' "$file"
    fi
}

add_backup_info_to_sysupgrade() {
    local conf_path="$BUILD_DIR/package/base-files/files/etc/sysupgrade.conf"

    if [ -f "$conf_path" ]; then
        # M11: 追加而非 cat > 整文件覆盖 —— 保留上游已有的保留条目/注释
        grep -qx "/etc/easytier" "$conf_path" 2>/dev/null || echo "/etc/easytier" >>"$conf_path"
        grep -qx "/etc/lucky/" "$conf_path" 2>/dev/null || echo "/etc/lucky/" >>"$conf_path"
    fi
}

fix_rust_compile_error() {
    if [ -f "$BUILD_DIR/feeds/packages/lang/rust/Makefile" ]; then
        sed -i 's/download-ci-llvm=true/download-ci-llvm=false/g' "$BUILD_DIR/feeds/packages/lang/rust/Makefile"
    fi
}

fix_smartdns_makefile() {
    local makefile="$BUILD_DIR/feeds/openwrt_packages/smartdns/Makefile"
    if [ ! -f "$makefile" ]; then
        makefile="$BUILD_DIR/feeds/packages/net/smartdns/Makefile"
    fi
    if [ ! -f "$makefile" ]; then
        echo "smartdns Makefile not found, skip fix"
        return 0
    fi

    echo "正在修复 smartdns Makefile，移除 Rust UI 依赖..."
    
    # 删除 Rust package include
    sed -i '/rust-package.mk/d' "$makefile"
    # 删除 Rust 相关变量
    sed -i '/^RUST_PKG/d' "$makefile"
    sed -i '/^PKG_BUILD_DEPENDS.*smartdns-ui/d' "$makefile"
    sed -i '/^PKG_CONFIG_DEPENDS.*smartdns-ui/d' "$makefile"
    # 删除 smartdns-ui 包定义
    sed -i '/^define Package\/smartdns-ui/,/^endef/d' "$makefile"
    # 删除 Build/Prepare 中的 smartdns-webui 下载
    sed -i '/^define Download\/smartdns-webui/,/^endef/d' "$makefile"
    sed -i '/smartdns-webui/d' "$makefile"
    # 删除 Build/Prepare 和 Build/Compile 中的 ifneq 块
    sed -i '/ifneq.*CONFIG_PACKAGE_smartdns-ui/,/endif/d' "$makefile"
    # 删除 smartdns-ui 安装规则
    sed -i '/^define Package\/smartdns-ui\/install/,/^endef/d' "$makefile"
    # 删除 smartdns-ui 的 eval
    sed -i '/smartdns-ui)/d' "$makefile"
    # 2026-10-30 加护栏：以上全是「按形态删行」，上游改写 Makefile 结构时会静默
    # 删不掉 → smartdns-ui 仍被求值（拉 node/rust host 依赖）。删完必须复查。
    if grep -q 'smartdns-ui' "$makefile"; then
        echo "警告: smartdns Makefile 仍残留 smartdns-ui 引用（上游结构已变），需人工核对 fix_smartdns_makefile" >&2
        grep -n 'smartdns-ui' "$makefile" | head -5 >&2
    fi
    # 补充缺失的 zlib 依赖
    if grep -q 'DEPENDS:=.*+i386:libatomic +libopenssl' "$makefile"; then
        if ! grep -q '+zlib' "$makefile"; then
            sed -i 's/DEPENDS:=+i386:libatomic +libopenssl/DEPENDS:=+i386:libatomic +libopenssl +zlib/' "$makefile"
        fi
    fi
    
    echo "smartdns Makefile 修复完成"
}

# 移除已被上游 2.3.11 吸收的 miniupnpd 补丁（VIKINGYFY 99c39ee7 起），
# 否则 feed 补丁与源码不匹配导致 build 中断。
# 移除条件：上游 miniupnpd 版本回退到 2.3.9 或补丁重新与源码匹配时，可删除本函数与调用。
fix_miniupnpd_patches() {
    local dir="$BUILD_DIR/feeds/packages/net/miniupnpd/patches"
    local name
    for name in 020-descr-filter-fix.patch 030-allow-private-fix.patch 040-improve-logging.patch; do
        [ -f "$dir/$name" ] || continue
        rm -f "$dir/$name"
        echo "正在移除已被上游合并的 miniupnpd 补丁：$name"
    done
}

update_nginx_ubus_module() {
    local makefile_path="$BUILD_DIR/feeds/packages/net/nginx/Makefile"
    local source_date="2024-03-02"
    local source_version="564fa3e9c2b04ea298ea659b793480415da26415"
    local mirror_hash="92c9ab94d88a2fe8d7d1e8a15d15cfc4d529fdc357ed96d22b65d5da3dd24d7f"

    if [ -f "$makefile_path" ]; then
        sed -i "s/SOURCE_DATE:=2020-09-06/SOURCE_DATE:=$source_date/g" "$makefile_path"
        sed -i "s/SOURCE_VERSION:=b2d7260dcb428b2fb65540edb28d7538602b4a26/SOURCE_VERSION:=$source_version/g" "$makefile_path"
        sed -i "s/MIRROR_HASH:=515bb9d355ad80916f594046a45c190a68fb6554d6795a54ca15cab8bdd12fda/MIRROR_HASH:=$mirror_hash/g" "$makefile_path"
        # 2026-10-30 加护栏：pin 是「源串 → 目标串」替换，上游改了 nginx-mod-ubus 的
        # SOURCE_DATE/VERSION/HASH 时 sed 会静默不命中，包仍会按旧源码构建（症状是
        # 意料外的模块行为，很难归因）。未命中即报警。
        if ! grep -qF "SOURCE_VERSION:=$source_version" "$makefile_path"; then
            echo "警告: nginx-mod-ubus pin 未生效（上游 SOURCE_DATE/SOURCE_VERSION/MIRROR_HASH 已变），请人工同步 update_nginx_ubus_module" >&2
        fi
        echo "已更新 nginx-mod-ubus 模块的 SOURCE_DATE, SOURCE_VERSION 和 MIRROR_HASH。"
    else
        echo "错误：未找到 $makefile_path 文件，无法更新 nginx-mod-ubus 模块。" >&2
    fi
}

# 2026-10-30 移除 fix_nginx_configure：该函数删的 5 个 autotools 参数
# （--target= / --host= / --disable-dependency-tracking / --program-prefix= /
# --program-suffix=）在 packages feed master 48f60904 的 net/nginx/Makefile 中
# 已全部不存在，sed 恒为空操作却仍打印「已修复」，属误导性死代码。

# 2026-10-30 移除 fix_openssl_ktls：上游 f9b0ce7 的 package/libs/openssl/Config.in
# 已把 OPENSSL_KTLS 改为无 default 的裸 bool（不再出现 select/depends PACKAGE_kmod-tls），
# 原 sed 恒不命中 → kTLS 会静默变成关闭。改为在 .config 显式 CONFIG_OPENSSL_KTLS=y
# （见 configs/link_nn6000v2_immwrt.config），由 build.sh 的 defconfig 后置校验兜底。

install_pbr_isp() {
    local pbr_pkg_dir="$BUILD_DIR/package/feeds/packages/pbr"
    local pbr_dir="$pbr_pkg_dir/files/usr/share/pbr"
    local pbr_conf="$pbr_pkg_dir/files/etc/config/pbr"
    local pbr_makefile="$pbr_pkg_dir/Makefile"
    local pbr_init_script="$pbr_pkg_dir/files/etc/init.d/pbr"

    if [ -d "$pbr_pkg_dir" ]; then
        echo "正在安装 PBR 多 ISP 自动识别脚本..."
        install -Dm755 "$BASE_PATH/patches/pbr.user.isp" "$pbr_dir/pbr.user.isp"

        if [ -f "$pbr_makefile" ]; then
            if ! grep -q "pbr.user.isp" "$pbr_makefile"; then
                echo "正在修改 PBR Makefile 添加安装规则..."
                sed -i '/pbr.user.netflix.*\$(1)/a\
	$(INSTALL_DATA) ./files/usr/share/pbr/pbr.user.isp $(1)/usr/share/pbr/pbr.user.isp' "$pbr_makefile"
            fi
        fi
        
        # Add auto-retry mechanism to pbr init script
        if [ -f "$pbr_init_script" ]; then
            echo "正在添加 PBR 自动重试机制..."
            # Simple retry: try every 10s for up to 50s if not configured
            cat >> "$pbr_init_script" << 'EOF'

# PBR auto-retry (simple version)
[ -f /var/run/pbr_configured ] || ( for i in 1 2 3 4 5; do
    sleep 10
    /usr/share/pbr/pbr.user.isp >/dev/null 2>&1 && break
done ) &
EOF
        fi
    fi

    if [ -f "$pbr_conf" ]; then
        if ! grep -q "pbr.user.isp" "$pbr_conf"; then
            echo "正在添加 PBR ISP 自动识别配置条目..."
            sed -i "/option path '\/usr\/share\/pbr\/pbr.user.netflix'/,/option enabled '0'/{
                /option enabled '0'/a\\
\\
config include\\
	option path '/usr/share/pbr/pbr.user.isp'\\
	option enabled '1'
            }" "$pbr_conf"
        fi
    fi
}

fix_pbr_ip_forward() {
    local pbr_pkg_dir="$BUILD_DIR/package/feeds/packages/pbr"
    local pbr_init_script="$pbr_pkg_dir/files/etc/init.d/pbr"

    if [ ! -d "$pbr_pkg_dir" ]; then
        echo "PBR package directory not found: $pbr_pkg_dir"
        return 1
    fi

    if [ ! -f "$pbr_init_script" ]; then
        echo "PBR init script not found: $pbr_init_script"
        return 1
    fi

    # Check if fix is already applied (enabled check already present)
    if grep -q '\[ -n "$enabled" \] && \[ -n "$strict_enforcement" \]' "$pbr_init_script"; then
        echo "PBR IP Forward fix already applied"
        return 0
    fi

    # Check if the original pattern exists that needs fixing
    if ! grep -q '\[ -n "$strict_enforcement" \] && \[ "$(cat /proc/sys/net/ipv4/ip_forward)"' "$pbr_init_script"; then
        echo "PBR IP Forward: 未找到需要修复的代码，可能上游已修复或此版本无此问题"
        return 0
    fi

    echo "正在应用 PBR IP Forward 修复..."
    # Fix: Add enabled check before strict_enforcement check
    # Original: if [ -n "$strict_enforcement" ] && [ "$(cat /proc/sys/net/ipv4/ip_forward)" != "0" ]; then
    # Fixed:   if [ -n "$enabled" ] && [ -n "$strict_enforcement" ] && [ "$(cat /proc/sys/net/ipv4/ip_forward)" != "0" ]; then
    sed -i 's/\[ -n "\$strict_enforcement" \] && \[ "\$(cat \/proc\/sys\/net\/ipv4\/ip_forward)"/\[ -n "\$enabled" \] \&\& \[ -n "\$strict_enforcement" \] \&\& \[ "\$(cat \/proc\/sys\/net\/ipv4\/ip_forward)"/' "$pbr_init_script"
    
    if grep -q '\[ -n "$enabled" \] && \[ -n "$strict_enforcement" \]' "$pbr_init_script"; then
        echo "PBR IP Forward 修复应用成功"
        return 0
    else
        echo "修复应用失败：未找到预期的修复内容"
        return 1
    fi
}

set_nginx_default_config() {
    # 源文件是 files/nginx.config（nginx-ssl-util Makefile:
    #   $(INSTALL_CONF) ./files/nginx.config $(1)/etc/config/nginx；
    #   openwrt/packages 与 immortalwrt/packages 的 net/nginx-util/files/ 均仅
    #   有 nginx.config）。2026-10 刷机实证: 旧目标 files/nginx 不存在 →
    #   [ -f ] 失败静默跳过 → 镜像保留通配监听（M2 未进镜像）。
    local nginx_uci="$BUILD_DIR/feeds/packages/net/nginx-util/files/nginx.config"
    if [ -f "$nginx_uci" ] && [ -f "$BASE_PATH/patches/nginx.config" ]; then
        \cp -f "$BASE_PATH/patches/nginx.config" "$nginx_uci"
        echo "已覆盖 nginx UCI config（files/nginx.config → /etc/config/nginx）"
    else
        # 不 return 1: update.sh 有 set -e/errexit（system.sh:185 M10 同款教训），只大声报错
        echo "错误: 未找到 $nginx_uci 或 patches/nginx.config，M2 监听收紧未进镜像" >&2
    fi

    # quickstart_icons.locations 已改为构建期静态安装（见 fix_default_set）：
    #   文件名后缀须为 .locations（复数），与 /etc/config/nginx 的
    #   conf.d/*.locations 通配一致；旧 997 用的单数 .location 从不匹配、无效。
    #   overlay 残留的旧单数文件由 fix_overlay_shadow 的 LEGACY_FILES 清理。

    local nginx_template="$BUILD_DIR/feeds/packages/net/nginx-util/files/uci.conf.template"
    if [ -f "$nginx_template" ]; then
        if ! grep -q "client_body_in_file_only clean;" "$nginx_template"; then
            sed -i "/client_max_body_size 128M;/a\\
\tclient_body_in_file_only clean;\\
\tclient_body_temp_path /mnt/tmp;" "$nginx_template"
        fi
    fi

    local luci_support_script="$BUILD_DIR/feeds/packages/net/nginx/files-luci-support/60_nginx-luci-support"

    if [ -f "$luci_support_script" ]; then
        if ! grep -q "client_body_in_file_only off;" "$luci_support_script"; then
            echo "正在为 Nginx ubus location 配置应用修复..."
            sed -i "/ubus_parallel_req 2;/a\\        client_body_in_file_only off;\\n        client_max_body_size 1M;" "$luci_support_script"
        fi
    fi
}

update_uwsgi_limit_as() {
    local cgi_io_ini="$BUILD_DIR/feeds/packages/net/uwsgi/files-luci-support/luci-cgi_io.ini"
    local webui_ini="$BUILD_DIR/feeds/packages/net/uwsgi/files-luci-support/luci-webui.ini"

    if [ -f "$cgi_io_ini" ]; then
        sed -i 's/^limit-as = .*/limit-as = 8192/g' "$cgi_io_ini"
    fi

    if [ -f "$webui_ini" ]; then
        sed -i 's/^limit-as = .*/limit-as = 8192/g' "$webui_ini"
    fi
}

# 构建期去重「显式清单（kenzok8 / 克隆钉版）」与「luci、packages feed 全量注册」的同名包
# （2026-10-20 CI 连挂修复）。
#
# 为什么必须去重: install_feeds 对非 openwrt_packages 的每个 feed 执行
#   `feeds install -f -ap`（全量注册），与 install_openwrt_packages 的显式条目撞名时，
#   「哪个 .apk 被编译」与「哪个 Kconfig 定义生效」由目录扫描顺序决定、结果不稳定。
#   实测翻转证据（同一仓库不同次构建）：
#     luci-app-smartdns  设备(10-15 构建)=kenzok8 1.2024.45-r1
#                        最近 CI(10-20)=immortalwrt/luci 1.2025.47.2-r1
#   撞名清单（2026-10-20 全量扫描 4 个 feed × 显式清单 19 名，仅这 4 项）：
#     luci-theme-argon          kenzok8 3.0.0-r20261016（设备在用） vs luci 3.0.0-r20261019
#     luci-app-smartdns         kenzok8 1.2024.45（设备在用） vs luci 1.2025.47.2
#     smartdns                  kenzok8 48.4-r2（设备在用） vs immortalwrt/packages net/smartdns 48.4-r1
#     luci-app-tailscale-community  Tokisaki 克隆钉版 d9a3954（=其 master HEAD）vs luci feed
#
# smartdns 额外风险: fix_smartdns_makefile 只优先 patch feeds/openwrt_packages/smartdns；
#   若 packages feed 侧胜出，Rust UI 剥离补丁作用不到真正被编译的 Makefile。
# tailscale-community 注意: 它在 kenzok8 GitHub 上没有（404 属正常），由
#   clone_luci_tailscale 克隆 Tokisaki-Galaxy 钉版注入 feeds/openwrt_packages，
#   显式清单装的就是钉版 —— 显式条目不是死条目，勿删。
#
# luci-app-argon-config 一并纳入（护栏）: 上游已于 2026-10-19 把该 app 合入主题
#   （immortalwrt/luci themes/luci-theme-argon: PKG_VERSION3.0.0 PKG_RELEASE20261019
#   LUCI_BASENAME:=argon-config PKG_PROVIDES:=luci-app-argon-config，原
#   applications/luci-app-argon-config 已 404）；但本仓库的 .config 已禁用该 app，
#   一旦 feed 回退、旧 app 复活，其生成的 luci-i18n-argon-config-<lang> 依赖裸名
#   → package-metadata.pl:161+228-237 转成 `depends on PACKAGE_luci-app-argon-config`
#   → apk 报 "luci-app-argon-config (no such package)"（2026-10-20 CI 实录）。
#
# 护栏: 仅当显式清单侧（kenzok8/克隆钉版）确有注册时才删 luci、packages 侧
#       （避免删完没有提供方）；
#       luci-app-argon-config 无显式清单提供也照删（上游已 PROVIDES 接管，
#       且我们本就不装该 app）。
# 时序: 必须在 install_feeds 之后调用，否则 symlink 会被重建。
# 移除条件: 上述 4 包在各 feed 不再撞名时本函数自动为空操作，可整段删除。
dedupe_feed_packages() {
    local name feed src dst
    for name in luci-theme-argon luci-app-smartdns smartdns luci-app-tailscale-community; do
        dst="$BUILD_DIR/package/feeds/openwrt_packages/$name"
        for feed in luci packages; do
            src="$BUILD_DIR/package/feeds/$feed/$name"
            if [ ! -e "$src" ] && [ ! -L "$src" ]; then
                continue
            fi
            if [ ! -e "$dst" ] && [ ! -L "$dst" ]; then
                echo "dedupe: 跳过 $name（kenzok8 侧未注册，保留 $feed 侧以免无提供方）" >&2
                continue
            fi
            rm -rf "$src"
            echo "dedupe: 已移除 $feed feed 的 $name（改用显式清单/钉版）"
        done
    done

    # 护栏项: 与 kenzok8 是否提供无关，只要出现就删
    local argon_app="$BUILD_DIR/package/feeds/luci/luci-app-argon-config"
    if [ -e "$argon_app" ] || [ -L "$argon_app" ]; then
        rm -rf "$argon_app"
        echo "dedupe: 已移除 luci feed 的 luci-app-argon-config（argon-config 已由主题内置/PKG_PROVIDES）"
    fi
}

remove_tweaked_packages() {
    local target_mk="$BUILD_DIR/include/target.mk"
    if [ -f "$target_mk" ]; then
        if grep -q "^DEFAULT_PACKAGES += \$(DEFAULT_PACKAGES.tweak)" "$target_mk"; then
            sed -i 's/DEFAULT_PACKAGES += $(DEFAULT_PACKAGES.tweak)/# DEFAULT_PACKAGES += $(DEFAULT_PACKAGES.tweak)/g' "$target_mk"
        fi
    fi
}

