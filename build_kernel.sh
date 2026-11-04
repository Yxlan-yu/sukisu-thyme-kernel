#!/bin/bash

# Exit on any error
set -e

# ==========================================
# Argument Parsing
# ==========================================
if [ -z "$1" ]; then
    echo "[!] Error: No device specified."
    echo "Usage: $0 <device_name> [ksu] [miui|aosp]"
    echo "Example: $0 lmi"
    echo "         $0 lmi ksu"
    echo "         $0 lmi ksu miui"
    echo "         $0 lmi aosp"
    exit 1
fi

DEVICE_NAME="$1"
DEFCONFIG="${DEVICE_NAME}_defconfig"
DEFCONFIG_PATH="arch/arm64/configs/${DEFCONFIG}"

if [ ! -f "$DEFCONFIG_PATH" ]; then
    echo "[!] Error: Defconfig not found at $DEFCONFIG_PATH"
    echo "[!] Please verify the device name and try again."
    exit 1
fi

ENABLE_KSU=0
TARGET_OS="both"

shift
# Parse remaining arguments loosely
for arg in "$@"; do
    case "$arg" in
        ksu) ENABLE_KSU=1 ;;
        miui) TARGET_OS="miui" ;;
        aosp) TARGET_OS="aosp" ;;
    esac
done

# ==========================================
# Configuration & Environment
# ==========================================
KERNEL_DIR="$(pwd)"
TOOLCHAIN_BIN="$HOME/zyc-clang/bin"

export PATH="${TOOLCHAIN_BIN}:${PATH}"
export ARCH="arm64"
export SUBARCH="arm64"

# ccache Setup
export CCACHE_DIR="$HOME/.cache/ccache_mikernel"
export CCACHE_EXEC=$(command -v ccache)

if [ -z "$CCACHE_EXEC" ]; then
    echo "[!] ccache not found! Please install ccache first."
    exit 1
fi

export USE_CCACHE=1
export CROSS_COMPILE="aarch64-linux-gnu-"
export CROSS_COMPILE_ARM32="arm-linux-gnueabi-"

echo "[*] Checking Clang version..."
clang --version || { echo "[!] Clang not found at ${TOOLCHAIN_BIN}. Please check the path."; exit 1; }

echo "[*] Setting up ccache in $CCACHE_DIR..."
mkdir -p "$CCACHE_DIR"

# ==========================================
# KernelSU (SukiSU) Setup
# ==========================================
if [ "$ENABLE_KSU" -eq 1 ]; then
    echo "==========================================="
    echo " [*] Initializing SukiSU Setup (v4.3.0-r1)"
    echo "==========================================="
    echo "[*] Downloading and running SukiSU remote setup script..."
    curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/v4.3.0-r1/kernel/setup.sh" | bash -s v4.3.0-r1
    if [ ! -d "drivers/kernelsu" ]; then
        echo "[!] SukiSU driver directory missing - setup failed."
        exit 1
    fi
    echo "[+] SukiSU setup finished."
    echo "[*] SukiSU tree:"; ls -la drivers/kernelsu | head -20

    # ------------------------------------------------------------------
    # 4.19 compatibility: MODULE_IMPORT_NS() does not exist before 5.4
    # (it appeared in 5.4, string form only in 6.13). SukiSU v4.3.0-r1
    # emits the unquoted form for every kernel < 6.13, so guard it.
    # ------------------------------------------------------------------
    echo "[*] Patching SukiSU MODULE_IMPORT_NS for pre-5.4 kernels..."
    python3 - drivers/kernelsu/core/init.c <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = 'MODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver);'
new = ('#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 4, 0)\n'
       'MODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver);\n'
       '#endif')
assert s.count(old) == 1, 'unexpected MODULE_IMPORT_NS count: %d' % s.count(old)
open(p, 'w', encoding='utf-8').write(s.replace(old, new))
print('[*] init.c patched')
PYEOF
    grep -n -A2 -B2 'MODULE_IMPORT_NS' drivers/kernelsu/core/init.c || true

    # ------------------------------------------------------------------
    # 4.19 compatibility: struct file_operations lacks ->iopoll (5.1+)
    # and ->remap_file_range (4.20+; 4.19 exposes dedupe_file_range).
    # ------------------------------------------------------------------
    echo "[*] Patching SukiSU infra/file_wrapper.c for pre-5.x kernels..."
    python3 - drivers/kernelsu/infra/file_wrapper.c <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

