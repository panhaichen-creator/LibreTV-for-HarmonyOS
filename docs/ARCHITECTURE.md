# 架构与实现要点

面向想读懂 / 二次开发本项目的人。只想装来用的话，看 [README](../README.md) 就够了。

---

## 一、工程结构

```
LibreTV-HarmonyOS/
├── AppScope/
│   ├── app.json5                          # bundleName: com.libretv.harmonyos
│   └── resources/base/{element,media}     # 应用级字符串 / 图标
├── build-profile.json5                    # 版本号为字符串 "26.0.0"（数字格式会报 HO_API_VERSION_VALIDATE_FAILED）
├── hvigor/
│   ├── hvigor-config.json5                # modelVersion "26.0.0"（须与根 oh-package.json5 一致）
│   └── hvigor-wrapper.js                  # 占位空文件（与官方模板一致）
├── hvigorfile.ts                          # system: appTasks（@ohos/hvigor-ohos-plugin）
├── oh-package.json5                       # modelVersion "26.0.0" + AGPL-3.0
├── code-linter.json5                      # Code Linter 规则
├── LICENSE                                # AGPL-3.0 全文
├── docs/                                  # 文档与截图
└── entry/
    ├── build-profile.json5                # apiType: stageMode / runtimeOS: HarmonyOS
    ├── oh-package.json5
    └── src/main/
        ├── module.json5                   # 权限（INTERNET / GET_NETWORK_INFO / CAMERA）、deviceTypes
        ├── resources/
        │   ├── base/
        │   │   ├── element/{string,color}.json
        │   │   ├── media/                 # PNG 图标（浅色主题）
        │   │   └── profile/network_config.json   # cleartextTrafficPermitted（支持 http:// 采集站）
        │   └── dark/                      # 深色主题（颜色 + 反色图标，两套必须同步改）
        └── ets/
            ├── entryability/EntryAbility.ets     # 初始化存储/源/下载，应用主题
            ├── pages/                            # 9 个页面
            │   ├── IndexPage.ets                # 主页面（首页/直播/我的三 Tab + 路由表）
            │   ├── SearchResultPage.ets         # 聚合搜索
            │   ├── DetailPage.ets               # 详情/选集/换源/下载
            │   ├── PlayerPage.ets               # 点播播放器（全屏）
            │   ├── LivePlayerPage.ets           # 直播播放器
            │   ├── HistoryPage.ets              # 播放历史 / 收藏
            │   ├── SourcesPage.ets              # 视频源管理 / 订阅导入导出 / 扫码导入
            │   ├── DownloadsPage.ets            # 下载管理
            │   └── SettingsPage.ets             # 设置
            ├── components/CommonWidgets.ets     # 通用 UI 组件
            ├── player/
            │   ├── AvPlayerController.ets       # AVPlayer 封装（倍速/seek/状态/缓冲）
            │   ├── VideoSurface.ets             # XComponent(SURFACE) 画面容器
            │   └── PlayUrlResolver.ets          # 直链 / fd:// / 本地回环 决策 + 防盗链头
            ├── model/                           # 纯逻辑层（可单测，不碰 UI）
            │   ├── Types.ets                    # 全局类型 + DEFAULT_SETTINGS
            │   ├── CmsClient.ets                # Apple CMS V10 客户端
            │   ├── M3uParser.ets                # M3U/M3U8 直播列表解析
            │   ├── M3u8Rewriter.ets             # HLS 广告过滤重写器
            │   ├── SubscriptionParser.ets       # 订阅（LibreTV-SourceList / TVBOX）解析
            │   ├── XmltvParser.ets              # XMLTV 节目单解析
            │   ├── DoubanClient.ets / BangumiClient.ets   # 首页推荐
            │   ├── RecommendedSources.ets       # 一键导入的内置推荐源
            │   └── SearchService.ets            # 聚合搜索 + 换源测速
            ├── data/                            # 持久化层（Preferences）
            │   ├── Store.ets                    # Preferences 单例
            │   ├── SourceManager.ets            # 源 CRUD + 健康度 + URL 归一化
            │   ├── HistoryStore.ets             # 历史/收藏/搜索历史/直播收藏
            │   ├── SettingsStore.ets            # 应用设置
            │   └── DownloadManager.ets          # 下载任务管理
            ├── net/HttpClient.ets               # http 封装（自定义头 / gzip 自动解压）
            └── common/
                ├── Utils.ets                    # 时间/字节/URL/标题归一化
                ├── EventBus.ets                 # 跨页面数据变更事件
                └── Gzip.ets                     # 纯 ArkTS DEFLATE/gzip 解压（puff 算法移植）
```

