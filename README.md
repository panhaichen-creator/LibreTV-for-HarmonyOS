<div align="center">

# LibreTV for HarmonyOS

**LibreTV 的鸿蒙原生客户端 · ArkTS + ArkUI · HarmonyOS NEXT (API 26)**

多源聚合搜索 · HLS 播放 · 直播与节目单 · 离线下载 · 深浅主题

[功能](#-功能) · [安装](#-安装) · [首次使用](#-首次使用重要) · [常见问题](#-常见问题) · [自己构建](#-从源码构建) · [架构说明](docs/ARCHITECTURE.md)

</div>

---

## 这是什么

[LibreTV](https://github.com/LibreSpark/LibreTV) 是一个开源的影视聚合播放 Web 应用 —— 它本身不提供任何影片，
而是把你自己的**采集站源**聚合起来，做统一的搜索、详情、播放体验。

这个项目是它的**纯血鸿蒙版本**：不是套壳浏览器，是用 ArkTS + ArkUI 从零写的原生应用，
播放走系统 `AVPlayer`，界面走声明式 UI，没有 WebView、没有 hls.js。

**核心逻辑与 Web 版对齐**：同一套 Apple CMS V10 协议、同一套跨源同名合并规则、
同一套源健康度阶梯停用策略。你在 Web 版里配的源，可以直接搬过来。

> [!IMPORTANT]
> 本项目**不内置任何影片内容，也不内置任何"种子源"**。首次安装是空的，
> 你需要自己添加采集站，或点应用内的一键导入按钮。
> 内容合法性与可用性由源方负责，请自行判断。

---

## 📺 Android TV 版

另有一个同一套能力的**电视盒子 / Android TV 版本**（Kotlin + Compose + Media3），目前**不在本仓库内**：

- 界面按电视设计稿重做，遥控器全程可操作
- 补上了鸿蒙平台做不到的两件事：**TVBox Spider 引擎**（动态加载 spider JAR）与**网盘直连播放**（夸克 / UC / 阿里云盘 / WebDAV）
- 产出可安装的 APK（`app/build/outputs/apk/release/app-release.apk`）

> 之所以没并入本仓库：它自带数百 MB 的预编译产物和一套独立的签名材料，混在一起会让只想编译鸿蒙端的人多下载十倍体积。整理成干净的子集后会单独开仓库。

---

## 截图

<div align="center">

| 首页推荐 | 浏览 · 无限滚动 |
|:---:|:---:|
| <img src="docs/screenshots/home.png" width="300"> | <img src="docs/screenshots/discover.png" width="300"> |

| 筛选与排序 | 平板 / 大屏横屏适配 |
|:---:|:---:|
| <img src="docs/screenshots/filter.png" width="300"> | <img src="docs/screenshots/tablet.png" width="420"> |

</div>

---

## ✨ 功能

### 搜索与浏览
- **多源聚合搜索**：并行请求所有启用的源，同名影片按「标题 + 年份」合并成一张卡片，卡片上标注有几个源可用
- **换源播放**：某个源卡顿/失效，一键切到另一个源，从同一集继续
- **换源测速**：并发拉取各源播放列表计时，按耗时排序，一眼看出哪个源快
- **相关性过滤**：多关键词逐词命中，避免搜「流浪地球」出来一堆无关内容
- **成人内容过滤**：关键词 + 分类双重判断，默认开启
- **搜索历史**：本地保存，可单条删除

### 首页推荐
- 豆瓣 / Bangumi 双数据源推荐，可切换
- 五个分类：热门电影、热门剧集、热门综艺、热门动漫、热门纪录片
- 多种排序：近期热门 / 标记最多 / 评分最高 / **最近上映**
- 年份、地区、类型筛选
- 瀑布流无限滚动（下拉回弹、上滑超过两屏出现「返回顶部」悬浮按钮）

### 播放
- **HLS 播放**，支持 m3u8 / mp4
- **广告分片过滤**：宽松（丢掉 DISCONTINUITY 包裹的整组短分片）/ 严格（丢掉所有 <3s 分片）两档
- **倍速** 0.5x – 2x 六档
- **自动连播**：播完自动跳下一集
- **进度续播**：精确到毫秒，退出再进接着看
- **防盗链支持**：自动注入桌面 UA + 站点 Referer
- **手势控制**：左侧上下滑调亮度、右侧上下滑调音量、横滑调进度
- **锁定 / 画面比例 / 长按倍速** 等常规操作
- 横竖屏自动切换，退出播放页自动还原系统亮度

### 直播 / IPTV
- M3U / M3U8 直播列表解析
- **XMLTV 电子节目单**（含 `.xml.gz` 压缩格式），显示「正在播 / 接下来」
- 直播源分组、频道收藏

### 离线
- 分片下载缓存到应用沙箱，断网可看
- 下载队列管理、进度显示、失败重试

### 源管理
- **一键导入 8 个实测可用的推荐源**
- 订阅导入：LibreTV-SourceList JSON / TVBox 订阅，支持 URL 导入、粘贴导入、**扫码导入**
- 手动添加：填站点地址即可，自动归一化
- 源健康度：连续失败自动阶梯停用（30 分钟 → 24 小时 → 长期），成功一次就恢复
- 导出订阅：生成 JSON 复制到剪贴板，方便分享或备份

### 其他
- 深浅色主题（跟随系统 / 强制浅色 / 强制深色）
- 手机 / 平板 / 2in1 / TV 多设备形态适配
- 支持 `http://` 明文采集站（大量可用源只有 http）

---

## 📥 安装

HarmonyOS NEXT 的应用必须签名才能安装，而签名用的**调试证书绑定设备白名单** ——
作者没办法预先签一个"谁都能装"的包。所以有两条路：

### 方式 A：从源码构建（推荐，约 5 分钟）

1. 安装 [DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/)（需支持 API 26 的版本）
2. 克隆本仓库，用 DevEco Studio 打开**根目录**（含 `AppScope/` 的那层）
3. 菜单 `File → Project Structure → Project → Signing Configs`
   → 勾选 **Automatically generate signature** → 登录华为账号 → `OK`
4. 手机开启「开发者模式 + USB 调试」，连上电脑
5. 点右上角 ▶ **Run**

签名配置会自动写进 `build-profile.json5`（**这个文件已被 gitignore 保护，别提交自己的证书**）。

### 方式 B：用 Release 里的 HAP 自己重签

[Releases](../../releases) 页面提供**未签名 HAP**。你需要用自己的证书签一遍：

```bash
# 1. 从 DevEco Studio 的 SDK 目录找到签名工具
#    <SDK>/toolchains/lib/hap-sign-tool.jar

# 2. 用你 DevEco 生成的证书签名
java -jar hap-sign-tool.jar sign-app \
  -keyAlias "debugKey" \
  -signAlg "SHA256withECDSA" \
  -mode "localSign" \
  -appCertFile "your.cer" \
  -profileFile "your.p7b" \
  -inFile "LibreTV-HarmonyOS-unsigned.hap" \
  -keystoreFile "your.p12" \
  -outFile "LibreTV-HarmonyOS-signed.hap" \
  -keyPwd "***" -keystorePwd "***"

# 3. 安装
hdc install LibreTV-HarmonyOS-signed.hap
```

其中 `your.p7b` 里的设备白名单必须包含你的设备 UDID（DevEco 自动签名时会自动登记）。

> [!TIP]
> 如果你只是想在**自己的一台设备**上用，方式 A 最省事。
> 如果想正式分发给别人，需要注册华为开发者账号并上架 AppGallery，那是另一套流程。

---

## 🚀 首次使用（重要）

装好打开，你会发现**首页推荐能刷，但搜索没结果** —— 这是正常的，因为还没有源。

### 三步搞定

1. 底部导航点 **「我的」**
2. 点 **「视频源管理」**
3. 点 **「一键导入推荐源」**

会出现 8 个实测可用的源（建设、索尼、量子、非凡、电影天堂、红牛、光速、极速），
点完提示「已添加 N 个推荐源」，返回首页就能搜了。

> 这些源是社区公开的采集站，**随时可能失效或关停**，属正常现象。
> 失效了就在源管理里删掉，或去 [源分享社区](https://github.com/LibreSpark/LibreTV) 找新的。
> 也可以点「换源测速」看看当前哪些源还活着。

### 添加自己的源

支持三种方式，都在「视频源管理」页：

| 方式 | 说明 |
|---|---|
| **粘贴 JSON** | LibreTV-SourceList 格式，即 Web 版导出的那份配置 |
| **填 URL** | TVBox 订阅地址，或直链到一个 JSON / m3u 文件 |
| **扫码** | 电脑上打开订阅链接生成二维码，手机扫一下 |
| **手动添加** | 只填站点地址，形如 `https://example.com`（会自动补全 API 路径） |

---

## 🎮 使用说明

### 首页
推荐列表点卡片 → 按标题聚合搜索 → 进详情页选集播放。

### 搜索
顶部搜索框输入关键词。结果卡片右上角的数字表示**有几个源命中**，
点进详情页可以看每个源各自的线路和集数。

### 详情页
- 顶部切换源（显示各源集数）
- 选集网格
- 「下载」按钮缓存当前集
- 「收藏」加入收藏夹

### 播放页
| 操作 | 效果 |
|---|---|
| 左侧上下滑 | 调亮度（退出自动还原） |
| 右侧上下滑 | 调音量 |
| 横滑 | 快进 / 快退 |
| 单击 | 显示 / 隐藏控制栏 |
| 长按 | 临时 2x 倍速 |
| 双击 | 播放 / 暂停 |

### 「我的」
播放历史、收藏、下载管理、视频源管理、设置。

### 设置项
- 广告过滤：关闭 / 宽松 / 严格
- 自动连播
- 成人内容过滤
- 默认倍速
- 记录播放历史
- 主题：跟随系统 / 浅色 / 深色（切换后需重启应用完全生效）
- 推荐源：豆瓣 / Bangumi

---

## ❓ 常见问题

<details>
<summary><b>搜索一直转圈 / 没有任何结果</b></summary>

1. 确认已经添加源（「我的 → 视频源管理」看列表是否为空）
2. 点「换源测速」，全部超时说明这些源当前不可用，换一批
3. 部分源仅支持 `http://`，如果手机网络环境强制 HTTPS 会失败
</details>

<details>
<summary><b>能搜到但点播放黑屏 / 一直 00:00</b></summary>

通常是源本身的播放地址失效，或需要特定的 Referer / Cookie 才能拉流。
在详情页**换一个源**试试，这是最快的验证方式。
</details>

<details>
<summary><b>导入订阅时提示「跳过 N 个 Spider 源」</b></summary>

`type: 3` 或 `api` 以 `csp_` 开头的源是 **TVBox spider 引擎**，
需要 Android 的 JVM 动态加载 JAR 才能运行。HarmonyOS NEXT 没有 JVM，
**无法支持**，这是平台能力边界，不是 bug。详见 [架构说明](docs/ARCHITECTURE.md#四平台能力边界spider-源不支持)。

导入时这类源会被自动跳过并计数，不影响其他源正常导入。
</details>

<details>
<summary><b>下载的视频能在别的播放器里播吗</b></summary>

不能。下载内容存在应用沙箱内，只能在应用内的「下载管理」里离线播放。
卸载应用会一并删除。
</details>

<details>
<summary><b>切换主题没反应</b></summary>

应用级 `setColorMode` 的语义限制，部分界面需要**重启应用**后才完全生效。
</details>

<details>
<summary><b>平板 / 折叠屏上布局很奇怪</b></summary>

应用已声明支持 `phone` / `tablet` / `2in1` / `tv`，并做了响应式列数适配。
如果遇到具体问题，欢迎提 [Issue](../../issues) 并附上设备型号与截图。
</details>

<details>
<summary><b>构建报错 <code>spawn java ENOENT</code> 或 <code>00308018</code></b></summary>

用命令行构建时，hvigor 打包阶段会 spawn 裸 `java`，不读 `JAVA_HOME`。
必须把 JDK 的 `bin` 目录加进 `PATH`：

```powershell
$env:DEVECO_SDK_HOME = "<DevEco>/sdk"
$env:JAVA_HOME       = "<DevEco>/jbr"
$env:PATH            = "<DevEco>/jbr/bin;" + $env:PATH
```

用 DevEco Studio 图形界面构建不会遇到这个问题。
</details>

<details>
<summary><b>构建报错 <code>HO_API_VERSION_VALIDATE_FAILED</code></b></summary>

`build-profile.json5` 里的 `compileSdkVersion` / `compatibleSdkVersion` 必须是
**字符串** `"26.0.0"`，不能写成数字 `26`。
</details>

---

## 🔨 从源码构建

### 环境要求

| 项 | 要求 |
|---|---|
| IDE | DevEco Studio（支持 API 26 工程模型，2026 版） |
| SDK | HarmonyOS SDK API 26 |
| 运行时 | HarmonyOS NEXT / OpenHarmony API 26+ 真机或模拟器 |
| Node | 18+（hvigor 需要） |

### 命令行构建

```powershell
$env:DEVECO_SDK_HOME = "D:\Program Files\Huawei\DevEco Studio\sdk"
$env:JAVA_HOME       = "D:\Program Files\Huawei\DevEco Studio\jbr"
$env:PATH            = "D:\Program Files\Huawei\DevEco Studio\jbr\bin;" + $env:PATH

node "<DevEco>\tools\hvigor\bin\hvigorw.js" `
     assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
```

产物：`entry/build/default/outputs/default/entry-default-signed.hap`

> **版本号是自动的**：打包前会先跑 `scripts/version.js`，源码（`entry/src/main`）有改动就
> 把版本号末位 +1。**每一位最大是 9，超过就归零并向左进一位**：
> `1.1.8 → 1.1.9 → 1.2.0`、`1.9.9 → 2.0.0`。
> 同一份代码重复打包不会虚增。
> 唯一写版本号的地方是 `AppScope/app.json5`，界面两处都运行时读取它。
> 只看不改：`node scripts\version.js --print`；
> 手动设成指定值（顺带记下当前源码指纹）：`node scripts\version.js --set 1.2.0`。

### 项目没有第三方依赖

`oh-package.json5` 的 `dependencies` 是空的，首次同步很快。
所有能力（HTTP、Preferences、AVPlayer、gzip、M3U 解析、XMLTV 解析）
都是基于系统 Kit 或自己实现的，没有 npm 包。

### 深入

- 工程结构、模块划分 → [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- 签名四件套、AGC 上架、27 项功能测试清单 → [TESTING_AND_RELEASE.md](TESTING_AND_RELEASE.md)
- 源兼容性、网盘接入、线路选择可行性分析 → [docs/FEASIBILITY.md](docs/FEASIBILITY.md)
- 零基础 GitHub 发布全流程（注册 → 建仓 → 认证 → 推送 → 装修 → 发 Release） → [docs/OPEN_SOURCE_RELEASE.md](docs/OPEN_SOURCE_RELEASE.md)
- 用 GitHub Desktop 上传改动（装软件 → 提交 → 推送 + 脱敏自查清单） → [docs/GITHUB_DESKTOP_GUIDE.md](docs/GITHUB_DESKTOP_GUIDE.md)

---

## 🤝 参与贡献

欢迎 Issue 和 PR。提交前请确认：

- [ ] `hvigorw assembleHap` 能过（0 编译错误）
- [ ] 没有提交 `build-profile.json5` 里的签名信息（`git diff` 自查）
- [ ] 新增的资源图标**同时**放在 `resources/base/media/` 和 `resources/dark/media/` 下
- [ ] 没有引入第三方依赖（本项目刻意保持零依赖）

### 对新增源的建议

提交 PR 增加内置推荐源时，请先在本地跑通「搜索 → 详情 → 播放」全链路，
并在 PR 里说明测试时间。采集站失效很快，我们不希望推荐源列表变成一堆死链。

### 欢迎补充

README 目前缺一张**播放页截图**（作者手上没有干净的截图素材）。
如果你在用这个项目，截一张播放界面（手机横屏、控制栏展开）提到
`docs/screenshots/player.png`，我们会很感激。

---

## ⚠️ 免责声明

- 本项目是 **LibreTV 的第三方鸿蒙移植实现**，与 LibreTV 项目组**无隶属关系**，未获其官方背书。
- 本项目**不提供、不托管、不分发任何音视频内容**。所有内容均来自用户自行添加的第三方采集站。
- 本项目**不内置任何默认源**。代码中出现的推荐源列表仅是公开采集站的技术示例，
  不构成对任何内容的推荐或授权。
- 使用本项目抓取、播放、下载的任何内容，其**合法性由源方与使用者自行负责**。
  请遵守你所在地区的法律法规与版权规定。
- 本项目仅供**个人学习与技术研究**使用，**请勿用于商业用途**。
- 因使用本项目产生的一切直接或间接后果，由使用者自行承担，作者不承担任何责任。

如果你认为本项目侵犯了你的权益，请提 Issue 联系，我们会及时处理。

---

## 📄 License

[**GNU Affero General Public License v3.0**](LICENSE) —— 与上游 LibreTV 保持一致。

这意味着：你可以自由使用、修改、分发本项目，但**必须**：

- 保留原始版权声明与许可声明
- 以相同协议（AGPL-3.0）开放你的修改
- 如果你把它部署成网络服务供他人使用，**也必须**公开源代码

---

<div align="center">

如果这个项目对你有帮助，点个 ⭐ Star 是这个仓库活下去的动力。

</div>
