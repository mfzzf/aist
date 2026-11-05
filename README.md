<p align="center">
  <img src="Resources/Mac/AppIcon.png" width="128" alt="Aist">
</p>

<h1 align="center">Aist</h1>

<p align="center">
  macOS 菜单栏里的 AI 待办助理：截屏、邮件、会议、企业微信、GitHub 里别人交代给你的事，自动变成待办。
</p>

<p align="center">
  <a href="https://github.com/mfzzf/aist/releases/latest">下载最新版</a> ·
  macOS 15+（会议转写需 macOS 26） · Apple 公证
</p>

---

## 它能做什么

**截屏识别待办**
按快捷键（默认 `⌃⌥T`）截下当前窗口——聊天、文档、日历都行。AI 判断哪些事是**你本人**要做的：分得清聊天里左右气泡、@ 的是谁、事情是否已经办完，宁缺毋滥。

**语音记待办**
按住快捷键（默认 `⌃⌥V`）说话，松开交给 AI；也可以按一下开始、再按一下结束，Esc 取消。不只是新增：「报价发了」「快递改到明天」「那个会取消了」会勾掉、改期、删除对应的待办。用 macOS 自带的语音识别（支持时在本机识别），语言跟随 设置 › 会议。

**邮件自动生成待办**
接入 IMAP/SMTP 邮箱（QQ、Gmail、企业邮箱等），新邮件到达时自动分析，抄送、群发、通知类邮件不会误判。每封邮件都会标出「AI 是否已分析、发现了几项待办」。CI/构建失败这类通知会变成高优先级待办，并附上排查建议。

**会议录音 → 纪要**
一键录下会议：麦克风是「我」，电脑里传出的声音是「对方」，分轨保存。转写默认在本机完成（Apple SpeechAnalyzer），也可在 设置 › AI › AstraFlow 改用 Gemini 实时转写与同传字幕（只上传有人说话的片段，断线自动重连），或散会后用 gpt-4o-transcribe-diarize / gemini-3.5-transcribe 转写录音，再由 AI 生成纪要：概要、要点、决定、待跟进、你的待办、别人的待办。
- **实时转写**：边开会边出文字，「会议实况」小窗口跟着滚动；可选字幕翻译（Apple 本机翻译）；自动识别中文、英文、马来语等并随说话切换；不戴耳机时麦克风录到的对方声音会自动去掉
- **会中速记**：大约每 45 秒更新一次要点、结论、你的待办和别人的待办，会还没开完就能看到
- **自动开始与结束**：腾讯会议、Zoom、飞书、Teams 等开始通话时提示录音；挂断或长时间没人说话时自动结束并生成纪要
- 自动关联同一时段的日历 / 企业微信日程，按**参会人**推断谁说了什么，按会议信息纠正人名与术语，对照议程找出没谈到的议题
- **人名与术语表**记下识别听错的写法，搜索正确写法也能找到听错的会议
- 纪要里的要点、决定、待办都能**跳回原话**；原始录音保留在本机，点转写里任一句的时间即可从那里回放
- **一键发送纪要**：纪要加双方待办写成邮件，收件人默认是日程里的参会人；也可以导出 Markdown、Word、SRT 字幕
- 实况窗口默认不会被屏幕共享、录屏和截图拍到

**企业微信与 GitHub**
- 企业微信：扫码登录，同步日程；会前 15 / 5 分钟通知，新日程通知
- GitHub：通知里点名你的 Issue / PR / Review 和 CI 失败自动变成待办，重复的会合并

**日历与提醒事项**
待办可同步到「提醒事项」（经 iCloud 出现在 iPhone、Apple Watch 上），可排进日历。

**AI 建议**
每条待办都会推断你真正要达成的目标，自动判断优先级，并给出一两条具体的下一步。

## 安装

