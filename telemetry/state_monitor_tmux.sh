#!/bin/bash
# tmuxベースの状態監視スクリプト（公式hooks代替）

if [ $# -lt 2 ]; then
    echo "Usage: $0 <AGENT_ID> <PANE_ID>"
    exit 1
fi

AGENT_ID=$1
PANE_ID=$2

# プロジェクトルート
if [ -n "$VIBECODE_ROOT" ]; then
    PROJECT_ROOT="$VIBECODE_ROOT"
else
    PROJECT_ROOT="$(pwd)"
fi

# 状態管理
STATE="idle"
PENDING_STATE="idle"
PENDING_START=0
STATE_PERSISTENCE_MS=200

# session_id取得（agent_and_pane_id_table.jsonlから）
get_session_id() {
    if [ -f "$PROJECT_ROOT/Agent-shared/agent_and_pane_id_table.jsonl" ]; then
        grep "\"agent_id\":\"$AGENT_ID\"" "$PROJECT_ROOT/Agent-shared/agent_and_pane_id_table.jsonl" | \
            tail -1 | \
            grep -oP '"claude_session_id":"\K[^"]*'
    fi
}

# 状態検出
detect_state() {
    local content="$1"
    local content_lower=$(echo "$content" | tr '[:upper:]' '[:lower:]')

    # waiting
    if echo "$content" | grep -qE "│ do you want|│ would you like"; then
        echo "waiting"
        return
    fi

    # busy
    if echo "$content_lower" | grep -q "esc to interrupt"; then
        echo "busy"
        return
    fi

    echo "idle"
}

# 状態変化時の処理
on_state_changed() {
    local old_state="$1"
    local new_state="$2"

    # Stopイベント相当（busy/waiting → idle）
    if [ "$new_state" = "idle" ] && [ "$old_state" != "idle" ]; then
        if [ -f "$CLAUDE_PROJECT_DIR/.claude/hooks/stop.py" ]; then
            echo "[state_monitor] Calling Stop hook"
            echo '{}' | python3 "$CLAUDE_PROJECT_DIR/.claude/hooks/stop.py" 2>/dev/null || true
        fi
    fi
}

echo "[state_monitor] Starting for $AGENT_ID (pane: $PANE_ID)"

# SessionStart hook実行（起動時1回のみ）
if [ -f "$CLAUDE_PROJECT_DIR/.claude/hooks/session_start.py" ]; then
    echo "[state_monitor] Calling SessionStart hook"
    echo '{}' | python3 "$CLAUDE_PROJECT_DIR/.claude/hooks/session_start.py" 2>/dev/null || true
fi

# PostToolUse監視用の最終チェック時刻
LAST_TOOL_CHECK=0

# JSONL監視用の関数
check_post_tool_use() {
    # session_idを取得
    local session_id=$(get_session_id)
    if [ -z "$session_id" ]; then
        return
    fi

    # JSONLパスを構築（~/.claude/projects/プロジェクトスラグ/session_id.jsonl）
    local home_dir=$(eval echo ~$(whoami))
    local jsonl_pattern="$home_dir/.claude/projects/*/${session_id}.jsonl"
    local jsonl_file=$(ls $jsonl_pattern 2>/dev/null | head -1)

    if [ ! -f "$jsonl_file" ]; then
        return
    fi

    # 最新10行をチェック（tool_useイベントを探す）
    local recent_tools=$(tail -10 "$jsonl_file" 2>/dev/null | grep -o '"type":"tool_use".*"name":"Bash"' | tail -1)

    if [ -n "$recent_tools" ]; then
        # Bash tool_useが見つかった場合、post_tool_ssh_handler.pyを呼ぶ
        if [ -f "$CLAUDE_PROJECT_DIR/.claude/hooks/post_tool_ssh_handler.py" ]; then
            echo "[state_monitor] Detected Bash tool use, calling PostToolUse hook"
            # 最新のtool_use行全体を取得してstdinに渡す
            tail -10 "$jsonl_file" 2>/dev/null | grep '"type":"tool_use"' | tail -1 | python3 "$CLAUDE_PROJECT_DIR/.claude/hooks/post_tool_ssh_handler.py" 2>/dev/null || true
        fi
    fi
}

# メインループ
while true; do
    # tmux pane存在確認
    if ! tmux list-panes -t "$PANE_ID" >/dev/null 2>&1; then
        echo "[state_monitor] Pane $PANE_ID not found, exiting"
        break
    fi

    # 最新30行取得
    OUTPUT=$(tmux capture-pane -p -S -30 -E -1 -t "$PANE_ID" 2>/dev/null || echo "")

    if [ -n "$OUTPUT" ]; then
        # 状態検出
        DETECTED=$(detect_state "$OUTPUT")
        NOW=$(date +%s%3N 2>/dev/null || echo "0")

        # PostToolUse監視（5秒ごとにチェック）
        if [ "$NOW" != "0" ]; then
            if [ $((NOW - LAST_TOOL_CHECK)) -ge 5000 ]; then
                check_post_tool_use
                LAST_TOOL_CHECK=$NOW
            fi
        fi

        # デバウンス処理
        if [ "$DETECTED" != "$PENDING_STATE" ]; then
            PENDING_STATE="$DETECTED"
            PENDING_START=$NOW
        else
            if [ "$NOW" != "0" ]; then
                DURATION=$((NOW - PENDING_START))
                if [ $DURATION -ge $STATE_PERSISTENCE_MS ] && [ "$STATE" != "$DETECTED" ]; then
                    OLD_STATE="$STATE"
                    STATE="$DETECTED"
                    echo "[state_monitor] State changed: $OLD_STATE → $STATE"
                    on_state_changed "$OLD_STATE" "$STATE"
                fi
            fi
        fi
    fi

    sleep 0.1
done

echo "[state_monitor] Stopped for $AGENT_ID"
