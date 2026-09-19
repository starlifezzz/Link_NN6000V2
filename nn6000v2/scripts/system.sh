#!/usr/bin/env bash
change_dnsmasq2full() {
    if ! grep -q "dnsmasq-full" $BUILD_DIR/include/target.mk; then
        sed -i 's/dnsmasq/dnsmasq-full/g' $BUILD_DIR/include/target.mk
    fi
}

fix_default_set() {
    if [ -d "$BUILD_DIR/feeds/luci/collections/" ]; then
        find "$BUILD_DIR/feeds/luci/collections/" -type f -name "Makefile" -exec sed -i "s/luci-theme-bootstrap/luci-theme-$THEME_SET/g" {} \;
    fi

    install -Dm544 "$BASE_PATH/patches/990_set_argon_primary" "$BUILD_DIR/package/base-files/files/etc/uci-defaults/990_set_argon_primary"
    install -Dm544 "$BASE_PATH/patches/991_custom_settings" "$BUILD_DIR/package/base-files/files/etc/uci-defaults/991_custom_settings"
    install -Dm544 "$BASE_PATH/patches/992_network_config.sh" "$BUILD_DIR/package/base-files/files/etc/uci-defaults/992_network_config.sh"
    install -Dm544 "$BASE_PATH/patches/994_set_opkg_repos" "$BUILD_DIR/package/base-files/files/etc/uci-defaults/994_set_opkg_repos"
    # 996_fix_luci_homepage 已废弃：uwsgi START 改为 93（quickstart S92 之后），
    # 路由缓存竞态从源头解决，不再需要每次启动清缓存+重启 uwsgi。
    install -Dm544 "$BASE_PATH/patches/996_fix_luci_homepage" "$BUILD_DIR/package/base-files/files/etc/uci-defaults/996_fix_luci_homepage"
    install -Dm544 "$BASE_PATH/patches/997_install_nginx_icons" "$BUILD_DIR/package/base-files/files/etc/uci-defaults/997_install_nginx_icons"
    # 998/999: 保留（NSS 频率设置 + 防火墙加固）
    install -Dm544 "$BASE_PATH/patches/998_set_nss_freq" "$BUILD_DIR/package/base-files/files/etc/uci-defaults/998_set_nss_freq"
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
    sed -i 's/libustream-mbedtls/libustream-openssl/g' $BUILD_DIR/include/target.mk 2>/dev/null
    if [ -f $BUILD_DIR/target/linux/qualcommax/Makefile ]; then
        sed -i 's/wpad-openssl/wpad-mesh-openssl/g' $BUILD_DIR/target/linux/qualcommax/Makefile
    fi
}

fix_kconfig_recursive_dependency() {
    local file="$BUILD_DIR/scripts/package-metadata.pl"
    if [ -f "$file" ]; then
        sed -i 's/<PACKAGE_\$pkgname/!=y/g' "$file"
        echo "已修复 package-metadata.pl 的 Kconfig 递归依赖生成逻辑。"
    fi
}

