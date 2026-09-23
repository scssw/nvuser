#!/usr/bin/env bash
# ==============================================================
# NaiveProxy 运维管理系统 (nv)
# 功能: 多端口管理、单端口多用户、流量统计、域名绑定、备份还原
# ==============================================================

export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin

NAIVE_DIR="/usr/local/naive"
DATA_DIR="${NAIVE_DIR}/data"
NODES_FILE="${DATA_DIR}/nodes.json"
CONFIG_FILE="${DATA_DIR}/config.json"
CADDY_CONFIG="${NAIVE_DIR}/naive.json"
BACKUP_DIR="/root/nvback"
HTML_DIR="${NAIVE_DIR}/html"
BIN_FILE="${NAIVE_DIR}/naive"

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
PURPLE="\033[35m"
CYAN="\033[36m"
WHITE="\033[37m"
PLAIN="\033[0m"

echo_r() { echo -e "${RED}$1${PLAIN}"; }
echo_g() { echo -e "${GREEN}$1${PLAIN}"; }
echo_y() { echo -e "${YELLOW}$1${PLAIN}"; }
echo_b() { echo -e "${BLUE}$1${PLAIN}"; }
echo_c() { echo -e "${CYAN}$1${PLAIN}"; }

check_root() {
  if [[ -n "$SKIP_ROOT_CHECK" ]]; then
    return 0
  fi
  if [[ $(id -u) != "0" ]]; then
    echo_r "错误: 必须使用 root 权限运行此命令！"
    exit 1
  fi
}

# 依赖检查与初始化
init_env() {
  mkdir -p "${DATA_DIR}"
  mkdir -p "${BACKUP_DIR}"
  mkdir -p "${HTML_DIR}"
  mkdir -p "${NAIVE_DIR}/file_system"

  if [[ ! -f "${NODES_FILE}" ]]; then
    echo "[]" > "${NODES_FILE}"
  fi

  if [[ ! -f "${CONFIG_FILE}" ]]; then
    cat > "${CONFIG_FILE}" <<EOF
{
  "domain": "",
  "ssl_type": "acme",
  "email": "",
  "crt_file": "",
  "key_file": ""
}
EOF
  fi

  # 检查 jq 是否安装
  if ! command -v jq &>/dev/null; then
    if command -v apt-get &>/dev/null; then
      apt-get update -y && apt-get install -y jq bc
    elif command -v yum &>/dev/null; then
      yum install -y jq bc
    fi
  fi
}

# 格式化流量字节显示
format_bytes() {
  local bytes=${1:-0}
  if (( $(echo "$bytes < 1024" | bc -l) )); then
    echo "${bytes} B"
  elif (( $(echo "$bytes < 1048576" | bc -l) )); then
    echo "$(echo "scale=2; $bytes/1024" | bc) KB"
  elif (( $(echo "$bytes < 1073741824" | bc -l) )); then
    echo "$(echo "scale=2; $bytes/1048576" | bc) MB"
  else
    echo "$(echo "scale=2; $bytes/1073741824" | bc) GB"
  fi
}

# 随机生成5位数端口 (10000 - 65535)
generate_random_port() {
  local port
  while true; do
    port=$(( RANDOM % 55536 + 10000 ))
    # 检查本地是否占用
    if ! ss -tuln | grep -q ":${port} "; then
      # 检查 nodes.json 中是否已有
      local exist
      exist=$(jq -r --arg p "$port" '.[] | select(.port == ($p | tonumber)) | .port' "${NODES_FILE}" 2>/dev/null | head -n 1)
      if [[ -z "${exist}" ]]; then
        echo "$port"
        return
      fi
    fi
  done
}

# 随机生成5位小写英文字母用户名
generate_random_username() {
  cat /dev/urandom | tr -dc 'a-z' | head -c 5
}

# 随机生成5位数字密码
generate_random_password() {
  cat /dev/urandom | tr -dc '0-9' | head -c 5
}

# 解析自定义日期格式 YY.M.D 或 YYYY.M.D (如 27.5.3 表示 2027年5月3日)
parse_custom_date() {
  local input_date="$1"
  local y m d
  IFS='.' read -r y m d <<< "$input_date"
  if [[ -z "$y" || -z "$m" || -z "$d" ]]; then
    return 1
  fi

  # 转换两位年份为四位年份 (如 27 -> 2027)
  if [[ "$y" =~ ^[0-9]{2}$ ]]; then
    y="20${y}"
  elif [[ ! "$y" =~ ^20[0-9]{2}$ ]]; then
    return 1
  fi

  # 月份检查与补齐
  if [[ ! "$m" =~ ^[0-9]{1,2}$ ]] || (( m < 1 || m > 12 )); then
    return 1
  fi
  m=$(printf "%02d" "$m")

  # 日期检查与补齐
  if [[ ! "$d" =~ ^[0-9]{1,2}$ ]] || (( d < 1 || d > 31 )); then
    return 1
  fi
  d=$(printf "%02d" "$d")

  local target_str="${y}-${m}-${d} 23:59:59"
  local target_ts
  target_ts=$(date -d "${target_str}" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "${target_str}" +%s 2>/dev/null)
  if [[ -z "$target_ts" ]]; then
    return 1
  fi

  echo "${target_ts}|${target_str}"
  return 0
}

