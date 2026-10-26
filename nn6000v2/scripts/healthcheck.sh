#!/bin/sh
######################################################################
# healthcheck.sh - Link_NN6000V2 固件层体检（H1-H6）
#
# 用法（本机执行，管道送进设备）:
#   ssh -i ~/.ssh/id_ed25519 -p 223 root@10.0.0.1 'sh -s' \
#       < nn6000v2/scripts/healthcheck.sh
#
# 退出码: 0=无 FAIL；1=存在 FAIL（便于脚本化/监控）
#         WARN 不影响退出码，但会在汇总行计数
#
# 目标为 busybox ash（无 find -newermt / ls --time-style / netstat -i /
# cat -A / pgrep -c / ps -o / ps -a / stat / od），本脚本已规避这些坑。
#
# 路径与判据可用环境变量覆盖（自测 / 失败路径演示用）:
#   APK_DB APK_WORLD APK_CACHE ECM_DB FOS ROM EMMC_CNT
#   PSTORE NSS_DIAG HWCLK DATA_MNT DATA_DEV DMESG_CMD
#   OVL_WARN(85) OVL_FAIL(95) IDX_MAX_AGE(30)
#   EXPECT_REV EXPECT_FILE EXPECT_SHA256
#   e.g. APK_WORLD=/etc/hostname sh healthcheck.sh   # 人为制造 db!=world → 必须 FAIL 且 rc=1
#        DMESG_CMD='echo EXT4-fs (sda1): recovery complete' sh healthcheck.sh  # 伪造非正常关机签名
######################################################################

APK_DB=${APK_DB:-/lib/apk/db/installed}
APK_WORLD=${APK_WORLD:-/etc/apk/world}
APK_CACHE=${APK_CACHE:-/var/cache/apk}
ECM_DB=${ECM_DB:-/sys/kernel/debug/ecm/ecm_db}
FOS=${FOS:-/etc/init.d/fix_overlay_shadow}
ROM=${ROM:-/rom}
EMMC_CNT=${EMMC_CNT:-/etc/emmc_health.count}
PSTORE=${PSTORE:-/sys/fs/pstore}
NSS_DIAG=${NSS_DIAG:-/usr/bin/nss_diag.sh}
HWCLK=${HWCLK:-/sys/kernel/debug/clk/clk_summary}
DATA_MNT=${DATA_MNT:-/mnt/data_sda2}
DATA_DEV=${DATA_DEV:-/dev/sda2}
DMESG_CMD=${DMESG_CMD:-dmesg}

OVL_WARN=${OVL_WARN:-85}
OVL_FAIL=${OVL_FAIL:-95}
IDX_MAX_AGE=${IDX_MAX_AGE:-30}

EXPECT_REV=${EXPECT_REV:-}
EXPECT_FILE=${EXPECT_FILE:-}
EXPECT_SHA256=${EXPECT_SHA256:-}

FAIL=0
WARN=0

# dmesg 统一入口：默认 applet，可用 DMESG_CMD 覆盖（失败路径演示）
dmesg_read() { sh -c "$DMESG_CMD" 2>/dev/null; }

# dmesg 可读性前置探测：不可读时相关检查必须 FAIL，不得用"0 命中"冒充通过（fail-safe）
DMESG_OK=1
dmesg_read >/dev/null 2>&1 || DMESG_OK=0
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
# 行数用 awk NR：world 缺尾换行时 wc -l 会少算 1（P12）
if [ ! -r "$APK_WORLD" ]; then
    bad "$APK_WORLD 不可读"
    wn=""
else
    wn=$(awk 'END{print NR}' "$APK_WORLD" 2>/dev/null)
fi
dbn=$(grep -c '^P:' "$APK_DB" 2>/dev/null)
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

# 仓库索引可解析性：模拟安装一个"未安装"的包（已安装包会短路过索引，P6）
probe=""
for p in nmap nano rsync htop vim; do
    if ! apk info -e "$p" >/dev/null 2>&1; then probe=$p; break; fi
done
if [ -z "$probe" ]; then
    info "仓库解析探测跳过（候选包均已安装）"
