# 用 GitHub Desktop 上传修改（零基础版）

> 这份文档假设你**从没用过 Git**，也**没敲过命令行**。
> 照着做就行：每一步都写清楚了「点哪里、看到什么、如果不对怎么办」。
>
> 适用仓库：`<你的本地仓库目录>\LibreTV-HarmonyOS`

---

## 0. 先花 1 分钟认识三个词

不用记命令，只要知道它们在说什么：

| 词 | 大白话 | 类比 |
| --- | --- | --- |
| **仓库（Repository）** | 一个被 Git 管起来的项目文件夹，它记得每一次改动 | 带历史的文件夹 |
| **提交（Commit）** | 给「这一批改动」拍一张快照，先存在你自己的电脑上 | 存档 |
| **推送（Push）** | 把本地这些快照传到 GitHub 网站上 | 上传存档 |

整件事的流程就是：

```
改代码  →  脱敏（很重要）  →  提交（存本地）  →  推送（传到 GitHub）
```

**关键认知**：提交和推送是**两步**。只提交不推送，GitHub 网页上什么都看不到。
很多人卡在「我明明提交了，网页怎么没变」，就是漏了推送。

---

## 1. 一次性准备（只做一次，约 10 分钟）

### 1.1 注册 GitHub 账号

已经有账号就跳过。

1. 打开 <https://github.com>
2. 点右上角 **Sign up**
3. 填邮箱 → 设密码 → 起用户名 → 收邮件验证

> 用户名会成为网址的一部分，建议用英文，例如 `panhaichen-creator`。

### 1.2 安装 GitHub Desktop

1. 打开 <https://desktop.github.com>
2. 点 **Download for Windows**
3. 双击下载好的安装包，一路 **Next / Install**
4. 装完打开，第一次会让你登录

### 1.3 登录

1. 打开 GitHub Desktop
2. 菜单 **File → Options…**（中文系统可能是 **文件 → 选项**）
3. 左侧选 **Accounts**
4. 点 **Sign in to GitHub.com**
5. 浏览器会弹出来 → 点 **Authorize desktop** → 回到 GitHub Desktop

> 看到右上角出现你的头像，就成功了。

---

## 2. 一次性把本地文件夹接进来（只做一次）

### 2.1 添加本地仓库

1. 菜单 **File → Add local repository…**
2. 点 **Choose…**，选中这个文件夹：

   ```
   <你的本地仓库目录>\LibreTV-HarmonyOS
   ```

   ⚠️ **必须选到 `LibreTV-HarmonyOS` 这一层**。选到它的上一层（`2026-10-16-15-38-25`）会认不出来，
   因为 `.git` 隐藏文件夹在 `LibreTV-HarmonyOS` 里面。

3. 点 **Add repository**

### 2.2 这时你会看到两种情况之一

**情况 A：上方出现 `Push origin` 按钮**

说明本地已经连上了 GitHub 上的仓库，直接跳到第 3 节。

**情况 B：提示 `This directory does not appear to be a Git repository`**

说明选错文件夹了，回到 2.1 重选。本项目已经有 `.git`，正常情况下不会出现这个提示。

**情况 C：上方出现 `Publish repository` 按钮**

说明本地还没连远程仓库（GitHub 上还没有这个项目）。

1. 点 **Publish repository**
2. **Name** 填 `LibreTV-HarmonyOS`（这就是网址里的名字）
3. **Description** 填一句：`LibreTV 鸿蒙原生客户端：点播 / 直播 / 离线下载`
4. **Keep this code private**：
   - **不勾** = 公开仓库，所有人都能看到（开源项目选这个）
   - **勾上** = 私有仓库，只有你自己能看
5. 点 **Publish repository**

> 本项目本地已经配好了远程地址
> （`https://github.com/panhaichen-creator/LibreTV-...git`），
> 所以正常情况下你看到的是**情况 A**。

---

## 3. 每次上传的固定动作（4 步，约 2 分钟）

以后每次改完代码，都是这四步。**第 1 步千万别跳。**

### 第 1 步：脱敏（30 秒，最重要）

**为什么要做**：这个项目里有两种东西**绝对不能**传到 GitHub ——

