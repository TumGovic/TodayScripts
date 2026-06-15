#!/usr/bin/env bash
# xraychain.sh v3.2 (sing-box core)
# inbound: VLESS Reality -> outbound: ss:// or vless:// (ONLY)
#
# ВАЖНО:
# - JSON sing-box генерируется только jq (без cat/heredoc для JSON)
# - state: /etc/xraychain (root-only)
# - config: /etc/sing-box/xraychain/config.json
# - systemd: xraychain.service

set -eEuo pipefail

########################################
# Константы / Пути
########################################
readonly SCRIPT_NAME="xraychain"
readonly SCRIPT_VERSION="3.2"

readonly STATE_DIR="/etc/xraychain"
readonly STATE_FILE="${STATE_DIR}/config.conf"
readonly CLIENTS_DB="${STATE_DIR}/clients.db"

readonly SB_BIN_DEFAULT="/usr/local/bin/sing-box"
readonly SB_CONFIG_ROOT="/etc/sing-box"
readonly SB_CONFIG_DIR="${SB_CONFIG_ROOT}/xraychain"
readonly SB_CONFIG_FILE="${SB_CONFIG_DIR}/config.json"

readonly SERVICE_NAME="xraychain"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

readonly SERVICE_USER="xraychain"
readonly SERVICE_GROUP="xraychain"

readonly REQUIRED_DEPS=(curl jq)
readonly OPTIONAL_DEPS=(qrencode)

########################################
# Цвета
########################################
if [[ -t 1 ]]; then
  readonly RED='\033[0;31m'
  readonly GREEN='\033[0;32m'
  readonly YELLOW='\033[1;33m'
  readonly BLUE='\033[0;34m'
  readonly NC='\033[0m'
else
  readonly RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

########################################
# Логирование
########################################
log_info(){ echo -e "${BLUE}[ИНФО]${NC} ${1:-}"; }
log_success(){ echo -e "${GREEN}[OK]${NC} ${1:-}"; }
log_warning(){ echo -e "${YELLOW}[ПРЕДУПРЕЖДЕНИЕ]${NC} ${1:-}"; }
log_error(){ echo -e "${RED}[ОШИБКА]${NC} ${1:-}" >&2; }
die(){ log_error "${1:-}"; exit "${2:-1}"; }

########################################
# Трап ошибок
########################################
on_err() {
  local exit_code=$?
  local line_no=${BASH_LINENO[0]:-}
  local cmd=${BASH_COMMAND:-}
  log_error "Сбой (код=${exit_code}) на строке ${line_no}: ${cmd}"
  exit "$exit_code"
}
trap on_err ERR

########################################
# Утилиты
########################################
have_cmd(){ command -v "$1" >/dev/null 2>&1; }

check_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Нужно запустить от root"
}

trim_ws() {
  local s="${1:-}"
  s="$(echo "$s" | sed -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//')"
  printf '%s' "$s"
}

########################################
# Интерактивный ввод (с дефолтом)
########################################
# Пример: prompt_default "Порт" "443" varname
prompt_default() {
  local prompt="${1:-}" default="${2:-}" __var="${3:-}"
  [[ -n "$__var" ]] || die "prompt_default: не задано имя переменной"

  local ans=""
  if [[ -n "$default" ]]; then
    echo -n "${prompt} [${default}]: "
  else
    echo -n "${prompt}: "
  fi
  IFS= read -r ans || die "Ввод прерван"
  ans="$(trim_ws "$ans")"
  if [[ -z "$ans" ]]; then
    ans="$default"
  fi
  printf -v "$__var" '%s' "$ans"
}

# Обязательное поле: если пусто — повторяем вопрос (Enter принимает дефолт, если он есть)
prompt_required() {
  local prompt="${1:-}" default="${2:-}" __var="${3:-}" hint="${4:-}"
  while true; do
    [[ -n "$hint" ]] && echo "$hint"
    prompt_default "$prompt" "$default" "$__var"
    # shellcheck disable=SC2154
    local val="${!__var:-}"
    val="$(trim_ws "$val")"
    printf -v "$__var" '%s' "$val"
    [[ -n "$val" ]] && return 0
    log_warning "Поле обязательно. Нажми Enter только если подсказка заполнена."
  done
}


# URL decode (НЕ превращаем '+' в пробел)
url_decode() {
  local s="${1:-}"
  printf '%b' "${s//%/\\x}"
}

url_encode() {
  local s="${1:-}"
  local out="" i c hex
  for ((i=0; i<${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
    esac
  done
  printf '%s' "$out"
}

# relaxed base64 decode (base64url + no padding).
# mod4==1 => битая строка (нельзя исправить padding'ом)
b64_decode_relaxed() {
  local in="${1:-}"
  in="$(trim_ws "$in")"
  [[ -n "$in" ]] || return 1

  local s="$in"
  s="${s//-/+}"
  s="${s//_/\/}"

  local mod=$(( ${#s} % 4 ))
  if (( mod == 2 )); then s+="=="
  elif (( mod == 3 )); then s+="="
  elif (( mod == 1 )); then
    return 2
  fi

  printf '%s' "$s" | base64 -d 2>/dev/null
}

detect_pkg_manager() {
  if have_cmd apt-get; then echo apt
  elif have_cmd dnf; then echo dnf
  elif have_cmd yum; then echo yum
  elif have_cmd pacman; then echo pacman
  elif have_cmd apk; then echo apk
  else echo unknown
  fi
}

install_packages() {
  local pm
  pm="$(detect_pkg_manager)"
  case "$pm" in
    apt)
      apt-get update -y
      DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
      ;;
    dnf) dnf install -y "$@";;
    yum) yum install -y "$@";;
    pacman) pacman -Sy --noconfirm "$@";;
    apk) apk add --no-cache "$@";;
    *) die "Неизвестный пакетный менеджер. Установи вручную: $*";;
  esac
}

