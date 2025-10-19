#!/bin/bash
# シングルエージェント起動用統合スクリプト
# 1つのClaude Codeインスタンスが全ての役割（PM/SE/PG/CD）を実行

set -e

# スクリプトのディレクトリからプロジェクトルートを取得
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

echo "🚀 VibeCodeHPC シングルエージェントモード起動"
echo "============================================"

# tmuxの確認（オプション）
TMUX_AVAILABLE=false
if command -v tmux &>/dev/null; then
    TMUX_AVAILABLE=true
    if [ -n "$TMUX_PANE" ]; then
        echo "✅ tmux環境で実行中: $TMUX_PANE"
    else
        echo "⚠️  tmux内で実行されていません。"
        echo "   推奨: tmux attach-session -t Team1_PM"
    fi
else
    echo "⚠️  tmuxが未インストール。非tmuxモードで動作します。"
    echo "   tmuxのインストールを推奨します。詳細はREADME.mdを参照。"
fi

# 1. SOLO用のhooks設定（VIBECODE_ENABLE_HOOKSがfalseでない限り有効）
if [ "${VIBECODE_ENABLE_HOOKS}" != "false" ]; then
    # CLI_HOOKS_MODEを取得（デフォルト: auto）
    CLI_HOOKS_MODE="${CLI_HOOKS_MODE:-auto}"
    echo "🔧 Setting up hooks for SOLO agent..."
    echo "   CLI_HOOKS_MODE: $CLI_HOOKS_MODE"
    if [ -f "$PROJECT_ROOT/hooks/setup_agent_hooks.sh" ]; then
        # SOLOはポーリング型として設定
        "$PROJECT_ROOT/hooks/setup_agent_hooks.sh" SOLO "$PROJECT_ROOT" polling "$CLI_HOOKS_MODE"
    else
        echo "⚠️  Warning: hooks setup script not found"
    fi
else
    echo "⚠️  Hooks disabled by VIBECODE_ENABLE_HOOKS=false"
fi

# 2. プロジェクト開始時刻を記録
START_TIME_FILE="$PROJECT_ROOT/Agent-shared/project_start_time.txt"
if [ ! -f "$START_TIME_FILE" ] || [ ! -s "$START_TIME_FILE" ]; then
    echo "📅 Recording project start time..."
    mkdir -p "$PROJECT_ROOT/Agent-shared"
    date -u +"%Y-%m-%dT%H:%M:%SZ" > "$START_TIME_FILE"
fi

# 3. agent_and_pane_id_table.jsonlのSOLOエントリを更新
if command -v jq &> /dev/null; then
    TABLE_FILE="$PROJECT_ROOT/Agent-shared/agent_and_pane_id_table.jsonl"
    if [ -f "$TABLE_FILE" ]; then
        echo "📝 Updating working_dir for SOLO..."
        TEMP_FILE="$TABLE_FILE.tmp"
        while IFS= read -r line; do
            if [[ -z "$line" || "$line" =~ ^# ]]; then
                echo "$line"
            else
                updated_line=$(echo "$line" | jq -c '
                    if .agent_id == "SOLO" then
                        . + {working_dir: "", last_updated: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))}
                    else
                        .
                    end
                ')
                echo "$updated_line"
            fi
        done < "$TABLE_FILE" > "$TEMP_FILE"
        mv "$TEMP_FILE" "$TABLE_FILE"
        echo "✅ Updated SOLO working_dir"
    fi
fi

# 4. stop_thresholds.jsonにSOLO用設定を追加（存在しない場合）
THRESHOLDS_FILE="$PROJECT_ROOT/Agent-shared/stop_thresholds.json"
if [ -f "$THRESHOLDS_FILE" ] && command -v jq &> /dev/null; then
    if ! jq '.thresholds | has("SOLO")' "$THRESHOLDS_FILE" | grep -q true; then
        echo "📝 Adding SOLO threshold to stop_thresholds.json..."
        TEMP_FILE="$THRESHOLDS_FILE.tmp"
        jq '.thresholds.SOLO = 100' "$THRESHOLDS_FILE" > "$TEMP_FILE"
        mv "$TEMP_FILE" "$THRESHOLDS_FILE"
        echo "✅ Added SOLO threshold (100 stops)"
    fi
fi

# 5. MCP（Desktop Commander）を設定
echo "🔧 Setting up MCP for SOLO agent..."
claude mcp add desktop-commander -- npx -y @wonderwhy-er/desktop-commander 2>/dev/null || {
    echo "⚠️  MCP設定をスキップ（既に設定済みまたはエラー）"
}

# 6. Claude起動
echo ""
echo "起動後、以下のプロンプトをコピーして貼り付けてください："
echo "================================================================"
cat << 'EOF'
あなたはVibeCodeHPCのシングルエージェントモードで動作します。
全ての役割（PM/SE/PG/CD）を1人で担当し、効率的にプロジェクトを進めます。

【初期設定】
まず以下のファイルを読み込んでください：
- CLAUDE.md（全エージェント共通ルール）
- instructions/SOLO.md（シングルモード専用の統合プロンプト）
- requirement_definition.md（存在する場合）
- Agent-shared/project_start_time.txt（プロジェクト開始時刻）

【ToDoリストによる役割管理】
TodoWriteツールを積極的に使用し、各タスクに役割タグ（[PM], [SE], [PG], [CD]）を付けて管理してください。

【時間管理】
- プロジェクト開始時刻から経過時間を定期的に確認
- requirement_definition.mdに時間制限がある場合は厳守
- 予算管理と並行して時間効率も意識

【効率的な実行順序】
1. [PM] 要件定義と環境調査
2. [SE] 環境構築
3. [PG] 実装とテスト（ループ）
4. [SE] 統計・可視化
5. [CD] GitHub同期（必要時）
6. [PM] 最終報告

agent_send.shは使用不要です（通信相手がいないため）。
全ての処理を内部で完結させてください。

プロジェクトを開始してください。
EOF
echo "================================================================"
echo ""

# テレメトリ設定に基づいてClaude起動
if [ "${VIBECODE_ENABLE_TELEMETRY}" = "false" ]; then
    echo "📊 Telemetry disabled - starting SOLO without telemetry"
    exec DISABLE_AUTOUPDATER=1 claude --dangerously-skip-permissions "$@"
else
    echo "📊 Telemetry enabled - starting SOLO with telemetry"
    exec "$PROJECT_ROOT/telemetry/launch_claude_with_env.sh" SOLO "$@"
fi