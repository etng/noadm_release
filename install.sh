#!/bin/sh
# install.sh —— noadm 一键安装（二进制 + 配置 + 索引站 + 常驻服务）
#
#   curl -fsSL https://raw.githubusercontent.com/etng/noadm_release/main/install.sh | sudo bash -s -- <noadc 地址>
#   wget -qO- https://raw.githubusercontent.com/etng/noadm_release/main/install.sh | sudo bash -s -- <noadc 地址>
#
# 注意不能写成 `bash - <noadc地址>`：bash 会把 `-` 之后那个词当**脚本文件名**执行，
# 报 "No such file or directory"，参数根本没进来。管道传脚本必须 `bash -s -- 参数`。
#
# 除 noadc 广告中心地址外，其余信息（源根、MySQL 连接、端口等）都从本机自动探测，
# 见下方参数表与 --dry-run 输出。
#
# 用法：
#   install.sh <noadc 地址> [选项]
#
#   <noadc 地址>          发布侧的清单地址或 base，如 http://1.2.3.4:8090
#                         也接受 .../manifest.json；不带 scheme 会补 http://
#                         也可用环境变量 NOADC
#   --no-adremote         不接远端广告中心（只用本地素材，ads 由 config 指定）
#   --port N              索引站端口（默认 8088）
#   --metrics-port N      指标与健康检查的独立端口（默认 8092，必须与 --port 不同）
#   --token S             静态口令（**仅开发/自建场景**）。默认不给：站点配置里不含任何
#                         口令，登录走 /__auth?k=<母口令>，由 noadm 比对派生值。
#                         传 random 则生成随机口令。也可用环境变量 NOADM_TOKEN
#   --metrics-password S  指标端点 /metrics 的 Basic 密码（用户名随意）。默认不给：
#                         比对母口令派生值（配置里不写凭证）。也可用 NOADM_METRICS_PASSWORD
#   --no-metrics          不启用指标端点（站点里也就不渲染该 server 块）。此时必须
#                         同时给 --token：派生模式的登录端点依赖 noadm 的 HTTP 服务
#   --no-nginx            不装 nginx 站点（只装二进制；站点文件仍会生成备用）
#   --source-root PATH    生产 HLS 源根（默认自动探测）
#   --mirror-root PATH    镜像输出根（默认 <home>/videos）
#   --ad-dir PATH         广告素材/缓存目录（默认 <home>/ad_sources）
#   --home PATH           noadm 数据根（默认 /home/noadm）
#   --base-url URL        索引页对外 base（默认 http://<本机IP>:<port>）
#   --db-file PATH        改用外部 MySQL 凭证文件（默认把凭证写进 noadm.yml）
#   --db-user/--db-pass   覆盖 .env 里的连接账号（不给就用 .env 的）
#   --db-name NAME        库名（默认取 .env 的 DB_DATABASE）
#   --latest-url URL      覆盖 latest.json 地址（内网镜像用）
#   --no-service          只装二进制与配置，不装/不启动 systemd 服务
#   --force               配置/凭证已存在也重写（默认保留并备份）
#   --dry-run             只打印将做什么，不落盘
#
# 依赖：curl 或 wget 其一；jq（缺失会自动安装）；sha256sum 或 shasum。
# 运行期还需 ffmpeg/ffprobe 与 mysql 客户端。
set -eu

# ── 约定位置（改这里就够了）──────────────────────────────────────────────
PREFIX=/usr/local
BIN_DST=$PREFIX/bin/noadm
CONF_DST=$PREFIX/etc/noadm.yml
UNIT_DST=/etc/systemd/system/noadm-watch.service
SERVICE=noadm-watch
NOADM_USER=noadm
HOME_DEFAULT=/home/noadm

# latest.json 的两个来源：GitHub raw > jsDelivr 兜底。
# 与二进制内自更新（internal/updater）同源，换地址时两处一起改。
LATEST_URLS="https://raw.githubusercontent.com/etng/noadm_release/main/latest.json https://cdn.jsdelivr.net/gh/etng/noadm_release@main/latest.json"

# ── 输出 ───────────────────────────────────────────────────────────────
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	C_R=$(printf '\033[31m') C_G=$(printf '\033[32m') C_Y=$(printf '\033[33m') C_B=$(printf '\033[36m') C_0=$(printf '\033[0m')
else
	C_R="" C_G="" C_Y="" C_B="" C_0=""