| 绝对不能提交 | 为什么 |
| --- | --- |
| `build-profile.json5` 里的 `signingConfigs` | 里面是你的**证书路径 + 口令**，等于把家门钥匙公开 |
| `.ohos/`、`*.p12`、`*.cer`、`*.p7b` | 签名证书本体 |
| `dev/` 目录 | 本机调试脚本、截图、体检报告 |
| `entry/build/`、`*.hap` | 打包产物，几十 MB，没意义 |
| 应用图标里的品牌字母 | 图片**扫不出来**，只能人眼看。仓库自带的是通用播放图标 |

**操作**：双击这个文件

```
<你的本地仓库目录>\LibreTV-HarmonyOS\dev\_local_signing\use-opensource.cmd
```

看到窗口打印 `[完成] build-profile.json5 已改为 signingConfigs: []` 就可以了，按任意键关闭。

> **找不到这个文件时**：桌面上也放了一份带绝对路径的副本 **`LibreTV-上传前脱敏.cmd`**，
> 双击那个效果一样（配套的 `LibreTV-切回签名版.cmd`，用于装机测试前切回去）。

> **为什么要双击 .cmd 而不是 .ps1**：Windows 默认禁止运行 PowerShell 脚本，
> 双击 `.ps1` 会报「在此系统上禁止运行脚本」。`.cmd` 没有这个限制。
>
> **实测替代方案**（不想双击脚本时）：用记事本打开 `build-profile.json5`，
> 确认 `"signingConfigs": []` 是空的；如果里面有一大段 `"material": {...}`，把整段删掉换成 `[]`。

脱敏后，**再花 10 秒确认一遍** GitHub Desktop 左侧的 Changes 列表：

- [ ] 列表里**没有** `dev/` 开头的文件
- [ ] 列表里**没有** `.p12` / `.cer` / `.p7b` / `.ohos`
- [ ] 列表里**没有** `.hap` / `build/`
- [ ] 点开 `build-profile.json5`，右侧绿色新增里**没有** `password` 字样
- [ ] 看一眼 `app_icon.png` 的缩略图，图标里**没有**品牌字母（想换回自己的图标：`python scripts/make-app-icon.py --write` 前改常量，或直接覆盖那张 PNG）

只要有一项不对，**先别提交**，回到上面重新脱敏。

### 第 2 步：看改动（Changes 面板）

脱敏完成后，GitHub Desktop 主界面长这样：

```
┌──────────────────────────────────────────────────────────┐
│  Current Repository   LibreTV-HarmonyOS                  │
│  Current Branch       main                               │
├───────────────────────┬──────────────────────────────────┤
│ Changes  3            │  @@ -1,3 +1,4 @@                 │
│ ☑ entry/.../IndexPage │  - rowValue: 'v1.0.0',           │
│ ☑ AppScope/app.json5  │  + rowValue: AppVersion.display()│
│ ☑ README.md           │                                  │
│                       │  （右边是红色删除 / 绿色新增）      │
├───────────────────────┴──────────────────────────────────┤
│ Summary: ______________________________________________  │
│ Description: __________________________________________  │
│                        [ Commit to main ]                │
└──────────────────────────────────────────────────────────┘
```

- **左侧数字** `Changes 3` = 有 3 个文件改了
- **点任意文件名** → 右边显示具体改了哪几行（红色是删掉的，绿色是新加的）
- **文件前面的 ☑** 取消勾选 = 这次不提交这个文件（文件还留在硬盘上，只是不进这次快照）

> 如果左侧显示 **`0 changed files`**，但你觉得明明改了东西 ——
> 那多半是改的文件被 `.gitignore` 忽略了（比如 `dev/`、`build/` 里的东西）。
> 这是**正常**的，那些文件本来就不该上传。

### 第 3 步：写一句说明

在左下角两个输入框里填：

| 框 | 填什么 | 例子 |
| --- | --- | --- |
| **Summary**（必填） | 一句话说清这次干了什么 | `fix: 我的页版本号改为运行时读取` |
| **Description**（可空） | 想多写就写，不想写留空 | `原来写死 v1.0.0，改版本号时会漏改` |

**推荐格式**（前面加个前缀，以后翻历史一眼能看懂）：

- `feat: 新增 XXX 功能`
- `fix: 修复 XXX 问题`
- `docs: 更新 XXX 文档`
- `chore: 调整 XXX 配置`

### 第 4 步：提交 + 推送

1. 点左下角的 **`Commit to main`** 按钮
   → 左侧 Changes 列表清空，说明快照存好了（**此时 GitHub 网页还没变**）
2. 点右上角的 **`Push origin`**
   → 等几秒，按钮变回 `Fetch origin`，说明上传完成
