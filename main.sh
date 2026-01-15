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

# functions
## cluster
start_cluster() {
  if ! minikube status; then
    minikube start --cpus "$CPUS" --memory "$MEMORY" --cni "$CNI"
  fi
}

## github 

## controller
get_controller_values_template() {
  mkdir -p "$CONTROLLER_CHART_DIR"
  helm show values "$CONTROLLER_CHART_URL" >"$CONTROLLER_CHART_DIR/values.yaml"
}

change_update_strategy() {
  if ! [ -f "$WORKDIR/$CONTROLLER_CHART_DIR/values.yaml" ]; then
    echo "Controller values.yaml file not found"
    return 1
  fi

  yq --inplace ".flags.updateStrategy = \"$CONTROLLER_UPDATE_STRATEGY\"" "$WORKDIR/$CONTROLLER_CHART_DIR/values.yaml"
}

configure_controller() {
  get_controller_values_template
  change_update_strategy
}

install_controller() {
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
    echo "Scale set number not provided"
    return 1
  fi

  mkdir -p "$SCALE_SET_CHART_DIR-$number"
  helm show values "$SCALE_SET_CHART_URL" >"$WORKDIR/$SCALE_SET_CHART_DIR-$number/values.yaml"
}

setup_pat_token() {
  local number=$1
  if [[ -z $number ]]; then
    echo "Scale set number not provided"
    return 1
  fi

  yq 'del(.githubConfigSecret.github_token)' "$WORKDIR/$SCALE_SET_CHART_DIR-$number/values.yaml"

}



# main
get_scale_set_values_template "$1"
