# AI convert from https://github.com/hraban/mac-app-util/blob/master/main.lisp
set -euo pipefail

DRY_RUN=${DRY_RUN:-}
DEBUGSH=${DEBUGSH:-}

PLUTIL="/usr/bin/plutil"
OSACOMPILE="/usr/bin/osacompile"
DOCKUTIL="dockutil"

copyable_app_props=(
  "CFBundleDevelopmentRegion"
  "CFBundleDocumentTypes"
  "CFBundleGetInfoString"
  "CFBundleIconFile"
  "CFBundleIdentifier"
  "CFBundleInfoDictionaryVersion"
  "CFBundleName"
  "CFBundleShortVersionString"
  "CFBundleURLTypes"
  "NSAppleEventsUsageDescription"
  "NSAppleScriptEnabled"
  "NSDesktopFolderUsageDescription"
  "NSDocumentsFolderUsageDescription"
  "NSDownloadsFolderUsageDescription"
  "NSPrincipalClass"
  "NSRemovableVolumesUsageDescription"
  "NSServices"
  "UTExportedTypeDeclarations"
)

dry_run_echo() {
  if [[ -n $DRY_RUN ]]; then
    echo "exec: $*"
  else
    "$@"
  fi
}

debug_run() {
  if [[ -n $DEBUGSH ]]; then
    echo "+ $*"
  fi
  if [[ -n $DRY_RUN ]]; then
    echo "(dry-run) $*"
  else
    eval "$@"
  fi
}

in_temp_dir() {
  dir=$(mktemp -d)
  trap "rm -rf '$dir'" EXIT
  pushd "$dir" > /dev/null
  "$@"
  popd > /dev/null
  trap - EXIT
}

copy_file() {
  local src=$1
  local dst=$2
  if [[ -n $DRY_RUN ]]; then
    echo "cp $src $dst"
  else
    cp -a "$src" "$dst"
  fi
}

copy_paths() {
  local from=$1
  local to=$2

  # Build jq filter from keys
  local keys_json
  keys_json=$(printf '%s\n' "${copyable_app_props[@]}" | jq -R . | jq -s .)

  in_temp_dir bash -c "
    set -eu
    cp -a '$from' orig
    cp -a '$to' bare-wrapper
    $PLUTIL -convert json -- orig
    $PLUTIL -convert json -- bare-wrapper

    jq_filter='to_entries | map(select(.key as \$k | ${keys_json} | index(\$k) != null)) | from_entries'

    jq --argjson keys '$keys_json' \"$jq_filter\" < orig > filtered

    jq -s '.[0] + .[1]' filtered bare-wrapper > final

    $PLUTIL -convert xml1 -- final

    cp final '$to'
  "
}

resources() {
  local app=$1
  echo "${app}/Contents/Resources"
}

infoplist() {
  local app=$1
  echo "${app}/Contents/Info.plist"
}

app_p() {
  local path=$1
  [[ -f "$(infoplist "$path")" ]]
}

sync_icons() {
  local from=$1
  local to=$2
  from_cnts=$(resources "$from")
  to_cnts=$(resources "$to")

  if [[ -d "$from_cnts" ]]; then
    debug_run "find \"$to_cnts\" -name '*.icns' -delete"
    debug_run "rsync --include='*.icns' --exclude='*' --recursive --links \"$from_cnts/\" \"$to_cnts/\""
  fi
}

mktrampoline_app() {
  local app=$1
  local trampoline=$2

  local cmd="do shell script \"open '$app'\""

  if [[ -n $DRY_RUN ]]; then
    echo "$OSACOMPILE -o \"$trampoline\" -e \"$cmd\""
  else
    $OSACOMPILE -o "$trampoline" -e "$cmd"
  fi
  sync_icons "$app" "$trampoline"
  copy_paths "$(infoplist "$app")" "$(infoplist "$trampoline")"
  if [[ -z $DRY_RUN ]]; then
    touch "$trampoline"
  fi
}

mktrampoline_bin() {
  local bin=$1
  local trampoline=$2

  local cmd="do shell script \"'$bin' &> /dev/null &\""
  if [[ -n $DRY_RUN ]]; then
    echo "$OSACOMPILE -o \"$trampoline\" -e \"$cmd\""
  else
    $OSACOMPILE -o "$trampoline" -e "$cmd"
  fi
}

mktrampoline() {
  local from=$1
  local to=$2
  if [[ -d "$from" ]]; then
    if app_p "$from"; then
      mktrampoline_app "$from" "$to"
    else
      echo "Error: $from is a directory but not a Mac app (no Info.plist)" >&2
      return 1
    fi
  else
    if [[ -f "$from" ]]; then
      mktrampoline_bin "$from" "$to"
    else
      echo "Error: file $from not found" >&2
      return 1
    fi
  fi
}

rootp() {
  [[ $(id -un) == "root" ]]
}

realpath_func() {
  realpath "$1"
}

sync_dock() {
  local apps=("$@")
  # Clear SUDO_USER to avoid dockutil issues
  unset SUDO_USER

  local dockutil_args=()
  if rootp; then
    dockutil_args+=(--allhomes)
  fi

  local persistents
  persistents=$(dockutil "${dockutil_args[@]}" --list | grep "/nix/store" | grep "persistentApps" | cut -f1)

  for existing in $persistents; do
    for app in "${apps[@]}"; do
      if [[ "$(basename "$existing")" == "$(basename "$app" .app)" ]]; then
        local abs_app
        abs_app=$(realpath_func "$app")
        debug_run dockutil "${dockutil_args[@]}" --add "$abs_app" --replacing "$existing"
      fi
    done
  done
}

sync_trampolines() {
  local from=$1
  local to=$2
  if [[ -d "$to" && -z $DRY_RUN ]]; then
    debug_run rm -rf "$to"
  fi
  mkdir -p "$to"

  # Gather .app recursively 1 level deep
  mapfile -t apps < <(find "$from" -maxdepth 2 -name '*.app' -type d)
  for app in "${apps[@]}"; do
    local trampoline_target="$to/$(basename "$app")"
    mktrampoline "$app" "$trampoline_target"
  done

  sync_dock "${apps[@]}"
}

print_usage() {
  cat <<EOF
Usage:

  mac-app-util mktrampoline FROM.app TO.app
  mac-app-util sync-dock Foo.app Bar.app ...
  mac-app-util sync-trampolines /my/nix/Applications /Applications/MyTrampolines/

mktrampoline creates a “trampoline” application launcher that immediately
launches another application.

sync-dock updates persistent items in your dock if any of the given apps has the
same name. This can be used to programmatically keep pinned items in your dock
up to date with potential new versions of an app outside of the /Applications
directory, without having to check which one is pinned etc.

sync-trampolines is an all-in-1 solution that syncs an entire directory of *.app
files to another by creating a trampoline launcher for every app, deleting the
rest, and updating the dock.
EOF
}

main() {
  if [[ $# -lt 1 ]]; then
    print_usage
    exit 1
  fi

  case "$1" in
    mktrampoline)
      if [[ $# -ne 3 ]]; then
        print_usage
        exit 1
      fi
      mktrampoline "$2" "$3"
      ;;
    sync-dock)
      if [[ $# -lt 2 ]]; then
        print_usage
        exit 1
      fi
      shift
      sync_dock "$@"
      ;;
    sync-trampolines)
      if [[ $# -ne 3 ]]; then
        print_usage
        exit 1
      fi
      sync_trampolines "$2" "$3"
      ;;
    -h|--help)
      print_usage
      ;;
    *)
      print_usage
      exit 1
      ;;
  esac
}

main "$@"


