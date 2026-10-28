#!/usr/bin/env bash
# 自签证书工具：选择/新建根证书 -> 签发网站证书（含 Tomcat 证书）
#
# 目录结构：
#   root/<组织>-<到期日>/root.crt, root.key.pem
#   cert/<域名>-<到期日>/<域名>.crt, .key.pem, .bundle.crt, .p12, .jks, root.crt

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
BASE="$(pwd)"
ROOT_DIR="${BASE}/root"
CERT_DIR="${BASE}/cert"
DEFAULT_ROOT="default-2099-12-31"

# ---------- 工具函数 ----------

die() { echo "错误: $*" >&2; exit 1; }

# ask <变量名> <提示> [默认值]
ask() {
    local __input
    if [ -n "${3:-}" ]; then
        read -r -p "$2 [$3]: " __input
        __input="${__input:-$3}"
    else
        read -r -p "$2: " __input
    fi
    printf -v "$1" '%s' "$__input"
}

# 日期计算统一用 UTC，避免夏令时造成天数误差；兼容 BSD(macOS) 与 GNU date
is_bsd_date() { date -v+1d >/dev/null 2>&1; }

# to_epoch YYYY-MM-DD
to_epoch() {
    if is_bsd_date; then
        TZ=UTC date -j -f "%Y-%m-%d %H:%M:%S" "$1 00:00:00" +%s 2>/dev/null
    else
        TZ=UTC date -d "$1 00:00:00" +%s 2>/dev/null
    fi
}

# date_add <数量> <y|m|d>  -> YYYY-MM-DD
date_add() {
    if is_bsd_date; then
        TZ=UTC date -v+"$1""$2" +%Y-%m-%d
    else
        local unit
        case "$2" in y) unit=years ;; m) unit=months ;; d) unit=days ;; esac
        TZ=UTC date -d "+$1 $unit" +%Y-%m-%d
    fi
}