fi
info() { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok() { printf '%s  ok%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s warn%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die() {
	printf '%s fail%s %s\n' "$C_R" "$C_0" "$*" >&2
	exit 1
}
have() { command -v "$1" >/dev/null 2>&1; }
run() {
	if [ "$DRY" = 1 ]; then
		printf '  [dry-run] %s\n' "$*"
	else
		"$@"
	fi
}
# 清理历史备份：只保留最近 N 个（默认 3）。备份名带 -<epoch> 后缀，按修改时间排序即可。
# 为什么清理：每装一次就多一个 .bak-*，装十次后 /etc/nginx 与数据根全是历史文件，
# 当前那份配置反而埋在一堆备份里。需要长期留档的自行拷到别处（不要靠安装脚本攒）。
prune_backups() {
	_pattern=$1
	_keep=${2:-3}
	if [ "$DRY" = 1 ]; then
		printf '  [dry-run] 只保留最近 %s 个备份：%s\n' "$_keep" "$_pattern"
		return 0
	fi
	# shellcheck disable=SC2012
	ls -1t $_pattern 2>/dev/null | tail -n +$((_keep + 1)) | while IFS= read -r _f; do
		rm -f "$_f"
	done
}

# ── 参数 ───────────────────────────────────────────────────────────────
ADREMOTE=${NOADC:-}
SOURCE_ROOT=""
MIRROR_ROOT=""
AD_DIR=""
NOADM_HOME=$HOME_DEFAULT
BASE_URL=""
DB_FILE=""
DB_USER=""
DB_PASS=""
DB_NAME=""
PORT=8088
METRICS_PORT=8092
TOKEN=${NOADM_TOKEN:-}
METRICS_PASS=${NOADM_METRICS_PASSWORD:-}
NO_METRICS=0
NO_SERVICE=0
NO_NGINX=0
NO_ADREMOTE=0
FORCE=0
DRY=0

usage() {
	# 从本文件头部的注释块取用法（到 set -eu 为止）；管道执行时 $0 不是本文件，
	# 退化成摘要——别去 sed 一个二进制。
	if [ -f "$0" ] && head -1 "$0" 2>/dev/null | grep -q '^#!/bin/sh'; then
		sed -n '2,/^set -eu$/p' "$0" | sed 's/^# \{0,1\}//' | sed '/^set -eu$/d'
	else
		cat <<'EOF'
usage: install.sh <noadc 地址> [选项]

  唯一必须的参数是 noadc 广告中心地址，其余位置都能自动探测。
    ... | sudo bash -s -- http://<noadc 主机>:8090
    ... | sudo bash -s -- --dry-run http://<noadc 主机>:8090     # 只看将做什么

  常用选项：--port N | --metrics-port N | --token S | --no-nginx | --no-adremote
            --metrics-password S | --no-metrics
            --source-root PATH | --db-user/--db-pass | --home PATH
            --base-url URL | --force | --no-service
  完整选项见脚本头部注释（`sh install.sh -h`）。
EOF
	fi
}

while [ $# -gt 0 ]; do
	case $1 in
	-h | --help) usage; exit 0 ;;
	--no-adremote) ADREMOTE=""; NO_ADREMOTE=1; shift ;;
	--port) PORT=${2:?--port 需要值}; shift 2 ;;
	--metrics-port) METRICS_PORT=${2:?--metrics-port 需要值}; shift 2 ;;
	--token) TOKEN=${2:?--token 需要值}; shift 2 ;;
	--metrics-password) METRICS_PASS=${2:?--metrics-password 需要值}; shift 2 ;;
	--no-metrics) NO_METRICS=1; shift ;;
	--no-nginx) NO_NGINX=1; shift ;;
	--source-root) SOURCE_ROOT=${2:?--source-root 需要值}; shift 2 ;;
	--mirror-root) MIRROR_ROOT=${2:?--mirror-root 需要值}; shift 2 ;;
	--ad-dir) AD_DIR=${2:?--ad-dir 需要值}; shift 2 ;;
	--home) NOADM_HOME=${2:?--home 需要值}; shift 2 ;;
	--base-url) BASE_URL=${2:?--base-url 需要值}; shift 2 ;;
	--db-file) DB_FILE=${2:?--db-file 需要值}; shift 2 ;;
	--db-user) DB_USER=${2:?--db-user 需要值}; shift 2 ;;
	--db-pass) DB_PASS=${2:?--db-pass 需要值}; shift 2 ;;
	--db-name) DB_NAME=${2:?--db-name 需要值}; shift 2 ;;
	--latest-url) LATEST_URL=${2:?--latest-url 需要值}; shift 2 ;;
	--no-service) NO_SERVICE=1; shift ;;
	--force) FORCE=1; shift ;;
	--dry-run) DRY=1; shift ;;
	-*) die "未知参数: $1（用 --help 看用法）" ;;
	*)
		if [ -z "$ADREMOTE" ]; then
			ADREMOTE=$1
		else
			die "多余的位置参数: $1 —— 除 noadc 地址外一律用 --flag 指定"
		fi
		shift
		;;
	esac
done

# 端口后面要拼进 URL 与 nginx 配置，先挡住明显写错的
case $PORT in
'' | *[!0-9]*) die "--port 必须是数字：$PORT" ;;
esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "--port 超出范围：$PORT"

case $METRICS_PORT in
'' | *[!0-9]*) die "--metrics-port 必须是数字：$METRICS_PORT" ;;
esac
[ "$METRICS_PORT" -ge 1 ] && [ "$METRICS_PORT" -le 65535 ] || die "--metrics-port 超出范围：$METRICS_PORT"
# 同端口会让指标端点的 Basic 凭据作用域覆盖索引站（浏览器按 scheme+host+port 缓存凭据），
# 表现为"在 /metrics 登录过，看 task.log 还是 444"。这里提前挡住。
[ "$METRICS_PORT" -ne "$PORT" ] || die "--metrics-port 不能与 --port 相同（都是 $PORT）"

# ── 凭证：默认不需要传 ─────────────────────────────────────────────────
# v2 起索引站口令不再出现在站点配置里：登录由 noadm 用 Argon2id 比对母口令的派生值
# （编译进二进制），再下发 HMAC cookie。所以 --token 不再是"重装要沿用的现场值"，
# 而是一个**仅开发/自建**场景的静态口令开关（给了就把口令写进站点，等同旧行为）。
#
# 这里不再从现场站点 sed 出旧口令：旧站点里的 set $noad_token 在新版模板里已经不存在，
# 读出来必然是空值，接着往下传只会"静默把站点渲染成另一种模式"。
# 指标密码同理：不写 password 就是比对派生值，也不存在"沿用现场明文"这一步。
if [ "$NO_METRICS" = 1 ] && [ -z "$TOKEN" ]; then
	die "--no-metrics 需要同时给 --token：派生口令模式的登录端点跑在 noadm 的 HTTP 服务上，
  关掉它就没有后端可问。要么去掉 --no-metrics，要么用 --token <口令> 走静态模式"
fi

