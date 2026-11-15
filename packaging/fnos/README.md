# Strata for fnOS（NVIDIA CUDA，原生 fpk，无需 Docker）

在飞牛 fnOS 上原生运行的 [Strata](https://github.com/Niko1221/Strata)：本地大模型推理引擎 + 完整的网页界面（聊天、模型管理、监控），用 NVIDIA 显卡跑。本目录是 fork 里 `fpk` 分支的打包工程，作者 Cob。

## 包里有什么、没有什么

| | 来源 | 在不在包里 |
|---|---|---|
| 网页界面和宿主（Node 服务） | 上游 release 标签 `v0.2.13` 的 `apps/host`，构建时用 `npm ci && vite build` 重新构建 | 在 |
| Node 24.12.0 | nodejs.org 官方包（核对 SHA-256） | 在 |
| Python 3.12 + 全部依赖（numpy、jinja2、Pillow …） | 上游 Terminal 包 `strata-control-*`（核对 SHA-256） | 在 |
| 推理引擎 + CUDA 13 运行库（cudart、cuBLAS、cuBLASLt） | 上游引擎包 `strata-engine-*-cuda-cuda13`（核对 SHA-256） | 在 |
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
- AMD 显卡（含 MI50 / gfx906）**不支持**这个包：上游没有 gfx906 的预编译引擎，只能源码构建，以后另做一个变体。

## 访问方式

点飞牛桌面上的 Strata 图标，或访问 `http://NAS-IP:端口`（默认 **47831**）。**Strata 自己没有登录功能**，所以网页端口前面放了一个带 Basic Auth 的反向代理，安装向导里必须设置用户名和密码（密码以 scrypt 哈希保存，明文不落盘）。

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

## 数据在哪里

| | 位置 |
|---|---|
| **共享文件夹 `Strata`**（卸载不会删除） | `models/`（模型）、`workspace/`（聊天默认的工作目录） |
| 应用数据 | `/var/apps/strata/var/`（实际在 `/vol1/@appdata/strata/`）：`home/strata/`（聊天记录、设置）、`components/`（引擎的运行拷贝）、`home/.auth.json`（访问密码哈希）、`strata.log`（日志） |

已有的模型放进共享文件夹的 `models/` 即可；用命令行复制的话把属主改成 `strata`。

## 实测结果（2026-11-15，飞牛 fnOS 内核 6.18，i7-12700，125 GB 内存，RTX 3060 12 GB，驱动 580.142）

- `appcenter-cli install-fpk` 真实安装成功（向导参数用环境变量文件传入），应用用户 `strata`（在 video、render 组），共享文件夹 `Strata` 自动创建；启动约 1 秒就监听端口，宿主 2 秒内可用。
- 认证代理：不带密码 / 密码错误返回 401，正确返回界面；`/api/hardware`、`/api/engines`、`/v1/models` 都能通过代理访问。
- 硬件识别：机器里同时有 RTX 3060 和 MI50（32 GB）。上游宿主按显存最大选加速器，会选中 MI50（引擎没有它的代码）。`patches/0001-nvidia-only.patch` 加了开关 `STRATA_FPK_NVIDIA_ONLY=1`（`launch.sh` 里已设），只保留 NVIDIA 卡后识别为 `NVIDIA GeForce RTX 3060 / cuda`。
- 驱动库：引擎成功使用宿主机的 `libcuda.so.1`（`var/hostlibs` 里的符号链接）；服务的锁定内存限制是飞牛的默认值（8 MiB），引擎照常工作。
- 模型：通过宿主 API 下载 **Qwen3.6-35B-A3B UD-Q4_K_XL（22.9 GB，目录里最小的模型）**，走 hf-mirror.com，约 3.5 分钟（含校验）下完；加载成功后用 `/v1/chat/completions` 推理：**约 34–36 tokens/s**（32K 上下文、MTP；这个模型会先“思考”，所以短回答的 `content` 可能为空，内容在 `reasoning_content` 里）。
- 停止：`appcenter-cli stop` 约 6 秒，宿主、代理、Python 服务、引擎进程全部退出，显存从 11369 MiB 回到 0，端口关闭；再 `start` 正常。

## 已知问题和注意事项

- **12 GB 显存跑 128K 上下文会 `cudaMalloc … out of memory`**：Qwen3.6 的默认上下文是 128K，在 RTX 3060 上加载失败（引擎日志：`q36_engine.cu:1128`）。实测把上下文改成 32K 就能加载（在界面里选上下文；我是直接改了模型配置文件里的 `--max-context`）。更大显存的卡不一定有这个问题。
- **卸载必须在飞牛网页里做**（`appcenter-cli uninstall` 会拒绝）；`appcenter-cli install-fpk` 对已安装的同名应用会直接跳过，**升级也要在网页里做**。所以“升级路径”和“卸载向导”**没有实测**。
- **安装失败 `10234 … acl_get_file failed`**：飞牛安装时以 root 遍历应用目录，悬空 / 绝对 / 指到应用目录外的符号链接会让它失败。`build.sh` 在打包前检查这三类链接，有就直接报错。
- 第一次 `appcenter-cli start` 返回过一次 `Failed to launch app. error code 10500`，但应用中心日志里这次启动是 `success`，应用也确实起来了，之后的 start / stop 都正常；原因没查清。
- 宿主第一次启动会把 `engine-bundle` 里的引擎复制到应用数据的 `components/`，之后会删掉安装目录里的那份（日志有说明），所以占用的是应用数据里的 1.2 GB。
- **外部程序（Claude Code、OpenAI 兼容客户端）连 `/v1`**：网页端口要 Basic Auth，而这些客户端用 `Authorization: Bearer`，代理会拒绝。要给别的设备用 API，请用 Strata 自带的“其他设备”共享（它另开端口，带 API Key；用到的端口要自己在飞牛防火墙里放行）。这条没有实测。
- 防火墙服务文件（`.sc`）里写的是默认端口 47831；向导里改了端口又开着防火墙的话，要自己放行。
- **没有实测**：向导在飞牛网页里的渲染、飞牛桌面图标（`"port": "${wizard_port}"` 的写法照搬了 1Panel / MoonTVPlus）、视觉模型（图片）、DeepSeek V4.1。
- 直连端口是明文 HTTP，只在可信局域网里用。

## 构建

```bash
packaging/fnos/build.sh          # 输出 packaging/fnos/dist/strata_<版本>_amd64.fpk
BUILD_NUMBER=2 packaging/fnos/build.sh
```

需要 Node 24.12+、python3、curl、`fnpack`（`~/.local/bin/fnpack` 或 `FNPACK=`）、网络，工作目录约 3 GB。版本号形如 `0.2.13-cob.1`（上游 `0.2.13` + 本地小版本，符合 fork 规则）。换上游版本时同时改 `UPSTREAM_TAG`、`CONTROL_ASSET`、`ENGINE_ASSET`；校验值从该 release 的 `SHA256SUMS.txt` 自动取。

```bash
packaging/fnos/tests/test_proxy.sh   # 不需要 GPU / 飞牛：认证代理的 14 项检查
```

## 目录

```
build.sh                  构建脚本
fnos/                     fpk 骨架（@APPNAME@ 等占位符由 build.sh 替换）
├── manifest, config/     应用清单；privilege（应用用户 strata + video/render 组）、resource（共享文件夹、防火墙）
├── cmd/                  生命周期脚本（start/stop/status、安装/配置/升级/卸载回调）
├── wizard/               安装 / 设置 / 卸载向导
└── app/                  → /var/apps/strata/target
    ├── bin/launch.sh     环境、宿主机驱动库链接、宿主崩溃自动重启
    ├── bin/proxy.mjs     认证反向代理（HTTP / SSE / WebSocket）
    ├── bin/set-password.mjs
    └── ui/               飞牛桌面入口（直接打开网页端口）
tests/test_proxy.sh       认证代理的本地测试
build/, dist/             构建缓存和成品（不入库）
```
