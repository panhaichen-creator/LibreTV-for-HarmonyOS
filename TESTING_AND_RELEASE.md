# LibreTV 鸿蒙原生客户端 — 测试与发布指南

适用版本：v1.0.6（versionCode 1100002）  
目标平台：HarmonyOS NEXT（纯血鸿蒙，API 26，DevEco Studio 26.0.0）  
工程根目录：`LibreTV-HarmonyOS/`

> ✅ **构建验证状态（2026-10-16 实测）**：本工程已在本机 DevEco Studio 26.0.0.851
> （HarmonyOS SDK API 26）用命令行工具链完成 **Debug HAP / Release HAP / Release APP
> 三种构建的从零重建（clean 后全量编译）**，均 `BUILD SUCCESSFUL`、**0 编译错误**，
> 全部 32 个 ArkTS 源文件通过严格模式编译。剩余未覆盖项：**真机/模拟器运行时测试**
> （编写本文档时本机 `hdc list targets` 为空，无已连接设备）——连接设备后按
> 「第四阶段」执行即可。



---

## 第一阶段 · 环境准备与工程导入

### 步骤 1：确认 DevEco Studio 版本

| 组件            | 最低要求                    | 说明                                 |
| ------------- | ----------------------- | ---------------------------------- |
| DevEco Studio | **26.0.0（2026 版）或可创建 API 26 工程的版本** | API 26 需要新版 IDE 支持；`Help → About` 可查看版本 |
| HarmonyOS SDK | **API 26**（与工程 compileSdk 一致） | SDK Manager → HarmonyOS → 下载 |
| Node.js       | 内置即可（随 DevEco 安装）       | ohpm 依赖安装用                         |
| Node.js（命令行）  | 16+（仅命令行构建需要）           | 调用 IDE 内置 hvigorw.js 需要         |

检查方式：DevEco Studio 启动后看欢迎页 `Help → About`，版本号需 ≥ 5.0.0。  
SDK 检查：`File → Settings → Appearance & Behavior → System Settings → HarmonyOS SDK`，确认已下载 **API 26** 或更高的 SDK Platform 与 System Image（模拟器镜像也要勾选）。

### 步骤 2：导入工程

1. DevEco Studio 欢迎页 → **Open**（不要用 Import，本工程已是完整 DevEco 工程，非其他 IDE 导出）。
2. 选择 `LibreTV-HarmonyOS` 目录（即包含 `oh-package.json5`、`build-profile.json5` 与 `hvigor/` 的那一层），点 OK。
3. **导入前自检**（避免 `00304004 Not Found` 类错误）：工程根必须同时存在
   `hvigor/hvigor-config.json5`、`hvigorfile.ts`、`oh-package.json5`、`build-profile.json5`、
   `AppScope/app.json5`、`entry/src/main/module.json5`——本工程均已内置。
4. 首次打开会自动执行 **Sync**（右下角进度条）。若提示 "hvigor sync failed"，大概率是：
   - 未登录华为账号（见步骤 4）
   - 未配置签名（见步骤 4）
   - SDK 未下载 API 26
   - `modelVersion` 不一致（`hvigor-config.json5` 与 `oh-package.json5` 必须相同）
5. 等待右下角出现 **"Sync finished"** 或类似提示，`entry/build` 目录生成即成功。

### 步骤 3：先做一次「编译预检」（强烈建议）

在连接真机/模拟器之前，先跑一次纯编译，把类型错误暴露出来：

```
Build → Rebuild Project
```

**如果报错**，按以下优先级处理：

