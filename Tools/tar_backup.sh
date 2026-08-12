#!/bin/bash
# 通用 tar 打包备份(保留权限与用户组),不限 MC
# 用法: ./tar_backup.sh <源路径> [目标目录]
# 源路径必填(文件或目录);目标目录可选,默认 /mnt/SSD-Cache/Backups
# 还原: sudo tar -xzpof <包名> -C <目标父目录>

if [ -z "$1" ]; then
    echo "=================================================="
    echo " 用法: ./tar_backup.sh <源路径> [目标目录]"
    echo "=================================================="
    echo ""
    echo " 示例:"
    echo "   ./tar_backup.sh ~/Podman/minecraft/1.21.1-Fabric-0.19.2/data"
    echo "   ./tar_backup.sh ~/Podman/minecraft/1.21.1-Fabric-0.19.2/data /mnt/New-2"
    echo "   ./tar_backup.sh /mnt/Old-1/某目录 /mnt/New-1/备份"
    echo ""
    echo " 说明:"
    echo "   - 通用打包备份工具,任意文件/目录均可"
    echo "   - tar -czpf 打包,保留文件权限与属主"
    echo "   - 目标目录默认: /mnt/SSD-Cache/Backups"
    echo "   - 还原命令: sudo tar -xzpof <包名> -C <目标父目录>"
    echo "   - 打包完成后自动校验条目数"
    echo "=================================================="
    exit 1
fi

SRC="$1"
DEST="${2:-/mnt/SSD-Cache/Backups}"

if [ ! -e "$SRC" ]; then
    echo "错误: 源路径 '$SRC' 不存在"
    exit 1
fi

mkdir -p "$DEST" || { echo "错误: 无法创建目标目录 '$DEST'"; exit 1; }

SRC_ABS=$(realpath "$SRC")
SRC_NAME=$(basename "$SRC_ABS")
SRC_PARENT=$(dirname "$SRC_ABS")
TS=$(date "+%Y%m%d_%H%M%S")
OUT="$DEST/backup_${SRC_NAME}_${TS}.tar.gz"

echo "打包中: $SRC_ABS"
echo "输出到: $OUT"
tar -czpf "$OUT" --warning=no-file-changed -C "$SRC_PARENT" "$SRC_NAME" || { echo "错误: 打包失败"; exit 1; }

COUNT=$(tar -tzf "$OUT" 2>/dev/null | wc -l)
SIZE=$(du -h "$OUT" | cut -f1)

echo "=================================================="
echo " ✅ 备份完成: $OUT"
echo "    大小: $SIZE,条目数: $COUNT"
echo "    还原: sudo tar -xzpof '$OUT' -C '$SRC_PARENT'"
echo "=================================================="