m1 = '#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0)\nstatic int ksu_wrapper_iopoll'
m2 = '#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 6, 0)\nstatic int ksu_wrapper_iterate'
i = s.index(m1)
j = s.index(m2)
s = s[:i] + '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 1, 0)\n' + s[i:j] + '#endif\n\n' + s[j:]

i = s.index('static loff_t ksu_wrapper_remap_file_range(')
j = s.index('static int ksu_wrapper_fadvise(')
s = s[:i] + '#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 20, 0)\n' + s[i:j] + '#endif\n\n' + s[j:]

old = '    p->ops.iopoll = fp->f_op->iopoll ? ksu_wrapper_iopoll : NULL;\n'
new = '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 1, 0)\n' + old + '#endif\n'
assert s.count(old) == 1, 'unexpected iopoll assignment count: %d' % s.count(old)
s = s.replace(old, new)

old = '    p->ops.remap_file_range = fp->f_op->remap_file_range ? ksu_wrapper_remap_file_range : NULL;\n'
new = '#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 20, 0)\n' + old + '#endif\n'
assert s.count(old) == 1, 'unexpected remap assignment count: %d' % s.count(old)
s = s.replace(old, new)

open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('[*] file_wrapper.c patched')
PYEOF
    grep -n 'iopoll\|remap_file_range' drivers/kernelsu/infra/file_wrapper.c || true

    # ------------------------------------------------------------------
    # 4.19 compatibility: TWA_RESUME (5.8+), strscpy_pad (4.20+) and the
    # fallthrough keyword (5.4+).
    # ------------------------------------------------------------------
    echo "[*] Patching SukiSU task_work / string helpers for 4.19..."
    python3 - policy/allowlist.c supercall/supercall.c <<'PYEOF'
import sys

twa = ('#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 8, 0) && !defined(TWA_RESUME)\n'
       '#define TWA_RESUME 1\n'
       '#endif\n')

for p in sys.argv[1:]:
    s = open(p, encoding='utf-8').read()
    anchor = '#include <linux/version.h>\n'
    assert s.count(anchor) == 1, '%s: version.h include count %d' % (p, s.count(anchor))
    s = s.replace(anchor, anchor + twa)
    open(p, 'w', encoding='utf-8', newline='\n').write(s)
    print('[*] %s: TWA_RESUME fallback added' % p)
PYEOF
    python3 - policy/allowlist.c <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

old = 'strscpy_pad(domain, KSU_DEFAULT_SELINUX_DOMAIN, domain_len);'
new = ('#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 20, 0)\n'
       '                strscpy_pad(domain, KSU_DEFAULT_SELINUX_DOMAIN, domain_len);\n'
       '#else\n'
       '                memset(domain, 0, domain_len);\n'
       '                strlcpy(domain, KSU_DEFAULT_SELINUX_DOMAIN, domain_len);\n'
       '#endif')
assert s.count(old) == 1, 'strscpy_pad count: %d' % s.count(old)
s = s.replace(old, new)

old = '        fallthrough;'
new = ('#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 4, 0)\n'
       '        fallthrough;\n'
       '#else\n'
       '        /* fallthrough */\n'
       '#endif')
assert s.count(old) == 1, 'fallthrough count: %d' % s.count(old)
s = s.replace(old, new)

open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('[*] allowlist.c patched')
PYEOF
    grep -n 'TWA_RESUME' policy/allowlist.c supercall/supercall.c || true

    # ------------------------------------------------------------------
    # 4.19 compatibility: struct selinux_policy only exists since 5.7, so
    # the sepolicy rule engine and the SELinux hide feature are 5.7+ only.
    # Stub out their public entry points so the rest of SukiSU links.
    # ------------------------------------------------------------------
    echo "[*] Stubbing SukiSU selinux rules / selinux_hide for pre-5.7 kernels..."
    python3 - feature/selinux_hide.c <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