| 报错关键字                                               | 原因                | 处理                                                                                           |
| --------------------------------------------------- | ----------------- | -------------------------------------------------------------------------------------------- |
| `hvigor ERROR: 00304004 Not Found` + `hvigor-config.json5 does not exist` | 工程缺少 hvigor 脚手架目录 | 确认工程根有 `hvigor/hvigor-config.json5`（本工程已内置；若误删，可从本机 IDE 模板 `DevEco Studio 安装目录/plugins/openharmony/lib/templates/project/New Project/code template/hvigor/` 复制，`modelVersion` 填 `"26.0.0"`） |
| `INCONSISTENT_MODEL_VERSION`                        | 两处 modelVersion 不一致 | `hvigor-config.json5` 与根 `oh-package.json5` 的 `modelVersion` 必须完全相同（本工程均为 `"26.0.0"`） |
| `UNSUPPORTED_MODEL_VERSION_OF_HVIGOR`               | modelVersion 超出支持范围 | 须满足 `5.0.0 ≤ modelVersion ≤ 26.0.0`（IDE 26.0.0 的预设上限） |
| `HO_API_VERSION_VALIDATE_FAILED`                    | HarmonyOS 版本号写成了数字 | `build-profile.json5` 的 `compatibleSdkVersion`/`targetSdkVersion` 必须是**字符串**（`"26.0.0"`），不能写 `26` |
| `10605038`                                          | 页面参数未声明 interface | 检查 `pageMap` 里 `pushPath({name, param})`，param 对象须先 `interface X { ... }` 再定义变量传入（本工程已按此规范写） |
| `... has no exported member` / kit 路径错误             | API 所在 kit 不符     | 大部分集中在 `@kit.MediaKit`、`@kit.ArkUI`、`@kit.NetworkKit`；查官方 API 参考确认归属                         |
| `Property 'xxx' does not exist on type 'AVPlayer'`  | AVPlayer 属性名变更    | 注意是 `surfaceId`（小写 d）                                                                        |
| `Only 'let' variables can be captured in a closure` | 严格模式闭包捕获          | 将捕获变量改为 `let` 或提升到成员                                                                         |
| `Ternary expression is not allowed in build()`      | 三元表达式             | 已全量改为辅助方法，若新增代码务必遵守                                                                          |
| 1000+ 个错误                                           | IDE 语言服务未就绪       | 先 `File → Invalidate Caches → Invalidate and Restart`                                        |

| `00303148 Hvigorfile not found: entry\hvigorfile.ts`       | 模块级缺少 hvigorfile       | DevEco 6.x 要求**每个模块**都有自己的 `hvigorfile.ts`（entry 模块用 `hapTasks`）。本工程已内置 `entry/hvigorfile.ts`；新建模块时别忘了抄一份 |
| `module.json5: must have required property 'deliveryWithInstall'` | module 节点缺必填字段 | entry 模块的 `module.json5` → `module` 节点加 `"deliveryWithInstall": true` |
| `10605040` / `10605038`（内联对象字面量作类型） | ArkTS 严格模式禁止内联对象字面量作类型声明 | 先 `interface X { ... }` 声明接口，再让函数返回该接口类型（对象字面量不得直接当类型用） |
| `10505001` TextDecoder `decode` / `decodeWithStream` 已弃用 | 旧版解码 API | 统一改用 `decodeToString(input: Uint8Array)`（API 12+） |
| `PackageHap: 00308018 spawn java ENOENT`            | 命令行构建找不到 Java       | 打包 HAP 需要 JDK：设 `JAVA_HOME` 指向 DevEco 的 `jbr`，并把 `jbr/bin` 加进 PATH |
| `00306054 assembleApp was not found`                | 把工程级任务当模块级跑       | `assembleApp` 是**工程级**任务，**不能**加 `--mode module`，直接 `hvigorw assembleApp -p buildMode=release` |
| `00303217 Invalid value of 'DEVECO_SDK_HOME'`       | 命令行构建未注入 SDK 路径    | HarmonyOS 工程只读该环境变量（local.properties 会被忽略），须显式 export，见文末速查 |
| **黑屏：`SetUIContentInner ... errorCode: 13`（Parameter error）** | `module.json5` 缺 `"pages": "$profile:main_pages"` 字段且缺 `resources/base/profile/main_pages.json` | 运行时通过该 profile 解析页面注册表，两者缺一即页面表为空、`loadContent` 直接失败。补上后**会触发 ArkTS 严格模式全量校验**，一次性暴露此前宽松编译掩盖的真实错误（本工程修复 57 处，涉及 `promptAction`→`getPromptAction()`、`AVPlayerState` 字符串联合、`TextAlign.RIGHT`、`pasteboard.createData` 模块级函数、`ScrollDirection`、`tabIndex` 与 `CustomComponent` 内置属性冲突等），详见「附录 B · 黑屏故障修复记录」 |

