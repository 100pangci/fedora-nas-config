#!/bin/bash

# 1. 确定 BaiduPCS-Go 路径 (使用您 alias 里的绝对路径)
PCS_BIN="/home/ywpc/Software/BaiduPCS-Go/BaiduPCS-Go"
if [ ! -f "$PCS_BIN" ]; then
    echo "❌ 错误: 未在 $PCS_BIN 找到 BaiduPCS-Go 可执行文件。"
    exit 1
fi

# 2. 获取本地文件/目录路径
LOCAL_PATH="$1"
if [ -z "$LOCAL_PATH" ]; then
    read -e -p "请输入或拖入本地文件/目录路径: " LOCAL_PATH
fi

# 转换为绝对路径
LOCAL_PATH=$(realpath "$LOCAL_PATH" 2>/dev/null)

if [ ! -e "$LOCAL_PATH" ]; then
    echo "❌ 错误: 本地找不到该文件或目录 -> $LOCAL_PATH"
    exit 1
fi

# 3. 解析路径与日期
DIR_NAME=$(dirname "$LOCAL_PATH")
BASE_NAME=$(basename "$LOCAL_PATH")
BASE_NO_EXT="${BASE_NAME%.*}"    # 文件名（去掉后缀，如 Vault-1）
CURRENT_DATE=$(date +%Y%m%d)     # 当前日期（如 20260629）

# 4. 智能判断/生成网盘远程路径
REMOTE_PATH="$2"
if [ -z "$REMOTE_PATH" ]; then
    # 自动生成您习惯的默认规则路径
    DEFAULT_REMOTE="/我的全盘备份/Temp/${BASE_NO_EXT}/${CURRENT_DATE}"
    
    echo "💡 检测到未手动输入网盘路径，已根据您的习惯生成默认路径："
    echo "👉 $DEFAULT_REMOTE"
    read -e -p "请输入网盘目标目录 (直接回车即使用上方默认路径): " INPUT_REMOTE
    
    if [ -z "$INPUT_REMOTE" ]; then
        REMOTE_PATH="$DEFAULT_REMOTE"
    else
        REMOTE_PATH="$INPUT_REMOTE"
    fi
fi

# 5. 确定日志文件路径 (放在本地文件同目录下，命名为: 文件名_upload.log)
LOG_FILE="${DIR_NAME}/${BASE_NO_EXT}_upload.log"

# 6. 任务预览
echo "============================================"
echo "📂 本地路径: $LOCAL_PATH"
echo "☁️  网盘路径: $REMOTE_PATH"
echo "📝 进度日志: $LOG_FILE"
echo "============================================"

# 7. 后台静默挂起执行 (nohup)
nohup "$PCS_BIN" upload "$LOCAL_PATH" "$REMOTE_PATH" > "$LOG_FILE" 2>&1 &
PID=$!

echo "🚀 上传任务已在后台挂起！(PID: $PID)"
echo "💡 提示：按 [Ctrl + C] 可随时退出日志监控，后台上传【不会】停止。"
echo "👉 5秒后将自动为您跟踪上传进度..."
echo "--------------------------------------------"
sleep 5

# 8. 自动跟踪日志进度
tail -f "$LOG_FILE"
