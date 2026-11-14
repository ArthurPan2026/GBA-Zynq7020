#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
app_src="$repo_root/src/ps/app/src"
evip_root="${EMBEDDED_VIDEO_IP_REPO:-$(cd "$repo_root/.." && pwd)/EmbeddedVideoIP}"
vitis_root="${VITIS_ROOT:-/tools/AMDDesignTools/2025.2.1/Vitis}"
platform_workspace="${PS_APP_VITIS_WORKSPACE:-$repo_root/.build_cache/vitis_workspace}"
build_dir_base="${PS_APP_BUILD_DIR:-$repo_root/.build_cache/ps_app}"
xsa_file="${PS_APP_XSA:-$repo_root/build/zynq_gba_system_wrapper.xsa}"

if [[ ! -d "$app_src" || ! -f "$app_src/CMakeLists.txt" ]]; then
  echo "PS app source is missing: $app_src" >&2
  exit 2
fi
if [[ ! -f "$xsa_file" ]]; then
  echo "Current consumer XSA is missing: $xsa_file" >&2
  echo "Build the hardware design before building the PS app." >&2
  exit 2
fi
if [[ ! -x "$vitis_root/bin/vitis" || ! -x "$vitis_root/bin/ninja" ||
      ! -x "$vitis_root/gnu/aarch32/lin/gcc-arm-none-eabi/bin/arm-none-eabi-gcc" ]]; then
  echo "Vitis, Ninja, or ARM GCC is missing below $vitis_root" >&2
  exit 2
fi

export VITIS_ROOT="$vitis_root"
export LD_LIBRARY_PATH="$vitis_root/lib/lnx64.o:$vitis_root/aietools/lib/lnx64.o:${LD_LIBRARY_PATH:-}"
export PATH="$vitis_root/bin:$vitis_root/gnu/aarch32/lin/gcc-arm-none-eabi/bin:$PATH"
export VITIS_ROOT ESW_REPO="${ESW_REPO:-$vitis_root/data/embeddedsw}"
export PS_APP_PROJECT_ROOT="$repo_root"
export PS_APP_XSA="$xsa_file"
export PS_APP_VITIS_WORKSPACE="$platform_workspace"

evip_expected_version="$(awk '$1=="set" && $2=="evip_expected_version" {gsub(/"/,"",$3); print $3}' "$repo_root/scripts/build/embedded_video_ip_consumer.tcl")"
evip_expected_commit="$(awk '$1=="set" && $2=="evip_expected_commit" {gsub(/"/,"",$3); print $3}' "$repo_root/scripts/build/embedded_video_ip_consumer.tcl")"
evip_actual_version="$(tr -d '\r\n' < "$evip_root/VERSION")"
evip_actual_commit="$(git -C "$evip_root" rev-parse HEAD)"
evip_dirty="$(git -C "$evip_root" status --porcelain)"
if [[ "$evip_expected_version" != "$evip_actual_version" || "$evip_expected_commit" != "$evip_actual_commit" || -n "$evip_dirty" ]]; then
  echo "EmbeddedVideoIP dependency does not match the clean lock $evip_expected_version@$evip_expected_commit" >&2
  exit 2
fi

python3 "$evip_root/tools/install_ps_library.py" --app-src "$app_src" --platform zynq7000
mkdir -p "$platform_workspace"
"$vitis_root/bin/vitis" -s "$repo_root/scripts/build/update_vitis_platform.py"

platform_sw="${PS_APP_PLATFORM_SW_DIR:-$(cat "$platform_workspace/platform_sw_path.txt" 2>/dev/null || true)}"
if [[ ! -f "$platform_sw/cortexa9_toolchain.cmake" ||
      ! -f "$platform_sw/Findcommon.cmake" ||
      ! -f "$platform_sw/include/xparameters.h" ||
      ! -f "$platform_sw/include/FreeRTOSConfig.h" ]]; then
  echo "Generated FreeRTOS platform files are missing or incomplete: $platform_sw" >&2
  exit 2
fi
platform_domain="${PS_APP_PLATFORM_DOMAIN_DIR:-$(cat "$platform_workspace/platform_domain_path.txt" 2>/dev/null || true)}"
if [[ ! -d "$platform_domain/bsp/libsrc/build_configs/gen_bsp" ]]; then
  echo "Generated FreeRTOS BSP source tree is missing: $platform_domain" >&2
  exit 2
fi
export PS_APP_PLATFORM_SW_DIR="$platform_sw"
export PS_APP_PLATFORM_DOMAIN_DIR="$platform_domain"
python3 "$repo_root/scripts/fatfs/configure_utf8_lfn.py" --apply