elif apk add --simulate "$probe" >/dev/null 2>&1; then
    ok "apk add --simulate $probe rc=0（本地索引可解析）"
else
    bad "apk add --simulate $probe rc!=0（本地索引异常）"
fi

# 索引新鲜度：只反映"最后一次 apk update 距今多久"，不代表镜像可达
newest=""
for f in "$APK_CACHE"/APKINDEX.*; do
    [ -e "$f" ] || continue
    t=$(date -r "$f" +%s 2>/dev/null)
    [ -n "$t" ] || continue
    if [ -z "$newest" ]; then newest=$t; elif [ "$t" -gt "$newest" ]; then newest=$t; fi
done
if [ -z "$newest" ]; then
    warn "无本地 APKINDEX 缓存（$APK_CACHE）：仓库可用性未验证"
else
    idx_days=$(( ( $(date +%s) - newest ) / 86400 ))
    if [ "$idx_days" -ge "$IDX_MAX_AGE" ]; then
        warn "APKINDEX 最新缓存 ${idx_days} 天前（≥${IDX_MAX_AGE} 天），建议 apk update"
    else
        ok "APKINDEX 缓存年龄 ${idx_days} 天"
    fi
fi

# world 令牌合法性：禁空白/空行/非法起始字符/重名（C6：'pkg><Q1...=' 属合法）
if [ -r "$APK_WORLD" ]; then
    wtok=$(awk '
        {
            if ($0 ~ /^[[:space:]]*$/) { print NR ":empty"; next }
            if ($0 ~ /[[:space:]]/)    { print NR ":space"; next }
            if ($0 !~ /^[!]?[A-Za-z0-9][A-Za-z0-9._+-]*([<>=].*)?$/) \
                                       { print NR ":badstart"; next }
            n = $0
            sub(/^!/, "", n)
            sub(/[<>=].*$/, "", n)
            c[n]++
        }
        END { for (k in c) if (c[k] > 1) print "dup:" k "(" c[k] ")" }
    ' "$APK_WORLD" 2>/dev/null)
    if [ -z "$wtok" ]; then
        ok "world 令牌合法（无空白/空行/重名）"
    else
        bad "world 存在非法/重复令牌: $(echo "$wtok" | tr '\n' ' ')"
    fi
    info "world 中 '><' pin 令牌行数: $(grep -c '><' "$APK_WORLD" 2>/dev/null)（合法语法）"
fi

echo "===== H2 NSS/ECM offload ====="
for m in qca_nss_drv qca_nss_dp qca_ssdk ecm; do
    if lsmod | grep -qE "^${m}[[:space:]]"; then ok "模块 $m 已加载"; else bad "模块 $m 缺失"; fi
done
for n in connection_count node_count host_count iface_count; do
    v=$(cat "$ECM_DB/$n" 2>/dev/null)
    case "$v" in
        ''|*[!0-9]*)
            warn "ecm/$n 不可读（值 '$v'）" ;;
        0)
            if [ "$n" = connection_count ]; then
                warn "ecm/connection_count = 0（单次采样；持续为 0 = offload 失效）"
            else
                info "ecm/$n = 0"
            fi ;;
        *)
            ok "ecm/$n = $v" ;;
    esac
done
if [ -x "$NSS_DIAG" ]; then
    nd_out=$($NSS_DIAG 2>&1)
    nd_rc=$?
    if [ "$nd_rc" -eq 0 ]; then
        ok "nss_diag.sh rc=0"
    else
        bad "nss_diag.sh rc=$nd_rc"
    fi
    # 只展示头部摘要（MODEL/KERNEL/NSS FW/CPU GOV…），跳过冗长的 PKGS/INTERFACE 列表
    printf '%s\n' "$nd_out" | awk '/^=+$/{c++; if (c==3) {print; exit}} {print}' | sed 's/^/  [info] /'
    info "（nss_diag.sh 的 NSS PKGS / INTERFACE 明细已省略，需要时单独执行）"
else
    warn "$NSS_DIAG 不存在或不可执行"