check_dependencies() {
  local missing=()
  for d in "${REQUIRED_DEPS[@]}"; do
    have_cmd "$d" || missing+=("$d")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_info "Ставлю зависимости: ${missing[*]}"
    install_packages "${missing[@]}" || die "Не удалось установить зависимости: ${missing[*]}"
  fi

  local opt_missing=()
  for d in "${OPTIONAL_DEPS[@]}"; do
    have_cmd "$d" || opt_missing+=("$d")
  done
  if [[ ${#opt_missing[@]} -gt 0 ]]; then
    log_warning "Опционально можно установить: ${opt_missing[*]} (для QR-кодов)"
  fi

  have_cmd jq || die "jq обязателен, но не найден и/или не удалось установить"
}

ensure_user_group() {
  if ! getent group "$SERVICE_GROUP" >/dev/null 2>&1; then
    log_info "Создаю группу: ${SERVICE_GROUP}"
    groupadd --system "$SERVICE_GROUP"
  fi
  if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    log_info "Создаю пользователя: ${SERVICE_USER}"
    useradd --system --gid "$SERVICE_GROUP" --home-dir /var/lib/"$SERVICE_USER" --create-home \
      --shell /usr/sbin/nologin "$SERVICE_USER"
  fi
}

ensure_dirs() {
  install -d -m 700 -o root -g root "$STATE_DIR"
  install -d -m 750 -o root -g "$SERVICE_GROUP" "$SB_CONFIG_ROOT"
  install -d -m 750 -o root -g "$SERVICE_GROUP" "$SB_CONFIG_DIR"
}

write_state_kv() {
  # НЕ пишем SCRIPT_VERSION (он readonly). Пишем STATE_SCRIPT_VERSION.
  local tmp
  tmp="$(mktemp)"
  umask 077
  {
    printf 'STATE_SCRIPT_VERSION=%q\n' "$SCRIPT_VERSION"
    printf 'SB_BIN=%q\n' "${SB_BIN:-$SB_BIN_DEFAULT}"
    printf 'SERVER_ADDR=%q\n' "${SERVER_ADDR:-}"
    printf 'VLESS_PORT=%q\n' "${VLESS_PORT:-}"
    printf 'REALITY_SNI=%q\n' "${REALITY_SNI:-}"
    printf 'REALITY_DEST=%q\n' "${REALITY_DEST:-}"
    printf 'PRIVATE_KEY=%q\n' "${PRIVATE_KEY:-}"
    printf 'PUBLIC_KEY=%q\n' "${PUBLIC_KEY:-}"
    printf 'SHORT_ID=%q\n' "${SHORT_ID:-}"
    printf 'FLOW=%q\n' "${FLOW:-}"
    printf 'FINGERPRINT=%q\n' "${FINGERPRINT:-}"
    printf 'OUTBOUND_URI=%q\n' "${OUTBOUND_URI:-}"
  } > "$tmp"
  mv "$tmp" "$STATE_FILE"
  chmod 600 "$STATE_FILE"
  chown root:root "$STATE_FILE"
}

load_state() {
  [[ -f "$STATE_FILE" ]] || die "Не установлен. Сначала: ${SCRIPT_NAME} install"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  : "${SB_BIN:=${SB_BIN_DEFAULT}}"
}

########################################
# sing-box install/upgrade
########################################
detect_arch() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "armv7" ;;
    armv6l|armv6) echo "armv6" ;;
    i386|i686) echo "386" ;;
    *) die "Неизвестная архитектура: $arch" ;;
  esac
}

install_singbox() {
  local sb_bin="${SB_BIN:-$SB_BIN_DEFAULT}"

  if [[ -x "$sb_bin" ]]; then
    log_info "sing-box уже установлен: $sb_bin"
    return 0
  fi

  log_info "Устанавливаю sing-box (GitHub Releases) ..."

  local arch os version tag asset url tmpdir
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  [[ "$os" == "linux" ]] || die "Поддерживается только Linux (обнаружено: $os)"
  arch="$(detect_arch)"

  tag="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name')"
  [[ -n "$tag" && "$tag" != "null" ]] || die "Не удалось получить версию sing-box из GitHub API"
  version="${tag#v}"

  asset="sing-box-${version}-${os}-${arch}.tar.gz"
  url="https://github.com/SagerNet/sing-box/releases/download/${tag}/${asset}"

  tmpdir="$(mktemp -d)"
  (
    cd "$tmpdir"
    curl -fL --retry 3 --retry-delay 1 -o "$asset" "$url"
    tar -xzf "$asset"
    local extracted
    extracted="$(find . -type f -name sing-box -perm -111 | head -n1)"
    [[ -n "$extracted" ]] || die "Не нашёл бинарник sing-box в архиве"
    install -m 0755 "$extracted" "$sb_bin"
  )
  rm -rf "$tmpdir"

  log_success "sing-box установлен: $sb_bin"
}

########################################
# Генерация ключей/UUID
########################################
generate_uuid() {
  if have_cmd "${SB_BIN:-$SB_BIN_DEFAULT}" && "${SB_BIN:-$SB_BIN_DEFAULT}" generate uuid >/dev/null 2>&1; then
    "${SB_BIN:-$SB_BIN_DEFAULT}" generate uuid
    return 0
  fi
  cat /proc/sys/kernel/random/uuid
}

generate_short_id() {
  od -An -N8 -tx1 /dev/urandom | tr -d ' \n'
}

