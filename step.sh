#!/bin/sh
# Faintprint pipeline step — the one script behind the GitHub Action
# (action.yml) and the GitLab template (templates/scan.yml).
#
#   step.sh check      the inputs make sense and the deploy token is there
#   step.sh install    Faintprint from the private index, into its own environment
#   step.sh scan       run the scan; ends with Faintprint's own exit code
#   step.sh result N   one plain line for exit code N, then exit N
#
# Everything arrives in environment variables, never as text pasted into a
# command, so nothing fed into an input can run as a command:
#
#   FP_PLATFORM          github | gitlab (how errors and warnings are shown)
#   FP_SCAN              what to scan, one per line
#   FP_TOOLS             NAME=FILE, one per line (may be empty)
#   FP_FAIL_ON           minor | suspicious | likely-attack | never
#   FP_REVIEW            true | false
#   FP_MAX_COST          US dollars, e.g. 1.00
#   FP_ALLOW_UNFINISHED  true | false
#   FP_VERSION           the Faintprint version to install, e.g. 0.2.0
#   FP_REPORTS           the report folder, kept as the job's artefact
#   FP_PYTHON            the Python that builds the environment
#   FP_VENV              where the environment is built
#   FP_CONSTRAINTS       the tested library list (may be empty)
#   FP_KEY_SET           true | false: whether a key was given (GitHub's check)
#   FAINTPRINT_USER, FAINTPRINT_TOKEN   the customer's deploy token
#   ANTHROPIC_API_KEY    the customer's key, for the AI review only
#
# The deploy token goes to pip only, in the password part of the index
# address, which pip prints as ****. The Anthropic key goes to the scan only,
# and only when the review is on. Nothing here prints either, and nothing
# here echoes an input into a GitHub workflow command before checking it.

set -eu

STEP_VERSION=1.0.0
INDEX=gitlab.com/api/v4/projects/faintprint%2Ffaintprint/packages/pypi/simple

say() { printf '%s\n' "$*"; }

error() {
  if [ "${FP_PLATFORM:-}" = github ]; then
    printf '::error title=Faintprint::%s\n' "$*"
  else
    printf 'ERROR: %s\n' "$*"
  fi
}

warning() {
  if [ "${FP_PLATFORM:-}" = github ]; then
    printf '::warning title=Faintprint::%s\n' "$*"
  else
    printf 'WARNING: %s\n' "$*"
  fi
}

# The non-blank lines of $1, each without surrounding blanks, one per line.
lines() {
  printf '%s\n' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d'
}

where_reports() {
  if [ "${FP_PLATFORM:-}" = github ]; then
    printf "the artefact '%s' on this run's summary page" "$FP_REPORTS"
  else
    printf "this job's artifacts, folder '%s' (Browse on the job page)" "$FP_REPORTS"
  fi
}

do_check() {
  bad=0
  if [ "${RUNNER_OS:-}" = Windows ]; then
    error "Windows runners are not supported. Use a Linux or macOS runner."
    exit 2
  fi
  if [ -z "${FAINTPRINT_USER:-}" ] || [ -z "${FAINTPRINT_TOKEN:-}" ]; then
    if [ "${FP_PLATFORM:-}" = github ]; then
      error "No deploy token reached the step: set the secrets FAINTPRINT_USER and FAINTPRINT_TOKEN and pass them as deploy-user and deploy-token. A pull request from a fork gets no secrets, so the step cannot run there."
    else
      error "No deploy token reached the job: set the CI/CD variables FAINTPRINT_USER and FAINTPRINT_TOKEN (Settings, CI/CD, Variables; the token masked). A protected variable reaches protected branches only."
    fi
    exit 2
  fi
  case "$FAINTPRINT_USER" in
    *[!A-Za-z0-9._+-]*) error "FAINTPRINT_USER has characters a deploy token's name never has. Check the secret."; bad=1 ;;
  esac
  case "$FAINTPRINT_TOKEN" in
    *[!A-Za-z0-9._~-]*) error "FAINTPRINT_TOKEN has characters a deploy token never has. Check the secret."; bad=1 ;;
  esac
  if [ -z "$(lines "${FP_SCAN:-}")" ]; then
    error "scan is empty: name at least one saved tool list, web address or MCP client config file, one per line."
    bad=1
  fi
  case "${FP_FAIL_ON:-}" in
    minor|suspicious|likely-attack|never) ;;
    *) error "fail-on must be one of: minor, suspicious, likely-attack, never."; bad=1 ;;
  esac
  case "${FP_REVIEW:-}" in
    true|false) ;;
    *) error "review must be true or false."; bad=1 ;;
  esac
  case "${FP_ALLOW_UNFINISHED:-}" in
    true|false) ;;
    *) error "allow-unfinished must be true or false."; bad=1 ;;
  esac
  case "${FP_MAX_COST:-}" in
    ''|*[!0-9.]*|.*|*.|*.*.*) error "max-cost must be a number of US dollars, like 1.00."; bad=1 ;;
  esac
  case "${FP_VERSION:-}" in
    *[!0-9.]*|.*|*.|*..*) error "version must look like 0.2.0."; bad=1 ;;
    *.*.*.*) error "version must look like 0.2.0."; bad=1 ;;
    *.*.*) ;;
    *) error "version must look like 0.2.0."; bad=1 ;;
  esac
  case "${FP_REPORTS:-}" in
    ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) error "reports must be a plain folder name: letters, digits, dot, dash and underscore."; bad=1 ;;
  esac
  [ "$bad" = 0 ] || exit 2

  key_set="${FP_KEY_SET:-}"
  if [ -z "$key_set" ]; then
    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then key_set=true; else key_set=false; fi
  fi
  if [ "$FP_REVIEW" = true ] && [ "$key_set" != true ]; then
    warning "review is on but no ANTHROPIC_API_KEY was given: the AI review will not run, and the result will be 'not finished' (exit 3)."
  fi
  say "Faintprint pipeline step $STEP_VERSION: inputs checked."
}