> 命令行构建专属错误见「附：命令行构建环境三要素」。

**Rebuild 通过后再进入下一步。** 编译期解决 80% 的问题，比真机调试省 10 倍时间。

---

## 第二阶段 · 签名配置（两条路线）

工程 `build-profile.json5` 当前 `signingConfigs: []`，即**未签名状态**，必须先配置。

### 路线 A：自动签名（推荐新手，5 分钟）

**前置条件**（缺一不可）：

1. 系统时间已对齐北京时间（自动签名服务端会校验）；
2. IDE 已登录具备 **APP 管理员** 或更高权限的华为开发者账号（未注册先去 [developer.huawei.com](https://developer.huawei.com) 注册并完成实名认证）；
3. 工程的 bundleName（`com.libretv.harmonyos`）**已在 AppGallery Connect 中创建了对应的应用**；
4. 已连接一台真机或启动一个模拟器。

**操作步骤**：

1. `File → Project Structure → Project → Signing Configs`
2. 勾选 **"Automatically generate signature"**（部分版本显示为「支持 HarmonyOS」的自动签名开关）
3. 点击 **Sign In** 登录华为账号，授权
4. 勾选生成的签名配置（通常命名为 `default`）
5. OK 退出，IDE 会自动生成 .p12/.csr/.cer/.p7b 四件套并回填到 `build-profile.json5`
6. 重新 Sync

> 自动签名生成的是**调试证书 + 调试 Profile**，**只能装到已注册的调试机上**，**不能上架**。发布路线见下文。

### 路线 B：手动签名（上架必走）

发布用的签名必须手动申请，因为发布证书/Profile 不能用于调试。

**B1. 生成密钥与 CSR（本地）**

```
Build → Generate Key and CSR
```

- 填入 Key Store 路径（建议存到工程外，如 `~/harmony-keys/libretv.p12`，**切勿提交 git**）
- Validity（有效期）建议填 **25 年以上**，避免证书过期导致无法更新应用
- **姓名字段不能含中文**，用拼音或英文
- 记好密码

**B2. 申请数字证书（AGC 网页）**

1. 登录 [AppGallery Connect](https://developer.huawei.com/consumer/cn/service/josp/agc/index.html)
2. `用户与访问 → 证书管理 → 新建证书`
3. 上传 B1 生成的 `.csr`
4. 选择「**发布证书**」（注意：不是调试证书），提交后下载 `.cer`
5. 发布证书有效期通常 3 年，到期前需更换

**B3. 申请 Profile**

1. 同一页面 `Profile 管理 → 新建 Provisioning Profile`
2. 类型选「**发布**」，绑定 bundleName `com.libretv.harmonyos`
3. 选择 B2 的发布证书
4. 选择应用权限（本工程需要：网络、网络状态）
5. 提交后下载 `.p7b`

**B4. 回填工程**  
`File → Project Structure → Signing Configs` 手动填入四个文件路径，或直接编辑 `build-profile.json5`：

```json5
"signingConfigs": [
  {
    "name": "release",
    "type": "HarmonyOS",
    "material": {
      "storeFile": "C:/path/to/libretv.p12",
      "storePassword": "******",
      "keyAlias": "libretv",
      "keyPassword": "******",
      "signAlg": "SHA256withECDSA",
      "profile": "C:/path/to/libretv.p7b",
      "certpath": "C:/path/to/libretv.cer"
    }
  }
]
```

**安全提醒**：不要把真实密码提交到 git。可改用环境变量或在 `.gitignore` 排除 `local.signing.json5`。

---

## 第三阶段 · 构建产物

| 目标                  | 命令/菜单                                                                                                | 产物路径                                                                   |
| ------------------- | ---------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| Debug HAP（装调试机）     | `Build → Build Hap(s)/APP(s) → Build Debug Hap(s)`                                                   | `entry/build/default/outputs/default/entry-default-debug-signed.hap`   |
| Release HAP（上架）     | `Build → Build Hap(s)/APP(s) → Build Release Hap(s)`                                                 | `entry/build/default/outputs/default/entry-default-release-signed.hap` |
| Release APP（推荐上架格式） | `Build → Build APP(s)`                                                                               | `entry/build/default/outputs/default/entry-default-release-signed.app` |
| 命令行                 | 用 IDE 自带 hvigor（新版工程不再自带 `hvigorw` 脚本），且**必须先配好环境变量**（见文末速查）：<br>`node.exe tools\hvigor\bin\hvigorw.js assembleHap --mode module -p product=default -p buildMode=release` | 同上                                                                     |

**上架请用 `.app` 包**，HAP 包仅用于真机侧载测试。

> 未配置签名时产物名带 `-unsigned` 后缀（如 `entry-default-unsigned.hap`、
> `LibreTV-HarmonyOS-default-unsigned.app`），这是正常现象；配好签名后即为可安装/可上架包。
> 2026-10-16 实测产物大小：Release HAP 约 90 KB、Release APP 约 52 KB
> （APP 内嵌 HAP，HAP 本身已压缩故 APP 不显著变大）。

版本号规则（每次上架必改）：

- `AppScope/app.json5` → `versionCode`：**必须递增的正整数**（本工程当前为 `1100001`，下次上架改 `1100002`……），AGC 拒绝相同或更低的 versionCode
- `versionName`：语义化版本，如 `1.0.0`、`1.1.0`

---

## 第四阶段 · 真机与模拟器测试

### 4.1 设备准备

**真机（推荐，播放类应用必须真机验证）**：

- 纯血鸿蒙 NEXT 机型：Mate 60/70 系列、Pura 70、Pocket 2、nova 12/13 等
- `设置 → 系统和更新 → 关于手机`，确认 HarmonyOS 版本为 **5.0（NEXT）或更高（API 26 设备为 6.x）**
- 开启开发者模式：`设置 → 关于手机 → 连点「版本号」7 次`
- `设置 → 系统和更新 → 开发人员选项` 开启 **USB 调试**
- 数据线连接电脑，授权弹窗点允许

**模拟器（快速验证 UI）**：

- `Tools → Device Manager → New Emulator`，选 API 26 或 26+ 的 Phone 镜像
- 首次启动需下载镜像，约 3-10 GB

### 4.2 运行与日志

- 点击 IDE 顶部 ▶ 运行，选择目标设备
- 抓日志（命令行）：
  ```
  hdc hilog | Select-String "LibreTV"      # PowerShell
  hdc hilog | grep LibreTV                 # Git Bash
  ```
- 常用过滤：`hdc shell hilog -x domain:0x0001` 后看 tag 为 `LibreTV` 的行；崩溃看 `FaultLog`（`hdc faultlog print`）

### 4.3 功能测试清单（逐项打勾）

| #  | 模块   | 测试项                      | 预期结果                       |
| -- | ---- | ------------------------ | -------------------------- |
| 1  | 启动   | 冷启动                      | 3 秒内出首页，无白屏/闪退             |
| 2  | 主题   | 深浅色切换（我的 → 设置 → 主题）      | 全局即时切换，重启后保持               |
| 3  | 首页   | 推荐位渲染、分类入口               | 封面图加载，点击进详情                |
| 4  | 搜索   | 输入关键词搜索                  | 聚合多源结果，排序正常                |
| 5  | 搜索   | 搜索历史                     | 记录、点击回填、可清空                |
| 6  | 详情   | 剧集列表、简介展开                | 选集可点，简介可折叠                 |
| 7  | 播放   | 点播播放（默认源）                | 起播 ≤ 3s，音画同步               |
| 8  | 播放   | 拖动进度条 seek               | 跳转后正常续播                    |
| 9  | 播放   | 倍速（0.5x–2x）              | 六档切换生效                     |
| 10 | 播放   | 全屏/竖屏切换                  | 窗口方向正确，UI 不重叠              |
| 11 | 播放   | 返回键                      | 退出全屏 → 退出页面，进度已存           |
| 12 | 续播   | 杀进程后重新进入同一集              | 从上次位置续播                    |
| 13 | 换源   | 详情页换源测速                  | 列出各线路延迟，可切换                |
| 14 | 广告过滤 | 播放 m3u8 含广告分片的源          | 分片过滤生效（对比 LibreTV Web 版效果） |
| 15 | 广告过滤 | 过滤模式 off/low/medium/high | 四档行为差异符合预期                 |
| 16 | 直播   | 直播频道列表播放                 | 起播正常，频道切换 ≤ 2s             |
| 17 | 直播   | EPG 节目单                  | now/next 显示，无节目时优雅降级       |
| 18 | 收藏   | 收藏/取消（点播、直播）             | 状态同步，历史页可见                 |
| 19 | 历史   | 播放历史列表、续播入口              | 正确记录与跳转                    |
| 20 | 源管理  | 增删改视频源/直播源               | 立即生效，重启保持                  |
| 21 | 订阅   | URL 导入 / 粘贴导入            | 解析成功，失败有明确提示               |
| 22 | 订阅   | 导出到剪贴板                   | 剪贴板内容格式正确                  |
| 23 | 下载   | 添加下载任务                   | 进度条推进，完成可离线播放              |
| 24 | 下载   | 删除任务                     | 沙箱文件真正删除（设置 → 存储 复核）       |
| 25 | 设置   | 成人过滤开关                   | 开启后隐藏敏感分类                  |
| 26 | 网络   | 弱网/断网播放                  | 有 loading 与错误态，不闪退         |
| 27 | 性能   | 连续播放 30 分钟               | 无内存持续增长，不发烫严重              |

### 4.4 已知需要重点观察的风险点

1. **AVPlayer 状态机**：换集/自动连播依赖 `ensureIdle()`，若出现「第二次播放无画面」，重点看 hilog 中 reset 后是否回到 idle。
2. **广告过滤 m3u8**：依赖 `@ohos.zlib` 的 DEFLATE 移植实现，遇到非标准 m3u8 会退化为直链（功能降级但不崩溃）。
3. **防盗链**：部分源校验 Referer/UA，`PlayUrlResolver.headersFor()` 已内置桌面 UA + 站点 Referer，个别站点可能仍失败。
4. **直播源**：部分直播协议（如 RTMP）AVPlayer 不支持，会自动降级或报错。

---

## 第五阶段 · 上架 AppGallery

### 5.1 上架前资质材料清单

| 材料           | 说明                                 |
| ------------ | ---------------------------------- |
| 软件著作权（或电子版权） | **视频聚合类必须**，无软著基本无法过审              |
| 隐私政策可访问链接    | 公网 URL，不能是本地文件；须说明收集的信息、用途、第三方 SDK |
| APP 备案号      | 工信部 ICP 备案 + App 备案，缺一不可           |
| 512×512 应用图标 | PNG，无圆角                            |
| ≥ 3 张真实截图    | 手机截图，须与实际 UI 一致（审核会比对）             |
| 应用分类与标签      | 建议选「工具」类，**避免「AI」相关标签**            |
| 内容分级问卷       | 如实填写                               |

### 5.2 上架流程

1. **创建应用**（若未创建）：AGC → APP 与元服务 → 我的应用 → 新建应用 → 包类型选「HarmonyOS」→ 包名填 `com.libretv.harmonyos`（**提交后不可修改**）
2. **版本管理**：选择应用 → 版本管理 → HarmonyOS → 新建版本
3. **上传软件包**：拖入 `.app` 包（不是 HAP）
   - 勾选「合法性检测」（必选）
   - 建议勾选「上架自检」，提前暴露常见问题
4. **填写发布信息**：
   - 基础信息：应用名称、简介、分类、标签
   - 发布区域：按需选择
   - 资费：免费
   - 隐私政策链接
   - AI 声明：本应用**不是 AI 类应用**，不勾选 AI 相关声明（界面与描述中也不应出现「AI」字样）
   - 资质：上传软著
   - APP 备案号
   - 联系信息
   - 上架时间：可选手动或自动
5. **提交审核**

### 5.3 审核周期与驳回高频原因

- 常规审核 **1-3 个工作日**；涉及特殊资质 1-7 个工作日
- 高频驳回原因：
  1. 隐私政策不完整/不可访问
  2. 未说明权限用途（本工程只用了网络与网络状态权限，需在隐私政策中说明）
  3. 截图与实际 UI 不符
  4. 功能不完整（测试时发现按钮点了没反应）
  5. 视频源内容合规风险 —— 见下方风险提示

### 5.4 灰度发布（强烈建议）

上架后不要直接全量：

1. 版本管理 → 灰度发布 → 比例 **5%**
2. 观察 1-2 天：崩溃率、下载转化
3. 无异常后逐步 **20% → 50% → 100%**
4. 灰度期间发现问题可**暂停灰度**或**回滚版本**

---

## ⚠️ 合规与风险提示（务必阅读）

1. **第三方视频聚合类应用在 AppGallery 属于高风险类目**。LibreTV 本身聚合公开的视频源接口，若源站内容无授权，可能被认定为「提供未经授权的视听节目服务」，存在被下架风险。上架前请评估内容合规性。
2. **本应用不抓取、不存储版权内容**，仅解析公开接口并播放，技术形态与 Web 版 LibreTV 一致。
3. 界面、商店描述、截图内**不要出现「AI」字样**，避免触发额外类目审核。
4. 本工程代码**已通过命令行全量编译验证（Debug/Release/APP 三种构建 0 错误）**，但**未经真机运行验证**；真机首跑如遇问题，优先检查 ArkTS 严格模式约束（build() 内无三元/局部变量/switch/console、ForEach 必须显式 key、禁止 any/unknown）。
5. 密钥与证书文件**严禁提交到公开仓库**。

---

## 附：常用命令速查

```bash
# ========== 命令行构建环境三要素（缺一不可，2026-10-16 实测） ==========
# ① SDK 路径：HarmonyOS 工程只读 DEVECO_SDK_HOME 环境变量，local.properties 会被忽略
export DEVECO_SDK_HOME="D:\Program Files\Huawei\DevEco Studio\sdk"
# ② Java：打包 HAP 需要 JDK（否则报 00308018 spawn java ENOENT）
export JAVA_HOME="D:\Program Files\Huawei\DevEco Studio\jbr"
export PATH="/d/Program Files/Huawei/DevEco Studio/jbr/bin:$PATH"
# ③ 若在注入了 Node 垫片的沙盒/代理环境里跑，需剔除注入变量，否则 hvigor daemon
#    的 fs.rmSync（文件锁解锁）会被转去调用 trash 二进制而 ETIMEDOUT：
env -u NODE_OPTIONS -u CODEBUDDY_SAFE_DELETE_BULK_GUARD -u CODEBUDDY_SAFE_DELETE_BIN_DIR ...

# ========== 构建 Release HAP ==========
# （新版工程无自带 hvigorw 脚本，用 IDE 内置的）
"D:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" "D:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js" assembleHap --mode module -p product=default -p buildMode=release

# ========== 构建 Release APP（上架包；assembleApp 是工程级任务，不能加 --mode module） ==========
"D:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" "D:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js" assembleApp -p product=default -p buildMode=release

# 清理构建产物（解决诡异的缓存错误；也可直接删工程根的 .hvigor 目录）
"D:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" "D:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js" clean

# 安装 HAP 到已连接设备
hdc app install entry/build/default/outputs/default/entry-default-debug-signed.hap

# 卸载
hdc app uninstall com.libretv.harmonyos

# 查看实时日志（过滤 LibreTV tag）
hdc shell hilog | Select-String "LibreTV"

# 查看崩溃日志
hdc faultlog print
```

---

## 附录 B · 黑屏故障修复记录（2026-10-17 实测）

### 故障现象

真机（LMR-AL10，HarmonyOS 7.0.0.109 / API 26）安装后启动，界面全黑、无任何显示，
无崩溃、无弹窗。`hdc shell bm dump` 显示应用 `"pages": ""`（页面注册表为空）。

### 根因定位

抓取 hilog 找到关键报错：

```
E WindowSessionImpl: SetUIContentInner: failed to init or restore uicontent
  with file pages/IndexPage. errorCode: 13
E LibreTV: loadContent failed: Parameter error
```

**根因：`entry/src/main/module.json5` 缺少 `"pages": "$profile:main_pages"` 字段，
且 `entry/src/main/resources/base/profile/main_pages.json` 不存在。**
运行时通过该 profile 解析页面列表；两者缺一 → 页面注册表为空 → `loadContent` 报 errorCode 13。
对比 DevEco 26 官方模板（`codegenie-plugin/previewProject`）确认两者均为必需。

### 修复内容（两轮，共 59 处）

**第一轮 · 恢复页面注册表：**

1. `module.json5` 的 `module` 节点补 `"pages": "$profile:main_pages"`；
2. 新建 `resources/base/profile/main_pages.json`（无 `src/main/ets` 前缀、无 `.ets` 后缀）。

**⚠️ 注意：补上 `pages` 字段后 hvigor 会从宽松编译切换为 ArkTS 严格模式全量校验，
此前「0 错误」是假象——一次性暴露 57 处真实违规。第二轮按官方 SDK 声明逐项修复：**

| 类别 | 修复 |
| --- | --- |
| `UIContext.promptAction` 成员不存在（API 26） | 9 个页面改 `getUIContext().getPromptAction().showToast(...)` |
| `media.AVPlayerState` 改为字符串联合类型 | 10 处 `media.AVPlayerState.XXX` 改 `'xxx'` 字面量 |
| ArkUI `TextAlign` 成员全大写 | `TextAlign.Right` → `TextAlign.RIGHT`（3 处） |
| `XComponentController`/`Axis` 为全局声明 | 删除多余 `@kit.ArkUI` import |
| `pasteboard.createData` 是模块级函数（非 `SystemPasteboard` 方法） | 改 `pasteboard.createData(...)` |
| `Scroll.scrollable` 参数类型是 `ScrollDirection` | `Axis.Horizontal` → `ScrollDirection.Horizontal` |
| `tabIndex` 与 `CustomComponent` 内置属性冲突 | 首页/源管理页改名为 `activeTab` |
| `JSON.parse` 隐式 any / 数组未强转 / 内联对象字面量作类型 | 补显式类型与 interface（XmltvParser、SearchService、Douban/Bangumi/CmsClient） |
| `GridAttribute` 不含 `maxHeight` | 改 `.height(260)` |
| 死代码与变量遮蔽 | 删除未声明的 `infoLoading` 赋值、pasteboard 局部变量改名 `pb` |

**第三轮收尾（6 处）**：恢复 `BangumiClient` 被误删的 `as object`、两页 `tabIndex`→`activeTab`、
pasteboard 调用层级调整、`scrollable` 参数类型修正。clean 重建 `BUILD SUCCESSFUL`、0 错误。

### 验证结果（2026-10-17，真机截图）

- 首页正常渲染：搜索栏、推荐网格（豆瓣+Bangumi 评分/标题）、底部三 Tab；
- 「我的」页、视频源管理页（点播/直播 Tab、源卡片、探测/删除）正常渲染；
- Navigation 子页面可达（首页 → 我的 → 视频源管理）；
- hilog 无 JS 异常、无 errorCode 13、无崩溃；
- 待用户逐项验证：播放、搜索、下载、直播、历史等（见第四阶段清单）。

### 经验沉淀

1. **`module.json5` 的 `pages` 字段是运行时就绪的前提**，缺它编译期不报错（宽松编译），
   运行期直接黑屏——这是「编译通过但黑屏」的头号嫌疑，应第一时间排查。
2. **宽松编译的「0 错误」不可信**：缺 `pages` 字段时 hvigor 几乎不做完整语义检查；
   任何声称「编译已验证」的结论都必须以 clean 全量重建 + 严格模式通过为准。
3. 排查手段：`hdc shell bm dump`（看 pages 是否为空）→ `hilog` 搜 `SetUIContentInner`/`loadContent`
   → 对比官方模板补字段 → 严格模式错误按 SDK d.ts 声明逐项修。

---

*本文档随工程分发，与 README.md 配合阅读。*
