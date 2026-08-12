#!/bin/bash
# XFS reflink 快照:写时复制,瞬间完成、零空间占用(修改源后快照保持原状)
# 要求: 快照与源必须同一文件系统(reflink 特性限制)
# 用法: sudo ./reflink_snapshot.sh <源路径> [快照位置(可选)]
#   快照位置省略时: 源同级目录下 <源名>.snapshot_<时间戳>
#   快照位置为已存在目录时: 在其下创建 <源名>.snapshot_<时间戳>
# 恢复: sudo rm -rf '<源路径>' && sudo mv '<快照>' '<源路径>'

if [ -z "$1" ]; then
    echo "=================================================="
    echo " 用法: sudo ./reflink_snapshot.sh <源路径> [快照位置]"
    echo "=================================================="
    echo ""
    echo " 示例:"
    echo "   sudo ./reflink_snapshot.sh /home/ywpc/Podman/minecraft/1.21.1-Fabric-0.19.2/data"
    echo "   sudo ./reflink_snapshot.sh /mnt/New-1/某目录 /mnt/New-1/快照区"
    echo ""
    echo " 说明:"
    echo "   - XFS reflink 快照,复制瞬间完成、基本不占空间(CoW)"
    echo "   - 修改源文件后,快照仍保持复制那一刻的完整状态"
    echo "   - 必须与源在同一文件系统,跨盘会拒绝"
    echo "   - 建议 sudo 运行(源文件可能属主 525287 等,普通用户读不了)"
    echo "   - 恢复: sudo rm -rf '<源>' && sudo mv '<快照>' '<源>'"
    echo "=================================================="
    exit 1
fi

SRC="$1"
if [ ! -e "$SRC" ]; then
    echo "错误: 源路径 '$SRC' 不存在"
    exit 1
fi

SRC_ABS=$(realpath "$SRC")
SRC_NAME=$(basename "$SRC_ABS")
SRC_PARENT=$(dirname "$SRC_ABS")
TS=$(date "+%Y%m%d_%H%M%S")

if [ -n "$2" ]; then
    if [ -d "$2" ]; then
        SNAP="$2/${SRC_NAME}.snapshot_${TS}"
    else
        SNAP="$2"
    fi
else
    SNAP="$SRC_PARENT/${SRC_NAME}.snapshot_${TS}"
fi

SRC_DEV=$(stat -c %d "$SRC_ABS")
SNAP_PARENT=$(dirname "$SNAP")
if ! mkdir -p "$SNAP_PARENT" 2>/dev/null; then
    echo "错误: 无法创建快照目录 '$SNAP_PARENT'(权限不够?试试 sudo)"
    exit 1
fi
SNAP_DEV=$(stat -c %d "$SNAP_PARENT")
if [ "$SRC_DEV" != "$SNAP_DEV" ]; then
    echo "错误: 快照与源不在同一文件系统(XFS reflink 要求同盘),已退出"
    echo "      源: $SRC_ABS"
    echo "      快照目录: $SNAP_PARENT"
    exit 1
fi

if [ -e "$SNAP" ]; then
    echo "错误: 快照位置已存在,拒绝覆盖: $SNAP"
    exit 1
fi

echo "创建 reflink 快照(CoW,零空间占用)..."
echo "  源:  $SRC_ABS"
echo "  快照: $SNAP"
if ! cp -a --reflink=auto "$SRC_ABS" "$SNAP"; then
    echo "错误: 快照创建失败(权限不够?试试 sudo)"
    rm -rf "$SNAP"
    exit 1
fi

echo ""
echo "=================================================="
echo " ✅ 快照完成: $SNAP"
echo "    恢复: sudo rm -rf '$SRC_ABS' && sudo mv '$SNAP' '$SRC_ABS'"
echo "    提示: 修改源时快照保持原状;确认无误后可删除快照释放空间"
echo "=================================================="
