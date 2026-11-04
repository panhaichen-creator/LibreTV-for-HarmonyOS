# 开源发布全流程（零基础版）

> **前提**：你已经写完代码，现在要把 `LibreTV-HarmonyOS/` 这个文件夹放到 GitHub 上，让全世界能下载。
>
> **读者假设**：你从没在 GitHub 上发布过任何东西，也不知道 Token、SSH、remote 是什么。
> 本文会把每个按钮在哪、点完出现什么、下一步该做什么，一步步写清楚。

---

## 目录

- [第 0 步：先选一条路](#第-0-步先选一条路)
- [第 1 步：发布前体检（最重要）](#第-1-步发布前体检最重要)
- [第 2 步：注册并登录 GitHub](#第-2-步注册并登录-github)
- [第 3 步：在 GitHub 上创建一个空仓库](#第-3-步在-github-上创建一个空仓库)
- [第 4 步：在电脑上初始化本地仓库](#第-4-步在电脑上初始化本地仓库)
- [第 5 步：让电脑获得"推送权限"](#第-5-步让电脑获得推送权限)
- [第 6 步：把代码推上去](#第-6-步把代码推上去)
- [第 7 步：验证真的推上去了](#第-7-步验证真的推上去了)
- [第 8 步：装修仓库门面（About 和 Topics）](#第-8-步装修仓库门面about-和-topics)
- [第 9 步：发布 Release（让别人能下载）](#第-9-步发布-release让别人能下载)
- [第 10 步：以后怎么改东西（不用命令行）](#第-10-步以后怎么改东西不用命令行)
- [第 11 步：出错了怎么办](#第-11-步出错了怎么办)
- [附录 A：全网页操作（一点命令行都不碰）](#附录-a全网页操作一点命令行都不碰)
- [附录 B：用 GitHub Desktop 图形界面](#附录-b用-github-desktop-图形界面)
- [附录 C：合规红线](#附录-c合规红线)
- [附录 D：一页速查](#附录-d一页速查)

---

## 第 0 步：先选一条路

把代码传到 GitHub 有三种方式，**效果完全一样**，选一个适合你的就行：

| 路线 | 工具 | 适合谁 | 上手难度 |
|:---|:---|:---|:---|
| **A. 命令行** | `git` + PowerShell | 用惯了终端，或者想一次学会 | ★★★ |
| **B. GitHub Desktop** | 官方图形客户端 | **推荐新手**，点点鼠标就行 | ★ |
| **C. 全网页** | 浏览器 | 一点命令行都不想碰 | ★（但后续更新麻烦） |

**本文主线是 A**，因为命令可以直接复制粘贴，不需要找按钮。
如果你完全不想碰命令，直接跳到 [附录 B](#附录-b用-github-desktop-图形界面) 或 [附录 A](#附录-a全网页操作一点命令行都不碰)，
走完后再回来读第 8、9 步。

### 先装 git（走 A 路线才需要）

打开 PowerShell，输入：

```powershell
git --version
```

- **出现 `git version 2.xx.x`** → 已经装好了，跳过这节
- **出现红字 `无法将"git"项识别为...`** → 没装，去 <https://git-scm.com/download/win> 下载安装
  - 安装时一路点 **Next** 即可，**唯一要注意**：到 "Choosing the default editor" 那一步，
    建议选 **"Use Notepad as Git's default editor"**（默认的 Vim 新手退出不来）

装完**关掉 PowerShell 重新打开**，再 `git --version` 验证一次。

---

## 第 1 步：发布前体检（最重要）

这一步不做完，后面全白搭 —— 因为 **GitHub 的提交历史是删不掉的**。
签名密码一旦进了第一次提交，即使你之后改掉文件，任何人翻历史记录还是能看到。

> 好消息：本文对应的仓库 `LibreTV-HarmonyOS/` 已经替你做完这一步了。
> 如果你是拿自己的项目来做，请照着下面检查一遍。

### 1.1 确认签名信息已清空

打开 `build-profile.json5`，检查两件事：

```json5
{
  "app": {
    "signingConfigs": [],       // ← 必须是空数组，里面不能有 material

    "products": [{
      "name": "default",
      // ← 这里不能有 "signingConfig": "default" 这一行
      "compileSdkVersion": "26.0.0",
      ...
    }]
  }
}
```

用命令快速确认：

```powershell
Set-Location "路径\LibreTV-HarmonyOS"
Select-String -Path build-profile.json5 -Pattern 'signingConfig'
```

输出里应该只有 `"signingConfigs": []` 和注释里的示例文字，**不能有** `"certpath"`、`"keyPassword"`、
`"storePassword"`、`"C:\\Users\\..."` 这些东西。

> ⚠️ 如果 products 里还留着 `"signingConfig": "default"`，构建会报
> `signingConfig default not found`，一定要一起删掉。

### 1.2 扫一遍全仓库

在 PowerShell 里依次执行这三条，**输出都应该是空的**：

```powershell
Set-Location "路径\LibreTV-HarmonyOS"

# ① 有没有泄露本机路径 / 用户名
Get-ChildItem -Recurse -File -Include *.ets,*.ts,*.json5,*.json,*.md,*.ps1,*.py |
  Where-Object { $_.FullName -notmatch '\\build\\|\\\.hvigor\\|\\oh_modules\\' } |
  Select-String -Pattern 'C:\\\\Users|C:/Users'

# ② 有没有密钥类字段
Get-ChildItem -Recurse -File -Include *.ets,*.ts,*.json5,*.json,*.md |
  Where-Object { $_.FullName -notmatch '\\build\\|\\\.hvigor\\' } |
  Select-String -Pattern 'storePassword|keyPassword|apiKey|secret'

# ③ 有没有证书文件准备被提交
Get-ChildItem -Recurse -File -Include *.p12,*.cer,*.p7b,*.jks,*.keystore
```

第 ③ 条如果列出了文件，说明 `.gitignore` 没盖住，先把它们加进 `.gitignore`。

### 1.3 确认 `.gitignore` 生效

```powershell
Get-Content .gitignore
```

里面至少要有这些行（本项目已有）：

```gitignore
/build/
/entry/build/
.hvigor/
oh_modules/
*.hap
.ohos/
*.p12
*.cer
*.p7b
.idea/
local.properties
dev/
*.log
```

---

## 第 2 步：注册并登录 GitHub

> 已经有账号、且**验证过邮箱**的，可以跳到第 3 步。

### 2.1 注册

1. 浏览器打开 <https://github.com/signup>
2. 依次填写：
   - **Email**：你的邮箱（建议用常用邮箱，QQ 邮箱、163、Gmail 都行）
   - **Password**：至少 15 个字符，或至少 8 个字符且包含数字和小写字母
   - **Username**：用户名，会出现在你的仓库地址里（例如 `zhangsan` → `github.com/zhangsan/xxx`）
     - 只能用字母、数字、连字符 `-`，不能有空格
     - 想好再填，改起来麻烦
   - 邮箱验证码（会发到你邮箱）
3. 完成人机验证（拼图/选图）
4. 选 **Free**（免费版）—— 开源项目用免费版完全够

### 2.2 一定要验证邮箱

注册后会收到一封 GitHub 的邮件，**点里面的 "Verify email address" 按钮**。

> ❗ 不验证邮箱，后面可能出现「能建仓库但推不上去」「不能发 Release」这类莫名其妙的失败。
> 没收到邮件就去 <https://github.com/settings/emails> 点 **Resend verification email**。

### 2.3 顺便设置两件小事

在 <https://github.com/settings/emails> 页面：

- 勾选 **Keep my email addresses private** —— 这样你的真实邮箱不会出现在公开的提交记录里
- 页面下方会给你一个 `12345678+用户名@users.noreply.github.com` 形式的地址，
  **复制它**，第 4 步配置 git 时会用到

### 2.4 记住两个页面

| 页面 | 地址 | 用来干什么 |
|---|---|---|
| 你的主页 | `https://github.com/你的用户名` | 看自己所有仓库 |
| 新建仓库 | `https://github.com/new` | 建新仓库 |

---

## 第 3 步：在 GitHub 上创建一个空仓库

### 3.1 打开新建页面

浏览器访问 <https://github.com/new>
（也可以点右上角 **`+`** 号 → **New repository**）

### 3.2 逐项填写

页面从上到下是这样的，**照这个表填**：

| 字段 | 填什么 | 说明 |
|---|---|---|
| **Repository name** `*` | `LibreTV-HarmonyOS` | 仓库名。会变成网址的一部分 |
| **Description** | `LibreTV 的鸿蒙原生客户端 · ArkTS + ArkUI · HarmonyOS NEXT` | 一句话简介，可以不填，后面还能改 |
| **Public / Private** | 选 **Public** | 开源必须选 Public。Private 只有你自己能看 |
| **Add a README file** | ❌ **不勾** | 你本地已经有 README 了，勾了会冲突 |
| **Add .gitignore** | ❌ **不勾** | 同上，本地已有 |
| **Choose a license** | ❌ **不勾** | 同上，本地已有 LICENSE |

> 🔴 **这三个复选框是新手最大的坑。**
> 只要勾了任意一个，GitHub 就会在你的远程仓库里先放一个文件，
> 等你本地推上去时就会报 `Updates were rejected`（翻译：远程有你本地没有的东西，不让我覆盖）。
> 勾错了也不用慌，见 [第 11 步](#第-11-步出错了怎么办) 的对应条目。

### 3.3 点绿色的 "Create repository"

### 3.4 你会看到什么

一个几乎空白的页面，中间有一段 **"Quick setup — if you've done this kind of thing before"**，
下面是一堆 `git init`、`git remote add` 之类的命令。

**这是正常的** —— 仓库刚建好就是空的（只有一份 GitHub 自己生成的说明页）。

**先别关这个页面**，下面要用到它上面的仓库地址。

### 3.5 复制仓库地址

页面上有一个绿色按钮 **`< > Code`**（在 "Quick setup" 区域上方），点它：

- 弹出的框里，**HTTPS** 标签下有一行地址，形如：
  ```
  https://github.com/你的用户名/LibreTV-HarmonyOS.git
  ```
- 点右边的小方块图标 **复制**

把这个地址记下来，第 6 步要用。

> 如果找不到 Code 按钮，也可以直接手拼：
> `https://github.com/` + 你的用户名 + `/` + 仓库名 + `.git`

---

## 第 4 步：在电脑上初始化本地仓库

> 走 B（GitHub Desktop）或 C（全网页）路线的，跳过这一步，直接看附录。

### 4.1 进入项目文件夹

```powershell
Set-Location "C:\Users\你的用户名\WorkBuddy\...\LibreTV-HarmonyOS"
```

确认进对了 —— 执行下面这条，应该能看到 `AppScope`、`entry`、`README.md` 等：

```powershell
Get-ChildItem -Name
```

### 4.2 设置你的身份

**每条提交都会记录"谁改的"**，所以先告诉 git 你是谁：

```powershell
# 只用保护邮箱 —— 把下面两行换成你自己的
git config --local user.name  "张三"
git config --local user.email "12345678+zhangsan@users.noreply.github.com"
```

> `--local` 表示只对当前这个仓库生效，不会影响你电脑上的其他项目。
> 邮箱就用第 2.3 步复制的那串 `users.noreply.github.com` 地址；
> 嫌麻烦填真实邮箱也行，只是会公开。

### 4.3 初始化

```powershell
git init -b main
```

**你会看到**：

```
Initialized empty Git repository in C:/Users/.../LibreTV-HarmonyOS/.git/
```

意思是：在这个文件夹里建了一个"版本控制仓库"，主分支叫 `main`。
文件夹里会多出一个隐藏的 `.git` 目录，**别去动它**。

> 💡 如果报 `Reinitialized existing Git repository`，说明之前已经初始化过了，
> 不是错误，继续往下走就行。

### 4.4 把所有文件加入待提交队列

```powershell
git add -A
```

这个命令不会输出任何东西（没消息就是好消息）。

### 4.5 ★ 关键一步：审阅将要提交的文件清单

```powershell
git status --short
```

**你会看到一长串 `A  xxx` 的行**（`A` = Added，新增）。**必须逐项确认**：

- [ ] 没有 `*.p12` / `*.cer` / `*.p7b`（证书）
- [ ] 没有 `build/`、`.hvigor/`、`oh_modules/`（构建产物）
- [ ] 没有 `dev/`（开发过程杂物）
- [ ] 没有 `*.log`（日志）
- [ ] `build-profile.json5` **在**列表里（正常，它现在是脱敏版）
- [ ] `docs/screenshots/*.png` **在**列表里（正常，README 要用）
- [ ] 数量级合理 —— 本项目是 **122 个文件**。如果显示 3000+，说明 `.gitignore` 没生效

数一下有多少个：

```powershell
(git status --short | Measure-Object).Count
```

> 🔴 **数量明显偏多怎么办**：多半是 `.gitignore` 没保存或编码不对。
> 补救：`git rm -r --cached .` 然后重新 `git add -A`。

### 4.6 提交

```powershell
git commit -m "feat: LibreTV 鸿蒙原生客户端首个开源版本"
```

**你会看到**：

```
[main (root-commit) e46f897] feat: LibreTV 鸿蒙原生客户端首个开源版本
 122 files changed, 17380 insertions(+)
```

看到 `N files changed` 就成功了。这一步只是把文件"存进了本地的历史"，
**还没有传到 GitHub**。

---

## 第 5 步：让电脑获得"推送权限"

> 🔴 **这是新手最容易卡住的一步**，请耐心看完。

### 5.1 为什么不能用密码

GitHub 从 2021 年起就**禁止用账号密码推送**了。你如果直接 push，
会看到这样的报错：

```
remote: Support for password authentication was removed on August 13, 2021.
fatal: Authentication failed for 'https://github.com/...'
```

不是密码错了，是**这种方式本身被废除了**。解决办法有两个：Token 或 SSH。

### 5.2 先试最简单的：直接 push

现代版的 Git for Windows 自带一个叫 **Git Credential Manager** 的组件，
执行 `git push` 时它会**自动弹出浏览器窗口**让你登录 GitHub。

所以你先**直接跳到 [第 6 步](#第-6-步把代码推上去) 试一次**：

- ✅ **弹出浏览器 → 显示 "Sign in to GitHub" → 点 Authorize** → 说明你运气好，什么都配好了
- ❌ **命令行里提示 `Username for 'https://github.com':`** → 说明没装 GCM，回来配 Token

### 5.3 方案一：Personal Access Token（推荐）

Token 就是"一串代替密码的字符"，可以单独撤销，比密码安全。

#### ① 生成 Token

1. 登录 GitHub，点右上角**你的头像** → 菜单里点 **Settings**
2. 左侧菜单**拉到最底部** → 点 **Developer settings**
3. 左侧点 **Personal access tokens** → 再点 **Tokens (classic)**
4. 右上角点 **Generate new token** → 选 **Generate new token (classic)**
5. 可能会要求你输入密码确认身份，输一下
6. 填写表单：

| 字段 | 填什么 |
|---|---|
| **Note** | `LibreTV 本地推送`（随便写，只是备注） |
| **Expiration** | 选 **90 days**（90 天后过期，安全一些；到期重新生成即可） |
| **Select scopes** | 只勾 **`repo`** 这一个大项（勾了大项，下面的子项会自动全勾） |

7. 页面**拉到最底**，点绿色按钮 **Generate token**
8. 生成成功！页面上会出现一串 `ghp_xxxxxxxxxxxxxxxxxxxx` 的字符

> 🔴 **这串字符只显示这一次。** 刷新页面就再也看不到了。
> **立刻复制并粘贴到记事本里存好**。丢了只能重新生成。

#### ② 用 Token 推送

回到 PowerShell，执行第 6 步的 `git push`。当它问你要账号密码时：

```
Username for 'https://github.com': 你的GitHub用户名
Password for 'https://你的用户名@github.com': ← 在这里粘贴 Token
```

> ⚠️ **粘贴时屏幕上不会有任何显示**（连 `*` 都没有），这是正常的。
> 直接 `Ctrl+V` 然后按回车就行。

#### ③ 让它记住，下次不用再输

Windows 会把凭据存在"凭据管理器"里，正常情况下推送成功后自动记住。

如果每次都问，可以手动检查：

1. 开始菜单搜索 **凭据管理器** → 打开
2. 点 **Windows 凭据**
3. 往下找 **`git:https://github.com`** —— 有这条就说明记住了

想删掉重来，就点它 → **删除**，下次 push 会重新问。

### 5.4 方案二：SSH 密钥（配一次，永久免密）

适合你会长期用 GitHub 的情况。

```powershell
# 1. 生成密钥对（一路回车，不用设密码）
ssh-keygen -t ed25519 -C "你的邮箱"

# 2. 把公钥复制到剪贴板
Get-Content "$env:USERPROFILE\.ssh\id_ed25519.pub" | Set-Clipboard

# 3. 验证
```

然后：

1. 浏览器打开 <https://github.com/settings/keys>
2. 点 **New SSH key**
3. **Title** 填 `我的电脑`；**Key** 里 `Ctrl+V` 粘贴刚才复制的内容
4. 点 **Add SSH key**

回来测试：

```powershell
ssh -T git@github.com
```

第一次会问 `Are you sure you want to continue connecting?` → 输入 `yes` 回车。

**成功的样子**：

```
Hi 你的用户名! You've successfully authenticated, but GitHub does not provide shell access.
```

看到 `successfully authenticated` 就成了。然后要把仓库地址改成 SSH 形式（见第 6.1 步的备选）。

---

## 第 6 步：把代码推上去

### 6.1 告诉 git "远程仓库在哪"

```powershell
git remote add origin https://github.com/你的用户名/LibreTV-HarmonyOS.git
```

- `origin` 是给这个远程地址起的**别名**，习惯上都叫 origin
- 后面那串换成你**第 3.5 步复制的地址**

没输出 = 成功。

**检查一下配对了没有**：

```powershell
git remote -v
```

**你应该看到**（两行，一行 fetch 一行 push）：

```
origin  https://github.com/你的用户名/LibreTV-HarmonyOS.git (fetch)
origin  https://github.com/你的用户名/LibreTV-HarmonyOS.git (push)
```

> ❌ 如果报 `error: remote origin already exists`，说明之前加过了。
> 用这条改地址：`git remote set-url origin https://github.com/你的用户名/LibreTV-HarmonyOS.git`
>
> 走 SSH 路线的，地址要写成 `git@github.com:你的用户名/LibreTV-HarmonyOS.git`

### 6.2 推送

```powershell
git push -u origin main
```

拆开解释：

- `push` = 推上去
- `-u` = 记住这次的关系，**以后只需要敲 `git push` 两个词**
- `origin` = 推到哪个远程（第 6.1 步起的别名）
- `main` = 推哪个分支

### 6.3 你会看到什么

**成功的样子**（关键看最后一行）：

```
Enumerating objects: 130, done.
Counting objects: 100% (130/130), done.
Delta compression using up to 8 threads
Compressing objects: 100% (95/95), done.
Writing objects: 100% (130/130), 1.82 MiB | 3.20 MiB/s, done.
Total 130 (delta 20), reused 0 (delta 0), pack-reused 0
remote: Resolving deltas: 100% (20/20), done.
To https://github.com/你的用户名/LibreTV-HarmonyOS.git
 * [new branch]      main -> main
branch 'main' set up to track 'origin/main'.
```

看到 `* [new branch] main -> main` 和 `branch 'main' set up to track` 就是成功了。

如果中途弹窗要你登录/授权，按第 5 步处理，然后重新执行一次 `git push -u origin main`。

---

## 第 7 步：验证真的推上去了

**别只看命令行，一定要去网页确认。**

### 7.1 打开你的仓库

浏览器访问：

```
https://github.com/你的用户名/LibreTV-HarmonyOS
```

**你应该看到**：

1. 页面顶部是你的仓库名 `你的用户名 / LibreTV-HarmonyOS`
2. 下面有一行小字 `Public`
3. **README 内容自动显示在页面下方**（大标题 "LibreTV for HarmonyOS"、截图、功能列表）
4. 文件列表里有 `AppScope`、`docs`、`entry`、`README.md` 等
5. 右侧有 **About** 区域（目前是空的，第 8 步去填）
6. 右上角有 **⭐ Star**、**Fork** 按钮
7. 文件列表上方显示最后一次提交的信息和 **`122 Commits`**（或你实际的数量）

### 7.2 如果 README 没显示 / 图片裂开

| 现象 | 原因 | 解决 |
|---|---|---|
| 页面只有文件列表，README 内容是空的 | 仓库里没有 `README.md`，或名字大小写不对 | 必须是**根目录**下叫 `README.md`（大写 README） |
| 截图显示成一个破图标 | 图片路径错了，或文件名大小写不匹配 | GitHub 服务器区分大小写：`Home.png` ≠ `home.png`，改成完全一致 |
| README 里表格没渲染 | 表格上方少了空行 | Markdown 表格前面必须空一行 |

---

## 第 8 步：装修仓库门面（About 和 Topics）

这一步决定**别人能不能搜到你的项目、敢不敢点进来**。花 3 分钟做完，效果差别很大。

### 8.1 打开编辑面板

在仓库首页，**右侧边栏**有一个 **About** 标题。标题右边有个**齿轮图标 ⚙**
（鼠标移上去才会明显）。点它。

### 8.2 填 Description

```
LibreTV 的鸿蒙原生客户端｜ArkTS 多源影视聚合播放器｜HarmonyOS NEXT
```

一句话说清"是什么"。别写成"我的第一个开源项目"。

### 8.3 填 Website（可选）

有文档站、博客文章介绍这个项目的，填上去。没有就空着。

### 8.4 加 Topics（最重要）

Topics 就是**标签**，别人搜 "harmonyos 播放器" 时能不能找到你，全靠它。

在 **Topics** 输入框里，**一个一个输入，每输入一个按一次回车**。

> 🔴 很多人以为打完字就行，其实**必须按回车（或逗号）才会变成一个蓝色标签**。

直接复制这一串，逐个粘贴+回车：

```
harmonyos
harmonyos-next
arkts
arkui
libretv
video-player
hls
iptv
m3u8
avplayer
```

### 8.5 保存

点面板右下角的 **Save changes**。

### 8.6 顺便勾两个框

在同一个面板里还有：

- ☑️ **Releases** —— 让右侧显示"有版本可下载"（第 9 步发完 Release 才有内容）
- ☑️ **Packages** —— 本项目用不上，不勾

### 8.7 确认效果

刷新页面，右侧应该显示：

```
About
LibreTV 的鸿蒙原生客户端｜ArkTS 多源影视聚合播放器｜HarmonyOS NEXT

harmonyos  harmonyos-next  arkts  arkui  ...

⭐ 0    👁 1    🍴 0
```

---

## 第 9 步：发布 Release（让别人能下载）

**Release = 挂在仓库上的"下载专区"**。别人不用编译，直接下载你打包好的文件。

### 9.1 先在本机把 HAP 构建出来

```powershell
$env:DEVECO_SDK_HOME = "D:\Program Files\Huawei\DevEco Studio\sdk"
$env:JAVA_HOME       = "D:\Program Files\Huawei\DevEco Studio\jbr"
$env:PATH            = "D:\Program Files\Huawei\DevEco Studio\jbr\bin;" + $env:PATH

Set-Location "路径\LibreTV-HarmonyOS"
node "D:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js" `
     assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
```

产物位置：

```
entry\build\default\outputs\default\entry-default-unsigned.hap
```

### 9.2 改个看得懂的名字，放到桌面

```powershell
$src = "entry\build\default\outputs\default\entry-default-unsigned.hap"
$dst = "$env:USERPROFILE\Desktop\LibreTV-HarmonyOS-v1.0.6-unsigned.hap"
Copy-Item $src $dst
Get-Item $dst | Select-Object Name, @{N='大小MB';E={[math]::Round($_.Length/1MB,2)}}
```

### 9.3 生成校验和（可选，但很显专业）

```powershell
$h = Get-FileHash $dst -Algorithm SHA256
"$($h.Hash.ToLower())  LibreTV-HarmonyOS-v1.0.6-unsigned.hap" |
  Out-File -Encoding ascii "$env:USERPROFILE\Desktop\LibreTV-HarmonyOS-v1.0.6-unsigned.hap.sha256"
```

桌面上会多一个 `.sha256` 文件，下载的人可以用它核对文件有没有被篡改。

### 9.4 打一个版本标签（tag）

在 PowerShell 里（项目目录下）：

```powershell
git tag -a v1.0.6 -m "v1.0.6 - 首个开源版本"
git push origin v1.0.6
```

**你会看到**：

```
To https://github.com/你的用户名/LibreTV-HarmonyOS.git
 * [new tag]         v1.0.6 -> v1.0.6
```

> 💡 **不想用命令行？** 可以在网页上打 tag：仓库首页右侧 **Releases** →
> **Draft a new release** → 在 "Choose a tag" 里**直接输入** `v1.0.6` →
> 下面会出现 **"Create new tag: v1.0.6 on publish"** → 点它即可。

### 9.5 创建 Release

1. 打开仓库首页
2. **右侧边栏**找到 **Releases**（如果没看到，直接在网址后面加 `/releases`）
3. 点 **Create a new release**（或 **Draft a new release**）
4. 逐项填写：

| 字段 | 填什么 | 注意 |
|---|---|---|
| **Choose a tag** | 下拉选 `v1.0.6` | 第 9.4 步推上去的那个 |
| **Target** | `main` | 默认就是，不用改 |
| **Release title** | `v1.0.6 — 首个开源版本` | 会显示成大标题 |
| **Describe this release** | 见下方模板 | 可以 Markdown |
| **Set as the latest release** | ✅ 勾 | 让它在 Releases 页排最前 |
| **Set as a pre-release** | ❌ 不勾 | 只有测试版才勾 |

5. **上传文件** —— 页面下方有一块虚线框区域，写着
   **"Attach binaries by dropping them here or selecting them."**
   - 把桌面上的 `.hap` 和 `.sha256` **直接拖进这个框**
   - 或者点 "selecting them" → 在文件对话框里选这两个文件
   - 上传时每个文件旁边会显示进度条，等它变成绿色 ✓

6. 点绿色按钮 **Publish release**

### 9.6 Release 说明模板（直接复制改）

````markdown
## 下载

| 文件 | 说明 |
|---|---|
| `LibreTV-HarmonyOS-v1.0.6-unsigned.hap` | **未签名**，需用自己的证书重签后安装，见 README「安装」章节 |
| `LibreTV-HarmonyOS-v1.0.6-unsigned.hap.sha256` | SHA256 校验和 |

> 为什么没有"直接能装"的包：HarmonyOS 侧载要求调试证书的 profile 里登记设备 UDID，
> 作者无法为所有人的设备预先签名。详见 README。

## 新增

- 首页下拉弹簧回弹 + 顶部提示
- 上滑超过两屏出现「返回顶部」悬浮按钮
- 「一键导入 8 个推荐源」按钮

## 修复

- 修复返回顶部按钮阈值按"50 行"计算导致几乎不出现的问题

## 已知问题

- spider 源（TVBox `type:3`）不支持，HarmonyOS 无 JVM
- 主题切换需重启应用完全生效
````

### 9.7 验证

访问：

```
https://github.com/你的用户名/LibreTV-HarmonyOS/releases
```

**你应该看到**：一个大标题 `v1.0.6 — 首个开源版本`，下面是说明文字，
最下方是 **Assets** 区域，列着两个文件，点文件名能直接下载。

点一下 `.hap` 试试，能下载就成功了。

---

## 第 10 步：以后怎么改东西（不用命令行）

日常维护（改个错别字、更新 README、发新版本）都可以在网页上完成。

### 10.1 修改一个已有文件

1. 在仓库里点开这个文件（比如 `README.md`）
2. 右上角有个**铅笔图标 ✏️**（在 "Raw"、"Blame" 旁边），点它
3. 进入编辑模式，直接改
4. 改完**拉到页面最底**，有个 **Commit changes** 区域：
   - **Commit message**：写一句改了什么，例如 `docs: 修正安装说明里的路径`
   - 保持 **Commit directly to the `main` branch** 选中
5. 点绿色 **Commit changes** 按钮

几秒后文件就更新了。**网页上的每次编辑都等于一次提交**，不需要再 `git push`。

### 10.2 上传新文件（比如换截图）

1. 仓库首页，点文件列表右上方的 **Add file** 按钮
2. 选 **Upload files**
3. 把文件**拖进虚线框**，或点 "choose your files"
4. 底部填 Commit message
5. 点 **Commit changes**

### 10.3 新建文件

**Add file** → **Create new file** → 输入文件名（带路径会自动建文件夹，如 `docs/NOTES.md`）→ 填内容 → Commit。

### 10.4 删除文件

点开文件 → 右上角 **垃圾桶图标 🗑** → Commit changes。

### 10.5 在你自己的电脑上继续改

如果你在本地改了代码，记得走一遍：

```powershell
git add -A
git commit -m "fix: 修复某某问题"
git push
```

> 注意 `git push` 后面不用再带 `origin main` 了 —— 第 6.2 步的 `-u` 已经帮你记住了。

### 10.6 网页改过、本地也改过，冲突了怎么办

如果网页上改过，本地又改过同一处，`git push` 会被拒绝：
`Updates were rejected because the remote contains work...`

**解决**（本地改动还在，不会丢）：

```powershell
git pull --rebase origin main
git push
```

如果 `git pull` 报冲突（`CONFLICT`），说明同一行两边都改了。
打开冲突的文件，找到 `<<<<<<<` 和 `>>>>>>>` 之间的内容，手动决定保留哪一段，
删掉这些标记行，然后：

```powershell
git add -A
git rebase --continue
git push
```

---

## 第 11 步：出错了怎么办

### 11.1 推送相关

<details>
<summary><b><code>remote: Support for password authentication was removed</code></b></summary>

**原因**：GitHub 不允许用账号密码推送。

**解决**：按 [第 5.3 步](#53-方案一personal-access-token推荐) 生成 Token，用 Token 当密码。
</details>

<details>
<summary><b><code>Updates were rejected because the remote contains work that you do not have locally</code></b></summary>

**原因**：远程仓库里有你本地没有的提交 —— 90% 是因为建仓时**勾了 "Add a README file"**。

**解决**：

```powershell
git pull --rebase origin main
git push
```

如果 `git pull` 报 `refusing to merge unrelated histories`：

```powershell
git pull --rebase origin main --allow-unrelated-histories
git push
```
</details>

<details>
<summary><b><code>error: src refspec main does not match any</code></b></summary>

**原因**：本地分支不叫 `main`（可能是 `master`），或者**还没提交过任何东西**。

**解决**：

```powershell
git branch -M main          # 把当前分支改名成 main
git log --oneline           # 确认至少有一个提交；如果是空的，先 git add -A && git commit -m "init"
git push -u origin main
```
</details>

<details>
<summary><b><code>error: remote origin already exists</code></b></summary>

**原因**：之前已经 `git remote add` 过了。

**解决**（改地址）：

```powershell
git remote set-url origin https://github.com/你的用户名/LibreTV-HarmonyOS.git
git remote -v               # 确认
```
</details>

<details>
<summary><b><code>fatal: not a git repository</code></b></summary>

**原因**：当前目录不在仓库里。

**解决**：`Set-Location` 到项目根目录（能看到 `AppScope`、`entry` 那一层），再执行命令。
</details>

<details>
<summary><b>push 卡住不动 / 超时</b></summary>

**原因**：网络到 GitHub 不通，或大文件太多。

**解决**：

```powershell
# 1. 先看看能不能通
Test-NetConnection github.com -Port 443

# 2. 临时改用 SSH 协议（走 22 端口，有时更通）
git remote set-url origin git@github.com:你的用户名/LibreTV-HarmonyOS.git
git push -u origin main
```

项目里有大文件（>50MB）的，考虑用 Git LFS。
</details>

### 11.2 仓库内容相关

<details>
<summary><b>不小心把 <code>.p12</code> 证书推上去了</b></summary>

🔴 **立刻当作密码已泄露处理**，按这个顺序：

1. **先去华为 AGC 重新生成证书，作废旧的**（这一步最重要，否则清理历史也没用）
2. 把文件加进 `.gitignore`，从仓库删除：
   ```powershell
   git rm --cached 证书文件名
   git commit -m "chore: 移除误提交的证书"
   git push
   ```
3. 如果已经推送过，历史里还有。GitHub 上**删文件不会删历史**。需要清洗历史：
   ```powershell
   pip install git-filter-repo
   git filter-repo --path 证书文件名 --invert-paths
   git push --force
   ```
4. 通知 GitHub Support 清理缓存（fork 和缓存副本你自己删不掉）

> 结论：**能重签证书就重签**。清理历史永远不如"这个密钥从来没生效过"干净。
</details>

<details>
<summary><b>推上去发现多了 <code>build/</code> 等不该有的目录</b></summary>

```powershell
# 1. 先修好 .gitignore（加一行 /entry/build/）
# 2. 把这些文件从 git 的索引里移除（本地文件不会删）
git rm -r --cached entry/build
git rm -r --cached .hvigor
# 3. 重新提交
git add -A
git commit -m "chore: 移除构建产物"
git push
```
</details>

### 11.3 页面显示相关

<details>
<summary><b>GitHub 把项目语言识别成 "Other" 或 "HTML"</b></summary>

**原因**：GitHub 不认识 `.ets` 扩展名。

**解决**：仓库根目录建一个 `.gitattributes`，加一行：

```
*.ets linguist-language=TypeScript
```

（本项目已有这个文件）提交后等几分钟生效。
</details>

<details>
<summary><b>右上角没有显示 AGPL-3.0 license</b></summary>

**原因**：`LICENSE` 文件名不对，或内容不是标准全文。

**解决**：文件名必须叫 `LICENSE`（无扩展名），内容必须是协议原文。
本项目的 `LICENSE` 是标准 AGPL-3.0 全文，正常会被识别为 `AGPL-3.0 license`。
</details>

---

## 附录 A：全网页操作（一点命令行都不碰）

> 代价：**没有提交历史**（所有文件变成一次巨大的提交），且以后更新要一个一个传。
> 适合"只想先把它放上去"的场景。

### A.1 准备

把项目文件夹里**不该上传的东西先删掉或移走**（或者复制一份到别处，只留要上传的）：

- 删除 `entry/build/`、`build/`、`.hvigor/`、`dev/`、`.idea/`
- 删除所有 `*.log`、`*.hap`、`patch_*.py`

> ⚠️ 网页上传**不会读 `.gitignore`**，你拖什么它就传什么。删干净再拖。

### A.2 上传

1. 打开你的仓库首页
2. 点 **Add file** → **Upload files**
3. 打开资源管理器，进入项目文件夹，**全选**（`Ctrl+A`）所有文件和文件夹
4. **直接拖进浏览器的虚线框**

   浏览器会显示 `N files` 正在上传。等它全部完成（122 个文件大约 1-2 分钟）。
5. 页面下方填 **Commit message**：`feat: 首个开源版本`
6. 点 **Commit changes**

### A.3 检查

刷新仓库首页，确认文件都在、文件夹结构正确（`AppScope/`、`entry/src/...`、`docs/` 等）。

> 🔴 **如果某个子文件夹变成了一个文件**，说明拖拽时浏览器没识别目录结构。
> 解决：改用 **GitHub Desktop**（附录 B），或者装 git 走主线。

---

## 附录 B：用 GitHub Desktop 图形界面

完全不想敲命令的话，这是最稳的方案。

### B.1 安装

<https://desktop.github.com/> 下载 → 安装 → 打开 → 用 GitHub 账号登录（会跳浏览器授权）

### B.2 添加本地项目

1. 菜单 **File** → **Add local repository**
2. **Local path** 选你的项目文件夹（`...\LibreTV-HarmonyOS`）
3. 如果提示 "This directory does not appear to be a Git repository"，点它下面的
   **"create a repository"** 链接
4. **Name** 保持默认；**Local path** 保持默认
5. 点 **Create repository**

### B.3 提交

1. 左侧会列出所有变更的文件，**逐个看一遍**（确认没有 `.p12`、`build/`）
2. 左下角 **Summary** 填：`feat: 首个开源版本`
3. 点 **Commit to main**

### B.4 发布到 GitHub

1. 顶部点 **Publish repository**
2. 弹窗里：
   - **Name**：`LibreTV-HarmonyOS`
   - **Description**：一句话简介
   - **Keep this code private**：❌ **不要勾**（勾了就是私有仓库）
3. 点 **Publish repository**

完成。它会自动推到 GitHub，你可以直接去网页看。

### B.5 以后更新

改完文件 → GitHub Desktop 会自动列出变更 → 填 Summary → **Commit to main** →
右上角 **Push origin**。两步搞定。

---

## 附录 C：合规红线

影视聚合类项目有额外风险，发布前确认：

### C.1 绝不内置内容源

代码里**不能有**任何默认的采集站地址作为"开箱即用"的源。

本项目的做法：

- `SourceManager` 首次启动时源列表为空
- 推荐源以 `RECOMMENDED_VOD` 常量数组的形式存在，**必须由用户主动点「一键导入」**才写入
- README 明确写出"不内置任何内容"

**为什么这条重要**：仓库里预置源 = 你在分发侵权内容的入口。
用户主动添加 = 工具中立。

### C.2 免责声明要具体

不要只写"本项目仅供学习"。要写清楚：

- 不提供、不托管、不分发任何内容
- 内容合法性由源方与使用者负责
- 不构成对任何内容的推荐或授权
- 收到侵权通知会处理

### C.3 不要宣传"破解 / 去广告 / 绕过会员"

"过滤 HLS 里的广告分片"是技术特性（提升播放体验），
但**不能**宣传成"破解 VIP 内容"或"去除平台贴片广告"。

### C.4 保留上游署名

本项目是 LibreTV 的移植实现，README 首段即注明来源，`LICENSE` 保留 AGPL-3.0。
**AGPL 要求保留原始版权声明**，删掉它本身就是违规。

---

## 附录 D：一页速查

```powershell
# ========== 一次性发布（确认第 1 步体检已通过）==========
Set-Location "路径\LibreTV-HarmonyOS"

# 1. 身份（换成你自己的）
git config --local user.name  "你的名字"
git config --local user.email "你的邮箱"

# 2. 初始化 + 提交
git init -b main
git add -A
git status --short                # ★ 人工核对：没有证书/构建产物
git commit -m "feat: 首个开源版本"

# 3. 关联远程（换成你的地址）
git remote add origin https://github.com/你的用户名/LibreTV-HarmonyOS.git

# 4. 推送
git push -u origin main

# 5. 打版本标签
git tag -a v1.0.6 -m "v1.0.6 - 首个开源版本"
git push origin v1.0.6

# ========== 以后日常更新 ==========
git add -A
git commit -m "fix: 改了什么"
git push
```

**网页上还要做的三件事**（命令替代不了）：

1. 右侧 **About ⚙** → 填 Description + 加 Topics + Save changes
2. **Releases** → Create a new release → 选 tag → 拖入 `.hap` → Publish release
3. 复制仓库链接，用**无痕窗口**打开，用陌生人视角检查一遍
