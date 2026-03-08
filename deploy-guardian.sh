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

# [Diagnostic 1.5.6] 捕获错误行号并记录环境
trap 'echo "❌ ERROR: 脚本在第 \$LINENO 行挂掉了 (Exit Code: \$?)" >> "$BACKUP_DIR/cron_backup.log"' ERR
echo "DEBUG: 当前 PATH=\$PATH" >> "$BACKUP_DIR/cron_backup.log"
echo "DEBUG: 当前 Proxy=\$(env | grep -iE 'proxy|http' || echo 'None')" >> "$BACKUP_DIR/cron_backup.log"

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

    echo "📦 正在上传卷 \${PART_INDEX}/\${TOTAL_PARTS} (size: \$(ls -lh "\$PART" | awk '{print \$5}')) ..." >> "$BACKUP_DIR/cron_backup.log"
    RESPONSE=\$(curl --max-time 60 -X POST "https://api.telegram.org/bot\${BOT_TOKEN}/sendDocument" \\
      -F chat_id="\${CHAT_ID}" \\
      -F disable_notification="true" \\
      -F document="@\${PART}" \\
      -F caption="\${CAPTION}")

    if echo "\$RESPONSE" | jq -e '.ok' >/dev/null 2>&1; then
        MSG_ID=\$(echo "\$RESPONSE" | jq -r '.result.message_id')
        FILE_ID=\$(echo "\$RESPONSE" | jq -r '.result.document.file_id')
        
        UPLOADED_IDS+=("\$FILE_ID")
        echo "卷 \${PART_INDEX} 发送成功。" >> "$BACKUP_DIR/cron_backup.log"
    else
        echo "❌ Telegram 发送失败 | 响应: \$RESPONSE" >> "$BACKUP_DIR/cron_backup.log"
        curl -s -X POST "https://api.telegram.org/bot\${BOT_TOKEN}/sendMessage" \\
            -d chat_id="\${CHAT_ID}" \\
            -d text="❌ [Guardian 备份失败] 卷 \${PART_INDEX} 上传失败。由于 Telegram API 报错，请检查网络或 Token。"
        exit 1
    fi
    PART_INDEX=\$((PART_INDEX + 1))
done

echo "所有分卷发送完毕！正在记录历史..." >> "$BACKUP_DIR/cron_backup.log"

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

# --- [Cloud Sync 1.6.0] 元数据私有云同步 ---
echo "🔐 正在同步元数据至云端索引..." >> "\$BACKUP_DIR/cron_backup.log"
METADATA_PKG="\${TMP_DIR}/Guardian_Sync_\${TIMESTAMP}.tar.gz"
STATS_FILE="\$BACKUP_DIR/stats.json"

# 打包索引与统计
tar -czf "\${METADATA_PKG}" -C "$BACKUP_DIR" backup-history.json stats.json 2>/dev/null || true

if [ -f "\${METADATA_PKG}" ]; then
    curl --max-time 30 -X POST "https://api.telegram.org/bot\${BOT_TOKEN}/sendDocument" \\
      -F chat_id="\${CHAT_ID}" \\
      -F disable_notification="true" \\
      -F document="@\${METADATA_PKG}" \\
      -F caption="🔐 [Guardian 云端同步包] 
- 类型: 元数据索引 (Metadata)
- 时间: \$(date +"%Y-%m-%d %H:%M:%S")
💡 提示：此文件仅包含备份清单与字数统计，不含大型备份文件。请妥善保存，用于异地恢复索引。" >> "\$BACKUP_DIR/cron_backup.log" 2>&1
fi

rm -rf "\${TMP_DIR}"
echo "清理完毕。"
EOF

chmod +x "$BACKUP_DIR/backup.sh"

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
import requests, time, subprocess, json, os, threading, html, re

BOT_TOKEN = "${TG_BOT_TOKEN}"
CHAT_ID = "${TG_CHAT_ID}"
BACKUP_DIR = "${BACKUP_DIR}"
VERSION = "v1.8.7"
SCHEDULE_FILE = os.path.join(BACKUP_DIR, "schedule.json")

API_URL = f"https://api.telegram.org/bot{BOT_TOKEN}"
grep_lock = threading.Lock()
is_thinking = False
think_start_time = 0
think_msg_id = None
last_shown_time = 0
STATS_FILE = os.path.join(BACKUP_DIR, "stats.json")

