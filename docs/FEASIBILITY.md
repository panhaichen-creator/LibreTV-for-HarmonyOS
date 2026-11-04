# LibreTV-HarmonyOS 功能扩展可行性分析

> 分析对象：① 视频源添加方式的兼容性扩展；② 网盘配置与扫码登录；③ 详情页点播线路选择。
> 结论基于当前代码实际结构（2026-10-18），标注了具体改造点和风险等级。

---

## 一、视频源添加方式扩展

### 现状

| 入口 | 位置 | 能力 |
|---|---|---|
| 手动添加 | `SourcesPage.addVodForm()` | 仅 Apple CMS V10 接口地址 |
| 订阅导入 | `SourcesPage.importForm()` | URL 拉取 / 粘贴文本，`SubscriptionParser` 已支持 LibreTV JSON 与 TVBox 配置（自动剥注释、尾逗号、跳过 spider） |
| 直播源 | `M3uParser.parse()` | 仅 `#EXTM3U` 格式，支持 `group-title` 与fallback分组 |

**缺口**：没有任何「本地文件」入口（只有粘贴文本）；直播 TXT 格式不认；点播侧没有直链列表型源。

### 1.1 本地文件导入（.m3u / .m3u8 / .json / .txt）—— 可行性 ★★★★★，工作量小

- 平台能力齐备：`@ohos.file.picker` 的 `DocumentViewPicker`，`DocumentSelectOptions.fileSuffixFilters`
  可限定后缀；picker 属用户授权式选取，**不需要申请任何存储权限**。读内容用 `fileIo.open` + `read`。
- 改造点（全部是增量，不动现有链路）：
  1. `SourcesPage.importForm()` 加「从本地文件导入」按钮 → picker → 读出文本；
  2. 新增 `SourceFormatSniffer.sniff(text)` 做内容嗅探分发（不靠后缀，靠内容，网盘转存/改名不会骗过它）：
     - 首个非空白字符为 `{` 或 `[` → 走现有 `SubscriptionParser.parse()`（JSON 订阅 / TVBox）；
     - 含 `#EXTM3U` 或 `#EXTINF` → 走 `M3uParser`（直播）；
     - 含 `,#genre#` 或形如 `名称,url` 的行 → TVBox 直播 TXT（见 1.3）；
  3. 复用现有 `applySubscription(text, '本地导入')` 回执与去重、上限逻辑。
- 风险与注意：
  - **编码**：`fileIo.read` 返回 ArrayBuffer；`@ohos.util.TextDecoder` 默认 UTF-8。
    老源站导出的 m3u 偶有 GBK，UTF-8 解出乱码时按「无法解析」提示，不做 GBK 兜底
    （TextDecoder 的 GBK 支持需实测，不可靠就明确报错，比静默乱码好）。
  - 大文件：直播源动辄几 MB，`readText` 一次载入可接受；超过 ~10MB 时给个「文件过大」提示。

### 1.2 直播源支持 TXT（TVBox 格式）—— 可行性 ★★★★★，工作量很小

`M3uParser` 增加一个 TXT 分支即可（几十行）：
```
央视频道,#genre#
CCTV1,http://…/1.m3u8
```
- `xxx,#genre#` → 开新分组；`名称,url` → 频道；空行分隔；保留 URL 后 `#` 后的备注剥离。
- `SubscriptionParser.parseTvbox` 里对 `type:0` 且 `.txt` 的直播条目目前是**直接跳过**
  （「非 M3U 直播」）——把这条分支改为「标记为 TXT 格式」，由加载时按内容嗅探决定用哪个解析器。
- 注意：TXT 里也混有 `m3u8://` 伪协议前缀，需要剥掉。

### 1.3 点播源支持 M3U 直链列表 —— 可行性 ★★★☆☆，中等规模

「用 m3u 当点播源」和现有模型**不兼容**：`VodSource` 是 CMS API（有搜索、分类、详情、分集），
m3u 列表只是「一批直链」，没有搜索也没有详情接口。若硬塞进现有类型，首页/搜索/详情全都要写特判。