parse_dest() {
  local d
  d="$(trim_ws "${1:-}")"
  if [[ "$d" =~ ^\[(.+)\]:([0-9]+)$ ]]; then
    echo "${BASH_REMATCH[1]}|${BASH_REMATCH[2]}"
    return 0
  fi
  if [[ "$d" =~ ^([^:]+):([0-9]+)$ ]]; then
    echo "${BASH_REMATCH[1]}|${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

generate_reality_keypair() {
  local sb="${SB_BIN:-$SB_BIN_DEFAULT}"
  [[ -x "$sb" ]] || die "sing-box не найден: $sb"

  local out priv pub
  out="$("$sb" generate reality-keypair 2>/dev/null)" || die "Не удалось: sing-box generate reality-keypair"

  priv="$(echo "$out" | awk -F': ' '/Private(Key)?/ {print $2; exit}')"
  pub="$(echo "$out" | awk -F': ' '/Public(Key)?/ {print $2; exit}')"
  [[ -n "$priv" && -n "$pub" ]] || die "Не удалось распарсить Reality keypair"
  echo "$priv|$pub"
}

########################################
# Парсинг query параметров
########################################
query_get() {
  local qs="${1:-}" key="${2:-}"
  local pair k v
  IFS='&' read -r -a __pairs <<< "$qs"
  for pair in "${__pairs[@]}"; do
    [[ -z "$pair" ]] && continue
    if [[ "$pair" == *"="* ]]; then
      k="${pair%%=*}"
      v="${pair#*=}"
    else
      k="$pair"
      v=""
    fi
    k="$(url_decode "$k")"
    if [[ "$k" == "$key" ]]; then
      echo "$(url_decode "$v")"
      return 0
    fi
  done
  return 1
}

parse_bool() {
  local v
  v="$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "$v" in
    1|true|yes|y|on) echo "true" ;;
    *) echo "false" ;;
  esac
}

split_csv_to_json_array() {
  local s="${1:-}"
  if [[ -z "$s" ]]; then
    echo '[]'
    return 0
  fi
  jq -c -n --arg s "$s" '$s|split(",")|map(select(length>0))'
}