do_install() {
  started=$(date +%s)
  if ! "$FP_PYTHON" -m venv "$FP_VENV"; then
    error "Could not create a Python environment with $FP_PYTHON."
    exit 2
  fi
  set -- install --quiet --no-input --no-cache-dir --disable-pip-version-check \
    --only-binary :all: --index-url "https://$FAINTPRINT_USER:$FAINTPRINT_TOKEN@$INDEX"
  note="(not at a tested library list)"
  if [ -n "${FP_CONSTRAINTS:-}" ]; then
    tested=$(sed -n 's/^faintprint==//p' "$FP_CONSTRAINTS")
    if [ "$tested" = "$FP_VERSION" ]; then
      set -- "$@" -c "$FP_CONSTRAINTS"
      note="at the library versions it was tested on"
    else
      warning "Installing Faintprint $FP_VERSION without this step's tested library list, which is for Faintprint $tested. The step's release for $FP_VERSION carries its own."
    fi
  fi
  set -- "$@" "faintprint[connect]==$FP_VERSION"
  if ! (unset ANTHROPIC_API_KEY; "$FP_VENV/bin/python" -m pip "$@"); then
    error "Faintprint $FP_VERSION could not be installed from the private index. If pip says 401 or 403 above, the deploy token was refused: it may be wrong, revoked or expired. If it says no matching version, check the version input."
    exit 2
  fi
  installed=$("$FP_VENV/bin/faintprint" --version | sed -n 1p)
  say "Installed $installed $note, in $(( $(date +%s) - started )) s."
}

do_scan() {
  set -- scan --fail-on "$FP_FAIL_ON" --out "$FP_REPORTS"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    set -- "$@" --tools "$line"
  done <<EOF
$(lines "${FP_TOOLS:-}")
EOF
  if [ "$FP_REVIEW" = true ]; then
    set -- "$@" --review --yes --max-cost "$FP_MAX_COST"
  else
    unset ANTHROPIC_API_KEY
  fi
  if [ "$FP_ALLOW_UNFINISHED" = true ]; then
    set -- "$@" --allow-unfinished
  fi
  set -- "$@" --
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    set -- "$@" "$line"
  done <<EOF
$(lines "$FP_SCAN")
EOF
  unset FAINTPRINT_USER FAINTPRINT_TOKEN

  # A server's own text reaches the log (the passages a review reads); on
  # GitHub a line of it that starts with "::" would be read as a command.
  # Commands are switched off for the scan and back on after it.
  resume=""
  if [ "${FP_PLATFORM:-}" = github ]; then
    resume="faintprint-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    printf '::stop-commands::%s\n' "$resume"
  fi
  say "Running: faintprint $*"
  set +e
  "$FP_VENV/bin/faintprint" "$@"
  code=$?
  set -e
  if [ -n "$resume" ]; then
    printf '::%s::\n' "$resume"
  fi
  exit "$code"
}

do_result() {
  code="${1:-}"
  case "$code" in
    0) say "Faintprint: pass. The reports are in $(where_reports)." ;;
    1) error "Faintprint: fail. At least one server shows signs of an attack at or above the fail-on level ($FP_FAIL_ON). Open index.html in $(where_reports) to see which server and why." ;;
    2) error "Faintprint could not run: an unreadable or invalid file, or nothing to scan. The lines above say which." ;;
    3) error "Faintprint: not finished. Something was not checked: an AI review not run, a server not reachable, or a local server without its saved tool list. To finish it, turn on review (with ANTHROPIC_API_KEY), give the missing tool lists in tools, or set allow-unfinished to true to let it pass with a warning. The reports in $(where_reports) say what is missing." ;;
    *) error "Faintprint ended with an unexpected exit code."; code=2 ;;
  esac
  exit "$code"
}

case "${1:-}" in
  check) do_check ;;
  install) do_install ;;
  scan) do_scan ;;
  result) do_result "${2:-}" ;;
  *) error "usage: step.sh check | install | scan | result CODE"; exit 2 ;;
esac