head = ('#include <linux/version.h>\n\n'
        '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 7, 0)\n')
tail = ('\n#else /* < 5.7.0: selinux_hide relies on struct selinux_policy */\n'
        'void ksu_selinux_hide_init(void) {}\n'
        'void ksu_selinux_hide_exit(void) {}\n'
        'void ksu_selinux_hide_drop_backup_if_unused(void) {}\n'
        'void ksu_selinux_hide_handle_second_stage(void) {}\n'
        'void ksu_selinux_hide_handle_post_fs_data(void) {}\n'
        '#endif\n')
assert 'LINUX_VERSION_CODE' not in s.split('\n')[0]
open(p, 'w', encoding='utf-8', newline='\n').write(head + s + tail)
print('[*] selinux_hide.c guarded')
PYEOF
    python3 - selinux/rules.c <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
head = ('#include <linux/version.h>\n'
        '#include <linux/types.h>\n'
        '#include <linux/compiler_types.h>\n'
        '#include <linux/errno.h>\n\n'
        '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 7, 0)\n')
tail = ('\n#else /* < 5.7.0: no struct selinux_policy, so no sepolicy patching */\n'
        'struct selinux_policy *backup_sepolicy = NULL;\n\n'
        'void apply_kernelsu_rules(void)\n'
        '{\n'
        '\tpr_warn("ksu: sepolicy rules need kernel 5.7+, skipped on 4.19\\n");\n'
        '}\n\n'
        'int handle_sepolicy(void __user *user_data, u64 data_len)\n'
        '{\n'
        '\treturn -EOPNOTSUPP;\n'
        '}\n'
        '#endif\n')
open(p, 'w', encoding='utf-8', newline='\n').write(head + s + tail)
print('[*] rules.c guarded')
PYEOF
    python3 - selinux/sepolicy.c <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
head = ('#include <linux/version.h>\n\n'
        '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 7, 0)\n')
tail = ('\n#else /* < 5.7.0: policydb rewrite helpers are 5.7+ only */\n'
        'static int __maybe_unused ksu_sepolicy_stub;\n'
        '#endif\n')
open(p, 'w', encoding='utf-8', newline='\n').write(head + s + tail)
print('[*] sepolicy.c guarded')
PYEOF
    grep -n 'LINUX_VERSION_CODE >= KERNEL_VERSION(5, 7, 0)' feature/selinux_hide.c selinux/rules.c selinux/sepolicy.c || true
fi

# ==========================================
# Baseband-guard Setup
# ==========================================
echo "==========================================="
echo " [*] Initializing Baseband-guard Setup"
echo "==========================================="
echo "[*] Downloading and running Baseband-guard remote setup script..."
wget -O- https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh | bash

echo "[*] Patching security/Kconfig for baseband_guard..."
sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' security/Kconfig
echo "[+] Baseband-guard setup finished."
echo "==========================================="

# ==========================================
# AnyKernel3 Setup
# ==========================================
echo "==========================================="
echo " [*] Initializing AnyKernel3 Workspace"
echo "==========================================="
rm -rf anykernel
echo "[*] Cloning AnyKernel3..."
git clone https://github.com/AstideLabs/AnyKernel3 -b kona --single-branch --depth=1 anykernel
echo "[+] AnyKernel3 cloned successfully."
echo "[*] Adjusting AnyKernel3..."
sed -i "s/^device\.name1=.*/device.name1=${DEVICE_NAME}/" anykernel/anykernel.sh
echo "[*] AnyKernel3 adjusted successfully."
echo "==========================================="

