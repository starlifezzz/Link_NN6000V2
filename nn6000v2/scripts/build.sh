#!/usr/bin/env bash

set -e

# Determine nn6000v2 path
if [ -d "nn6000v2" ]; then
    NN6000V2_PATH="nn6000v2"
elif [ -d "../nn6000v2" ]; then
    NN6000V2_PATH="../nn6000v2"
else
    echo "Error: nn6000v2 directory not found!"
    exit 1
fi

BASE_PATH=$(cd "$NN6000V2_PATH" && pwd)

Dev=$1
Build_Mod=$2

CONFIG_FILE="$BASE_PATH/configs/$Dev.config"

if [[ ! -f $CONFIG_FILE ]]; then
    echo "Config not found: $CONFIG_FILE"
    exit 1
fi

# Use environment variables or defaults for repo config
# 默认回退原版 VIKINGYFY/immortalwrt (main)，含完整 NSS 生态
REPO_URL=${REPO_URL:-https://github.com/VIKINGYFY/immortalwrt.git}
REPO_BRANCH=${REPO_BRANCH:-main}

# 官方仓库（如需切换，取消注释下一行并注释上面两行）
# REPO_URL=${REPO_URL:-https://github.com/immortalwrt/immortalwrt.git}
# REPO_BRANCH=${REPO_BRANCH:-master}

BUILD_DIR=${BUILD_DIR:-imm-nss}
COMMIT_HASH=${COMMIT_HASH:-none}

remove_uhttpd_dependency() {
    local config_path="$BASE_PATH/../$BUILD_DIR/.config"
    local luci_makefile_path="$BASE_PATH/../$BUILD_DIR/feeds/luci/collections/luci/Makefile"

    if grep -q "CONFIG_PACKAGE_luci-app-quickfile=y" "$config_path"; then
        if [ -f "$luci_makefile_path" ]; then
            sed -i '/luci-light/d' "$luci_makefile_path"
            echo "Removed uhttpd (luci-light) dependency as luci-app-quickfile (nginx) is enabled."
        fi
    fi
}

apply_config() {
    \cp -f "$CONFIG_FILE" "$BASE_PATH/../$BUILD_DIR/.config"
}

fix_netfilter_kmod_clash() {
    local include_netfilter_mk="$BASE_PATH/../$BUILD_DIR/include/netfilter.mk"
    local netfilter_mk="$BASE_PATH/../$BUILD_DIR/package/kernel/linux/modules/netfilter.mk"

    if [ ! -f "$include_netfilter_mk" ]; then
        echo "Netfilter include file not found: $include_netfilter_mk" >&2
        return 1
    fi

    if [ ! -f "$netfilter_mk" ]; then
        echo "Netfilter makefile not found: $netfilter_mk" >&2
        return 1
    fi

    if grep -q 'CONFIG_IP_NF_IPTABLES_LEGACY, $(P_V4)ip_tables, ge 6.12' "$include_netfilter_mk" && \
       grep -q 'CONFIG_IP6_NF_IPTABLES_LEGACY, $(P_V6)ip6_tables, ge 6.12' "$include_netfilter_mk" && \
       grep -q 'DEPENDS:=+(!(LINUX_6_12||LINUX_6_18)):kmod-iptables' "$netfilter_mk"; then
        echo "Netfilter kmod clash workaround already applied"
        return 0
    fi

    if grep -q '$(eval $(if $(NF_KMOD),$(call nf_add,NF_IPT,CONFIG_IP_NF_IPTABLES, $(P_V4)ip_tables),))' "$include_netfilter_mk"; then
        echo "Updating NF_IPT mapping for Linux 6.12/6.18..."
        sed -i 's@$(eval $(if $(NF_KMOD),$(call nf_add,NF_IPT,CONFIG_IP_NF_IPTABLES, $(P_V4)ip_tables),))@$(eval $(if $(NF_KMOD),$(call nf_add,NF_IPT,CONFIG_IP_NF_IPTABLES, $(P_V4)ip_tables, lt 6.12),))@' "$include_netfilter_mk"
        sed -i '/CONFIG_IP_NF_IPTABLES, $(P_V4)ip_tables, lt 6\.12)/a$(eval $(if $(NF_KMOD),$(call nf_add,NF_IPT,CONFIG_IP_NF_IPTABLES_LEGACY, $(P_V4)ip_tables, ge 6.12),))' "$include_netfilter_mk"
    fi

    if grep -q '$(eval $(if $(NF_KMOD),,$(call nf_add,IPT_CORE,CONFIG_IP_NF_IPTABLES, xt_standard ipt_icmp xt_tcp xt_udp xt_comment xt_set xt_SET)))' "$include_netfilter_mk"; then
        echo "Updating IPT_CORE userland mapping for Linux 6.12/6.18..."
        sed -i 's@$(eval $(if $(NF_KMOD),,$(call nf_add,IPT_CORE,CONFIG_IP_NF_IPTABLES, xt_standard ipt_icmp xt_tcp xt_udp xt_comment xt_set xt_SET)))@$(eval $(if $(NF_KMOD),,$(call nf_add,IPT_CORE,CONFIG_IP_NF_IPTABLES, xt_standard ipt_icmp xt_tcp xt_udp xt_comment xt_set xt_SET, lt 6.12)))@' "$include_netfilter_mk"
        sed -i '/CONFIG_IP_NF_IPTABLES, xt_standard ipt_icmp xt_tcp xt_udp xt_comment xt_set xt_SET, lt 6\.12))/a$(eval $(if $(NF_KMOD),,$(call nf_add,IPT_CORE,CONFIG_IP_NF_IPTABLES_LEGACY, xt_standard ipt_icmp xt_tcp xt_udp xt_comment xt_set xt_SET, ge 6.12)))' "$include_netfilter_mk"
    fi

    if grep -q '$(eval $(if $(NF_KMOD),$(call nf_add,NF_IPT6,CONFIG_IP6_NF_IPTABLES, $(P_V6)ip6_tables),))' "$include_netfilter_mk"; then
        echo "Updating NF_IPT6 mapping for Linux 6.12/6.18..."
        sed -i 's@$(eval $(if $(NF_KMOD),$(call nf_add,NF_IPT6,CONFIG_IP6_NF_IPTABLES, $(P_V6)ip6_tables),))@$(eval $(if $(NF_KMOD),$(call nf_add,NF_IPT6,CONFIG_IP6_NF_IPTABLES, $(P_V6)ip6_tables, lt 6.12),))@' "$include_netfilter_mk"
        sed -i '/CONFIG_IP6_NF_IPTABLES, $(P_V6)ip6_tables, lt 6\.12)/a$(eval $(if $(NF_KMOD),$(call nf_add,NF_IPT6,CONFIG_IP6_NF_IPTABLES_LEGACY, $(P_V6)ip6_tables, ge 6.12),))' "$include_netfilter_mk"
    fi

    if grep -q '$(eval $(if $(NF_KMOD),,$(call nf_add,IPT_IPV6,CONFIG_IP6_NF_IPTABLES, ip6t_icmp6)))' "$include_netfilter_mk"; then
        echo "Updating IPT_IPV6 userland mapping for Linux 6.12/6.18..."
        sed -i 's@$(eval $(if $(NF_KMOD),,$(call nf_add,IPT_IPV6,CONFIG_IP6_NF_IPTABLES, ip6t_icmp6)))@$(eval $(if $(NF_KMOD),,$(call nf_add,IPT_IPV6,CONFIG_IP6_NF_IPTABLES, ip6t_icmp6, lt 6.12)))@' "$include_netfilter_mk"
        sed -i '/CONFIG_IP6_NF_IPTABLES, ip6t_icmp6, lt 6\.12))/a$(eval $(if $(NF_KMOD),,$(call nf_add,IPT_IPV6,CONFIG_IP6_NF_IPTABLES_LEGACY, ip6t_icmp6, ge 6.12)))' "$include_netfilter_mk"
    fi

    if grep -q 'DEPENDS:=+!LINUX_6_12:kmod-iptables' "$netfilter_mk"; then
        echo "Applying netfilter kmod clash workaround for Linux 6.12/6.18..."
        sed -i 's/DEPENDS:=+!LINUX_6_12:kmod-iptables/DEPENDS:=+(!(LINUX_6_12||LINUX_6_18)):kmod-iptables/' "$netfilter_mk"
        return 0
    fi

    echo "Netfilter kmod clash workaround applied successfully"
}

if [[ -d action_build ]]; then
    BUILD_DIR="action_build"
fi

"$BASE_PATH/scripts/update.sh" "$REPO_URL" "$REPO_BRANCH" "$BUILD_DIR" "$COMMIT_HASH"

# 清理 gettext 缓存和构建文件
if [ -d "$BASE_PATH/../$BUILD_DIR/build_dir/hostpkg/gettext-1.0" ]; then
    echo "清理旧的 gettext 构建文件..."
    rm -rf "$BASE_PATH/../$BUILD_DIR/build_dir/hostpkg/gettext-1.0"
    rm -f "$BASE_PATH/../$BUILD_DIR/staging_dir/hostpkg/stamp/.package_*.gettext*"
fi

apply_config
fix_netfilter_kmod_clash
remove_uhttpd_dependency

# Modify kernel size to 12MB for ipq60xx devices
# modify_kernel_size() {
#     local ipq60xx_mk_path="$BASE_PATH/../$BUILD_DIR/target/linux/qualcommax/image/ipq60xx.mk"
    
#     if [ -f "$ipq60xx_mk_path" ]; then
#         # Change KERNEL_SIZE from 6144k to 12288k for link_nn6000 devices
#         sed -i '/link_nn6000-common/,/endef/{s/KERNEL_SIZE := 6144k/KERNEL_SIZE := 12288k/g}' "$ipq60xx_mk_path"
#         echo "Updated KERNEL_SIZE to 12288k (12MB) for link_nn6000 devices"
#     fi
# }

# 适配imwrt官方
modify_kernel_size() {
    local ipq60xx_mk_path="$BASE_PATH/../$BUILD_DIR/target/linux/qualcommax/image/ipq60xx.mk"
    
    if [ -f "$ipq60xx_mk_path" ]; then
        # 更灵活的正则，处理 endef 前可能有空格的情况
        sed -i '/define Device\/link_nn6000-v[12]/,/^[[:space:]]*endef[[:space:]]*$/{s/KERNEL_SIZE := 6144k/KERNEL_SIZE := 12288k/}' "$ipq60xx_mk_path"
        
        # 验证修改是否成功
        if grep -q "link_nn6000-v[12]" "$ipq60xx_mk_path" && grep -q "KERNEL_SIZE := 12288k" "$ipq60xx_mk_path"; then
            echo "✓ Updated KERNEL_SIZE to 12288k (12MB) for link_nn6000 devices"
        else
            echo "✗ Warning: KERNEL_SIZE update may have failed, please verify manually"
        fi
    else
        echo "✗ Error: ipq60xx.mk not found at $ipq60xx_mk_path"
        return 1
    fi
}

modify_kernel_size

# 防御性覆盖 GL-AX1800 的 dts 为已知健康版本
# 背景: VIKINGYFY main 与 upstream/master 合并（commit 6353e1f "Merge remote-tracking
#       branch 'upstream/master'"）曾造成 ipq60xx.mk / 多个 dts 冲突，其 merge 窗口期
#       ipq6000-glinet.dtsi 的 include 链损坏导致 dtc phandle_references 报错
#       （dp1-dp5 引用无法解析），连累整个 ipq60xx 内核 DTS 编译失败。
#       当前上游已修复，本函数为防御性保险：若上游再次 merge 破坏 glinet 系列 dts，
#       构建时强制覆盖为已知健康版本，保证 link_nn6000 的共享 dtsi（ipq6018-ess.dtsi
#       等）不受影响。link_nn6000 自身不依赖 ipq6000-glinet.dtsi，覆盖仅影响 gl-ax1800
#       设备定义，不改变我们目标设备行为。
# 注意: 覆盖会丢弃上游对 glinet 系列 dts 的未来改进（本仓库仅使用 link_nn6000，
#       影响可忽略）。上游彻底修复并稳定后可移除本函数。
restore_glinet_dts() {
    local dts_dir="$BASE_PATH/../$BUILD_DIR/target/linux/qualcommax/dts"
    local patch_dir="$BASE_PATH/patches"

    if [ ! -d "$dts_dir" ]; then
        echo "✗ Warning: qualcommax dts dir not found at $dts_dir, skip glinet dts restore"
        return 1
    fi

    # 仅当上游文件缺失或 include 链明显损坏（缺少 ipq6018-ess.dtsi）时才覆盖，
    # 避免每次构建都无谓地覆盖上游改进
    if [ ! -f "$dts_dir/ipq6000-glinet.dtsi" ] || \
       ! grep -q 'ipq6018-ess.dtsi' "$dts_dir/ipq6000-glinet.dtsi"; then
        echo "✓ Restoring healthy glinet dts (gl-ax1800 include chain) from patches/"
        \cp -f "$patch_dir/ipq6000-glinet.dtsi" "$dts_dir/ipq6000-glinet.dtsi"
        \cp -f "$patch_dir/ipq6000-gl-ax1800.dts" "$dts_dir/ipq6000-gl-ax1800.dts"
    else
        echo "✓ glinet dts include chain intact, skip restore"
    fi
}

restore_glinet_dts

# 仅保留 link_nn6000-v2，禁用 VIKINGYFY 其余 ipq60xx 设备的 DTB/镜像编译
# 背景: 本 .config 仅显式声明 link_nn6000-v2=y，未对 VIKINGYFY 其余 31 个
#       ipq60xx 设备写 =n。实际构建中观察到 glinet_gl-ax1800 的 DTS 被编译，
#       且 VIKINGYFY main 近期与 upstream/master 合并后 ipq60xx.mk/多个 dts
#       存在冲突（见 VIKINGYFY main 最新 merge commit），其 dts include 链
#       解析失败导致 dtc phandle_references 报错。
#       为避免依赖上游合并状态，这里显式裁剪：只保留 link_nn6000-v2，
#       其余设备无论因何被 defconfig 选中一律置 n（自愈式，上游新增设备也安全）。
# 注意: make defconfig 后必须再调用一次（defconfig 会补齐缺失符号默认值）。
restrict_to_link_nn6000() {
    local device_line
    # 1. 将所有 ipq60xx 设备的 DEVICE_*=y 行全部置 n（含 link_nn6000-v1/v2）
    grep -E '^CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_.+=y$' .config | while IFS= read -r device_line; do
        sed -i "s|^${device_line%=y}=y$|${device_line%=y}=n|" .config
    done
    # 2. 把 link_nn6000-v2 恢复为 y
    sed -i 's/^CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_link_nn6000-v2=n$/CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_link_nn6000-v2=y/' .config
}

cd "$BASE_PATH/../$BUILD_DIR"
make defconfig
restrict_to_link_nn6000
make defconfig

if [[ $Build_Mod == "debug" ]]; then
    exit 0
fi

TARGET_DIR="$BASE_PATH/../$BUILD_DIR/bin/targets"
if [[ -d $TARGET_DIR && "$Dev" != *"nowifi"* ]]; then
    find "$TARGET_DIR" -type f \( -name "*.bin" -o -name "*.manifest" -o -name "*efi.img.gz" -o -name "*.itb" -o -name "*.fip" -o -name "*.ubi" -o -name "*rootfs.tar.gz" \) -exec rm -f {} +
fi

if [[ "$Dev" != *"nowifi"* ]]; then
    make download -j$(($(nproc) * 2))
    make -j$(($(nproc) + 1)) || make -j1 V=s
fi

if [[ -d action_build ]]; then
    make clean
fi

# 如果是正常版本编译，完成后自动编译无 WiFi 版本
if [[ "$Dev" != *"nowifi"* ]]; then
    echo ""
    echo "=============================================="
    echo "  版本编译完成！"
    echo "  开始编译无 WiFi 版本..."
    echo "=============================================="
    echo ""
    
    # 先复制带 WiFi 版本到最终目录
    FIRMWARE_DIR="$BASE_PATH/../firmware"
    \rm -rf "$FIRMWARE_DIR"
    mkdir -p "$FIRMWARE_DIR"
    find "$TARGET_DIR" -type f \( -name "*.bin" -o -name "*.manifest" -o -name "*efi.img.gz" -o -name "*.itb" -o -name "*.fip" -o -name "*.ubi" -o -name "*rootfs.tar.gz" \) -exec cp -f {} "$FIRMWARE_DIR/" \;
    
    # 生成 nowifi 版本的 .config（通过管道生成，不修改源配置，避免中途失败污染源文件）
    cd "$BASE_PATH/../$BUILD_DIR"
    
    echo "应用配置..."
    sed -e 's/^CONFIG_PACKAGE_kmod-ath=y$/CONFIG_PACKAGE_kmod-ath=n/' \
        -e 's/^CONFIG_PACKAGE_kmod-ath11k=y$/CONFIG_PACKAGE_kmod-ath11k=n/' \
        -e 's/^CONFIG_PACKAGE_kmod-ath11k-ahb=y$/CONFIG_PACKAGE_kmod-ath11k-ahb=n/' \
        -e 's/^CONFIG_PACKAGE_kmod-ath11k-pci=y$/CONFIG_PACKAGE_kmod-ath11k-pci=n/' \
        -e 's/^CONFIG_PACKAGE_ath11k-firmware-ipq6018=y$/CONFIG_PACKAGE_ath11k-firmware-ipq6018=n/' \
        -e 's/^CONFIG_PACKAGE_ath11k-firmware-ipq6018-ddwrt=y$/CONFIG_PACKAGE_ath11k-firmware-ipq6018-ddwrt=n/' \
        -e 's/^CONFIG_PACKAGE_ath11k-firmware-qcn9074=y$/CONFIG_PACKAGE_ath11k-firmware-qcn9074=n/' \
        -e 's/^CONFIG_PACKAGE_ath11k-firmware-qcn9074-ddwrt=y$/CONFIG_PACKAGE_ath11k-firmware-qcn9074-ddwrt=n/' \
        "$CONFIG_FILE" > .config

    # 关键: wpad-openssl / kmod-ath11k* 位于 qualcommax/Makefile 的
    # DEFAULT_PACKAGES（第 14-16 行），而 DEFAULT_PACKAGES 优先级高于 .config
    # 的 =n —— 只改 .config 无法真正移除。必须从 target Makefile 直接删除，
    # nowifi 才能不含 WiFi 组件（否则 wpad 会拉起 hostapd/wpa_supplicant 空转、
    # ath11k 空包占 rootfs 空间）。
    # 仅影响本次 nowifi 构建（WiFi 版此前已构建完成）。
    qca_mk="$BASE_PATH/../$BUILD_DIR/target/linux/qualcommax/Makefile"
    if [ -f "$qca_mk" ]; then
        # 注意: 名称必须是 wpad-mesh-openssl —— system.sh 的 fix_mk_def_depends
        # 已把默认的 wpad-openssl 替换成 wpad-mesh-openssl（真机包名证实），
        # 只写 wpad-openssl 不会匹配，nowifi 仍会带上 wpad。
        sed -i 's/\bwpad-mesh-openssl\b//g; s/\bwpad-openssl\b//g; s/\bkmod-ath11k-ahb\b//g; s/\bkmod-ath11k-pci\b//g; s/\bkmod-ath11k\b//g' "$qca_mk"
        echo "✓ nowifi: 已从 DEFAULT_PACKAGES 移除 wpad-mesh-openssl / kmod-ath11k*"
    fi

    make defconfig
    restrict_to_link_nn6000
    make defconfig
    
    echo "编译无 WiFi 版本..."
    make -j$(($(nproc) + 1)) || make -j1 V=s
    
    echo "复制固件..."
    find "$TARGET_DIR" -type f \( -name "*.bin" -o -name "*.manifest" -o -name "*efi.img.gz" -o -name "*.itb" -o -name "*.fip" -o -name "*.ubi" -o -name "*rootfs.tar.gz" \) | while read -r file; do
        filename=$(basename "$file")
        new_filename=$(echo "$filename" | sed 's/\.\([^.]*\)$/_nowifi.\1/')
        echo "Copying: $filename -> $new_filename"
        cp -f "$file" "$FIRMWARE_DIR/$new_filename"
    done
    
    echo ""
    echo "=============================================="
    echo "  双版本已编译完成！"
    echo "  输出目录：$FIRMWARE_DIR"
    echo "=============================================="
    echo ""
    
    if [[ -d action_build ]]; then
        make clean
    fi
    
    exit 0
fi