1. 从 [Releases](https://github.com/mfzzf/aist/releases/latest) 下载 `Aist-x.y.z.dmg`
2. 打开后把 **Aist** 拖进「应用程序」
3. 首次启动会进入新手引导：
   - **权限**：录屏与系统录音（截屏、录对方声音）、麦克风、日历、提醒事项、通知
   - **AI 模型**：选一个服务商填入 API Key
   - **自动化**：你的名字（让 AI 认出「@你」）、工作背景（你负责的产品/项目/客户，没人点名时 AI 也会主动认领）、登录时打开、邮件自动分析

之后随时可以在 设置 › 通用 › 新手引导 重新打开。

**自动更新**：Aist 会定期检查 GitHub Releases，有新版本时提示你一键安装并重新打开；下载的安装包必须带有同一开发者的 Developer ID 签名才会被安装。也可以在菜单「检查更新…」或 设置 › 通用 › 更新 手动检查。

## AI 服务商

设置 › AI 里可切换，模型列表直接从服务商接口拉取并按发布时间排序：

DeepSeek · Claude · OpenAI · Gemini · Kimi · 智谱 · 通义千问 · AstraFlow（UCloud，多地域）· OpenRouter · Ollama（本地）· 以及任何 OpenAI（Chat Completions / Responses）/ Anthropic 兼容的自定义服务

AstraFlow 只需选地域、填密钥、选模型：DeepSeek 模型自动走 Responses 接口，其他模型走 Chat Completions。

AI 输出统一走 JSON Schema 工具调用（function calling），不支持的服务会自动降级为文本 JSON。

## 隐私

- 待办、会议、录音、转写都只保存在这台 Mac：`~/Library/Application Support/aist/`
- API Key、GitHub Token、邮箱密码保存在「钥匙串」
- 会议转写默认在本机完成（打开 AstraFlow 实时转写或会后转写时，有人说话的片段会发到 AstraFlow）；发送给 AI 服务商的只有截图、邮件正文或转写文本本身
- 删除会议时，原始录音移到废纸篓而不是直接销毁

## 从源码构建

需要 Xcode 26 / Swift 6。

```bash
swift build                    # 编译
swift test                     # 单元测试
./scripts/build-mac.sh         # 打包 build/Aist.app（用开发证书签名）
./scripts/package-dmg.sh       # Developer ID 签名 + 公证 + DMG
```

`build-mac.sh` 通过 `AIST_SIGN_IDENTITY` 指定签名证书。签名身份要固定，否则每次重新编译都会丢失录屏权限。

`package-dmg.sh` 需要先保存公证凭据：

```bash
xcrun notarytool store-credentials aist-notary \
  --apple-id <Apple ID> --team-id <Team ID> --password <App 专用密码>
```

### 发布新版本

1. 改 `Resources/Mac/Info.plist` 里的 `CFBundleShortVersionString` / `CFBundleVersion`
2. `NOTES_FILE=notes.md ./scripts/package-dmg.sh`，得到 `build/Aist-x.y.z.dmg` 和 `build/latest.json`
3. `gh release create vx.y.z build/Aist-x.y.z.dmg build/latest.json --notes-file notes.md`

App 读的是 `releases/latest/download/latest.json`（走 GitHub 下载 CDN，不受 API 每小时 60 次的限流），并按里面的 SHA-256 校验下载的 DMG；没有这个文件时退回 GitHub API。

### 调试提示词

`aist-cli` 用和 App 相同的提示词跑一次分析，不需要权限，适合在 SSH 下迭代：

```bash
aist-cli extract shot.png --app 企业微信 --me "张三,zhangsan"
aist-cli email mail.txt
aist-cli chat chat.txt
aist-cli meeting transcript.txt --context meeting-info.txt
```

可用环境变量临时换模型：`AIST_BASE_URL`、`AIST_MODEL`、`AIST_FORMAT`（`anthropic` | `openai`）、`AIST_API_KEY`；`AIST_DEBUG=1` 打印模型原始输出。

## 项目结构

```
Sources/
  AistCore/     提示词、LLM 客户端（工具调用）、待办与会议存储——Mac、CLI 共用
  AistMac/      菜单栏 App：截屏、录音转写、主窗口、设置、引导
    Mail/         IMAP/SMTP 邮箱与自动分析
    Integrations/ 日历、提醒事项、企业微信、GitHub、通知
  aist-cli/     命令行调试工具
Tests/          单元测试
scripts/        打包、签名、公证
```

## 致谢

- [SwiftMail](https://github.com/Cocoanetics/SwiftMail)（IMAP/SMTP）
- 服务商图标来自 [LobeHub Icons](https://github.com/lobehub/lobe-icons)（MIT）