3. 打开 <https://github.com/panhaichen-creator> 刷新页面，能看到刚才的改动

> **只做了第 1 步会怎样**：改动只在你电脑上，GitHub 网页看不到，
> 别人也拉不到。所以「提交」和「推送」两步都要做。

---

## 4. 版本号不用你手动改（打包时自动进一位）

### 4.1 规则

**源码有改动 → 打包时版本号自动进一位；每一位最大 9，超过就归零并向左进一位**

```
1.1.6  →  1.1.7  →  1.1.8  →  1.1.9  →  1.2.0  →  1.2.1 ...
1.9.9  →  2.0.0
```

也就是像里程表一样逐位滚动，末位不会出现 `1.1.10` 这种两位数。

判断依据是 `entry/src/main` 下文件的内容有没有变（做的是内容哈希，改一个字就算变）。
**同一份代码重复打包不会虚增版本号** —— 否则一天打三次包就变成 1.0.9 了，版本号就没意义了。

### 4.2 谁在改

| 文件 | 作用 |
| --- | --- |
| `AppScope/app.json5` | **唯一**写版本号的地方（`versionName` / `versionCode`） |
| `scripts/version.js` | 计算源码指纹，有变化就把上面两个值 +1，两个 `oh-package.json5` 同步跟上 |
| `hvigorfile.ts`（项目根目录） | 构建一启动就调用上面那个脚本，早于配置读取 |

界面上的两处版本号（「我的」页的 `v1.1.0`、「关于」页的 `版本 1.1.0`）
**都不是写死的**，运行时从包信息读取（见 `entry/src/main/ets/common/AppVersion.ets`），
所以改一处就够了。

> 历史教训：这两个地方以前各写了一份字面量（`'1.0.0'` 和 `'v1.0.0'`），
> 发版时只改了 `app.json5`，结果「关于」页显示 1.0.5、「我的」页还挂着 v1.0.0，
> 而且不报任何错，只能靠用户截图发现。

### 4.3 你想手动看 / 手动调

在项目根目录打开 PowerShell（或让 WorkBuddy 代跑）：

```powershell
# 只看当前版本，不改任何文件
node scripts\version.js --print

# 强制进一位（源码没变也想出个新版本号时用）
node scripts\version.js --force

# 直接把版本号设成指定值（用于纠错，顺带记下当前源码指纹，不会再多进一位）
node scripts\version.js --set 1.2.0
```

**不要**在代码里手写版本号，也不要直接改「关于」页的文字 —— 那会覆盖掉自动机制。

### 4.4 `versionCode` 为什么是 1100002 这种怪数字

- `versionName`（1.1.0）是**给人看的**
- `versionCode`（1100010）是**给系统判断能不能覆盖安装的**，必须只增不减；
  手机装过 1100010，再装 1100009 会被系统拒绝（`INSTALL_FAILED_VERSION_DOWNGRADE`）

所以它每次 +1，而不是跟着版本名走。

---

## 5. 常见问题

<details>
<summary><b>Q1. 点 Push 报 <code>Authentication failed</code>（登录失败）</b></summary>

登录状态过期了。**File → Options → Accounts → Sign out**，再 **Sign in** 一次。

> GitHub 2021 年起**不允许用账号密码推送**，必须走浏览器授权登录。
> 如果你用命令行，要生成 Personal Access Token 当密码用；
> 用 GitHub Desktop 就没这个麻烦，它管的是 OAuth。
</details>

<details>
<summary><b>Q2. 点 Push 报 <code>Updates were rejected</code>（推送被拒）</b></summary>

说明 GitHub 上有你本地没有的新提交（比如你在网页上直接改过文件）。

1. 点 **Fetch origin**，再点 **Pull origin**
2. 如果提示冲突（conflict），选 **Use theirs** / **Use mine**，或手动打开文件改
3. 解决后重新 **Commit** + **Push**
</details>

<details>
<summary><b>Q3. 已经推上去了，才发现带了密码 / 证书，怎么办</b></summary>

**立刻按这个顺序处理**，不要只是「再提交一次删掉」，因为历史里还留着：

1. **先去改密码**：证书口令、华为账号密码全部换掉（这是最要紧的，历史清不干净就先失效它）
2. 本地删掉证书文件，确认 `.gitignore` 里已有 `*.p12` / `*.cer` / `*.p7b` / `.ohos/`
3. 如果仓库是**刚建的、没有别人在协作**，最省事的办法是：
   在 GitHub 网页上 **Settings → 最下方 Delete this repository** 删库重建，
   本地重新 `Publish repository`（历史一起删掉，干净）
