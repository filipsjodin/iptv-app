#!/usr/bin/env bash
# Installs a pre-commit hook that blocks commits containing secrets.
set -euo pipefail
hooks_dir="$(git rev-parse --git-path hooks)"
mkdir -p "$hooks_dir"
hook="$hooks_dir/pre-commit"
cat > "$hook" <<'HOOK'
#!/usr/bin/env bash
if ! command -v gitleaks >/dev/null 2>&1; then
  echo "gitleaks is not installed - commit aborted. Install it: winget install gitleaks" >&2
  exit 1
fi
cd "$(git rev-parse --show-toplevel)"
if ! gitleaks git --staged --config .gitleaks.toml --redact; then
  echo "gitleaks found possible secrets - commit aborted." >&2
  exit 1
fi
HOOK
chmod +x "$hook"
echo "Installed pre-commit hook at $hook"
