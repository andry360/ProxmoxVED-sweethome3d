#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: andry360
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://www.sweethome3d.com/

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

setup_deb_based() {
  msg_info "Installing Dependencies"
  $STD apt install -y subversion ant
  msg_ok "Installed Dependencies"

  JAVA_VERSION="21" setup_java
  # JSweet shells out to tsc during the Ant build, so Node and TypeScript are build-time
  # requirements rather than optional extras - the transpilation fails without them.
  NODE_VERSION="24" NODE_MODULE="typescript" setup_nodejs
  PHP_APACHE="YES" setup_php

  msg_info "Configuring Apache"
  mkdir -p /opt/sweethome3d /opt/sweethome3d_data
  chown -R www-data:www-data /opt/sweethome3d_data
  cat <<'EOF' >/etc/apache2/sites-available/sweethome3d.conf
<VirtualHost *:80>
  DocumentRoot /opt/sweethome3d
  AddType application/octet-stream .sh3x .sh3f .sh3d

  <Directory /opt/sweethome3d>
    Options -Indexes +FollowSymLinks
    AllowOverride None
    Require all granted
  </Directory>

  # writeData.php saves under whatever name the browser asks for, including the furniture
  # and texture resources of a home, so the formats a home needs cannot be allowlisted one
  # by one without breaking reloads. Refuse what a handler would execute instead. Both
  # spellings are listed because data is a symlink and either form can be the one Apache
  # matches the request against.
  <Directory /opt/sweethome3d_data>
    Options -Indexes
    Require all granted
    <FilesMatch "(?i)\.(php[0-9]?|phar|phtml|cgi|pl|py|sh)$">
      Require all denied
    </FilesMatch>
  </Directory>

  <Directory /opt/sweethome3d/data>
    Options -Indexes
    Require all granted
    <FilesMatch "(?i)\.(php[0-9]?|phar|phtml|cgi|pl|py|sh)$">
      Require all denied
    </FilesMatch>
  </Directory>
</VirtualHost>
EOF
  $STD a2dissite 000-default
  $STD a2ensite sweethome3d
  msg_ok "Configured Apache"

  msg_info "Starting Apache"
  systemctl enable -q --now apache2
  systemctl restart apache2
  msg_ok "Started Apache"
}

setup_alpine() {
  msg_info "Installing Dependencies"
  $STD apk add --no-cache apache2 php-apache2 apache-ant subversion nodejs npm typescript
  msg_ok "Installed Dependencies"

  JAVA_VERSION="21" setup_java

  msg_info "Configuring Apache"
  mkdir -p /opt/sweethome3d /opt/sweethome3d_data
  chown -R apache:apache /opt/sweethome3d_data
  # Alpine has no a2ensite/a2dissite - everything in conf.d is read by httpd.conf already.
  cat <<'EOF' >/etc/apache2/conf.d/sweethome3d.conf
<VirtualHost *:80>
  DocumentRoot /opt/sweethome3d
  AddType application/octet-stream .sh3x .sh3f .sh3d

  <Directory /opt/sweethome3d>
    Options -Indexes +FollowSymLinks
    AllowOverride None
    Require all granted
  </Directory>

  # writeData.php saves under whatever name the browser asks for, including the furniture
  # and texture resources of a home, so the formats a home needs cannot be allowlisted one
  # by one without breaking reloads. Refuse what a handler would execute instead. Both
  # spellings are listed because data is a symlink and either form can be the one Apache
  # matches the request against.
  <Directory /opt/sweethome3d_data>
    Options -Indexes
    Require all granted
    <FilesMatch "(?i)\.(php[0-9]?|phar|phtml|cgi|pl|py|sh)$">
      Require all denied
    </FilesMatch>
  </Directory>

  <Directory /opt/sweethome3d/data>
    Options -Indexes
    Require all granted
    <FilesMatch "(?i)\.(php[0-9]?|phar|phtml|cgi|pl|py|sh)$">
      Require all denied
    </FilesMatch>
  </Directory>
</VirtualHost>
EOF
  msg_ok "Configured Apache"

  msg_info "Starting Apache"
  $STD rc-update add apache2 default
  $STD rc-service apache2 start
  msg_ok "Started Apache"
}

run_os_setup

msg_info "Checking the latest Sweet Home 3D release"
SH3D_TAG=$(curl -fsSL "https://svn.code.sf.net/p/sweethome3d/code/tags/" |
  sed -n 's|.*href="\(V_[0-9][0-9_]*\)/".*|\1|p' | sort -t_ -k2,2n -k3,3n -k4,4n | tail -1)
if [[ -z "$SH3D_TAG" ]]; then
  msg_error "Could not read the release tags from SourceForge"
  exit 1
fi
msg_ok "Checked the latest Sweet Home 3D release (${SH3D_TAG})"

msg_info "Fetching Sweet Home 3D ${SH3D_TAG} sources"
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
# JSweet reads a handful of javac internals reflectively, which JDK 17+ refuses unless
# those packages are opened. Ant forks a fresh JVM per <java> task, so the flags have to
# travel in the environment - ANT_OPTS would only reach Ant's own JVM.
export JAVA_TOOL_OPTIONS="\
  --add-exports jdk.compiler/com.sun.tools.javac.code=ALL-UNNAMED \
  --add-exports jdk.compiler/com.sun.tools.javac.tree=ALL-UNNAMED \
  --add-exports jdk.compiler/com.sun.tools.javac.util=ALL-UNNAMED \
  --add-opens jdk.compiler/com.sun.tools.javac.code=ALL-UNNAMED \
  --add-opens jdk.compiler/com.sun.tools.javac.tree=ALL-UNNAMED \
  --add-opens jdk.compiler/com.sun.tools.javac.util=ALL-UNNAMED"
# applicationPhpDeploy, not applicationDistribution: it depends on the latter and then
# copies the generated files into the lib/ layout index.html actually references.
# Deliberately not silenced: this is the step that breaks, and an exit code on its own
# tells a tester nothing about which transpilation unit failed.
if ! ant applicationPhpDeploy; then
  msg_error "The Sweet Home 3D Online build failed - the complete Ant log is above"
  exit 1
fi
msg_ok "Built Sweet Home 3D Online"

msg_info "Deploying Sweet Home 3D Online"
cp -r /opt/sweethome3d-src/SweetHome3DJS/deployDirectHomeRecorder/. /opt/sweethome3d/
# Upstream ships index.html without a doctype, which leaves browsers in quirks mode.
sed -i '1i <!DOCTYPE html>' /opt/sweethome3d/index.html
# index.html, writeData.php and listHomes.php all hardcode a relative "data" directory, so
# that name is not ours to choose; the symlink keeps the saved homes out of the tree a
# rebuild overwrites.
ln -sfn /opt/sweethome3d_data /opt/sweethome3d/data
cat <<EOF >~/.sweethome3d
${SH3D_TAG}
EOF
rm -rf /opt/sweethome3d-src
msg_ok "Deployed Sweet Home 3D Online"

motd_ssh
customize
cleanup_lxc