页面导航使用 **Navigation + NavDestination**（单 `@Entry` + `pageMap` 路由表）。
`pushPath` 的参数必须先声明 interface 再传变量，否则报 `10605038`。

---

## 二、实现要点

### 1. HLS 广告过滤（`M3u8Rewriter.ets`）

Web 版用 hls.js 在内存里改写播放列表；AVPlayer 没有注入点，所以改成
「自己拉 m3u8 → 过滤 → 落盘 → 交给播放器」：

```
拉取 m3u8 → 主列表选最高码率变体 → 按 DISCONTINUITY 切 run
  宽松：整组分片均 < 5s → 丢弃该组（典型广告插槽）；无 DISCONTINUITY 时退化丢 < 1s 分片
  严格：丢弃所有 < 3s 分片
  → KEY/MAP 状态补发、URI="..." 绝对化 → 写沙箱，保持 fd 打开
  → playUrl = http://127.0.0.1:<port>/index.m3u8（本地回环，见第 6 节）
```

### 2. gzip 解压（`Gzip.ets`）

`@ohos.zlib` 在 API 26 上没有可靠的同步 gunzip，因此移植 zlib `puff.c` 的 DEFLATE 实现
（BitReader / HuffmanTable / stored + fixed + dynamic 块），用于 XMLTV `.xml.gz` 节目单
与 `Content-Encoding: gzip` 响应。

### 3. 防盗链

`PlayUrlResolver.headersFor(url)` 生成桌面 UA + 站点 Referer，
经 `media.createMediaSourceWithUrl(url, headers)` 注入。
本地回环播放时，同一组 headers 由回环服务器转发给上游 `.ts` 请求。

### 4. 明文 HTTP

`network_config.json` 里 `cleartextTrafficPermitted: true`。
原因很实际：大量可用采集站只提供 `http://`，关掉就少一半源。

### 5. 源健康度

`SourceManager.recordFailure`：连续失败 2 次停 30 分钟、3 次停 24 小时、5 次长期停用；
搜索时自动跳过停用源，成功后清零恢复。设置页有「恢复健康度」按钮一键清零。

### 6. 离线 / 本地资源播放：只能走回环 HTTP

这是本项目踩坑最多的地方。AVPlayer 读不到应用沙箱里的文件，三条路都试过：

| 方案 | 结果 |
|---|---|
| m3u8 + 沙箱分片（`file://` 或裸绝对路径） | `5400103 IO Error` |
| `fd://` 指向整文件 | `5400106 CONTAINER_ERR`（fd 无文件名，判断不出容器） |
| `file://` 指向整文件 | 连 `initialized` 都过不去 |

可行解：分片合并成 `video.ts` → 起 `@kit.NetworkKit` 的 **TCPSocketServer**
（只听 `127.0.0.1`，实现 Range / 206）→ 用 `http://127.0.0.1:<port>/media.ts` 播放。
注意 `playUrl` **不要**设 mime（`AVMimeTypes` 只有 `APPLICATION_M3U8`，设了会报 Invalid M3U8）。

### 7. AVPlayer 调用顺序（硬约束）

顺序错了不会抛异常、UI 也没提示，只会表现为「进度永远 00:00 / 没画面」：