if [ "$NO_METRICS" = 0 ] && [ -z "$METRICS_PASS" ] && [ -f "$CONF_DST" ]; then
	# 只认 metrics: 块里的 password，别把别的块偶然同名的键读进来
	METRICS_PASS=$(awk '
		/^metrics:[[:space:]]*$/ { inblk = 1; next }
		inblk && /^[^[:space:]#]/ { exit }
		inblk && /^[[:space:]]+password:/ {
			sub(/^[[:space:]]+password:[[:space:]]*/, "")
			gsub(/"/, "")
			print
			exit
		}' "$CONF_DST")
	[ -n "$METRICS_PASS" ] && info "沿用 metrics 现有密码（来自 ${CONF_DST}），要换加 --metrics-password"
fi

# ── 基础检查 ───────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || [ "$DRY" = 1 ] || die "需要 root：请用 sudo 运行（curl ... | sudo bash -s -- ...）"

if ! have curl && ! have wget; then
	die "需要 curl 或 wget 之一用于下载"
fi
if ! have sha256sum && ! have shasum; then
	die "需要 sha256sum 或 shasum 用于校验"
fi

case $(uname -s) in
Linux) OS=linux ;;
Darwin) OS=darwin ;;
*) die "不支持的系统: $(uname -s)（只有 linux/darwin 有发布产物）" ;;
esac
case $(uname -m) in
x86_64 | amd64) ARCH=amd64 ;;
aarch64 | arm64) ARCH=arm64 ;;
*) die "不支持的架构: $(uname -m)" ;;
esac
PLATFORM=$OS-$ARCH

if [ "$OS" = darwin ] && [ "$NO_SERVICE" = 0 ]; then
	warn "darwin 无常驻服务（inotify 仅 Linux 实现）：自动改为 --no-service"
	NO_SERVICE=1
fi

# ── jq：缺失就装 ────────────────────────────────────────────────────────
# 上一版手写了 50 行 awk 做 JSON 分词，只为了"不引入依赖"。这属于把外部复杂度
# 搬进脚本：缩进/单行/转义各要照顾一次。jq 是各发行版都有的一行命令，直接装。
pkg_install() {
	if have apt-get; then
		DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$1" >/dev/null 2>&1 && return 0
		apt-get update -qq >/dev/null 2>&1 || true
		DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$1" >/dev/null 2>&1
	elif have dnf; then dnf install -y -q "$1" >/dev/null 2>&1
	elif have yum; then yum install -y -q "$1" >/dev/null 2>&1
	elif have apk; then apk add -q --no-cache "$1" >/dev/null 2>&1
	elif have zypper; then zypper -n install -q "$1" >/dev/null 2>&1
	elif have pacman; then pacman -Sy --noconfirm --quiet "$1" >/dev/null 2>&1
	else return 1
	fi
}

ensure_jq() {
	have jq && return 0
	info "安装 jq（解析 latest.json）"
	pkg_install jq || true
	have jq || die "缺少 jq 且自动安装失败，请手动安装后重试（apt install jq / dnf install jq / apk add jq）"
	ok "jq 已就绪"
}

# ── 下载与校验 ─────────────────────────────────────────────────────────
TMP=$(mktemp -d "${TMPDIR:-/tmp}/noadm-install.XXXXXX")
trap 'rm -rf "$TMP"' EXIT INT TERM

fetch() { # fetch <url> <timeout秒> <输出文件>
	if have curl; then
		curl -fsSL --max-time "$2" -o "$3" "$1" 2>/dev/null
	else
		wget -q -T "$2" -O "$3" "$1" 2>/dev/null
	fi
}

sha256_of() {
	if have sha256sum; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

ensure_jq

info "获取发布信息（${PLATFORM}）"
LATEST="$TMP/latest.json"
got=0
if [ -n "${LATEST_URL:-}" ]; then
	fetch "$LATEST_URL" 20 "$LATEST" && got=1
else
	# 脚本是本地文件时优先用同目录的 latest.json（离线/内网安装）
	if [ -f "$0" ] && [ -f "$(dirname "$0")/latest.json" ]; then
		cp "$(dirname "$0")/latest.json" "$LATEST" && got=1
	fi
	if [ "$got" = 0 ]; then
		for u in $LATEST_URLS; do
			if fetch "$u" 20 "$LATEST"; then got=1; break; fi
		done
	fi
fi
[ "$got" = 1 ] || die "无法获取 latest.json（可用 --latest-url 指定内网镜像）"

jq -e . "$LATEST" >/dev/null 2>&1 || die "latest.json 不是合法 JSON：$LATEST"
VERSION=$(jq -r '.version // empty' "$LATEST")
ASSET_URL=$(jq -r --arg p "$PLATFORM" '.assets[$p].url // empty' "$LATEST")
ASSET_SHA=$(jq -r --arg p "$PLATFORM" '.assets[$p].sha256 // empty' "$LATEST")
[ -n "$VERSION" ] || die "latest.json 里没有 version"
[ -n "$ASSET_URL" ] || die "latest.json 里没有 $PLATFORM 的产物（可能是版本太老）"
case $ASSET_SHA in
[0-9a-fA-F][0-9a-fA-F]*) [ ${#ASSET_SHA} -eq 64 ] || die "latest.json 里 $PLATFORM 的 sha256 格式不对" ;;
*) die "latest.json 里 $PLATFORM 的 sha256 为空，拒绝安装（无法校验完整性）" ;;
esac
ok "版本 v$VERSION"

# ── 探测：能用源系统的数据就不问人 ─────────────────────────────────────
mysql_q() { mysql --defaults-extra-file="$DB_FILE" -N -B -e "$1" 2>/dev/null; }
mysql_usable() { have mysql && [ -n "$DB_FILE" ] && [ -f "$DB_FILE" ] && mysql_q 'select 1' >/dev/null 2>&1; }

# 源根判定：顶层应有 YYYYMMDD 形式的日期目录（生产 HLS 的实际布局）。
looks_like_hls_root() {
	[ -d "$1" ] || return 1
	for sub in "$1"/*; do
		[ -d "$sub" ] || continue
		case ${sub##*/} in
		[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) return 0 ;;
		esac
	done
	return 1
}

nginx_roots() {
	have nginx || return 0
	nginx -T 2>/dev/null | sed -n 's/^[[:space:]]*root[[:space:]][[:space:]]*\([^;]*\);.*/\1/p' | sort -u
}

