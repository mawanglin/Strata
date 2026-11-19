# Strata for fnOS（原生 fpk，无需 Docker）

在飞牛 fnOS 上原生运行的 [Strata](https://github.com/Niko1221/Strata)：本地大模型推理引擎 + 完整的网页界面（聊天、模型管理、监控）。本目录是 fork 里的打包工程，作者 Cob。

两个变体，可以装在同一台 NAS 上：

| 变体 | 应用名 | 显卡 | 默认端口 | 共享文件夹 | 引擎来源 |
|---|---|---|---|---|---|
| CUDA | `strata` | NVIDIA RTX 20 / 30 / 40 / 50 | 47831 | `Strata` | 上游 release 的 CUDA13 引擎包 |
| gfx906 | `strata-gfx906` | AMD Instinct MI50 / MI60、Radeon VII | 47832 | `Strata-gfx906` | 自己编译（上游没有现成包），见 [gfx906 变体](#gfx906-变体amd-mi50--mi60--radeon-vii) |

下面先讲 CUDA 版；两者共用同一套脚本、界面、认证代理和向导，只有引擎和显卡相关的部分不同。

两个应用的**图标不一样**（`tools/make_icon.py`，构建时生成）：Strata 图标中间那条横杠换成厂商的标志色，下方写厂商名，NVIDIA 版是绿色 “NVIDIA”，gfx906 版是红色 “AMD”，飞牛桌面上一眼能分清。

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

**只有一个 Key，就是 Strata 自己的**：打开 Strata 网页 → 左侧 **“API 服务”** → **“API 密钥”** → **“创建 API 密钥”**（可以“再生成一个”）→ **“使用此密钥”**。本地共享、Cloudflare 隧道、`strata connect` 用的也是它。设好后程序可以不登录网页、直接用 Key 调用 `/v1` 接口：

| 协议 | 地址 | Key 放在 |
|---|---|---|
| OpenAI 兼容 | `http://NAS-IP:端口/v1` | `Authorization: Bearer <Key>` |
| Anthropic 兼容（Claude Code） | `http://NAS-IP:端口` | `x-api-key: <Key>`（或 Bearer） |

```bash
# Claude Code
ANTHROPIC_BASE_URL=http://NAS-IP:47831 ANTHROPIC_API_KEY=<Key> ANTHROPIC_MODEL=<模型 id，见 /v1/models> claude
```

- Key 只对 `/v1/...` 有效；带 Key 访问网页和 `/api` 会被拒（401），网页仍然只能用户名密码登录。错 Key 返回 401 的 JSON 错误（不会弹浏览器登录框）。
- 认证由本包的代理做：它拿 Strata 的 Key（`home/strata/data/state.json` 的 `serving.apiKey`）来校验，通过后用同一个 Key 转发给宿主；**Strata 里没设 Key 时，带 Key 的请求一律拒绝**（401，提示去 Strata 里创建），`/v1` 不会因为没设 Key 而敞开。在 Strata 里换 Key 不用重启，旧 Key 立刻失效。
- 为什么不在飞牛设置里另设一个：早期版本那样做过，结果有两个设置的地方——飞牛设置页显示默认值、一保存就把 Key 删了；两边各设一个时还会对不上。统一成 Strata 自己的 Key 后这两类问题都没有了。从旧版本升级时，飞牛设置里那个 Key（只存了哈希，取不回原文）不再使用，启动时删除并在日志里说明：**在 Strata 里创建一个 Key，把程序里的 Key 换成它**。
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

## 模型目录：授权目录，两个应用共用

模型可以放在本应用的共享文件夹（默认），也可以放在**授权给本应用的文件夹**里：

1. 在飞牛应用中心里本应用的“设置 → 授权目录”添加一个文件夹（比如自己的 `Model`），设置里“模型目录”选“授权目录里的文件夹”，重启应用。
2. 模型放进它下面的 **`Strata` 子文件夹**（`/vol1/1000/Model/Strata`），不和你放在 `Model` 里的别的东西混在一起。
3. **NVIDIA 版和 gfx906 版授权同一个文件夹，就共用一个模型库**：一边下载过的模型，另一边“下载”时只校验、不重复下载（两边都能跑的是 Qwen3.8-Flash-Next 系列）。

为什么要授权：飞牛的共享文件夹由它自己的 **Trim-ACL**（`/usr/trim/bin/trimacl`）管，每个应用只能访问自己的共享文件夹和被授权的文件夹；应用（包括 `cmd/` 生命周期脚本）以应用用户运行，改不了别的目录的权限（试过 POSIX ACL：写得进去但不起作用，已撤销）。“授权目录”就是飞牛给文件夹加上应用用户的 Trim-ACL（实测 `Model` 上多了 uid 899、900 两条允许规则，继承到子目录和文件）。

实测（2026-11-15）：两个应用都授权 `/vol1/1000/Model`，日志显示 `models: in an authorized folder ...: /vol1/1000/Model/Strata`；CUDA 版“安装”只在 gfx906 版下载过的 Coder IQ1_M：**36 秒，没有下载**，在 RTX 3060 上 128K 上下文加载、推理正确（约 32 tok/s）。已经装过的模型不会搬家（gfx906 版的 Coder 仍用它原来那份），只有新装的进共享库。

**往授权文件夹里手动放 / 复制模型时注意**：飞牛按 Trim-ACL 判断权限，用 `cp` 以 root 复制进去的文件不会继承授权，两个应用都读不了。复制后要补上规则（以 root）：
`find /vol1/1000/Model/Strata -mindepth 1 -exec /usr/trim/bin/trimacl -m a:u:<应用uid>:rwxpdDaAeEc:sfd {} \;`（两个应用的 uid 各一次，`id -u strata`、`id -u strata-gfx906`）。在 ZFS 上 `cp` 是块克隆，几十 GB 瞬间复制完，不多占空间。

## 终端命令

包里带着 Strata 的命令行，用和应用完全相同的环境运行（SSH 到飞牛后）：

```bash
sudo /var/apps/strata/target/bin/strata status        # gfx906 版把 strata 换成 strata-gfx906
sudo /var/apps/strata/target/bin/strata monitor       # 实时看速度、显存、请求（q 退出；--once 只看一次）
sudo /var/apps/strata/target/bin/strata --help
```

`status` / `monitor` 没给 `--url` 时自动接上网页里正在运行的模型（宿主分配的端口和密钥，密钥经环境变量传，不出现在进程参数里）；没加载模型时会提示。实测能看到模型、显卡占用、请求记录。`strata runtime …` 管的是命令行自己起的服务，和应用里的实例格式不同（`runtime status` 会报 “unsupported shape”），不要用它管应用里的模型。

## HTTPS

设置里“HTTPS”开启后，**同一个端口同时收 HTTP 和 HTTPS**（看连接的第一个字节是不是 TLS 握手），地址改成 `https://NAS-IP:端口`：

- 证书：默认自动生成**自签名证书**（ECDSA P-256，10 年，`bin/tls-cert.mjs` 只用 Node 自带的 crypto 生成，不用系统的 openssl），覆盖 NAS 的主机名、`localhost` 和所有 IP；本机的名字或 IP 变了会重新生成。想用正式证书（比如飞牛里申请的域名证书），导出成 `cert.pem` + `key.pem` 放进共享文件夹的 `tls/` 目录，重启应用即可（私钥和证书对不上时不用它，日志说明，只开 HTTP）。
- 网页从 http 打开会 308 跳到 https；**`/v1` 接口两种都收**，已经配好 `http://` 的程序不受影响。自签名证书下程序要走 https，得信任这张证书（`/var/apps/<应用>/var/home/tls/cert.pem`）。
- 实测：证书被 openssl 和 Node 正确解析，SAN 含全部 IP；把它当 CA 时按 IP 严格校验通过；页面和资源经 HTTPS 正常；HTTP 网页 308 跳转；HTTP / HTTPS 的 `/v1` 都是 200；WebSocket 和流式响应经 HTTPS 正常。默认关闭。

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

- **两个应用打开后都显示 NVIDIA 的卡**（2026-11-19 发现，cob.14 / cob.13 修好）：有两个原因。
  - **开机时端口冲突、留下孤儿进程**：两个变体的宿主都优先用内部端口 18791，飞牛开机时两个应用几乎同时启动，后起的宿主报 “Port 18791 is already in use” 起不来。`launch.sh` 有 `set -eu`，宿主出错退出时 `wait` 的非零返回值让整个脚本直接退出（本该有的自动重启也就没发生），已经启动的反向代理没人停，一直占着网页端口；再启动时新代理听不上，旧代理还在把请求转给 18791，也就是 **另一个应用的宿主**，于是 gfx906 版的网页打开的是 CUDA 版（11-18 的日志）。停止应用时也一样：`cleanup` 里 `wait` 宿主的退出码让脚本中途退出，代理留了下来（11-19 部署时又碰到一次）。现在：两个变体用不同的首选宿主端口（CUDA 18791，gfx906 18891）；宿主退出按设计自动重启；`launch.sh` 不管怎么退出都停掉代理和宿主（`trap … EXIT`），`cleanup` 里的 `wait` / `kill` 失败不再中断；网页端口听不上时直接启动失败（日志 `the web port … could not be opened`）；`cmd/main` 判定启动失败时把 launch.sh 的整组进程一起停掉。`tests/test_launch_lifecycle.sh` 覆盖这些情况。
  - **Control 列出机器里所有的卡**：上游的 Control 报告所有显卡，另标 `engine_vendor`，模型计划只算引擎那一家的卡；但网页里“本机”之类的卡片按这个列表显示，两个应用都把 RTX 3060 排在第一。`patches/control/0003-gpu-vendor.patch` 让 Control 和宿主一样按 `STRATA_FPK_GPU_VENDOR` 只留本变体的卡：CUDA 版只有 RTX 3060，gfx906 版只有 MI50（NAS 上核对过两边的 `/api/native` 和 `/api/hardware`）。
- **小显存卡的上下文：自动降档**（`patches/0003-q36-context-fallback.patch`，`STRATA_FPK_CONTEXT_FALLBACK=1`）。Qwen3.6 引擎把整个上下文（fp32 的 K/V）放在显存里，没有放到内存的选项（大内存用来放专家：64K 时 256 个专家全在内存里），所以上游“所有卡默认 128K”在 12 GB 卡上起不来。补丁让它在引擎日志说显存不够时把上下文减半重试（最低 16K），成功的值写回模型配置，下次直接从这里起；用户在模型设置里自己选过的上下文不改；只是“同时 2 个请求”放不下（单个放得下）时交给上游的“一次一个请求”处理，不降上下文。
  RTX 3060 12 GB 实测：128K ❌，96K ❌（放完上下文只剩 216 MiB，专家缓冲区要 1256 MiB），**64K ✅（约 29.7 tok/s）**，32K ✅（约 36 tok/s）。连续三次加载：第 1 次 128K → 自动 64K 并记住，第 2、3 次直接 64K。
- **卸载必须在飞牛网页里做**（`appcenter-cli uninstall` 会拒绝）；`appcenter-cli install-fpk` 对已安装的同名应用会直接跳过，**升级也要在网页里做**。所以“升级路径”和“卸载向导”**没有实测**。
- **设置向导显示的不是当前值**：飞牛的设置页只显示向导里写的默认值。所以设置里每一项默认都是“保持不变”或留空，只改动过的项（`tests/test_settings.sh`）。之前没有这一条时，在设置里加授权目录顺手保存，就把已开启的 API Key 删掉了。
- **安装失败 `10234 … acl_get_file failed`**：飞牛安装时以 root 遍历应用目录，悬空 / 绝对 / 指到应用目录外的符号链接会让它失败。`build.sh` 在打包前检查这三类链接，有就直接报错。
- 第一次 `appcenter-cli start` 返回过一次 `Failed to launch app. error code 10500`，但应用中心日志里这次启动是 `success`，应用也确实起来了，之后的 start / stop 都正常；原因没查清。
- **不在线更新程序**：引擎、Control、DeepSeek 引擎都随 fpk 走（`launch.sh` 设 `STRATA_FPK_NO_UPDATES=1`，`patches/0002-no-online-updates.patch`）。设置里没有“更新引擎 / 更新 Strata”，“检查更新”返回“请安装更新的 fpk”，更新操作会被拒绝。**模型、读图文件、DFlash2 草稿模型照常下载**（它们是数据，不是程序）。从本地文件安装引擎（离线、手动）仍然可以。实测：关掉后装模型、加载、推理都正常。
- 宿主第一次启动会把 `engine-bundle` 里的引擎复制到应用数据的 `components/`，之后会删掉安装目录里的那份（日志有说明），所以占用的是应用数据里的 1.2 GB。
- **升级时引擎版本号没变、内容变了**（比如 gfx906 组件加进了 `strata-dsv41`）：上游宿主看到同版本已装就保留旧的。`launch.sh` 在启动时比较包里和已装的同名组件的清单（`engine-component.json`），不一样就删掉已装的那份，宿主再按新包装（日志：`bundled engine ... differs from the installed copy`）。别的版本、用户自己装的引擎不动；终端命令 `bin/strata` 不触发。cob.11 → cob.12 实测：旧组件被换掉，`strata-dsv41` 到位。
- **图片要在模型准备时开启**：模型当初没开图片就装了的话，之后加载时开图片不会自动补文件（服务端会报 “started without the vision encoder”）。在界面里带图片重新准备一次这个模型即可，只补下读图文件（约 1 GB），不会重下模型本体。
- **Qwen3.8-Flash-Next IQ3_XXS**（2026-11-15，RTX 3060 12 GB）：gfx906 版下载进共享模型库后，NVIDIA 版“安装”只用 31 秒（不下载）；128K 上下文加载 236 秒（专家在内存里，显存只放一部分），同时 2 个请求。和 MI50 上同样的四项测试：

  | 测试 | RTX 3060 | MI50（对照，见 gfx906 一节） |
  |---|---|---|
  | 写 `is_prime` | 8.1 秒，正确，约 35 tok/s | 28.8 秒（加载后第一个请求），约 45 tok/s |
  | 鸡兔同笼 | 4.5 秒，鸡 23、兔 12，正确 | 5.3 秒，正确 |
  | 长文（上限 2000 token） | 50 秒写满 2000 token 的正文，平均约 **40 tok/s** | 上限 800 时全用在“思考”上 |
  | 4237 token 的长提示词 | 6.1 秒，读入约 **837 tok/s** | 16.7 秒，约 436 tok/s |

  3060 的生成速度和 MI50 差不多（都在 35–45 tok/s），读长提示词快一倍左右。
- **DeepSeek V4.1 能跑，但在机械硬盘池上很慢**。2026-11-15 实测：ISTA-DAS-Coder（190.7 GB，最小的一套），hf-mirror.com 下载加两轮校验 44 分钟，放在共享模型库（8 块 12 TB 机械硬盘的 RAIDZ3，2 块 1 TB NVMe 做 L2ARC 读缓存）；RTX 3060 上 60 秒加载完；写 `is_prime` 两次都正确，第一次 121 秒 / 245 token（约 **2.3 tok/s**），第二次 66 秒 / 204 token（约 **3.2 tok/s**）。上游在 RTX 3060 + NVMe SSD 上是 9–11 tok/s：差在专家要从机械硬盘读。加载期间 NAS 内存用到 97 / 125 GB（可用只剩 27 GB），会挤到别的服务；想认真用 DeepSeek，把模型放到单独的 NVMe 上，用完记得卸载。
- 防火墙服务文件（`.sc`）里写的是默认端口 47831；向导里改了端口又开着防火墙的话，要自己放行。
- **没有实测**：向导在飞牛网页里的渲染、飞牛桌面图标（`"port": "${wizard_port}"` 的写法照搬了 1Panel / MoonTVPlus）、Cloudflare 隧道（见下面“补测”）。
- 直连端口是明文 HTTP，只在可信局域网里用。

## 补测：客户端和其他功能（2026-11-16，同一台 NAS）

| 功能 | 结果 |
|---|---|
| **Codex 0.167.0** | ✅ 配置 `wire_api = "responses"`、`base_url = "http://<NAS>:47832/v1"`、模型 `coder-iq1_m`（gfx906 版）。任务“建 `sum.py` 打印 17+25 并运行”：40 秒，文件建好，运行输出 42。Codex 提示找不到这个模型的元数据（只是提示，不影响）。 |
| **OpenCode 1.19.5** | ✅ 用 `@ai-sdk/openai-compatible` 接 `/v1`。同样的任务 63 秒完成，输出 42；“Say hi.” 50 秒。第一次运行 600 秒没有任何输出就超时了，很可能是 OpenCode 第一次下载 SDK（没确认）。 |
| **Claude Code 2.1** | ✅ 见上面“实测结果”。 |
| **两个应用同时加载模型** | ❌→已修：两边同时点“加载”时，两个宿主都从 18500 开始找空闲的引擎端口、探到同一个，后起的引擎报 `OSError: [Errno 98] Address already in use`。`patches/0004-engine-port-base.patch` 让两个应用各用一段（CUDA 18500 起，gfx906 18600 起，`launch.sh` 设 `STRATA_FPK_ENGINE_PORT_BASE`）。修好后（cob.12 / cob.11）两边同一时刻点加载：CUDA 的 IQ3_XXS 61 秒、gfx906 的 Coder IQ1_M 109 秒都加载成功，端口 18500 / 18600；同时提问都答对（3.8 秒 / 2.9 秒）。两个都加载着时 NAS 内存可用只剩 6–14 GB（共 125 GB），**两个大模型同时加载要先看内存**，用完卸载。 |
| **局域网共享**（网页“API 服务 → 局域网共享”） | ✅ CUDA 版：打开后监听宿主端口 + 1（这次是 18792），局域网不带 Key 401、带 Key 200，网页路径 404；关闭后端口关掉。gfx906 版的共享端口跟着它自己的宿主端口走。它绕过本包的认证代理，只认 Strata 的 API Key。 |
| **自动调优**（网页里用户自己跑） | Coder IQ1_M：调完了，但没有生成可用的预设；它的基准：生成 27.9 tok/s、读入 37 tok/s（24 token 输入 / 200 输出，贪心，不思考）。DeepSeek 2.00bpw：两次都失败，“The operation was aborted due to timeout”（机械硬盘池太慢，见上面 DeepSeek 一条）。 |
| **DFlash2 草稿模型**（Qwen3.8-Flash-Next） | ❌→已修：选 DFlash2 加载时退回 MTP，说明是 “There is no internet connection, so the DFlash2 drafter can't be downloaded now.”。原因：12 GB 的 3060 用不上调优版（上游只给“专家全在显存里”的卡），走的是原版 drafter，而它的下载地址写死了 `huggingface.co`，不认 `HF_ENDPOINT`；NAS 连不上 huggingface.co（5 秒无响应），hf-mirror.com 可以。`patches/control/0002-dflash2-hf-endpoint.patch` 让它按 `HF_ENDPOINT`（向导里的模型下载源）下载。修好后（cob.12）：从 hf-mirror.com 下载 1.2 GB 约 24 秒，打包 12 秒，连同加载共 121 秒。**RTX 3060 上 DFlash2 比 MTP 快**（上游把这张卡标为 “slower”，实测相反）：写 `is_prime` 4.2–6.4 秒（MTP 8.1 秒），引擎解码 58–67 tok/s；鸡兔同笼 3.6 秒（MTP 4.5 秒）；长文 1865 token 40 秒，平均约 46 tok/s（MTP 约 40 tok/s）。代价是只能一次一个请求（MTP 可以同时 2 个）。 |
| **gfx906 上的 DFlash2**（2026-11-16，MI50，IQ3_XXS） | ✅ 能用，但**不比 MTP 快**：加载 85 秒（drafter 直接用共享模型库 `dflash2/` 里 CUDA 版下过的那份，没有重新下载，占 591 MiB 显存）；同样四个提示，DFlash2 / MTP：写 `is_prime` 44 / 45 tok/s，再问一次 51 / 52，鸡兔同笼 48 / 42（都答对），长文 37.5（2000 token）/ 44.3（1123 token）。DFlash2 只能一次一个请求，MTP 可以同时 2 个，**MI50 上保持默认的 MTP 就好**。 |
| **聊天页的 MCP 工具** | ✅ 不需要 harness：模型设置里的“MCP 服务器”由引擎旁的 Python 服务（`serve/server.py`）启动和调用，聊天页打开工具开关（请求带 `"strata_mcp": true`）就能用。用一个自写的最小 stdio MCP 服务器（两个工具：`secret_word`、`add`）接到 CUDA 版的 IQ3_XXS 上：问“今天的密语是什么，用工具查”，模型调用 `fpktest__secret_word`，照实回答 `MAPLE-7731`，3.8 秒；“用 add 算 98765432 + 12345679”，带参数调用，回答 `111111111`，3.5 秒。MCP 服务器的日志确认两次调用都执行了。MCP 程序以应用用户运行，要放在应用读得到的地方。 |
| **编程助手（agent 模式）、联网搜索、浏览器工具** | ⚪ 用不了：网页提示 “The coding assistant isn't installed…”。这个组件（harness）不在上游的更新源里（只有 app、control、drafters、dsv41、engine），上游文档说它的仓库还没发布。不是本包的问题。聊天页的 MCP 工具不受影响（上一行）。 |
| **终端里完整的 `strata` 命令**（CUDA 版，`sudo /var/apps/strata/target/bin/strata …`） | ✅ `--version`、`doctor`、`components engines`、`models list`、`drafting plan`、`launch --plan` 都正常（认出 5 个已装模型、两个引擎，不需要下载）。`launch --family qwen --model iq3_xxs --vision off --access local --port 18580 --yes --no-tui`：76 秒起好服务，没有下载；之后 `launch --status`、`status`、`monitor --once`、`logs` 都看得到它，`connect opencode / claude-code / codex --check` 三个都 PASS（一个提示 + 一次工具调用），`bench run --suite serving-smoke` 通过（46–49 tok/s），`launch --stop` 停掉、显存清零。**注意：终端和应用共用同一份模型配置**：用 `strata launch` 换了选项（比如 `--vision off`）启动，会把应用里这个模型的设置一起改掉（这次读图设置和 `--vram-reserve-mib 1536` 被去掉了，已用自动备份的 `.bak` 恢复）。终端启动尽量和网页里的设置一致，或者先停用网页里的这个模型、用完核对一下。 |
| **Cloudflare 隧道、Tailscale** | ⚪ 故意没测：Cloudflare 会把服务公开到互联网，还要在运行时下载 `cloudflared`；这台 NAS 用不上这两个。要用的话自己在网页里开，并且一定要设 API Key。 |
| MI60 / Radeon VII、飞牛网页里的升级和卸载 | ⚪ 没有硬件 / 只能在网页里点，没测。 |

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
| `gfx906/patches/0002-dsv41-on-gfx906.patch` | 引擎源码 | 让 DeepSeek 引擎 `strata-dsv41` 能编给 gfx906，见下面“gfx906 上的 DeepSeek V4.1”。只动 DeepSeek 自己的源码和 CMake 段，主引擎 `strata` 编出来和以前逐字节相同（sha256 核对过） |
| `patches/control/0001-gfx906-opt-in-and-backend.patch` | Control 的 `setup.py` | ① 加开关 `STRATA_EXPERIMENTAL_GFX906=1`（照上游 gfx1103 / gfx1150 的写法），把 gfx906 加进 AMD 支持名单；② 安装时没指定后端就用 `STRATA_ENGINE_BACKEND`，否则同时有 NVIDIA 卡的机器会默认装成 CUDA |
| `patches/0001-gpu-vendor.patch` | 宿主 | 只保留本变体厂商的卡（两个变体共用） |
| `patches/0002-no-online-updates.patch` | 宿主 | 关掉引擎 / Control 的在线更新（两个变体共用） |
| `patches/0003-q36-context-fallback.patch` | 宿主 | Qwen3.6 显存不够时自动降上下文并记住（两个变体共用；gfx906 不跑 Qwen3.6，不会触发） |
| `patches/0004-engine-port-base.patch` | 宿主 | 引擎端口从 `STRATA_FPK_ENGINE_PORT_BASE` 起找（CUDA 18500，gfx906 18600），两个应用同时加载不再抢同一个端口（两个变体共用） |
| `patches/control/0002-dflash2-hf-endpoint.patch` | Control | DFlash2 草稿模型按 `HF_ENDPOINT` 下载（默认 hf-mirror.com），不再写死 huggingface.co（两个变体共用） |
| `patches/control/0003-gpu-vendor.patch` | Control | Control 的显卡列表也只留本变体厂商的卡（和宿主的 0001 一样），网页上不再把另一家的卡排在第一（两个变体共用） |

`launch.sh` 按 `bin/variant.env`（构建时写入）设置：gfx906 版 `STRATA_FPK_GPU_VENDOR=amd`、`STRATA_ENGINE_BACKEND=hip`、`STRATA_EXPERIMENTAL_GFX906=1`，不链接任何宿主机的库。

**能跑哪些模型**：这个引擎只有 `qwen4exp` 一个系列（`strata --families`），也就是 **Qwen3.8-Flash-Next 及其 Coder / Swift / Unsloth / Gyro 等量化**。**Qwen3.6-35B-A3B 不在 gfx906 构建里**（上游文档也这么说），目录里虽然列着，但装了也跑不起来。最小可用的是 Coder IQ1_M（58.4 GB）。**DeepSeek V4.1 由本包自己移植**（上游的 CMake 明确写着 `STRATA_BUILD_DSV41 AND NOT STRATA_HIP_GFX906`，不给 gfx906 编），见下面“gfx906 上的 DeepSeek V4.1”。

### gfx906 实测（2026-11-15，同一台 NAS，Instinct MI50 32 GB，和 RTX 3060 同机）

- `appcenter-cli install-fpk` 安装 `strata-gfx906`（端口 47832、共享文件夹 `Strata-gfx906`、应用用户在 video / render 组），和 CUDA 版的 `strata` **同时运行**互不影响（内部端口被占用时自动换一个）。
- 硬件识别为 MI50；Control 认为 MI50 可用、引擎 `0.1.59 (linux-x86_64-hip)` 可用；装模型时后端自动是 `hip`。
- 下载 **Qwen3.8-Flash-Next Coder IQ1_M（58.4 GB）**，hf-mirror.com，约 15 分钟（含校验和 MTP 草稿层）。
- 默认 **128K 上下文**直接加载成功（MI50 显存用到 31.3 / 32 GB，Strata 自动设为同时 2 个请求）。
- 推理：写 `is_prime` 函数（162 token，7.4 秒，代码正确），`17*23` 回答 391；**解码平均约 60 tokens/s，峰值约 78**。上游的社区报告是 2 张 MI50 16 GB 跑同一个模型约 50 tok/s。
- 停止约 6 秒，MI50 显存从 31352 MiB 回到 10 MiB。
- **图片**（上游文档写着 gfx906 “没做过”）：Coder 带图片重新准备后（补下 `mmproj-Qwen3.8-Flash-Next-BF16.gguf`），32 GB 显存下 Strata 选了 **GPU 读图器 `strata-vision-hip`**，测试图回答 “A red circle and a blue square are shown above the number 742.”，6 秒。
- API Key 和 Claude Code 的测试就是在这个版本上做的（见 CUDA 版实测）。
- **Qwen3.8-Flash-Next IQ3_XXS（上游首推的 ISTA-DASLab 版本，75.8 GB）**，2026-11-15 实测：hf-mirror.com 下载约 5 分钟 + 校验 3 分钟，进共享模型库；加载 276 秒（第一次从机械硬盘读 79 GB），128K 上下文、同时 2 个请求。

  | 测试 | 用时 | 结果 | 生成速度 |
  |---|---|---|---|
  | 写 `is_prime`（加载后第一个请求） | 28.8 秒 / 244 token | 正确 | 约 45 tok/s |
  | 鸡兔同笼（35 头 94 脚） | 5.3 秒 / 126 token | 鸡 23、兔 12，正确 | 约 47 tok/s |
  | 800 token 长输出 | 28.4 秒 | 全用在“思考”上，正文为空（模型习惯；放大输出上限即可） | 峰值 58，平均约 40 tok/s |
  | 4237 token 的长提示词 | 16.7 秒 | 正确回答 “OK” | 读入约 **436 tok/s** |

  和 Coder IQ1_M 比：生成慢一些（平均约 40 对 60 tok/s），但量化精度更高，适合日常聊天和推理；Coder 适合写代码。
- **没有实测**：MI60 和 Radeon VII（同一指令集，没跑过）、多张 gfx906 卡。DFlash2 草稿模型能用，但不比 MTP 快（见“补测”）。

### gfx906 上的 DeepSeek V4.1（2026-11-16，本包移植，上游没有）

**怎么做的**：上游给 AMD 写的 DeepSeek 引擎只编给 RDNA 系列（wave32，如 R9700）。MI50 是 wave64，主引擎能跑靠的是 gfx906 兼容层：把一个 64 线程的 wave 当成两个 32 线程的 warp，CUDA 的 shuffle / ballot 都按 32 线程模拟。`gfx906/patches/0002-dsv41-on-gfx906.patch` 让 DeepSeek 引擎也走这条路：

- `src/dsv41` 里所有 `defined(STRATA_USE_HIP)` 改成 `(defined(STRATA_USE_HIP) || defined(STRATA_HIP_GFX906))`：走上游给 AMD 写的那套分支（FP8 / BF16 用普通算术转换、不用 NVIDIA 的 `globaltimer` 汇编和 `mma.sync`、`nvcuda::wmma` 等）。WMMA 矩阵核心的代码都有 gfx11 / gfx12 的架构条件，在 gfx906 上自动退回普通实现。
- CMake 允许 `STRATA_BUILD_DSV41` 和 `STRATA_HIP_GFX906` 一起开，DeepSeek 的目标和对拍测试按 HIP 编译，强制引入上游的 `include/strata/dsv41/hip_extra.h`（另补 `cublasSgemm`、`cudaDevAttrIntegrated` 两个映射，并按兼容层用 hipBLAS v2 API）。
- `src/dsv41/ds4_gfx906_stubs.cpp`：RDNA3 的 WMMA 稠密矩阵乘在 gfx906 上回答“没有”，调用方照常用 hipBLAS（和 `wmma_gemm.cu` 在非 gfx11 构建里的写法一样）。
- `gfx906/build-engine.sh` 在单独的构建目录里编 `strata-dsv41`，放进同一个引擎组件（共用 ROCm 库），`BUILD.json` 标 `"dsv41": true`。它没有上游签名，所以 `launch.sh` 用 Control 的 `STRATA_DSV41_EXE`（“自己编的引擎”）指给它；组件里的 `BUILD.json` 写着 `archs: ["gfx906"]`，Control 据此认为 MI50 能跑 DeepSeek。

**正确性**（MI50 上跑上游自己的对拍测试，和 CPU / ggml 参考实现比）：

| 测试 | 内容 | 结果 |
|---|---|---|
| `ds4_iq_test` | i-quant 专家（IQ1_M、IQ2_XS/S、IQ3_XXS/S、IQ4_XS）的单 token、批量、CPU 通道 | 全部在上游的容差内，`ALL OK` |
| `ds4_tq_test_portable` | trellis 专家（TQK4X/5X/4T/5T） | `ALL OK` |
| `ds4_dq_test`（`tests/dsv41/run_dq_test.sh`） | 16 种稠密权重类型 × 新旧内核 × rows / gguf / gemm / mv 路径 | 161 项结果全部 `fail=0`，没有崩溃、没有设备错误 |
| `tools/dsv41/smoke.py` | 2.00bpw 整个模型出 16 个字 | “The capital of France is Paris.”（第一次从机械硬盘读，334 秒） |

**在应用里实测**（cob.12，模型在共享模型库，机械硬盘 RAIDZ3）：

| 模型 | 安装（文件已有） | 加载 | 结果 |
|---|---|---|---|
| ISTA-DAS 2.00 bpw | 296 秒（含 Strata 自己的出字测试） | 272 秒，MI50 显存用满（2864 / 15360 个专家在卡上，其余 108 GB 由 CPU 从模型文件里读） | **约 0.4–0.5 tok/s**：内存只放得下 30 GB 最常用的专家，其余每个字都要从机械硬盘现读（CPU 只用了约 11%，在等硬盘）。非流式请求 5 分钟后报 `fetch failed`（见下） |
| **ISTA-DAS-Coder** | 60 秒 | **55 秒** | 写 `is_prime` 两次都正确：第一次 34 秒（第一个字 6 秒，之后 **4.9 tok/s**），第二次 15 秒（**8.4 tok/s**）；鸡兔同笼“鸡 23，兔 12”正确，42 秒。引擎统计解码平均 2.6 tok/s、读提示词 7.5 tok/s |

同一个 Coder 包在 RTX 3060（12 GB）上是 2.3–3.2 tok/s（见“已知问题”里 DeepSeek 一条）：MI50 显存大，放在卡上的专家多，所以更快。**想用 DeepSeek 选 Coder**；2.00 / 2.25 bpw 要把模型放到 NVMe 上才有可用的速度。

**Coder 的专家全在显存和内存里时**（2026-11-16 复测）：加载时 NAS 有 80 GB 可用内存，引擎自动把显存放不下的 41.2 GB 专家全部复制进内存（`--mmap-experts auto`，18.7 秒），显存 25.2 GB，加载 49 秒。上一次加载时只有约 30 GB 空闲，它只拿了 13.6 GB 内存放专家，其余从机械硬盘现读。ZFS 的读缓存（ARC）会自己让出内存（32 GB 缩到 4 GB），不用改系统设置。

| 测试（应用里，流式） | 结果 |
|---|---|
| 写 `is_prime` | 9.9 tok/s；再问一次 5.5 tok/s，都正确 |
| 鸡兔同笼 | 4.9 tok/s，正确 |
| LRU 缓存类（600 token） / 300 词说明（400 token） | 3.2 / 2.6 tok/s |
| 读提示词 | 30–43 tok/s（上一次 4–7） |

**慢在哪**：直接运行引擎（`strata-dsv41 --n 256`，提示词 17 token）加 `DS4_PROF=1`，三次 4.2–5.0 tok/s，每个 token 约 200 ms：

| 阶段（GPU 上每个 token） | 时间 |
|---|---|
| attention（含等 Engram） | 144–154 ms |
| 等 CPU 算专家 | 21–44 ms |
| routing + 共享专家 | 11–13 ms |
| 专家 gate/up、down 等 | 约 10 ms |

- **Engram 表在机械硬盘上**：DeepSeek 的 n-gram 表是一个 110 GB 的文件（`deepseek-v4.1-flash-shared/DeepSeek-V4.1-Flash-Engram-IQ4_NL.gguf`，Coder 和 2.00 bpw 共用），内存放不下。每个 token 要随机读约 47 行，在 RAIDZ3 上 110–150 ms，其中约 100 ms 和计算重叠不上，只能等。Engram 用在第 1 层和第 14 层，等待落在这两层的 attention 阶段里，所以 attention 显得很慢（这一点是看代码推出来的，没有单独测）。短回答、重复的提问更快（9.9 tok/s），是因为那些行已经在缓存里了。
- **专家计算不是瓶颈**：CPU 算一个专家 0.4 ms，每个 token 在 CPU 上的专家约 20%。
- **上游的单卡解码加速帮不上**：它的作用是把 CPU 那部分专家经 PCIe 搬到 GPU 上算。在 MI50 上用环境变量强制打开（`DS4_STREAM=1 DS4_STREAM_WIN=1 DS4_LAND=1 DS4_STREAM_ZC=1 DS4_IQ1S_ROWS=1`），引擎能跑、不出错，但搬一个专家要 1.7–2.2 ms，比 CPU 自己算（0.4 ms）慢得多；引擎自己的对比是慢 5.9% 和 74%，然后自动不再搬。结果 4.43 tok/s，比不开（4.68）还慢一点。原因之一：**这台 NAS 的 MI50 插在走芯片组的 PCIe 4.0 x4 上**（根端口 `00:1b.0`），带宽只有 x16 的四分之一。
- **逐个 GPU 函数的耗时**（`rocprofv3 --kernel-trace`，64 个 token，约 10 万次 GPU 函数调用）：GPU 占用率 98%，但每个 token 有 92 ms 是 `wait_seq_kernel` 在 GPU 上原地空转，等 CPU 算完它那份专家（这次运行时 NAS 可用内存只剩约 20 GB，部分专家又从机械硬盘读，所以等得比平时 21–44 ms 长）。真正在计算的 GPU 函数每个 token 约 44 ms，其中矩阵运算约 25 ms：

  | GPU 函数 | 每个 token | 说明 |
  |---|---|---|
  | `mv_kernel<13>`（Q5_K 稠密矩阵乘） | 16.6 ms | attention 的 `wq_b` / `wo_a` / `wo_b` 等投影；5.3 GB 权重约合 300 GB/s，MI50 实际能到 700–800 GB/s |
  | 专家 gate/up/down（IQ 格式） | 约 6 ms | |
  | 其余几十个小函数 | 约 20 ms | 归一化、路由、稀疏注意力等 |

  点积已经用的是 gfx906 的硬件指令（`v_dot4_i32_i8`，在 `include/strata/platform/hip_compat/strata_hip.h`）。MI50 没有矩阵核心（MFMA 从 MI100 才有），能优化的是用点积指令重写这些函数：Q5_K 矩阵乘有望提速到 2–2.5 倍，每个 token 省约 10 ms，整体只快 7–10%，本包没有做。等 CPU 和等 Engram 才是大头。
- **和 Qwen3.8 差这么多，主要是模型结构**：DeepSeek 多一张 110 GB 的 Engram 表（每个 token 都要查），注意力更宽更复杂（64 头 × 512 维，加压缩缓存和稀疏索引），专家一共 66 GB，比 MI50 的显存大一倍。上游在自己推荐的环境（RTX 3060 + NVMe）里，DeepSeek 2.00 bpw 也只有 6–9 tok/s，而同一张卡跑 Qwen3.8 是 35–40 tok/s。**MI50 上日常请用 Qwen3.8**（Coder IQ1_M 约 60 tok/s，IQ3_XXS 约 40–47 tok/s）。
- **能提速的办法**：把 110 GB 的 Engram 文件放到固态上（估计每个 token 能省约 100 ms，接近翻倍；没测）；把 MI50 换到 CPU 直连的 x16 槽（加载、读提示词更快，搬专家也可能变得划算；没测）；为 gfx906 优化 attention 内核（要改引擎，收益不确定）。

**限制**：

- 上游有一项单卡解码加速只给 NVIDIA（日志：`the one-GPU decode path ... off (not NVIDIA + one GPU)`），在这台 NAS 上强制打开反而慢一点（见上面“慢在哪”）；DSpark 草稿在专家远多于显存时自己不加载（CUDA 版也一样）。
- **非流式请求超过 5 分钟会失败**（`{"error":{"message":"fetch failed"}}`）：宿主转发 `/v1` 时等响应头最多 5 分钟，引擎其实还在出字。慢模型请用流式（`"stream": true`，Claude Code、Codex、OpenCode 和网页聊天都是流式）。这是上游宿主的行为，CUDA 版一样。
- 没有测（DeepSeek 在这台 NAS 上太慢，不再测）：DeepSeek 的读图、多张 gfx906 卡、MI60 / Radeon VII、长上下文。

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
packaging/fnos/tests/test_proxy.sh             # 认证代理（用户名密码、/v1 的 API Key（Strata 自己的）、转发、流式、WebSocket、HTTPS），36 项
packaging/fnos/tests/test_settings.sh          # 安装 / 设置向导的处理（“保持不变”），8 项
packaging/fnos/tests/test_context_fallback.sh  # Qwen3.6 上下文自动降档的判断，11 项
packaging/fnos/tests/test_models_dir.sh        # 模型目录的选择（授权目录），8 项
packaging/fnos/tests/test_port_and_drafter.sh  # 两个应用的引擎端口段、DFlash2 按 HF_ENDPOINT 下载，7 项
packaging/fnos/tests/test_launch_engine.sh     # 升级时替换内容变了的同版本引擎组件、gfx906 的 STRATA_DSV41_EXE，7 项
packaging/fnos/tests/test_launch_lifecycle.sh  # 两个变体的宿主端口、宿主退出自动重启、停止和启动失败时不留代理 / 宿主，11 项
packaging/fnos/tests/test_gpu_vendor_control.sh # Control 的显卡列表只留本变体厂商的卡，5 项
# 都不需要 GPU / 飞牛
```

## 目录

```
build.sh                  构建脚本（VARIANT=cuda|gfx906）
tools/make_icon.py        两个变体的应用图标（厂商色 + 厂商名）
gfx906/                   gfx906 引擎的构建：build-engine-docker.sh（宿主侧）、build-engine.sh（容器里）、patches/（引擎源码补丁）
patches/                  宿主补丁（0001-gpu-vendor、0002-no-online-updates、0003-q36-context-fallback、0004-engine-port-base）；patches/control/ 是 Control 的补丁（0001-gfx906-opt-in-and-backend、0002-dflash2-hf-endpoint、0003-gpu-vendor）
fnos/                     fpk 骨架（@APPNAME@ 等占位符由 build.sh 替换）
├── manifest, config/     应用清单；privilege（应用用户 strata + video/render 组）、resource（共享文件夹、防火墙）
├── cmd/                  生命周期脚本（start/stop/status、安装/配置/升级/卸载回调）
├── wizard/               安装 / 设置 / 卸载向导
└── app/                  → /var/apps/strata/target
    ├── bin/launch.sh     环境（按 bin/variant.env 区分变体）、宿主机 NVIDIA 驱动库链接、宿主崩溃自动重启
    ├── bin/proxy.mjs     认证反向代理（HTTP / SSE / WebSocket；HTTPS 同端口）
    ├── bin/tls-cert.mjs  自签名证书（纯 Node）
    ├── bin/strata        终端命令入口（sudo 运行，切到应用用户和应用的环境）
    ├── bin/set-password.mjs   网页密码（scrypt）
    └── ui/               飞牛桌面入口（直接打开网页端口）
tests/test_proxy.sh       认证代理的本地测试
build/                    构建缓存（不入库）；成品在仓库根目录的 dist/（不入库）
```
