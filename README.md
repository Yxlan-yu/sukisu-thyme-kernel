# sukisu-thyme-kernel

小米 10S（`thyme` / sm8250）HyperOS 4 / Android 17 内核构建仓，用于给 **非 GKI** 的 4.19 内核集成 **SukiSU-Ultra v4.3.0-r1**。

## 用途

`images/boot.img` 属于 header v3、无 AVB footer 的明文 boot，kernel 为 4.19.325（`CONFIG_KPROBES` 未开启、非 GKI），因此 SukiSU 的 LKM / GKI 模式都不可用，只能集成内核源码后重编。

本仓库只做一件事：

1. 下载 `AstideLabs/android_kernel_xiaomi_sm8250` 分支 `android17-aptusitu` 源码；
2. 用 `kernel/setup.sh` 换成 **SukiSU v4.3.0-r1**（上游默认是 ReSukiSU/BakaSU）；
3. 打开 `CONFIG_KPROBES`（SukiSU Kconfig 依赖 `KPROBES && EXT4_FS`）；
4. 编译 thyme 的 MIUI 内核，产出 AnyKernel3 zip + 原始 `Image`。

## 触发方式

Actions → `Build SukiSU Kernel (thyme)` → Run workflow（`workflow_dispatch`，无参数）。

单次构建约 40–60 分钟，产物：

- `APTKernel_MIUI_thyme_SukiSU_*.zip`（AnyKernel3，可用内核管理器/Recovery 刷入）
- `out_miui/arch/arm64/boot/Image`（用于离线重打 `boot.img`）
- `dtb` / `dtbo.img` / `.config`（核对与备查）

## 与上游 build_kernel.sh 的差异

- KernelSU 段：`ReSukiSU/ReSukiSU/main/kernel/setup.sh` → `SukiSU-Ultra/SukiSU-Ultra/v4.3.0-r1/kernel/setup.sh`，并显式 `checkout v4.3.0-r1`；
- `scripts/config`：`-e KSU -e KPROBES -e MODULES -e KALLSYMS -e KALLSYMS_ALL`（去掉 `THREAD_INFO_IN_TASK` 与上游不存在的 `KSU_SUSFS`）；
- 打包名 `KSU_ZIP_STR=SukiSU`；
- `make olddefconfig` 之后增加断言：`CONFIG_KSU` / `CONFIG_KPROBES` / `CONFIG_KALLSYMS_ALL` / `CONFIG_EXT4_FS` 必须为 `y`，否则立即失败。

## 注意

- 管理器必须用官方已签名 release APK（`SukiSU_v4.3.0-r1_*_release.apk`），自签包可能被内核拒绝。
- 本仓产物只替换 `boot` 分区的 kernel，**不改动 ROM 自带的 dtbo / vendor_boot**。