# Build XilFFS again after applying UTF-8/LFN headers to the generated BSP.
bsp_build_dir="$platform_domain/bsp/libsrc/build_configs/gen_bsp"
cmake --build "$bsp_build_dir" --target xilffs --parallel "${PS_APP_BSP_BUILD_JOBS:-8}"
xilffs_archive="$bsp_build_dir/libsrc/xilffs/src/libxilffs.a"
if [[ ! -f "$xilffs_archive" || ! -d "$platform_sw/lib" || ! -d "$platform_domain/bsp/lib" ]]; then
  echo "Configured XilFFS library output is missing." >&2
  exit 2
fi
copy_if_changed() {
  local source="$1"
  local destination="$2"
  if [[ ! -f "$destination" ]] || ! cmp -s "$source" "$destination"; then
    install -m 0644 "$source" "$destination"
  fi
}
copy_if_changed "$xilffs_archive" "$platform_domain/bsp/lib/libxilffs.a"
copy_if_changed "$xilffs_archive" "$platform_sw/lib/libxilffs.a"

xsa_sha256="$(sha256sum "$xsa_file" | cut -d ' ' -f 1)"
compiler="$vitis_root/gnu/aarch32/lin/gcc-arm-none-eabi/bin/arm-none-eabi-gcc"
compiler_version="$("$compiler" --version | head -n 1)"
platform_key="$( {
  printf '%s\n%s\n%s\n' "$xsa_sha256" "$vitis_root" "$compiler_version"
  cat "$platform_workspace/platform_state.json" "$platform_sw/cortexa9_toolchain.cmake" "$platform_sw/include/xparameters.h" "$platform_sw/include/FreeRTOSConfig.h" "$platform_sw/lib/libxilffs.a"
  for config_header in "$platform_sw/include/ffconf.h" "$platform_sw/include/xilffs_config.h"; do
    if [[ -f "$config_header" ]]; then cat "$config_header"; fi
  done
} | sha256sum | cut -d ' ' -f 1)"
build_name="xsa-${xsa_sha256}-${platform_key}"
mkdir -p "$build_dir_base"
build_dir_base="$(cd "$build_dir_base" && pwd)"
build_dir="$build_dir_base/$build_name"
build_marker="$build_dir/.ps_app_build_complete"

build_mode=full
if [[ -f "$build_marker" && -f "$build_dir/CMakeCache.txt" && -f "$build_dir/build.ninja" ]]; then
  grep -Fxq "xsa_sha256=$xsa_sha256" "$build_marker" &&
  grep -Fxq "platform_key=$platform_key" "$build_marker" || {
    echo "PS build cache marker does not match the selected XSA/platform: $build_dir" >&2
    exit 2
  }
  build_mode=incremental
elif [[ -e "$build_dir" ]]; then
  case "$build_dir/" in
    "$build_dir_base/"*) rm -rf -- "$build_dir" ;;
    *) echo "Refusing to remove PS build directory outside cache base: $build_dir" >&2; exit 2 ;;
  esac
fi
echo "PS_APP_BUILD_MODE=$build_mode"
echo "PS_APP_XSA_SHA256=$xsa_sha256"
echo "PS_APP_BUILD_DIR=$build_dir"

config_marker="$build_dir/.ps_app_cmake_key"
config_key="$( {
  printf '%s\n%s\n' "$app_src" "$platform_sw"
  sha256sum "$app_src/CMakeLists.txt" "$app_src/UserConfig.cmake" "$app_src/Empty_applicationExample.cmake" "$repo_root/scripts/fatfs/configure_utf8_lfn.py"
  find "$app_src" -type f -printf '%P\n' | sort
} | sha256sum | cut -d ' ' -f 1)"
if [[ -f "$config_marker" && -f "$build_dir/CMakeCache.txt" && -f "$build_dir/build.ninja" ]] &&
   grep -Fxq "config_key=$config_key" "$config_marker"; then
  echo "PS_APP_CMAKE_CONFIG=cache-hit"
else
  cmake -S "$app_src" -B "$build_dir" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$platform_sw/cortexa9_toolchain.cmake" \
    -DCMAKE_MODULE_PATH="$platform_sw" \
    -DCMAKE_INCLUDE_PATH="$platform_sw/include" \
    -DCMAKE_LIBRARY_PATH="$platform_sw/lib" \
    -DCMAKE_MAKE_PROGRAM="$vitis_root/bin/ninja"
  printf 'config_key=%s\n' "$config_key" > "$config_marker.tmp"
  mv -f "$config_marker.tmp" "$config_marker"
  echo "PS_APP_CMAKE_CONFIG=configured"
fi
cmake --build "$build_dir" --target app.elf --parallel "${PS_APP_BUILD_JOBS:-8}"
printf 'xsa_sha256=%s\nplatform_key=%s\n' "$xsa_sha256" "$platform_key" > "$build_marker.tmp"
mv -f "$build_marker.tmp" "$build_marker"
sha256sum "$build_dir/app.elf"