########################################
# URI helpers
########################################
sanitize_uri_input() {
  local input="${1:-}"
  local line
  while IFS= read -r line; do
    line="$(trim_ws "$line")"
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue
    if [[ "$line" =~ ^(ss|vless):// ]]; then
      echo "$line"
      return 0
    fi
  done <<< "$input"
  return 1
}

parse_std_uri() {
  # scheme://userinfo@host:port/path?query#fragment
  local uri="${1:-}"
  local rest fragment query authority userinfo hostport host port

  rest="${uri#*://}"

  fragment=""
  if [[ "$rest" == *"#"* ]]; then
    fragment="${rest#*#}"
    rest="${rest%%#*}"
  fi

  query=""
  if [[ "$rest" == *"?"* ]]; then
    query="${rest#*?}"
    rest="${rest%%\?*}"
  fi

  authority="$rest"
  if [[ "$authority" == *"/"* ]]; then
    authority="${authority%%/*}"
  fi

  userinfo=""
  hostport="$authority"
  if [[ "$authority" == *"@"* ]]; then
    userinfo="${authority%%@*}"
    hostport="${authority#*@}"
  fi
  userinfo="$(url_decode "$userinfo")"

  host=""
  port=""
  if [[ "$hostport" =~ ^\[(.+)\]:(.+)$ ]]; then
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
  elif [[ "$hostport" == *":"* ]]; then
    host="${hostport%:*}"
    port="${hostport##*:}"
  else
    host="$hostport"
  fi

  echo "$userinfo|$host|$port|$query|$fragment"
}

########################################
# TLS + Transport builders (jq only)
########################################
build_transport_json() {
  local t="${1:-}" path="${2:-}" host="${3:-}" service_name="${4:-}" headers_json="${5:-}"

  case "$t" in
    ""|tcp|none)
      echo "null"
      ;;
    ws|websocket)
      jq -c -n \
        --arg path "$path" \
        --arg host "$host" \
        --argjson extra "${headers_json:-null}" '
        ({
          type: "ws",
          path: ($path // "")
        }
        + (if ($host|length)>0 then {headers: {"Host": $host}} else {} end))
        + (if $extra != null then {headers: (.headers // {} ) + $extra} else {} end)
      '
      ;;
    grpc)
      jq -c -n --arg sn "$service_name" '
        {
          type: "grpc",
          service_name: $sn
        }
      '
      ;;
    httpupgrade)
      jq -c -n \
        --arg host "$host" \
        --arg path "$path" \
        --argjson extra "${headers_json:-null}" '
        ({
          type: "httpupgrade",
          host: $host,
          path: ($path // "")
        }
        + (if $extra != null then {headers: $extra} else {} end))
      '
      ;;
    http)
      jq -c -n \
        --arg host "$host" \
        --arg path "$path" \
        --argjson extra "${headers_json:-null}" '
        ({
          type: "http",
          host: (if ($host|length)>0 then [$host] else [] end),
          path: ($path // "")
        }
        + (if $extra != null then {headers: $extra} else {} end))
      '
      ;;
    *)
      die "Неподдерживаемый transport type: $t"
      ;;
  esac
}

build_tls_outbound_json() {
  local mode="${1:-}" sni="${2:-}" insecure="${3:-false}" alpn_csv="${4:-}" fp="${5:-}" pbk="${6:-}" sid="${7:-}"

  if [[ -z "$mode" || "$mode" == "none" ]]; then
    echo "null"
    return 0
  fi

  local alpn_json
  alpn_json="$(split_csv_to_json_array "$alpn_csv")"

  jq -c -n \
    --arg sni "$sni" \
    --argjson insecure "$insecure" \
    --argjson alpn "$alpn_json" \
    --arg fp "$fp" \
    --arg mode "$mode" \
    --arg pbk "$pbk" \
    --arg sid "$sid" '
    (
      {
        enabled: true
      }
      + (if ($sni|length)>0 then {server_name: $sni} else {} end)
      + (if $insecure == true then {insecure: true} else {} end)
      + (if ($alpn|length)>0 then {alpn: $alpn} else {} end)
      + (if ($fp|length)>0 then {utls: {enabled: true, fingerprint: $fp}} else {} end)
    )
    + (if $mode == "reality" then
        {reality: {enabled: true, public_key: $pbk, short_id: $sid}}
      else
        {}
      end)
  '
}

build_tls_inbound_reality_json() {
  local dest_host="${1:-}" dest_port="${2:-}" priv="${3:-}" sid="${4:-}" server_name="${5:-}"
  jq -c -n \
    --arg dest_host "$dest_host" \
    --argjson dest_port "$dest_port" \
    --arg priv "$priv" \
    --arg sid "$sid" \
    --arg sni "$server_name" '
    {
      enabled: true
    }
    + (if ($sni|length)>0 then {server_name: $sni} else {} end)
    + {
      reality: {
        enabled: true,
        handshake: { server: $dest_host, server_port: $dest_port },
        private_key: $priv,
        short_id: $sid
      }
    }
  '
}

########################################
# Outbound парсинг: ss:// и vless://
########################################

# headers=... иногда приходит как python-dict в одинарных кавычках
# Пытаемся привести к JSON объекту. Если не вышло — вернём null.
try_parse_headers_param_to_json() {
  local raw="${1:-}"
  raw="$(trim_ws "$raw")"
  [[ -n "$raw" ]] || { echo "null"; return 0; }

  # {'A':'B'} -> {"A":"B"}
  local candidate
  candidate="$(printf '%s' "$raw" | sed "s/'/\"/g")"

  if echo "$candidate" | jq -e -c 'fromjson | (type=="object")' >/dev/null 2>&1; then
    echo "$candidate" | jq -c 'fromjson'
    return 0
  fi

  echo "null"
}

# Поддержка:
# 1) ss://BASE64(method:password)@host:port#name
# 2) ss://method:password@host:port#name
# 3) ss://BASE64(method:password@host:port)#name (без @ в URI)
parse_ss_url() {
  local url="$1"
  [[ "$url" == ss://* ]] || die "Не ss://"

  local rest="${url#ss://}"
  local fragment="" query="" before_q

  before_q="$rest"
  if [[ "$before_q" == *"#"* ]]; then
    fragment="${before_q#*#}"
    before_q="${before_q%%#*}"
  fi
  if [[ "$before_q" == *"?"* ]]; then
    query="${before_q#*?}"
    before_q="${before_q%%\?*}"
  fi

  local auth_and_server="$before_q"
  local auth_part="" server_part=""

  if [[ "$auth_and_server" == *"@"* ]]; then
    auth_part="${auth_and_server%%@*}"
    server_part="${auth_and_server#*@}"
  else
    auth_part="$auth_and_server"
    server_part=""
  fi

  local method="" password="" host="" port=""

  if [[ "$auth_part" == *":"* ]]; then
    method="${auth_part%%:*}"
    password="${auth_part#*:}"
  else
    local decoded
    if decoded="$(b64_decode_relaxed "$auth_part")"; then
      :
    else
      local rc=$?
      if [[ $rc -eq 2 ]]; then
        die "ss:// base64-часть некорректна (длина mod4==1). Ссылка повреждена/обрезана: $auth_part"
      fi
      die "Не удалось декодировать ss:// base64. Проверь ссылку."
    fi

    if [[ "$decoded" == *"@"* ]]; then
      local left="${decoded%%@*}"
      local right="${decoded#*@}"
      method="${left%%:*}"
      password="${left#*:}"
      server_part="$right"
    else
      method="${decoded%%:*}"
      password="${decoded#*:}"
    fi
  fi

  method="$(url_decode "$method")"
  password="$(url_decode "$password")"

  [[ -n "$server_part" ]] || die "ss:// не содержит host:port (после @) и не зашит внутри base64"

  if [[ "$server_part" =~ ^\[(.+)\]:(.+)$ ]]; then
    host="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[2]}"
  else
    host="${server_part%%:*}"; port="${server_part#*:}"
  fi

  [[ -n "$method" && -n "$password" && -n "$host" && -n "$port" ]] || die "Не удалось распарсить ss://"
  [[ "$port" =~ ^[0-9]+$ ]] || die "Порт ss:// не число: $port"

  echo "$method|$password|$host|$port|$query|$fragment"
}

parse_outbound_ss() {
  local uri="$1"
  local info method password host port query fragment
  info="$(parse_ss_url "$uri")"
  IFS='|' read -r method password host port query fragment <<< "$info"

  jq -c -n \
    --arg host "$host" \
    --argjson port "$port" \
    --arg method "$method" \
    --arg password "$password" '
    {
      type: "shadowsocks",
      tag: "chain-out",
      server: $host,
      server_port: $port,
      method: $method,
      password: $password
    }
  '
}

parse_outbound_vless() {
  local uri="$1"
  local info userinfo host port query fragment
  info="$(parse_std_uri "$uri")"
  IFS='|' read -r userinfo host port query fragment <<< "$info"
  [[ -n "$userinfo" ]] || die "vless:// без UUID (userinfo)"

  local flow security sni pbk sid fp alpn insecure ttype path thost service_name
  flow="$(query_get "$query" "flow" || true)"
  security="$(query_get "$query" "security" || true)"
  sni="$(query_get "$query" "sni" || true)"
  pbk="$(query_get "$query" "pbk" || true)"
  sid="$(query_get "$query" "sid" || true)"
  fp="$(query_get "$query" "fp" || true)"
  alpn="$(query_get "$query" "alpn" || true)"
  insecure="$(parse_bool "$(query_get "$query" "allowInsecure" || query_get "$query" "insecure" || true)")"

  ttype="$(query_get "$query" "type" || true)"
  path="$(query_get "$query" "path" || true)"
  thost="$(query_get "$query" "host" || true)"
  service_name="$(query_get "$query" "serviceName" || true)"

  local headers_param headers_json
  headers_param="$(query_get "$query" "headers" || true)"
  headers_json="$(try_parse_headers_param_to_json "$headers_param")"

  local tls_mode=""
  if [[ "$security" == "reality" ]]; then tls_mode="reality"
  elif [[ "$security" == "tls" ]]; then tls_mode="tls"
  else tls_mode=""
  fi

  local tls_json transport_json
  tls_json="$(build_tls_outbound_json "$tls_mode" "${sni:-$host}" "$insecure" "$alpn" "$fp" "$pbk" "$sid")"
  transport_json="$(build_transport_json "$ttype" "$path" "${thost:-}" "${service_name:-}" "$headers_json")"

  jq -c -n \
    --arg host "$host" \
    --argjson port "$port" \
    --arg uuid "$userinfo" \
    --arg flow "$flow" \
    --argjson tls "$tls_json" \
    --argjson transport "$transport_json" '
    {
      type: "vless",
      tag: "chain-out",
      server: $host,
      server_port: $port,
      uuid: $uuid
    }
    + (if ($flow|length)>0 then {flow: $flow} else {} end)
    + (if $tls != null then {tls: $tls} else {} end)
    + (if $transport != null then {transport: $transport} else {} end)
  '
}

parse_outbound_uri() {
  local raw="${1:-}"
  [[ -n "$raw" ]] || die "Пустая ссылка outbound"

  local uri
  uri="$(sanitize_uri_input "$raw" || true)"
  [[ -n "$uri" ]] || die "Не нашёл поддерживаемую ссылку в вводе (только ss:// и vless://)"

  local scheme="${uri%%://*}"
  case "$scheme" in
    ss)    parse_outbound_ss "$uri" ;;
    vless) parse_outbound_vless "$uri" ;;
    *) die "Неподдерживаемая схема outbound: $scheme (только ss:// и vless://)" ;;
  esac
}

########################################
# sing-box config (jq only)
########################################
build_users_json_from_db() {
  [[ -f "$CLIENTS_DB" ]] || { echo '[]'; return 0; }
  load_state >/dev/null 2>&1 || true

  local flow="${FLOW:-}"
  jq -c -R -s --arg flow "$flow" '
    [ split("\n")[]
      | select(length>0)
      | split(";")
      | select(length>=2 and (.[0]|length)>0 and (.[1]|length)>0)
      | ({name: .[0], uuid: .[1]}
         + (if (($flow|tostring)|length)>0 then {flow: ($flow|tostring)} else {} end)
        )
    ]
  ' "$CLIENTS_DB"
}

build_inbound_json() {
  local users_json="$1"

  local dest_host dest_port
  IFS='|' read -r dest_host dest_port <<< "$(parse_dest "${REALITY_DEST:-}" || true)"
  [[ -n "${dest_host:-}" && -n "${dest_port:-}" ]] || die "Некорректный REALITY_DEST: ${REALITY_DEST:-}"

  local tls_json
  tls_json="$(build_tls_inbound_reality_json "$dest_host" "$dest_port" "${PRIVATE_KEY:-}" "${SHORT_ID:-}" "${REALITY_SNI:-}")"

  jq -c -n \
    --arg listen "0.0.0.0" \
    --argjson port "${VLESS_PORT}" \
    --argjson users "$users_json" \
    --argjson tls "$tls_json" '
    {
      type: "vless",
      tag: "vless-in",
      listen: $listen,
      listen_port: $port,
      users: $users,
      tls: $tls
    }
  '
}

build_outbounds_json() {
  local chain_out_json="$1"
  jq -c -n --argjson chain "$chain_out_json" '
    [
      {type:"direct", tag:"direct"},
      {type:"block", tag:"block"},
      $chain
    ]
  '
}

build_route_json() {
  jq -c -n '
    {
      rules: [
        {
          inbound: ["vless-in"],
          action: "sniff",
          sniffer: ["http","tls","quic"]
        },
        {
          inbound: ["vless-in"],
          action: "route",
          outbound: "chain-out"
        }
      ],
      final: "direct"
    }
  '
}

build_log_json() {
  jq -c -n '
    {
      level: "warn",
      timestamp: true
    }
  '
}

render_singbox_config() {
  load_state

  [[ -n "${VLESS_PORT:-}" ]] || die "VLESS_PORT не задан"
  [[ -n "${REALITY_DEST:-}" ]] || die "REALITY_DEST не задан"
  [[ -n "${PRIVATE_KEY:-}" ]] || die "PRIVATE_KEY не задан"
  [[ -n "${SHORT_ID:-}" ]] || die "SHORT_ID не задан"
  [[ -n "${OUTBOUND_URI:-}" ]] || die "OUTBOUND_URI не задан"

  local chain_out_json users_json inbound_json inbounds_json outbounds_json route_json log_json
  chain_out_json="$(parse_outbound_uri "$OUTBOUND_URI")"
  users_json="$(build_users_json_from_db)"
  inbound_json="$(build_inbound_json "$users_json")"
  inbounds_json="$(jq -c -n --argjson inbound "$inbound_json" '[ $inbound ]')"
  outbounds_json="$(build_outbounds_json "$chain_out_json")"
  route_json="$(build_route_json)"
  log_json="$(build_log_json)"

  local tmp prev
  tmp="$(mktemp)"
  prev=""
  if [[ -f "$SB_CONFIG_FILE" ]]; then
    prev="${SB_CONFIG_FILE}.$(date +%Y%m%d-%H%M%S).bak"
    cp -a "$SB_CONFIG_FILE" "$prev"
  fi

  jq -n \
    --argjson log "$log_json" \
    --argjson inbounds "$inbounds_json" \
    --argjson outbounds "$outbounds_json" \
    --argjson route "$route_json" '
    {
      log: $log,
      inbounds: $inbounds,
      outbounds: $outbounds,
      route: $route
    }
  ' > "$tmp"

  local check_out=""
  if check_out="$("${SB_BIN:-$SB_BIN_DEFAULT}" check -c "$tmp" 2>&1)"; then
    :
  else
    log_error "sing-box: конфиг не прошёл проверку: ${SB_BIN:-$SB_BIN_DEFAULT} check -c ${tmp}"
    log_error "Вывод sing-box check:"
    echo "$check_out" >&2
    log_error "Полный конфиг (для диагностики):"
    cat "$tmp" >&2
    if [[ -n "$prev" ]]; then
      log_warning "Откат на бэкап: $prev"
      cp -a "$prev" "$SB_CONFIG_FILE" || true
    fi
    rm -f "$tmp"
    die "Остановка: некорректный JSON конфиг"
  fi

  mv "$tmp" "$SB_CONFIG_FILE"
  chown root:"$SERVICE_GROUP" "$SB_CONFIG_FILE"
  chmod 640 "$SB_CONFIG_FILE"

  log_success "Конфиг sing-box обновлён: $SB_CONFIG_FILE"
}

########################################
# systemd управление сервисом
########################################
ensure_systemd() {
  have_cmd systemctl || die "systemd (systemctl) не найден"
}

install_service_unit() {
  ensure_systemd
  ensure_user_group
  ensure_dirs

  local sb="${SB_BIN:-$SB_BIN_DEFAULT}"
  [[ -x "$sb" ]] || die "sing-box binary не найден/не исполняемый: $sb"
  [[ -f "$SB_CONFIG_FILE" ]] || die "config.json не найден: $SB_CONFIG_FILE (сначала сгенерируй конфиг)"

  local marker="XrayChain (sing-box)"
  local need_write=1
  if [[ -f "$SERVICE_FILE" ]]; then
    if grep -q "$marker" "$SERVICE_FILE" 2>/dev/null; then
      need_write=0
    else
      log_warning "Существующий ${SERVICE_FILE} не принадлежит скрипту. Перезапишу."
      need_write=1
    fi
  fi

  if (( need_write == 1 )); then
    log_info "Пишу systemd unit: $SERVICE_FILE"
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=${marker}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}

AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

ExecStart=${sb} run -c ${SB_CONFIG_FILE}
ExecReload=/bin/kill -HUP \$MAINPID

StandardOutput=null
StandardError=null

Restart=on-failure
RestartSec=2
LimitNOFILE=1048576

PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

StateDirectory=${SERVICE_NAME}
LogsDirectory=${SERVICE_NAME}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
  fi

  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
}

