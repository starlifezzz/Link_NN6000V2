#!/bin/sh
######################################################################
# healthcheck.sh - Link_NN6000V2 固件层体检（H1-H6）
#
# 用法（本机执行，管道送进设备）:
#   ssh -i ~/.ssh/id_ed25519 -p 223 root@10.0.0.1 'sh -s' \
#       < nn6000v2/scripts/healthcheck.sh
#
# 退出码: 0=无 FAIL；1=存在 FAIL（便于脚本化/监控）
#
# 目标为 busybox ash（无 find -newermt / ls --time-style / netstat -i /
# cat -A / pgrep -c / ps -o / ps -a），本脚本已规避这些坑。
#
# 路径可用环境变量覆盖（自测 / 失败路径演示用）:
#   APK_DB APK_WORLD ECM_DB FOS ROM
#   e.g. APK_WORLD=/etc/hostname sh healthcheck.sh   # 人为制造 db!=world → 必须 FAIL 且 rc=1
######################################################################

APK_DB=${APK_DB:-/lib/apk/db/installed}
APK_WORLD=${APK_WORLD:-/etc/apk/world}
ECM_DB=${ECM_DB:-/sys/kernel/debug/ecm/ecm_db}
FOS=${FOS:-/etc/init.d/fix_overlay_shadow}
ROM=${ROM:-/rom}

FAIL=0
WARN=0

# dmesg 可读性前置探测：不可读时相关检查必须 FAIL，不得用"0 命中"冒充通过（fail-safe）
DMESG_OK=1
dmesg >/dev/null 2>&1 || DMESG_OK=0
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL + 1)); }
warn() { echo "  [WARN] $*"; WARN=$((WARN + 1)); }
info() { echo "  [info] $*"; }

echo "===== 0. 环境 ====="
info "uptime:  $(cut -d' ' -f1 /proc/uptime)s"
info "loadavg: $(cut -d' ' -f1-3 /proc/loadavg)"
info "kernel:  $(uname -r)"
info "mem:     $(awk '/MemTotal/{printf "%.0f MB", $2/1024}' /proc/meminfo) (swap $(awk '/SwapTotal/{printf "%.0f MB", $2/1024}' /proc/meminfo))"

echo "===== H1 apk db/world 一致性 ====="
dbn=$(grep -c '^P:' "$APK_DB" 2>/dev/null)
wn=$(wc -l < "$APK_WORLD" 2>/dev/null)
info "db(P:)=$dbn  world=$wn"
if [ -n "$dbn" ] && [ -n "$wn" ] && [ "$dbn" = "$wn" ]; then
    ok "db==world ($dbn)"
else
    bad "db($dbn) != world($wn)"
fi
apk add --simulate luci >/dev/null 2>&1
[ $? -eq 0 ] && ok "apk add --simulate luci rc=0" || bad "apk add --simulate luci rc!=0"
apk fix --simulate >/dev/null 2>&1
[ $? -eq 0 ] && ok "apk fix --simulate rc=0" || bad "apk fix --simulate rc!=0"
info "world 中 '><' pin 令牌行数: $(grep -c '><' "$APK_WORLD" 2>/dev/null)（合法语法）"

echo "===== H2 NSS/ECM offload ====="
for m in qca_nss_drv qca_nss_dp qca_ssdk ecm; do
    if lsmod | grep -qE "^${m}[[:space:]]"; then ok "模块 $m 已加载"; else bad "模块 $m 缺失"; fi
done
for n in connection_count node_count host_count iface_count; do
    v=$(cat "$ECM_DB/$n" 2>/dev/null)
    [ -n "$v" ] && ok "ecm/$n = $v" || warn "ecm/$n 不可读"
done

echo "===== H3 存储/overlay/eMMC ====="
mline=$(mount | grep ' on /overlay ')
if [ -z "$mline" ]; then
    bad "/overlay 未挂载"
else
    echo "$mline" | grep -q '(rw' && ok "/overlay 已挂载且可写" || bad "/overlay 只读"