update_default_lan_addr() {
    local CFG_PATH="$BUILD_DIR/package/base-files/files/bin/config_generate"
    if [ -f $CFG_PATH ]; then
        sed -i 's/192\.168\.[0-9]*\.[0-9]*/'$LAN_ADDR'/g' $CFG_PATH
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

# 修复 istore 全量备份还原后旧版 luci ucode 文件遮蔽 /rom 新版导致的
# luci RPC object 未注册（前端 -32000 Object not found、系统信息变 ?）。
# 每次开机（START=10，早于 rpcd START=12）用 /rom 固件自带版本覆盖。
install_luci_ucode_fix() {
    local target_dir="$BUILD_DIR/target/linux/qualcommax"

    if [ -d "$target_dir" ]; then
        install -Dm755 "$BASE_PATH/patches/fix_luci_ucode" "$target_dir/base-files/etc/init.d/fix_luci_ucode"
        echo "已安装 fix_luci_ucode 启动修复脚本 (luci ucode 版本自愈)"
    fi
}

# 部署 uhttpd 适配器（nginx→uhttpd 密码哈希桥接）+ rpcd 空密码哈希初始化。
# START=11，在 fix_luci_ucode (START=10) 之后运行。
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
# 均以 patches/ 下的修复版覆盖；另装 fix_istorex 运行期自愈（对抗备份还原）。
# 移除条件: kenzok8 feed 的 luci-app-quickstart 原生提供 /linkease/api 路由，
#           且其配套 autocore cpuinfo 输出自带温度后，可删除本函数与相关 patches。
install_istorex_fixes() {
    local target_dir="$BUILD_DIR/target/linux/qualcommax"

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

    # 3. 运行期自愈脚本（每次开机用 /rom 修复版覆盖被备份还原遮蔽的文件）
    if [ -d "$target_dir" ]; then
        install -Dm755 "$BASE_PATH/patches/fix_istorex" \
            "$target_dir/base-files/etc/init.d/fix_istorex"
        echo "已安装 fix_istorex 运行期自愈脚本 (istorex 温度/路由自愈)"
    fi
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
        echo "警告: 未找到 $dts，跳过 NN6000 按键 GPIO 冲突修复"
        return 1
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
        echo "警告: 未找到 qualcommax target，跳过调优脚本安装"
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

fix_hash_value() {
    local makefile_path="$1"
    local old_hash="$2"
    local new_hash="$3"
    local package_name="$4"

    if [ -f "$makefile_path" ]; then
        sed -i "s/$old_hash/$new_hash/g" "$makefile_path"
        echo "已修正 $package_name 的哈希值。"
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
    mkdir -p "$cron_dir"
    cat >"$cron_dir/root" <<'EOF'
15 3 * * * sync && echo 3 > /proc/sys/vm/drop_caches
3 3 12 12 * /usr/bin/nginx-util 'check_ssl'
EOF
    chmod 600 "$cron_dir/root"
    echo "已写入 cron 任务到 base-files（构建时）"
}

update_nss_diag() {
    local file="$BUILD_DIR/package/base-files/files/usr/bin/nss_diag.sh"
    mkdir -p "$(dirname "$file")"
    install -Dm755 "$BASE_PATH/patches/nss_diag.sh" "$file"
    echo "已安装 nss_diag.sh 到 /usr/bin/"
}

fix_compile_coremark() {
    local file="$BUILD_DIR/feeds/packages/utils/coremark/Makefile"
    if [ -d "$(dirname "$file")" ] && [ -f "$file" ]; then
        sed -i 's/mkdir \$/mkdir -p \$/g' "$file"
    fi
}

update_dnsmasq_conf() {
    local file="$BUILD_DIR/package/network/services/dnsmasq/files/dhcp.conf"
    if [ -d "$(dirname "$file")" ] && [ -f "$file" ]; then
        sed -i '/dns_redirect/d' "$file"
    fi
}

add_backup_info_to_sysupgrade() {
    local conf_path="$BUILD_DIR/package/base-files/files/etc/sysupgrade.conf"

    if [ -f "$conf_path" ]; then
        cat >"$conf_path" <<'EOF'
/etc/easytier
/etc/lucky/
EOF
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
    # 补充缺失的 zlib 依赖
    if grep -q 'DEPENDS:=.*+i386:libatomic +libopenssl' "$makefile"; then
        if ! grep -q '+zlib' "$makefile"; then
            sed -i 's/DEPENDS:=+i386:libatomic +libopenssl/DEPENDS:=+i386:libatomic +libopenssl +zlib/' "$makefile"
        fi
    fi
    
    echo "smartdns Makefile 修复完成"
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
        echo "已更新 nginx-mod-ubus 模块的 SOURCE_DATE, SOURCE_VERSION 和 MIRROR_HASH。"
    else
        echo "错误：未找到 $makefile_path 文件，无法更新 nginx-mod-ubus 模块。" >&2
    fi
}

fix_nginx_configure() {
    local makefile_path="$BUILD_DIR/feeds/packages/net/nginx/Makefile"
    if [ -f "$makefile_path" ]; then
        # 移除不支持的 autotools 参数
        sed -i 's/--target=.*\s//g' "$makefile_path"
        sed -i 's/--host=.*\s//g' "$makefile_path"
        sed -i 's/--disable-dependency-tracking\s//g' "$makefile_path"
        sed -i 's/--program-prefix=.*\s//g' "$makefile_path"
        sed -i 's/--program-suffix=.*\s//g' "$makefile_path"
        echo "已修复 nginx 配置参数，移除不支持的 autotools 选项。"
    else
        echo "错误：未找到 $makefile_path 文件，无法修复 nginx 配置。" >&2
    fi
}

fix_openssl_ktls() {
    local config_in="$BUILD_DIR/package/libs/openssl/Config.in"
    if [ -f "$config_in" ]; then
        echo "正在更新 OpenSSL kTLS 配置..."
        sed -i 's/select PACKAGE_kmod-tls/depends on PACKAGE_kmod-tls/g' "$config_in"
        sed -i '/depends on PACKAGE_kmod-tls/a\\tdefault y if PACKAGE_kmod-tls' "$config_in"
    fi
}

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
    # nginx-ssl-util 安装的 UCI config 源文件是 files/nginx（→ /etc/config/nginx）
    # 不是 files/nginx.config，也不是 /etc/nginx/conf.d/
    local nginx_uci="$BUILD_DIR/feeds/packages/net/nginx-util/files/nginx"
    if [ -f "$nginx_uci" ] && [ -f "$BASE_PATH/patches/nginx.config" ]; then
        \cp -f "$BASE_PATH/patches/nginx.config" "$nginx_uci"
        echo "已覆盖 nginx UCI config（files/nginx → /etc/config/nginx）"
    fi

    # quickstart_icons.location：通过 uci-defaults 997 安装到 /etc/nginx/conf.d/
    # 构建期 base-files/files/ 不适合安装 nginx conf.d 文件（squashfs 打包时
    # 目录可能不存在或被 nginx-mod-luci 覆盖），uci-defaults 写 overlay 更可靠

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

remove_tweaked_packages() {
    local target_mk="$BUILD_DIR/include/target.mk"
    if [ -f "$target_mk" ]; then
        if grep -q "^DEFAULT_PACKAGES += \$(DEFAULT_PACKAGES.tweak)" "$target_mk"; then
            sed -i 's/DEFAULT_PACKAGES += $(DEFAULT_PACKAGES.tweak)/# DEFAULT_PACKAGES += $(DEFAULT_PACKAGES.tweak)/g' "$target_mk"
        fi
    fi
}

