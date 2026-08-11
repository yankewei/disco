#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workspace_dir="$(cd "${script_dir}/.." && pwd)"
profile="${1:-debug}"

if [[ "${profile}" == "release" ]]; then
    cargo build --manifest-path "${workspace_dir}/Cargo.toml" -p disco-app --release
else
    cargo build --manifest-path "${workspace_dir}/Cargo.toml" -p disco-app
fi

app_dir="${workspace_dir}/target/${profile}/Disco.app"
contents_dir="${app_dir}/Contents"
macos_dir="${contents_dir}/MacOS"
resources_dir="${contents_dir}/Resources"
assets_dir="${workspace_dir}/assets"
app_icon_source_dir="${assets_dir}/app-icon"
icon_work_dir="$(mktemp -d)"
iconset_dir="${icon_work_dir}/AppIcon.iconset"

cleanup_icon_work_dir() {
    rm -R "${icon_work_dir}"
}
trap cleanup_icon_work_dir EXIT

if [[ -d "${app_dir}" ]]; then
    rm -R "${app_dir}"
fi

mkdir -p "${macos_dir}" "${resources_dir}" "${iconset_dir}"
cp "${workspace_dir}/packaging/macos/Info.plist" "${contents_dir}/Info.plist"
cp "${workspace_dir}/target/${profile}/disco-app" "${macos_dir}/disco-app"
cp "${app_icon_source_dir}"/icon_*.png "${iconset_dir}/"
iconutil --convert icns --output "${resources_dir}/AppIcon.icns" "${iconset_dir}"
cp -R "${assets_dir}/images" "${resources_dir}/images"
cp -R "${assets_dir}/icons" "${resources_dir}/icons"

echo "Built ${app_dir}"
