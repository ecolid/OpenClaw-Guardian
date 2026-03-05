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

# 要求用户输入 Telegram Bot Token
while true; do
    read -p "请输入你的 Telegram Bot Token (例如 123456789:ABCdefGHI...): " TG_BOT_TOKEN
    if [[ "$TG_BOT_TOKEN" =~ ^[0-9]+:[a-zA-Z0-9_-]+$ ]]; then
        break
    else
        log_warn "Token 格式似乎有误，请重新输入。"
    fi
done

# 要求用户输入 Telegram Chat ID
while true; do
    read -p "请输入接收通知的 Telegram Chat ID (你的个人数字ID，例如 12345678): " TG_CHAT_ID
    if [[ "$TG_CHAT_ID" =~ ^[0-9]+$ || "$TG_CHAT_ID" =~ ^-[0-9]+$ ]]; then
        break
    else
        log_warn "Chat ID 格式有误，必须是纯数字 (或带负号的群组ID)。"
    fi
done

log_info "配置完成，准备开始安装环境..."

# =================================================================
# 1. 前置准备
# =================================================================
log_step "[1/5] 安装必要依赖..."
if [ "$EUID" -ne 0 ]; then
  log_error "请使用 root 权限运行此脚本 (例如: sudo bash deploy-guardian.sh)"
fi

apt-get update -y
apt-get install -y tar curl jq cron python3 python3-pip python3-venv inotify-tools

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
# ================================================
# OpenClaw Guardian - 增量备份脚本
# ================================================

BOT_TOKEN="${TG_BOT_TOKEN}"
CHAT_ID="${TG_CHAT_ID}"
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
tar --warning=no-file-changed -czf "\${BACKUP_FILE}" config/ restore.sh || true

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
import requests, time, subprocess, json, os, threading

BOT_TOKEN = "${TG_BOT_TOKEN}"
CHAT_ID = "${TG_CHAT_ID}"
BACKUP_DIR = "${BACKUP_DIR}"
HISTORY_FILE = os.path.join(BACKUP_DIR, "backup-history.json")

API_URL = f"https://api.telegram.org/bot{BOT_TOKEN}"

def send_msg(text, reply_markup=None):
    payload = {"chat_id": CHAT_ID, "text": text, "parse_mode": "HTML"}
    if reply_markup: payload["reply_markup"] = json.dumps(reply_markup)
    try: requests.post(f"{API_URL}/sendMessage", json=payload, timeout=10)
    except: pass

def run_cmd(cmd):
    try: return subprocess.check_output(cmd, shell=True, text=True, stderr=subprocess.STDOUT)
    except subprocess.CalledProcessError as e: return e.output

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

def config_monitor():
    """防抖监听配置改动自动备份"""
    os.makedirs("/root/.openclaw/agents", exist_ok=True)
    cmd = "inotifywait -m -e modify,create,delete /root/.openclaw/openclaw.json /root/.openclaw/agents/ 2>/dev/null"
    
    last_backup_time = 0
    pending_timer = None
    lock = threading.Lock()
    
    def do_backup_task():
        nonlocal last_backup_time, pending_timer
        with lock: pending_timer = None
        send_msg("👀 检测到配置修改并已度过冷却期，正在执行后台增量备份...")
        run_cmd(f"{BACKUP_DIR}/backup.sh")
        with lock: last_backup_time = time.time()

    while True:
        proc = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        while proc.poll() is None:
            line = proc.stdout.readline()
            if not line:
                time.sleep(1)
                continue
            now = time.time()
            with lock:
                if pending_timer is None:
                    wait_time = 15 
                    if now - last_backup_time < 300:
                        wait_time = 300 - (now - last_backup_time) + 5
                    pending_timer = threading.Timer(wait_time, do_backup_task)
                    pending_timer.start()
                    if wait_time > 20: 
                        send_msg(f"👀 收到改动通知（当前在备份冷却期），已排期于 {int(wait_time)} 秒后合并备份。")
        time.sleep(2)

