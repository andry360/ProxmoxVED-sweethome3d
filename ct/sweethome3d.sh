#!/usr/bin/env bash
_cs_boot="${COMMUNITY_SCRIPTS_CORE_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../core}/core/build.func"
source "$_cs_boot" 2>/dev/null || source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/core/build.func")
# Copyright (c) 2021-2026 community-scripts ORG
# Author: andry360
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://www.sweethome3d.com/

APP="SweetHome3D"
var_tags="${var_tags:-modeling;3d}"
var_cpu="${var_cpu:-2}"
var_unprivileged="${var_unprivileged:-1}"
#var_arm64="${var_arm64:-no}" # unset = ask the user; nothing here is a prebuilt binary, but it has never been run on arm64

if [[ -z "${var_os:-}" ]] && command -v pveversion >/dev/null 2>&1; then
  var_os=$(msg_menu "Choose the container OS" \
    "debian" "Debian 13" \
    "alpine" "Alpine 3.24 (smaller footprint)")
fi

if [[ "${var_os:-}" == "alpine" ]]; then
  var_ram="${var_ram:-1024}"
  var_disk="${var_disk:-6}"
  var_version="${var_version:-3.24}"
else
  var_ram="${var_ram:-2048}"
  var_disk="${var_disk:-8}"
  var_version="${var_version:-13}"
fi

header_info "$APP"
variables
color
catch_errors

update_deb_based() {
  msg_info "Updating packages"
  $STD apt update
  $STD apt -y upgrade
  msg_ok "Updated packages"

  safe_service_restart apache2
}

update_alpine() {
  msg_info "Updating packages"
  $STD apk -U upgrade
  msg_ok "Updated packages"

  $STD rc-service apache2 restart
}

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -f /opt/sweethome3d/index.html ]]; then
    msg_error "No Sweet Home 3D Online Installation Found!"
    exit
  fi

  msg_info "Checking for a new Sweet Home 3D release"
  SH3D_TAG=$(curl -fsSL "https://svn.code.sf.net/p/sweethome3d/code/tags/" |
    sed -n 's|.*href="\(V_[0-9][0-9_]*\)/".*|\1|p' | sort -t_ -k2,2n -k3,3n -k4,4n | tail -1)
  if [[ -z "$SH3D_TAG" ]]; then
    msg_error "Could not read the release tags from SourceForge"
    exit
  fi
  msg_ok "Checked for a new Sweet Home 3D release"

  if [[ "$SH3D_TAG" == "$(cat ~/.sweethome3d 2>/dev/null)" ]]; then
    msg_ok "Sweet Home 3D Online ${SH3D_TAG} is already up to date"
  else
    msg_info "Fetching Sweet Home 3D ${SH3D_TAG} sources"
    rm -rf /opt/sweethome3d-src
    mkdir -p /opt/sweethome3d-src/SweetHome3D
    $STD svn export --non-interactive --trust-server-cert \
      "https://svn.code.sf.net/p/sweethome3d/code/tags/${SH3D_TAG}/SweetHome3DJS" /opt/sweethome3d-src/SweetHome3DJS
    # The JS project transpiles ../SweetHome3D/src and links two jars out of
    # ../SweetHome3D/libtest, and it pins which desktop release it expects - 7.5.2 builds
    # against 7.5 - so the tag to pair with comes out of build.xml, not out of $SH3D_TAG.
    SH3D_DESKTOP_TAG="V_$(sed -n 's/.*name="SweetHome3D-version" value="\([^"]*\)".*/\1/p' \
      /opt/sweethome3d-src/SweetHome3DJS/build.xml | tr '.' '_')"
    $STD svn export --non-interactive --trust-server-cert \
      "https://svn.code.sf.net/p/sweethome3d/code/tags/${SH3D_DESKTOP_TAG}/SweetHome3D/src" /opt/sweethome3d-src/SweetHome3D/src
    $STD svn export --non-interactive --trust-server-cert \
      "https://svn.code.sf.net/p/sweethome3d/code/tags/${SH3D_DESKTOP_TAG}/SweetHome3D/libtest" /opt/sweethome3d-src/SweetHome3D/libtest
    msg_ok "Fetched Sweet Home 3D ${SH3D_TAG} sources"

    msg_info "Building Sweet Home 3D Online (Patience)"
    cd /opt/sweethome3d-src/SweetHome3DJS
    # JSweet reflects into a wide slice of javac's internals, which JDK 17+ blocks unless
    # those packages are opened. JAVA_TOOL_OPTIONS only recognizes "--flag=value" as a single
    # token - "--flag value" (space-separated) makes the JVM refuse to start at all - and Ant
    # forks a fresh JVM per <java> task, so the flags have to travel in the environment rather
    # than as ANT_OPTS, which would only reach Ant's own JVM.
    for _cs_javac_pkg in api code comp file jvm main model parser processing tree util; do
      JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:-}${JAVA_TOOL_OPTIONS:+ }--add-exports=jdk.compiler/com.sun.tools.javac.${_cs_javac_pkg}=ALL-UNNAMED --add-opens=jdk.compiler/com.sun.tools.javac.${_cs_javac_pkg}=ALL-UNNAMED"
    done
    export JAVA_TOOL_OPTIONS
    unset _cs_javac_pkg
    # Deliberately not silenced: this is the step that breaks, and an exit code on its own
    # tells a tester nothing about which transpilation unit failed.
    if ! ant applicationPhpDeploy; then
      msg_error "The Sweet Home 3D Online build failed - the complete Ant log is above"
      exit
    fi
    msg_ok "Built Sweet Home 3D Online"

    msg_info "Deploying Sweet Home 3D Online"
    # Replacing the tree rather than copying over it drops the generated lib/ files of the
    # previous release. The saved homes are not in here to lose - data is a symlink, and rm
    # removes the link, not the directory it points at.
    rm -rf /opt/sweethome3d
    mkdir -p /opt/sweethome3d
    cp -r /opt/sweethome3d-src/SweetHome3DJS/deployDirectHomeRecorder/. /opt/sweethome3d/
    # Upstream ships index.html without a doctype, which leaves browsers in quirks mode.
    sed -i '1i <!DOCTYPE html>' /opt/sweethome3d/index.html
    ln -sfn /opt/sweethome3d_data /opt/sweethome3d/data
    cat <<EOF >~/.sweethome3d
${SH3D_TAG}
EOF
    rm -rf /opt/sweethome3d-src
    msg_ok "Deployed Sweet Home 3D Online"
    msg_ok "Updated Sweet Home 3D Online to ${SH3D_TAG}"
  fi

  run_os_update
  exit
}

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Access it using the following URL:${CL}"
echo -e "${GATEWAY}${BGN}http://${IP}${CL}"