```
createAVPlayer → 立刻注册事件 → setMediaSource → 等 initialized → 设 surfaceId → prepare → play
```

- 在 **idle** 态设 `surfaceId` 报 `5400102`，且此时事件还没注册，错误**不会**冒泡到 `onError`
  （日志只打 `can not find error callback!`）。
- `setVolume` 同样只能在 prepared 之后调；控制器里先存 `volume` 字段，到 prepared 再补上。
- `player.off('stateChange', 临时回调)` 会**连带卸掉主回调**，用完必须重新注册。
  所以等待状态统一用 `waitForState()` 轮询（30ms 间隔），不要在 `stateChange` 里串 async。

### 8. 滚动位置保持

详情页返回首页要回到原来的位置。三件事一起做才稳：
`onAreaChange` 高度增量补偿（列表变高会把偏移夹回）+ `onScrollStop` 记录 +
返回时 80ms / 350ms 两次 `scrollTo`（首帧布局还没稳定）。

### 9. 深浅主题双套资源

`resources/base/media` 与 `resources/dark/media` 是**两套并列**的 PNG。
同名图标必须两边一起换，否则会出现「浅色端更新了、深色端还是旧图」这种只在单端复现的问题。
PNG 不支持 `fillColor` 染色，所以不能靠主题自动适配；需要染色的图标一律用 SVG
（如 `ic_back_top.svg`、`ic_player_*.svg`），配合 `.fillColor($r('app.color.color_text'))`。

---

## 三、数据源约定

- **点播源必须是 Apple CMS V10**：`站点根 + /api.php/provide/vod/?ac=list|videolist|detail`。
- **URL 必须归一到站点根**。订阅里地址形态很杂（带查询串、带子路径、带 `?wd=`），
  `SourceManager.normalizeApiUrl` 统一剥掉 `/api.php/provide/vod` 及其后内容，
  否则 `CmsClient` 二次拼接会造出报废 URL —— 症状是「电脑端能播、APP 不能播」。
- 部分 Apple CMS 克隆会**忽略 `ids` 参数**直接返回最新列表，
  所以详情接口必须校验 `vod_id` 回显，否则点任何影片都显示同一条。
- 应用**不内置任何种子源**。首次安装是空的，需要自己添加或点「一键导入推荐源」。

---

## 四、平台能力边界：spider 源不支持

TVBox 生态里的 `type: 3` / `api: "csp_xxx"` 源是 **spider 引擎**：
宿主用 Android 的 `DexClassLoader` 加载订阅根 `spider` 字段指向的 JAR
（常伪装成 `.png;md5;<md5>`）。HarmonyOS NEXT 没有 JVM / ART，**无法执行**。
JS 型 spider 也不可行 —— 它依赖 TVBox 专有宿主 API（`req` / `pdfh` / `pdfa` / `joinUrl`），
不是标准 JS 运行时能补的。

因此 `SubscriptionParser` 遇到 `type===3`、`csp_*`、`.jar|.js|.py` 会直接
`markSkip('Spider 引擎')` 并在导入结果里计数提示。这是**设计上的明确不支持**，不是 bug。

---

## 五、与 LibreTV Web 版的实现差异

平台约束所致，非功能缺失：

1. **HLS 广告过滤**：Web 版在内存里改写；原生端落盘 + 回环播放（见上）。
   过滤规则与 Web 版一致。
2. **下载缓存**：Web 版存 IndexedDB；原生端存应用沙箱（`filesDir/downloads/<任务 id>/`），
   完成后生成本地播放列表，可离线播放。
3. **直播流不重写**：直播 m3u8 是滑动窗口，本地重写会导致列表停止刷新，
   因此直播直链播放，由 AVPlayer 原生刷新。
4. **横屏播放**：通过 `window.setPreferredOrientation` 切换。
5. **主题切换**：应用级 `setColorMode` 语义，重启后完全生效。
