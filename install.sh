#!/usr/bin/env bash
# install.sh — singtun 一键引导安装脚本（支持 curl | sudo bash）
set -euo pipefail

DEFAULT_REPO_URL="https://github.com/YogzZ/singtun.git"
DEFAULT_REPO_REF="main"
DEFAULT_INSTALL_DIR="/opt/singtun"
DEFAULT_BIN_DIR="/usr/local/bin"

log_info()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$*" >&2; }
log_warn()  { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
log_error() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
die()       { log_error "$*"; exit 1; }

usage() {
  cat <<'EOF'
用法: install.sh [选项]

选项:
  --install-only          仅安装/更新仓库与 singtun 命令，不启动交互式 setup 向导
  --update                更新已安装的 singtun 代码（自动保留 private/ 状态与配置）
  --dir <path>            指定安装目录（默认 /opt/singtun）
  --repo <url|path>       指定 Git 仓库地址或本地路径（默认 https://github.com/YogzZ/singtun.git）
  --ref <branch|tag>      指定分支或标签（默认 main）
  --bin-dir <path>        指定命令软链目录（默认 /usr/local/bin）
  -h, --help              显示本帮助信息

环境变量覆盖:
  SINGTUN_REPO_URL / SINGTUN_REPO_REF / SINGTUN_INSTALL_DIR / SINGTUN_BIN_DIR
EOF
}

check_supported_os() {
  [[ "${SKIP_OS_CHECK:-false}" == "true" ]] && return 0
  if [[ -r /etc/os-release ]]; then
    local os_id=""
    os_id="$(awk -F= '/^ID=/{gsub(/"/, "", $2); print tolower($2)}' /etc/os-release 2>/dev/null || true)"
    case "${os_id}" in
      ubuntu|debian) return 0 ;;
      *) die "不支持的操作系统 (${os_id:-unknown})，singtun 仅支持 Debian 与 Ubuntu 22.04+。" ;;
    esac
  fi
}