建议做法：给 `VodSource` 加 `type: 'cms' | 'playlist'` 字段（默认 `cms`，存量数据迁移时补默认值）：
- `playlist` 源：加载时整表解析为条目数组，分页浏览；搜索退化为本地过滤（标题包含）；
  「详情页」直接由单条直链生成（单集、无简介）。
- 影响面：`SourceManager`（存取/健康度）、`SearchService`（聚合时跳过无搜索能力的源）、
  `IndexPage` 分类浏览、`DetailPage`（单集详情模板）。
- 结论：**可行，但建议排在直播 TXT 之后单独做一期**，不要和 1.1/1.2 捆绑。

### 1.4 其他主流添加方式

| 方式 | 依赖 | 评估 |
|---|---|---|
| 剪贴板识别 | `pasteboard`（已在用） | 简单：进 SourcesPage 时读剪贴板，发现 `http…` 且像配置链接时弹「检测到订阅链接」 |
| 扫码导入 | `@kit.ScanKit`（SDK 已带 `detectBarcode`/`customScan`） | 简单：扫 TVBox 二维码 → 得 URL → 走现有订阅导入；需要 `ohos.permission.CAMERA` |
| 局域网传源 | `LocalHttpServer`（已有 TCPSocket HTTP 雏形） | 中等：加一个 `POST /import` 接收配置文本；电脑浏览器访问即可投递 |
| TVBox type:3 spider（jar/py/js） | 需要执行引擎 | **继续不可行**。HarmonyOS 没有 dex/py 运行时，js 引擎也跑不动 TVBox 生态的爬虫约定。保持跳过并在导入回执里说明 |

---

## 二、网盘配置与扫码登录（百度 / 夸克 / UC）

### 总体判断

**百度：可行（官方 API 路线）。夸克 / UC：技术上可行，但不建议作为正式功能。**

三家的可用接口不是一回事，必须分开评估：

### 2.1 百度网盘 —— 官方开放平台

- 路线：注册「百度网盘开放平台」开发者 → 拿 AppKey/Secret → OAuth 2.0 授权（授权页自带扫码登录，
  WebView 打开即可，不需要自己做二维码轮询）→ `access_token`（30 天，`refresh_token` 续期）。
- 能拿到什么：`/xpan/file` 列目录、`/xpan/multimedia` 播放接口返回 302 到 CDN 直链（支持 Range，
  AVPlayer 可直接跟随）；文件搜索接口也有。
- 前提与成本：
  1. **开发者账号审核**是最大变量（实名 + 应用审核 + 接口配额申请），周期不可控；
  2. `HttpClient` 目前只有 GET，需要补 POST + `application/x-www-form-urlencoded`；
  3. token 续期、过期重登的存储与提示（`SettingsStore` 加字段即可）。
- 结论：**推荐做**。工作量大头不在代码在审核流程；接口契约稳定，一次接入长期可用。

### 2.2 夸克 / UC 网盘 —— 无官方 API，只有逆向路线

两家同属阿里系、接口结构相同（Alist / quark-auto-save 等社区项目已验证）：
- 登录：请求 `uop.quark.cn`（UC 为 `uop.uc.cn`）的二维码接口 → 显示二维码 → 轮询状态 →
  换取 cookie + 设备标识；后续所有请求带 cookie 和签名头。
- **二维码可以自己生成**：`@kit.ScanKit` 里有 `generateBarcode`，把登录 URL 画成码显示在设置页即可。

技术上 HarmonyOS 全部具备（http 请求可带 cookie/自定义头、可轮询），但有三个硬风险：

| 风险 | 说明 |
|---|---|
| **接口无契约** | 签名参数、设备指纹、风控随时变；社区项目平均几个月就要跟随改版一次，需要持续维护投入 |
| **合规 / 封号** | 违反网盘用户协议，账号有被限速/封禁风险，必须在 UI 明示 |
| **直链鉴权** | 大文件 302 到 CDN 后，**AVPlayer 不会把自定义 Cookie 透传给 302 的目标域名**，裸播会 403 |

第三点的解法恰好是本项目已有的能力：**用 `LocalHttpServer` 做本地回环代理**。
它现在就是个 TCPSocketServer（离线播放用，已实现 Range/206），扩展成
「带 Cookie/UA 的 Range 转发代理」后，AVPlayer 只认 `http://127.0.0.1:port/…`，
鉴权、防盗链、302 全部在代理层消化。这个代理对功能一、三也有复用价值。

