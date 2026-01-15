#!/bin/bash

# Agent Monitor - Lifecycle Hook Installer
# https://github.com/vaxin/agent-monitor
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/vaxin/agent-monitor/main/install.sh | bash

set -e

echo "🔧 Installing Agent Monitor lifecycle hook..."

# Check for jq dependency
if ! command -v jq &> /dev/null; then
    echo "⚠️  jq is required but not installed."
    echo "   Install with: brew install jq"
    exit 1
fi

# Create directories
mkdir -p ~/.claude/hooks
mkdir -p ~/.claude/logs/lifecycle

# Download or create the monitoring script
cat > ~/.claude/hooks/lifecycle-monitor.sh << 'EOF'
#!/bin/bash

# Agent Monitor - Claude Code Lifecycle Hook
# https://github.com/vaxin/agent-monitor

# 获取事件类型（从命令行参数）
EVENT_TYPE="$1"

# 读取 stdin 的完整 JSON
INPUT=$(cat)

# 提取关键信息
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
PROJECT_DIR=$(echo "$INPUT" | jq -r '.cwd // "unknown"')

# 向上查找 claude 进程 PID（用于精确匹配 iTerm2 tab）
find_claude_pid() {
    local pid=$PPID
    while [ "$pid" != "1" ] && [ -n "$pid" ]; do
        local cmd=$(ps -p $pid -o comm= 2>/dev/null)
        if [[ "$cmd" == *"claude"* ]]; then
            echo $pid
            return
        fi
        pid=$(ps -p $pid -o ppid= 2>/dev/null | tr -d ' ')
    done
}
CLAUDE_PID=$(find_claude_pid)

# 日志目录
LOG_DIR="$HOME/.claude/logs/lifecycle"
mkdir -p "$LOG_DIR"

# 按 session 分类的日志文件
SESSION_LOG="$LOG_DIR/session-${SESSION_ID}.log"
ALL_EVENTS_LOG="$LOG_DIR/all-events.jsonl"

# 构建日志条目
LOG_ENTRY=$(cat <<LOGEOF
[$TIMESTAMP] EVENT: $EVENT_TYPE
  Session ID: $SESSION_ID
  Project: $PROJECT_DIR
LOGEOF
)

# 根据不同事件类型添加特定信息
case "$EVENT_TYPE" in
  SessionStart)
    SOURCE=$(echo "$INPUT" | jq -r '.source // "unknown"')
    LOG_ENTRY="$LOG_ENTRY
  Source: $SOURCE (startup/resume/clear)
  PID: $CLAUDE_PID"
    echo "🚀 Session Started: $SESSION_ID (PID: $CLAUDE_PID)" >&2
    ;;

  SessionEnd)
    REASON=$(echo "$INPUT" | jq -r '.reason // "unknown"')
    LOG_ENTRY="$LOG_ENTRY
  End Reason: $REASON"
    echo "🛑 Session Ended: $SESSION_ID (Reason: $REASON)" >&2

    # Session 结束时播放声音 (macOS only)
    afplay /System/Library/Sounds/Glass.aiff 2>/dev/null &
    ;;

  UserPromptSubmit)
    PROMPT=$(echo "$INPUT" | jq -r '.prompt // ""' | cut -c 1-100)
    LOG_ENTRY="$LOG_ENTRY
  Prompt: ${PROMPT}..."
    ;;

  PreToolUse|PostToolUse)
    TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"')
    LOG_ENTRY="$LOG_ENTRY
  Tool: $TOOL_NAME"

    if [ "$EVENT_TYPE" = "PostToolUse" ]; then
      # 可以记录工具执行结果
      RESULT=$(echo "$INPUT" | jq -r '.tool_response // ""' | cut -c 1-50)
      LOG_ENTRY="$LOG_ENTRY
  Result: ${RESULT}..."
    fi
    ;;

  Stop)
    echo "✅ Claude Response Complete: $SESSION_ID" >&2
    # 播放不同的声音 (macOS only)
    afplay /System/Library/Sounds/Ping.aiff 2>/dev/null &
    ;;

  SubagentStop)
    echo "🤖 Subagent Complete: $SESSION_ID" >&2
    ;;

  PermissionRequest)
    TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"')
    LOG_ENTRY="$LOG_ENTRY
  Permission for: $TOOL_NAME"
    echo "🔐 Permission Request: $TOOL_NAME" >&2
    ;;

  PreCompact)
    TRIGGER=$(echo "$INPUT" | jq -r '.trigger // "unknown"')
    LOG_ENTRY="$LOG_ENTRY
  Trigger: $TRIGGER (manual/auto)"
    echo "📦 Compaction: $SESSION_ID" >&2
    ;;

  Notification)
    NOTIF_TYPE=$(echo "$INPUT" | jq -r '.notification_type // "unknown"')
    LOG_ENTRY="$LOG_ENTRY
  Type: $NOTIF_TYPE"
    ;;
esac

# 写入按 session 分类的日志
echo "$LOG_ENTRY" >> "$SESSION_LOG"
echo "---" >> "$SESSION_LOG"

# 写入 JSONL 格式的全局日志（便于分析）
JSONL_ENTRY=$(jq -n \
  --arg ts "$TIMESTAMP" \
  --arg event "$EVENT_TYPE" \
  --arg session "$SESSION_ID" \
  --arg pid "$CLAUDE_PID" \
  --argjson input "$INPUT" \
  '{
    timestamp: $ts,
    event: $event,
    session_id: $session,
    claude_pid: $pid,
    data: $input
  }')
echo "$JSONL_ENTRY" >> "$ALL_EVENTS_LOG"

# 成功退出
exit 0
EOF

# Set execute permission
chmod +x ~/.claude/hooks/lifecycle-monitor.sh

# Test the script
echo "🧪 Testing installation..."
echo '{"session_id":"test-install","cwd":"/tmp/test"}' | ~/.claude/hooks/lifecycle-monitor.sh SessionStart 2>&1 | head -1

echo ""
echo "✅ Hook script installed to: ~/.claude/hooks/lifecycle-monitor.sh"
echo ""
echo "📝 Next steps:"
echo "   1. Run: claude config edit"
echo "   2. Add the following hooks configuration to your settings.json:"
echo ""
cat << 'CONFIG'
{
  "hooks": {
    "SessionStart": [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/lifecycle-monitor.sh SessionStart" }] }],
    "SessionEnd": [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/lifecycle-monitor.sh SessionEnd" }] }],
    "Stop": [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/lifecycle-monitor.sh Stop" }] }],
    "SubagentStop": [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/lifecycle-monitor.sh SubagentStop" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/lifecycle-monitor.sh UserPromptSubmit" }] }],
    "PreToolUse": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "~/.claude/hooks/lifecycle-monitor.sh PreToolUse" }] }],
    "PostToolUse": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "~/.claude/hooks/lifecycle-monitor.sh PostToolUse" }] }],
    "PreCompact": [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/lifecycle-monitor.sh PreCompact" }] }],
    "Notification": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "~/.claude/hooks/lifecycle-monitor.sh Notification" }] }],
    "PermissionRequest": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "~/.claude/hooks/lifecycle-monitor.sh PermissionRequest" }] }]
  }
}
CONFIG
echo ""
echo "📁 Logs will be written to: ~/.claude/logs/lifecycle/"
echo "🖥️  For the GUI app, download from: https://github.com/vaxin/agent-monitor/releases"
