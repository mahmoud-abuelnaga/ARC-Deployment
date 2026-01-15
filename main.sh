#!/usr/bin/env bash

set -e          # Exit immediately if a command exits with a non-zero status
set -o pipefail # Prevent errors in a pipeline from being masked
set -u          # Treat unset variables as an error

# General variables
WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# minikube configuration
CPUS=2
MEMORY="4g"
CNI="calico"

# controller configuration
CONTROLLER_CHART_URL="oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller:0.13.1"
CONTROLLER_CHART_DIR="gha-runner-scale-set-controller"
CONTROLLER_UPDATE_STRATEGY="eventual"
CONTROLLER_RELEASE_NAME="gha-runner-scale-set-controller"
CONTROLLER_NAMESPACE="arc-system"

# scale set configuration
SCALE_SET_CHART_URL="oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set:0.13.1"
SCALE_SET_CHART_DIR="gha-runner-scale-set"
SCALE_SET_RELEASE_NAME="gha-runner-scale-set"
SCALE_SET_NAMESPACE="arc-runners"
REPOSITORY_SCALE_SET_REGISTERED_TO="https://github.com/mahmoud-abuelnaga/ARC-Deployment"

# github app configuration
GITHUB_APP_CONFIG_PATH="github/apps/arc.json"
GITHUB_APP_CREDENTIALS_PATH="github/apps/credentials.json"
GITHUB_APP_PRIVATE_KEY_PATH="tmp/private_key.pem"
PYTHON_SERVER_PORT=8000
REQUESTS_LOG_FILE_PATH="requests.log"
GITHUB_APP_DIR_PATH="github/apps"
github_app_installation_id=""
github_app_id=""
github_app_name=""
python_server_pid=""
ngrok_pid=""

# functions
## cluster
start_cluster() {
  if ! minikube status; then
    minikube start --cpus "$CPUS" --memory "$MEMORY" --cni "$CNI"
  fi
}

## github app
start_ngrok() {
  local port
  port=$1

  if ! command -v ngrok &>/dev/null; then
    echo "Error: ngrok could not be found" >&2
    return 1
  fi

  if pgrep -f "ngrok" &>/dev/null; then
    echo "Error: ngrok is already running" >&2
    return 1
  fi

  echo "Starting ngrok on port $port..." >&2
  ngrok http "$port" >/dev/null 2>&1 &
  ngrok_pid=$!
}

get_ngrok_url() {
  curl -s http://127.0.0.1:4040/api/tunnels | jq -r '.tunnels[0].public_url'
}

start_python_server() {
  local port
  port=$1

  python3 -c "
import http.server
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        print(self.path, flush=True) # Print path to stdout (captured by wrapper)
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'App created! You can close this tab and return to the terminal.')

server = http.server.HTTPServer(('127.0.0.1', $port), Handler)
server.handle_request() # Handle only one request then exit
" >"$WORKDIR/$REQUESTS_LOG_FILE_PATH" &
  python_server_pid=$!
}