结论：**可以做成「实验性功能」**（设置里单独分区 + 明确的风险提示 + 随时可能失效的免责说明），
不建议承诺为正式能力。若接受这个定位，三家实现可以共用一套 `CloudDriveClient`
抽象（`listDir / resolvePlayUrl / refreshToken`）+ 统一代理播放。

### 2.3 设置页与播放链路的落点

- `SettingsPage` 新增「网盘账号」分区：每家一张卡片（未登录 / 已登录·有效期 / 登出），
  扫码登录用 WebView（百度）或 `generateBarcode` + 轮询（夸克/UC）。
- `SourceManager` 的 `VodSource` 加 `type: 'netdisk'` 变体，浏览时按网盘目录树渲染。
- 播放：`PlayUrlResolver.resolve()` 增加 `netdisk` 分支 → 返回 127.0.0.1 代理地址。

---

## 三、详情页点播线路选择 —— 可行性 ★★★★★，工作量最小、收益直接

### 现状（关键发现）

`CmsClient.extractEpisodes()` **已经解析了 `$$$` 多线路结构**，但只保留一组：

```
vod_play_url: "线路1$https://a.m3u8#第2集$…$$$线路2$https://b.m3u8#…"
```

- 按 `$$$` 拆组、组内按 `#` 拆集 —— 都做了；
- 然后挑「含 m3u8 的第一组」返回，**其余组直接丢弃**；
- 线路名（`vod_play_from`，如「蓝光线路M3U8$$$/量子资源」）接口里有、`SearchItem.playFrom`
  字段也有，只是从未传到详情页。

也就是说这个功能的数据层已经完成 90%，纯粹是被主动丢掉了。

### 改造点

1. `CmsClient`：`extractEpisodes(playUrl)` → `extractLineGroups(playUrl, playFrom)`，
   返回 `PlayLine[]`（`{ name: string, episodes: Episode[] }`），保留全部非空组；
   「默认线路」逻辑沿用现有规则（优先含 m3u8 的组），只决定初始选中项。
2. `Types`：`DetailInfo` 加 `lines: PlayLine[]`；`PlayRecord` 加 `lineIndex?: number`。
3. `DetailPage`：选集标题旁加一行线路 chip（横滚，样式复用筛选 chip），切换后：
   - 重渲染选集列表；
   - **清空当前集选中态**（不同线路分集数/命名都不同）；
   - 续播记录按「源 + vodId + 线路」匹配，旧记录无 `lineIndex` 兜底 0；
   - 下载任务同样记录线路。
4. `PlayerPage` 基本不用动：它拿到的本来就是切好的一组 `episodes`。
5. `DetailCache`：缓存值结构变化，旧缓存直接判失效即可（首次会多一次请求，可接受）。

### 风险

低。唯一要注意的是**历史记录兼容**：旧 `PlayRecord` 没有 `lineIndex`，回填时要兜底，
否则「跨线路恢复进度」会错位到错误的集。

---

## 四、建议的实施顺序

| 期 | 内容 | 理由 |
|---|---|---|
| 第一期 | ③ 详情页线路选择 | 数据层已现成，改动面最小，用户感知最强 |
| 第一期 | ① 本地文件导入 + 直播 TXT | 纯增量、无权限、无接口依赖 |
| 第二期 | ① 剪贴板识别 / 扫码导入 | 依赖 `ScanKit` + 相机权限，独立好做 |
| 第二期 | ② 百度网盘（官方 API） | 前置：开发者账号审核，先启动流程 |
| 第三期 | ① m3u 点播列表源类型 | 需要新的源类型与多处 UI 分支 |
| 第三期 | ② 夸克 / UC（实验性） | 依赖本地代理重构 + 风险提示，放最后 |

**共同的前置重构**（做网盘前必须先做）：把 `LocalHttpServer` 从「只服务离线 m3u8」
泛化成通用本地代理（支持按 URL 注册转发规则、带自定义头、Range 透传）。
这一步同时解决网盘直链 Cookie、302 跟随、referer 防盗链三类问题。