# 统一流量输入与到期时间设定 (支持标准档位 50/150/300/600 与非标流量自定义日期如 27.5.3)
prompt_traffic_and_expire() {
  local input_traffic
  while true; do
    echo -e "\n${YELLOW}流量档位说明: 标准档位自动对应到期时间:${PLAIN}"
    echo -e "              ${CYAN}50${PLAIN}   = 50G / 1个月到期"
    echo -e "              ${CYAN}150${PLAIN}  = 150G / 3个月到期"
    echo -e "              ${CYAN}300${PLAIN}  = 300G / 半年(6个月)到期"
    echo -e "              ${CYAN}600${PLAIN}  = 600G / 1年到期 (最高)"
    echo -e "${YELLOW}              若输入非标流量 (如 140)，将弹出自定义时间设定 (输入 27.5.3 回车即 2027年5月3日到期)${PLAIN}"
    read -r -p "请输入流量大小(GB) [默认 50]: " input_traffic
    [[ -z "$input_traffic" ]] && input_traffic="50"

    if [[ ! "$input_traffic" =~ ^[0-9]+$ || "$input_traffic" -le 0 ]]; then
      echo_r "流量必须为正整数！"
      continue
    fi

    local is_standard=0
    local days=0
    local desc=""

    if [[ "$input_traffic" -eq 50 ]]; then
      is_standard=1; days=30; desc="1个月"
    elif [[ "$input_traffic" -eq 150 ]]; then
      is_standard=1; days=90; desc="3个月"
    elif [[ "$input_traffic" -eq 300 ]]; then
      is_standard=1; days=180; desc="半年(6个月)"
    elif [[ "$input_traffic" -eq 600 ]]; then
      is_standard=1; days=365; desc="1年"
    elif (( input_traffic % 50 == 0 && input_traffic < 600 )); then
      is_standard=1
      local months=$(( input_traffic / 50 ))
      days=$(( months * 30 ))
      desc="${months}个月"
    fi

    if [[ "$is_standard" -eq 1 ]]; then
      local now_ts=$(date +%s)
      local exp_ts=$(( now_ts + days * 86400 ))
      local exp_str=$(date -d "@${exp_ts}" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date -r "${exp_ts}" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
      echo_g "已匹配标准档位: ${input_traffic} GB -> 到期时间为 ${desc} (${exp_str})"
      TRAFFIC_QUOTA="$input_traffic"
      TRAFFIC_EXP_TS="$exp_ts"
      TRAFFIC_EXP_STR="$exp_str"
      return 0
    else
      # 非标流量，弹出时间设定
      echo_y "\n检测到输入非标流量 (${input_traffic} GB)，请设定到期时间："
      while true; do
        read -r -p "请输入到期日期 (格式 YY.M.D，如 27.5.3 表示 2027年5月3日): " custom_date
        if [[ -z "$custom_date" ]]; then
          echo_r "日期不能为空！"
          continue
        fi

        local parsed
        parsed=$(parse_custom_date "$custom_date")
        if [[ $? -eq 0 && -n "$parsed" ]]; then
          local c_ts=$(echo "$parsed" | cut -d'|' -f1)
          local c_str=$(echo "$parsed" | cut -d'|' -f2)
          local now_ts=$(date +%s)
          if (( c_ts <= now_ts )); then
            echo_r "到期时间不能早于当前时间，请重新输入！"
            continue
          fi
          echo_g "非标流量到期时间已设定为: ${c_str}"
          TRAFFIC_QUOTA="$input_traffic"
          TRAFFIC_EXP_TS="$c_ts"
          TRAFFIC_EXP_STR="$c_str"
          return 0
        else
          echo_r "日期格式不正确！示例: 27.5.3 (2027年5月3日) 或 28.12.31"
        fi
      done
    fi
  done
}

# Caddy 的 JSON 解码会先对 []byte 字段做 Base64 解码；插件再与客户端
# 发送的 Basic 凭据比较，因此配置里的字符串需要双重 Base64 编码。
encode_credentials() {
  local user=$1
  local pass=$2
  printf '%s' "${user}:${pass}" | base64 | tr -d '\r\n' | base64 | tr -d '\r\n'
}

# iptables 端口流量规则配置
setup_iptables_for_port() {
  local port=$1
  command -v iptables &>/dev/null || return 0
  iptables -C INPUT -p tcp --dport "$port" &>/dev/null 2>&1 || iptables -I INPUT -p tcp --dport "$port"
  iptables -C OUTPUT -p tcp --sport "$port" &>/dev/null 2>&1 || iptables -I OUTPUT -p tcp --sport "$port"
  iptables -C INPUT -p udp --dport "$port" &>/dev/null 2>&1 || iptables -I INPUT -p udp --dport "$port"
  iptables -C OUTPUT -p udp --sport "$port" &>/dev/null 2>&1 || iptables -I OUTPUT -p udp --sport "$port"
}

remove_iptables_for_port() {
  local port=$1
  command -v iptables &>/dev/null || return 0
  iptables -D INPUT -p tcp --dport "$port" &>/dev/null 2>&1
  iptables -D OUTPUT -p tcp --sport "$port" &>/dev/null 2>&1
  iptables -D INPUT -p udp --dport "$port" &>/dev/null 2>&1
  iptables -D OUTPUT -p udp --sport "$port" &>/dev/null 2>&1
}

# 获取某个端口的总流量 (Bytes)
get_port_bytes() {
  local port=$1
  if ! command -v iptables &>/dev/null; then
    echo "0"
    return
  fi
  local in_bytes out_bytes
  in_bytes=$(iptables -nvx -L INPUT 2>/dev/null | awk -v p="$port" '($11 == "dpt:"p || $10 == "dpt:"p) {sum += $2} END {print sum+0}')
  out_bytes=$(iptables -nvx -L OUTPUT 2>/dev/null | awk -v p="$port" '($11 == "spt:"p || $10 == "spt:"p) {sum += $2} END {print sum+0}')
  local total_bytes=$(( in_bytes + out_bytes ))
  echo "$total_bytes"
}

# 动态生成 Caddy naive.json
rebuild_caddy_config() {
  local domain ssl_type email crt_file key_file
  domain=$(jq -r '.domain // empty' "${CONFIG_FILE}")
  ssl_type=$(jq -r '.ssl_type // "acme"' "${CONFIG_FILE}")
  email=$(jq -r '.email // empty' "${CONFIG_FILE}")
  crt_file=$(jq -r '.crt_file // empty' "${CONFIG_FILE}")
  key_file=$(jq -r '.key_file // empty' "${CONFIG_FILE}")

  if [[ -z "$domain" ]]; then
    domain="127.0.0.1"
  fi

  # 获取所有活跃且唯一的端口
  local ports
  ports=$(jq -r '[.[] | select(.status == "active")] | map(.port) | unique | .[]' "${NODES_FILE}" 2>/dev/null)

  # 构建 servers JSON (默认包含 80 端口的 Web 伪装站点，便于 ACME 证书申请及防封探测)
  local servers_json="{}"
  local web_block
  web_block=$(cat <<EOF
{
  "listen": [":80"],
  "routes": [
    {
      "match": [
        {
          "host": ["${domain}"]
        }
      ],
      "handle": [
        {
          "handler": "file_server",
          "root": "${HTML_DIR}",
          "index_names": ["index.html", "index.htm"]
        }
      ],
      "terminal": true
    }
  ]
}
EOF
)
  servers_json=$(echo "$servers_json" | jq --argjson wblock "$web_block" '.["srv_web"] = $wblock')

  if [[ -n "$ports" ]]; then
    for p in $ports; do
      # 找出该端口下的所有有效凭证
      local cred_list
      cred_list=$(jq -c --argjson p "$p" '[.[] | select(.port == $p and .status == "active") | "\(.username):\(.password)"]' "${NODES_FILE}")
      
      # 转换成双重 base64 数组
      local cred_json="[]"
      for cred in $(echo "$cred_list" | jq -r '.[]'); do
        local u=$(echo "$cred" | cut -d: -f1)
        local pwd=$(echo "$cred" | cut -d: -f2)
        local enc=$(encode_credentials "$u" "$pwd")
        cred_json=$(echo "$cred_json" | jq --arg c "$enc" '. + [$c]')
      done

      local server_block
      server_block=$(cat <<EOF
{
  "listen": [":${p}"],
  "routes": [
    {
      "handle": [
        {
          "handler": "subroute",
          "routes": [
            {
              "handle": [
                {
                  "auth_credentials": ${cred_json},
                  "handler": "forward_proxy",
                  "hide_ip": true,
                  "hide_via": true,
                  "probe_resistance": {}
                }
              ]
            },
            {
              "match": [
                {
                  "host": ["${domain}"]
                }
              ],
              "handle": [
                {
                  "handler": "file_server",
                  "root": "${HTML_DIR}",
                  "index_names": ["index.html", "index.htm"]
                }
              ],
              "terminal": true
            }
          ]
        }
      ]
    }
  ],
  "tls_connection_policies": [
    {
      "match": {
        "sni": ["${domain}"]
      }
    }
  ],
  "automatic_https": {
    "disable": true
  }
}
EOF
)
      servers_json=$(echo "$servers_json" | jq --arg sname "srv_${p}" --argjson sblock "$server_block" '.[$sname] = $sblock')
      # 同时设置 iptables 监听
      setup_iptables_for_port "$p"
    done
  fi

  # 构建 TLS 配置
  local tls_json="{}"
  if [[ "$ssl_type" == "custom" && -n "$crt_file" && -n "$key_file" && -f "$crt_file" && -f "$key_file" ]]; then
    tls_json=$(cat <<EOF
{
  "certificates": {
    "load_files": [
      {
        "certificate": "${crt_file}",
        "key": "${key_file}"
      }
    ]
  }
}
EOF
)
  else
    local issuer_module="acme"
    if [[ "$ssl_type" == "zerossl" ]]; then
      issuer_module="zerossl"
    fi
    local email_line=""
    if [[ -n "$email" ]]; then
      email_line="\"email\": \"${email}\","
    fi
    tls_json=$(cat <<EOF
{
  "certificates": {
    "automate": ["${domain}"]
  },
  "automation": {
    "policies": [
      {
        "issuers": [
          {
            "module": "${issuer_module}",
            ${email_line}
            "challenges": {
              "http": {
                "disabled": false
              }
            }
          }
        ]
      }
    ]
  }
}
EOF
)
  fi

  # 拼装最终配置
  local full_caddy_json
  full_caddy_json=$(cat <<EOF
{
  "admin": {
    "disabled": true
  },
  "logging": {
    "sink": {
      "writer": {
        "output": "stderr"
      }
    },
    "logs": {
      "default": {
        "writer": {
          "output": "stderr"
        }
      }
    }
  },
  "storage": {
    "module": "file_system",
    "root": "${NAIVE_DIR}/file_system"
  },
  "apps": {
    "http": {
      "servers": ${servers_json}
    },
    "tls": ${tls_json}
  }
}
EOF
)

  echo "$full_caddy_json" | jq . > "${CADDY_CONFIG}.tmp"
  if [[ $? -eq 0 && -s "${CADDY_CONFIG}.tmp" ]]; then
    mv -f "${CADDY_CONFIG}.tmp" "${CADDY_CONFIG}"
  else
    echo_r "生成 Caddy 配置失败，保留原有配置！"
    rm -f "${CADDY_CONFIG}.tmp"
    return 1
  fi

  # 重载或重启 Naive 服务
  if systemctl is-active --quiet naive; then
    systemctl reload naive &>/dev/null || systemctl restart naive &>/dev/null
  fi
}

# 节点链接附带客户端显示备注：域名前缀、端口和到期月日。
build_node_url() {
  local u=$1
  local p=$2
  local dom=$3
  local port=$4
  local exp_str=$5
  local domain_prefix=${dom%%.*}
  local month_day

  month_day=$(date -d "$exp_str" "+%m.%d" 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$exp_str" "+%m.%d" 2>/dev/null)
  printf 'naive+https://%s:%s@%s:%s#%s:%s-%s' \
    "$u" "$p" "$dom" "$port" "$domain_prefix" "$port" "$month_day"
}

# 格式化打印单个节点信息
print_node_detail() {
  local u=$1
  local p=$2
  local port=$3
  local dom=$4
  local quota=$5
  local exp_str=$6
  local link
  link=$(build_node_url "$u" "$p" "$dom" "$port" "$exp_str")

  echo -e "\n${GREEN}================== 节点配置信息 ==================${PLAIN}"
  echo -e " 域名:         ${CYAN}${dom}${PLAIN}"
  echo -e " 端口:         ${CYAN}${port}${PLAIN}"
  echo -e " 用户名:       ${CYAN}${u}${PLAIN}"
  echo -e " 密码:         ${CYAN}${p}${PLAIN}"
  echo -e " 流量限额:     ${CYAN}${quota} GB${PLAIN}"
  echo -e " 到期时间:     ${CYAN}${exp_str}${PLAIN}"
  echo -e "--------------------------------------------------"
  echo -e " 节点链接:     ${YELLOW}${link}${PLAIN}"
  echo -e "--------------------------------------------------"
  echo -e " 客户端 (config.json) proxy 字段:"
  echo -e "   ${CYAN}\"proxy\": \"https://${u}:${p}@${dom}:${port}\"${PLAIN}"
  echo -e "${GREEN}==================================================${PLAIN}\n"
}

# 保存新节点到 nodes.json
save_node() {
  local u=$1
  local p=$2
  local port=$3
  local dom=$4
  local quota=$5
  local exp_ts=$6
  local exp_str=$7
  local now_str
  now_str=$(date "+%Y-%m-%d %H:%M:%S")
  local link
  link=$(build_node_url "$u" "$p" "$dom" "$port" "$exp_str")

  local new_node
  new_node=$(jq -n \
    --arg port "$port" \
    --arg u "$u" \
    --arg p "$p" \
    --arg dom "$dom" \
    --arg quota "$quota" \
    --arg exp_ts "$exp_ts" \
    --arg exp_str "$exp_str" \
    --arg now_str "$now_str" \
    --arg link "$link" \
    '{
      port: ($port | tonumber),
      username: $u,
      password: $p,
      domain: $dom,
      quota_gb: ($quota | tonumber),
      expire_timestamp: ($exp_ts | tonumber),
      expire_time: $exp_str,
      create_time: $now_str,
      node_url: $link,
      status: "active"
    }')

  local updated
  updated=$(jq --argjson node "$new_node" '. + [$node]' "${NODES_FILE}")
  echo "$updated" | jq . > "${NODES_FILE}"

  rebuild_caddy_config
  # Read display values from the saved JSON. This keeps the details and link
  # tied to the exact credentials persisted for this node.
  print_node_detail \
    "$(jq -r '.username' <<< "$new_node")" \
    "$(jq -r '.password' <<< "$new_node")" \
    "$(jq -r '.port' <<< "$new_node")" \
    "$(jq -r '.domain' <<< "$new_node")" \
    "$(jq -r '.quota_gb' <<< "$new_node")" \
    "$(jq -r '.expire_time' <<< "$new_node")"
}

# ==================== 菜单 1: 服务器控制 ====================
menu_server_control() {
  while true; do
    echo -e "\n${CYAN}---------- 1、服务器控制 ----------${PLAIN}"
    echo -e " 1. 暂停 Naive 服务"
    echo -e " 2. 重启 Naive 服务"
    echo -e " 3. 查看运行状态"
    echo -e " 0. 返回主菜单"
    echo -e "----------------------------------"
    read -r -p "请输入选择 [0-3]: " sub_choice
    case "$sub_choice" in
      1)
        systemctl stop naive
        echo_g "Naive 服务已暂停。"
        ;;
      2)
        systemctl restart naive
        echo_g "Naive 服务已重启。"
        ;;
      3)
        echo -e "\n${YELLOW}--- 服务状态 ---${PLAIN}"
        systemctl status naive --no-pager -l
        echo -e "\n${YELLOW}--- 当前系统监听的 Naive 端口 ---${PLAIN}"
        local active_ports
        active_ports=$(jq -r '[.[] | select(.status == "active")] | map(.port) | unique | .[]' "${NODES_FILE}" 2>/dev/null)
        if [[ -z "$active_ports" ]]; then
          echo "暂无配置任何节点端口。"
        else
          for ap in $active_ports; do
            local ss_status="未监听"
            if ss -tuln | grep -q ":${ap} "; then
              ss_status="${GREEN}正常监听中${PLAIN}"
            else
              ss_status="${RED}未运行或异常${PLAIN}"
            fi
            echo -e "端口 ${CYAN}${ap}${PLAIN}: ${ss_status}"
          done
        fi
        read -r -p "按回车键继续..."
        ;;
      0)
        break
        ;;
      *)
        echo_r "无效输入！"
        ;;
    esac
  done
}