def load_stats():
    today = time.strftime("%Y-%m-%d")
    if os.path.exists(STATS_FILE):
        try:
            with open(STATS_FILE, "r") as f:
                s = json.load(f)
                if s.get("last_reset_date") != today:
                    s.update({"today_prompt_chars": 0, "today_convs": 0, "today_folds": 0, "last_reset_date": today})
                return s
        except: pass
    return {"total_prompt_chars": 0, "today_prompt_chars": 0, "total_convs": 0, "today_convs": 0, "total_folds": 0, "today_folds": 0, "total_thinking_seconds": 0, "last_reset_date": today}

def load_schedule():
    default = {"hours": [3, 7, 11, 15, 19, 23], "label": "每 4 小时 (错峰)"}
    if os.path.exists(SCHEDULE_FILE):
        try:
            with open(SCHEDULE_FILE, "r") as f: return json.load(f)
        except: pass
    return default

def save_schedule(s):
    try:
        with open(SCHEDULE_FILE, "w") as f: json.dump(s, f)
        h_str = ",".join(map(str, s["hours"]))
        cmd = f"0 {h_str} * * * /bin/bash {BACKUP_DIR}/backup.sh >> {BACKUP_DIR}/cron_backup.log 2>&1"
        run_cmd(f"(crontab -l 2>/dev/null | grep -v '{BACKUP_DIR}/backup.sh' || true; echo '{cmd}') | crontab -")
        run_cmd("service cron restart || systemctl restart cron || service crond restart || true")
        return True
    except: return False

def get_backup_info():
    """计算下一次备份的标签和时间"""
    try:
        now_h = time.localtime().tm_hour
        sch = load_schedule()
        hours = sch["hours"]
        next_h = hours[0]
        for h in hours:
            if h > now_h:
                next_h = h; break
        return sch["label"], f"{next_h:02d}:00"
    except: return "未知计划", "未知时间"

def save_stats(s):
    try:
        with open(STATS_FILE, "w") as f: json.dump(s, f)
    except: pass

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

