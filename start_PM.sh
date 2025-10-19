#!/bin/bash
# PM起動用統合スクリプト
# hooks設定とtelemetry起動を自動化

set -e

# スクリプトのディレクトリからプロジェクトルートを取得
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

echo "🎯 VibeCodeHPC PM起動スクリプト"
echo "================================"

# 1. PM用のhooks設定（VIBECODE_ENABLE_HOOKSがfalseでない限り有効）
if [ "${VIBECODE_ENABLE_HOOKS}" != "false" ]; then
    # CLI_HOOKS_MODEを取得（デフォルト: auto）
    CLI_HOOKS_MODE="${CLI_HOOKS_MODE:-auto}"
    echo "🔧 Setting up hooks for PM..."
    echo "   CLI_HOOKS_MODE: $CLI_HOOKS_MODE"
    if [ -f "$PROJECT_ROOT/hooks/setup_agent_hooks.sh" ]; then
        "$PROJECT_ROOT/hooks/setup_agent_hooks.sh" PM "$PROJECT_ROOT" polling "$CLI_HOOKS_MODE"
    else
        echo "⚠️  Warning: hooks setup script not found"
    fi
else
    echo "⚠️  Hooks disabled by VIBECODE_ENABLE_HOOKS=false"
fi

# 1.5. TMUX_PANE環境変数の確認と記録
echo "🔍 Checking TMUX environment..."
if [ -n "$TMUX_PANE" ]; then
    echo "  TMUX_PANE: $TMUX_PANE"
    # settings.local.jsonに環境変数を追加（Claude Codeに引き継がれない可能性への対策）
    if [ -f "$PROJECT_ROOT/.claude/settings.local.json" ]; then
        echo "  ⚠️  Note: Claude Code may not inherit TMUX_PANE environment variable"
    fi
else
    echo "  ⚠️  Warning: Not running in tmux pane"
fi

# 2. プロジェクト開始時刻を記録（hooksが動作しない場合の保険）
START_TIME_FILE="$PROJECT_ROOT/Agent-shared/project_start_time.txt"
if [ ! -f "$START_TIME_FILE" ] || [ ! -s "$START_TIME_FILE" ]; then
    echo "📅 Recording project start time..."
    mkdir -p "$PROJECT_ROOT/Agent-shared"
    date -u +"%Y-%m-%dT%H:%M:%SZ" > "$START_TIME_FILE"
fi

# 2.5. PMのworking_dirを更新（プロジェクトルート = 空文字列）
if command -v jq &> /dev/null; then
    TABLE_FILE="$PROJECT_ROOT/Agent-shared/agent_and_pane_id_table.jsonl"
    if [ -f "$TABLE_FILE" ]; then
        echo "📝 Updating working_dir for PM..."
        TEMP_FILE="$TABLE_FILE.tmp"
        while IFS= read -r line; do
            if [[ -z "$line" || "$line" =~ ^# ]]; then
                echo "$line"
            else
                # JSONとして解析して、PMの場合はworking_dirを更新
                updated_line=$(echo "$line" | jq -c '
                    if .agent_id == "PM" then
                        . + {working_dir: "", last_updated: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))}
                    else
                        .
                    end
                ')
                echo "$updated_line"
            fi
        done < "$TABLE_FILE" > "$TEMP_FILE"
        mv "$TEMP_FILE" "$TABLE_FILE"
        echo "✅ Updated PM working_dir"
    fi
fi

# 3. Claude起動
echo ""
echo "起動後、以下のプロンプトをコピーして貼り付けてください："
echo "================================================================"
cat << 'EOF'
あなたはPM（Project Manager）です。VibeCodeHPCプロジェクトを開始します。

まず以下のファイルを読み込んでプロジェクトの全体像を把握してください：
- CLAUDE.md（全エージェント共通ルール）
- instructions/PM.md（あなたの役割詳細）
- requirement_definition.md（プロジェクト要件）※存在する場合
- Agent-shared/以下の全ての.mdと.txtファイル（ただし、.pyファイル、_template、_exampleを除く）

特に重要：
- max_agent_number.txt（利用可能なワーカー数）
- agent_and_pane_id_table.jsonl（セッション構成とエージェント管理）
- directory_pane_map.txt（エージェント配置とペイン管理）
- sota_management.md（SOTA管理方法とfamilyの重要性）

全て読み込んだ後、該当する既存の tmux セッションを活用してプロジェクトを初期化してください。新規セッションは作成しないでください。
EOF
echo "================================================================"
echo ""

# テレメトリ設定に基づいてClaude起動
if [ "${VIBECODE_ENABLE_TELEMETRY}" = "false" ]; then
    echo "📊 Telemetry disabled - starting PM without telemetry"
    exec env DISABLE_AUTOUPDATER=1 claude --dangerously-skip-permissions "$@"
else
    echo "📊 Telemetry enabled - starting PM with telemetry"
    exec "$PROJECT_ROOT/telemetry/launch_claude_with_env.sh" PM "$@"
fi