# --- 指令处理 ---
def set_commands():
    commands = [
        {"command": "status", "description": "查看服务器状态与内存占用"},
        {"command": "backup", "description": "立即全量备份机器人配置"},
        {"command": "rollback", "description": "一键回滚到历史快照"},
        {"command": "restart", "description": "重启机器人的后端进程"},
        {"command": "logs", "description": "查看最近的报错日志"}
    ]
    try: requests.post(f"{API_URL}/setMyCommands", json={"commands": commands}, timeout=5)
    except: pass

def handle_msg(msg):
    if "text" not in msg: return
    text = msg["text"]
    if str(msg["chat"]["id"]) != CHAT_ID: return

    if text.startswith("/status"):
        status = run_cmd("systemctl is-active openclaw").strip()
        mem = run_cmd("free -m | awk 'NR==2{printf \"%.2f%%\", \$3*100/\$2 }'")
        disk = run_cmd("df -h / | awk 'NR==2{print \$5}'")
        send_msg(f"📊 <b>系统状态</b>\nOpenClaw: <code>{status}</code>\n内存使用: <code>{mem}</code>\n磁盘空间: <code>{disk}</code>")
    elif text.startswith("/backup"):
        send_msg("⏳ 正在执行全量备份，请稍候...")
        threading.Thread(target=lambda: run_cmd(f"{BACKUP_DIR}/backup.sh")).start()
    elif text.startswith("/restart"):
        send_msg("🔄 正在重启 OpenClaw...")
        run_cmd("systemctl restart openclaw")
        send_msg("✅ 重启指令已发送。使用 /status 检查状态。")
    elif text.startswith("/logs"):
        logs = run_cmd("journalctl -u openclaw -n 20 --no-pager")[-3500:]
        send_msg(f"📝 <b>最近日志:</b>\n<pre>{logs}</pre>")
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
    
    if data.startswith("rb_"):
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

        file_ids = record.get("file_ids", [])
        if not file_ids:
            single_id = record.get("file_id")
            if single_id: file_ids = [single_id]
        if not file_ids:
            send_msg("❌ 此记录无文件ID。")
            return

        send_msg(f"⏳ 正在下载 {len(file_ids)} 个备份分卷，请稍候...")
        
        def do_rollback():
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
    send_msg("👋 <b>Guardian 守护进程已启动并接管 OpenClaw！</b>\n随时可以使用 /status 检查状态。")
    threading.Thread(target=health_monitor, daemon=True).start()
    threading.Thread(target=config_monitor, daemon=True).start()
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

# 每 4 小时执行一次备份
CRON_CMD="0 */4 * * * $BACKUP_DIR/backup.sh >/dev/null 2>&1"
(crontab -l 2>/dev/null | grep -v "$BACKUP_DIR/backup.sh" || true; echo "$CRON_CMD") | crontab -

echo ""
echo -e "${CYAN}=================================================================${PLAIN}"
echo -e "${GREEN}🎉 OpenClaw Guardian 部署成功！${PLAIN}"
echo -e "${CYAN}=================================================================${PLAIN}"
echo -e "${YELLOW}📌 关键功能${PLAIN}"
echo "  - 常驻守护: 你的 Telegram Bot 现在全天 24 小时在线"
echo "  - 双层监控: journalctl 实时流 + 60s 兜底轮询"
echo "  - 修改防抖: 配置文件发生改动时，自动倒计时合并备份"
echo ""
echo -e "${YELLOW}🛠️ Telegram 命令列表${PLAIN}"
echo "  /status   - 查看系统和 OpenClaw 状态"
echo "  /backup   - 触发手动备份"
echo "  /rollback - 历史备份一键回滚"
echo "  /restart  - 强制重启 OpenClaw 服务"
echo "  /logs     - 查看报错日志"
echo -e "${CYAN}=================================================================${PLAIN}"