# ==================== 菜单 2: 新增与管理用户 ====================
sub_add_quick() {
  local domain
  domain=$(jq -r '.domain // empty' "${CONFIG_FILE}")
  if [[ -z "$domain" ]]; then
    echo_r "提示: 尚未绑定域名，请先在菜单 4 绑定域名！"
    return
  fi

  local port
  port=$(generate_random_port)
  local username
  username=$(generate_random_username)
  local password
  password=$(generate_random_password)

  echo_g "已自动生成五位数端口:     ${CYAN}${port}${PLAIN}"
  echo_g "已自动生成用户名(5位字母): ${CYAN}${username}${PLAIN}"
  echo_g "已自动生成密码(5位数字):   ${CYAN}${password}${PLAIN}"

  prompt_traffic_and_expire
  save_node "$username" "$password" "$port" "$domain" "$TRAFFIC_QUOTA" "$TRAFFIC_EXP_TS" "$TRAFFIC_EXP_STR"
}

sub_add_manual() {
  local domain
  domain=$(jq -r '.domain // empty' "${CONFIG_FILE}")
  if [[ -z "$domain" ]]; then
    echo_r "提示: 尚未绑定域名，请先在菜单 4 绑定域名！"
    return
  fi

  local port
  while true; do
    read -r -p "请输入要指定的端口 (1-65535): " port
    if [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]]; then
      if ss -tuln | grep -q ":${port} "; then
        local exist
        exist=$(jq -r --arg p "$port" '.[] | select(.port == ($p | tonumber)) | .port' "${NODES_FILE}" 2>/dev/null | head -n 1)
        if [[ -n "$exist" ]]; then
          echo_y "该端口已存在于 Naive 节点中。若要在该端口增加用户，请使用【3、单端口多用户】功能！"
          return
        else
          echo_r "该端口已被系统其他程序占用，请换一个端口！"
        fi
      else
        break
      fi
    else
      echo_r "请输入有效的端口号！"
    fi
  done

  local username
  username=$(generate_random_username)
  local password
  password=$(generate_random_password)

  echo_g "已自动生成用户名(5位字母): ${CYAN}${username}${PLAIN}"
  echo_g "已自动生成密码(5位数字):   ${CYAN}${password}${PLAIN}"

  prompt_traffic_and_expire
  save_node "$username" "$password" "$port" "$domain" "$TRAFFIC_QUOTA" "$TRAFFIC_EXP_TS" "$TRAFFIC_EXP_STR"
}