fi

echo "===== H3 存储/overlay/eMMC ====="
mline=$(mount | grep ' on /overlay ')
if [ -z "$mline" ]; then
    bad "/overlay 未挂载"
else
    echo "$mline" | grep -q '(rw' && ok "/overlay 已挂载且可写" || bad "/overlay 只读"
fi
df -h /overlay / 2>/dev/null | sed 's/^/  [info] /'
use=$(df -P /overlay 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')
case "$use" in
    ''|*[!0-9]*)
        warn "overlay 用量不可读（'$use'）" ;;
    *)
        if [ "$use" -ge "$OVL_FAIL" ]; then
            bad "overlay 用量 ${use}%（≥${OVL_FAIL}%）"
        elif [ "$use" -ge "$OVL_WARN" ]; then
            warn "overlay 用量 ${use}%（≥${OVL_WARN}%）"
        else
            ok "overlay 用量 ${use}%（<${OVL_WARN}%）"
        fi ;;
esac

# 数据盘（sda2）：与 overlay 同盘，overlay 在而它掉线即异常
if mount | grep -q " on ${DATA_MNT} "; then
    ok "${DATA_MNT} 已挂载"
else
    if [ -e "$DATA_DEV" ]; then
        bad "${DATA_DEV} 存在但未挂载到 ${DATA_MNT}"
    else
        warn "${DATA_DEV} 不存在，${DATA_MNT} 未挂载"
    fi
fi

cnt=$(cat "$EMMC_CNT" 2>/dev/null)
case "$cnt" in
    ''|*[!0-9]*) warn "eMMC 计数不可读/非数字: '$cnt'" ;;
    0)           ok "eMMC 健康计数 0" ;;
    *)           warn "eMMC 健康计数非 0: $cnt" ;;
esac
if [ "$DMESG_OK" = 1 ]; then
    ioerr=$(dmesg_read | grep -c 'mmcblk0.*error')
    [ "$ioerr" = "0" ] && ok "mmcblk0 无 I/O 错误" || warn "mmcblk0 I/O 错误计数: $ioerr"
    rec1=$(dmesg_read | grep -cE 'EXT4-fs \(sda1\): recovery complete')
    rec2=$(dmesg_read | grep -cE 'EXT4-fs \(sda2\): recovery complete')
    recf=$(dmesg_read | grep -cE 'f2fs_recover')
    rect=$((rec1 + rec2 + recf))
    if [ "$rect" -eq 0 ]; then
        ok "本次开机无非正常关机签名"
    else
        warn "本次开机有非正常关机签名: sda1=$rec1 sda2=$rec2 loop0-f2fs=$recf（C7.4）"
    fi
else
    bad "dmesg 不可读，无法检查 mmcblk0 I/O 与非正常关机签名"
fi

echo "===== H4 崩溃取证 ====="
# 目录不存在 = 内核未提供/未挂 pstore = 无持久化取证能力，不等于"无崩溃残留"（H4/C4.4）
if [ -d "$PSTORE" ]; then
    pn=$(ls -A "$PSTORE" 2>/dev/null | awk 'END{print NR}')
    if [ "$pn" = "0" ]; then
        info "$PSTORE 存在但为空"
    else
        warn "$PSTORE 有 $pn 项残留（检查崩溃现场）"
    fi
else
    info "$PSTORE 不存在：本机无持久化崩溃取证能力（≠ 无崩溃，C4.4）"
fi
if [ "$DMESG_OK" = 1 ]; then
    oops=$(dmesg_read | grep -iE 'oops|BUG:|kernel panic' | grep -vc ramoops)
    [ "$oops" = "0" ] && ok "dmesg 无 oops/BUG/panic" || bad "dmesg 命中 $oops 行"
else
    bad "dmesg 不可读，无法检查 oops/BUG/panic"
fi
dz=$(ps | grep -c '[d]efunct')
[ "$dz" = "0" ] && ok "无 defunct 进程" || warn "defunct 进程: $dz"