candidate_roots() {
	# 1) 其他 nginx 站点的 root + uploads/videos
	nginx_roots | while read -r r; do
		[ -n "$r" ] || continue
		case $r in
		*/uploads/videos) echo "$r" ;;
		*) echo "$r/uploads/videos" ;;
		esac
	done
	# 2) 常见部署约定
	printf '%s\n' \
		/var/www/html/public/uploads/videos \
		/var/www/html/uploads/videos \
		/var/www/uploads/videos \
		/srv/www/public/uploads/videos \
		/data/www/public/uploads/videos
}

detect_source_root() {
	[ -n "$SOURCE_ROOT" ] && { echo "$SOURCE_ROOT"; return 0; }

	# MySQL 里有 data_dir（web 根相对，形如 /uploads/videos/20260328/68047_2a17dafe/）。
	# 取一条真实记录，到候选根下验证同名目录存在——比自己猜路径可靠得多。
	if [ -n "$DB_NAME" ] && mysql_usable; then
		dd=$(mysql_q "SELECT data_dir FROM $DB_NAME.videos WHERE data_dir<>'' ORDER BY id DESC LIMIT 1" | head -1)
		rel=$(printf '%s' "$dd" | sed 's#^/*uploads/videos/##; s#/*$##')
		if [ -n "$rel" ]; then
			for c in $(candidate_roots); do
				if [ -d "$c/$rel" ]; then echo "$c"; return 0; fi
			done
		fi
	fi

	for c in $(candidate_roots); do
		if looks_like_hls_root "$c"; then echo "$c"; return 0; fi
	done
	return 1
}

detect_base_url() {
	[ -n "$BASE_URL" ] && { echo "$BASE_URL"; return 0; }
	ip=""
	if have hostname && hostname -I >/dev/null 2>&1; then
		ip=$(hostname -I 2>/dev/null | awk '{print $1}')
	fi
	if [ -z "$ip" ] && have ip; then
		ip=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -1)
	fi
	[ -n "$ip" ] && echo "http://$ip:$PORT"
}

norm_manifest() { # 把 noadc 地址归一成清单 URL
	u=$1
	case $u in
	http://* | https://*) ;;
	*) u="http://$u" ;;
	esac
	case $u in
	*/manifest.json) ;;
	*/) u="${u}manifest.json" ;;
	*) u="$u/manifest.json" ;;
	esac
	printf '%s' "$u"
}

# ── 源系统的 .env：MySQL 参数的真相源 ───────────────────────────────────
# Laravel 部署里 DB_HOST/DB_PORT/DB_DATABASE/DB_USERNAME/DB_PASSWORD 就是生产库
# 的连接参数。它比"查 information_schema 找出含 videos 表的库"更准确：库名、账号、
# 远端 host 都对得上，也不会把备份库/测试库误认成生产库。
find_env() { # 从源根向上找 .env（不跨过根）
	d=$1
	[ -n "$d" ] || return 1
	while [ "$d" != "/" ] && [ -n "$d" ]; do
		if [ -f "$d/.env" ]; then printf '%s' "$d/.env"; return 0; fi
		d=$(dirname "$d")
	done
	return 1
}

env_get() { # env_get <.env> <KEY>：取第一个值并去掉引号/行内注释
	v=$(sed -n "s/^[[:space:]]*$2[[:space:]]*=//p" "$1" | head -1 | tr -d '\r')
	v=$(printf '%s' "$v" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
	case $v in
	\"*) v=$(printf '%s' "$v" | sed 's/^"//; s/"$//') ;;          # 双引号：内容原样
	\'*) v=$(printf '%s' "$v" | sed "s/^'//; s/'\$//") ;;         # 单引号：内容原样
	*) v=$(printf '%s' "$v" | sed 's/[[:space:]]#.*$//') ;;       # 裸值：空格后的 # 是注释
	esac
	printf '%s' "$v"
}

# my.cnf 的值含 # ; 或空格时必须加引号，否则会被当注释/分隔截断
cnf_val() {
	case $1 in
	*'#'* | *';'* | *' '* | *'"'*)
		printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
		;;
	*) printf '%s' "$1" ;;
	esac
}

# yaml_val 把值安全地放进 YAML 双引号里（密码可能含 # : 空格 引号 反斜杠）。
yaml_val() {
	printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
}

# ── 推导路径 ───────────────────────────────────────────────────────────
[ -n "$AD_DIR" ] || AD_DIR=$NOADM_HOME/ad_sources
[ -n "$MIRROR_ROOT" ] || MIRROR_ROOT=$NOADM_HOME/videos
# 凭证默认写进配置文件（mysql 直连字段）；--db-file 只在要用外部凭证文件时才给。
# 数据根不再放 .my.cnf：多一个 0600 文件就多一处要记得同步/清理的东西。

ENV_FILE=""
if [ -n "$SOURCE_ROOT" ]; then ENV_FILE=$(find_env "$SOURCE_ROOT" 2>/dev/null || true); fi
if [ -z "$ENV_FILE" ]; then
	# 源根还没确定时，先按候选根去撞 .env（生产站点通常就在候选根的上几级）
	for c in $(candidate_roots); do
		if e=$(find_env "$c" 2>/dev/null) && [ -n "$e" ]; then ENV_FILE=$e; break; fi
	done
fi

E_HOST="" E_PORT="" E_NAME="" E_USER="" E_PASS=""
if [ -n "$ENV_FILE" ]; then
	ok "源系统 .env = ${ENV_FILE}（MySQL 连接参数以此为准）"
	E_HOST=$(env_get "$ENV_FILE" DB_HOST)
	E_PORT=$(env_get "$ENV_FILE" DB_PORT)
	E_NAME=$(env_get "$ENV_FILE" DB_DATABASE)
	E_USER=$(env_get "$ENV_FILE" DB_USERNAME)
	E_PASS=$(env_get "$ENV_FILE" DB_PASSWORD)