sub_add_multi_user() {
  local domain
  domain=$(jq -r '.domain // empty' "${CONFIG_FILE}")
  if [[ -z "$domain" ]]; then
    echo_r "提示: 尚未绑定域名，请先在菜单 4 绑定域名！"
    return
  fi

  # 获取所有现有端口列表
  local ports
  ports=$(jq -r '[.[] | select(.status == "active")] | map(.port) | unique | .[]' "${NODES_FILE}" 2>/dev/null)
  if [[ -z "$ports" ]]; then
    echo_r "当前暂无任何已建节点端口，请先使用【1、一键新增】或【2、手动新增】创建首个端口！"
    return
  fi

  local port_arr=($ports)
  local count=${#port_arr[@]}

  # 筛选出用户数尚未达到 20 个的端口
  local available_ports=()
  for p in "${port_arr[@]}"; do
    local u_cnt
    u_cnt=$(jq -r --argjson p "$p" '[.[] | select(.port == $p and .status == "active")] | length' "${NODES_FILE}")
    if [[ "$u_cnt" -lt 20 ]]; then
      available_ports+=("$p")
    fi
  done

  if [[ ${#available_ports[@]} -eq 0 ]]; then
    echo_r "所有已有端口的节点数量均已达到 20 个上限！请新增端口。"
    return
  fi

  # 随机调出一个可用端口
  local rand_idx=$(( RANDOM % ${#available_ports[@]} ))
  local chosen_port="${available_ports[$rand_idx]}"
  local cur_users
  cur_users=$(jq -r --argjson p "$chosen_port" '[.[] | select(.port == $p and .status == "active")] | length' "${NODES_FILE}")

  echo_g "系统随机调出已有端口: ${CYAN}${chosen_port}${PLAIN} (当前已有用户: ${cur_users}/20)"

  local username
  username=$(generate_random_username)
  local password
  password=$(generate_random_password)

  echo_g "已自动生成用户名(5位字母): ${CYAN}${username}${PLAIN}"
  echo_g "已自动生成密码(5位数字):   ${CYAN}${password}${PLAIN}"

  prompt_traffic_and_expire
  save_node "$username" "$password" "$chosen_port" "$domain" "$TRAFFIC_QUOTA" "$TRAFFIC_EXP_TS" "$TRAFFIC_EXP_STR"
}


sub_modify_node() {
  echo -e "\n请输入节点链接或端口号 (支持备注后缀，例如 naive+https://user:pass@nav.ssrr.today:5566#nav:5566-10.23):"
  read -r -p "节点链接/端口: " raw_url
  if [[ -z "$raw_url" ]]; then
    echo_r "输入为空！"
    return
  fi

  # 清除前后空格
  raw_url=$(echo "$raw_url" | xargs)
  raw_url=${raw_url%%#*}

  local matched_idx
  if [[ "$raw_url" =~ ^[0-9]{1,5}$ ]]; then
    local port_matches=()
    while IFS= read -r idx; do
      [[ -n "$idx" ]] && port_matches+=("$idx")
    done < <(jq -r --arg port "$raw_url" \
      'to_entries[] | select((.value.port | tostring) == $port) | .key' "${NODES_FILE}")

    if [[ ${#port_matches[@]} -eq 0 ]]; then
      echo_r "端口 ${raw_url} 下没有找到节点！"
      return
    elif [[ ${#port_matches[@]} -eq 1 ]]; then
      matched_idx=${port_matches[0]}
    else
      echo -e "\n端口 ${CYAN}${raw_url}${PLAIN} 下有多个用户，请选择："
      local i=1
      for idx in "${port_matches[@]}"; do
        local node=$(jq ".[$idx]" "${NODES_FILE}")
        echo -e " ${i}. 用户: $(jq -r '.username' <<< "$node") | 到期: $(jq -r '.expire_time' <<< "$node") | 状态: $(jq -r '.status' <<< "$node")"
        i=$((i + 1))
      done
      read -r -p "请输入序号 [1-${#port_matches[@]}]: " node_choice
      if [[ ! "$node_choice" =~ ^[0-9]+$ || "$node_choice" -lt 1 || "$node_choice" -gt ${#port_matches[@]} ]]; then
        echo_r "选择无效，已取消。"
        return
      fi
      matched_idx=${port_matches[$((node_choice - 1))]}
    fi
  else
    # 解析 URL: naive+https://username:password@domain:port
    # 或者 https://username:password@domain:port
    local clean_url=${raw_url#naive+}
    clean_url=${clean_url#*://}
    local user_pass=${clean_url%%@*}
    local host_port=${clean_url##*@}
    local req_u=${user_pass%%:*}
    local req_p=${user_pass##*:}
    local req_port=${host_port##*:}

    if [[ "$user_pass" == "$clean_url" || -z "$req_u" || -z "$req_p" || ! "$req_port" =~ ^[0-9]{1,5}$ ]]; then
      echo_r "无法解析该节点格式，请输入端口号或完整节点链接！"
      return
    fi

    # 在 nodes.json 中查找，备注后缀已在 URL 解析前移除。
    matched_idx=$(jq -r --arg u "$req_u" --arg p "$req_p" --arg port "$req_port" \
      'to_entries[] | select(.value.username == $u and .value.password == $p and (.value.port|tostring) == $port) | .key' "${NODES_FILE}" | head -n 1)
  fi

  if [[ -z "$matched_idx" ]]; then
    echo_r "未找到匹配的节点！"
    return
  fi

  local cur_node
  cur_node=$(jq ".[$matched_idx]" "${NODES_FILE}")
  local c_u=$(echo "$cur_node" | jq -r .username)
  local c_p=$(echo "$cur_node" | jq -r .password)
  local c_port=$(echo "$cur_node" | jq -r .port)
  local c_dom=$(echo "$cur_node" | jq -r .domain)
  local c_quota=$(echo "$cur_node" | jq -r .quota_gb)
  local c_exp=$(echo "$cur_node" | jq -r .expire_time)
  local c_status=$(echo "$cur_node" | jq -r .status)

  echo -e "\n${GREEN}找到匹配节点:${PLAIN}"
  echo -e " 端口: ${CYAN}${c_port}${PLAIN} | 用户: ${CYAN}${c_u}${PLAIN} | 密码: ${CYAN}${c_p}${PLAIN}"
  echo -e " 当前配额: ${CYAN}${c_quota} GB${PLAIN} | 到期时间: ${CYAN}${c_exp}${PLAIN} | 状态: ${CYAN}${c_status}${PLAIN}"

  echo -e "\n${YELLOW}请选择要执行的操作:${PLAIN}"
  echo -e " 1. 删除该节点"
  echo -e " 2. 修改节点时间"
  echo -e " 3. 修改节点流量"
  echo -e " 0. 取消返回"
  read -r -p "请输入选择 [0-3]: " mod_choice

  case "$mod_choice" in
    1)
      read -r -p "确定要删除该节点吗？(y/n): " confirm_del
      if [[ "$confirm_del" == "y" || "$confirm_del" == "Y" ]]; then
        local updated
        updated=$(jq "del(.[$matched_idx])" "${NODES_FILE}")
        echo "$updated" | jq . > "${NODES_FILE}"
        
        # 检查该端口是否还有其他活跃用户，若无则清理 iptables
        local remaining
        remaining=$(jq -r --argjson p "$c_port" '[.[] | select(.port == $p)] | length' "${NODES_FILE}")
        if [[ "$remaining" -eq 0 ]]; then
          remove_iptables_for_port "$c_port"
        fi
        
        rebuild_caddy_config
        echo_g "节点已成功删除！"
      else
        echo_y "已取消删除。"
      fi
      ;;
    2)
      echo -e "\n当前到期时间: ${CYAN}${c_exp}${PLAIN}"
      echo -e "请选择修改方式: 1. 延长天数  2. 设置新天数(从现在算起)"
      read -r -p "选择 [1-2]: " t_choice
      if [[ "$t_choice" == "1" ]]; then
        read -r -p "请输入追加的天数 (如 30): " add_days
        if [[ "$add_days" =~ ^[0-9]+$ && "$add_days" -gt 0 ]]; then
          local old_ts=$(echo "$cur_node" | jq -r .expire_timestamp)
          local now_ts=$(date +%s)
          local base_ts=$old_ts
          if (( old_ts < now_ts )); then base_ts=$now_ts; fi
          local new_exp_ts=$(( base_ts + add_days * 86400 ))
          local new_exp_str=$(date -d "@${new_exp_ts}" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date -r "${new_exp_ts}" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
          local new_node_url
          new_node_url=$(build_node_url "$c_u" "$c_p" "$c_dom" "$c_port" "$new_exp_str")
          
          local updated
          updated=$(jq --arg idx "$matched_idx" --arg ts "$new_exp_ts" --arg str "$new_exp_str" --arg link "$new_node_url" \
            '.[($idx | tonumber)].expire_timestamp = ($ts | tonumber) | .[($idx | tonumber)].expire_time = $str | .[($idx | tonumber)].node_url = $link | .[($idx | tonumber)].status = "active"' "${NODES_FILE}")
          echo "$updated" | jq . > "${NODES_FILE}"
          rebuild_caddy_config
          echo_g "修改成功！新到期时间: ${CYAN}${new_exp_str}${PLAIN}"
        else
          echo_r "输入天数不合法！"
        fi
      elif [[ "$t_choice" == "2" ]]; then
        read -r -p "请输入有效天数(如 30)或到期日期 YY.M.D (如 26.9.25): " set_value
        local new_exp_ts new_exp_str
        if [[ "$set_value" =~ ^[0-9]+$ && "$set_value" -gt 0 ]]; then
          local now_ts=$(date +%s)
          new_exp_ts=$(( now_ts + set_value * 86400 ))
          new_exp_str=$(date -d "@${new_exp_ts}" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date -r "${new_exp_ts}" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
        else
          local parsed_date
          parsed_date=$(parse_custom_date "$set_value")
          if [[ -z "$parsed_date" ]]; then
            echo_r "请输入正整数天数，或有效日期 YY.M.D (如 26.9.25)！"
            return
          fi
          new_exp_ts=${parsed_date%%|*}
          new_exp_str=${parsed_date#*|}
          if (( new_exp_ts <= $(date +%s) )); then
            echo_r "到期日期必须晚于当前时间！"
            return
          fi
        fi

        if [[ -n "$new_exp_ts" && -n "$new_exp_str" ]]; then
          local new_node_url
          new_node_url=$(build_node_url "$c_u" "$c_p" "$c_dom" "$c_port" "$new_exp_str")
          local updated
          updated=$(jq --arg idx "$matched_idx" --arg ts "$new_exp_ts" --arg str "$new_exp_str" --arg link "$new_node_url" \
            '.[($idx | tonumber)].expire_timestamp = ($ts | tonumber) | .[($idx | tonumber)].expire_time = $str | .[($idx | tonumber)].node_url = $link | .[($idx | tonumber)].status = "active"' "${NODES_FILE}")
          echo "$updated" | jq . > "${NODES_FILE}"
          rebuild_caddy_config
          echo_g "修改成功！新到期时间: ${CYAN}${new_exp_str}${PLAIN}"
        fi
      fi
      ;;
    3)
      echo -e "\n当前流量限额: ${CYAN}${c_quota} GB${PLAIN}"
      read -r -p "请输入新的流量限额(GB): " new_quota
      if [[ "$new_quota" =~ ^[0-9]+$ && "$new_quota" -gt 0 ]]; then
        read -r -p "是否同时按新流量重新推算/设定到期时间？(y/n 默认: n): " sync_exp
        if [[ "$sync_exp" == "y" || "$sync_exp" == "Y" ]]; then
          prompt_traffic_and_expire
          local new_node_url
          new_node_url=$(build_node_url "$c_u" "$c_p" "$c_dom" "$c_port" "$TRAFFIC_EXP_STR")
          local updated
          updated=$(jq --arg idx "$matched_idx" --arg q "$TRAFFIC_QUOTA" --arg ts "$TRAFFIC_EXP_TS" --arg str "$TRAFFIC_EXP_STR" --arg link "$new_node_url" \
            '.[($idx | tonumber)].quota_gb = ($q | tonumber) | .[($idx | tonumber)].expire_timestamp = ($ts | tonumber) | .[($idx | tonumber)].expire_time = $str | .[($idx | tonumber)].node_url = $link | .[($idx | tonumber)].status = "active"' "${NODES_FILE}")
          echo "$updated" | jq . > "${NODES_FILE}"
          rebuild_caddy_config
          echo_g "修改成功！新流量限额: ${CYAN}${TRAFFIC_QUOTA} GB${PLAIN}，到期时间: ${CYAN}${TRAFFIC_EXP_STR}${PLAIN}"
        else
          local updated
          updated=$(jq --arg idx "$matched_idx" --arg q "$new_quota" \
            '.[($idx | tonumber)].quota_gb = ($q | tonumber) | .[($idx | tonumber)].status = "active"' "${NODES_FILE}")
          echo "$updated" | jq . > "${NODES_FILE}"
          rebuild_caddy_config
          echo_g "修改成功！新流量限额: ${CYAN}${new_quota} GB${PLAIN}"
        fi
      else
        echo_r "输入流量数值不合法！"
      fi
      ;;
    *)
      echo_y "已取消。"
      ;;
  esac
}

menu_add_user() {
  while true; do
    echo -e "\n${CYAN}---------- 2、新增与管理用户 ----------${PLAIN}"
    echo -e " 1. 一键新增 (随机端口+随机账密+流量推算时间)"
    echo -e " 2. 手动新增 (输入指定端口+随机账密+流量推算时间)"
    echo -e " 3. 单端口多用户 (调出已有端口+随机账密+限额)"
    echo -e " 4. 修改节点 (输入节点链接可删除/改时间/改流量)"
    echo -e " 0. 返回主菜单"
    echo -e "---------------------------------------"
    read -r -p "请输入选择 [0-4]: " sub_choice
    case "$sub_choice" in
      1) sub_add_quick ;;
      2) sub_add_manual ;;
      3) sub_add_multi_user ;;
      4) sub_modify_node ;;
      0) break ;;
      *) echo_r "无效输入！" ;;
    esac
  done
}

# ==================== 菜单 3: 显示所有用户流量 ====================
menu_show_traffic() {
  while true; do
    echo -e "\n${CYAN}======================== 端口与流量概览 ========================${PLAIN}"
    local ports
    ports=$(jq -r '[.[]] | map(.port) | unique | .[]' "${NODES_FILE}" 2>/dev/null)
    if [[ -z "$ports" ]]; then
      echo -e "${YELLOW}当前没有任何配置的端口或节点。${PLAIN}"
      echo -e "================================================================\n"
      read -r -p "按回车键返回主菜单..."
      break
    fi

    local port_arr=($ports)
    printf "%-6s %-10s %-16s %-16s %-10s\n" "序号" "端口" "累计消耗流量" "节点类型" "监听状态"
    echo "----------------------------------------------------------------"

    local idx=1
    for p in "${port_arr[@]}"; do
      local bytes=$(get_port_bytes "$p")
      local fmt_bytes=$(format_bytes "$bytes")
      local user_count=$(jq -r --argjson p "$p" '[.[] | select(.port == $p)] | length' "${NODES_FILE}")
      
      local type_desc="【单用户】"
      if [[ "$user_count" -gt 1 ]]; then
        type_desc="【多用户(${user_count}人)】"
      fi

      local status_desc="未监听"
      if ss -tuln | grep -q ":${p} "; then
        status_desc="${GREEN}正常${PLAIN}"
      else
        status_desc="${RED}停止${PLAIN}"
      fi

      printf "%-6s %-10s %-16s %-20b %-10b\n" "$idx" "$p" "$fmt_bytes" "${YELLOW}${type_desc}${PLAIN}" "$status_desc"
      idx=$(( idx + 1 ))
    done
    echo "----------------------------------------------------------------"
    echo -e "提示: 输入排列数字查看对应端口的各个节点详情，按 0 或回车返回主菜单"
    read -r -p "请输入序号 [1-${#port_arr[@]}]: " view_idx

    if [[ -z "$view_idx" || "$view_idx" == "0" ]]; then
      break
    fi

    if [[ "$view_idx" =~ ^[0-9]+$ && "$view_idx" -ge 1 && "$view_idx" -le "${#port_arr[@]}" ]]; then
      local sel_port="${port_arr[$(( view_idx - 1 ))]}"
      local sel_bytes=$(get_port_bytes "$sel_port")
      local sel_fmt_bytes=$(format_bytes "$sel_bytes")

      echo -e "\n${CYAN}========= 端口 [${sel_port}] 节点详情 (端口总消耗: ${sel_fmt_bytes}) =========${PLAIN}"
      local nodes_in_port
      nodes_in_port=$(jq -c --argjson p "$sel_port" '[.[] | select(.port == $p)]' "${NODES_FILE}")
      local node_len=$(echo "$nodes_in_port" | jq 'length')

      for (( i=0; i<node_len; i++ )); do
        local n=$(echo "$nodes_in_port" | jq ".[$i]")
        local u=$(echo "$n" | jq -r .username)
        local pwd=$(echo "$n" | jq -r .password)
        local dom=$(echo "$n" | jq -r .domain)
        local q=$(echo "$n" | jq -r .quota_gb)
        local exp=$(echo "$n" | jq -r .expire_time)
        local exp_ts=$(echo "$n" | jq -r .expire_timestamp)
        local st=$(echo "$n" | jq -r .status)
        local link
        link=$(build_node_url "$u" "$pwd" "$dom" "$sel_port" "$exp")

        local now_ts=$(date +%s)
        local is_expired="有效"
        if (( exp_ts < now_ts )); then
          is_expired="${RED}已到期${PLAIN}"
        else
          is_expired="${GREEN}有效${PLAIN}"
        fi

        echo -e " [节点 $((i+1))]"
        echo -e "  用户名/密码: ${CYAN}${u}${PLAIN} / ${CYAN}${pwd}${PLAIN}"
        echo -e "  流量配额:    ${CYAN}${q} GB${PLAIN}"
        echo -e "  到期时间:    ${CYAN}${exp}${PLAIN} (${is_expired})"
        echo -e "  状态:        ${CYAN}${st}${PLAIN}"
        echo -e "  节点链接:    ${YELLOW}${link}${PLAIN}"
        echo "----------------------------------------------------------------"
      done
      read -r -p "按回车键返回端口列表..."
    else
      echo_r "无效序号！"
    fi
  done
}

# ==================== 菜单 4: 绑定域名 ====================
menu_bind_domain() {
  while true; do
    local cur_domain=$(jq -r '.domain // empty' "${CONFIG_FILE}")
    local cur_ssl=$(jq -r '.ssl_type // empty' "${CONFIG_FILE}")
    echo -e "\n${CYAN}---------- 4、绑定域名 ----------${PLAIN}"
    echo -e " 当前绑定域名: ${YELLOW}${cur_domain:-暂无}${PLAIN} (${cur_ssl:-无})"
    echo -e " 1. 换绑新域名 (重新自动申请 SSL 证书)"
    echo -e " 2. 指定本地域名 (使用本地已有的 crt/key 证书)"
    echo -e " 0. 返回主菜单"
    echo -e "--------------------------------"
    read -r -p "请输入选择 [0-2]: " sub_choice

    case "$sub_choice" in
      1)
        echo_y "提示: 请先确认新域名已正确解析到本服务器公网 IP，且服务器 80 端口未被占用！"
        local new_dom
        while read -r -p "请输入新域名 (如 nav.ssrr.today): " new_dom; do
          if [[ -n "$new_dom" ]]; then break; else echo_r "域名不能为空！"; fi
        done

        read -r -p "请输入邮箱 (用于申请证书，可选直接回车): " new_email
        read -r -p "请选择证书颁发机构 (1/acme(Let's Encrypt) 2/zerossl 默认:1): " ssl_opt
        local ssl_type="acme"
        if [[ "$ssl_opt" == "2" ]]; then ssl_type="zerossl"; fi

        # 更新 config.json
        local updated_cfg
        updated_cfg=$(jq --arg dom "$new_dom" --arg ssl "$ssl_type" --arg email "$new_email" \
          '.domain = $dom | .ssl_type = $ssl | .email = $email | .crt_file = "" | .key_file = ""' "${CONFIG_FILE}")
        echo "$updated_cfg" | jq . > "${CONFIG_FILE}"

        # 同步更新现有所有节点的 domain 字段与链接
        local updated_nodes
        updated_nodes=$(jq --arg dom "$new_dom" \
          'map(.domain = $dom | .node_url = "naive+https://\(.username):\(.password)@\($dom):\(.port)#\($dom | split(".")[0]):\(.port)-\(.expire_time[5:7]).\(.expire_time[8:10])")' "${NODES_FILE}")
        echo "$updated_nodes" | jq . > "${NODES_FILE}"

        rebuild_caddy_config
        echo_g "换绑域名完成！配置已重载。新域名: ${CYAN}${new_dom}${PLAIN}"
        ;;
      2)
        local loc_dom
        while read -r -p "请输入域名: " loc_dom; do
          if [[ -n "$loc_dom" ]]; then break; else echo_r "域名不能为空！"; fi
        done

        local crt_path key_path
        while read -r -p "请输入证书 .crt/.pem 文件的绝对路径: " crt_path; do
          if [[ -f "$crt_path" ]]; then break; else echo_r "文件不存在: $crt_path"; fi
        done

        while read -r -p "请输入私钥 .key 文件的绝对路径: " key_path; do
          if [[ -f "$key_path" ]]; then break; else echo_r "文件不存在: $key_path"; fi
        done

        local updated_cfg
        updated_cfg=$(jq --arg dom "$loc_dom" --arg crt "$crt_path" --arg key "$key_path" \
          '.domain = $dom | .ssl_type = "custom" | .crt_file = $crt | .key_file = $key' "${CONFIG_FILE}")
        echo "$updated_cfg" | jq . > "${CONFIG_FILE}"

        local updated_nodes
        updated_nodes=$(jq --arg dom "$loc_dom" \
          'map(.domain = $dom | .node_url = "naive+https://\(.username):\(.password)@\($dom):\(.port)#\($dom | split(".")[0]):\(.port)-\(.expire_time[5:7]).\(.expire_time[8:10])")' "${NODES_FILE}")
        echo "$updated_nodes" | jq . > "${NODES_FILE}"

        rebuild_caddy_config
        echo_g "本地域名及证书配置完成！新域名: ${CYAN}${loc_dom}${PLAIN}"
        ;;
      0)
        break
        ;;
      *)
        echo_r "无效输入！"
        ;;
    esac
  done
}

# ==================== 菜单 5: 程序管理 ====================
sub_backup_data() {
  mkdir -p "${BACKUP_DIR}"
  local backup_file="${BACKUP_DIR}/nv_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
  
  tar -czf "${backup_file}" -C "${NAIVE_DIR}" data naive.json html &>/dev/null
  if [[ $? -eq 0 && -f "${backup_file}" ]]; then
    local fsize=$(ls -lh "${backup_file}" | awk '{print $5}')
    echo_g "数据备份成功！"
    echo -e "备份文件路径: ${CYAN}${backup_file}${PLAIN} (${fsize})"
  else
    echo_r "备份失败！"
  fi
}

sub_restore_data() {
  mkdir -p "${BACKUP_DIR}"
  local files=( $(ls -t "${BACKUP_DIR}"/nv_backup_*.tar.gz 2>/dev/null) )
  if [[ ${#files[@]} -eq 0 ]]; then
    echo_r "在 ${BACKUP_DIR} 未找到任何历史备份文件！"
    return
  fi

  echo -e "\n${CYAN}--- 本地可用备份列表 ---${PLAIN}"
  local i=1
  for f in "${files[@]}"; do
    local f_time=$(ls -l --time-style="+%Y-%m-%d %H:%M:%S" "$f" | awk '{print $6, $7}')
    local f_size=$(ls -lh "$f" | awk '{print $5}')
    printf " %2d. %-35s (%s, %s)\n" "$i" "$(basename "$f")" "$f_size" "$f_time"
    i=$(( i + 1 ))
  done
  echo "-----------------------------------"
  read -r -p "请选择需要还原的备份序号 [1-${#files[@]}], 按 0 取消: " sel_num

  if [[ -z "$sel_num" || "$sel_num" == "0" ]]; then
    echo_y "已取消还原。"
    return
  fi

  if [[ "$sel_num" =~ ^[0-9]+$ && "$sel_num" -ge 1 && "$sel_num" -le "${#files[@]}" ]]; then
    local target_file="${files[$(( sel_num - 1 ))]}"
    read -r -p "还原操作将覆盖当前所有节点数据，确定要继续吗？(y/n): " confirm_res
    if [[ "$confirm_res" == "y" || "$confirm_res" == "Y" ]]; then
      # 自动先对当前做一个应急快照
      tar -czf "${BACKUP_DIR}/nv_before_restore_$(date +%Y%m%d_%H%M%S).tar.gz" -C "${NAIVE_DIR}" data naive.json html &>/dev/null

      tar -xzf "${target_file}" -C "${NAIVE_DIR}"
      if [[ $? -eq 0 ]]; then
        rebuild_caddy_config
        echo_g "数据还原成功！服务配置已重载生效。"
      else
        echo_r "解压还原文件失败！"
      fi
    else
      echo_y "已取消还原。"
    fi
  else
    echo_r "输入序号无效！"
  fi
}

menu_app_mgmt() {
  while true; do
    echo -e "\n${CYAN}---------- 5、程序管理 ----------${PLAIN}"
    echo -e " 1. 备份数据 (备份所有节点和配置到 /root/nvback)"
    echo -e " 2. 还原数据 (从 /root/nvback 列表中还原)"
    echo -e " 0. 返回主菜单"
    echo -e "--------------------------------"
    read -r -p "请输入选择 [0-2]: " sub_choice
    case "$sub_choice" in
      1) sub_backup_data ;;
      2) sub_restore_data ;;
      0) break ;;
      *) echo_r "无效输入！" ;;
    esac
  done
}

# ==================== 后台定时检查任务 (Crontab 维护) ====================
cron_check_limits() {
  local now_ts=$(date +%s)
  local nodes_cnt=$(jq 'length' "${NODES_FILE}" 2>/dev/null || echo 0)
  if [[ "$nodes_cnt" -eq 0 ]]; then return 0; fi

  local changed=0
  for (( i=0; i<nodes_cnt; i++ )); do
    local st=$(jq -r ".[$i].status" "${NODES_FILE}")
    local exp_ts=$(jq -r ".[$i].expire_timestamp" "${NODES_FILE}")
    local quota_gb=$(jq -r ".[$i].quota_gb" "${NODES_FILE}")
    local port=$(jq -r ".[$i].port" "${NODES_FILE}")

    # 检查是否过期
    if [[ "$st" == "active" && "$exp_ts" -lt "$now_ts" ]]; then
      local updated=$(jq ".[$i].status = \"expired\"" "${NODES_FILE}")
      echo "$updated" | jq . > "${NODES_FILE}"
      changed=1
    fi

    # 检查单端口单用户是否超流量
    local port_users=$(jq -r --argjson p "$port" '[.[] | select(.port == $p)] | length' "${NODES_FILE}")
    if [[ "$port_users" -eq 1 && "$st" == "active" ]]; then
      local used_bytes=$(get_port_bytes "$port")
      local quota_bytes=$(echo "$quota_gb * 1073741824" | bc)
      if (( $(echo "$used_bytes > $quota_bytes" | bc -l) )); then
        local updated=$(jq ".[$i].status = \"overquota\"" "${NODES_FILE}")
        echo "$updated" | jq . > "${NODES_FILE}"
        changed=1
      fi
    fi
  done

  if [[ "$changed" -eq 1 ]]; then
    rebuild_caddy_config
  fi
}

# ==================== 主菜单 ====================
main_menu() {
  while true; do
    clear
    echo -e "${GREEN}==============================================================${PLAIN}"
    echo -e "                   ${CYAN}NaiveProxy 管理系统 (nv)${PLAIN}"
    echo -e "${GREEN}==============================================================${PLAIN}"
    echo -e " 1、服务器控制"
    echo -e " 2、新增用户"
    echo -e " 3、显示所有用户流量"
    echo -e " 4、绑定域名"
    echo -e " 5、程序管理"
    echo -e " 0、退出菜单"
    echo -e "${GREEN}==============================================================${PLAIN}"
    read -r -p "请输入选项 [0-5]: " main_choice

    case "$main_choice" in
      1) menu_server_control ;;
      2) menu_add_user ;;
      3) menu_show_traffic ;;
      4) menu_bind_domain ;;
      5) menu_app_mgmt ;;
      0)
        echo_g "感谢使用！再见。"
        exit 0
        ;;
      *)
        echo_r "无效选择，请重新输入！"
        sleep 1
        ;;
    esac
  done
}

# 命令行参数入口
check_root
init_env

if [[ "$1" == "--cron" || "$1" == "cron" ]]; then
  cron_check_limits
  exit 0
elif [[ "$1" == "--rebuild" || "$1" == "rebuild" ]]; then
  rebuild_caddy_config
  exit 0
fi

main_menu