service_is_active() {
  systemctl is-active --quiet "$SERVICE_NAME"
}

service_reload() {
  ensure_systemd
  if systemctl reload "$SERVICE_NAME" >/dev/null 2>&1; then
    log_success "Сервис перезагружен (reload): $SERVICE_NAME"
    return 0
  fi

  log_warning "Reload не сработал. Делаю start/restart."
  if service_is_active; then
    systemctl restart "$SERVICE_NAME"
    log_success "Сервис перезапущен (restart): $SERVICE_NAME"
  else
    systemctl start "$SERVICE_NAME"
    log_success "Сервис запущен (start): $SERVICE_NAME"
  fi
}

service_status() {
  ensure_systemd
  systemctl --no-pager status "$SERVICE_NAME" || true
}

########################################
# Клиенты
########################################
client_exists() {
  local name="$1"
  [[ -f "$CLIENTS_DB" ]] || return 1
  awk -F';' -v n="$name" '$1==n{found=1; exit} END{exit !found}' "$CLIENTS_DB"
}

get_client_uuid() {
  local name="$1"
  [[ -f "$CLIENTS_DB" ]] || return 1
  awk -F';' -v n="$name" '$1==n{print $2; exit}' "$CLIENTS_DB"
}

add_client() {
  local client_name="$1"
  client_name="$(trim_ws "$client_name")"
  [[ -n "$client_name" ]] || die "Имя клиента пустое"
  [[ "$client_name" != *";"* ]] || die "Имя не должно содержать ';'"

  if client_exists "$client_name"; then
    die "Клиент '$client_name' уже существует"
  fi

  local uuid
  uuid="$(generate_uuid)"

  echo "${client_name};${uuid}" >> "$CLIENTS_DB"
  chmod 600 "$CLIENTS_DB"
  chown root:root "$CLIENTS_DB"

  log_success "Клиент добавлен: $client_name"
}