else
	warn "未找到源系统的 .env（从候选根逐级向上找），MySQL 参数改用探测"
fi

[ -n "$DB_NAME" ] || DB_NAME=$E_NAME
[ -n "$DB_USER" ] || DB_USER=$E_USER
[ -n "$DB_PASS" ] || DB_PASS=$E_PASS
DB_HOST=${E_HOST:-localhost}
DB_PORT=${E_PORT:-3306}

# 库名还未知但凭证可用 → 反查含 videos 表的库（旧路径，.env 缺失时才走）
if [ -z "$DB_NAME" ] && mysql_usable; then
	DB_NAME=$(mysql_q "SELECT table_schema FROM information_schema.tables WHERE table_name='videos' LIMIT 1" | head -1)
fi

info "探测源系统布局"
if SOURCE_ROOT=$(detect_source_root); then
	ok "sourceRoot = $SOURCE_ROOT"
else
	die "无法确定生产 HLS 源根（顶层需有 YYYYMMDD 目录）。请用 --source-root 指定，例如 /var/www/html/public/uploads/videos"
fi

# 源根可能落在另一棵树里（例如 --source-root 指到别处）：再找一次 .env
[ -n "$ENV_FILE" ] || ENV_FILE=$(find_env "$SOURCE_ROOT" 2>/dev/null || true)

if [ "$NO_ADREMOTE" = 1 ]; then
	MANIFEST=""
	warn "已跳过广告中心（--no-adremote）：ads 由配置指定，未配置则只镜像不插广告"
else
	[ -n "$ADREMOTE" ] || die "缺少 noadc 广告中心地址。

  它是唯一无法自动推导的参数（其余位置都有约定，能从 .env/MySQL/nginx 读出来）：
    curl -fsSL <本脚本地址> | sudo bash -s -- http://<noadc 主机>:8090

  确实没有广告中心时用 --no-adremote（只镜像、不插广告）。"
	MANIFEST=$(norm_manifest "$ADREMOTE")
	ok "adRemote.manifestURL = $MANIFEST"
fi

BASE=$(detect_base_url || true)
if [ -n "$BASE" ]; then ok "publicBaseURL = $BASE"; else warn "未探测到本机 IP，publicBaseURL 留空（索引页链接会不可用）"; fi

if [ -n "$DB_NAME" ]; then ok "mysql.database = $DB_NAME"; else warn "未确定库名（.env 无 DB_DATABASE 且探测失败），-id/-all 会不可用"; fi

# ── 下载二进制 ─────────────────────────────────────────────────────────
info "下载 noadm v$VERSION"
BIN_TMP=$TMP/noadm
fetch "$ASSET_URL" 120 "$BIN_TMP" || die "下载失败: $ASSET_URL"
sum=$(sha256_of "$BIN_TMP")
[ "$sum" = "$ASSET_SHA" ] || die "sha256 不匹配，拒绝安装
  期望 $ASSET_SHA
  实际 $sum"
ok "sha256 校验通过"
# dry-run 下要直接执行这个临时文件（noadm assets），必须补执行位
chmod 0755 "$BIN_TMP"

# ── 落盘 ───────────────────────────────────────────────────────────────
if [ "$DRY" = 0 ] && [ -f "$UNIT_DST" ] && systemctl is-active -q "$SERVICE" 2>/dev/null; then
	info "停止 ${SERVICE}（运行中的二进制无法覆盖）"
	systemctl stop "$SERVICE" || true
fi

info "安装二进制 → $BIN_DST"
run mkdir -p "$(dirname "$BIN_DST")"
if [ "$DRY" = 1 ]; then
	printf '  [dry-run] install -m 0755 <%s> %s\n' "$BIN_TMP" "$BIN_DST"
else
	install -m 0755 -o root -g root "$BIN_TMP" "$BIN_DST"
fi
ok "$BIN_DST"

# 数据根与运行用户（属主用于保护配置与日志；服务本身仍以 root 运行，与 Ansible 部署一致）
info "准备数据根 $NOADM_HOME"
if [ "$DRY" = 0 ]; then
	if ! id "$NOADM_USER" >/dev/null 2>&1; then
		useradd --system --home-dir "$NOADM_HOME" --shell /usr/sbin/nologin --user-group "$NOADM_USER" 2>/dev/null ||
			adduser --system --home "$NOADM_HOME" --group "$NOADM_USER" 2>/dev/null ||
			warn "创建用户 $NOADM_USER 失败，目录将保持当前属主"
	fi
	mkdir -p "$NOADM_HOME" "$MIRROR_ROOT" "$AD_DIR"
	if id "$NOADM_USER" >/dev/null 2>&1; then
		chown "$NOADM_USER:$NOADM_USER" "$NOADM_HOME" "$MIRROR_ROOT" "$AD_DIR" 2>/dev/null || true
	fi
else
	printf '  [dry-run] mkdir -p %s %s %s\n' "$NOADM_HOME" "$MIRROR_ROOT" "$AD_DIR"
fi
ok "$MIRROR_ROOT / $AD_DIR"

# MySQL 凭证：.env 有就用它（那是生产库的真实账号），--db-* 可覆盖
write_mycnf() {
	run mkdir -p "$(dirname "$DB_FILE")"
	if [ "$DRY" = 1 ]; then
		printf '  [dry-run] 写入 %s（[client] user/password/host/port，0600）\n' "$DB_FILE"
		return 0
	fi
	umask 077
	{
		printf '[client]\n'
		[ -n "$DB_USER" ] && printf 'user=%s\n' "$(cnf_val "$DB_USER")"
		[ -n "$DB_PASS" ] && printf 'password=%s\n' "$(cnf_val "$DB_PASS")"
		[ -n "$DB_HOST" ] && printf 'host=%s\n' "$(cnf_val "$DB_HOST")"
		[ -n "$DB_PORT" ] && printf 'port=%s\n' "$(cnf_val "$DB_PORT")"
	} >"$DB_FILE"
	chmod 600 "$DB_FILE"
	if [ "$(id -u)" -eq 0 ] && id "$NOADM_USER" >/dev/null 2>&1; then
		chown "$NOADM_USER:$NOADM_USER" "$DB_FILE" 2>/dev/null || true
	fi
	ok "${DB_FILE}（0600，来自 ${ENV_FILE:-命令行}）"
}

