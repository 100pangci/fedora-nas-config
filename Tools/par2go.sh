#!/bin/bash

# 1. 检查是否安装了 par2
if ! command -v par2 &> /dev/null; then
    echo "❌ 错误: 未检测到 par2 命令。请先安装 par2cmdline-turbo。"
    echo "安装命令: sudo dnf copr enable errornointernet/par2cmdline-turbo -y && sudo dnf install par2cmdline-turbo -y"
    exit 1
fi

# 2. 获取目标文件路径
FILE_PATH="$1"
if [ -z "$FILE_PATH" ]; then
    read -e -p "请输入或拖入文件绝对路径: " FILE_PATH
fi

# 转换成绝对路径并去除潜在的引号/空格问题
FILE_PATH=$(realpath "$FILE_PATH" 2>/dev/null)

if [ ! -e "$FILE_PATH" ]; then
    echo "❌ 错误: 找不到该文件 -> $FILE_PATH"
    exit 1
fi

# 3. 核心变量解析
DIR_NAME=$(dirname "$FILE_PATH")
BASE_NAME=$(basename "$FILE_PATH")
BASE_NO_EXT="${BASE_NAME%.*}" # 去掉后缀的文件名

ACTION=""
PAR2_FILE=""
DATA_FILE=""
REDUNDANCY=10 # 默认冗余度 10%，可以根据需要修改此数值

# 4. 智能判断逻辑
if [[ "$FILE_PATH" == *.par2 ]]; then
    # 情况 A：用户直接传入了 .par2 文件 -> 执行修复
    ACTION="REPAIR"
    PAR2_FILE="$FILE_PATH"
else
    # 情况 B：用户传入的是普通数据文件 (如 .hc, .tar.gz)
    DATA_FILE="$FILE_PATH"
    POSSIBLE_PAR2="${DIR_NAME}/${BASE_NO_EXT}.par2"

    if [ -f "$POSSIBLE_PAR2" ]; then
        # 如果同目录下已经存在对应的 .par2 校验包
        echo "🔍 检测到该文件在同目录下已存在校验包。"
        # 5秒无操作默认选择 [R] 修复
        read -t 5 -p "🔑 请选择操作 [R]修复原文件 / [C]重新生成校验包 (5秒无操作默认: R): " CHOICE
        CHOICE=$(echo "$CHOICE" | tr '[:lower:]' '[:upper:]')
        
        if [ "$CHOICE" == "C" ]; then
            ACTION="CREATE"
            PAR2_FILE="$POSSIBLE_PAR2"
        else
            ACTION="REPAIR"
            PAR2_FILE="$POSSIBLE_PAR2"
        fi
    else
        # 如果同目录下没有对应的 .par2 校验包 -> 执行创建
        ACTION="CREATE"
        PAR2_FILE="$POSSIBLE_PAR2"
    fi
fi

# 5. 确定日志文件路径
if [ "$ACTION" == "CREATE" ]; then
    LOG_FILE="${DIR_NAME}/${BASE_NO_EXT}_create.log"
else
    LOG_FILE="${DIR_NAME}/${BASE_NO_EXT}_repair.log"
fi

# 6. 打印任务预览
echo "============================================"
echo "📂 目标文件: $FILE_PATH"
echo "⚙️  自动判定: [ $ACTION ]"
if [ "$ACTION" == "CREATE" ]; then
    echo "📊 冗余比例: ${REDUNDANCY}%"
    echo "💾 校验文件: $PAR2_FILE"
else
    echo "🛠️  使用校验: $PAR2_FILE"
fi
echo "📝 进度日志: $LOG_FILE"
echo "============================================"

# 7. 后台挂起执行 (nohup)
if [ "$ACTION" == "CREATE" ]; then
    nohup par2 create -r${REDUNDANCY} "$PAR2_FILE" "$DATA_FILE" > "$LOG_FILE" 2>&1 &
else
    nohup par2 repair "$PAR2_FILE" > "$LOG_FILE" 2>&1 &
fi

PID=$!

echo "🚀 任务已在后台挂起！(PID: $PID)"
echo "💡 提示：按 [Ctrl + C] 可随时退出日志监控，后台任务【不会】停止。"
echo "👉 5秒后将自动为您跟踪进度日志..."
echo "--------------------------------------------"
sleep 5

# 8. 自动打印进度
tail -f "$LOG_FILE"