fi
df -h /overlay / 2>/dev/null | sed 's/^/  [info] /'
cnt=$(cat /etc/emmc_health.count 2>/dev/null)
case "$cnt" in
    ''|*[!0-9]*) warn "emmc_health.count 不可读/非数字: '$cnt'" ;;
    0)           ok "eMMC 健康计数 0" ;;
    *)           warn "eMMC 健康计数非 0: $cnt" ;;
esac
if [ "$DMESG_OK" = 1 ]; then
    ioerr=$(dmesg | grep -c 'mmcblk0.*error')
    [ "$ioerr" = "0" ] && ok "mmcblk0 无 I/O 错误" || warn "mmcblk0 I/O 错误计数: $ioerr"
    rec=$(dmesg | grep -cE 'EXT4-fs \(sda1\): recovery complete')
    [ "$rec" = "0" ] && info "本次开机无 ext4 recovery" || info "本次开机有 ext4 recovery（=上次非正常关机，C7.4）"
else
    bad "dmesg 不可读，无法检查 mmcblk0 I/O 与 ext4 recovery"
fi

echo "===== H4 崩溃取证 ====="
if [ -d /sys/fs/pstore ]; then warn "/sys/fs/pstore 存在（检查残留）"; else ok "无 pstore 残留（该目录不存在）"; fi
if [ "$DMESG_OK" = 1 ]; then
    oops=$(dmesg | grep -iE 'oops|BUG:|kernel panic' | grep -vc ramoops)
    [ "$oops" = "0" ] && ok "dmesg 无 oops/BUG/panic" || bad "dmesg 命中 $oops 行"
else
    bad "dmesg 不可读，无法检查 oops/BUG/panic"
fi
dz=$(ps | grep -c '[d]efunct')
[ "$dz" = "0" ] && ok "无 defunct 进程" || warn "defunct 进程: $dz"

echo "===== H5 产物/内容核对 ====="
info "revision: $(grep -o "DISTRIB_REVISION='[^']*'" "$ROM/etc/openwrt_release" 2>/dev/null | cut -d"'" -f2)"
# 变体判据（C4.1 口径）：/rom 无 usr/sbin/wpad* / hostapd* 且无 lib/firmware/ath11k → nowifi。
# 只认文件内容，不看 apk db（手工 apk add wpad 会污染 db，导致误判）。
if [ ! -d "$ROM" ]; then
    warn "$ROM 不存在，无法按内容判定变体"
else
    wf=0
    for p in "$ROM"/usr/sbin/wpad* "$ROM"/usr/sbin/hostapd*; do
        [ -e "$p" ] && wf=$((wf + 1))
    done
    af=0
    [ -d "$ROM/lib/firmware/ath11k" ] && af=1
    if [ "$wf" -gt 0 ] || [ "$af" -gt 0 ]; then
        info "变体: WiFi（/rom 无线二进制 ${wf} 个，ath11k fw 目录 ${af}）"
    else
        info "变体: nowifi（/rom 无 wpad/hostapd，无 lib/firmware/ath11k）"
    fi
fi
nw=$(grep -cE '^P:.*(ath11k|wpad|hostapd)' "$APK_DB" 2>/dev/null)
info "  附: apk db 无线包命中 ${nw:-0}（仅参考，判据以 /rom 内容为准）"
if [ -f "$FOS" ]; then info "$(basename "$FOS") md5: $(md5sum "$FOS" | cut -d' ' -f1)"; else warn "$FOS 不存在"; fi

echo "===== H6 温度/频率 ====="
if command -v tempinfo >/dev/null 2>&1; then tempinfo 2>/dev/null | sed 's/^/  [info] /'; else info "tempinfo 不存在"; fi
if [ -r /proc/sys/dev/nss/clock/current_freq ]; then
    info "current_freq=$(cat /proc/sys/dev/nss/clock/current_freq 2>/dev/null) Hz  auto_scale=$(cat /proc/sys/dev/nss/clock/auto_scale 2>/dev/null)"
fi
info "uci nss_freq.settings.level = $(uci -q get nss_freq.settings.level 2>/dev/null)"
info "CPU governor = $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"

echo "===== 汇总 ====="
echo "  FAIL=$FAIL  WARN=$WARN"
if [ "$FAIL" -gt 0 ]; then
    echo "  RESULT: FAIL"
    exit 1
fi
echo "  RESULT: PASS"
exit 0