if [ -n "$DB_FILE" ]; then
	info "写入外部 MySQL 凭证 → $DB_FILE"
	if [ -f "$DB_FILE" ] && [ "$FORCE" = 0 ]; then
		warn "凭证文件已存在，保留不动：${DB_FILE}（要按 .env/命令行重写加 --force）"
	else
		[ -f "$DB_FILE" ] && run cp "$DB_FILE" "$DB_FILE.bak-$(date +%s)"
		write_mycnf
	fi
elif [ -z "$DB_USER" ] && [ -z "$DB_PASS" ]; then
	warn "既没有 .env 的账号也没有 --db-user/--db-pass：配置文件会缺 mysql 凭证，需手工补"
fi

# 配置文件：已存在则保留（升级不覆盖现场调参），--force 才覆盖并备份
render_conf() {
	cat <<EOF
# noadm 配置 —— 由 install.sh 于 $(date '+%Y-%m-%d %H:%M:%S') 生成
#
# 只写与约定位置相关的项；其余全部走二进制内置默认值（见源码
# internal/config/defaults.go，启动时会校验，写错的键名会直接报错）。
sourceRoot: $SOURCE_ROOT
mirrorRoot: $MIRROR_ROOT
adSourceDir: $AD_DIR
indexOutput: $NOADM_HOME/index.html
EOF
	[ -n "$BASE" ] && printf 'publicBaseURL: %s\n' "$BASE"
	cat <<EOF

mysql:
EOF
	if [ -n "$DB_USER" ]; then
		printf '  host: %s\n' "$(yaml_val "$DB_HOST")"
		printf '  port: %s\n' "$DB_PORT"
		printf '  user: %s\n' "$(yaml_val "$DB_USER")"
		printf '  password: %s\n' "$(yaml_val "$DB_PASS")"
	else
		printf '  defaultsFile: %s\n' "$DB_FILE"
	fi
	[ -n "$DB_NAME" ] && printf '  database: %s\n' "$DB_NAME"
	cat <<EOF

watch:
  logFile: $NOADM_HOME/logs/watch.log

adRemote:
EOF
	if [ -n "$MANIFEST" ]; then
		cat <<EOF
  enabled: true
  manifestURL: "$MANIFEST"
  dir: $AD_DIR
EOF
	else
		printf '  enabled: false\n'
	fi
	cat <<EOF

metrics:
EOF
	if [ "$NO_METRICS" = 1 ]; then
		printf '  enabled: false\n'
	elif [ -n "$METRICS_PASS" ]; then
		printf '  enabled: true\n  password: "%s"\n' "$METRICS_PASS"
	else
		# 不写 password：由二进制内置默认兜底。默认值住二进制里是因为本脚本会
		# 原样发到公开的 release 仓库，把凭证写在这儿等于把钥匙一起公开。
		printf '  enabled: true\n'
	fi
}

