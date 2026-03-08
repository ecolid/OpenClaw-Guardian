#!/usr/bin/env bash
set -e

# =================================================================
# OpenClaw Guardian - 备份与监控守护机器人一键部署脚本
# GitHub: https://github.com/ecolid/openclaw-guardian
# 
# 功能: 
# 1. 常驻 Telegram Bot，支持 /backup, /rollback, /status, /restart, /logs
# 2. 定时备份 (默认每 4 小时) 和 修改防抖备份
# 3. 状态机监控 (实时流发现异常 + 60s 兜底轮询)
# =================================================================

# 颜色配置
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
PLAIN='\033[0m'

log_info() { echo -e "${GREEN}[INFO] $1${PLAIN}"; }
log_warn() { echo -e "${YELLOW}[WARN] $1${PLAIN}"; }
log_step() { echo -e "${CYAN}>>> $1${PLAIN}"; }
log_error() { echo -e "${RED}[ERROR] $1${PLAIN}"; exit 1; }

echo -e "${CYAN}=================================================================${PLAIN}"
echo -e "${GREEN}🛡️ 欢迎安装 OpenClaw Guardian (备份与监控守护系统)${PLAIN}"
echo -e "${CYAN}=================================================================${PLAIN}"
echo ""

# =================================================================
# 0. 交互式配置参数 (替代硬编码)
# =================================================================
log_step "[0/5] 初始化配置"

ENV_FILE="/root/.openclaw-guardian/.env"
if [ -f "$ENV_FILE" ]; then
    log_info "检测到已存在的配置文件 ($ENV_FILE)，自动加载配置跳过输入..."
    source "$ENV_FILE"
fi

if [ -z "$TG_BOT_TOKEN" ]; then
    # 要求用户输入 Telegram Bot Token
    while true; do
        read -p "请输入你的 Telegram Bot Token (例如 123456789:ABCdefGHI...): " TG_BOT_TOKEN
        if [[ "$TG_BOT_TOKEN" =~ ^[0-9]+:[a-zA-Z0-9_-]+$ ]]; then
            break
        else
            log_warn "Token 格式似乎有误，请重新输入。"
        fi
    done
fi

if [ -z "$TG_CHAT_ID" ]; then
    # 要求用户输入 Telegram Chat ID
    while true; do
        read -p "请输入接收通知的 Telegram Chat ID (你的个人数字ID，例如 12345678): " TG_CHAT_ID
        if [[ "$TG_CHAT_ID" =~ ^[0-9]+$ || "$TG_CHAT_ID" =~ ^-[0-9]+$ ]]; then
            break
        else
            log_warn "Chat ID 格式有误，必须是纯数字 (或带负号的群组ID)。"
        fi
    done
fi

mkdir -p /root/.openclaw-guardian
echo "TG_BOT_TOKEN=\"$TG_BOT_TOKEN\"" > "$ENV_FILE"
echo "TG_CHAT_ID=\"$TG_CHAT_ID\"" >> "$ENV_FILE"

log_info "配置完成，准备开始安装环境..."

# =================================================================
# 1. 前置准备
# =================================================================
log_step "[1/5] 安装必要依赖..."
if [ "$EUID" -ne 0 ]; then
  log_error "请使用 root 权限运行此脚本 (例如: sudo bash deploy-guardian.sh)"
fi

DEBIAN_FRONTEND=noninteractive apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y tar curl jq cron python3 python3-pip python3-venv inotify-tools

BACKUP_DIR="/opt/openclaw-guardian"
mkdir -p "$BACKUP_DIR"
cd "$BACKUP_DIR"

# 初始化 Python 虚拟环境
python3 -m venv venv
./venv/bin/pip install requests

# 初始化备份历史记录
if [ ! -f "$BACKUP_DIR/backup-history.json" ]; then
    echo "[]" > "$BACKUP_DIR/backup-history.json"
fi

log_info "基础目录和依赖已就绪: $BACKUP_DIR"

# =================================================================
# 2. 生成核心备份脚本 (backup.sh)
# =================================================================
log_step "[2/5] 生成核心备份脚本..."

cat > "$BACKUP_DIR/backup.sh" <<EOF
#!/usr/bin/env bash
set -e
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
# ================================================
# OpenClaw 增量备份脚本 - \$(date)
# ================================================

BOT_TOKEN="${TG_BOT_TOKEN}"
CHAT_ID="${TG_CHAT_ID}"
echo "-----------------------------------" >> "$BACKUP_DIR/cron_backup.log"
echo "🚀 备份脚本启动 (\$(date))" >> "$BACKUP_DIR/cron_backup.log"
TIMESTAMP=\$(date +"%Y%m%d_%H%M%S")
HOSTNAME=\$(hostname)
TMP_DIR="/tmp/oc_backup_\${TIMESTAMP}"
ARCHIVE_NAME="OC_Backup_\${TIMESTAMP}.tar.gz"
BACKUP_FILE="\${TMP_DIR}/\${ARCHIVE_NAME}"
HISTORY_FILE="$BACKUP_DIR/backup-history.json"