# ==========================================
# Modular Build Function
# ==========================================
build_target() {
    local OS_TYPE=$1
    echo "==========================================="
    echo " Starting Kernel Compilation for ${DEVICE_NAME} (Target: $OS_TYPE)"
    echo "==========================================="
    
    local OUT_DIR="${KERNEL_DIR}/out_${OS_TYPE}"
    
    local MAKE_OPTS=(
        -j"$(nproc)"
        O="${OUT_DIR}"
        ARCH="${ARCH}"
        SUBARCH="${SUBARCH}"
        LLVM=1
        LLVM_IAS=1
        CC="ccache clang"
        HOSTCC="ccache clang"
        CROSS_COMPILE="${CROSS_COMPILE}"
        CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32}"
    )

    echo "[*] Cleaning ${OUT_DIR}..."
    rm -rf "${OUT_DIR}"
    mkdir -p "${OUT_DIR}"

    local DTS_SOURCE="arch/arm64/boot/dts/vendor/qcom"
    local DTS_BACKUP=".dts.bak.${OS_TYPE}"

    if [ "$OS_TYPE" == "miui" ]; then
        echo "[*] Applying MIUI DTS patches..."
        cp -a "${DTS_SOURCE}" "${DTS_BACKUP}"
        
        # Apply MIUI specific sed patches to dts
        sed -i 's/<154>/<1537>/g' ${DTS_SOURCE}/dsi-panel-j1s* || true
        sed -i 's/<154>/<1537>/g' ${DTS_SOURCE}/dsi-panel-j2* || true
        sed -i 's/<155>/<1544>/g' ${DTS_SOURCE}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi || true
        sed -i 's/<155>/<1545>/g' ${DTS_SOURCE}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi || true
        sed -i 's/<155>/<1546>/g' ${DTS_SOURCE}/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi || true
        sed -i 's/<155>/<1546>/g' ${DTS_SOURCE}/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi || true
        sed -i 's/<70>/<695>/g' ${DTS_SOURCE}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi || true
        sed -i 's/<70>/<695>/g' ${DTS_SOURCE}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi || true
        sed -i 's/<70>/<695>/g' ${DTS_SOURCE}/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi || true
        sed -i 's/<70>/<695>/g' ${DTS_SOURCE}/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi || true
        sed -i 's/<71>/<710>/g' ${DTS_SOURCE}/dsi-panel-j1s* || true
        sed -i 's/<71>/<710>/g' ${DTS_SOURCE}/dsi-panel-j2* || true

        sed -i 's/\/\/ mi,mdss-dsi-pan-enable-smart-fps/mi,mdss-dsi-pan-enable-smart-fps/g' ${DTS_SOURCE}/dsi-panel* || true
        sed -i 's/\/\/ mi,mdss-dsi-smart-fps-max_framerate/mi,mdss-dsi-smart-fps-max_framerate/g' ${DTS_SOURCE}/dsi-panel* || true
        sed -i 's/\/\/ qcom,mdss-dsi-pan-enable-smart-fps/qcom,mdss-dsi-pan-enable-smart-fps/g' ${DTS_SOURCE}/dsi-panel* || true
        sed -i 's/qcom,mdss-dsi-qsync-min-refresh-rate/\/\/qcom,mdss-dsi-qsync-min-refresh-rate/g' ${DTS_SOURCE}/dsi-panel* || true

        sed -i 's/120 90 60/120 90 60 50 30/g' ${DTS_SOURCE}/dsi-panel-g7a-36-02-0c-dsc-video.dtsi || true
        sed -i 's/120 90 60/120 90 60 50 30/g' ${DTS_SOURCE}/dsi-panel-g7a-37-02-0a-dsc-video.dtsi || true
        sed -i 's/120 90 60/120 90 60 50 30/g' ${DTS_SOURCE}/dsi-panel-g7a-37-02-0b-dsc-video.dtsi || true
        sed -i 's/144 120 90 60/144 120 90 60 50 48 30/g' ${DTS_SOURCE}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi || true

        sed -i 's/\/\/39 00 00 00 00 00 03 51 03 FF/39 00 00 00 00 00 03 51 03 FF/g' ${DTS_SOURCE}/dsi-panel-j9-38-0a-0a-fhd-video.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 03 51 0D FF/39 00 00 00 00 00 03 51 0D FF/g' ${DTS_SOURCE}/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${DTS_SOURCE}/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${DTS_SOURCE}/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${DTS_SOURCE}/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${DTS_SOURCE}/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${DTS_SOURCE}/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 00 00/39 01 00 00 00 00 03 51 00 00/g' ${DTS_SOURCE}/dsi-panel-j2-38-0c-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 03 FF/39 01 00 00 00 00 03 51 03 FF/g' ${DTS_SOURCE}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 03 FF/39 01 00 00 00 00 03 51 03 FF/g' ${DTS_SOURCE}/dsi-panel-j9-38-0a-0a-fhd-video.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${DTS_SOURCE}/dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${DTS_SOURCE}/dsi-panel-j2-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${DTS_SOURCE}/dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${DTS_SOURCE}/dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${DTS_SOURCE}/dsi-panel-j2-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${DTS_SOURCE}/dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${DTS_SOURCE}/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${DTS_SOURCE}/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${DTS_SOURCE}/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${DTS_SOURCE}/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${DTS_SOURCE}/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 01 00 03 51 03 FF/39 01 00 00 01 00 03 51 03 FF/g' ${DTS_SOURCE}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 11 00 03 51 03 FF/39 01 00 00 11 00 03 51 03 FF/g' ${DTS_SOURCE}/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi || true
    fi

    echo "[*] Making defconfig: ${DEFCONFIG}..."
    make "${MAKE_OPTS[@]}" "${DEFCONFIG}"

    # ----------------------------------------------------
    # Configuration tweaks
    # ----------------------------------------------------
    
    # 1. Baseband-guard configuration (Always applied)
    echo "[*] Injecting Baseband-guard configuration..."
    scripts/config --file "${OUT_DIR}/.config" -e BBG

    # 2. KernelSU (SukiSU) configurations
    if [ "$ENABLE_KSU" -eq 1 ]; then
        echo "[*] Injecting SukiSU configurations..."
        scripts/config --file "${OUT_DIR}/.config" \
            -e KSU \
            -e KPROBES \
            -e MODULES \
            -e KALLSYMS \
            -e KALLSYMS_ALL
    fi

    # 3. MIUI configurations
    if [ "$OS_TYPE" == "miui" ]; then
        echo "[*] Injecting MIUI specific configurations..."
        scripts/config --file "${OUT_DIR}/.config" \
            --set-str STATIC_USERMODEHELPER_PATH /system/bin/micd \
            -e PERF_CRITICAL_RT_TASK \
            -e SF_BINDER \
            -e OVERLAY_FS \
            -e MIGT \
            -e MIGT_ENERGY_MODEL \
            -e MIHW \
            -e PACKAGE_RUNTIME_INFO \
            -e BINDER_OPT \
            -e KPERFEVENTS \
            -e PERF_HUMANTASK \
            -d LTO_CLANG \
            -e LTO_NONE \
            -d SHADOW_CALL_STACK \
            -e XIAOMI_MIUI \
            -d MI_MEMORY_SYSFS \
            -e TASK_DELAY_ACCT \
            -e MIUI_ZRAM_MEMORY_TRACKING \
            -e PERF_HELPER \
            -e BOOTUP_RECLAIM \
            -e MI_RECLAIM \
            -e RTMM \
            -e MILLET_CGROUP \
            -e MILLET_SIG \
            -e MILLET_BINDER \
            -e MILLET_PKG \
            -e MILLET_BINDER_GKI \
            -e MILLET_CORE \
            -e MILLET_HS \
            -e BINDER_PRIO \
            -d REKERNEL \
            -d REKERNEL_NETWORK
    fi

    # 4. AOSP configurations
    if [ "$OS_TYPE" == "aosp" ]; then
        echo "[*] Injecting AOSP specific configurations..."
        scripts/config --file "${OUT_DIR}/.config" \
            -e REKERNEL \
            -e REKERNEL_NETWORK
    fi

    # We always need to re-evaluate dependencies because BBG is injected unconditionally
    echo "[*] Updating config (make olddefconfig)..."
    make "${MAKE_OPTS[@]}" olddefconfig

    # ----------------------------------------------------
    # Sanity checks on the resolved config
    # ----------------------------------------------------
    echo "[*] Resolved config check:"
    grep -E '^CONFIG_(KSU|KPROBES|KALLSYMS|KALLSYMS_ALL|EXT4_FS|MODULES)=' "${OUT_DIR}/.config" || true
    for want in CONFIG_KSU CONFIG_KPROBES CONFIG_KALLSYMS_ALL CONFIG_EXT4_FS; do
        if ! grep -q "^${want}=y$" "${OUT_DIR}/.config"; then
            echo "[!] FATAL: ${want} is not enabled after olddefconfig"
            exit 1
        fi
    done
    if [ "$ENABLE_KSU" -eq 1 ]; then
        grep -q 'drivers/kernelsu/Kconfig' drivers/Kconfig || { echo "[!] FATAL: kernelsu Kconfig not wired"; exit 1; }
        grep -q 'kernelsu' drivers/Makefile || { echo "[!] FATAL: kernelsu Makefile not wired"; exit 1; }
    fi

    # ----------------------------------------------------
    # Compilation
    # ----------------------------------------------------
    echo "[*] Building kernel..."
    make "${MAKE_OPTS[@]}" 

    # Restore DTS backup for MIUI
    if [ "$OS_TYPE" == "miui" ]; then
        echo "[*] Restoring DTS backups..."
        rm -rf "${DTS_SOURCE}"
        mv "${DTS_BACKUP}" "${DTS_SOURCE}"
    fi

    echo "==========================================="
    if [ -f "${OUT_DIR}/arch/arm64/boot/Image" ]; then
        echo "[+] $OS_TYPE Build Successful!"
        echo "[+] Kernel Image path: ${OUT_DIR}/arch/arm64/boot/Image"

        echo "[*] Packaging to AnyKernel3 ($OS_TYPE)..."
        # 确保独立打包：清空现有的 kernels 目录
        rm -rf anykernel/kernels/*
        mkdir -p "anykernel/kernels/${OS_TYPE}/"
        
        cp "${OUT_DIR}/arch/arm64/boot/Image" "anykernel/kernels/${OS_TYPE}/"
        cp "${OUT_DIR}/arch/arm64/boot/dtb" "anykernel/kernels/${OS_TYPE}/"
        
        if [ -f "${OUT_DIR}/arch/arm64/boot/dtbo.img" ]; then
            cp "${OUT_DIR}/arch/arm64/boot/dtbo.img" "anykernel/kernels/${OS_TYPE}/"
        fi
        
        # 确定 ZIP 文件名
        local KSU_ZIP_STR="NoKernelSU"
        if [ "$ENABLE_KSU" -eq 1 ]; then
            KSU_ZIP_STR="SukiSU"
        fi
        local GIT_COMMIT_ID=$(git rev-parse --short=8 HEAD 2>/dev/null || echo "unknown")
        local OS_UPPER=$(echo "$OS_TYPE" | tr '[:lower:]' '[:upper:]')
        local ZIP_FILENAME="APTKernel_${OS_UPPER}_${DEVICE_NAME}_${KSU_ZIP_STR}_$(date +'%Y%m%d_%H%M%S')_anykernel3_${GIT_COMMIT_ID}.zip"
        
        echo "[*] Zipping $ZIP_FILENAME ..."
        pushd anykernel > /dev/null
        zip -r9 "$ZIP_FILENAME" ./* -x .git .gitignore out/ ./*.zip > /dev/null
        mv "$ZIP_FILENAME" ../
        popd > /dev/null
        
        echo "[+] $OS_TYPE kernel binaries successfully packed into: $ZIP_FILENAME"
    else
        echo "[-] $OS_TYPE Build Failed. Kernel Image not found."
        exit 1
    fi
}

# ==========================================
# Execute builds based on target OS
# ==========================================
if [ "$TARGET_OS" == "aosp" ] || [ "$TARGET_OS" == "both" ]; then
    build_target "aosp"
fi

if [ "$TARGET_OS" == "miui" ] || [ "$TARGET_OS" == "both" ]; then
    build_target "miui"
fi

echo "==========================================="
echo "[*] ccache stats:"
ccache -s
echo "[+] All requested builds completed!"