remove_client() {
  local client_name="$1"
  client_name="$(trim_ws "$client_name")"
  [[ -n "$client_name" ]] || die "Имя клиента пустое"
  client_exists "$client_name" || die "Клиент '$client_name' не найден"

  local tmp
  tmp="$(mktemp)"
  awk -F';' -v n="$client_name" '$1!=n{print $0}' "$CLIENTS_DB" > "$tmp"
  mv "$tmp" "$CLIENTS_DB"
  chmod 600 "$CLIENTS_DB"
  chown root:root "$CLIENTS_DB"

  log_success "Клиент удалён: $client_name"
}

generate_vless_url() {
  local client_name="$1" uuid="$2"
  load_state

  local tag="XrayChain-$client_name"

  local server="$SERVER_ADDR"
  if [[ "$server" == *:* && "$server" != *.* ]]; then
    server="[$server]"
  fi

  local sni_enc fp_enc flow_enc pbk_enc sid_enc
  sni_enc="$(url_encode "$REALITY_SNI")"
  fp_enc="$(url_encode "${FINGERPRINT:-chrome}")"
  flow_enc="$(url_encode "${FLOW:-}")"
  pbk_enc="$(url_encode "$PUBLIC_KEY")"
  sid_enc="$(url_encode "$SHORT_ID")"

  local url="vless://${uuid}@${server}:${VLESS_PORT}?encryption=none&security=reality&sni=${sni_enc}&fp=${fp_enc}&pbk=${pbk_enc}&sid=${sid_enc}&type=tcp&headerType=none"
  [[ -n "${FLOW:-}" ]] && url+="&flow=${flow_enc}"
  url+="#$(url_encode "$tag")"

  echo "$url"
}

show_client_connection() {
  local client_name="$1"
  local uuid
  uuid="$(get_client_uuid "$client_name")"
  [[ -n "$uuid" ]] || die "Клиент '$client_name' не найден"

  local vless_url
  vless_url="$(generate_vless_url "$client_name" "$uuid")"

  echo
  echo "Клиент: $client_name"
  echo "UUID:   $uuid"
  echo
  echo "VLESS URI:"
  echo "$vless_url"
  echo

  if have_cmd qrencode; then
    echo "QR (для мобильных клиентов):"
    qrencode -t ANSIUTF8 "$vless_url" || true
    echo
  else
    log_warning "qrencode не установлен — QR не показываю"
  fi
}