echo "===== H5 产物/内容核对 ====="
rev=$(grep -o "DISTRIB_REVISION='[^']*'" "$ROM/etc/openwrt_release" 2>/dev/null | cut -d"'" -f2)
info "revision: ${rev:-未知}"
if [ -n "$EXPECT_REV" ]; then
    if [ "$rev" = "$EXPECT_REV" ]; then ok "revision 与预期一致 ($rev)"; else bad "revision '$rev' != 预期 '$EXPECT_REV'"; fi
fi

# 内核与模块目录必须同版本（内核升级但模块未跟 = 隐性坏包）
kr=$(uname -r)
if [ -d "/lib/modules/$kr" ]; then
    ok "模块目录与内核一致 (/lib/modules/$kr)"
else
    bad "内核 $kr 无对应 /lib/modules 目录"
fi

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

# 可选：与构建产物比对（不设变量则跳过；设备上无 manifest，故改为按文件校验）
if [ -n "$EXPECT_SHA256" ]; then
    if [ -z "$EXPECT_FILE" ] || [ ! -r "$EXPECT_FILE" ]; then
        bad "EXPECT_SHA256 已给出但 EXPECT_FILE 缺失/不可读"
    elif ! command -v sha256sum >/dev/null 2>&1; then
        warn "sha256sum 不可用，跳过校验"
    else
        got=$(sha256sum "$EXPECT_FILE" | cut -d' ' -f1)
        if [ "$got" = "$EXPECT_SHA256" ]; then ok "$EXPECT_FILE sha256 与预期一致"; else bad "$EXPECT_FILE sha256 '$got' != 预期 '$EXPECT_SHA256'"; fi
    fi
fi

echo "===== H6 温度/频率 ====="
if command -v tempinfo >/dev/null 2>&1; then
    printf '%s\n' "$(tempinfo 2>/dev/null)" | sed 's/^/  [info] /'
else
    info "tempinfo 不存在"
fi

lvl=$(uci -q get nss_freq.settings.level 2>/dev/null)
cf=$(cat /proc/sys/dev/nss/clock/current_freq 2>/dev/null)
as=$(cat /proc/sys/dev/nss/clock/auto_scale 2>/dev/null)
info "uci nss_freq.settings.level = ${lvl:-未知}  current_freq=${cf:-?} Hz  auto_scale=${as:-?}"

case "$lvl" in
    '') warn "uci nss_freq.settings.level 不可读" ;;
    high) ok "NSS 档位 level=high" ;;
    *) warn "NSS 档位 level=$lvl（H6 失败信号：期望 high）" ;;
esac

cf_exp=""
case "$lvl" in
    high) cf_exp=1497600000 ;;
    mid)  cf_exp=748800000 ;;
    low)  cf_exp=187200000 ;;
esac
if [ -n "$cf_exp" ] && [ -n "$cf" ] && [ "$cf" != "$cf_exp" ]; then
    warn "current_freq=$cf 与 level=$lvl 期望 $cf_exp 不一致（档位漂移）"
fi

# 硬件时钟才是真值：sysctl current_freq 只是驱动变量
hw=$(grep -E 'gcc_ubi0_core_clk' "$HWCLK" 2>/dev/null | awk '{print $5; exit}')
if [ -z "$hw" ]; then
    info "硬件时钟不可读（$HWCLK），无法交叉验证"
elif [ -n "$cf" ] && [ "$cf" -gt 0 ] 2>/dev/null; then
    d=$((hw - cf))
    [ "$d" -lt 0 ] && d=$((0 - d))
    if [ $((d * 100)) -gt "$cf" ]; then
        warn "硬件时钟 ${hw}Hz 与 current_freq ${cf}Hz 偏差 >1%"
    else
        ok "硬件时钟 ${hw}Hz 与 current_freq 一致（差 ${d}Hz）"
    fi
fi
info "CPU governor = $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"

echo "===== 汇总 ====="
echo "  FAIL=$FAIL  WARN=$WARN"
if [ "$FAIL" -gt 0 ]; then
    echo "  RESULT: FAIL"
    exit 1
fi
echo "  RESULT: PASS"
exit 0
