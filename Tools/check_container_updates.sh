#!/bin/bash
# 一键检查并自动重建所有 rootless 容器镜像更新(带代理)
# 排除: mc-fabric-server
# 流程: 代理预检 -> 遍历容器 -> pull 新镜像 -> 对比 Image ID -> compose up -d

set -o pipefail

# 1. 代理配置
PROXY_URL="http://127.0.0.1:1145"
export HTTP_PROXY="$PROXY_URL"
export HTTPS_PROXY="$PROXY_URL"
export http_proxy="$PROXY_URL"
export https_proxy="$PROXY_URL"
export NO_PROXY="localhost,127.0.0.1"
export no_proxy="localhost,127.0.0.1"

# 排除配置
EXCLUDE_NAMES=("mc-fabric-server")
FIXED_IMAGES=("docker.io/getmeili/meilisearch:v1.47.0")

# 辅助函数: 判断元素是否在数组中
in_array() {
    local target="$1"; shift
    for item in "$@"; do
        [[ "$item" == "$target" ]] && return 0
    done
    return 1
}

# ================= 0. 代理连通性预检 =================
echo "==== 0. 检查代理 ===="
# 快速探测代理端口是否在监听（只测本地 TCP 连接，不卡外网）
if ! timeout 2 bash -c "cat < /dev/null > /dev/tcp/127.0.0.1/1145" 2>/dev/null; then
    echo "[错误] 代理端口 127.0.0.1:1145 无法连通，请先启动代理客户端！"
    exit 1
fi
echo "[OK] 本地代理端口正常"
echo ""

# ================= 1. 获取容器列表 =================
mapfile -t lines < <(podman ps --format '{{.Names}}\t{{.Image}}')

if [ ${#lines[@]} -eq 0 ]; then
    echo "未发现任何正在运行的 Podman 容器。"
    exit 0
fi

echo "==== 1. 检查并拉取最新镜像 ===="

declare -A seen_images
declare -A container_old

for line in "${lines[@]}"; do
    [ -z "$line" ] && continue
    name="${line%%$'\t'*}"
    img="${line#*$'\t'}"

    if in_array "$name" "${EXCLUDE_NAMES[@]}"; then
        echo "[跳过] 容器: $name (已排除)"
        continue
    fi
    if in_array "$img" "${FIXED_IMAGES[@]}"; then
        echo "[固定] 镜像: $img (版本锁定，跳过)"
        continue
    fi
    if [[ "$img" == localhost/* ]]; then
        echo "[跳过] 镜像: $img (本地构建)"
        continue
    fi

    # 镜像去重处理
    if [ -z "${seen_images[$img]}" ]; then
        seen_images[$img]=1
        echo -n "[检查] 正在拉取 $img ... "

        old_id=$(podman image inspect "$img" --format '{{.Id}}' 2>/dev/null)

        # 设置 120 秒拉取超时，并记录错误输出
        pull_output=$(timeout 120 podman pull "$img" 2>&1)
        pull_exit_code=$?

        if [ $pull_exit_code -eq 0 ]; then
            new_id=$(podman image inspect "$img" --format '{{.Id}}' 2>/dev/null)
            if [ -n "$old_id" ] && [ "$old_id" != "$new_id" ]; then
                echo -e "\r\033[K[更新] 镜像: $img (已拉取新版本)"
            else
                echo -e "\r\033[K[最新] 镜像: $img"
            fi
        else
            echo -e "\r\033[K[失败] 镜像: $img (拉取失败/超时)"
            err_msg=$(echo "$pull_output" | tail -n 1)
            [ -n "$err_msg" ] && echo "       └─ $err_msg"
        fi
    fi
done

echo ""
echo "==== 2. 检查容器是否运行旧镜像 ===="

for line in "${lines[@]}"; do
    [ -z "$line" ] && continue
    name="${line%%$'\t'*}"
    img="${line#*$'\t'}"

    in_array "$name" "${EXCLUDE_NAMES[@]}" && continue
    in_array "$img" "${FIXED_IMAGES[@]}" && continue
    [[ "$img" == localhost/* ]] && continue

    container_img_id=$(podman inspect "$name" --format '{{.Image}}' 2>/dev/null)
    latest_img_id=$(podman image inspect "$img" --format '{{.Id}}' 2>/dev/null)

    if [ -n "$container_img_id" ] && [ -n "$latest_img_id" ] && [ "$container_img_id" != "$latest_img_id" ]; then
        echo "[落后] 容器: $name ($img)"
        container_old[$name]=1
    fi
done

if [ ${#container_old[@]} -eq 0 ]; then
    echo "所有容器均运行最新镜像，无需重建。"
    exit 0
fi

echo ""
echo "==== 3. 自动重建过时容器 ===="

# 关键: 清除代理，防止 127.0.0.1 注入到新容器中
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy NO_PROXY no_proxy

declare -A dirs
for name in "${!container_old[@]}"; do
    dir=$(podman inspect "$name" --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null)
    if [ -z "$dir" ] || [ "$dir" = "<no value>" ]; then
        echo "[警告] $name 缺少 compose working_dir 标签，跳过自动重建"
        continue
    fi
    dirs[$dir]=1
done

for dir in "${!dirs[@]}"; do
    echo "[重建] 目录: $dir"
    (cd "$dir" && podman compose up -d 2>&1 | tail -5)
done

echo ""
echo "==== 重建后容器状态 ===="
podman ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' | sort

echo ""
echo "==== 清理提示 ===="
echo "如业务正常，可执行清理悬空旧镜像: podman image prune -f"