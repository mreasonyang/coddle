# Coddle

[简体中文](README.md) · [English](README.en.md)

**原生 macOS 菜单栏工具：精细控制电池充电上限，并在屏幕熄灭或合盖时保持长任务持续运行。**

日常插电办公时自定义充电上限，外出前一键临时充满；挂机下载、代码编译、模型渲染或运行自动化任务时，无需让屏幕常亮耗电。充电作息严格在本地学习，尊重隐私与硬件边界。

[GitHub 源码](https://github.com/MrEasonYang/coddle) · [官网](https://coddle.kyun.si/) · [下载最新 macOS 预览版 (Universal)](https://github.com/MrEasonYang/coddle/releases/latest) · [安装说明](https://coddle.kyun.si/install.html)

> [!NOTE]
> **0.2.0 早期预览版**，支持 Apple Silicon 与 Intel 架构（macOS 13.0+ 部署目标）。采用临时签名（ad-hoc），**未进行 Developer ID 签名与 Apple 公证**。系统原生充电上限依赖 Apple Silicon 及较新 macOS，各项能力在运行时由硬件与系统实际检测决定；首次启动请参考[安装说明](https://coddle.kyun.si/install.html)。

<img src="site/public/assets/coddle-panel.png" width="340" alt="Coddle 界面：电池状态、功率流向、手动限充、智能充电、电源模式与防止休眠">

*应用实际运行截图（展示示例数据）；内置中文等多种语言。*

## 使用场景

### 1. 日常插电办公：控制充电上限

1. 点击菜单栏 Coddle 图标，在「手动限充」滑块中选择所需上限（例如 **80%**）。
2. 面板即时显示当前受控状态与实时功率读数。若硬件支持，达到上限后可观察到旁路供电（Bypassed）与较低的电池功率读数；具体表现取决于设备机型与当前系统负载。调低上限不会主动反向放电，电量将随日常使用自然回落。在系统需要校准电池等特殊情况下，macOS 可能会暂时覆盖限充设置。
3. 若希望自动化作息，可启用「智能充电」并在设置中配置保持电量与提前补电时间。系统在本地积累足够的拔电习惯数据后会自动推算补电时间表（数据不足时显示「学习中」）。智能充电基于本机历史统计推算，无法绝对保证出门前必定充满；手动调整限充滑块会随时切回手动限充。

### 2. 准备出门移动：一键临时充满

当设备支持、已接通电源、当前尚未满电且启用了低于 100% 的限充策略时：
- 点击面板上的「**立即充满电**」按钮，应用将临时放宽充电上限至 100%，不改动原本的日常限充偏好。
- 在充电期间可随时点击动态的「**恢复 N% 上限**」提早结束；若拔掉电源线或电池已完全充至 100%，系统亦会自动恢复为原设定的限充规则。

### 3. 长任务后台挂机：黑屏或合盖继续运行

1. 打开面板底部的「**防止休眠**」开关，保持子选项「屏幕常亮」处于未勾选状态。Mac 将阻止系统自动进入睡眠，同时允许显示器按照系统节能设定自然熄灭，兼顾节能与降温。
2. 展开控制菜单，可按需勾选「屏幕常亮」或「合盖后继续运行」（两者可独立组合）。其中合盖运行需要安装可选的高权限辅助组件；合盖运行不承诺维持满频性能，也不保证机身不发热。
3. 挂机任务完成后，随手关闭「防止休眠」主开关。关闭后子选项锁定不可操作，但会保留屏幕常亮与合盖偏好供下次沿用。关闭操作是向系统异步请求停止 Coddle 管理的休眠防止效果；若停止未完全确认，面板会保留状态提示并支持重试。Coddle 不会自动判断长任务何时结束；只要主开关保持开启，重新打开应用时就会尝试恢复保活。

## 安装与快速上手

1. **下载应用**：从 [GitHub Releases 下载最新 universal ZIP](https://github.com/MrEasonYang/coddle/releases/latest) 并解压，将 `Coddle.app` 移入系统的「应用程序」（`/Applications`）目录。
2. **首次启动**：由于当前预览版未经 Apple 公证，直接打开可能会受到 macOS 安全拦截，详细操作请查阅[安装说明](https://coddle.kyun.si/install.html)。
3. **设置向导**：初次启动会展示配置向导，协助你选择充电模式、长任务运行方案以及按需授权。向导完成后即可从菜单栏日常使用。

- **完整性校验**：每个 [GitHub Release](https://github.com/MrEasonYang/coddle/releases) 附带 `SHA256SUMS.txt`，可对照下载 ZIP 的 SHA-256。应用内更新还会验证 Sparkle 的 Ed25519 签名。
- **软件更新**：0.2.0 起，在「设置 → 通用 → 软件更新」中点击「检查更新…」，或开启「自动检查更新」。还可主动开启「自动下载并安装更新」，安装通常在退出 Coddle 时完成。0.1.0 没有更新器，需先手动安装一次 0.2.0 或更高版本。
- **源码与旧版下载**：当前源码位于 [GitHub 仓库](https://github.com/MrEasonYang/coddle)，每个 Release 也提供源码归档。官网原有的 0.1.0 应用与源码下载属于旧版快照，不随 GitHub Release 自动更新。

## 核心功能

| 功能 | 说明 | 权限与要求 |
|---|---|---|
| **电池与功率状态** | 实时显示电池电量、健康度、循环次数、温度，以及电源适配器、主板系统与电池之间的动态功率流动与读数状态。 | 普通用户权限，开箱可用 |
| **原生充电限制** | 调用系统原生服务管理硬件充电上限（80%–100%），支持临时充满与智能补电预测。 | 普通用户权限（无需特权 Helper，依赖支持的 Apple Silicon 与系统环境） |
| **熄屏防休眠** | 阻止 Mac 自动休眠的同时允许显示器正常关闭；状态允许时支持面板内一键「立即熄屏」。 | 普通用户权限（基于系统电源断言） |
| **合盖继续运行** | 即使合上 MacBook 屏幕，后台任务依然持续工作。基于 30 秒安全续约租约，正常退出时主动停止，异常中断时到期重置（恢复并非瞬间）。 | 需通过系统管理员授权安装可选特权辅助组件 |
| **离开与防捂包保护** | 离开常用网络且处于合盖、空闲或锁屏等无人使用状态时自动暂停保活，默认仅在电池供电时生效。 | 普通用户权限，依赖物理网络状态与闲置检测 |
| **系统能耗模式切换** | 快速切换设备支持的「自动」、「低电量」或「高功率」模式。 | 未安装 Helper 时每次明确切换需单次管理员授权；安装 Helper 后可免弹窗切换 |
| **多语言与外观** | 支持简体中文、繁体中文、英语、日语、韩语、西班牙语；提供「流体玻璃 (次世代)」与「经典原生」两套主题。 | 内置支持 |

## 使用需知与安全边界

- **机型与系统支持各异**：应用构建部署目标为 macOS 13.0，但系统原生 Charge Limit 依赖 Apple Silicon 及 macOS 26.4+ 运行时接口。Coddle 启动时会进行实时功能探测；对于本身不支持原生充电限制的机型或系统，安装辅助组件也无法强行开启。当前真机实测主要集中在较新 macOS 版本的 Apple Silicon 设备上；Intel 架构与 macOS 13 基线运行、物理合盖与外接屏组合、完整 VoiceOver 旁白支持仍在持续验证中，自动化测试不能替代这些物理验收。
- **按需启用最小权限**：充电控制、常规防休眠与电池功率监控完全运行在用户空间，**不需要**特权组件，也**不需要**辅助功能（Accessibility）或屏幕录制权限。仅「合盖继续运行」需要单次管理员授权安装 Helper 组件；安装 Helper 本身不会静默开启合盖保活。系统电源模式切换采用单一通道，优先通过 Helper 执行，若无 Helper 则可能每次切换触发管理员授权；执行失败后不会追加二次重试。
- **放入背包或手动休眠前请关闭防休眠**：虽然应用具备离开常用网络与无人值守时的离开保护机制，但网络及状态判定存在安全等待窗口，绝不能代替人工确认。在将 MacBook 放入背包或**手动让 Mac 休眠前**，请务必在面板中主动关闭「防止休眠」并确认状态已停止。Coddle 不调节显示器背光亮度。

## 维护与进阶指南

<details>
<summary><b>配置参考</b></summary>

- **配置文件位置**：
  ```text
  ~/Library/Application Support/Coddle/config.json
  ```
- **查看与生效**：在应用菜单中进入「设置 → 通用 → 高级」，点击「在 Finder 中显示配置」即可定位文件；手动修改保存后，点击「重新加载配置」即可应用改动。
- **默认参数**：默认关闭智能充电与防止休眠，手动限充默认目标为 80%；首次配置向导选择的方案会写入该文件。首次设置进度及未完成项记录在同目录的 `onboarding.json` 中。
- **容错处理**：所有配置字段与结构以 `platforms/macos/Coddle/Sources/Config.swift` 为准。若手动编辑出现格式错误，应用会保留原文件并弹出提示，不会静默覆盖损坏的配置。
</details>

<details>
<summary><b>特权辅助组件 (Helper)</b></summary>

- **系统位置与标识**：可选可执行文件位于 `/Library/PrivilegedHelperTools/com.coddle.helper`，LaunchDaemon 注册标识为 `com.coddle.helper`。
- **管理方式**：在「设置 → 防止休眠 → 系统组件」中点击「管理」，由用户主动选择安装或移除，操作均需通过系统管理员授权。卸载组件前会自动请求先终止合盖保活。
- **能力边界**：安装 Helper 仅用于在授权下执行合盖休眠禁用（`pmset -a disablesleep`）及免弹窗能耗模式切换。安装该组件本身不会自动开启合盖运行，亦无法使硬件不支持的机型获得原生限充能力。
</details>

<details>
<summary><b>开发、测试与本地构建</b></summary>

- **环境要求**：macOS 系统，包含 Swift、clang 与 macOS SDK 的 Apple 开发者工具链，以及 Python 3。首次构建会从 Sparkle 官方 GitHub Release 下载固定版本 2.10.0，并校验固定 SHA-256。图形与渲染测试必须在实际 GUI 桌面会话下运行。
- **源码目录**：
  - 完整代码仓库：`cd platforms/macos/Coddle`
  - 官网源码解压包（`Coddle-source-preview`）：`cd Coddle`
- **构建与测试**：
  - 完整仓库运行 `./test.sh` 会在退出时自动清理本次临时的 UI、回归与向导测试输出，保留 `Coddle.app`、`build/` 及编译缓存；
  - 官网解压源码包中的 `test.sh` 则直接将测试结果写入 `build/` 并保留；
  - 构建可直接执行 `./build.sh`（针对主机架构编译并 ad-hoc 签名），`open Coddle.app` 会直接读取当前登录用户的真实偏好设置。
- **独立输出与测试**：可通过环境变量指定输出路径，例如 `CODDLE_OUTPUT_DIR=/tmp/coddle-build ./build.sh`，随后将产物目录传递给测试脚本 `./test.sh /tmp/coddle-build/build`。
- **隔离 UI 布局与向导检查**：执行 `tests/ui/build.sh /tmp/coddle-ui render` 或 `tests/onboarding/build.sh /tmp/coddle-onboarding-ui` 检查界面布局与首次引导流程，临时输出位于指定目录，查看后请手动清理。界面文案调整须同步所有支持的多语言资源。
- **物理硬件写入验证**：硬件读写测试独立于常规构建流程，必须显式执行 `./build/coddle-hardware-smoke --write-and-restore` 并严格核对恢复状态，切勿混入普通快速开始步骤。
- **打包分发**：执行 `./package.sh /tmp/coddle-delivery` 生成包含通用双架构（Universal）二进制的应用包、发布 ZIP 以及对应的 SHA-256 校验文件并核对签名，但不运行完整测试、不执行安装亦不进行公证。
- **代码库规范自检**：从完整仓库根目录运行 `python3 tools/check_repository.py` 检查根目录是否仅保留两份 README 且本地相对链接有效（官网源码包不含 tools 或官网脚本）。
</details>

<details>
<summary><b>GitHub Actions 打包与应用更新发布</b></summary>

- **持续集成**：[CI 工作流](.github/workflows/ci.yml) 在 `main` 推送和 Pull Request 时执行构建、测试与双架构打包，产出带 SHA-256 的 Universal ZIP。CI artifact 用于构建检查；应用更新读取正式 GitHub Release。
- **发布前准备**：`Info.plist` 中的 `SUPublicEDKey` 必须与仓库 Actions secret `SPARKLE_PRIVATE_KEY` 配对。维护者应安全保存该发布密钥，不要写入仓库、构建产物或日志，也不要在每次发布时更换。缺少密钥或签名不匹配会阻止发布。
- **发布版本**：更新 `platforms/macos/Coddle/Info.plist` 的 `CFBundleShortVersionString`（例如 `0.2.1`）和严格递增的整数 `CFBundleVersion`（例如 `3`），提交至 `main`，再推送对应标签：
  ```bash
  git tag v0.2.1
  git push origin v0.2.1
  ```
  标签必须与应用版本完全一致，且版本号和构建号均高于当前已发布版本。
- **发布过程**：[Release 工作流](.github/workflows/release.yml) 在 macOS runner 上构建、测试并打包，使用 Sparkle 生成和验证签名更新源，然后上传 `Coddle-VERSION-universal.zip`、`appcast.xml`、`SHA256SUMS.txt`。先创建草稿并下载核对上传字节，全部通过后才发布为 Latest。上传失败的草稿需维护者检查并删除后再重试，不覆盖已发布版本。
- **更新来源**：应用固定读取 [GitHub 最新发布的 appcast](https://github.com/MrEasonYang/coddle/releases/latest/download/appcast.xml)，其中的 ZIP 地址固定到具体版本标签。该流程不使用 GitHub 的 prerelease 标记，以保证 Latest 地址可用；软件成熟度仍为早期预览。
- **签名与验证范围**：Sparkle 的更新签名验证发布来源和包完整性，不等同于 Developer ID 签名或 Apple 公证。当前包仍为 ad-hoc 签名。自动构建、签名与上传校验不能替代旧版本安装、下载、退出替换、重新启动的完整更新验收；CI 不执行用户设备上的合盖、充电写入或系统组件升级。

</details>

<details>
<summary><b>官网预览与发布说明</b></summary>

- **静态站点资源**：存放于 `site/public`。
- **本地开发预览**：在仓库根目录运行以下命令启动本地预览服务：
  ```bash
  python3 -m http.server 4186 --bind 0.0.0.0 --directory site/public
  ```
  本地访问地址为 `http://127.0.0.1:4186/`。
- **迁移状态**：仓库构建配置与官网校验已完成；Cloudflare GitHub App 的 Coddle 仓库授权、新项目创建和正式域名切换尚待完成。当前线上仍由旧 Direct Upload 项目 `coddle` 提供服务。以下为目标部署配置。
- **仓库自动部署**：官网通过 Cloudflare Workers and Pages GitHub App 连接 `mreasonyang/coddle`，生产分支为 `main`。Pages 项目 `coddle-site` 从仓库根目录执行 `bash site/scripts/cloudflare-build.sh`，发布目录为 `site/public`；Python 版本由 `.python-version` 固定。推送 `main` 后由 Cloudflare 自动构建和发布，无需配置 Cloudflare API Token。
- **本地校验与打包**：运行 `bash site/scripts/cloudflare-build.sh`，检查公开资源、下载文件校验值与 JavaScript 语法，并生成 `site/dist/coddle-site.zip` 和文件校验清单。GitHub 的 [官网校验工作流](.github/workflows/site.yml) 执行相同检查并保留提交绑定的产物；部署由 Cloudflare 原生集成完成。
- **域名与恢复**：`coddle.kyun.si` 绑定 `coddle-site`。旧 Direct Upload 项目 `coddle` 保留既有部署作为恢复来源。需要调整 GitHub App 授权时，只增加所需仓库，保留其他已有授权。
- **更新发布下载项**：使用以下命令成对更新下载资源与校验信息（请将参数替换为实际输入路径）：
  ```bash
  python3 site/scripts/package.py --prepare-downloads \
    --app-archive "dist/Coddle-preview-universal.zip" \
    --source-archive "dist/Coddle-source-preview.tar.gz" \
    --release-metadata "dist/release.json"
  ```
  元数据须显式包含两份压缩包的字节大小与 SHA-256 哈希。源码归档采用 `Coddle-source-preview/Coddle/` 布局，仅保留单个根 README.md 与许可证文件。
- **线上发布验证**：运行 `python3 site/scripts/verify-live.py https://coddle.kyun.si` 可在线核验生产环境发布状态与终端输出。
</details>

## 参与贡献

欢迎提交清晰的问题报告（包括 Mac 机型、芯片型号、macOS 版本、电源连接状态、开关位置及复现步骤）以及不同硬件环境的实测数据反馈。修改代码或文案时，请同步多语言资源并保持中文与英文 README 的结构、表格及链接对齐。提交前请确认清理个人隐私信息与临时调试记录。

## 开源许可

本项目采用 [MIT](LICENSE-MIT) 开源许可证。
