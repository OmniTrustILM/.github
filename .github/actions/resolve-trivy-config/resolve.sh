#!/usr/bin/env bash
# Resolve which Trivy config the vulnerability gate should use.
#
# Called by the reusable Docker workflows (containers-test.yml,
# containers-build-and-push.yml) just before the "Fail build on
# vulnerabilities" step. Decides between the bundled org-default policy and a
# repo-local override, and writes the chosen path to GITHUB_OUTPUT.
#
# Behaviour:
#   override not allowed (default) -> copy the bundled default into the
#                                     workspace and use it (org policy enforced),
#                                     and neutralize any repo-local .trivyignore
#   override allowed + file present -> use the repo's file (full replacement)
#   override allowed + file missing -> fail loudly (misconfiguration)
#
# Reads: INPUT_ALLOW_TRIVY_CONFIG_OVERRIDE, INPUT_TRIVY_CONFIG_PATH,
#        DEFAULT_CONFIG_SRC, GITHUB_OUTPUT, GITHUB_ENV, RUNNER_TEMP
set -euo pipefail

# Any value other than the exact string "true" falls through to the org
# default. This fail-closed default is intentional: an unexpected/empty value
# must never disable org policy enforcement.
allow="${INPUT_ALLOW_TRIVY_CONFIG_OVERRIDE:-false}"
override_path="${INPUT_TRIVY_CONFIG_PATH:-config/trivy.yaml}"
default_src="${DEFAULT_CONFIG_SRC:?DEFAULT_CONFIG_SRC must point at the bundled default trivy.yaml}"
default_dest=".trivy-default.yaml"

if [ "$allow" = "true" ]; then
  if [ -f "$override_path" ]; then
    echo "Trivy config: using repo override '$override_path' (allow-trivy-config-override=true)."
    resolved="$override_path"
  else
    echo "::error::allow-trivy-config-override is true but no Trivy config file was found at '$override_path'. Add the file or set allow-trivy-config-override to false to use the org default."
    exit 1
  fi
else
  if [ ! -f "$default_src" ]; then
    echo "::error::Bundled org-default Trivy config not found at '$default_src' (action packaging error)."
    exit 1
  fi
  # The workspace is the (untrusted) caller repo checkout. A committed symlink
  # named "$default_dest" could redirect this write outside the workspace
  # (symlink traversal), so refuse to write through one.
  if [ -L "$default_dest" ]; then
    echo "::error::'$default_dest' is a symlink in the checked-out repo; refusing to write the org-default Trivy config through it."
    exit 1
  fi
  cp "$default_src" "$default_dest"
  # Trivy auto-loads a repo-committed .trivyignore from the working directory,
  # which would silently suppress findings under the locked org default. Point
  # Trivy at an empty ignore file we control (outside the caller checkout) so
  # the default gate can't be weakened without opting into an override.
  empty_ignore="${RUNNER_TEMP:-/tmp}/trivy-empty-ignore"
  : > "$empty_ignore"
  echo "TRIVY_IGNOREFILE=$empty_ignore" >> "$GITHUB_ENV"
  echo "Trivy config: using org-default policy (override not enabled); repo-local .trivyignore neutralized."
  resolved="$default_dest"
fi

# Never hand the scan gate an empty/missing config: aquasecurity/trivy-action
# treats an empty trivy-config as "use Trivy defaults" (exit-code 0), which
# would silently disable the vulnerability gate. Fail closed instead.
if [ ! -s "$resolved" ]; then
  echo "::error::Resolved Trivy config '$resolved' is missing or empty; refusing to run with no policy."
  exit 1
fi

echo "config-file=${resolved}" >> "$GITHUB_OUTPUT"