create_github_app() {
  if ! [ -f "$WORKDIR/$GITHUB_APP_CREDENTIALS_PATH" ]; then
    if ! [ -f "$WORKDIR/$GITHUB_APP_CONFIG_PATH" ]; then
      echo "Error: GitHub app configuration not found" >&2
      return 1
    fi

    start_ngrok "$PYTHON_SERVER_PORT"
    echo "ngrok started with PID: $ngrok_pid" >&2

    sleep 2

    local ngrok_url
    ngrok_url=$(get_ngrok_url)
    echo "ngrok URL: $ngrok_url" >&2

    start_python_server "$PYTHON_SERVER_PORT"
    echo "Python server started with PID: $python_server_pid" >&2

    sleep 2

    jq ".redirect_url = \"$ngrok_url/hook\"" "$WORKDIR/$GITHUB_APP_CONFIG_PATH" | sponge "$WORKDIR/$GITHUB_APP_CONFIG_PATH"

    local manifest
    manifest=$(jq -c . "$WORKDIR/$GITHUB_APP_CONFIG_PATH")

    local html_file
    html_file=$(mktemp --suffix=.html)

    cat >"$html_file" <<EOF
<!DOCTYPE html>
<html>
<body>
  <h1>Redirecting to GitHub to create the app...</h1>
  <form id="manifest-form" method="post" action="https://github.com/settings/apps/new">
    <input type="hidden" name="manifest" value='$manifest'>
    <input type="submit" value="Create GitHub App" style="display: none;">
  </form>
  <script>
    // Auto-submit the form
    document.getElementById('manifest-form').submit();
  </script>
</body>
</html>
EOF

    echo "Opening browser to create GitHub App..."
    xdg-open "$html_file" 2>/dev/null || open "$html_file" 2>/dev/null || echo "Please open $html_file in your browser"

    wait "$python_server_pid"
    kill "$ngrok_pid"
    rm "$html_file"

    local code
    code=$(grep "/hook" "$WORKDIR/$REQUESTS_LOG_FILE_PATH" | grep -o 'code=[^&]*' | cut -d= -f2)
    echo "Code: $code" >&2
    rm "$WORKDIR/$REQUESTS_LOG_FILE_PATH"

    if [[ -z $code ]]; then
      echo "Error: Code not found" >&2
      return 1
    fi

    curl -s -X POST \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/app-manifests/$code/conversions" \
      >"$WORKDIR/$GITHUB_APP_CREDENTIALS_PATH"
  fi

  mkdir -p "$WORKDIR/tmp"
  jq -r '.pem' "$WORKDIR/$GITHUB_APP_CREDENTIALS_PATH" >"$WORKDIR/tmp/private_key.pem"

  github_app_id=$(jq -r '.id' "$WORKDIR/$GITHUB_APP_CREDENTIALS_PATH")
  github_app_name=$(jq -r '.name' "$WORKDIR/$GITHUB_APP_CREDENTIALS_PATH")
}

install_github_app() {
  if [[ -z $github_app_name ]]; then
    echo "Error: GitHub app name not found" >&2
    return 1
  fi

  xdg-open "https://github.com/settings/apps/$github_app_name/installations" 2>/dev/null ||
    open "https://github.com/settings/apps/$github_app_name/installations" 2>/dev/null ||
    echo "Please open https://github.com/settings/apps/$github_app_name/installations in your browser"

  read -rp "Enter the installation ID: " github_app_installation_id
}

deploy_github_app() {
  create_github_app
  install_github_app
}

## controller
get_controller_values_template() {
  mkdir -p "$CONTROLLER_CHART_DIR"
  helm show values "$CONTROLLER_CHART_URL" >"$CONTROLLER_CHART_DIR/values.yaml"
}

change_update_strategy() {
  if ! [ -f "$WORKDIR/$CONTROLLER_CHART_DIR/values.yaml" ]; then
    echo "Controller values.yaml file not found" >&2
    return 1
  fi

  yq --inplace ".flags.updateStrategy = \"$CONTROLLER_UPDATE_STRATEGY\"" "$WORKDIR/$CONTROLLER_CHART_DIR/values.yaml"
}

configure_controller() {
  get_controller_values_template
  change_update_strategy
}

deploy_controller() {
  configure_controller

  helm upgrade --install "$CONTROLLER_RELEASE_NAME" "$CONTROLLER_CHART_URL" \
    -f "$WORKDIR/$CONTROLLER_CHART_DIR/values.yaml" \
    --namespace "$CONTROLLER_NAMESPACE" \
    --create-namespace
}

## scale set
get_scale_set_values_template() {
  local number=$1
  if [[ -z $number ]]; then
    echo "Scale set number not provided" >&2
    return 1
  fi

  mkdir -p "$SCALE_SET_CHART_DIR-$number"
  helm show values "$SCALE_SET_CHART_URL" >"$WORKDIR/$SCALE_SET_CHART_DIR-$number/values.yaml"
}

