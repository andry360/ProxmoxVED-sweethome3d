# Sweet Home 3D Online - Proxmox LXC Community Script

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Debian](https://img.shields.io/badge/Debian-latest-red.svg)](https://www.debian.org/)
[![Alpine](https://img.shields.io/badge/Alpine-supported-0D597F.svg)](https://alpinelinux.org/)
[![Proxmox](https://img.shields.io/badge/Proxmox-VE-orange.svg)](https://www.proxmox.com/)

Specification for implementing an installation script for **Sweet Home 3D Online** in accordance with the [Proxmox VE Community Scripts contribution documentation](https://community-scripts.org/docs/contribution/readme).

## 🎯 Goal

An LXC container that installs Sweet Home 3D Online **natively** (no nested Docker/Podman), supporting Debian (the latest version available in Proxmox templates) and Alpine (for a smaller footprint). The OS is selected in the advanced container creation mode through `var_os`.

## 📦 Repository and Contribution Process

- The final PR must contain **only** the files listed below, with no local testing support files (for example, changes to `build.func`/`install.func`).

## 📁 Required Files

| File | Purpose | Naming convention |
|---|---|---|
| `ct/sweethome3d.sh` | Creates/updates the container and defines resources and OS settings | Must match `APP="SweetHome3D"` |
| `install/sweethome3d-install.sh` | Installation logic inside the container | Lowercase with hyphens and the `-install` suffix |
| `json/sweethome3d.json` | Metadata for community-scripts.org (name, tags, description, logo URL) | Lowercase |

## ✅ Requirements for `ct/sweethome3d.sh`

- The shebang `#!/usr/bin/env bash` must be followed by loading `core/build.func`, preferring the local checkout through `_cs_boot` and using `source <(curl -fsSL ...)` as the remote fallback.
- Include a header with copyright, author, MIT license, and `# Source:` pointing to the original project URL.
- Required variables: `var_tags`, `var_cpu`, `var_ram`, `var_disk`, `var_os`, `var_version`, and `var_unprivileged`.
- **Dual-OS support**: declare a default OS in `var_os` and respect the value selected by the user in advanced mode. Use the standard `run_os_update` dispatcher and define `update_deb_based` and `update_alpine` for OS-specific update logic.
- Use different defaults per OS (Alpine typically requires less RAM/disk for the same service: approximately 1 GB RAM / 6 GB disk compared with 2 GB RAM / 8 GB disk for Debian; verify this with real testing).
- OS version: use the latest stable version available in Proxmox templates at the time of the PR (do not pin an unnecessarily short-lived value).
- `update_script()` must call `run_os_update`; the framework selects the correct OS function (`update_deb_based` or `update_alpine`) to use systemd/apt on Debian and OpenRC/apk on Alpine.
- The container must be **unprivileged** by default.
- Do not request application credentials in the wizard: they are handled by the installation script, not the container creation wizard.

## ✅ Requirements for `install/sweethome3d-install.sh`

- Include a header with copyright, license, and `# Source:`.
- Load the standard shared functions (`color`, `verb_ip6`, `catch_errors`, `setting_up_container`, `network_check`, and `update_os`).
- Define `setup_deb_based` and `setup_alpine`, then call `run_os_setup`; the dispatcher detects the OS at runtime and selects the logic for:
  - Package names (`apk add` versus `apt install`)
  - Web server user/group (`apache:apache` on Alpine, `www-data:www-data` on Debian)
  - Apache configuration paths (Alpine: `conf.d/*.conf` without `a2ensite`/`a2dissite`, which do not exist on Alpine; Debian: `sites-available` plus `a2ensite`)
  - Service management (`rc-service`/`rc-update` on Alpine, `systemctl` on Debian)
- Always use `$STD` for package installation commands (framework-controlled output suppression), **except** for the Ant/JSweet build, whose output must remain visible when it fails (see the technical notes below).
- Do not create custom application credential files: Sweet Home 3D Online must not introduce credentials or prompts that are not required by upstream. If application configuration genuinely requires credentials, use the format and path required by the application.
- Always finish with `motd_ssh`, `customize`, and `cleanup_lxc`.

## 🧩 Upstream Technical Notes (Sweet Home 3D / SweetHome3DJS)

Communicate these details to the implementer because they are not obvious from the upstream code alone:

- **Node.js + TypeScript are required at build runtime**, not merely as optional dependencies: the JSweet transpiler (Java to JavaScript) invokes `tsc` during `ant`, so `nodejs`/`npm`/`typescript` must be installed **before** starting the build on both OSes.
- **Correct Ant target**: use `ant applicationPhpDeploy`, not `applicationDistribution`. The former depends on the latter and copies generated files into the `lib/` structure referenced by `index.html`; using only `applicationDistribution` puts the files in the wrong location.
- **Dependency on the sibling desktop Java project**: the `build.xml` file of `SweetHome3DJS` requires shared resources (textures, icons, and localization files) from the `SweetHome3D` desktop repository. Export it through SVN into the same hierarchy **before the build**, otherwise the build fails on missing paths such as `io/resources/patterns`.
- **Hardcoded upstream data path**: `index.html` and `writeData.php` reference `data/%s.sh3x`. The storage directory inside the container must be named exactly `data`.
- **Apache allowlist for custom formats**: without including `.sh3f`/`.sh3x` in the `FilesMatch` directive, saving works but reloading projects returns 403.
- **Quirks mode**: the upstream `index.html` has no `<!DOCTYPE html>`; insert it after deployment to avoid inconsistent CSS rendering between browsers.
- **Build log visibility**: the Ant/JSweet build takes 10-20 minutes and is the most fragile installation step; on failure, always print the complete log rather than a generic "exit code 1".
- **Non-blocking console warnings** (do NOT treat these as bugs): deprecated synchronous XHR (caused by transpiled code and not fixable without recompiling upstream), cascaded 404s for localization files (expected i18n fallback), and a 404 for `userPreferences.json` on first launch (the file is created on first save).

## 🚫 Practices to Avoid

- Nested Docker/Podman inside the LXC (the installation must be native).
- Wrappers that intercept or hide system commands (for example, overriding `curl` to mask 404 errors).
- Application credentials passed as environment variables in the public installation command (`APP_USER=... APP_PASS=... bash -c "$(curl ...)"`). The only credential variable accepted in the one-liner is `var_pw`, which is the **container root password** handled natively by the framework; it must not be confused with application credentials.
- Custom versioning files (for example, `VERSION` plus a git hook) instead of the framework convention (`update_script()` plus upstream revision/release tracking).
- Interactive prompts (`read -r -p`) in the installation script: it must run non-interactively through `curl | bash`.
- `$STD` or any other output suppression on the one command that can fail in a non-obvious way (the Ant build).
- Hardcoded software versions when there is a way to resolve them dynamically (GitHub release, SVN revision, and so on).

## 🧪 Validation Before the PR

- Test the installation **by running the script through `curl` from your fork**, not from local files.
- Validate both OS paths (Debian and Alpine) on a real Proxmox host, not only the default path.
- Run `shellcheck` and `bash -n` on both scripts.
- Verify the complete creation, installation, update, and error-handling lifecycle.
- Verify that `update_script()` works both when no update is available and when an update is available, on both OSes.

## 📚 Resources

- [Sweet Home 3D - Official Website](https://www.sweethome3d.com/)
- [Repository SVN SweetHome3DJS](https://sourceforge.net/p/sweethome3d/code/)
- [community-scripts.org - Contribution Documentation](https://community-scripts.org/docs/contribution/readme)
- [community-scripts/ProxmoxVED](https://github.com/community-scripts/ProxmoxVED)

## 📝 License

Distributed under the MIT license; see [LICENSE](LICENSE).
