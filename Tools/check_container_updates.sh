#!/bin/bash
# 一键检查并自动重建所有 rootless 容器镜像更新(带代理)
# 排除:mc-fabric-server(minecraft);本地构建镜像(无 RepoDigest)自动跳过
# 流程:对比 digest → pull 新镜像 → 容器 ImageDigest 落后则自动 compose up -d --force-recreate
# 注意:旧镜像不自动删除,拉新后由用户手动确认清理(podman images | grep '<none>')
# 用法:bash ~/Tools/check_container_updates.sh

export HTTP_PROXY=http://127.0.0.1:1145
export HTTPS_PROXY=http://127.0.0.1:1145
export NO_PROXY=localhost,127.0.0.1

EXCLUDE_NAMES="mc-fabric-server"
# 固定版本镜像:只显示状态,不拉取、不重建、不判定落后(如 meilisearch 数据为 1.47.0 建库,latest 不兼容)
FIXED_IMAGES="docker.io/getmeili/meilisearch:v1.47.0"

mapfile -t lines < <(podman ps --format '{{.Names}}\t{{.Image}}')

declare -A seen
declare -A updated_img
declare -A container_old

for line in "${lines[@]}"; do
    name="${line%%$'\t'*}"
    img="${line#*$'\t'}"
    [[ " $EXCLUDE_NAMES " == *" $name "* ]] && { echo "[跳过] $name (排除)"; continue; }
    [[ " $FIXED_IMAGES " == *" $img "* ]] && { echo "[固定] $img (版本已固定,跳过)"; continue; }
    [ -n "${seen[$img]}" ] && continue
    seen[$img]=1

    local_digest=$(podman image inspect "$img" --format '{{index .RepoDigests 0}}' 2>/dev/null | awk -F@ '{print $2}')
    if [ -z "$local_digest" ]; then
        echo "[跳过] $img (本地构建镜像)"
        continue
    fi

    if podman pull "$img" >/dev/null 2>&1; then
        new_digest=$(podman image inspect "$img" --format '{{index .RepoDigests 0}}' 2>/dev/null | awk -F@ '{print $2}')
        if [ "$local_digest" != "$new_digest" ]; then
            echo "[更新] $img (已拉取新镜像)"
        else
            echo "[最新] $img"
        fi
    else
        echo "[失败] $img (拉取错误)"
    fi
done

echo ""
echo "==== 判定容器是否落后于镜像 ===="

for line in "${lines[@]}"; do
    name="${line%%$'\t'*}"
    img="${line#*$'\t'}"
    [[ " $EXCLUDE_NAMES " == *" $name "* ]] && continue
    [[ " $FIXED_IMAGES " == *" $img "* ]] && continue
    repo_digest=$(podman image inspect "$img" --format '{{index .RepoDigests 0}}' 2>/dev/null | awk -F@ '{print $2}')
    [ -z "$repo_digest" ] && continue
    container_digest=$(podman inspect "$name" --format '{{.ImageDigest}}' 2>/dev/null)
    if [ -n "$container_digest" ] && [ "$container_digest" != "$repo_digest" ]; then
        echo "[落后] $name ($img)"
        container_old[$name]=1
    fi
done

if [ ${#container_old[@]} -eq 0 ]; then
    echo "所有容器均运行最新镜像,无需重建。"
    exit 0
fi

echo ""
echo "==== 开始自动重建 ===="

# 关键:拉镜像需要代理,但重建容器绝不能带代理 env(会把死地址 127.0.0.1:1145 烘焙进新容器)
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy

declare -A dirs
for name in "${!container_old[@]}"; do
    dir=$(podman inspect "$name" --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null)
    if [ -z "$dir" ] || [ "$dir" = "<no value>" ]; then
        echo "[警告] $name 无 compose working_dir,跳过重建(需手动处理)"
        continue
    fi
    dirs[$dir]=1
done

for dir in "${!dirs[@]}"; do
    echo "[重建] $dir"
    (cd "$dir" && podman compose up -d --force-recreate 2>&1 | tail -5)
done

echo ""
echo "==== 重建后容器状态 ===="
podman ps --format '{{.Names}}\t{{.Status}}' | sort

echo ""
echo "==== 提示 ===="
echo "旧镜像未自动删除,确认新镜像正常后手动清理:"
echo "  podman images | grep '<none>'   # 查看悬空旧镜像"
echo "  podman image prune -f           # 删除全部悬空镜像"
