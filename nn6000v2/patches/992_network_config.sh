#!/bin/sh
# ============================================================
# 网络初始化配置脚本
# 首次启动时自动配置 WiFi 和 PPPoE 宽带
# ============================================================

# ==================== WiFi 配置 ====================
# 5G WiFi 设置
WIFI_5G_SSID="500/5"
WIFI_5G_KEY="147258369"
WIFI_5G_CHANNEL=36
WIFI_5G_TXPOWER=24

# 2.4G WiFi 设置
WIFI_2G_SSID="500/5"
WIFI_2G_KEY="147258369"
WIFI_2G_CHANNEL=1
WIFI_2G_TXPOWER=22

# ==================== PPPoE 宽带配置 ====================
# 填写你的宽带账号密码，使用 "-" 表示跳过配置
# 在 GitHub Actions 构建时可以通过输入参数自动替换此处的值
PPPOE_USERNAME="-"
PPPOE_PASSWORD="-"
# ============================================================

board_name=$(cat /tmp/sysinfo/board_name 2>/dev/null)

configure_wifi() {
	local radio=$1 band=$2 channel=$3 htmode=$4
	local txpower=$5 ssid=$6 key=$7
	local encryption=${8:-"psk2+ccmp"}
	local now_encryption=$(uci -q get wireless.default_radio${radio}.encryption)

	if [ -n "$now_encryption" ] && [ "$now_encryption" != "none" ]; then
		return 1  # 返回 1 表示"已配置，跳过"
	fi

	uci -q batch <<EOF
set wireless.radio${radio}.band="${band}"
set wireless.radio${radio}.channel="${channel}"
set wireless.radio${radio}.htmode="${htmode}"
set wireless.radio${radio}.mu_beamformer='1'
set wireless.radio${radio}.country='US'
set wireless.radio${radio}.txpower="${txpower}"
set wireless.radio${radio}.cell_density='0'
set wireless.radio${radio}.disabled='1'
set wireless.default_radio${radio}.ssid="${ssid}"
set wireless.default_radio${radio}.encryption="${encryption}"
set wireless.default_radio${radio}.key="${key}"
set wireless.default_radio${radio}.ieee80211k='1'
set wireless.default_radio${radio}.time_advertisement='2'
set wireless.default_radio${radio}.time_zone='CST-8'
set wireless.default_radio${radio}.bss_transition='1'
set wireless.default_radio${radio}.wnm_sleep_mode='1'
set wireless.default_radio${radio}.wnm_sleep_mode_no_keys='1'
EOF
	return 0  # 返回 0 表示"新配置了"
}

link_nn6000v2_wifi_cfg() {
	local changed=0
	configure_wifi 0 '5g' $WIFI_5G_CHANNEL 'HE80' $WIFI_5G_TXPOWER "$WIFI_5G_SSID" "$WIFI_5G_KEY" && changed=1
	configure_wifi 1 '2g' $WIFI_2G_CHANNEL 'HT20' $WIFI_2G_TXPOWER "$WIFI_2G_SSID" "$WIFI_2G_KEY" && changed=1

	if [ "$changed" -eq 1 ]; then
		uci commit wireless
		return 0  # 有改动
	fi
	return 1  # 无改动
}

# 返回值：0=修改了配置需要重启, 1=跳过无需重启
setup_pppoe() {
	if [ "$PPPOE_USERNAME" = "-" ] || [ "$PPPOE_PASSWORD" = "-" ]; then
		echo "PPPoE: 使用占位符，跳过配置"
		return 1
	fi

	if [ ! -f /etc/config/network ]; then
		echo "PPPoE: network 配置文件不存在"
		return 1
	fi

	local wan_proto=$(uci -q get network.wan.proto)
	local wan_username=$(uci -q get network.wan.username)
	local wan_password=$(uci -q get network.wan.password)

	if [ "$wan_proto" = "pppoe" ] && [ "$wan_username" != "-" ] && [ "$wan_password" != "-" ]; then
		echo "PPPoE: 已配置有效账号，跳过"
		return 1
	fi

	uci -q batch <<EOF
set network.wan.proto='pppoe'
set network.wan.username='${PPPOE_USERNAME}'
set network.wan.password='${PPPOE_PASSWORD}'
set network.wan.keepalive='5 3'
set network.wan.demand='0'
EOF

	# PPPoE 场景下删除 config_generate 自动生成的 wan6
	# netifd 会自动派生绑定到 pppoe-wan 的 wan_6
	uci -q delete network.wan6

	uci commit network
	echo "PPPoE: 配置完成 - 用户名: ${PPPOE_USERNAME}"
	return 0
}

# ==================== 主流程 ====================
need_restart=0

case "${board_name}" in
link,nn6000-v2)
	link_nn6000v2_wifi_cfg && need_restart=1
	;;
esac

setup_pppoe && need_restart=1

if [ "$need_restart" -eq 1 ]; then
	echo "配置已更改，正在重启网络..."
	/etc/init.d/network restart
fi