mkdir -p "\${TMP_DIR}/config"
cd "\${TMP_DIR}"

echo "正在打包 OpenClaw 配置与对话历史..."
if [ -d "/root/.openclaw" ]; then
    mkdir -p config/openclaw
    cp -r /root/.openclaw/* config/openclaw/
fi
mkdir -p config/systemd
cp /etc/systemd/system/openclaw.service config/systemd/ 2>/dev/null || true

cp $BACKUP_DIR/restore.sh ./restore.sh 2>/dev/null || true

# 生成脱机恢复说明
cat > "config/🆘如何手动脱机恢复-README.txt" << 'IN_EOF'
如果你看到了这个说明文件，说明你正在进行脱机/异地恢复！

【脱机物理恢复指南】
1. 确保新服务器上已经安装了 Node.js 环境并克隆了最新的 OpenClaw 代码。
2. 将此压缩包内的 \`openclaw\` 文件夹里的所有内容，原封不动地复制/覆盖到新服务器的 \`~/.openclaw/\` 目录下。
   (如果你不知道怎么找，可以在新机器上执行命令: mkdir -p ~/.openclaw)
3. 复制完成后，重新启动或者运行你的 OpenClaw (例如 npm run start) 即可满血复活所有的机器人身份和聊天记忆。
4. 本压缩包外层的 \`restore.sh\` 是在配置了自动监控机器人的旧环境里用的，纯净新机器上请无视它，遵守上述前3步即可！
IN_EOF

echo "正在打包..."
# 忽略打包过程中文件被修改(如数据库写入)导致的警告和退出
# 自动排除图片、视频等大体积多媒体文件，防止 Playwright 截图撑爆备份包
tar --warning=no-file-changed --exclude="*.png" --exclude="*.jpg" --exclude="*.jpeg" --exclude="*.webp" --exclude="*.mp4" --exclude="*Cache*" --exclude="*cache*" --exclude="*.log" --exclude="logs" --exclude="*Code Cache*" --exclude="*Crashpad*" -czf "\${BACKUP_FILE}" config/ restore.sh || true

echo "正在处理 Telegram 附件限制 (45MB)..."

FILE_SIZE=\$(ls -lh "\${BACKUP_FILE}" | awk '{print \$5}')
FILE_SIZE_BYTES=\$(stat -c%s "\${BACKUP_FILE}")
MAX_BYTES=45000000

if [ "\$FILE_SIZE_BYTES" -gt "\$MAX_BYTES" ]; then
    echo "文件大小超出 45MB，正在进行安全分卷拆分..."
    split -b 45m "\${BACKUP_FILE}" "\${BACKUP_FILE}.part_"
    PART_FILES=(\$(ls "\${BACKUP_FILE}.part_"*))
else
    # 小于45MB，不拆分，直接上传本体
    PART_FILES=("\${BACKUP_FILE}")
fi

TOTAL_PARTS=\${#PART_FILES[@]}
echo "文件总大小: \${FILE_SIZE}，分卷数量: \${TOTAL_PARTS}。"

# 用来收集所有的 file_id
declare -a UPLOADED_IDS=()
PART_INDEX=1

for PART in "\${PART_FILES[@]}"; do
    if [ "\$TOTAL_PARTS" -gt 1 ]; then
        CAPTION="✅ [Guardian 备份成功] (分卷 \${PART_INDEX}/\${TOTAL_PARTS})
- 主机: \${HOSTNAME}
- 时间: \$(date +"%Y-%m-%d %H:%M:%S")
- 总大小: \${FILE_SIZE}
💡 提示：所有分卷上传完毕后自动生成记录，可用 /rollback 恢复。"
    else
        CAPTION="✅ [Guardian 备份成功]
- 主机: \${HOSTNAME}
- 时间: \$(date +"%Y-%m-%d %H:%M:%S")
- 大小: \${FILE_SIZE}
💡 提示：使用 /rollback 命令可以直接从历史备份恢复。"
    fi

    echo "正在发送卷 \${PART_INDEX}/\${TOTAL_PARTS} ..."
    RESPONSE=\$(curl -s -X POST "https://api.telegram.org/bot\${BOT_TOKEN}/sendDocument" \\
      -F chat_id="\${CHAT_ID}" \\
      -F disable_notification="true" \\
      -F document="@\${PART}" \\
      -F caption="\${CAPTION}")

    if echo "\$RESPONSE" | jq -e '.ok' >/dev/null; then
        MSG_ID=\$(echo "\$RESPONSE" | jq -r '.result.message_id')
        FILE_ID=\$(echo "\$RESPONSE" | jq -r '.result.document.file_id')
        
        UPLOADED_IDS+=("\$FILE_ID")
        echo "卷 \${PART_INDEX} 发送成功。"
    else
        echo "Telegram 发送失败:"
        echo "\$RESPONSE"
        curl -s -X POST "https://api.telegram.org/bot\${BOT_TOKEN}/sendMessage" \\
            -d chat_id="\${CHAT_ID}" \\
            -d text="❌ [Guardian 备份失败] 无法上传。文件保留在: \${TMP_DIR}"
        exit 1
    fi
    PART_INDEX=\$((PART_INDEX + 1))
done

echo "所有分卷发送完毕！记录历史..."

# 确保历史记录文件存在且格式正确，否则自动修复为 []
if ! jq -e . "\${HISTORY_FILE}" >/dev/null 2>&1; then
    echo "[]" > "\${HISTORY_FILE}"
fi

# 将 bash 数组转换为 JSON 数组格式给 jq
JSON_FILE_IDS=\$(printf '%s\n' "\${UPLOADED_IDS[@]}" | jq -R . | jq -s -c .)

# 使用 jq 的 --arg 安全地构建 JSON 实体并合并到历史记录头部，保留最近 30 条
jq -c \\
   --arg time "\$(date +"%Y-%m-%d %H:%M")" \\
   --arg file "\${ARCHIVE_NAME}" \\
   --arg msg_id "\${MSG_ID}" \\
   --argjson file_ids "\${JSON_FILE_IDS}" \\
   --arg size "\${FILE_SIZE}" \\
   '. = [{time: \$time, file: \$file, msg_id: \$msg_id, file_ids: \$file_ids, size: \$size}] + . | .[0:30]' \\
   "\${HISTORY_FILE}" > "\${HISTORY_FILE}.tmp" && mv "\${HISTORY_FILE}.tmp" "\${HISTORY_FILE}"

echo "✅ 备份成功并记录历史 (\$(date))" >> "$BACKUP_DIR/cron_backup.log"

rm -rf "\${TMP_DIR}"
echo "清理完毕。"
EOF

chmod +x "$BACKUP_DIR/backup.sh"

# =================================================================
# 3. 生成一键恢复脚本 (restore.sh)
# =================================================================
log_step "[3/5] 生成恢复脚本 (内嵌于备份文件中)..."

cat > "$BACKUP_DIR/restore.sh" <<'EOF'
#!/usr/bin/env bash
set -e

if [ -z "$1" ]; then
    echo "用法: bash restore.sh <backup_file.tar.gz>"
    exit 1
fi

BACKUP_FILE="$1"

if [ ! -f "$BACKUP_FILE" ]; then
    echo "错误: 找不到文件 $BACKUP_FILE"
    exit 1
fi

echo ">> 正在解压..."
TMP_R="$PWD/restore_tmp_$(date +%s)"
mkdir -p "$TMP_R"
tar -xzf "$BACKUP_FILE" -C "$TMP_R"

cd "$TMP_R"
echo ">> 正在停止 OpenClaw 服务以防数据库损坏..."
systemctl stop openclaw || true

echo ">> 正在还原配置文件..."

if [ -d "config/openclaw" ]; then
    echo "  - 还原 OpenClaw..."
    rm -rf /root/.openclaw_old
    mv /root/.openclaw /root/.openclaw_old 2>/dev/null || true
    mkdir -p /root/.openclaw
    cp -r config/openclaw/* /root/.openclaw/
fi

if [ -d "config/systemd/openclaw.service" ]; then
    echo "  - 还原 Systemd 服务..."
    cp config/systemd/openclaw.service /etc/systemd/system/ 2>/dev/null || true
    systemctl daemon-reload
fi

echo ">> 正在重新启动 OpenClaw..."
systemctl start openclaw || true

cd ..
rm -rf "$TMP_R"
echo "🎉 恢复完成！"
EOF
chmod +x "$BACKUP_DIR/restore.sh"

# =================================================================
# 4. 生成 Python Bot 守护程序
# =================================================================
log_step "[4/5] 生成 Guardian Bot..."

cat > "$BACKUP_DIR/guardian-bot.py" <<EOF
import requests, time, subprocess, json, os, threading, html

BOT_TOKEN = "${TG_BOT_TOKEN}"
CHAT_ID = "${TG_CHAT_ID}"
BACKUP_DIR = "${BACKUP_DIR}"
HISTORY_FILE = os.path.join(BACKUP_DIR, "backup-history.json")
VERSION = "v1.5.4"

API_URL = f"https://api.telegram.org/bot{BOT_TOKEN}"
grep_lock = threading.Lock()

def send_msg(text, reply_markup=None):
    payload = {"chat_id": CHAT_ID, "text": text, "parse_mode": "HTML"}
    if reply_markup: payload["reply_markup"] = json.dumps(reply_markup)
    try: requests.post(f"{API_URL}/sendMessage", json=payload, timeout=10)
    except: pass

def run_cmd(cmd, timeout_sec=None):
    try: return subprocess.check_output(cmd, shell=True, text=True, stderr=subprocess.STDOUT, timeout=timeout_sec)
    except subprocess.CalledProcessError as e: return e.output
    except subprocess.TimeoutExpired: return f"[Timeout] 指令执行超过 {timeout_sec} 秒，为保护系统资源已被强行中断。"

def gen_bar(pct, length=10):
    try: p = float(pct)
    except: p = 0.0
    filled = int(round(p / 100 * length))
    if filled > length: filled = length
    elif filled < 0: filled = 0
    bar = "█" * filled + "░" * (length - filled)
    if p < 60: icon = "🟢"
    elif p < 85: icon = "🟡"
    else: icon = "🔴"
    return f"{icon} [{bar}] {p: >4.1f}%"

# --- 监控逻辑 ---
def health_monitor():
    """双通道状态机监控: 实时流(快速通道) + 轮询(兜底)"""
    was_down = False
    last_flip_by = ""
    
    def flip_state(new_down, source):
        nonlocal was_down, last_flip_by
        if new_down and not was_down:
            status = run_cmd("systemctl is-active openclaw").strip()
            diag = run_cmd("journalctl -u openclaw -n 10 --no-pager")[-800:]
            extra = "\n\n⚠️ <i>(轮询兜底发现)</i>" if source == "poll" else ""
            send_msg("🚨 <b>警告：OpenClaw 服务已挂掉！</b>\n状态: <code>" + status + "</code>\n诊断信息:\n<pre>" + diag + "</pre>\n使用 /restart 命令尝试重启。" + extra)
            was_down = True
            last_flip_by = source
        elif not new_down and was_down:
            extra = "\n\n⚠️ <i>(轮询兜底发现)</i>" if source == "poll" else ""
            send_msg("✅ <b>恢复：OpenClaw 服务已重新运行！</b>" + extra)
            was_down = False
            last_flip_by = source
    
    def check_gold_standard(source):
        status = run_cmd("systemctl is-active openclaw").strip()
        if status == "activating": return
        is_down = (status != "active")
        if is_down != was_down: flip_state(is_down, source)
    
    def polling_loop():
        while True:
            time.sleep(60)
            check_gold_standard("poll")

    threading.Thread(target=polling_loop, daemon=True).start()
    
    CRASH_HINTS = ["Main process exited", "Failed with result", "Deactivated successfully"]
    RECOVERY_HINTS = ["Started OpenClaw", "Started openclaw"]
    while True:
        try:
            proc = subprocess.Popen(
                "journalctl -f -u openclaw --no-pager",
                shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
            )
            while proc.poll() is None:
                line = proc.stdout.readline()
                if not line:
                    time.sleep(0.5)
                    continue
                line_str = line.decode("utf-8", errors="ignore").strip()
                if not was_down and any(kw in line_str for kw in CRASH_HINTS):
                    time.sleep(5)
                    check_gold_standard("stream")
                elif was_down and any(kw in line_str for kw in RECOVERY_HINTS):
                    time.sleep(2)
                    check_gold_standard("stream")
        except: pass
        time.sleep(3)

def ota_monitor():
    """后台轮询 GitHub 检查更新"""
    notified_version = VERSION
    while True:
        time.sleep(600)
        try:
            r = requests.get("https://raw.githubusercontent.com/ecolid/OpenClaw-Guardian/main/deploy-guardian.sh", timeout=10)
            if r.status_code == 200:
                for line in r.text.split('\n'):
                    if line.startswith('VERSION = "'):
                        remote_version = line.split('"')[1]
                        if remote_version != VERSION and remote_version != notified_version:
                            btn = [[{"text": "📥 立即热更新系统 (OTA)", "callback_data": "ota_update"}]]
                            send_msg(f"🎉 <b>发现 Guardian 新版本！</b>\n当前运行: <code>{VERSION}</code>\n最新版本: <code>{remote_version}</code>\n\n点击下方按钮或发送 /update 立即热部署。", {"inline_keyboard": btn})
                            notified_version = remote_version
                        break
        except: pass

# --- 指令处理 ---
def set_commands():
    commands = [
        {"command": "status", "description": "查看服务器状态与内存占用"},
        {"command": "backup", "description": "立即全量备份机器人配置"},
        {"command": "rollback", "description": "一键回滚到历史快照"},
        {"command": "restart", "description": "重启机器人的后端进程"},
        {"command": "logs", "description": "日志中心：查看业务日志或备份自检日志"},
        {"command": "grep", "description": "定向搜索日志并提取上下文 (如 /grep 400)"},
        {"command": "update", "description": "从 GitHub 热更新守护程序代码"},
        {"command": "update_rollback", "description": "恢复上一版本的守护程序代码"}
    ]
    try: requests.post(f"{API_URL}/setMyCommands", json={"commands": commands}, timeout=5)
    except: pass

def handle_msg(msg):
    if "text" not in msg: return
    text = msg["text"]
    if str(msg["chat"]["id"]) != CHAT_ID: return

    if text.startswith("/status"):
        send_msg("⏳ 正在采集硬件深层指标，请稍候...")
        try:
            # Service Status
            oc_status = run_cmd("systemctl is-active openclaw").strip().upper()
            oc_emoji = "🟢" if oc_status == "ACTIVE" else "🔴"
            oc_uptime = run_cmd("systemctl show openclaw --property=ActiveEnterTimestamp | awk -F= '{print \$2}'").strip()
            if oc_uptime:
                try:
                    enter_ts = subprocess.check_output(f"date -d '{oc_uptime}' +%s", shell=True).strip()
                    now_ts = time.time()
                    diff = int(now_ts) - int(enter_ts)
                    h, m = diff // 3600, (diff % 3600) // 60
                    oc_time_str = f"运行 {h}h {m}m"
                except: oc_time_str = "运行时间未知"
            else: oc_time_str = "已停止"

            # Host Uptime & Load
            uptime = run_cmd("uptime -p").strip().replace("up ", "")
            load = run_cmd("cat /proc/loadavg | awk '{print \$1, \"|\", \$2, \"|\", \$3}'").strip()
            
            # CPU
            cpu_idle = run_cmd("top -bn1 | grep 'Cpu(s)' | awk '{print \$8}'").strip()
            try: cpu_pct = 100.0 - float(cpu_idle)
            except: cpu_pct = 0.0
            
            # Memory & Swap
            free_out = run_cmd("free -m | awk 'NR==2{print \$3, \$2}; NR==3{print \$3, \$2}'").strip().split('\n')
            try:
                mem_used, mem_tot = map(int, free_out[0].split())
                mem_pct = (mem_used / mem_tot) * 100 if mem_tot else 0
                mem_str = f"{(mem_used/1024):.1f}G/{(mem_tot/1024):.1f}G"
            except: mem_pct, mem_str = 0.0, "?/?"
            
            try:
                swap_used, swap_tot = map(int, free_out[1].split())
                swap_pct = (swap_used / swap_tot) * 100 if swap_tot else 0
                swap_str = f"{(swap_used/1024):.1f}G/{(swap_tot/1024):.1f}G"
            except: swap_pct, swap_str = 0.0, "0G/0G"

            # Disk & Last Backup
            df_out = run_cmd("df -h / | awk 'NR==2{print \$5, \$3, \$4}'").strip().split()
            try:
                disk_pct = float(df_out[0].replace('%', ''))
                disk_str = f"用{df_out[1]}/剩{df_out[2]}"
            except: disk_pct, disk_str = 0.0, "?/?"

            # Read last backup from JSON
            last_backup_str = "从未备份"
            try:
                if os.path.exists(HISTORY_FILE):
                    with open(HISTORY_FILE, "r") as f:
                        hist = json.load(f)
                        if hist: last_backup_str = hist[0]["time"]
            except: pass

            # Cron Service & Job Check
            cron_raw = run_cmd("systemctl is-active cron || service cron status").lower()
            if "active" in cron_raw and "running" in cron_raw or "active" in cron_raw and "is-active" not in cron_raw:
                cron_status = "🟢 运行良好"
            else:
                cron_status = "🔴 服务停滞"
            
            cron_job = run_cmd("crontab -l 2>/dev/null | grep 'backup.sh'").strip()
            cron_job_status = "✅ 已注册" if cron_job else "❌ 未发现任务"

            # Predict Next Backup (every 4h: 0, 4, 8, 12, 16, 20)
            try:
                now_h = time.localtime().tm_hour
                next_h = ((now_h // 4) + 1) * 4
                if next_h >= 24: next_h = 0
                next_backup_time = f"{next_h:02d}:00"
            except: next_backup_time = "计算中..."

            # Dashboard Assembly
            dash = f'''📊 <b>核心引擎状态 (Guardian {VERSION})</b>
-----------------------------------
{oc_emoji} <b>OpenClaw</b> [<code>{oc_status}</code>] ({oc_time_str})
⏱️ <b>宿主机 Uptime</b>: <code>{uptime}</code>
🔥 <b>负载热度</b> (1/5/15m): <code>{load}</code>

<b>[硬件水位监测]</b>
<pre>
🧠 CPU: {gen_bar(cpu_pct)}
🐏 内存: {gen_bar(mem_pct)} ({mem_str})
🔄 Swap: {gen_bar(swap_pct)} ({swap_str})
💽 磁盘: {gen_bar(disk_pct)} ({disk_str})
🕒 <b>最近备份</b>: <code>{last_backup_str}</code>

<b>[自动化调度中心]</b>
⏰ <b>Cron 服务</b>: <code>{cron_status}</code>
📌 <b>定时任务</b>: <code>{cron_job_status}</code>
⏭️ <b>下次预定</b>: <code>今天 {next_backup_time}</code>
</pre>
-----------------------------------'''
            send_msg(dash)
        except Exception as e:
            send_msg(f"❌ 状态面板渲染异常: {str(e)}")
    elif text.startswith("/backup"):
        send_msg("⏳ 正在执行全量备份，请稍候...")
        threading.Thread(target=lambda: run_cmd(f"{BACKUP_DIR}/backup.sh")).start()
    elif text.startswith("/restart"):
        send_msg("🔄 正在重启 OpenClaw...")
        run_cmd("systemctl restart openclaw")
        send_msg("✅ 重启指令已发送。使用 /status 检查状态。")
    elif text.startswith("/update"):
        if text.strip() == "/update_rollback":
            send_msg("⏪ 收到指令，正在恢复上一版本的守护程序...")
            res = run_cmd(f"cd {BACKUP_DIR} && [ -f backup.sh.bak ] && cp backup.sh.bak backup.sh && [ -f guardian-bot.py.bak ] && cp guardian-bot.py.bak guardian-bot.py && echo 'OK' || echo 'Error'")
            if "Error" in res:
                send_msg("❌ 回滚失败：未找到历史版本的原始快照 (.bak)。")
            else:
                send_msg("✅ 回滚解包成功，正在重启监控服务载入旧版大脑...")
                threading.Thread(target=lambda: (time.sleep(3), os.system("systemctl restart openclaw-guardian"))).start()
        else:
            send_msg("🔄 收到指令，正在从 GitHub 获取并自动热更新守护程序...")
            run_cmd(f"cd {BACKUP_DIR} && cp backup.sh backup.sh.bak && cp guardian-bot.py guardian-bot.py.bak")
            update_script = f'''#!/usr/bin/env bash
curl -sL https://raw.githubusercontent.com/ecolid/OpenClaw-Guardian/main/deploy-guardian.sh | bash > {BACKUP_DIR}/update.log 2>&1
if [ \\$? -eq 0 ]; then
  CHANGELOG=\$(curl -sL https://raw.githubusercontent.com/ecolid/OpenClaw-Guardian/main/CHANGELOG.md | awk '/^## \\\[v/{{if (p) exit; p=1; next}} p')
  if [ -z "\$CHANGELOG" ]; then CHANGELOG="本次升降级未提供更新日志说明。"; fi
  curl -s -X POST "https://api.telegram.org/bot{BOT_TOKEN}/sendMessage" -d chat_id="{CHAT_ID}" -d text="✅ <b>升级部署成功！</b>新版守护程序已接管。如果出现异常，请发送 /update_rollback 回滚。%0A%0A📝 <b>最新版本更新内容:</b>%0A\$CHANGELOG" -d parse_mode="HTML"
else
  curl -s -X POST "https://api.telegram.org/bot{BOT_TOKEN}/sendMessage" -d chat_id="{CHAT_ID}" -d text="❌ 升级脚本执行异常，查看日志: {BACKUP_DIR}/update.log，已自动回滚至上一版本。"
  cd {BACKUP_DIR} && cp backup.sh.bak backup.sh && cp guardian-bot.py.bak guardian-bot.py && systemctl restart openclaw-guardian
fi
'''
            with open(f"{BACKUP_DIR}/do_update.sh", "w") as f: f.write(update_script)
            os.system(f"nohup bash {BACKUP_DIR}/do_update.sh >/dev/null 2>&1 &")
    elif text.startswith("/logs"):
        cmd_parts = text.split()
        if len(cmd_parts) > 1 and cmd_parts[1].lower() == "cron":
            log_path = os.path.join(BACKUP_DIR, "cron_backup.log")
            if os.path.exists(log_path):
                logs = run_cmd(f"tail -n 30 {log_path}")[-3500:]
                send_msg(f"� <b>Cron 备份自检日志 (最近 30 行):</b>\n<pre>{html.escape(logs)}</pre>")
            else:
                send_msg("❌ 备份日志尚未生成 (Cron 定时任务可能尚未触发)。")
        else:
            buttons = [
                [{"text": "🧵 OpenClaw 业务日志", "callback_data": "log_oc"}],
                [{"text": "🕒 Cron 备份自检日志", "callback_data": "log_cron"}]
            ]
            send_msg("📄 <b>日志查询中心</b>\n请选择您要查阅的日志类型：", {"inline_keyboard": buttons})
    elif text.startswith("/grep"):
        keyword = text[5:].strip()
        if not keyword:
            buttons = [
                [{"text": "🔴 百炼风控拦截 (DataInspectionFailed)", "callback_data": "qg_DataInspectionFailed"}],
                [{"text": "🟡 网络请求超时 (Timeout)", "callback_data": "qg_Timeout"}],
                [{"text": "💥 内存耗尽被杀 (Out of memory)", "callback_data": "qg_Out of memory"}],
                [{"text": "🚨 严重运行异常 (Exception/Error)", "callback_data": "qg_Exception"}],
                [{"text": "🔵 系统启动记录 (Started)", "callback_data": "qg_Started"}]
            ]
            send_msg("✨ <b>快捷诊断面板 (Interactive Grep)</b>\n请选择您要一键回溯的场景，或手动输入如 <code>/grep 400</code>：", {"inline_keyboard": buttons})
            return
        def do_grep():
            if not grep_lock.acquire(blocking=False):
                send_msg("⏳ 当前已有日志检索任务正在执行，为保护服务器 IO 原性能，请等待上一条查询完成...")
                return
            try:
                send_msg(f"🔍 正在后台检索包含 <code>{keyword}</code> 的日志及其上下文，可能需要几秒钟...")
                safe_kw = keyword.replace("'", "'\\''")
                # 倒序查找 (-r)，强行截断每行前500字符防溢出，一旦搜满最近 5 次案发现场 (-m 5) 则立刻结束，附带前后 1 行上下文 (-C 1)
                grep_cmd = f"journalctl -u openclaw -r --no-pager | awk '{{print substr(\$0, 1, 500)}}' | grep -m 5 -i -C 1 '{safe_kw}'"
                res = run_cmd(grep_cmd, timeout_sec=60).strip()
                if not res:
                    send_msg(f"✅ 在整个日志历史中未找到与 <code>{keyword}</code> 相关的记录。")
                else:
                    if len(res) > 3500: res = res[:3500] + "\n...(由于 Telegram 限制，超长日志已被截断)..."
                    send_msg(f"🚨 <b>[{keyword}] 最近 5 次案发现场 (倒序):</b>\n<pre>{html.escape(res)}</pre>")
            finally:
                grep_lock.release()
                
        threading.Thread(target=do_grep).start()
    elif text.startswith("/rollback"):
        try:
            with open(HISTORY_FILE, "r") as f: history = json.load(f)
        except: history = []
        if not history:
            send_msg("❌ 未找到备份历史记录。")
            return
        
        buttons = []
        for i, v in enumerate(history[:10]):
            size_str = v.get('size', '未知大小')
            buttons.append([{"text": f"🕒 {v['time']} | 📦 {size_str}", "callback_data": f"rb_{v.get('msg_id', i)}"}])
        send_msg("请选择要回滚的时间点：\n<i>⚠️ 警告：这将覆盖当前所有配置和记忆！</i>", {"inline_keyboard": buttons})

def handle_callback(cb):
    data = cb["data"]
    if str(cb["message"]["chat"]["id"]) != CHAT_ID: return
    try: requests.post(f"{API_URL}/answerCallbackQuery", json={"callback_query_id": cb["id"]})
    except: pass
    
    if data == "log_oc":
        logs = run_cmd("journalctl -u openclaw -n 20 --no-pager | awk '{print substr(\$0, 1, 500)}'")[-3500:]
        send_msg(f"🧵 <b>OpenClaw 业务日志 (最近 20 行):</b>\n<pre>{html.escape(logs)}</pre>")
        return
    if data == "log_cron":
        handle_msg({"text": "/logs cron", "chat": {"id": CHAT_ID}})
        return
    
    if data == "ota_update":
        handle_msg({"text": "/update", "chat": {"id": CHAT_ID}})
        return
        
    if data.startswith("qg_"):
        keyword = data[3:]
        
        def do_quick_grep():
            if not grep_lock.acquire(blocking=False):
                send_msg("⏳ 当前已有日志检索任务正在执行，为保护服务器 IO 原性能，请等待上一条查询完成...")
                return
            try:
                send_msg(f"🔍 [快捷查询] 正在后台检索包含 <code>{keyword}</code> 的日志，请耐心等待...")
                safe_kw = keyword.replace("'", "'\\''")
                # 倒序查找 (-r)，强行截断每行前500字符防溢出，一旦搜满最近 5 次案发现场 (-m 5) 则立刻结束，附带前后 1 行上下文 (-C 1)
                grep_cmd = f"journalctl -u openclaw -r --no-pager | awk '{{print substr(\$0, 1, 500)}}' | grep -m 5 -i -C 1 '{safe_kw}'"
                res = run_cmd(grep_cmd, timeout_sec=60).strip()
                if not res:
                    send_msg(f"✅ 在整个日志历史中未找到与 <code>{keyword}</code> 相关的记录。")
                else:
                    if len(res) > 3500: res = res[:3500] + "\n...(由于 Telegram 限制，超长日志已被截断)..."
                    send_msg(f"🚨 <b>[{keyword}] 最近 5 次案发现场 (倒序):</b>\n<pre>{html.escape(res)}</pre>")
            finally:
                grep_lock.release()
                
        threading.Thread(target=do_quick_grep).start()
        return

    if data == "cancel":
        send_msg("✅ 回滚操作已取消。")
        return

    if data.startswith("rb_") or data.startswith("rbcfm_"):
        msg_id_str = data.split("_")[1]
        try:
            with open(HISTORY_FILE, "r") as f: history = json.load(f)
            record = next((r for r in history if str(r.get("msg_id")) == msg_id_str), None)
            if not record and msg_id_str.isdigit() and int(msg_id_str) < len(history):
                record = history[int(msg_id_str)]
            if not record: raise Exception()
        except:
            send_msg("❌ 历史记录读取失败。")
            return

        if data.startswith("rb_"):
            info = f"🕒 {record.get('time')} | 📦 {record.get('size', '未知大小')}"
            buttons = [
                [{"text": "✅ 确定回滚 (覆盖当前数据)", "callback_data": f"rbcfm_{msg_id_str}"}],
                [{"text": "❌ 取消操作", "callback_data": "cancel"}]
            ]
            send_msg(f"⚠️ <b>危险操作确认</b>\n您即将回滚到以下快照：\n{info}\n\n<i>此操作将彻底抹除当前 VPS 上的机器人配置和长短期记忆，并且无法撤销！</i>", {"inline_keyboard": buttons})
            return

        file_ids = record.get("file_ids", [])
        if not file_ids:
            single_id = record.get("file_id")
            if single_id: file_ids = [single_id]
        if not file_ids:
            send_msg("❌ 此记录无文件ID。")
            return

        send_msg(f"⏳ 正在执行回滚前自动快照...")
        
        def do_rollback():
            # 回滚前先做一次完整备份，确保当前状态可恢复
            pre_result = run_cmd(f"{BACKUP_DIR}/backup.sh")
            if "发送成功" in pre_result:
                send_msg("✅ 回滚前快照已保存。正在下载目标备份...")
            else:
                send_msg("⚠️ 回滚前快照失败，但仍将继续回滚。当前配置已本地备份至 ~/.openclaw_old")
            
            local_merged_file = f"/tmp/rb_{int(time.time())}.tar.gz"
            try:
                with open(local_merged_file, "wb") as f_out:
                    for idx, fid in enumerate(file_ids):
                        finfo = requests.post(f"{API_URL}/getFile", json={"file_id": fid}).json()
                        if not finfo.get("ok"):
                            send_msg(f"❌ 获取第 {idx+1} 个卷失败，中止回滚。")
                            os.remove(local_merged_file)
                            return
                        dl_url = f"https://api.telegram.org/file/bot{BOT_TOKEN}/" + finfo["result"]["file_path"]
                        f_out.write(requests.get(dl_url).content)
                out = run_cmd(f"bash {BACKUP_DIR}/restore.sh '{local_merged_file}'")
                send_msg(f"✅ <b>回滚执行日志:</b>\n<pre>{out[-3000:]}</pre>")
            finally:
                if os.path.exists(local_merged_file): os.remove(local_merged_file)
            
        threading.Thread(target=do_rollback).start()

def main():
    set_commands()
    send_msg(f"👋 <b>Guardian 守护进程 ({VERSION}) 已启动并接管 OpenClaw！</b>\n随时可以使用 /status 检查状态。")
    threading.Thread(target=health_monitor, daemon=True).start()
    threading.Thread(target=ota_monitor, daemon=True).start()
    try:
        r = requests.get(f"{API_URL}/getUpdates", timeout=5).json()
        if r.get("ok") and r["result"]:
            ignored = r["result"][-1]["update_id"] + 1
            requests.get(f"{API_URL}/getUpdates", params={"offset": ignored, "timeout": 1})
    except: pass
    
    offset = None
    while True:
        try:
            r = requests.get(f"{API_URL}/getUpdates", params={"offset": offset, "timeout": 30}, timeout=35).json()
            if r.get("ok"):
                for upd in r["result"]:
                    offset = upd["update_id"] + 1
                    if "message" in upd: handle_msg(upd["message"])
                    elif "callback_query" in upd: handle_callback(upd["callback_query"])
        except: time.sleep(5)

if __name__ == "__main__":
    main()
EOF

# =================================================================
# 5. 配置 Systemd 服务与 Cron
# =================================================================
log_step "[5/5] 配置守护进程与定时任务..."

cat > /etc/systemd/system/openclaw-guardian.service <<EOF
[Unit]
Description=OpenClaw Guardian Telegram Bot
After=network.target

[Service]
ExecStart=$BACKUP_DIR/venv/bin/python $BACKUP_DIR/guardian-bot.py
WorkingDirectory=$BACKUP_DIR
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable openclaw-guardian
# 停止旧版本(如果存在)
systemctl stop sysmonitor 2>/dev/null || true
systemctl disable sysmonitor 2>/dev/null || true

systemctl restart openclaw-guardian

# 每 4 小时执行一次备份 (改用最高兼容性的显式小时列表，并强制指定 bash 执行)
CRON_CMD="0 0,4,8,12,16,20 * * * /bin/bash $BACKUP_DIR/backup.sh >> $BACKUP_DIR/cron_backup.log 2>&1"
(crontab -l 2>/dev/null | grep -v "$BACKUP_DIR/backup.sh" || true; echo "$CRON_CMD") | crontab -

# 强制重启一次 Cron 服务以激活新配置
service cron restart || systemctl restart cron || service crond restart || true

echo ""
echo -e "${CYAN}=================================================================${PLAIN}"
echo -e "${GREEN}🎉 OpenClaw Guardian 部署成功！${PLAIN}"
echo -e "${CYAN}=================================================================${PLAIN}"
echo -e "${YELLOW}📌 关键功能${PLAIN}"
echo "  - 常驻守护: 你的 Telegram Bot 现在全天 24 小时在线"
echo "  - 双层监控: journalctl 实时流 + 60s 兜底轮询"
echo "  - 增量备份: 每 4 小时自动备份一次 OpenClaw 核心数据"
echo ""
echo -e "${YELLOW}🛠️ Telegram 命令列表${PLAIN}"
echo "  /status   - 查看系统和 OpenClaw 状态"
echo "  /backup   - 触发手动备份"
echo "  /rollback - 历史备份一键回滚"
echo "  /restart  - 强制重启 OpenClaw 服务"
echo "  /logs     - 查看报错日志"
echo -e "${CYAN}=================================================================${PLAIN}"