def thinking_monitor():
    """实时追踪 OpenClaw 思考状态并同步到 Telegram"""
    global is_thinking, think_start_time, think_msg_id
    session_chars = 0
    session_folds = 0
    session_tools = 0
    
    def update_think_msg(final=False):
        global think_msg_id, last_shown_time
        if not think_msg_id: return
        now_ts = time.time()
        elapsed = int(now_ts - think_start_time)
        delta = elapsed - last_shown_time
        
        if final:
            s = load_stats()
            total_convs = s.get("total_convs", 0)
            total_seconds = s.get("total_thinking_seconds", 0)
            avg = total_seconds / max(1, total_convs)
            diff = elapsed - avg
            if abs(diff) < 0.5: diff_info = " (⚖️ 持平)"
            else: diff_info = f" ({'-' if diff < 0 else '+'}{abs(diff):.1f}s)"
            perf_icon = "📈" if diff <= 0.5 else "📉"
            
            fold_str = f"\n♻️ 上下文折叠: <code>{session_folds}</code> 次" if session_folds > 0 else ""
            tool_str = f"\n🛠️ 工具执行: <code>{session_tools}</code> 次" if session_tools > 0 else ""
            text = f"✅ <b>小龙虾思考完毕！</b>\n⏱️ 总耗时: <code>{elapsed}</code>s {perf_icon} <code>{diff_info}</code>\n📊 本次消耗: <code>{session_chars:,}</code> 字符{tool_str}{fold_str}"
        else:
            # 🌑🌒🌓🌔🌕🌖🌗🌘 盈亏序列
            moons = ['🌑', '🌒', '🌓', '🌔', '🌕', '🌖', '🌗', '🌘']
            icon = moons[int(time.time() * 2) % len(moons)]
            inc_str = f" (+{delta}s)" if delta > 0 else ""
            text = f"Lobster 正在思考中... {icon}\n⏱️ 已耗时: <code>{elapsed}</code> 秒{inc_str}"
        
        try:
            resp = requests.post(f"{API_URL}/editMessageText", json={
                "chat_id": CHAT_ID, "message_id": think_msg_id, "text": text, "parse_mode": "HTML"
            }, timeout=5).json()
            if resp.get("ok"): last_shown_time = elapsed
            if final:
                # v1.8.6: 取消自动删除，让消息作为“对话回执”永久保留
                think_msg_id = None
        except: pass

    def typing_loop():
        while is_thinking:
            try: requests.post(f"{API_URL}/sendChatAction", json={"chat_id": CHAT_ID, "action": "typing"}, timeout=5)
            except: pass
            time.sleep(4)

    while True:
        try:
            # --- [Warm Start 1.7.1] 启动回溯：检查是否正在思考中 ---
            if not is_thinking:
                check_log = run_cmd("journalctl -u openclaw -n 50 --no-pager")
                lines = check_log.strip().split('\n')
                # 倒着找最后一条状态记录
                for l in reversed(lines):
                    if 'new=processing' in l and 'run_started' in l:
                        is_thinking = True
                        # 估算开始时间（从日志行首提取时间戳，简化版直接用当前，或解析日志）
                        think_start_time = time.time()
                        last_shown_time = 0
                        session_chars = 0  # 重置单次会话计数器
                        session_folds = 0
                        # 补发一条计时核心，标记为“恢复检测”
                        resp = requests.post(f"{API_URL}/sendMessage", json={
                            "chat_id": CHAT_ID, "text": "🦞 <b>检测到小龙虾正在思考中... (启动恢复)</b>\n⏱️ 已耗时: <code>计算中...</code>",
                            "parse_mode": "HTML", "disable_notification": True
                        }, timeout=5).json()
                        if resp.get("ok"): think_msg_id = resp["result"]["message_id"]
                        threading.Thread(target=typing_loop, daemon=True).start()
                        def live_ticker():
                            while is_thinking:
                                update_think_msg(); time.sleep(1.0)
                        threading.Thread(target=live_ticker, daemon=True).start()
                        break
                    elif 'new=idle' in l and 'run_completed' in l:
                        break # 最近的状态是空闲，无需恢复

            proc = subprocess.Popen("journalctl -f -u openclaw -n 0 --no-pager", shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            while proc.poll() is None:
                line = proc.stdout.readline()
                if not line: break
                line_str = line.decode("utf-8", errors="ignore").strip()
                if 'new=processing' in line_str and 'run_started' in line_str:
                    is_thinking = True
                    think_start_time = time.time()
                    last_shown_time = 0
                    session_chars = 0  # 重置单次会话计数器
                    session_folds = 0
                    resp = requests.post(f"{API_URL}/sendMessage", json={
                        "chat_id": CHAT_ID, "text": "🦞 <b>小龙虾正在思考中...</b>\n⏱️ 已耗时: <code>0s</code>",
                        "parse_mode": "HTML", "disable_notification": True
                    }, timeout=5).json()
                    if resp.get("ok"): think_msg_id = resp["result"]["message_id"]
                    threading.Thread(target=typing_loop, daemon=True).start()
                    def live_ticker():
                        while is_thinking:
                            update_think_msg(); time.sleep(1.0)
                    threading.Thread(target=live_ticker, daemon=True).start()

                # --- 实时采集单次会话的数据 ---
                if is_thinking:
                    # 匹配 promptChars=X (注意 shell heredoc 中的转义)
                    char_match = re.search(r'promptChars=(\d+)', line_str)
                    if char_match: session_chars += int(char_match.group(1))
                    
                    # 匹配工具调用：排除 diagnostic/telegram/routing 等系统日志，抓取 web_search/brave/python 等执行日志
                    # 通常工具日志不带 [diagnostic] 等系统标签，或者带有特定的 [tool] 标签
                    if ']:' in line_str and not any(x in line_str for x in ['[diagnostic]', '[telegram]', '[routing]', '[agent/embedded]']):
                        session_tools += 1
                    
                    # 匹配折叠：只有当真正执行 folding 逻辑时才计入，过滤掉 pre-prompt 里的静态统计
                    if 'compacting' in line_str.lower() or 'folding' in line_str.lower():
                        if '[diagnostic]' not in line_str: session_folds += 1

                if 'new=idle' in line_str and 'run_completed' in line_str:
                    if is_thinking:
                        is_thinking = False
                        final_elapsed = time.time() - think_start_time
                        s = load_stats()
                        s["total_thinking_seconds"] = s.get("total_thinking_seconds", 0) + final_elapsed
                        save_stats(s)
                        update_think_msg(final=True)
                
                # --- [Stats Logic 1.8.7 Fix] ---
                if 'pre-prompt:' in line_str and 'promptChars=' in line_str:
                    try:
                        pc = int(re.search(r'promptChars=(\d+)', line_str).group(1))
                        s = load_stats(); s['total_prompt_chars'] += pc; s['today_prompt_chars'] += pc
                        s['total_convs'] += 1; s['today_convs'] += 1
                        save_stats(s)
                    except: pass
                if 'compactionSummary:' in line_str:
                    try:
                        fc = int(re.search(r'compactionSummary:(\\d+)', line_str).group(1))
                        s = load_stats(); s['total_folds'] += fc; s['today_folds'] += fc
                        save_stats(s)
                    except: pass
        except: pass
        time.sleep(5)

def ota_monitor():
    """后台轮询 GitHub 检查更新"""
    notified_version = VERSION
    while True:
        try:
            r = requests.get("https://raw.githubusercontent.com/ecolid/OpenClaw-Guardian/main/deploy-guardian.sh", timeout=15)
            if r.status_code == 200:
                remote_version = None
                # 使用正则更稳健地提取版本号
                v_match = re.search(r'VERSION = "(.*?)"', r.text)
                if v_match:
                    remote_version = v_match.group(1)
                    if remote_version != VERSION and remote_version != notified_version:
                        # 获取更新日志 (Fetch latest changelog entry)
                        cl_r = requests.get("https://raw.githubusercontent.com/ecolid/OpenClaw-Guardian/main/CHANGELOG.md", timeout=10)
                        notes = ""
                        if cl_r.status_code == 200:
                            p = False
                            for l in cl_r.text.split('\n'):
                                if l.strip().startswith('## [v'):
                                    if p: break
                                    p = True; continue
                                if p: notes += l + '\n'
                        
                        notes = notes.strip()[:500]
                        changelog_str = f"\n\n📝 <b>新版更新内容:</b>\n<pre>{html.escape(notes)}</pre>" if notes else ""
                        
                        btn = [[{"text": "📥 立即查看并准备更新", "callback_data": "ota_update"}]]
                        send_msg(f"🎉 <b>发现 Guardian 新版本！</b>\n当前运行: <code>{VERSION}</code>\n最新版本: <code>{remote_version}</code>{changelog_str}\n\n建议点击下方按钮查看详情并进行热更新。", {"inline_keyboard": btn})
                        notified_version = remote_version
        except Exception as e:
            # 仅在调试时开启，平时静默
            # print(f"OTA Check error: {e}")
            pass
        time.sleep(600)

# --- 指令处理 ---
def set_commands():
    commands = [
        # 🔍 状态与监控 (Metrics)
        {"command": "status", "description": "📊 系统核心状态 (硬件/备份/下次预定)"},
        {"command": "stats", "description": "🦞 小龙虾数据看板 (字数统计/对话/折叠)"},
        {"command": "logs", "description": "📄 日志查询中心 (业务/备份双通道)"},
        {"command": "grep", "description": "🔍 故障定向查询 (DataInspection/Timeout/OOM)"},
        
        # 📦 备份与存储 (Storage)
        {"command": "backup", "description": "📦 立即手动执行全量备份"},
        {"command": "rollback", "description": "⏪ 恢复历史快照 (带二次确认)"},
        
        # ⚙️ 系统维护 (Control)
        {"command": "restart", "description": "🔄 重启后端服务 (清理内存/更新配置)"},
        {"command": "schedule", "description": "⏰ 计划调度：调整自动备份频率"},
        {"command": "update", "description": "📥 从 GitHub 获取并更新守护程序 (OTA)"},
        {"command": "update_rollback", "description": "💊 守护程序后悔药 (恢复上一版本大脑)"}
    ]
    try: requests.post(f"{API_URL}/setMyCommands", json={"commands": commands}, timeout=5)
    except: pass

def handle_msg(msg):
    if "text" not in msg: return
    text = msg["text"]
    if str(msg["chat"]["id"]) != CHAT_ID: return

    if text.startswith("/stats"):
        s = load_stats()
        avg_total = s['total_prompt_chars'] / s['total_convs'] if s['total_convs'] else 0
        avg_today = s['today_prompt_chars'] / s['today_convs'] if s['today_convs'] else 0
        avg_time = s.get('total_thinking_seconds', 0) / s['total_convs'] if s['total_convs'] else 0
        dash = f'''📊 <b>小龙虾数据看板 (Stats Center)</b>
-----------------------------------
📅 <b>今日统计 (Today)</b>
- 对话次数: <code>{s['today_convs']}</code> 次
- 字符规模: <code>{s['today_prompt_chars']}</code> Chars
- 记忆折叠: <code>{s['today_folds']}</code> 次
- 平均规模: <code>{avg_today:.1f}</code> 字/次

🌎 <b>历史累计 (Total)</b>
- 总对话数: <code>{s['total_convs']}</code> 次
- 总字符数: <code>{s['total_prompt_chars']}</code> Chars
- 平均规模: <code>{avg_total:.1f}</code> 字/次
- 平均响应: <code>{avg_time:.1f}</code> 秒
-----------------------------------
<i>注: 字符数包含提示词与上下文，反映 API 消耗强度。</i>'''
        send_msg(dash)
        return

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

            uptime = run_cmd("uptime -p").strip().replace("up ", "")
            load = run_cmd("cat /proc/loadavg | awk '{print \$1, \"|\", \$2, \"|\", \$3}'").strip()
            cpu_idle = run_cmd("top -bn1 | grep 'Cpu(s)' | awk '{print \$8}'").strip()
            try: cpu_pct = 100.0 - float(cpu_idle)
            except: cpu_pct = 0.0
            
            free_out = run_cmd("free -m | awk 'NR==2{print \$3, \$2}; NR==3{print \$3, \$2}'").strip().split('\\n')
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

            df_out = run_cmd("df -h / | awk 'NR==2{print \$5, \$3, \$4}'").strip().split()
            try:
                disk_pct = float(df_out[0].replace('%', ''))
                disk_str = f"用{df_out[1]}/剩{df_out[2]}"
            except: disk_pct, disk_str = 0.0, "?/?"

            last_backup_str = "从未备份"
            try:
                if os.path.exists(HISTORY_FILE):
                    with open(HISTORY_FILE, "r") as f:
                        hist = json.load(f)
                        if hist: last_backup_str = hist[0]["time"]
            except: pass

            cron_raw = run_cmd("systemctl is-active cron || service cron status").lower()
            cron_status = "🟢 运行良好" if ("active" in cron_raw and "running" in cron_raw) else "🔴 服务停滞"
            cron_job = run_cmd("crontab -l 2>/dev/null | grep 'backup.sh'").strip()
            cron_job_status = "✅ 已注册" if cron_job else "❌ 未发现任务"

            try:
                label, next_time = get_backup_info()
                next_backup_time = next_time
            except: next_backup_time = "计算中..."

            if is_thinking:
                think_elapsed = int(time.time() - think_start_time)
                status_header = f"🦞 <b>小龙虾状态</b>: 🧠 思考中... (<code>{think_elapsed}s</code>)"
            else:
                status_header = f"🦞 <b>小龙虾状态</b>: 💤 空闲待命"

            dash = f'''📊 <b>核心引擎状态 (Guardian {VERSION})</b>
-----------------------------------
{status_header}
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
⏰ <b>Cron 服务</b>: {cron_status}
📌 <b>定时任务</b>: {cron_job_status}
⏭️ <b>下次预定</b>: 今天 {next_backup_time}
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
            send_msg("🔍 正在连线 GitHub 检查最新的 Guardian 状态...")
            try:
                r = requests.get("https://raw.githubusercontent.com/ecolid/OpenClaw-Guardian/main/deploy-guardian.sh", timeout=10)
                if r.status_code == 200:
                    remote_v = "未知"
                    for line in r.text.split('\n'):
                        if line.startswith('VERSION = "'):
                            remote_v = line.split('"')[1]; break
                    
                    cl_r = requests.get("https://raw.githubusercontent.com/ecolid/OpenClaw-Guardian/main/CHANGELOG.md", timeout=10)
                    notes = ""
                    if cl_r.status_code == 200:
                        p = False
                        for l in cl_r.text.split('\n'):
                            if l.strip().startswith('## [v'):
                                if p: break
                                p = True; continue
                            if p: notes += l + '\n'
                    
                    notes = notes.strip()[:600]
                    change_info = f"\n\n📝 <b>最新版更新内容:</b>\n<pre>{html.escape(notes)}</pre>" if notes else ""
                    
                    if remote_v == VERSION:
                        status_str = f"✅ <b>当前已是最新版本 ({VERSION})</b>\n您可以选择强制重装当前版本以修复潜在环境问题。"
                        btn_txt = "🔄 强制重新部署当前版本"
                    else:
                        status_str = f"🚀 <b>发现新版本: {remote_v}</b> (当前: {VERSION})"
                        btn_txt = f"📥 立即升级至 {remote_v}"
                        
                    btn = [
                        [{"text": btn_txt, "callback_data": "ota_confirm"}],
                        [{"text": "❌ 取消本次更新", "callback_data": "cancel"}]
                    ]
                    send_msg(f"☁️ <b>Guardian 远程更新检查中心</b>\n{status_str}{change_info}\n\n是否立即执行部署脚本并重启服务？", {"inline_keyboard": btn})
                else:
                    send_msg("❌ 无法获取远程版本信息，请检查 VPS 网络。")
            except Exception as e:
                send_msg(f"❌ 链路异常: {str(e)}")
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
    elif text.startswith("/schedule"):
        s = load_schedule()
        buttons = [
            [{"text": "⏰ 每 4 小时 (标准: 0/4/8...)", "callback_data": "sch_4h_std"}],
            [{"text": "⏰ 每 4 小时 (错峰: 3/7/11...)", "callback_data": "sch_4h_off"}],
            [{"text": "⏰ 每 6 小时 (0/6/12/18)", "callback_data": "sch_6h"}],
            [{"text": "⏰ 每 12 小时 (0/12)", "callback_data": "sch_12h"}],
            [{"text": "⏰ 每天一次 (凌晨 00:00)", "callback_data": "sch_daily"}]
        ]
        send_msg(f"📅 <b>备份计划调度器</b>\n当前设置: <code>{s['label']}</code>\n请选择您希望的自动备份频率：", {"inline_keyboard": buttons})

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

    if data == "ota_confirm":
        send_msg("⚙️ <b>指令已确认，正在执行热更新部署...</b>\n请稍候，由于涉及服务重启，Bot 可能会短时间断连。")
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

    if data.startswith("sch_"):
        mode = data[4:]
        modes = {
            "4h_std": {"hours": [0,4,8,12,16,20], "label": "每 4 小时 (标准)"},
            "4h_off": {"hours": [3,7,11,15,19,23], "label": "每 4 小时 (错峰)"},
            "6h": {"hours": [0,6,12,18], "label": "每 6 小时"},
            "12h": {"hours": [0,12], "label": "每 12 小时"},
            "daily": {"hours": [0], "label": "每天一次 (凌晨)"}
        }
        if mode in modes:
            if save_schedule(modes[mode]):
                send_msg(f"✅ <b>计划更新成功！</b>\n新的备份周期: <code>{modes[mode]['label']}</code>\n系统 crontab 已同步刷新。")
            else:
                send_msg("❌ 计划更新失败，请检查文件权限。")
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
    label, next_time = get_backup_info()
    send_msg(f"👋 <b>Guardian 守护进程 ({VERSION}) 已启动！</b>\n📅 当前计划: <code>{label}</code>\n⏭️ 下次执行: <code>今天 {next_time}</code>\n\n随时可以使用 /status 查看详细水位。")
    threading.Thread(target=health_monitor, daemon=True).start()
    threading.Thread(target=thinking_monitor, daemon=True).start()
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

# 自动迁移/初始化 schedule.json
SCHEDULE_FILE="$BACKUP_DIR/schedule.json"
if [ ! -f "$SCHEDULE_FILE" ]; then
    echo '{"hours": [3, 7, 11, 15, 19, 23], "label": "每 4 小时 (错峰)"}' > "$SCHEDULE_FILE"
fi
# 从 JSON 提取当前计划的小时 (优先用 Python 提取以防没有 jq)
HOURS=$(python3 -c "import json; print(','.join(map(str, json.load(open('$SCHEDULE_FILE'))['hours'])))" 2>/dev/null || echo "3,7,11,15,19,23")

# 写入 Crontab (安全性: crontab -l | grep -v 确保只更新 Guardian 任务，不影响用户自定义的其他 Cron)
CRON_CMD="0 $HOURS * * * /bin/bash $BACKUP_DIR/backup.sh >> $BACKUP_DIR/cron_backup.log 2>&1"
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
