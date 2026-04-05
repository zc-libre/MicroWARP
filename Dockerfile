# ==========================================
# 阶段 1：极速编译 MicroSOCKS 引擎
# ==========================================
FROM alpine:latest AS builder
# 安装 C 语言编译环境
RUN apk add --no-cache build-base git
# 从官方仓库拉取源码并编译 (只需 2 秒)
RUN git clone https://github.com/rofl0r/microsocks.git /src && \
    cd /src && make

# ==========================================
# 阶段 2：下载 wgcf 二进制 (构建时固化，避免运行时下载)
# ==========================================
FROM alpine:latest AS wgcf-downloader
RUN apk add --no-cache curl jq
ARG TARGETARCH
RUN WGCF_VER=$(curl -sL https://api.github.com/repos/ViRb3/wgcf/releases/latest | jq -r '.tag_name' | sed 's/^v//') && \
    case "${TARGETARCH}" in \
        amd64) WGCF_ARCH="amd64" ;; \
        arm64) WGCF_ARCH="arm64" ;; \
        *) echo "Unsupported arch: ${TARGETARCH}" && exit 1 ;; \
    esac && \
    curl -L -o /wgcf "https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VER}/wgcf_${WGCF_VER}_linux_${WGCF_ARCH}" && \
    chmod +x /wgcf

# ==========================================
# 阶段 3：极净运行环境
# ==========================================
FROM alpine:latest

# 安装运行依赖: WireGuard + 网络工具 + flock(util-linux) + tini(PID 1)
RUN apk add --no-cache wireguard-tools iptables iproute2 wget curl util-linux tini coreutils

# 打包 microsocks
COPY --from=builder /src/microsocks /usr/local/bin/microsocks
# 打包 wgcf (构建时固化，支持后续 IP 轮换)
COPY --from=wgcf-downloader /wgcf /usr/local/bin/wgcf

WORKDIR /app
COPY entrypoint.sh rotate.sh lib.sh ./
COPY cgi-bin/ ./cgi-bin/
COPY httpd.conf ./
RUN chmod +x entrypoint.sh rotate.sh lib.sh cgi-bin/*

# tini 作为 PID 1，解决僵尸进程回收
ENTRYPOINT ["tini", "--"]
CMD ["./entrypoint.sh"]
