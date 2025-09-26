#!/bin/bash

# Claude Relay Service 升级脚本
# 作者: GitHub Copilot
# 版本: 1.1.1
# 创建时间: 2025-09-19
# 修复时间: 2025-09-26
# 修复内容: 修复端口映射丢失问题，增强错误处理和调试信息

set -euo pipefail  # 严格模式：未定义变量/管道失败均退出

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 基础配置（可按需调整）
CONTAINER_NAME="claude-relay-service"
# 若设置 IMAGE_TAG，则会使用该 tag；否则默认升级到 :latest
IMAGE_REPO_DEFAULT="weishaw/claude-relay-service"
IMAGE_TAG="${IMAGE_TAG:-latest}"
BACKUP_DIR="/Users/cknight/ck/Programmar/Front/claude-relay-service/backup"

# 运行期变量
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="${SCRIPT_DIR}"
TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t claude-upgrade)"
ENV_FILE="${TMP_DIR}/env.list"
PORTS_FILE="${TMP_DIR}/ports.txt"
NETWORKS_FILE="${TMP_DIR}/networks.txt"
EXTRA_HOSTS_FILE="${TMP_DIR}/extra_hosts.txt"
MOUNTS_FILE="${TMP_DIR}/mounts.txt"
PRIMARY_HOST_PORT=""

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查 Docker 是否运行
check_docker() {
    log_info "检查 Docker 服务状态..."
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker 服务未运行，请先启动 Docker"
        exit 1
    fi
    log_success "Docker 服务正常运行"
}

# 获取当前容器信息
get_current_info() {
    log_info "获取当前容器信息..."
    
    # 检查容器是否存在
    if ! docker ps -a --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
        log_error "容器 ${CONTAINER_NAME} 不存在"
        exit 1
    fi
    
    # 获取当前镜像信息与版本
    CURRENT_IMAGE=$(docker inspect ${CONTAINER_NAME} --format='{{.Config.Image}}')
    CURRENT_VERSION=$(docker inspect ${CONTAINER_NAME} --format='{{index .Config.Labels "org.opencontainers.image.version"}}')
    CURRENT_VERSION=${CURRENT_VERSION:-unknown}
    log_info "当前镜像: ${CURRENT_IMAGE}"
    log_info "当前版本: ${CURRENT_VERSION}"
    
    # 检查容器是否运行
    CONTAINER_STATUS=$(docker inspect ${CONTAINER_NAME} --format='{{.State.Status}}')
    log_info "容器状态: ${CONTAINER_STATUS}"

    # 推导镜像仓库与目标镜像
    # 优先沿用当前镜像仓库（去掉现有 tag），否则使用默认仓库
    if [[ "${CURRENT_IMAGE}" == *":"* ]]; then
        CURRENT_REPO="${CURRENT_IMAGE%%:*}"
    else
        CURRENT_REPO="${CURRENT_IMAGE}"
    fi
    IMAGE_REPO="${CURRENT_REPO:-${IMAGE_REPO_DEFAULT}}"
    IMAGE_NAME="${IMAGE_REPO}:${IMAGE_TAG}"
    log_info "目标镜像: ${IMAGE_NAME}"
}

# 导出容器环境变量到 env.list
export_env() {
    log_info "导出现有容器环境变量..."
    # 包含镜像默认与运行时设置的环境变量
    docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' ${CONTAINER_NAME} \
        | sed '/^$/d' > "${ENV_FILE}"
    chmod 600 "${ENV_FILE}"
    log_success "环境变量已导出到: ${ENV_FILE}"
}

