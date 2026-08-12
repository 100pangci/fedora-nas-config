#!/bin/zsh
# ================= 配置区 =================
# 用于主动刷新 SMB 缓存的本地账号和密码（请填写你的 Linux 账户密码）
SMB_USER="ywpc"
SMB_PASS="<REDACTED-填实际账户密码>"
# 缓存目录：在高速 SSD 上进行解压，解压完成后再移动到目标目录
CACHE_BASE_DIR="/mnt/SSD-Cache/U-A-Temp"
# ==========================================

# 确保是在 Zsh 环境下运行
if [ -z "$ZSH_VERSION" ]; then
    exec zsh "$0" "$@"
fi
# 开启扩展通配符、非精准匹配（防止 glob 找不到文件时崩溃）
setopt localoptions no_bang_hist extendedglob nonomatch

# 1. 获取输入路径
SRC_PATH="$1"
if [[ -z "$SRC_PATH" ]]; then
    echo "=================================================="
    echo " 💡 提示：强烈推荐在路径开头加单引号 ' 再按 TAB 补全，如："
    echo "        ./rar_background_unpacker.sh '/mnt/Old-1/Video/[TAB...'"
    echo "=================================================="
    # 初始化 Zsh 原生补全
    autoload -Uz compinit && compinit -u >/dev/null 2>&1
    zstyle ':completion::vared::*' completer _files
    bindkey '^I' expand-or-complete
    
    vared -p "请输入要解压的 RAR/ZIP/7Z 文件或目录路径: " SRC_PATH || exit 1
    echo ""
fi

