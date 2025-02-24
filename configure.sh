#!/bin/bash

set -eu

SRCDIR="$(dirname "$0")"
DEFAULT_BUILD_NAME="proton-localbuild" # If no --build-name specified

# Output helpers
COLOR_ERR=""
COLOR_STAT=""
COLOR_INFO=""
COLOR_CMD=""
COLOR_CLEAR=""
if [[ $(tput colors 2>/dev/null || echo 0) -gt 0 ]]; then
  COLOR_ERR=$'\e[31;1m'
  COLOR_STAT=$'\e[32;1m'
  COLOR_INFO=$'\e[30;1m'
  COLOR_CMD=$'\e[93;1m'
  COLOR_CLEAR=$'\e[0m'
fi

sh_quote() { 
        local quoted
        quoted="$(printf '%q ' "$@")"; [[ $# -eq 0 ]] || echo "${quoted:0:-1}"; 
}
err()      { echo >&2 "${COLOR_ERR}!!${COLOR_CLEAR} $*"; }
stat()     { echo >&2 "${COLOR_STAT}::${COLOR_CLEAR} $*"; }
info()     { echo >&2 "${COLOR_INFO}::${COLOR_CLEAR} $*"; }
showcmd()  { echo >&2 "+ ${COLOR_CMD}$(sh_quote "$@")${COLOR_CLEAR}"; }
die()      { err "$@"; exit 1; }
finish()   { stat "$@"; exit 0; }
cmd()      { showcmd "$@"; "$@"; }

#
# Configure
#

THIS_COMMAND="$0 $*" # For printing, not evaling
MAKEFILE="./Makefile"

# This is not rigorous.  Do not use this for untrusted input.  Do not.  If you need a version of
# this for untrusted input, rethink the path that got you here.
function escape_for_make() {
  local escape="$1"
  escape="${escape//\\/\\\\}" #  '\' -> '\\'
  escape="${escape//#/\\#}"   #  '#' -> '\#'
  escape="${escape//\$/\$\$}" #  '$' -> '$$'
  escape="${escape// /\\ }"   #  ' ' -> '\ '
  echo "$escape"
}

function configure() {
  local steamrt_image="$1"
  local steamrt_name="$2"
  local srcdir
  srcdir="$(dirname "$0")"

  # Build name
  local build_name="$arg_build_name"
  if [[ -n $build_name ]]; then
    info "Configuring with build name: $build_name"
  else
    build_name="$DEFAULT_BUILD_NAME"
    info "No build name specified, using default: $build_name"
  fi

  ## Write out config
  # Don't die after this point or we'll have rather unhelpfully deleted the Makefile
  [[ ! -e "$MAKEFILE" ]] || rm "$MAKEFILE"

  {
    # Config
    echo "# Generated by: $THIS_COMMAND"
    echo ""
    echo "SRCDIR     := $(escape_for_make "$srcdir")"
    echo "BUILD_NAME := $(escape_for_make "$build_name")"

    # ffmpeg?
    if [[ -n $arg_ffmpeg ]]; then
      echo "WITH_FFMPEG := 1"
    fi

    # SteamRT
    echo "STEAMRT_NAME  := $(escape_for_make "$steamrt_name")"
    echo "STEAMRT_IMAGE := $(escape_for_make "$steamrt_image")"

    if [[ -n "$arg_docker_opts" ]]; then
      echo "DOCKER_OPTS := $arg_docker_opts"
    fi

    # Include base
    echo ""
    echo "include \$(SRCDIR)/build/makefile_base.mak"
  } >> "$MAKEFILE"

  stat "Created $MAKEFILE, now run make to build."
  stat "  See README.md for make targets and instructions"
}

#
# Parse arguments
#

arg_steamrt="soldier"
arg_steamrt_image=""
arg_no_steamrt=""
arg_ffmpeg=""
arg_build_name=""
arg_docker_opts=""
arg_help=""
invalid_args=""
function parse_args() {
  local arg;
  local val;
  local val_used;
  local val_passed;
  while [[ $# -gt 0 ]]; do
    arg="$1"
    val=''
    val_used=''
    val_passed=''
    if [[ -z $arg ]]; then # Sanity
      err "Unexpected empty argument"
      return 1
    elif [[ ${arg:0:2} != '--' ]]; then
      err "Unexpected positional argument ($1)"
      return 1
    fi

    # Looks like an argument does it have a --foo=bar value?
    if [[ ${arg%=*} != "$arg" ]]; then
      val="${arg#*=}"
      arg="${arg%=*}"
      val_passed=1
    else
      # Otherwise for args that want a value, assume "--arg val" form
      val="${2:-}"
    fi

    # The args
    if [[ $arg = --help || $arg = --usage ]]; then
      arg_help=1
    elif [[ $arg = --build-name ]]; then
      arg_build_name="$val"
      val_used=1
    elif [[ $arg = --docker-opts ]]; then
      arg_docker_opts="$val"
      val_used=1
    elif [[ $arg = --with-ffmpeg ]]; then
      arg_ffmpeg=1
    elif [[ $arg = --steam-runtime-image ]]; then
      val_used=1
      arg_steamrt_image="$val"
    elif [[ $arg = --steam-runtime ]]; then
      val_used=1
      arg_steamrt="$val"
    elif [[ $arg = --no-steam-runtime ]]; then
      arg_no_steamrt=1
    else
      err "Unrecognized option $arg"
      return 1
    fi

    # Check if this arg used the value and shouldn't have or vice-versa
    if [[ -n $val_used && -z $val_passed ]]; then
      # "--arg val" form, used $2 as the value.

      # Don't allow this if it looked like "--arg --val"
      if [[ ${val#--} != "$val" ]]; then
        err "Ambiguous format for argument with value \"$arg $val\""
        err "  (use $arg=$val or $arg='' $val)"
        return 1
      fi

      # Error if this was the last positional argument but expected $val
      if [[ $# -le 1 ]]; then
        err "$arg takes a parameter, but none given"
        return 1
      fi

      shift # consume val
    elif [[ -z $val_used && -n $val_passed ]]; then
      # Didn't use a value, but passed in --arg=val form
      err "$arg does not take a parameter"
      return 1
    fi

    shift # consume arg
  done
}

usage() {
  "$1" "Usage: $0 { --no-steam-runtime | --steam-runtime-image=<image> --steam-runtime=<name> }"
  "$1" "  Generate a Makefile for building Proton.  May be run from another directory to create"
  "$1" "  out-of-tree build directories (e.g. mkdir mybuild && cd mybuild && ../configure.sh)"
  "$1" ""
  "$1" "  Options"
  "$1" "    --help / --usage     Show this help text and exit"
  "$1" ""
  "$1" "    --build-name=<name>  Set the name of the build that displays when used in Steam"
  "$1" ""
  "$1" "    --with-ffmpeg        Build ffmpeg for WMA audio support"
  "$1" ""
  "$1" "    --docker-opts='<options>' Extra options to pass to Docker when invoking the runtime."
  "$1" ""
  "$1" "  Steam Runtime"
  "$1" "    Proton builds that are to be installed & run under the steam client must be built with"
  "$1" "    the Steam Runtime SDK to ensure compatibility.  See README.md for more information."
  "$1" ""
  "$1" "    --steam-runtime-image=<image>  Automatically invoke the Steam Runtime SDK in <image>"
  "$1" "                                   for build steps that must be run in an SDK"
  "$1" "                                   environment.  See README.md for instructions to"
  "$1" "                                   create this image."
  "$1" "    --steam-runtime=soldier  Name of the steam runtime release to build for (soldier, scout)."
  "$1" ""
  "$1" "    --no-steam-runtime  Do not automatically invoke any runtime SDK as part of the build."
  "$1" "                        Build steps may still be manually run in a runtime environment."
  exit 1;
}

[[ $# -gt 0 ]] || usage info
parse_args "$@" || usage err
[[ -z $arg_help ]] || usage info

# Sanity check arguments
if [[ -n $arg_no_steamrt && -n $arg_steamrt_image ]]; then
    die "Cannot specify --steam-runtime-image as well as --no-steam-runtime"
elif [[ -z $arg_no_steamrt && -z $arg_steamrt_image ]]; then
    die "Must specify either --no-steam-runtime or --steam-runtime-image"
fi

configure "$arg_steamrt_image" "$arg_steamrt"