ensure_bootstrap_tools() {
  local -a missing_pkgs=()
  command -v git >/dev/null 2>&1 || missing_pkgs+=(git)
  command -v curl >/dev/null 2>&1 || missing_pkgs+=(curl)
  command -v openssl >/dev/null 2>&1 || missing_pkgs+=(openssl)
  [[ -d /etc/ssl/certs ]] || missing_pkgs+=(ca-certificates)

  if (( ${#missing_pkgs[@]} > 0 )); then
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
      die "缺少引导依赖 (${missing_pkgs[*]})，请使用 root / sudo 运行。"
    fi
    command -v apt-get >/dev/null 2>&1 || die "未找到 apt-get，请手动安装: ${missing_pkgs[*]}"
    log_info "正在安装基础引导依赖: ${missing_pkgs[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends "${missing_pkgs[@]}"
  fi
}

main() {
  local install_only="false"
  local update_mode="false"
  local repo_url="${SINGTUN_REPO_URL:-${DEFAULT_REPO_URL}}"
  local repo_ref="${SINGTUN_REPO_REF:-${DEFAULT_REPO_REF}}"
  local install_dir="${SINGTUN_INSTALL_DIR:-${DEFAULT_INSTALL_DIR}}"
  local bin_dir="${SINGTUN_BIN_DIR:-${DEFAULT_BIN_DIR}}"

  while (( $# > 0 )); do
    case "$1" in
      --install-only)
        install_only="true"
        shift
        ;;
      --update)
        update_mode="true"
        shift
        ;;
      --dir)
        [[ $# -ge 2 && -n "$2" ]] || die "--dir 需要提供目录路径"
        install_dir="$2"
        shift 2
        ;;
      --repo)
        [[ $# -ge 2 && -n "$2" ]] || die "--repo 需要提供仓库地址"
        repo_url="$2"
        shift 2
        ;;
      --ref)
        [[ $# -ge 2 && -n "$2" ]] || die "--ref 需要提供分支或标签名"
        repo_ref="$2"
        shift 2
        ;;
      --bin-dir)
        [[ $# -ge 2 && -n "$2" ]] || die "--bin-dir 需要提供目录路径"
        bin_dir="$2"
        shift 2
        ;;
      -h|--help)
        usage
        return 0
        ;;
      *)
        die "未知选项: $1（使用 --help 查看帮助）"
        ;;
    esac
  done

  if [[ "${EUID:-$(id -u)}" -ne 0 && "${SINGTUN_INSTALL_ALLOW_NONROOT_TEST:-false}" != "true" ]]; then
    die "请以 root 权限执行（示例: curl -fsSL ... | sudo bash）。"
  fi

  check_supported_os
  ensure_bootstrap_tools
  require_git_check() { command -v git >/dev/null 2>&1 || die "缺少 git 命令"; }
  require_git_check

  _INSTALL_BACKUP_DIR=""
  _INSTALL_STAGE_DIR=""
  _INSTALL_TARGET_DIR="${install_dir}"
  cleanup_install() {
    if [[ -n "${_INSTALL_BACKUP_DIR:-}" && -d "${_INSTALL_BACKUP_DIR}/private" && -n "${_INSTALL_TARGET_DIR:-}" && -d "${_INSTALL_TARGET_DIR}" && ! -d "${_INSTALL_TARGET_DIR}/private" ]]; then
      mkdir -p "${_INSTALL_TARGET_DIR}" 2>/dev/null || true
      cp -a "${_INSTALL_BACKUP_DIR}/private" "${_INSTALL_TARGET_DIR}/private" 2>/dev/null || true
    fi
    if [[ -n "${_INSTALL_BACKUP_DIR:-}" ]]; then
      rm -rf "${_INSTALL_BACKUP_DIR}" 2>/dev/null || true
    fi
    if [[ -n "${_INSTALL_STAGE_DIR:-}" ]]; then
      rm -rf "${_INSTALL_STAGE_DIR}" 2>/dev/null || true
    fi
  }
  trap cleanup_install EXIT

  mkdir -p "$(dirname "${install_dir}")"
  _INSTALL_BACKUP_DIR="$(mktemp -d)"
  chmod 700 "${_INSTALL_BACKUP_DIR}"

  if [[ -d "${install_dir}/private" ]]; then
    cp -a "${install_dir}/private" "${_INSTALL_BACKUP_DIR}/private"
    chmod 700 "${_INSTALL_BACKUP_DIR}/private"
  fi

  if [[ -d "${install_dir}/.git" ]]; then
    log_info "检测到已有仓库 (${install_dir})，正在更新至 ${repo_ref}..."
    git -C "${install_dir}" remote set-url origin "${repo_url}" 2>/dev/null || true
    if ! git -C "${install_dir}" fetch --depth 1 origin "${repo_ref}"; then
      die "从 ${repo_url} (${repo_ref}) 拉取更新失败，已有 private/ 已安全保留。"
    fi
    git -C "${install_dir}" reset --hard FETCH_HEAD
    git -C "${install_dir}" clean -fd -e private/
    if [[ -d "${_INSTALL_BACKUP_DIR}/private" && ! -d "${install_dir}/private" ]]; then
      cp -a "${_INSTALL_BACKUP_DIR}/private" "${install_dir}/private"
    fi
  else
    _INSTALL_STAGE_DIR="$(mktemp -d "${install_dir}.stage.XXXXXX")"
    rm -rf "${_INSTALL_STAGE_DIR}"
    log_info "正在克隆 singtun (${repo_ref}) 至 ${install_dir}..."
    if ! git clone --depth 1 --branch "${repo_ref}" "${repo_url}" "${_INSTALL_STAGE_DIR}"; then
      die "克隆仓库失败: ${repo_url} (${repo_ref})"
    fi
    if [[ -d "${_INSTALL_BACKUP_DIR}/private" ]]; then
      rm -rf "${_INSTALL_STAGE_DIR}/private"
      cp -a "${_INSTALL_BACKUP_DIR}/private" "${_INSTALL_STAGE_DIR}/private"
      chmod 700 "${_INSTALL_STAGE_DIR}/private"
    fi
    if [[ -e "${install_dir}" ]]; then
      rm -rf "${install_dir}"
    fi
    mv -f "${_INSTALL_STAGE_DIR}" "${install_dir}"
    _INSTALL_STAGE_DIR=""
  fi

  [[ -f "${install_dir}/singtun" ]] || die "安装目录缺少 singtun 可执行文件: ${install_dir}/singtun"
  chmod 755 "${install_dir}/singtun"

  mkdir -p "${bin_dir}"
  ln -sfn "${install_dir}/singtun" "${bin_dir}/singtun"
  log_info "已安装 CLI 软链: ${bin_dir}/singtun -> ${install_dir}/singtun"

  if [[ "${install_only}" == "true" ]]; then
    log_info "安装完成（--install-only）。运行 'sudo singtun setup' 开始配置并部署。"
    return 0
  fi

  if [[ "${update_mode}" == "true" ]]; then
    log_info "singtun 代码更新完成（已保留 ${install_dir}/private）。如需应用变更请运行 'sudo singtun deploy'。"
    return 0
  fi

  if [[ "${SINGTUN_SETUP_USE_STDIN:-false}" == "true" || -t 0 ]]; then
    exec "${bin_dir}/singtun" setup
  elif [[ -r /dev/tty ]]; then
    exec "${bin_dir}/singtun" setup </dev/tty
  else
    log_warn "当前环境无可用交互终端 (/dev/tty)，已跳过交互向导。请稍后执行: sudo singtun setup"
  fi
}

main "$@"