# 【完美路径解析器】
SRC_PATH="${SRC_PATH#\"}"
SRC_PATH="${SRC_PATH%\"}"
SRC_PATH="${SRC_PATH#\'}"
SRC_PATH="${SRC_PATH%\'}"
if [[ "$SRC_PATH" =~ '^[a-zA-Z]:' || ( "$SRC_PATH" == *'\'* && "$SRC_PATH" != */* ) ]]; then
    SRC_PATH="${SRC_PATH//\\//}"
else
    SRC_PATH="${(Q)SRC_PATH}"
fi

# 转换源路径为绝对路径
if [[ -e "$SRC_PATH" ]]; then
    SRC_PATH=$(realpath "$SRC_PATH")
else
    echo "错误: 路径 '$SRC_PATH' 不存在，请重新运行脚本。"
    exit 1
fi

# 确保缓存主目录存在
if ! mkdir -p "$CACHE_BASE_DIR" 2>/dev/null; then
    echo "错误: 无法创建或访问缓存目录 '$CACHE_BASE_DIR'，请检查权限。"
    exit 1
fi

# 2. 扫描并筛选需要解压的目标文件
local -a archives
local is_batch=0

if [[ -d "$SRC_PATH" ]]; then
    is_batch=1
    echo "🔍 正在扫描目录中的压缩包..."
    for f in "$SRC_PATH"/**/*.(#i)(rar|zip|7z)(.); do
        if [[ "$f" =~ '\.[pP][aA][rR][tT]([0-9]+)\.[rR][aA][rR]$' ]]; then
            local vol_num="${match[1]}"
            if (( $((10#$vol_num)) != 1 )); then
                continue 
            fi
        fi
        archives+=("$f")
    done
    
    if (( ${#archives} == 0 )); then
        echo "提示: 未在目录中找到任何支持的压缩包 (.rar, .zip, .7z)。"
        exit 0
    fi
    echo "📂 扫描完成！共发现 ${#archives} 个待解压压缩包。"
else
    if [[ "$SRC_PATH" =~ \.part[0-9]+\.rar$ ]]; then
        FIRST_PART=$(echo "$SRC_PATH" | sed -E 's/\.part[0-9]+\.rar$/.part1.rar/')
        if [[ "$SRC_PATH" != "$FIRST_PART" ]]; then
            echo "提示: 检测到分卷文件，已自动切换到第一卷: $FIRST_PART"
            SRC_PATH="$FIRST_PART"
        fi
    fi
    archives+=("$SRC_PATH")
fi

# 3. 安全获取解压密码
PASSWORD=""
read -s -r "PASSWORD?请输入解压密码 (若无统一密码或不确定，请直接回车): "
echo ""

# 4. 询问是否在成功解压后删除源文件（按单键瞬间触发，无需回车）
DELETE_CONFIRM=""
read -k 1 -r "DELETE_CONFIRM?是否在解压成功后自动删除源压缩包？(y/N): "
echo "" # 换行

# 5. 决定日志存放路径
local PARENT_DIR BASENAME LOG_FILE
if (( is_batch )); then
    PARENT_DIR="$SRC_PATH"
    LOG_DIR="$PARENT_DIR/unrar_logs"
    mkdir -p "$LOG_DIR"
    TIMESTAMP=$(date "+%Y%m%d_%H%M%S")
    LOG_FILE="$LOG_DIR/batch_unrar_${TIMESTAMP}.log"
else
    PARENT_DIR=$(dirname "$SRC_PATH")
    BASENAME=$(basename "$SRC_PATH")
    DIRNAME=$(echo "$BASENAME" | sed -E 's/\.part[0-9]+\.rar$//I' | sed -E 's/\.(rar|zip|7z)$//I')
    LOG_DIR="$PARENT_DIR/unrar_logs"
    mkdir -p "$LOG_DIR"
    TIMESTAMP=$(date "+%Y%m%d_%H%M%S")
    LOG_FILE="$LOG_DIR/${DIRNAME}_unrar_${TIMESTAMP}.log"
fi

# 6. 解析 Samba 共享名
local SMB_SHARE=""
if [[ "$PARENT_DIR" =~ ^/mnt/([^/]+) ]]; then
    SMB_SHARE="${match[1]}"
fi

# 7. 启动原生后台子进程
(
    echo "=================================================="
    echo " 🚀 任务启动时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo " 共需处理压缩包数量: ${#archives}"
    echo " 缓存工作目录: $CACHE_BASE_DIR"
    echo " 成功后自动删除源文件: $DELETE_CONFIRM"
    echo "=================================================="
    echo ""

    local count=1
    local success_count=0
    local skip_count=0

    for archive_file in $archives; do
        local archive_dir=$(dirname "$archive_file")
        local archive_name=$(basename "$archive_file")
        
        # 智能清洗后缀，生成目标解压文件夹
        local target_name=$(echo "$archive_name" | sed -E 's/\.part[0-9]+\.rar$//I' | sed -E 's/\.(rar|zip|7z)$//I')
        local extract_target_dir="$archive_dir/$target_name"
        
        # 在高速 SSD 缓存区建立以当前 Shell PID 命名的临时文件夹，防止多任务重名冲突
        local temp_extract_dir="$CACHE_BASE_DIR/${target_name}_tmp_$$"
        
        # 识别后缀
        local ext="${archive_file##*.}"
        ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

        # 创建 SSD 临时缓存目录
        mkdir -p "$temp_extract_dir"

        # 组装解压命令（解压到 SSD 缓存区）
        local decompress_cmd=""
        if [[ "$ext" == "rar" ]]; then
            if [[ -z "$PASSWORD" ]]; then
                decompress_cmd="unrar x -p- -o+ -y \"$archive_file\" \"$temp_extract_dir/\""
            else
                decompress_cmd="unrar x -p\"$PASSWORD\" -o+ -y \"$archive_file\" \"$temp_extract_dir/\""
            fi
        elif [[ "$ext" == "zip" || "$ext" == "7z" ]]; then
            if ! command -v 7z >/dev/null 2>&1; then
                echo "[错误] 找不到 7z 工具，跳过: $archive_name"
                rm -rf "$temp_extract_dir"
                continue
            fi
            if [[ -z "$PASSWORD" ]]; then
                decompress_cmd="7z x -y -p- \"$archive_file\" -o\"$temp_extract_dir/\""
            else
                decompress_cmd="7z x -y -p\"$PASSWORD\" \"$archive_file\" -o\"$temp_extract_dir/\""
            fi
        fi

        echo "--------------------------------------------------"
        echo "[$count/${#archives}] 正在解压 (SSD 缓存): $archive_name"
        echo "暂存目录: $temp_extract_dir"
        echo "最终目录: $extract_target_dir"
        echo "--------------------------------------------------"
        
        eval "$decompress_cmd"
        local exit_status=$?

        if (( exit_status == 0 )); then
            echo "⚡ [成功] 解压完成，开始归档至目标路径..."
            
            # 安全归档：如果目标已存在同名目录，先清理掉，防止 mv 嵌套
            if [[ -d "$extract_target_dir" ]]; then
                echo "⚠️ 检测到目标目录已存在，正在覆盖式清理..."
                rm -rf "$extract_target_dir"
            fi
            
            mkdir -p "$(dirname "$extract_target_dir")"
            if mv "$temp_extract_dir" "$extract_target_dir"; then
                echo "🚚 [归档] 成功移至最终存储介质！"
                success_count=$((success_count+1))
            else
                echo "❌ [严重错误] 无法将解压结果从高速缓存移动到 '$extract_target_dir'（可能磁盘空间不足）"
                rm -rf "$temp_extract_dir"
                skip_count=$((skip_count+1))
                continue
            fi
            
            # 【安全销毁源文件】
            if [[ "$DELETE_CONFIRM" =~ ^[yY]$ ]]; then
                if [[ "$archive_file" =~ '(\.[pP][aA][rR][tT]0*1\.[rR][aA][rR])$' ]]; then
                    local base_pattern="${archive_file%${match[1]}}"
                    echo "🧹 [销毁] 检测到分卷，正在清理该整套分卷压缩包..."
                    rm -f "${base_pattern}".[pP][aA][rR][tT][0-9]*.[rR][aA][rR]
                else
                    echo "🧹 [销毁] 正在删除源压缩包: $archive_name"
                    rm -f "$archive_file"
                fi
            fi
            
            # 【双通道实时音速刷新 SMB 缓存】
            touch "$archive_dir/.smb_refresh" && rm "$archive_dir/.smb_refresh"
            
            if [[ -n "$SMB_SHARE" ]] && command -v smbclient >/dev/null 2>&1; then
                local current_subdir=""
                if [[ "$archive_dir" =~ ^/mnt/[^/]+(.*)$ ]]; then
                    current_subdir="${match[1]}"
                    current_subdir="${current_subdir#/}"
                fi
                
                local -a smb_cmds
                if [[ -n "$current_subdir" ]]; then
                    smb_cmds+=("cd \"$current_subdir\"")
                fi
                smb_cmds+=(
                    "mkdir .smb_refresh_dir"
                    "rmdir .smb_refresh_dir"
                )
                print -l "${smb_cmds[@]}" | smbclient "//127.0.0.1/$SMB_SHARE" -U "$SMB_USER%$SMB_PASS" >/dev/null 2>&1
            fi
            
        else
            echo "❌ [失败/跳过] $archive_name (错误码: $exit_status，可能是密码错误或坏包)"
            # 解压失败，彻底清除 SSD 残留的临时文件夹，绝不破坏源文件
            rm -rf "$temp_extract_dir"
            skip_count=$((skip_count+1))
        fi

        echo ""
        count=$((count+1))
    done

    echo "=================================================="
    echo " 🎉 批量任务全部完成！"
    echo " 成功解压: $success_count"
    echo " 失败跳过: $skip_count"
    echo " 结束时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "=================================================="
) > "$LOG_FILE" 2>&1 &

PID=$!
disown

# 8. 提示用户
echo "=================================================="
echo " 🚀 后台高速批量解压任务已成功提交！"
echo "=================================================="
echo " 扫描目标: $SRC_PATH"
echo " 缓存路径: $CACHE_BASE_DIR"
echo " 待处理数: ${#archives} 个"
echo " 自动删除: $( [[ "$DELETE_CONFIRM" =~ ^[yY]$ ]] && echo "是" || echo "否" )"
echo " 后台 PID: $PID"
echo " 日志文件: $LOG_FILE"
echo "--------------------------------------------------"
echo " 此时您可以安全地关闭 SSH 窗口，任务绝对不会中断。"
echo ""
echo " 想要【实时监控每个包的解压进度和销毁状态】，请运行："
echo " tail -f \"$LOG_FILE\""
echo "=================================================="