# parse_duration <输入>：支持 10y / 24m / 825d / 2099-12-31
# 结果写入全局变量 END_DATE 和 DAYS
parse_duration() {
    local input="$1"
    if [[ "$input" =~ ^([0-9]+)([yYmMdD])$ ]]; then
        local unit
        unit="$(echo "${BASH_REMATCH[2]}" | tr 'YMD' 'ymd')"
        END_DATE="$(date_add "${BASH_REMATCH[1]}" "$unit")"
    elif [[ "$input" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        END_DATE="$input"
    else
        return 1
    fi
    local end_epoch today_epoch
    end_epoch="$(to_epoch "$END_DATE")" || return 1
    [ -n "$end_epoch" ] || return 1
    today_epoch="$(to_epoch "$(TZ=UTC date +%Y-%m-%d)")"
    DAYS=$(( (end_epoch - today_epoch) / 86400 ))
    [ "$DAYS" -gt 0 ] || return 1
}

# ask_duration <提示> <默认值>
ask_duration() {
    local input
    while true; do
        ask input "$1（如 2y / 24m / 825d / 2099-12-31）" "$2"
        if parse_duration "$input"; then
            echo "  到期日: ${END_DATE}（${DAYS} 天）"
            return
        fi
        echo "  格式无效或日期不晚于今天，请重新输入"
    done
}

# 目录名里去掉不安全字符
safe_name() { echo "$1" | sed -e 's/^\*\./wildcard./' -e 's/[^A-Za-z0-9._-]/_/g'; }

# 已存在则追加时间后缀
unique_dir() {
    local dir="$1"
    [ -e "$dir" ] && dir="${dir}_$(date +%H%M%S)"
    echo "$dir"
}

cert_enddate() { openssl x509 -in "$1" -noout -enddate -dateopt iso_8601 | cut -d= -f2 | cut -c1-10; }
cert_subject_field() {
    openssl x509 -in "$1" -noout -subject -nameopt multiline,utf8,-esc_msb \
        | sed -n "s/^ *$2 *= *//p" | head -n1
}

# cert_info <证书> <类型> <名称> [SAN]：输出证书的组织、到期时间等信息
cert_info() {
    local crt="$1" v
    echo "$2: $3"
    v="$(cert_subject_field "$crt" countryName)";         [ -n "$v" ] && echo "国家 (C): $v"
    v="$(cert_subject_field "$crt" stateOrProvinceName)"; [ -n "$v" ] && echo "省份 (ST): $v"
    v="$(cert_subject_field "$crt" localityName)";        [ -n "$v" ] && echo "城市 (L): $v"
    echo "组织 (O): $(cert_subject_field "$crt" organizationName)"
    echo "通用名称 (CN): $(cert_subject_field "$crt" commonName)"
    [ -n "${4:-}" ] && echo "域名 (SAN): $4"
    [ -n "${4:-}" ] && echo "签发者: $(openssl x509 -in "$crt" -noout -issuer -nameopt multiline,utf8,-esc_msb | sed -n 's/^ *commonName *= *//p')"
    echo "生效时间: $(openssl x509 -in "$crt" -noout -startdate -dateopt iso_8601 | cut -d= -f2)"
    echo "到期时间: $(openssl x509 -in "$crt" -noout -enddate -dateopt iso_8601 | cut -d= -f2)"
    echo "SHA-256 指纹: $(openssl x509 -in "$crt" -noout -fingerprint -sha256 | cut -d= -f2)"
}

# ---------- 根证书 ----------

# create_root <目录> <C> <ST> <L> <O> <CN> <天数>
create_root() {
    local dir="$1"
    mkdir -p "$dir"
    openssl req -x509 -new -sha256 -days "$7" \
        -newkey rsa:4096 -nodes -keyout "${dir}/root.key.pem" \
        -out "${dir}/root.crt" \
        -subj "/C=$2/ST=$3/L=$4/O=$5/CN=$6" \
        -addext "basicConstraints=critical,CA:true" \
        -addext "keyUsage=critical,keyCertSign,cRLSign,digitalSignature" \
        -addext "subjectKeyIdentifier=hash" 2>/dev/null
    chmod 600 "${dir}/root.key.pem"
}

ensure_default_root() {
    [ -f "${ROOT_DIR}/${DEFAULT_ROOT}/root.crt" ] && return
    echo "未找到默认根证书，正在生成 ${DEFAULT_ROOT} ..."
    parse_duration "2099-12-31"
    create_root "${ROOT_DIR}/${DEFAULT_ROOT}" CN Shanghai Shanghai Default "Default ROOT CA" "$DAYS"
}

new_root() {
    local c st l o cn
    echo
    echo "== 新建根证书 =="
    while true; do
        ask o "组织名称 (O)"
        [ -n "$o" ] && break
    done
    ask c  "国家代码 (C)" "CN"
    ask st "省份 (ST)" "Shanghai"
    ask l  "城市 (L)" "Shanghai"
    ask cn "通用名称 (CN)" "${o} ROOT CA"
    ask_duration "根证书时长" "2099-12-31"

    local dir
    dir="$(unique_dir "${ROOT_DIR}/$(safe_name "$o")-${END_DATE}")"
    create_root "$dir" "$c" "$st" "$l" "$o" "$cn" "$DAYS"
    echo "根证书已生成: ${dir#"$BASE"/}"
    ROOT_PATH="$dir"
}

select_root() {
    local roots=() d i choice
    for d in "${ROOT_DIR}"/*/; do
        [ -f "${d}root.crt" ] && [ -f "${d}root.key.pem" ] && roots+=("${d%/}")
    done

    echo
    echo "== 选择根证书 =="
    i=1
    for d in "${roots[@]}"; do
        local mark=""
        openssl x509 -in "${d}/root.crt" -noout -checkend 0 >/dev/null || mark="  [已过期]"
        printf "  %d) %-32s %s%s\n" "$i" "$(basename "$d")" "$(cert_subject_field "${d}/root.crt" commonName)" "$mark"
        i=$((i + 1))
    done
    echo "  0) 新建根证书"

    while true; do
        ask choice "请选择" "1"
        if [ "$choice" = "0" ]; then
            new_root
            return
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#roots[@]}" ]; then
            ROOT_PATH="${roots[$((choice - 1))]}"
            return
        fi
        echo "  无效选择"
    done
}

# ---------- 网站证书 ----------

issue_cert() {
    local input domains=() san="" d
    echo
    echo "== 签发网站证书（根证书: $(basename "$ROOT_PATH")）=="
    while true; do
        ask input "域名或 IP（多个用空格或逗号分隔，如 example.com *.example.com 127.0.0.1）"
        # shellcheck disable=SC2206
        domains=(${input//,/ })
        [ "${#domains[@]}" -gt 0 ] && break
    done

    for d in "${domains[@]}"; do
        if [[ "$d" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "$d" =~ ^[0-9a-fA-F:]+$ && "$d" == *:* ]]; then
            san+="IP:${d},"
        else
            san+="DNS:${d},"
        fi
    done
    san="${san%,}"

    ask_duration "证书时长" "2y"
    if [ "$DAYS" -gt 825 ]; then
        echo "  提示: 超过 825 天的证书在 macOS/iOS 上不被信任"
    fi

    local tomcat_pass
    ask tomcat_pass "Tomcat 证书密码" "changeit"

    local main="${domains[0]}" name dir
    name="$(safe_name "$main")"
    dir="$(unique_dir "${CERT_DIR}/${name}-${END_DATE}")"
    mkdir -p "$dir"

    local key="${dir}/${name}.key.pem" csr="${dir}/${name}.csr.pem" crt="${dir}/${name}.crt"
    local root_crt="${ROOT_PATH}/root.crt" root_key="${ROOT_PATH}/root.key.pem"
    local org
    org="$(cert_subject_field "$root_crt" organizationName)"
    EXT_FILE="$(mktemp)"
    trap 'rm -f "$EXT_FILE"' EXIT

    cat > "$EXT_FILE" <<EOF
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
subjectAltName = ${san}
EOF

    openssl genrsa -out "$key" 2048 2>/dev/null
    chmod 600 "$key"
    openssl req -new -sha256 -key "$key" -out "$csr" -subj "/O=${org:-Default}/CN=${main}"
    openssl x509 -req -sha256 -in "$csr" -days "$DAYS" \
        -CA "$root_crt" -CAkey "$root_key" \
        -set_serial "0x$(openssl rand -hex 16)" \
        -extfile "$EXT_FILE" -out "$crt" 2>/dev/null
    rm -f "$csr"

    cp "$root_crt" "${dir}/root.crt"
    cert_info "$root_crt" "根证书" "$(basename "$ROOT_PATH")" > "${dir}/root.txt"
    cert_info "$crt" "网站证书" "$(basename "$dir")" "$san" > "${dir}/${name}.txt"
    cat "$crt" "$root_crt" > "${dir}/${name}.bundle.crt"

    # Tomcat: PKCS12（Tomcat 8.5+ / Java 8u301+ 直接使用），有 keytool 时额外生成 JKS
    openssl pkcs12 -export -name tomcat \
        -in "$crt" -inkey "$key" -certfile "$root_crt" \
        -out "${dir}/${name}.p12" -passout "pass:${tomcat_pass}"
    if keytool -help >/dev/null 2>&1; then
        keytool -importkeystore -noprompt \
            -srckeystore "${dir}/${name}.p12" -srcstoretype PKCS12 -srcstorepass "$tomcat_pass" \
            -destkeystore "${dir}/${name}.jks" -deststoretype JKS \
            -deststorepass "$tomcat_pass" -destkeypass "$tomcat_pass" >/dev/null 2>&1 \
            || echo "  提示: JKS 生成失败，可直接使用 .p12"
    fi

    cat > "${dir}/tomcat.txt" <<EOF
Tomcat server.xml 配置示例（alias: tomcat，密码: ${tomcat_pass}）

<Connector port="8443" protocol="org.apache.coyote.http11.Http11NioProtocol"
           maxThreads="150" SSLEnabled="true">
    <SSLHostConfig>
        <Certificate certificateKeystoreFile="conf/${name}.p12"
                     certificateKeystoreType="PKCS12"
                     certificateKeystorePassword="${tomcat_pass}" />
    </SSLHostConfig>
</Connector>

使用 JKS 时将 certificateKeystoreFile 改为 conf/${name}.jks，certificateKeystoreType 改为 JKS。
EOF

    echo
    echo "网站证书已生成: ${dir#"$BASE"/}"
    echo "  SAN: ${san}"
    echo "  到期: $(cert_enddate "$crt")"
    echo
    ls -l "$dir"
}

# ---------- 主流程 ----------

command -v openssl >/dev/null || die "需要安装 openssl"
mkdir -p "$ROOT_DIR" "$CERT_DIR"
ensure_default_root
select_root
issue_cert
