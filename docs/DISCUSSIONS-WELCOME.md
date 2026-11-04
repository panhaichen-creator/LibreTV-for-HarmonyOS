<!-- 粘贴用：标题填「👋 欢迎来到 LibreTV for HarmonyOS」，分类选 Announcements，发布后 Pin 置顶。
     本注释在 GitHub 上不渲染，整篇复制即可。 -->

这里是 **LibreTV 鸿蒙原生客户端**的讨论区：报问题、提想法、晒你的界面改造，都在这里。

先把最重要的一句放在前面——**这个项目不提供任何片源**。它是一个播放器客户端（HarmonyOS NEXT 原生 ArkTS 写的），
片源由你自己在「我的 → 视频源管理」里添加。把这句话记住，后面的规则就好理解了。

## 这个项目是什么

| | |
| --- | --- |
| 形态 | HarmonyOS NEXT 原生应用（ArkTS / ArkUI），不是套壳网页 |
| 支持系统 | API 26 及以上 |
| 片源 | **不内置**，首次使用需自行添加点播源（Apple CMS V10）与直播源（M3U / TXT） |
| 安装包 | Release 里是**未签名** HAP，需用自己的证书重签后安装 |
| 版本号 | 每次源码有实质改动自动递增（现在到 v1.9.8），所以版本号看着跳得快是正常的 |

## 这里可以聊什么

- **🙏 Q&A** —— 装了打不开、某个片源连不上、下载卡住、播放黑屏……求助贴发这里
- **💡 Ideas** —— 想要的功能、觉得别扭的交互，先说清楚「现在怎样、希望怎样」
- **🙌 Show and tell** —— 改配色、换图标、做主题、跑在平板/车机上，欢迎晒图
- **📣 Announcements** —— 新版本、已知问题、计划，由维护者发布
- **💬 General** —— 其它任何相关话题

## 这里不要做的事

以下几条会**直接关闭讨论**，请别试：

1. **求片源、发片源、发影视资源链接**（磁力、网盘、订阅地址都算）。
   这个项目是播放器，不是资源站，贴上来只会让仓库消失。
2. 讨论怎么绕过版权保护、付费墙、地区限制。
3. 贴出带个人信息的日志：设备序列号（UDID）、MAC、华为账号、证书密码、
   `build-profile.json5` 里的 `storePassword` / `keyPassword`。**发之前先打码。**
4. 只写「不能用」「闪退」四个字——没人能凭这句话定位问题，请用下面的模板。

## 提问前先自查这五项

| 项 | 在哪看 |
| --- | --- |
| 版本号 | 「我的 → 关于」，形如 `v1.9.8` |
| 设备与系统 | 例如 `Pura 80 Ultra / HarmonyOS 6.0.x / API 26` |
| 问题在哪条链路 | 点播 / 直播 / 下载 / 离线播放 / 纯界面 |
| 用的是哪类源 | Apple CMS V10、M3U、订阅 JSON，或「一键导入推荐源」——**具体域名可打码** |
| 能不能稳定复现 | 每次都这样 / 偶发 / 只出现过一次 |

## 提问模板（复制这段，填空即可）

```text
版本：v1.9.8
设备 / 系统：
问题类型：点播 / 直播 / 下载 / 播放 / 界面
用的哪类源：（CMS V10 / M3U / 订阅 JSON / 未添加）
复现步骤：
1.
2.
3.
期望结果：
实际结果：
截图或日志：（记得打码）
```

## 先看这几条已知限制，能省一轮往返

| 现象 | 原因 | 怎么办 |
| --- | --- | --- |
| 微信里点分享链接，没直接打开 App | 微信只放行自家白名单协议，内置浏览器禁止跳转自定义 scheme | 点右上角 `···` → **在浏览器打开**，会自动播放 |
| 分享到微信的卡片没有「一影片一封面」大图 | 需要服务端按影片参数动态渲染分享页，静态托管做不到 | 当前版本不做 |
| Release 里的 HAP 装不上 | 那是**未签名**包，系统拒绝 | 用你自己的证书重签 |
| 搜索什么都是空 | 没有内置片源 | 先添加点播源，或点「一键导入推荐源」 |
| 直播频道点开没画面 | 直播源本身失效（M3U 里的地址经常过期） | 换源，或在源管理里点「探测」看健康度 |

## 关于片源与合规

这个仓库只包含**客户端代码**：不含片源、不做资源搜索代理、不维护订阅地址列表。
你添加什么源、用它看什么内容，由你自己负责，与本项目无关。

讨论区里出现资源分享时，维护者会直接删除，不另行解释——
这不是不近人情，是保住这个仓库唯一可行的做法。

## 想贡献代码

- 动手前先开一条 **Ideas** 或 **Q&A**，把方向对一下，避免写完发现不合适。
- 构建方式见 [README](https://github.com/panhaichen-creator/LibreTV-for-HarmonyOS/blob/main/README.md)
  与 [TESTING_AND_RELEASE](https://github.com/panhaichen-creator/LibreTV-for-HarmonyOS/blob/main/TESTING_AND_RELEASE.md)；
  注意本机必须用 DevEco 内置的 hvigor 与 node，且签名配置不进仓库。
- 改文案、调间距、补图标这类「小 PR」一样欢迎，不必憋大招。
- 提交前请确认没有把自己的证书、桌面路径、本机品牌名带进去。

## 最后

中文为主，English is welcome too。提问不必客气，但请把信息写全——
**把「怎么复现」讲清楚，比说十句「很好用」更能帮到这个项目。**

维护者也是业余时间在做这个项目，回复可能不及时，见谅。

---

### 🇬🇧 In short (English)

**LibreTV for HarmonyOS** is a native HarmonyOS NEXT player client (ArkTS), API 26+.
It ships **no content sources** — you add your own (Apple CMS V10 endpoints or M3U playlists)
under *Mine → Sources*. Release assets are **unsigned** HAPs: re-sign them with your own certificate.

- Bugs / errors → **Q&A**, wishes → **Ideas**, screenshots and themes → **Show and tell**.
- Please **do not** ask for or share sources, streams, magnets or cloud-drive links.
- When reporting, include: app version, device + OS build, playback type (VOD / live), the kind
  of source you used (mask the domain), and reproduction steps.
- Known: WeChat blocks custom URL schemes in its in-app browser — use *··· → Open in browser*
  to make shared links launch the app.