list_clients() {
  [[ -f "$CLIENTS_DB" ]] || die "База клиентов не найдена"

  echo "┌─────┬──────────────────────────────────────┬──────────────────────────────────────┐"
  echo "│  №  │               Имя клиента            │                 UUID                 │"
  echo "├─────┼──────────────────────────────────────┼──────────────────────────────────────┤"
  local i=1
  while IFS=';' read -r n u; do
    [[ -z "${n:-}" ]] && continue
    printf "│ %3d │ %-36s │ %-36s │\n" "$i" "$n" "$u"
    i=$((i+1))
  done < "$CLIENTS_DB"
  echo "└─────┴──────────────────────────────────────┴──────────────────────────────────────┘"
}

########################################
# Команды
########################################
show_help() {
  cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION} (sing-box core)

Команды:
  install        Установка/настройка цепи (VLESS Reality inbound -> outbound по URI)
  add            Добавить клиента
  remove         Удалить клиента
  list           Список клиентов
  show [name]    Показать подключение клиента (URI + QR)
  update-out     Обновить outbound (ss:// или vless://)
  parse-out      Распарсить URI и показать JSON outbound (для отладки)
  status         Статус сервиса ${SERVICE_NAME}
  uninstall      Удалить сервис и конфиги xraychain (sing-box бинарник не трогаем)
  help           Эта справка

Поддерживаемые outbound URI (в этой версии):
  ss://, vless://

EOF
}

cmd_install() {
  check_root
  check_dependencies
  ensure_systemd
  ensure_user_group
  ensure_dirs

  local non_interactive="false"
  local server_addr="${XRAYCHAIN_SERVER_ADDR:-}"
  local vless_port="${XRAYCHAIN_VLESS_PORT:-}"
  local reality_sni="${XRAYCHAIN_REALITY_SNI:-}"
  local reality_dest="${XRAYCHAIN_REALITY_DEST:-}"
  local flow="${XRAYCHAIN_FLOW:-xtls-rprx-vision}"
  local fp="${XRAYCHAIN_FINGERPRINT:-chrome}"
  local outbound_uri="${XRAYCHAIN_OUTBOUND_URI:-}"
  local client_name="${XRAYCHAIN_CLIENT_NAME:-}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --non-interactive|--yes|-y) non_interactive="true"; shift ;;
      --server-addr) server_addr="${2:-}"; shift 2 ;;
      --vless-port) vless_port="${2:-}"; shift 2 ;;
      --reality-sni) reality_sni="${2:-}"; shift 2 ;;
      --reality-dest) reality_dest="${2:-}"; shift 2 ;;
      --flow) flow="${2:-}"; shift 2 ;;
      --fingerprint) fp="${2:-}"; shift 2 ;;
      --outbound-uri) outbound_uri="${2:-}"; shift 2 ;;
      --client-name) client_name="${2:-}"; shift 2 ;;
      *) break ;;
    esac
  done

  if [[ -z "$server_addr" ]]; then
    server_addr="$(curl -fsSL https://api.ipify.org 2>/dev/null || true)"
  fi

  # ДЕФОЛТЫ (как ты просил)
  [[ -n "$reality_sni" ]] || reality_sni="eh.vk.com"
  [[ -n "$reality_dest" ]] || reality_dest="eh.vk.com:443"

  if [[ "$non_interactive" != "true" ]]; then

# SERVER_ADDR обязателен (для генерации клиентской ссылки).
prompt_required "Публичный адрес сервера (SERVER_ADDR)" "${server_addr:-}" server_addr \
  "Можно IP или домен. (Если подсказка пустая — введи вручную.)"

# VLESS_PORT: Enter => дефолт (если переменная пустая — 443)
while true; do
  prompt_default "Порт inbound (VLESS_PORT)" "${vless_port:-443}" vless_port
  vless_port="$(trim_ws "$vless_port")"
  if [[ "$vless_port" =~ ^[0-9]+$ ]] && [[ "$vless_port" -ge 1 && "$vless_port" -le 65535 ]]; then
    break
  fi
  log_warning "VLESS_PORT должен быть числом в диапазоне 1-65535"
done

prompt_default "Reality SNI (REALITY_SNI)" "${reality_sni}" reality_sni

while true; do
  prompt_default "Reality DEST (REALITY_DEST host:port)" "${reality_dest}" reality_dest
  reality_dest="$(trim_ws "$reality_dest")"
  if parse_dest "$reality_dest" >/dev/null 2>&1; then
    break
  fi
  log_warning "REALITY_DEST должен быть в формате host:port (пример: example.com:443)"
done

prompt_default "Flow (FLOW)" "${flow}" flow
prompt_default "Fingerprint (FINGERPRINT)" "${fp}" fp

# OUTBOUND_URI обязателен. Если пользователь жмёт Enter на пустом — спрашиваем снова.
while true; do
  if [[ -z "${outbound_uri:-}" ]]; then
    echo "Вставь outbound URI (ss:// или vless://)."
  fi
  prompt_default "OUTBOUND_URI" "${outbound_uri:-}" outbound_uri
  outbound_uri="$(trim_ws "$outbound_uri")"
  [[ -n "$outbound_uri" ]] || { log_warning "OUTBOUND_URI обязателен"; continue; }

  # Валидируем парсером (в subshell, чтобы die() не убил установку)
  if ( parse_outbound_uri "$outbound_uri" >/dev/null ); then
    break
  fi
  log_warning "Ссылка outbound некорректна/неподдерживается (только ss:// и vless://). Попробуй ещё раз."
done

