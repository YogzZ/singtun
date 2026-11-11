#!/usr/bin/env bash
# scripts/hooks/install-hooks.sh — 幂等安装本地原生 Git 防泄漏与静态检查钩子（无需依赖 Python pre-commit）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MARKER="# Managed by ssctl (install-hooks.sh)"

if ! command -v git >/dev/null 2>&1 || ! git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf '\033[1;33m[WARN]\033[0m 当前目录不是 Git 工作区，跳过 Git 钩子安装。\n' >&2
  exit 0
fi

HOOKS_DIR="$(git -C "${REPO_ROOT}" rev-parse --git-path hooks)"
if [[ "${HOOKS_DIR}" != /* ]]; then
  HOOKS_DIR="${REPO_ROOT}/${HOOKS_DIR}"
fi
if ! mkdir -p "${HOOKS_DIR}" 2>/dev/null || [[ ! -w "${HOOKS_DIR}" ]]; then
  printf '\033[1;33m[WARN]\033[0m Git hooks 目录不可写 (%s)，跳过钩子自动更新。\n' "${HOOKS_DIR}" >&2
  exit 0
fi

install_single_hook() {
  local hook_name="$1"
  local hook_path="${HOOKS_DIR}/${hook_name}"
  local new_content
  new_content="$(cat)"

  if [[ -f "${hook_path}" ]] && ! grep -Fq "${MARKER}" "${hook_path}"; then
    printf '\033[1;34m[INFO]\033[0m 检测到已有外部 Git 钩子 (%s)，保留现有配置。\n' "${hook_path}"
    return 0
  fi

  if [[ -f "${hook_path}" && -x "${hook_path}" ]] && [[ "$(<"${hook_path}")" == "${new_content}" ]]; then
    return 0
  fi

  printf '%s\n' "${new_content}" > "${hook_path}"
  chmod 755 "${hook_path}"
  printf '\033[1;34m[INFO]\033[0m 已启用 Git 钩子: %s\n' "${hook_path}"
}

install_single_hook "pre-commit" <<'EOF'
#!/usr/bin/env bash
# Managed by ssctl (install-hooks.sh)
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"

bash "${REPO_ROOT}/scripts/hooks/check-private-leak.sh" --staged

if command -v shellcheck >/dev/null 2>&1; then
  mapfile -t staged_sh < <(git diff --cached --name-only --diff-filter=ACMR | grep -E '^(ssctl|scripts/.*\.sh)$' || true)
  if (( ${#staged_sh[@]} > 0 )); then
    (cd "${REPO_ROOT}" && shellcheck -x "${staged_sh[@]}")
  fi
fi

if command -v gitleaks >/dev/null 2>&1; then
  gitleaks protect --staged --redact --source "${REPO_ROOT}"
fi
EOF

install_single_hook "commit-msg" <<'EOF'
#!/usr/bin/env bash
# Managed by ssctl (install-hooks.sh)
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"

bash "${REPO_ROOT}/scripts/hooks/check-private-leak.sh" --commit-msg "$1"
EOF
