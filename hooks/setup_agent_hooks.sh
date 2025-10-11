#!/bin/bash
# VibeCodeHPC エージェント用hooks設定スクリプト
# PMが各エージェント起動時に実行

set -e

# 引数チェック
if [ $# -lt 3 ]; then
    echo "Usage: $0 <AGENT_ID> <AGENT_DIR> <AGENT_TYPE> [CLI_HOOKS_MODE]"
    echo "Example: $0 PG1.1.1 /path/to/agent/dir polling custom"
    echo "AGENT_TYPE: polling or event-driven"
    echo "CLI_HOOKS_MODE: auto (default), custom, or hybrid"
    exit 1
fi

AGENT_ID=$1
AGENT_DIR=$2
AGENT_TYPE=$3
CLI_HOOKS_MODE="${4:-auto}"  # 第4引数から取得、未指定時はauto

# プロジェクトルートを取得
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TEMPLATE_DIR="$PROJECT_ROOT/hooks/templates"

# hooksバージョンを読み込み（同階層の.hooks_version）
if [ -f "$SCRIPT_DIR/.hooks_version" ]; then
    HOOKS_VERSION=$(cat "$SCRIPT_DIR/.hooks_version")
else
    HOOKS_VERSION="v3"  # デフォルトv3
fi

echo "🔧 Setting up hooks for agent: $AGENT_ID (type: $AGENT_TYPE, version: $HOOKS_VERSION)"
echo "   CLI_HOOKS_MODE: $CLI_HOOKS_MODE"

# .claude/hooks ディレクトリ作成
mkdir -p "$AGENT_DIR/.claude/hooks"

# session_start.pyをコピー（全エージェント共通）
cp "$TEMPLATE_DIR/session_start.py" "$AGENT_DIR/.claude/hooks/"

# post_tool_ssh_handler.pyをコピー（PostToolUse SSH/SFTP支援）
cp "$TEMPLATE_DIR/post_tool_ssh_handler.py" "$AGENT_DIR/.claude/hooks/"

# agent_id.txtを作成
echo "$AGENT_ID" > "$AGENT_DIR/.claude/hooks/agent_id.txt"

# エージェントタイプに応じたstop hookをコピー
# v0.4以降：PGもポーリング型に変更（全エージェントがポーリング型）
# v0.5: SOLOエージェントもv3を使用（auto_tuning_config.json活用）

# CLI_HOOKS_MODE=customの場合は、hooksセクションのみ空にする
if [ "$CLI_HOOKS_MODE" = "custom" ]; then
    echo "   Custom hooks mode: hooks section will be empty"
    # stop.pyはコピーするが、settings.local.jsonには登録しない
    if [ "$AGENT_TYPE" = "polling" ] || [[ "$AGENT_ID" =~ ^PG ]] || [ "$AGENT_ID" = "SOLO" ]; then
        cp "$TEMPLATE_DIR/stop_polling_v3.py" "$AGENT_DIR/.claude/hooks/stop.py"
    else
        cp "$TEMPLATE_DIR/stop_event.py" "$AGENT_DIR/.claude/hooks/stop.py"
    fi

    # settings.local.jsonを空のhooksで作成（Claude起動前なので既存設定は存在しない）
    cat > "$AGENT_DIR/.claude/settings.local.json" << EOF
{
  "hooks": {}
}
EOF
    echo "✅ Custom hooks mode configured (hooks will be called by state monitor)"

elif [ "$AGENT_ID" = "SOLO" ]; then
    # SOLOもstop_polling_v3.pyを使用（SOLOの確率設定あり）
    cp "$TEMPLATE_DIR/stop_polling_v3.py" "$AGENT_DIR/.claude/hooks/stop.py"
    # settings.jsonを作成（SOLOも同じ構造）
    cat > "$AGENT_DIR/.claude/settings.local.json" << EOF
{
  "hooks": {
    "PostToolUse": [{
      "matcher": "mcp__desktop-commander__start_process|Bash",
      "hooks": [{
        "type": "command",
        "command": "python3 \"\$CLAUDE_PROJECT_DIR\"/.claude/hooks/post_tool_ssh_handler.py"
      }]
    }],
    "Stop": [{
      "hooks": [{
        "type": "command",
        "command": "python3 \"\$CLAUDE_PROJECT_DIR\"/.claude/hooks/stop.py"
      }]
    }],
    "SessionStart": [{
      "hooks": [{
        "type": "command",
        "command": "python3 \"\$CLAUDE_PROJECT_DIR\"/.claude/hooks/session_start.py"
      }]
    }]
  }
}
EOF
    echo "✅ SOLO agent hooks configured (using v3 with SOLO probabilities)"
elif [ "$AGENT_TYPE" = "polling" ] || [[ "$AGENT_ID" =~ ^PG ]]; then
    # hooksバージョンに応じてファイルを選択
    if [ "$HOOKS_VERSION" = "v2" ]; then
        cp "$TEMPLATE_DIR/stop_polling_v2.py" "$AGENT_DIR/.claude/hooks/stop.py"
    elif [ "$HOOKS_VERSION" = "v3" ]; then
        cp "$TEMPLATE_DIR/stop_polling_v3.py" "$AGENT_DIR/.claude/hooks/stop.py"
    else
        echo "⚠️ Unknown hooks version '$HOOKS_VERSION', using v3"
        cp "$TEMPLATE_DIR/stop_polling_v3.py" "$AGENT_DIR/.claude/hooks/stop.py"
    fi
    # settings.jsonを作成（絶対パスを使用）
    cat > "$AGENT_DIR/.claude/settings.local.json" << EOF
{
  "hooks": {
    "PostToolUse": [{
      "matcher": "mcp__desktop-commander__start_process|Bash",
      "hooks": [{
        "type": "command",
        "command": "python3 \"\$CLAUDE_PROJECT_DIR\"/.claude/hooks/post_tool_ssh_handler.py"
      }]
    }],
    "Stop": [{
      "hooks": [{
        "type": "command",
        "command": "python3 \"\$CLAUDE_PROJECT_DIR\"/.claude/hooks/stop.py"
      }]
    }],
    "SessionStart": [{
      "hooks": [{
        "type": "command",
        "command": "python3 \"\$CLAUDE_PROJECT_DIR\"/.claude/hooks/session_start.py"
      }]
    }]
  }
}
EOF
    echo "✅ Polling agent hooks configured with absolute paths"
else
    cp "$TEMPLATE_DIR/stop_event.py" "$AGENT_DIR/.claude/hooks/stop.py"
    # settings.jsonを作成（絶対パスを使用）
    cat > "$AGENT_DIR/.claude/settings.local.json" << EOF
{
  "hooks": {
    "PostToolUse": [{
      "matcher": "mcp__desktop-commander__start_process|Bash",
      "hooks": [{
        "type": "command",
        "command": "python3 \"\$CLAUDE_PROJECT_DIR\"/.claude/hooks/post_tool_ssh_handler.py"
      }]
    }],
    "Stop": [{
      "hooks": [{
        "type": "command",
        "command": "python3 \"\$CLAUDE_PROJECT_DIR\"/.claude/hooks/stop.py"
      }]
    }],
    "SessionStart": [{
      "hooks": [{
        "type": "command",
        "command": "python3 \"\$CLAUDE_PROJECT_DIR\"/.claude/hooks/session_start.py"
      }]
    }]
  }
}
EOF
    echo "✅ Event-driven agent hooks configured with absolute paths"
fi

# 実行権限を付与
chmod +x "$AGENT_DIR/.claude/hooks/"*.py

# stop_count.txtを初期化（0から開始）
echo "0" > "$AGENT_DIR/.claude/hooks/stop_count.txt"

echo "✅ Hooks setup completed for $AGENT_ID at $AGENT_DIR"