create_github_credentials_secrets() {
  if [[ -z $github_app_id || -z $github_app_installation_id || ! -f $GITHUB_APP_PRIVATE_KEY_PATH ]]; then
    echo "Error: GitHub app configuration not found" >&2
    return 1
  fi

  kubectl create namespace "$SCALE_SET_NAMESPACE" || true
  kubectl delete secret "$github_app_name" --namespace "$SCALE_SET_NAMESPACE" || true
  kubectl create secret generic "$github_app_name" \
    --from-literal=github_app_id="$github_app_id" \
    --from-literal=github_app_installation_id="$github_app_installation_id" \
    --from-file=github_app_private_key="$WORKDIR/$GITHUB_APP_PRIVATE_KEY_PATH" \
    --namespace "$SCALE_SET_NAMESPACE"
}

configure_scale_set_values() {
  local number=$1
  if [[ -z $number ]]; then
    echo "Scale set number not provided" >&2
    return 1
  fi

  local mode="${2:-dind}"
  local min_runners="${3:-}"
  local max_runners="${4:-}"

  create_github_credentials_secrets
  yq --inplace 'del(.githubConfigSecret.github_token)' "$WORKDIR/$SCALE_SET_CHART_DIR-$number/values.yaml"
  yq --inplace ".githubConfigSecret = \"$github_app_name\"" "$WORKDIR/$SCALE_SET_CHART_DIR-$number/values.yaml"
  yq --inplace ".githubConfigUrl = \"$REPOSITORY_SCALE_SET_REGISTERED_TO\"" "$WORKDIR/$SCALE_SET_CHART_DIR-$number/values.yaml"
  yq --inplace ".containerMode.type = \"$mode\"" "$WORKDIR/$SCALE_SET_CHART_DIR-$number/values.yaml"
  if [ -n "$min_runners" ]; then
    yq --inplace ".minRunners = $min_runners" "$WORKDIR/$SCALE_SET_CHART_DIR-$number/values.yaml"
  fi
  if [ -n "$max_runners" ]; then
    yq --inplace ".maxRunners = $max_runners" "$WORKDIR/$SCALE_SET_CHART_DIR-$number/values.yaml"
  fi

  if [[ $mode == "kubernetes" ]]; then
    yq --inplace ".template.spec.containers[0].env[0].name = \"ACTIONS_RUNNER_REQUIRE_JOB_CONTAINER\"" "$WORKDIR/$SCALE_SET_CHART_DIR-$number/values.yaml"
    yq --inplace ".template.spec.containers[0].env[0].value = \"false\"" "$WORKDIR/$SCALE_SET_CHART_DIR-$number/values.yaml"
    yq --inplace ".containerMode.kubernetesModeWorkVolumeClaim.accessModes[0] = \"ReadWriteOnce\"" "$WORKDIR/$SCALE_SET_CHART_DIR-$number/values.yaml"
    yq --inplace ".containerMode.kubernetesModeWorkVolumeClaim.storageClassName = \"standard\"" "$WORKDIR/$SCALE_SET_CHART_DIR-$number/values.yaml"
    yq --inplace ".containerMode.kubernetesModeWorkVolumeClaim.resources.requests.storage = \"1Gi\"" "$WORKDIR/$SCALE_SET_CHART_DIR-$number/values.yaml"
  fi
}

deploy_scale_set() {
  local number=$1
  if [[ -z $number ]]; then
    echo "Scale set number not provided" >&2
    return 1
  fi

  local mode="${2:-}"
  local min_runners="${3:-}"
  local max_runners="${4:-}"

  get_scale_set_values_template "$number"
  configure_scale_set_values "$number" "$mode" "$min_runners" "$max_runners"

  helm upgrade --install "$SCALE_SET_RELEASE_NAME-$number" "$SCALE_SET_CHART_URL" \
    -f "$WORKDIR/$SCALE_SET_CHART_DIR-$number/values.yaml" \
    --namespace "$SCALE_SET_NAMESPACE" \
    --create-namespace
}

# main
## cluster
start_cluster

## github app
deploy_github_app

## controller
deploy_controller

## scale set
deploy_scale_set 1 "dind" 2 ""
deploy_scale_set 2 "kubernetes" 2 ""