prompt_default "Создать первого клиента. Имя клиента" "${client_name:-user1}" client_name
client_name="$(trim_ws "$client_name")"
[[ -z "$client_name" ]] && client_name="user1"
  else
    [[ -n "$server_addr" ]] || die "Non-interactive: не задан --server-addr или XRAYCHAIN_SERVER_ADDR"
    [[ -n "$outbound_uri" ]] || die "Non-interactive: не задан --outbound-uri или XRAYCHAIN_OUTBOUND_URI"
    [[ -n "$vless_port" ]] || vless_port="443"
    [[ -n "$client_name" ]] || client_name="user1"
  fi

  vless_port="$(trim_ws "$vless_port")"
  [[ "$vless_port" =~ ^[0-9]+$ ]] || die "VLESS_PORT должен быть числом"
  [[ "$vless_port" -ge 1 && "$vless_port" -le 65535 ]] || die "VLESS_PORT вне диапазона"

  parse_dest "$reality_dest" >/dev/null || die "REALITY_DEST должен быть в формате host:port"

  # Проверяем парсер outbound сразу
  parse_outbound_uri "$outbound_uri" >/dev/null

  SB_BIN="$SB_BIN_DEFAULT"
  install_singbox

  local kp priv pub
  kp="$(generate_reality_keypair)"
  IFS='|' read -r priv pub <<< "$kp"

  local sid
  sid="$(generate_short_id)"

  SERVER_ADDR="$server_addr"
  VLESS_PORT="$vless_port"
  REALITY_SNI="$reality_sni"
  REALITY_DEST="$reality_dest"
  PRIVATE_KEY="$priv"
  PUBLIC_KEY="$pub"
  SHORT_ID="$sid"
  FLOW="$flow"
  FINGERPRINT="$fp"
  OUTBOUND_URI="$outbound_uri"
  write_state_kv

  if [[ ! -f "$CLIENTS_DB" ]]; then
    : > "$CLIENTS_DB"
    chmod 600 "$CLIENTS_DB"
    chown root:root "$CLIENTS_DB"
  fi

  if ! client_exists "$client_name"; then
    add_client "$client_name"
  fi

  render_singbox_config
  install_service_unit
  service_reload

  local self_path
  self_path="$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || true)"
  if [[ -n "$self_path" ]]; then
    install -m 0755 "$self_path" "/usr/local/bin/$SCRIPT_NAME" 2>/dev/null || true
  fi

  show_client_connection "$client_name"
}

cmd_add() {
  check_root
  load_state
  [[ -f "$CLIENTS_DB" ]] || die "База клиентов не найдена. Сначала: ${SCRIPT_NAME} install"

  local client_name="${1:-}"
  if [[ -z "$client_name" ]]; then
    echo -n "Имя клиента: "
    read -r client_name
  fi
  add_client "$client_name"

  render_singbox_config
  service_reload
}

cmd_remove() {
  check_root
  load_state
  [[ -f "$CLIENTS_DB" ]] || die "База клиентов не найдена"

  local client_name="${1:-}"
  if [[ -z "$client_name" ]]; then
    echo -n "Имя клиента: "
    read -r client_name
  fi
  remove_client "$client_name"

  render_singbox_config
  service_reload
}

cmd_list() {
  check_root
  [[ -f "$CLIENTS_DB" ]] || die "База клиентов не найдена"
  list_clients
}

cmd_show() {
  check_root
  [[ -f "$CLIENTS_DB" ]] || die "База клиентов не найдена"
  local client_name="${1:-}"
  if [[ -z "$client_name" ]]; then
    echo -n "Имя клиента: "
    read -r client_name
  fi
  client_name="$(trim_ws "$client_name")"
  [[ -n "$client_name" ]] || die "Имя пустое"
  client_exists "$client_name" || die "Клиент '"$client_name"' не найден"
  show_client_connection "$client_name"
}

cmd_update_out() {
  check_root
  load_state

  local uri="${1:-}"
  if [[ -z "$uri" ]]; then
    echo -n "Новая ссылка outbound (ss:// или vless://): "
    read -r uri
  fi
  uri="$(trim_ws "$uri")"
  [[ -n "$uri" ]] || die "Пустая ссылка"

  parse_outbound_uri "$uri" >/dev/null

  OUTBOUND_URI="$uri"
  write_state_kv

  render_singbox_config
  service_reload

  log_success "Outbound обновлён."
}

cmd_parse_out() {
  check_root
  local uri="${1:-}"
  if [[ -z "$uri" ]]; then
    echo -n "URI для парсинга: "
    read -r uri
  fi
  uri="$(trim_ws "$uri")"
  [[ -n "$uri" ]] || die "Пустая ссылка"
  parse_outbound_uri "$uri" | jq .
}

cmd_status() {
  check_root
  service_status
}

cmd_uninstall() {
  check_root
  ensure_systemd

  log_warning "Удаляю сервис и конфиги xraychain..."

  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true

  if [[ -f "$SERVICE_FILE" ]]; then
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
  fi

  rm -rf "$SB_CONFIG_DIR" || true
  rm -rf "$STATE_DIR" || true

  if [[ -f "/usr/local/bin/$SCRIPT_NAME" ]]; then
    if grep -q "xraychain.sh v" "/usr/local/bin/$SCRIPT_NAME" 2>/dev/null && grep -q "(sing-box core)" "/usr/local/bin/$SCRIPT_NAME" 2>/dev/null; then
      rm -f "/usr/local/bin/$SCRIPT_NAME" || true
    else
      log_warning "/usr/local/bin/$SCRIPT_NAME существует, но не похож на этот скрипт — не удаляю ..."
    fi
  fi

  log_success "Готово. sing-box бинарник НЕ удалён."
}

main() {
  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    install)      cmd_install "$@" ;;
    add)          cmd_add "$@" ;;
    remove)       cmd_remove "$@" ;;
    list)         cmd_list ;;
    show)         cmd_show "$@" ;;
    update-out)   cmd_update_out "$@" ;;
    parse-out)    cmd_parse_out "$@" ;;
    status)       cmd_status ;;
    uninstall)    cmd_uninstall ;;
    help|--help|-h|"") show_help ;;
    *) die "Неизвестная команда: $cmd" ;;
  esac
}

main "$@"