# 导出端口映射、网络与额外 hosts
export_ports_networks_hosts() {
    log_info "导出端口、网络与 hosts 信息..."
    # 端口（使用 docker port 便于解析）
    if docker port ${CONTAINER_NAME} >/dev/null 2>&1; then
        docker port ${CONTAINER_NAME} > "${PORTS_FILE}" || true
    fi
    # 网络
    docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{println $k}}{{end}}' ${CONTAINER_NAME} \
        > "${NETWORKS_FILE}" || true
    # 额外 hosts
    docker inspect -f '{{range .HostConfig.ExtraHosts}}{{println .}}{{end}}' ${CONTAINER_NAME} \
        > "${EXTRA_HOSTS_FILE}" || true
    # 挂载（类型|源|目标|RW）
    docker inspect -f '{{range .Mounts}}{{println .Type "|" .Source "|" .Destination "|" .RW}}{{end}}' ${CONTAINER_NAME} \
        > "${MOUNTS_FILE}" || true
}

# 解析端口映射为 docker run -p 形式，并确定健康检查端口
build_port_args() {
    PORT_ARGS=()
    PRIMARY_HOST_PORT=""
    
    log_info "解析端口映射信息..."
    if [ ! -f "${PORTS_FILE}" ]; then
        log_warning "端口配置文件不存在: ${PORTS_FILE}"
        return 0
    fi
    
    if [ ! -s "${PORTS_FILE}" ]; then
        log_warning "端口配置文件为空，容器可能没有端口映射"
        return 0
    fi
    
    log_info "读取端口配置文件: ${PORTS_FILE}"
    cat "${PORTS_FILE}" | while IFS= read -r line; do
        [ -n "$line" ] && log_info "端口配置行: $line"
    done
    
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        # 示例: 3000/tcp -> 0.0.0.0:3000 或 3000/tcp -> :::3000
        cport_proto=$(echo "$line" | awk '{print $1}')
        cport=${cport_proto%%/*}
        haddr=$(echo "$line" | awk '{print $3}')
        hport=${haddr##*:}
        
        log_info "解析端口映射: 容器端口=${cport}, 主机端口=${hport}"
        
        if [ -n "${cport}" ] && [ -n "${hport}" ]; then
            PORT_ARGS+=("-p" "${hport}:${cport}")
            if [ -z "${PRIMARY_HOST_PORT}" ]; then
                PRIMARY_HOST_PORT="${hport}"
            fi
            log_success "添加端口映射: -p ${hport}:${cport}"
        else
            log_warning "跳过无效的端口配置行: $line"
        fi
    done < "${PORTS_FILE}"
    
    if [ ${#PORT_ARGS[@]} -eq 0 ]; then
        log_warning "未解析到任何端口映射"
    else
        log_success "共解析到 ${#PORT_ARGS[@]} 个端口映射"
        log_info "主要端口: ${PRIMARY_HOST_PORT}"
    fi
}

# 获取重启策略参数
get_restart_policy_arg() {
    local name count source_container
    # 如果备份容器存在，从备份容器获取配置；否则从当前容器获取
    source_container="${BACKUP_CONTAINER_NAME:-${CONTAINER_NAME}}"
    name=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' ${source_container} 2>/dev/null || echo "")
    count=$(docker inspect -f '{{.HostConfig.RestartPolicy.MaximumRetryCount}}' ${source_container} 2>/dev/null || echo "0")
    RESTART_ARG=""
    if [ -n "${name}" ] && [ "${name}" != "no" ]; then
        if [ "${name}" = "on-failure" ] && [ "${count}" != "0" ]; then
            RESTART_ARG="--restart on-failure:${count}"
        else
            RESTART_ARG="--restart ${name}"
        fi
    else
        RESTART_ARG="--restart unless-stopped"
    fi
}

# 拉取最新镜像
pull_latest_image() {
    log_info "拉取镜像 ${IMAGE_NAME}..."
    docker pull ${IMAGE_NAME}
    
    # 获取新版本
    NEW_VERSION=$(docker inspect ${IMAGE_NAME} --format='{{index .Config.Labels "org.opencontainers.image.version"}}' || true)
    NEW_VERSION=${NEW_VERSION:-unknown}
    log_info "新版本: ${NEW_VERSION}"
    
    if [ "${CURRENT_VERSION}" = "${NEW_VERSION}" ] && [ "${IMAGE_TAG}" = "latest" ]; then
        log_warning "当前已是最新版本 ${CURRENT_VERSION}，无需升级"
        read -p "是否强制重新部署? [y/N]: " FORCE_DEPLOY
        if [[ ! ${FORCE_DEPLOY:-n} =~ ^[Yy]$ ]]; then
            exit 0
        fi
    fi
}

# 创建备份
create_backup() {
    log_info "创建数据与配置备份..."
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_PATH="${BACKUP_DIR}/${TIMESTAMP}"
    mkdir -p "${BACKUP_PATH}/mounts" "${BACKUP_PATH}/meta"

    # 备份容器配置与导出的辅助文件
    docker inspect ${CONTAINER_NAME} > "${BACKUP_PATH}/meta/container_config.json"
    cp -f "${ENV_FILE}" "${BACKUP_PATH}/meta/env.list" || true
    cp -f "${PORTS_FILE}" "${BACKUP_PATH}/meta/ports.txt" || true
    cp -f "${NETWORKS_FILE}" "${BACKUP_PATH}/meta/networks.txt" || true
    cp -f "${EXTRA_HOSTS_FILE}" "${BACKUP_PATH}/meta/extra_hosts.txt" || true
    cp -f "${MOUNTS_FILE}" "${BACKUP_PATH}/meta/mounts.txt" || true
    log_success "容器元数据备份完成: ${BACKUP_PATH}/meta"

    # 备份挂载（bind 类型直接复制，volume 类型打包）
    if [ -s "${MOUNTS_FILE}" ]; then
        while IFS='|' read -r mtype msrc mdst mrw; do
            mtype=$(echo "$mtype" | xargs)
            msrc=$(echo "$msrc" | xargs)
            mdst=$(echo "$mdst" | xargs)
            safe_dst=$(echo "$mdst" | sed 's#/#_#g' | sed 's#^_##')
            if [ "$mtype" = "bind" ] && [ -e "$msrc" ]; then
                tar czf "${BACKUP_PATH}/mounts/bind_${safe_dst}.tar.gz" -C "$(dirname "$msrc")" "$(basename "$msrc")" || true
            elif [ "$mtype" = "volume" ]; then
                # 使用临时容器打包 named volume 内容
                docker run --rm --volumes-from ${CONTAINER_NAME} -v "${BACKUP_PATH}/mounts:/backup" busybox \
                    sh -c "cd '${mdst}' 2>/dev/null && tar czf '/backup/vol_${safe_dst}.tar.gz' ." || true
            fi
        done < "${MOUNTS_FILE}"
        log_success "挂载数据备份完成: ${BACKUP_PATH}/mounts"
    fi
}

# 健康检查
health_check() {
    log_info "执行健康检查..."
    local max_attempts=45
    local attempt=1

    # 首先验证容器是否启动
    local status
    status=$(docker inspect -f '{{.State.Status}}' ${CONTAINER_NAME} 2>/dev/null || echo "")
    if [ "$status" != "running" ]; then
        log_error "容器未运行，状态: $status"
        # 显示容器日志帮助调试
        log_error "容器启动失败，显示最后20行日志:"
        docker logs --tail=20 ${CONTAINER_NAME} 2>&1 | while read line; do
            log_error "LOG: $line"
        done
        return 1
    fi

    # 验证端口映射是否生效
    local port_check_passed=false
    if [ -n "${PRIMARY_HOST_PORT}" ]; then
        log_info "验证端口 ${PRIMARY_HOST_PORT} 是否可访问..."
        local port_mappings
        port_mappings=$(docker port ${CONTAINER_NAME} 2>/dev/null || true)
        if [ -n "$port_mappings" ]; then
            log_success "端口映射验证成功:"
            echo "$port_mappings" | while read line; do
                log_info "PORT: $line"
            done
            port_check_passed=true
        else
            log_warning "端口映射验证失败，无端口映射信息"
        fi
    else
        log_info "跳过端口映射验证（无主要端口）"
        port_check_passed=true
    fi

    # 优先依据 Docker Health 状态
    local has_health
    has_health=$(docker inspect -f '{{if .State.Health}}yes{{end}}' ${CONTAINER_NAME} || true)

    while [ $attempt -le $max_attempts ]; do
        status=$(docker inspect -f '{{.State.Status}}' ${CONTAINER_NAME} 2>/dev/null || echo "")
        if [ "$status" = "exited" ] || [ "$status" = "dead" ]; then
            log_error "容器异常退出"
            docker logs --tail=10 ${CONTAINER_NAME}
            return 1
        fi

        if [ "$has_health" = "yes" ]; then
            local hstatus
            hstatus=$(docker inspect -f '{{.State.Health.Status}}' ${CONTAINER_NAME} 2>/dev/null || echo "")
            log_info "Docker Health状态: $hstatus"
            if [ "$hstatus" = "healthy" ]; then
                log_success "健康检查通过（Docker Health）"
                # 如果有端口映射，额外验证HTTP访问
                if [ "$port_check_passed" = "true" ] && [ -n "${PRIMARY_HOST_PORT}" ]; then
                    if curl -fsS "http://127.0.0.1:${PRIMARY_HOST_PORT}/health" >/dev/null 2>&1; then
                        log_success "HTTP健康检查也通过"
                    else
                        log_warning "Docker Health通过但HTTP访问失败，请检查服务配置"
                    fi
                fi
                return 0
            fi
        else
            # 回退到 HTTP 探活（基于映射端口）
            if [ "$port_check_passed" = "true" ] && [ -n "${PRIMARY_HOST_PORT}" ]; then
                if curl -fsS "http://127.0.0.1:${PRIMARY_HOST_PORT}/health" >/dev/null 2>&1; then
                    log_success "健康检查通过（HTTP 探活）"
                    return 0
                fi
            fi
        fi

        log_info "健康检查中... (${attempt}/${max_attempts})"
        sleep 2
        attempt=$((attempt+1))
    done

    log_error "健康检查失败"
    log_error "容器状态: $status"
    if [ "$has_health" = "yes" ]; then
        local hstatus
        hstatus=$(docker inspect -f '{{.State.Health.Status}}' ${CONTAINER_NAME} 2>/dev/null || echo "")
        log_error "Health状态: $hstatus"
    fi
    log_error "显示容器日志进行调试:"
    docker logs --tail=20 ${CONTAINER_NAME} 2>&1 | while read line; do
        log_error "LOG: $line"
    done
    return 1
}

# 升级容器
upgrade_container() {
    log_info "开始升级容器..."

    # 停止当前容器
    log_info "停止当前容器..."
    docker stop ${CONTAINER_NAME}

    # 等待端口释放并清理网络
    log_info "等待端口完全释放..."
    sleep 5
    
    # 强制清理Docker网络连接（但保留当前停止的容器）
    if [ -n "${PRIMARY_HOST_PORT}" ]; then
        log_info "清理端口 ${PRIMARY_HOST_PORT} 的网络连接..."
        # 只清理网络，不清理容器
        docker network prune -f 2>/dev/null || true
    fi
    
    # 再次等待确保端口完全释放
    sleep 3

    # 重命名当前容器作为备份
    BACKUP_CONTAINER_NAME="${CONTAINER_NAME}_backup_$(date +%Y%m%d_%H%M%S)"
    log_info "备份当前容器为: ${BACKUP_CONTAINER_NAME}"
    docker rename ${CONTAINER_NAME} ${BACKUP_CONTAINER_NAME}

    # 获取重启策略（需要在容器重命名后调用）
    get_restart_policy_arg

    # 验证端口映射配置（使用之前导出的配置）
    log_info "验证端口映射配置..."
    if [ ! -s "${PORTS_FILE}" ]; then
        log_error "端口配置丢失！这可能导致服务无法访问"
        log_error "请检查备份文件: ${BACKUP_PATH}/meta/ports.txt"
        read -p "是否继续升级（可能需要手动配置端口）? [y/N]: " CONTINUE_WITHOUT_PORTS
        if [[ ! ${CONTINUE_WITHOUT_PORTS:-n} =~ ^[Yy]$ ]]; then
            log_error "升级已取消"
            exit 1
        fi
    fi
    
    # 组装运行参数
    build_port_args

    RUN_ARGS=(
        "-d"
        "--name" "${CONTAINER_NAME}"
        ${RESTART_ARG}
        "--env-file" "${ENV_FILE}"
        "--volumes-from" "${BACKUP_CONTAINER_NAME}"
    )

    # 端口映射
    if [ ${#PORT_ARGS[@]} -gt 0 ]; then
        log_info "应用端口映射: ${PORT_ARGS[*]}"
        RUN_ARGS+=("${PORT_ARGS[@]}")
    else
        log_warning "警告：没有端口映射！容器将无法从外部访问"
        log_warning "如果需要端口映射，请停止升级并检查配置"
        read -p "是否继续创建没有端口映射的容器? [y/N]: " CONTINUE_NO_PORTS
        if [[ ! ${CONTINUE_NO_PORTS:-n} =~ ^[Yy]$ ]]; then
            log_error "升级已取消"
            exit 1
        fi
    fi

    # 网络（首个作为主网络）
    PRIMARY_NETWORK=""
    NET_ARR=()
    while IFS= read -r line; do
        [ -n "$line" ] && NET_ARR+=("$line")
    done < <(grep -v '^$' "${NETWORKS_FILE}" 2>/dev/null || true)
    if [ ${#NET_ARR[@]} -gt 0 ]; then
        PRIMARY_NETWORK="${NET_ARR[0]}"
        RUN_ARGS+=("--network" "${PRIMARY_NETWORK}")
    fi

    # 额外 hosts
    if [ -s "${EXTRA_HOSTS_FILE}" ]; then
        while IFS= read -r hostline; do
            [ -n "${hostline}" ] && RUN_ARGS+=("--add-host" "${hostline}")
        done < "${EXTRA_HOSTS_FILE}"
    fi

    # 还原 bind 挂载（--volumes-from 不涵盖 bind 类型）
    if [ -s "${MOUNTS_FILE}" ]; then
        while IFS='|' read -r mtype msrc mdst mrw; do
            mtype=$(echo "$mtype" | xargs)
            msrc=$(echo "$msrc" | xargs)
            mdst=$(echo "$mdst" | xargs)
            mrw=$(echo "${mrw}" | tr 'A-Z' 'a-z')
            if [ "$mtype" = "bind" ] && [ -n "$msrc" ] && [ -n "$mdst" ]; then
                mode=""
                if [ "$mrw" = "false" ]; then
                    mode=":ro"
                fi
                RUN_ARGS+=("-v" "${msrc}:${mdst}${mode}")
            fi
        done < "${MOUNTS_FILE}"
    fi

    # 启动新容器
    log_info "启动新版本容器..."
    docker run "${RUN_ARGS[@]}" ${IMAGE_NAME}

    # 连接剩余网络
    if [ ${#NET_ARR[@]} -gt 1 ]; then
        for ((i=1; i<${#NET_ARR[@]}; i++)); do
            docker network connect "${NET_ARR[$i]}" "${CONTAINER_NAME}" || true
        done
    fi

    # 等待容器启动
    log_info "等待容器启动..."
    sleep 3

    # 执行健康检查
    if health_check; then
        log_success "升级成功！新版本容器运行正常"
        
        # 询问是否删除备份容器
        read -p "是否删除备份容器 ${BACKUP_CONTAINER_NAME}? [y/N]: " DELETE_BACKUP
        if [[ ${DELETE_BACKUP:-n} =~ ^[Yy]$ ]]; then
            docker rm ${BACKUP_CONTAINER_NAME}
            log_success "备份容器已删除"
        else
            log_info "备份容器保留: ${BACKUP_CONTAINER_NAME}"
        fi
    else
        log_error "升级失败！正在回滚..."
        rollback_container ${BACKUP_CONTAINER_NAME}
        exit 1
    fi
}

# 回滚容器
rollback_container() {
    local backup_container_name=$1
    log_warning "执行回滚操作..."
    
    # 停止并删除失败的容器
    docker stop ${CONTAINER_NAME} 2>/dev/null || true
    docker rm ${CONTAINER_NAME} 2>/dev/null || true
    
    # 恢复备份容器
    docker rename ${backup_container_name} ${CONTAINER_NAME}
    docker start ${CONTAINER_NAME}
    
    if health_check; then
        log_success "回滚成功，服务已恢复"
    else
        log_error "回滚失败，请手动检查"
    fi
}

# 显示升级结果
show_upgrade_result() {
    log_info "升级结果总览:"
    echo "================================"
    
    # 显示版本信息
    FINAL_VERSION=$(docker inspect ${CONTAINER_NAME} --format='{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || echo "unknown")
    echo "版本: ${CURRENT_VERSION} → ${FINAL_VERSION}"
    
    # 显示容器状态
    CONTAINER_STATUS=$(docker inspect ${CONTAINER_NAME} --format='{{.State.Status}}' 2>/dev/null || echo "unknown")
    echo "状态: ${CONTAINER_STATUS}"
    
    # 显示健康检查
    HEALTH_STATUS=$(docker inspect ${CONTAINER_NAME} --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' 2>/dev/null || echo "unknown")
    echo "健康状态: ${HEALTH_STATUS}"
    
    # 显示端口映射
    echo "端口映射:"
    local port_mappings
    port_mappings=$(docker port ${CONTAINER_NAME} 2>/dev/null || true)
    if [ -n "$port_mappings" ]; then
        echo "$port_mappings"
        if [ -n "${PRIMARY_HOST_PORT}" ]; then
            echo "主要访问地址: http://localhost:${PRIMARY_HOST_PORT}"
            echo "管理界面: http://localhost:${PRIMARY_HOST_PORT}/admin-next/accounts"
        fi
    else
        echo "  无端口映射"
    fi
    
    # 显示容器资源使用
    echo "容器信息:"
    docker stats ${CONTAINER_NAME} --no-stream --format "  CPU: {{.CPUPerc}}  内存: {{.MemUsage}}" 2>/dev/null || echo "  无法获取资源信息"
    
    echo "================================"
    log_success "升级完成！"
    
    if [ -n "$port_mappings" ] && [ -n "${PRIMARY_HOST_PORT}" ]; then
        log_info "快速验证服务是否正常:"
        log_info "curl http://localhost:${PRIMARY_HOST_PORT}/health"
    fi
}

# 主函数
main() {
    echo "======================================="
    echo "  Claude Relay Service 升级工具"
    echo "======================================="
    
    check_docker
    get_current_info
    export_env
    export_ports_networks_hosts
    pull_latest_image
    build_port_args
    create_backup
    
    log_warning "即将执行升级操作，预计停机时间: 10-30秒"
    read -p "确认继续升级? [Y/n]: " CONFIRM
    
    if [[ ${CONFIRM} =~ ^[Nn]$ ]]; then
        log_info "升级已取消"
        exit 0
    fi
    
    upgrade_container
    show_upgrade_result

    # 清理临时文件
    rm -rf "${TMP_DIR}" || true
}

# 执行主函数
main "$@"