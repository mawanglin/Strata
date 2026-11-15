# Strata for fnOS（原生 fpk，无需 Docker）

在飞牛 fnOS 上原生运行的 [Strata](https://github.com/Niko1221/Strata)：本地大模型推理引擎 + 完整的网页界面（聊天、模型管理、监控）。本目录是 fork 里的打包工程，作者 Cob。

两个变体，可以装在同一台 NAS 上：

| 变体 | 应用名 | 显卡 | 默认端口 | 共享文件夹 | 引擎来源 |
|---|---|---|---|---|---|
| CUDA | `strata` | NVIDIA RTX 20 / 30 / 40 / 50 | 47831 | `Strata` | 上游 release 的 CUDA13 引擎包 |
| gfx906 | `strata-gfx906` | AMD Instinct MI50 / MI60、Radeon VII | 47832 | `Strata-gfx906` | 自己编译（上游没有现成包），见 [gfx906 变体](#gfx906-变体amd-mi50--mi60--radeon-vii) |

下面先讲 CUDA 版；两者共用同一套脚本、界面、认证代理和向导，只有引擎和显卡相关的部分不同。

## 包里有什么、没有什么

| | 来源 | 在不在包里 |
|---|---|---|
| 网页界面和宿主（Node 服务） | 上游 release 标签 `v0.2.13` 的 `apps/host`，构建时用 `npm ci && vite build` 重新构建 | 在 |
| Node 24.12.0 | nodejs.org 官方包（核对 SHA-256） | 在 |
| Python 3.12 + 全部依赖（numpy、jinja2、Pillow …） | 上游 Terminal 包 `strata-control-*`（核对 SHA-256） | 在 |
| 推理引擎 + CUDA 13 运行库（cudart、cuBLAS、cuBLASLt）+ GPU 图片读取器 | 上游引擎包 `strata-engine-*-cuda-cuda13`（核对 SHA-256） | 在 |
| DeepSeek V4.1 引擎（`strata-dsv41`，独立组件） | 上游 `strata-dsv41-*-cuda-cuda13`（核对 SHA-256），原样放进包里，启动时放到 `install/engine-dsv41/`，选 DeepSeek 模型时 Strata 核对上游签名后自己安装 | 在 |
| 固定版本的 llama.cpp（模型处理工具要用） | 构建时按 `setup.py` 固定的提交取回 | 在 |
| 网页端口的认证反向代理 | `app/bin/proxy.mjs`（Node 标准库，无第三方依赖） | 在 |
| **NVIDIA 驱动的内核模块** | 飞牛应用中心的 `Nvidia-Driver-580` | **不在**：内核模块不可能放进应用包 |
| **`libcuda.so.1`、`libnvidia-ml.so.1`** | 同上 | **不在**：它们必须和内核模块**同一个版本**，打进包里一旦驱动升级就会对不上。运行时只把这几个库做成符号链接放进应用自己的一个目录（`var/hostlibs`），再加进 `LD_LIBRARY_PATH`，不会把宿主机别的库带进来 |

不往系统里装任何东西：不装 Docker 容器、不装 apt 包、不改系统目录；应用不用沙箱，直接以应用用户 `strata` 运行，设备文件 `/dev/nvidia*` 本来就对所有用户开放。

## 要求

- 飞牛 fnOS（x86_64，glibc ≥ 2.34；飞牛基于 Debian 12，是 2.36），已安装并启用应用中心里的 **NVIDIA 驱动**，驱动版本 ≥ **580.65**（引擎要求）。
- NVIDIA RTX 20 / 30 / 40 / 50 系列（引擎带 sm_75 / 86 / 89 / 120 的机器码）。
- CPU 支持 AVX2（引擎按可移植方式编译，要求 AVX2）。
- 内存和显存按模型来，见上游的 [模型选择指南](../../docs/MODELS.md)。
- AMD MI50 / MI60 / Radeon VII 用 gfx906 变体；其他 AMD 显卡两个包都不支持。

## 访问方式

点飞牛桌面上的 Strata 图标，或访问 `http://NAS-IP:端口`（默认 **47831**）。**Strata 自己没有登录功能**，所以网页端口前面放了一个带 Basic Auth 的反向代理，安装向导里必须设置用户名和密码（密码以 scrypt 哈希保存，明文不落盘）。

### 给 Claude Code、Codex 等程序用（API Key）

向导（以及应用设置）的“API 访问”里开启并设置 **API Key**（16 位以上，字母、数字、- 和 _；只保存 SHA-256）后，程序可以不登录网页、直接用 Key 调用 `/v1` 接口：

| 协议 | 地址 | Key 放在 |
|---|---|---|
| OpenAI 兼容 | `http://NAS-IP:端口/v1` | `Authorization: Bearer <Key>` |
| Anthropic 兼容（Claude Code） | `http://NAS-IP:端口` | `x-api-key: <Key>`（或 Bearer） |

```bash
# Claude Code
ANTHROPIC_BASE_URL=http://NAS-IP:47831 ANTHROPIC_API_KEY=<Key> ANTHROPIC_MODEL=<模型 id，见 /v1/models> claude
```

- Key 只对 `/v1/...` 有效；带 Key 访问网页和 `/api` 会被拒（401），网页仍然只能用户名密码登录。错 Key 返回 401 的 JSON 错误（不会弹浏览器登录框）。
- 认证由本包的代理做。**不要再在 Strata 网页设置里另设 API Key**：代理认完就把 Key 头去掉，宿主那边若另有 Key 会对不上。
- Claude Code 不认识 Strata 的模型名，会提示 “assumes a context window of 1m tokens”，实际窗口是模型加载时的上下文（如 128K），长会话前按它提示的文档设一下窗口。
- 明文 HTTP，同样只在可信局域网里用。

为什么不走飞牛网关（`/app/strata/`）：这个界面的前端在代码里到处用绝对路径（`/api/…`、`/icons/…`、`/fonts/…`），放到网关的子路径下需要改写大量响应，很脆；直连端口加认证简单可靠。代价是 FN Connect 不能直接用，以及这是**明文 HTTP**，请只在可信的局域网里用，需要外网访问时放在你自己的 VPN / 反向代理（带 HTTPS）后面。

## 模型下载源

Strata 首次使用要下载几十 GB 的模型。向导里可选：

| 选项 | 效果 |
|---|---|
| Hugging Face 镜像站 hf-mirror.com（默认） | 设置 `HF_ENDPOINT=https://hf-mirror.com`；文件与官方一致，上游固定版本的 SHA-256 校验仍然生效 |
| ModelScope（魔搭） | 设置 `STRATA_SOURCE=modelscope`；注意它提供的是仓库的**当前**文件，不是 Strata 固定的版本（上游文档的说明） |
| Hugging Face 官方站 | 不设置 |
| 自定义镜像站 | `HF_ENDPOINT=<你填的地址>` |

之后可以在飞牛应用设置里改，保存后应用自动重启。

## 两个应用共用模型目录

同时装了 NVIDIA 版和 gfx906 版时，可以让一个用另一个的 `models` 目录，下载过的模型不用再下（两边都能跑的是 Qwen3.8-Flash-Next 系列）：

1. 在应用设置的“模型目录”里选“与另一个 Strata 共用”。
2. **在飞牛应用中心里本应用的“设置 → 授权目录”里添加对方的共享文件夹**（NVIDIA 版加 `Strata-gfx906`，gfx906 版加 `Strata`），再重启本应用。

为什么要第 2 步：飞牛的共享文件夹由它自己的 **Trim-ACL**（`/usr/trim/bin/trimacl`）管，每个共享文件夹只允许它所属的应用用户和用户组 1000 访问；应用（包括 `cmd/` 生命周期脚本）都以应用用户运行，改不了别的应用的目录（试过 POSIX ACL：写得进去但不起作用，已撤销）。“授权目录”是飞牛给应用开放别的目录的正式办法。没授权时应用自动用自己的目录，日志里有一行 `models: sharing was asked for, but ...` 说明原因。

**没有在真机上实测授权后的效果**（授权目录只能在飞牛网页里加）；`tests/test_models_dir.sh` 检查了目录选择的逻辑。

## 数据在哪里

| | 位置 |
|---|---|
| **共享文件夹 `Strata`**（卸载不会删除） | `models/`（模型）、`workspace/`（聊天默认的工作目录） |
| 应用数据 | `/var/apps/strata/var/`（实际在 `/vol1/@appdata/strata/`）：`home/strata/`（聊天记录、设置）、`components/`（引擎的运行拷贝）、`home/.auth.json`（访问密码哈希）、`strata.log`（日志） |

已有的模型放进共享文件夹的 `models/` 即可；用命令行复制的话把属主改成 `strata`。

## 实测结果（2026-11-15，飞牛 fnOS 内核 6.18，i7-12700，125 GB 内存，RTX 3060 12 GB，驱动 580.142）

- `appcenter-cli install-fpk` 真实安装成功（向导参数用环境变量文件传入），应用用户 `strata`（在 video、render 组），共享文件夹 `Strata` 自动创建；启动约 1 秒就监听端口，宿主 2 秒内可用。
- 认证代理：不带密码 / 密码错误返回 401，正确返回界面；`/api/hardware`、`/api/engines`、`/v1/models` 都能通过代理访问。
- 硬件识别：机器里同时有 RTX 3060 和 MI50（32 GB）。上游宿主按显存最大选加速器，会选中 MI50（引擎没有它的代码）。`patches/0001-gpu-vendor.patch` 加了开关 `STRATA_FPK_GPU_VENDOR=nvidia|amd`（`launch.sh` 按变体设置），只保留本变体厂商的卡后识别为 `NVIDIA GeForce RTX 3060 / cuda`。
- 驱动库：引擎成功使用宿主机的 `libcuda.so.1`（`var/hostlibs` 里的符号链接）；服务的锁定内存限制是飞牛的默认值（8 MiB），引擎照常工作。
- 模型：通过宿主 API 下载 **Qwen3.6-35B-A3B UD-Q4_K_XL（22.9 GB，目录里最小的模型）**，走 hf-mirror.com，约 3.5 分钟（含校验）下完；加载成功后用 `/v1/chat/completions` 推理：**约 34–36 tokens/s**（32K 上下文、MTP；这个模型会先“思考”，所以短回答的 `content` 可能为空，内容在 `reasoning_content` 里）。
- 停止：`appcenter-cli stop` 约 6 秒，宿主、代理、Python 服务、引擎进程全部退出，显存从 11369 MiB 回到 0，端口关闭；再 `start` 正常。
- **API Key**：OpenAI（Bearer）和 Anthropic（`x-api-key`）两种协议的非流式、流式（SSE 事件完整）都通；错 Key / 用 Key 访问网页路径都是 401。**Claude Code 2.1 真实连接**（gfx906 版的 Coder 模型）：一句话任务 63 秒完成，建出的 `sum.py` 运行正确。
- **图片**：Qwen3.6 带图片重新准备后（补下 `mmproj-F16.gguf`），通过 API 发一张测试图（红圆、蓝方块、数字 742），回答 “A red circle and a blue square are positioned above the number 742.”，25 秒；12 GB 显存下 Strata 用的是 CPU 读图器。
- **DeepSeek 引擎**：启动时引擎包被放进 `install/engine-dsv41/`；用 Strata 自己的安装函数检查：上游签名有效、每个文件哈希一致，装好后试启动输出 `strata-dsv41 0.1.59 build 712fec6b4`。

## 已知问题和注意事项

- **小显存卡的上下文：自动降档**（`patches/0003-q36-context-fallback.patch`，`STRATA_FPK_CONTEXT_FALLBACK=1`）。Qwen3.6 引擎把整个上下文（fp32 的 K/V）放在显存里，没有放到内存的选项（大内存用来放专家：64K 时 256 个专家全在内存里），所以上游“所有卡默认 128K”在 12 GB 卡上起不来。补丁让它在引擎日志说显存不够时把上下文减半重试（最低 16K），成功的值写回模型配置，下次直接从这里起；用户在模型设置里自己选过的上下文不改；只是“同时 2 个请求”放不下（单个放得下）时交给上游的“一次一个请求”处理，不降上下文。
  RTX 3060 12 GB 实测：128K ❌，96K ❌（放完上下文只剩 216 MiB，专家缓冲区要 1256 MiB），**64K ✅（约 29.7 tok/s）**，32K ✅（约 36 tok/s）。连续三次加载：第 1 次 128K → 自动 64K 并记住，第 2、3 次直接 64K。
- **卸载必须在飞牛网页里做**（`appcenter-cli uninstall` 会拒绝）；`appcenter-cli install-fpk` 对已安装的同名应用会直接跳过，**升级也要在网页里做**。所以“升级路径”和“卸载向导”**没有实测**。
- **安装失败 `10234 … acl_get_file failed`**：飞牛安装时以 root 遍历应用目录，悬空 / 绝对 / 指到应用目录外的符号链接会让它失败。`build.sh` 在打包前检查这三类链接，有就直接报错。
- 第一次 `appcenter-cli start` 返回过一次 `Failed to launch app. error code 10500`，但应用中心日志里这次启动是 `success`，应用也确实起来了，之后的 start / stop 都正常；原因没查清。
- **不在线更新程序**：引擎、Control、DeepSeek 引擎都随 fpk 走（`launch.sh` 设 `STRATA_FPK_NO_UPDATES=1`，`patches/0002-no-online-updates.patch`）。设置里没有“更新引擎 / 更新 Strata”，“检查更新”返回“请安装更新的 fpk”，更新操作会被拒绝。**模型、读图文件、DFlash2 草稿模型照常下载**（它们是数据，不是程序）。从本地文件安装引擎（离线、手动）仍然可以。实测：关掉后装模型、加载、推理都正常。
- 宿主第一次启动会把 `engine-bundle` 里的引擎复制到应用数据的 `components/`，之后会删掉安装目录里的那份（日志有说明），所以占用的是应用数据里的 1.2 GB。
- **图片要在模型准备时开启**：模型当初没开图片就装了的话，之后加载时开图片不会自动补文件（服务端会报 “started without the vision encoder”）。在界面里带图片重新准备一次这个模型即可，只补下读图文件（约 1 GB），不会重下模型本体。
- **DeepSeek V4.1 的模型没有实测**（最小的也要 190 GB 以上）；引擎已在飞牛上验证（见下）。它会把放不进内存的部分从硬盘读，模型放在机械硬盘上会很慢。
- 防火墙服务文件（`.sc`）里写的是默认端口 47831；向导里改了端口又开着防火墙的话，要自己放行。
- **没有实测**：向导在飞牛网页里的渲染、飞牛桌面图标（`"port": "${wizard_port}"` 的写法照搬了 1Panel / MoonTVPlus）、DeepSeek V4.1 的模型推理、Codex / OpenCode 等其他客户端（协议和 curl 测过的一样）。
- 直连端口是明文 HTTP，只在可信局域网里用。

## gfx906 变体（AMD MI50 / MI60 / Radeon VII）

上游没有 gfx906 的现成引擎：它是单独的 `-DSTRATA_HIP_GFX906=ON` 构建（把 CUDA 源码当 HIP 编译，wave64），上游只说“社区测试过”，
安装程序也不认这张卡。这个变体自己编引擎，其余（界面、宿主、Control、代理、向导）和 CUDA 版共用。

**引擎怎么来的**（`gfx906/build-engine-docker.sh` → `gfx906/build-engine.sh`）：

- 在 **Ubuntu 22.04 容器**（glibc 2.35）里编译，和上游官方 HIP 包的做法一样，所以产物能跑在飞牛（Debian 12，glibc 2.36）上。实测产物最高要求 GLIBC_2.34、GLIBCXX_3.4.30。
- ROCm 用 **AMD TheRock 的 gfx906 wheel**（`rocm[libraries,devel]==7.14.0a20260612`，索引 `https://rocm.nightlies.amd.com/v2/gfx906/`）：AMD 正式版 ROCm 已经不带 gfx906，而 TheRock 的 rocBLAS 里有 gfx906 的内核（`rocblas/library/gfx906/`）。上游 gfx906 报告者用的也是 HIP 7.14。
- 源码是上游 `v0.2.13` 里 0.1.59 引擎的那个提交（`712fec6b4297`）。
- 引擎、CPU 图片读取器、**GPU 图片读取器**（llama.cpp 的 ggml-hip 编给 gfx906，`strata-vision-hip`）、ROCm 运行库（HIP、HSA、rocBLAS、hipBLAS、comgr……）和 **只有 gfx906 的** rocBLAS 内核数据一起，用上游的 `package_engine.py` 打成标准引擎组件 `0.1.59-linux-x86_64-hip-gfx906`（RUNPATH 都是 `$ORIGIN`，`binary_deps.py` 检查通过）。**运行时连宿主机的用户态库都不需要**，只用内核自带的 amdgpu 驱动（`/dev/kfd`、`/dev/dri`）。
- 构建过程中踩过的坑都已经写进脚本：Python 环境放在容器自己的文件系统里（放在 ZFS 绑定挂载上，rocm-sdk 建硬链接会报 `Invalid cross-device link`）；用独立版 CPython 3.12（TheRock 的 `rocm-sdk` 在 22.04 的 Python 3.10 / 早期 3.11 上会报 `MetadataPathFinder.invalidate_caches()` 错）；可选的 `APT_MIRROR`、`PIP_MIRROR`（国内的官方源很慢或超时）。

**补丁**（都很小，打不上就让构建失败）：

| 补丁 | 打在哪 | 作用 |
|---|---|---|
| `gfx906/patches/0001-hip-compat-stream-priority.patch` | 引擎源码 | gfx906 兼容层缺 `cudaStreamCreateWithPriority`、`cudaDeviceGetStreamPriorityRange` 的映射，`src/core/dflash2.cpp` 编不过；补两行 `#define`。上游到现在的 HEAD 也没补 |
| `patches/control/0001-gfx906-opt-in-and-backend.patch` | Control 的 `setup.py` | ① 加开关 `STRATA_EXPERIMENTAL_GFX906=1`（照上游 gfx1103 / gfx1150 的写法），把 gfx906 加进 AMD 支持名单；② 安装时没指定后端就用 `STRATA_ENGINE_BACKEND`，否则同时有 NVIDIA 卡的机器会默认装成 CUDA |
| `patches/0001-gpu-vendor.patch` | 宿主 | 只保留本变体厂商的卡（两个变体共用） |
| `patches/0002-no-online-updates.patch` | 宿主 | 关掉引擎 / Control 的在线更新（两个变体共用） |
| `patches/0003-q36-context-fallback.patch` | 宿主 | Qwen3.6 显存不够时自动降上下文并记住（两个变体共用；gfx906 不跑 Qwen3.6，不会触发） |

`launch.sh` 按 `bin/variant.env`（构建时写入）设置：gfx906 版 `STRATA_FPK_GPU_VENDOR=amd`、`STRATA_ENGINE_BACKEND=hip`、`STRATA_EXPERIMENTAL_GFX906=1`，不链接任何宿主机的库。

**能跑哪些模型**：这个引擎只有 `qwen4exp` 一个系列（`strata --families`），也就是 **Qwen3.8-Flash-Next 及其 Coder / Swift / Unsloth / Gyro 等量化**。**Qwen3.6-35B-A3B 不在 gfx906 构建里**（上游文档也这么说），目录里虽然列着，但装了也跑不起来。最小可用的是 Coder IQ1_M（58.4 GB）。**DeepSeek V4.1 也不支持**：上游的 CMake 明确写着 `STRATA_BUILD_DSV41 AND NOT STRATA_HIP_GFX906`，要支持得移植它的内核，不是打包能解决的。

### gfx906 实测（2026-11-15，同一台 NAS，Instinct MI50 32 GB，和 RTX 3060 同机）

- `appcenter-cli install-fpk` 安装 `strata-gfx906`（端口 47832、共享文件夹 `Strata-gfx906`、应用用户在 video / render 组），和 CUDA 版的 `strata` **同时运行**互不影响（内部端口被占用时自动换一个）。
- 硬件识别为 MI50；Control 认为 MI50 可用、引擎 `0.1.59 (linux-x86_64-hip)` 可用；装模型时后端自动是 `hip`。
- 下载 **Qwen3.8-Flash-Next Coder IQ1_M（58.4 GB）**，hf-mirror.com，约 15 分钟（含校验和 MTP 草稿层）。
- 默认 **128K 上下文**直接加载成功（MI50 显存用到 31.3 / 32 GB，Strata 自动设为同时 2 个请求）。
- 推理：写 `is_prime` 函数（162 token，7.4 秒，代码正确），`17*23` 回答 391；**解码平均约 60 tokens/s，峰值约 78**。上游的社区报告是 2 张 MI50 16 GB 跑同一个模型约 50 tok/s。
- 停止约 6 秒，MI50 显存从 31352 MiB 回到 10 MiB。
- **图片**（上游文档写着 gfx906 “没做过”）：Coder 带图片重新准备后（补下 `mmproj-Qwen3.8-Flash-Next-BF16.gguf`），32 GB 显存下 Strata 选了 **GPU 读图器 `strata-vision-hip`**，测试图回答 “A red circle and a blue square are shown above the number 742.”，6 秒。
- **API Key** 和 Claude Code 的测试就是在这个版本上做的（见 CUDA 版实测）。
- **没有实测**：MI60 和 Radeon VII（同一指令集，没跑过）、多张 gfx906 卡、DFlash2 草稿模型。

**和 ComfyUI（gfx906）共用一张卡**：Strata 加载模型后几乎占满 MI50 的显存，这时 ComfyUI 出图会显存不足；反过来也一样。两个不要同时用，或者在 Strata 里卸载模型（停止应用也行）。

## 构建

```bash
packaging/fnos/build.sh                          # CUDA 版：dist/strata_<版本>_amd64.fpk
BUILD_NUMBER=2 packaging/fnos/build.sh

# gfx906 版：先在有 docker 的 x86_64 Linux（比如飞牛本机）编引擎。在飞牛上一次完整流程（装系统包、下载 ROCm wheel、编译、打包）实测约 17 分钟，
# 但那次引擎是在之前失败的编译上增量编译的，从零编译的时间没单独测
APT_MIRROR=http://mirrors.ustc.edu.cn PIP_MIRROR=https://mirrors.cloud.tencent.com/pypi/simple \
    packaging/fnos/gfx906/build-engine-docker.sh /path/to/work
# 再打 fpk：dist/strata-gfx906_<版本>_amd64.fpk
VARIANT=gfx906 ENGINE_COMPONENT=/path/to/work/out/components/engine/0.1.59-linux-x86_64-hip-gfx906 packaging/fnos/build.sh
```

`build.sh` 需要 Node 24.12+、python3、curl、`fnpack`（`~/.local/bin/fnpack` 或 `FNPACK=`）、网络，每个变体的工作目录约 3 GB（`packaging/fnos/build/<变体>/`，下载缓存共用 `packaging/fnos/build/cache/`）。版本号形如 `0.2.13-cob.1`（上游 `0.2.13` + 本地小版本，符合 fork 规则）。换上游版本时同时改 `UPSTREAM_TAG`、`CONTROL_ASSET`、`ENGINE_ASSET`；校验值从该 release 的 `SHA256SUMS.txt` 自动取。

```bash
packaging/fnos/tests/test_proxy.sh             # 认证代理（用户名密码、/v1 的 API Key、转发、流式、WebSocket），25 项
packaging/fnos/tests/test_context_fallback.sh  # Qwen3.6 上下文自动降档的判断，11 项
packaging/fnos/tests/test_models_dir.sh        # 共用模型目录的选择，5 项
# 都不需要 GPU / 飞牛
```

## 目录

```
build.sh                  构建脚本（VARIANT=cuda|gfx906）
gfx906/                   gfx906 引擎的构建：build-engine-docker.sh（宿主侧）、build-engine.sh（容器里）、patches/（引擎源码补丁）
patches/                  宿主补丁（0001-gpu-vendor、0002-no-online-updates、0003-q36-context-fallback）；patches/control/ 是 Control 的补丁
fnos/                     fpk 骨架（@APPNAME@ 等占位符由 build.sh 替换）
├── manifest, config/     应用清单；privilege（应用用户 strata + video/render 组）、resource（共享文件夹、防火墙）
├── cmd/                  生命周期脚本（start/stop/status、安装/配置/升级/卸载回调）
├── wizard/               安装 / 设置 / 卸载向导
└── app/                  → /var/apps/strata/target
    ├── bin/launch.sh     环境（按 bin/variant.env 区分变体）、宿主机 NVIDIA 驱动库链接、宿主崩溃自动重启
    ├── bin/proxy.mjs     认证反向代理（HTTP / SSE / WebSocket）
    ├── bin/set-password.mjs   网页密码（scrypt）
    ├── bin/set-api-key.mjs    API Key（SHA-256）
    └── ui/               飞牛桌面入口（直接打开网页端口）
tests/test_proxy.sh       认证代理的本地测试
build/                    构建缓存（不入库）；成品在仓库根目录的 dist/（不入库）
```