4. 如果仓库已经有人用，需要改写历史（`git filter-repo`），这属于进阶操作，建议找懂的人处理
</details>

<details>
<summary><b>Q4. 能不能直接在 GitHub 网页上把文件夹拖进去上传</b></summary>

**不建议**，原因有两个：

1. 网页拖拽**不读 `.gitignore`** —— 你拖整个文件夹，`dev/`、`build/`、证书全都会传上去
2. 无法逐个确认改动，容易误传

本项目已经导出过一份干净压缩包（`git archive` 生成，只含被 Git 跟踪的文件）。
如果确实需要网页上传，用那份，**不要**直接拖项目文件夹。
</details>

<details>
<summary><b>Q5. 提交了但想反悔</b></summary>

- **刚提交、还没推送**：GitHub Desktop 左下角点 **Undo**，或右上 **History → 右键该记录 → Undo commit**
- **想丢弃某个文件的改动**：Changes 里右键该文件 → **Discard changes**（⚠️ 不可恢复）
- **已经推送了**：不要 `force push`，正确做法是**再提交一次**把它改回来
</details>

<details>
<summary><b>Q6. 提示「几十个文件都改了」，但我只改了一个</b></summary>

多半是换行符（CRLF / LF）差异。本项目已经有 `.gitattributes` 固定成 `text=auto eol=lf`，
正常情况下不会出现。如果还是出现：

1. GitHub Desktop 菜单 **Repository → Repository settings → Ignored files** 看一眼有没有漏
2. 关掉编辑器（DevEco / VS Code）重新打开再提交，避免编辑器自动转换换行符
</details>

<details>
<summary><b>Q7. 提示文件超过 100 MB</b></summary>

GitHub 单文件上限 100 MB。本项目已经把 `*.hap`、`build/`、`dev/` 都忽略了，
正常提交不会超。如果超了，说明你误提交了打包产物 —— 在 Changes 里取消勾选即可。
</details>

<details>
<summary><b>Q8. 提交后网页上找不到某个文件</b></summary>

被 `.gitignore` 忽略了，属于预期行为。打开项目根目录的 `.gitignore` 可以看到规则，
例如 `dev/`、`*.hap`、`.ohos/` 都不会上传。
</details>

---

## 6. 上传前 60 秒自查清单

每次都过一遍，全部打勾再点 `Commit to main`：

- [ ] 双击过 `dev\_local_signing\use-opensource.cmd`（或手动确认 `"signingConfigs": []`）
- [ ] Changes 列表里没有 `dev/`、`.ohos/`、`*.p12`、`*.cer`、`*.p7b`、`*.hap`
- [ ] `build-profile.json5` 的 diff 里没有 `password`、没有 `C:\\Users\\<你的用户名>`
- [ ] `app_icon.png` 是通用图标，图里没有品牌字母
- [ ] Summary 写清楚了这次改了什么（建议带 `feat:` / `fix:` 前缀）
- [ ] 点完 `Commit to main` 后，**又点了 `Push origin`**
- [ ] 打开 GitHub 网页刷新，能看到这次改动

---

## 7. 桌面客户端 ↔ 命令行 对照（看得懂别人说的命令就行）

| 想做的事 | GitHub Desktop | 命令行 |
| --- | --- | --- |
| 看改了哪些文件 | 左侧 Changes | `git status` |
| 看具体改了哪几行 | 点文件名看 diff | `git diff` |
| 把改动加入本次提交 | 勾选文件前的 ☑ | `git add <文件>` |
| 提交 | 填 Summary → **Commit to main** | `git commit -m "说明"` |
| 推送 | **Push origin** | `git push` |
| 拉取别人的改动 | **Fetch origin** → **Pull origin** | `git pull` |
| 看历史 | **History** 标签 | `git log --oneline` |
| 撤销未提交的改动 | 右键文件 → Discard changes | `git checkout -- <文件>` |

---

## 8. 一句话总结

> 改完代码 → 双击 `use-opensource.cmd` 脱敏 → 看 Changes 没有证书 → 写 Summary →
> **Commit to main** → **Push origin** → 网页刷新确认。

版本号不用管，打包时会自动进一位（每位最大 9，满 9 归零并向左进位）。