# 指标端点密码：不给就比对母口令派生值（编译进二进制），本脚本不持有任何凭证。
# 只有显式给了才写进配置，并在这里校验它能安全地放进 YAML 双引号里。
if [ -n "$METRICS_PASS" ]; then
	case $METRICS_PASS in
	*'"'* | *\\* ) die "--metrics-password 不能包含双引号或反斜杠" ;;
	esac
	[ ${#METRICS_PASS} -ge 8 ] || die "--metrics-password 至少 8 位"
fi

info "生成配置 → $CONF_DST"
if [ "$DRY" = 0 ]; then
	mkdir -p "$(dirname "$CONF_DST")"
	if [ -f "$CONF_DST" ] && [ "$FORCE" = 0 ]; then
		warn "配置已存在，保留不动：${CONF_DST}（要重写加 --force，会先备份）"
	else
		if [ -f "$CONF_DST" ]; then
			cp "$CONF_DST" "$CONF_DST.bak-$(date +%s)"
			prune_backups "$CONF_DST.bak-*" 3
		fi
		render_conf >"$CONF_DST"
		# 配置里可能带 DB 密码：只有属主可读
		chmod 0600 "$CONF_DST"
		ok "$CONF_DST"
	fi
else
	# dry-run 也要反映"已存在就保留"的真实行为，否则会让人以为配置会被重写
	if [ -f "$CONF_DST" ] && [ "$FORCE" = 0 ]; then
		printf '  [dry-run] 保留 %s（已存在，要重写加 --force）\n' "$CONF_DST"
	else
		printf '  [dry-run] 写入 %s：\n' "$CONF_DST"
		render_conf | sed 's/^/    /'
	fi
fi

# ── 部署文件（unit + nginx 站点）由二进制释放 ───────────────────────────
# 不再从 release 仓库下载：端口、目录这些口径必须跟二进制一致，
# 分开发布就会出现"二进制改了端口、站点还是旧的"。二进制内嵌一份（internal/assets），
# `noadm assets` 释放的就是当前版本认可的那一份。
#
# 指标走独立端口（-metrics-port）：Basic 凭据按 origin 缓存，跟索引站同端口会串味。
render_assets() {
	if [ "$NO_METRICS" = 1 ]; then
		"$1" assets -o "$ASSET_DIR" -port "$PORT" -metrics-port "$METRICS_PORT" -no-metrics \
			-token "$TOKEN" -home "$NOADM_HOME" \
			-source-root "$SOURCE_ROOT" -mirror-root "$MIRROR_ROOT" >/dev/null
	else
		"$1" assets -o "$ASSET_DIR" -port "$PORT" -metrics-port "$METRICS_PORT" \
			-token "$TOKEN" -home "$NOADM_HOME" \
			-source-root "$SOURCE_ROOT" -mirror-root "$MIRROR_ROOT" >/dev/null
	fi
}
info "释放部署文件（noadm assets）"
ASSET_DIR=$TMP/assets
# 口令留空 = 派生值模式：站点里不含任何口令，登录由 noadm 比对派生值。
# --token 只在开发/自建场景用；本脚本不生成、也不持有任何口令。
if [ "$DRY" = 1 ]; then
	render_assets "$BIN_TMP" ||
		die "noadm assets 执行失败（需要 v0.3.2 及以上的二进制；旧版本没有这个子命令）"
else
	render_assets "$BIN_DST" ||
		die "noadm assets 执行失败（需要 v0.3.2 及以上的二进制；旧版本没有这个子命令）"
fi
ok "systemd unit + nginx 站点已渲染"

# 回读真正生效的口令：静态模式才有值（写在站点的 set $noad_token 里）；
# 派生模式下一个口令都不该出现在站点里，此时摘要改成提示用母口令登录。
EFFECTIVE_TOKEN=$TOKEN
if [ -f "$ASSET_DIR/noadm.conf" ]; then
	EFFECTIVE_TOKEN=$(sed -n 's/^[[:space:]]*set \$noad_token "\([^"]*\)".*/\1/p' "$ASSET_DIR/noadm.conf" | head -1)
fi
if [ -z "$EFFECTIVE_TOKEN" ]; then
	# 兜底自检：派生模式下站点里出现任何口令字样都说明渲染不对
	if grep -q 'set \$noad_token' "$ASSET_DIR/noadm.conf" 2>/dev/null; then
		warn "站点里出现了空口令的 set 指令，请检查 noadm assets 渲染结果"
	fi
fi
METRICS_PASS_NOTE=""
if [ "$NO_METRICS" = 0 ] && [ -z "$METRICS_PASS" ]; then
	METRICS_PASS_NOTE="（比对母口令派生值，配置里不写密码；要用独立密码加 --metrics-password）"
fi

# ── 常驻服务 ───────────────────────────────────────────────────────────
if [ "$NO_SERVICE" = 1 ]; then
	info "跳过 systemd 服务（--no-service 或非 Linux）"
elif ! have systemctl; then
	warn "没有 systemctl，跳过服务安装；直接用 $BIN_DST -all 批处理"
else
	info "安装 systemd unit → $UNIT_DST"
	if [ "$DRY" = 0 ]; then
		install -m 0644 -o root -g root "$ASSET_DIR/noadm-watch.service" "$UNIT_DST"
		systemctl daemon-reload
		ok "$UNIT_DST"
	else
		printf '  [dry-run] install -m 0644 <%s> %s\n' "$ASSET_DIR/noadm-watch.service" "$UNIT_DST"
	fi
fi

# ── 索引站 nginx 站点 ──────────────────────────────────────────────────
# 受限 URI 一律挂 auth_request（鉴权在 noadm 侧），否则装完就把索引、task.log、
# report.json 全暴露了。
NGINX_SITE=""
if [ "$NO_NGINX" = 1 ]; then
	info "跳过 nginx 站点（--no-nginx）
  需要时：sudo $BIN_DST assets -o /tmp/a -port $PORT -metrics-port $METRICS_PORT -home $NOADM_HOME -source-root $SOURCE_ROOT"
elif ! have nginx; then
	warn "未检测到 nginx，跳过站点安装。装好 nginx 后执行：
  sudo $BIN_DST assets -o /tmp/a -port $PORT -metrics-port $METRICS_PORT -home $NOADM_HOME -source-root $SOURCE_ROOT
  sudo cp /tmp/a/noadm.conf /etc/nginx/conf.d/noadm.conf && sudo nginx -t && sudo systemctl reload nginx"
else
	# 重复安装时旧站点本来就占着这个端口——只有"不是 nginx"或"nginx 里没这个端口"
	# 才值得警告，否则每次升级都报一条假警报。
	if have ss && ss -ltn 2>/dev/null | grep -q ":$PORT "; then
		if have nginx && nginx -T 2>/dev/null | grep -Eq "listen[[:space:]]+$PORT([[:space:]]|;)"; then
			ok "端口 $PORT 已由现有 nginx 站点占用（本次替换该站点）"
		else
			warn "端口 $PORT 已被其它进程监听，站点可能起不来（ss -ltnp 查看）"
		fi
	fi
	# 指标端口是新增的对外端口：被别的进程占着就 reload 失败，提前提示
	if [ "$NO_METRICS" = 0 ] && have ss && ss -ltn 2>/dev/null | grep -q ":$METRICS_PORT "; then
		if ! nginx -T 2>/dev/null | grep -Eq "listen[[:space:]]+$METRICS_PORT([[:space:]]|;)"; then
			warn "指标端口 $METRICS_PORT 已被其它进程监听，reload 可能失败（ss -ltnp 查看；或用 --metrics-port 换一个）"
		fi
	fi
	# auth_request 模块自检：Ubuntu 官方包默认带，但自编译/精简包可能没有。
	# 缺它的话站点能装上却永远 500（unknown directive），装之前先问一句。
	if ! nginx -V 2>&1 | grep -q auth_request; then
		if [ -n "$TOKEN" ]; then
			warn "nginx 缺 ngx_http_auth_request_module：静态模式不依赖它，可继续"
		else
			die "nginx 缺 ngx_http_auth_request_module（nginx -V 2>&1 | grep auth_request 无输出）。
  派生口令模式依赖它；装官方包或加 --token 走静态模式"
		fi
	fi
	info "安装 nginx 站点（站点端口 ${PORT}，指标端口 $([ "$NO_METRICS" = 1 ] && echo 未启用 || echo "$METRICS_PORT")）"
	if [ -d /etc/nginx/sites-enabled ]; then
		NGINX_SITE=/etc/nginx/sites-available/noadm.conf
		LINK=/etc/nginx/sites-enabled/noadm.conf
	else
		NGINX_SITE=/etc/nginx/conf.d/noadm.conf
		LINK=""
	fi
	if [ "$DRY" = 1 ]; then
		printf '  [dry-run] install -m 0644 <%s> %s\n' "$ASSET_DIR/noadm.conf" "$NGINX_SITE"
		[ -n "$LINK" ] && printf '  [dry-run] ln -sfn ../sites-available/noadm.conf %s\n' "$LINK"
		printf '  [dry-run] nginx -t && systemctl reload nginx\n'
	else
		BACKUP=""
		if [ -f "$NGINX_SITE" ]; then
			BACKUP=$NGINX_SITE.bak-$(date +%s)
			cp "$NGINX_SITE" "$BACKUP"
			prune_backups "$NGINX_SITE.bak-*" 3
		else
			mkdir -p "$(dirname "$NGINX_SITE")"
		fi
		install -m 0644 -o root -g root "$ASSET_DIR/noadm.conf" "$NGINX_SITE"
		[ -n "$LINK" ] && ln -sfn ../sites-available/noadm.conf "$LINK"

		# 语法错就回滚：宁可不装站点，也不能让对方正在跑的 nginx 起不来
		if ! nginx -t >"$TMP/nginx-t.log" 2>&1; then
			sed 's/^/    /' "$TMP/nginx-t.log" >&2
			if [ -n "$BACKUP" ]; then
				cp "$BACKUP" "$NGINX_SITE"
				warn "nginx -t 失败，已回滚到 $BACKUP"
			else
				rm -f "$NGINX_SITE"
				[ -n "$LINK" ] && rm -f "$LINK"
				warn "nginx -t 失败，已移除本次安装的站点文件"
			fi
			NGINX_SITE=""
		else
			if systemctl is-active -q nginx 2>/dev/null; then
				systemctl reload nginx && ok "nginx 已 reload"
			else
				systemctl enable --now nginx >/dev/null 2>&1 && ok "nginx 已启动" ||
					warn "nginx 启动失败：systemctl status nginx"
			fi
		fi
	fi
fi

# ── 校验与启动 ─────────────────────────────────────────────────────────
if [ "$DRY" = 0 ]; then
	info "校验安装结果"
	"$BIN_DST" version || die "二进制无法运行：$BIN_DST version"
fi

if [ "$NO_SERVICE" = 0 ] && have systemctl; then
	if [ "$DRY" = 0 ] && ! mysql_usable; then
		warn "MySQL 不可用（$DB_FILE 缺失或连不上），暂不启动服务（-id/-all/-watch 都需要它）。
  确认 $DB_FILE 后：sudo $BIN_DST -config $CONF_DST -genindex    # 先验证配置
                  sudo systemctl enable --now $SERVICE"
	else
		if [ "$DRY" = 0 ]; then
			systemctl enable --now "$SERVICE" >/dev/null 2>&1 || warn "启动失败：journalctl -u $SERVICE -n 50 --no-pager"
			ok "$SERVICE 已启用"
		else
			printf '  [dry-run] systemctl enable --now %s\n' "$SERVICE"
		fi
	fi
fi

# ── 摘要 ───────────────────────────────────────────────────────────────
printf '\n%s安装完成%s v%s（%s）\n' "$C_G" "$C_0" "$VERSION" "$PLATFORM"
cat <<EOF

  二进制    $BIN_DST
  配置      $CONF_DST
  服务      $([ "$NO_SERVICE" = 1 ] && echo "未安装" || echo "$UNIT_DST")
  索引站    ${NGINX_SITE:-未安装（可用 noadm assets 随时重新渲染）}
  源根      ${SOURCE_ROOT}（只读，不会被写入）
  镜像根    $MIRROR_ROOT
  广告缓存  $AD_DIR
  清单      ${MANIFEST:-（未启用）}
  指标      $([ "$NO_METRICS" = 1 ] && echo "未启用" || echo "http://<本机IP>:$METRICS_PORT/metrics（Basic 认证，用户名随意）")

进索引站要先登录（cookie 30 天有效）：

$([ -n "$EFFECTIVE_TOKEN" ] && printf '  http://<本机IP>:%s/__auth?k=%s\n  静态口令 %s（写在站点配置里，仅开发/自建场景）\n' "$PORT" "$EFFECTIVE_TOKEN" "$EFFECTIVE_TOKEN" || printf '  http://<本机IP>:%s/__auth?k=<母口令>\n  站点配置里不含口令；母口令见控制机 private/mother_secret.txt。\n  换口令=改母口令→重算派生值→重新发版（无法只改配置）。\n' "$PORT")

指标与健康检查（独立端口，与索引站分开是为了让浏览器凭据不串味）：
  curl -u any:${METRICS_PASS:-<密码>} http://<本机IP>:$METRICS_PORT/metrics | jq .
  curl -s http://<本机IP>:$METRICS_PORT/healthz          # 免认证，探针用
  密码：$([ -n "$METRICS_PASS" ] && echo "写在 $CONF_DST 的 metrics.password" || echo "母口令（比对派生值，配置里没写密码）${METRICS_PASS_NOTE}")；改端口用 --metrics-port 重装。
  注意：这两套凭据互不相通 —— Basic 只管指标，索引/task.log/report.json 只认 cookie。

下一步：
  1) 全量首次处理：sudo $BIN_DST -all        # 索引会自动重建
  2) 看日志：journalctl -u $SERVICE -f
  3) ts/m3u8 与播放页保持公开，索引/task.log/report.json 需登录（auth_request 校验）
EOF

# 收尾必须显式 exit 0：`[ ... ] && printf` 在条件不成立时返回 1，会让整个脚本
# 以失败码退出（`curl | bash` 后面接 && 的自动化就会误判）。
if [ "$DRY" = 1 ]; then
	printf '\n%s（dry-run：以上均为预览；除 jq 等依赖安装外未改动系统）%s\n' "$C_Y" "$C_0"
fi
exit 0
