<p align="center">
  <img src="Resources/AppIcon-512.png" width="132" alt="Agent Pet Runtime: a round-faced pet inside a golden ring, on orange">
</p>

# Agent Pet Runtime

[English](README.md) · **简体中文**

一只会对你正在跑的 CLI Agent 做出反应的 macOS 桌面宠物。

Claude Code 弹权限请求，它抬爪子。任务做完，它庆祝一下再回到发呆。你拖它，它朝你拖的方向走。你不理它，它会用十六个方向盯着你的鼠标看。

这不是套在日志解析器外面的玩具。Agent 状态是认真建模的，桥接延迟是量过并卡死的，不该记的东西一样没记。

```
   Claude Code ─┐
   Codex       ─┤          spawn            ┌──────────────┐
   Grok        ─┼──────► agentpet-hook ───►│    socket    │
   Pi          ─┤          (~5 ms)         └──────┬───────┘
   Oh My Pi    ─┘                                 │
                                                  │
                       ┌──────────────────────────▼──────────────────────┐
                       │  归一化 → Activity 引擎 → 动画 → 宠物           │
                       └─────────────────────────────────────────────────┘
```

---

## 安装

```bash
brew tap dncore/agent-pet-runtime
brew install --cask agent-pet-runtime
```

应用是 ad-hoc 签名、未公证，所以 cask 会在安装时移除 macOS 的 quarantine 属性。
如果仍被 Gatekeeper 拦截：

```bash
xattr -dr com.apple.quarantine "/Applications/AgentPet.app"
```

<details>
<summary>或者从源码构建</summary>

```bash
git clone https://github.com/dncore/agent-pet-runtime.git
cd agent-pet-runtime
swift build -c release
./Scripts/build-app.sh          # 组装 AgentPet.app
open build/AgentPet.app
```

需要 macOS 14+ 与 Swift 6.1+（Xcode 16.4 或更新）。

</details>

cask 由
[`homebrew/agent-pet-runtime.rb.template`](homebrew/agent-pet-runtime.rb.template)
在每次 release 时生成，推送到
[dncore/homebrew-agent-pet-runtime](https://github.com/dncore/homebrew-agent-pet-runtime)。
**要改就改这里的模板，不要改 tap。**

---

## 接入你的 Agent

在你主动配置之前，它什么都不做。用菜单栏，或者：

```bash
swift run AgentPet --status                    # 装了哪些、配了哪些
swift run AgentPet --configure claude-code     # 安装 hook
swift run AgentPet --unconfigure claude-code   # 精确移除它写过的东西
```

**不需要重启。** Claude Code 在**每次派发 hook 时**重新读取 `~/.claude/settings.json`，所以会话运行中途加的 hook 下一个事件就生效，正在跑长任务的会话不会被打断。（实测方式：给一个已经跑了好几个小时的会话新增 `SubagentStart`/`SubagentStop`，然后看它们触发。）

六个 agent 现在都可配置。Codex 多一步：它的 hooks 要你在 Codex 自己的 `/hooks` 面板里 review 并信任一次才会生效——配置完成的那一刻，运行时会直接把这句话打给你。

### 配置到底做了什么

配置做什么因 agent 而异，除此之外一概不碰：Claude Code 是往 `~/.claude/settings.json` 加 hook 行；Grok 是写运行时自己的 `~/.grok/hooks/agentpet.json`（移除时整个删掉），并在 `~/.grok/config.toml` 末尾追加一个开关 `[compat.claude] hooks = false`——否则 Grok 的 Claude 兼容扫描会把 Claude 的 hook 再放一遍；Pi 是写运行时自己的一个 TypeScript 扩展 `~/.pi/agent/extensions/agentpet.ts`（同样删除即卸载）；Oh My Pi 同理，写 `~/.omp/agent/extensions/agentpet.ts`（同样删除即卸载；装完要新起一个 omp 会话才生效，正在跑的那个不算）；Codex 是往 `~/.codex/hooks.json` 加 hook 行，与已有条目合并（比如 Otty 的四条原样保留，卸载时也只删自己写的）；Antigravity 是往 `~/.gemini/config/hooks.json` 写一个命名钩子（工具事件用 matcher 分组、其余事件是扁平 handler 列表——它的 schema 并不统一），与其它命名钩子合并、卸载只删自己：

- **先备份。** 动笔之前先把原文件复制到运行时备份目录。
- **原子写入。** 写临时文件再 rename，读者要么看到旧文件要么看到新文件，不会看到写了一半的。
- **幂等。** 连点两次 Configure 什么都不会变。
- **可逆。** Remove Integration 只删运行时自己写的行。**其他工具的 hook 行原样保留**——而你机器上通常有好几个；追加的开关按字节精确删回。扩展文件则整个删掉，且只在文件里还留着记录中那行标记时才删：把那行换掉、或同名换成你自己写的文件，运行时不会碰它。两种情况都先留一份备份，所以即使你在它基础上加过东西也拿得回来。
- **检测并发修改。** 文件的主人自己也会写它。如果读和写之间它变了，就放弃这次编辑而不是覆盖它。扩展文件没有第二个写入方：它只校验是不是运行时自己写的、原子写入、再读回验证。

它永远不碰模型配置、凭据和 prompt。

---

## Agent 状态是怎么读的

Agent 状态是一个由 hook 事件驱动的小型状态机。**映射是最容易做错的部分**，所以在这里写清楚。

| Agent 说 | 宠物显示 | 依据 |
|---|---|---|
| `PermissionRequest` | **等待** | 唯一表示「Agent 无法继续」的事件 |
| `PreToolUse` / `PostToolUse` / `UserPromptSubmit` | 工作中 | 正在干活 |
| `Stop` | 庆祝一下，然后发呆 | 它在**每一轮**结束时都触发，不是会话结束 |
| `TaskCompleted` | 庆祝 | 真的有一个任务做完了 |
| `StopFailure` | 失败 | 失败的一轮不等于成功的一轮 |
| `SessionStart` | *(不出行)* | 它只说明有个进程启动了，而进程不一定是用户启动的——会话在它的第一个真实事件到来时才出现 |
| `SessionEnd` | *(移除)* | 会话结束 |

四个只有对着真实 Agent 才会暴露的细节：

**`SessionStart` 不等于"你看得见的会话"。** Claude Code 的后台守护进程会**预热**会话：进程铸造一个 session id、触发这个 hook、然后坐在那里等被 claim——没有终端、没有 transcript、也永远不会有后续事件来修正它画出的那一行。所以只宣布了自己的会话不上屏，它在第一句话或第一次工具调用时出现；真的在干活的会话下一秒就会自己报到，而没人能填的空行恰恰是唯一不会自己消失的行。

**`Notification` 是个杂类事件。** 它携带 `permission_prompt`、`idle_prompt`、`auth_success`、`elicitation_dialog` 四种情况，只能靠一个字段区分。把整个事件当成"等待输入"，会导致**只要你开超过一个会话，宠物就永久卡在求关注的状态**。现在只有 `permission_prompt` 会映射，其余不改变任何状态。

**子 Agent 在跑的时候 `Stop` 会撒谎。** 主 Agent 让出控制权就触发 `Stop`，而后台子 Agent 可能还在干活。payload 里的 `background_tasks` 如果还有 running 的，说明这一轮没结束。

**Grok 会读 Claude Code 的配置，所以运行时把这个扫描关掉。** Grok Build 会扫描并信任 `~/.claude/settings.json`，那会让每个 Grok 事件被 Claude 的 hook 再放一遍。配置 Grok 时会往 `~/.grok/config.toml` 追加 `[compat.claude] hooks = false`，并改为安装 Grok 自己的 hooks 文件。shim 仍检测 `GROK_HOOK_NAME`，万一仍有扫描来的事件也会被改判成 Grok。

### Oh My Pi 的映射

Oh My Pi 没有 hook 表，所以上面那张表是 Claude Code 的。运行时装的扩展监听八个事件、另发一条上下文读数（第九个事件名），映射如下：

| 扩展说 | 宠物显示 | 依据 |
|---|---|---|
| `tool_approval_requested` | **等待** | 工具被扣住等你批准——对应 Claude Code 的权限提示 |
| `tool_execution_start` 且 toolName 是 `ask` | **等待** | `ask` 工具本身就是问用户一个问题，不答就走不下去 |
| `agent_start`、其他工具调用 | 工作中 | 正在干活 |
| `tool_execution_end` / `tool_approval_resolved` | 工作中 | 也是你答完问题、或审批通过后，把宠物从「等待输入」上取下来的信号 |
| `agent_end` | 庆祝一下，然后发呆 | 每轮 prompt 触发一次；payload 里 `willContinue` 为真时说明已经排好了重试，这时不报 |
| `session_start` | *(不出行)* | 与 Claude Code 同理：只说明有进程启动，会话在第一个真实事件时出现 |
| `session_shutdown` | *(移除)* | 会话结束 |
| `context_update`（结算时发送，不是独立监听的事件） | *(只描述，不改变状态)* | 模型与上下文占用——与状态栏 tap 同一归约形状 |

故意不映射的：`turn_start`/`turn_end`（Oh My Pi 的一个 turn 是一次模型调用，不是一轮 prompt，所以 turn 边界不代表干完了一段活），以及各种 message 事件（它们携带模型输出，本项目根本不读）。

这个扩展有两个值得知道的性质，都写在装出来的文件里：

**它只上报，永不设卡。** 它没有注册任何能拦截工具、改写参数或代答审批的 handler，每一步都包了 try/catch，出错也传不到 Agent 身上。它唯一会改变的东西也写明了：只要**任意扩展**在处理四个工具生命周期事件（`tool_call`、`tool_result`、`tool_approval_requested`、`tool_approval_resolved`）之一，Oh My Pi 就会跳过实验性推测本地读（`tools.speculativeExecution.enabled`，默认关闭）；本文件占的是后两个——审批之所以能显示成 **Needs input**，靠的正是它们。删掉文件即恢复。

**它的 payload 走环境变量，不走管道。** 这个扩展跑在 Agent 自己的运行时里，往管道写数据的动作要排在事件循环上，而 Agent 可能正占着它。本机实测：spawn 之后忙等 30ms 再写，就足以让 shim 的 stdin 等待超时，事件到达时**没有任何 session id**——宠物上会出现一行永远填不上的东西。环境变量由内核在 spawn 时交给子进程，没有可迟到的余地。（见 `Sources/agentpet-hook/main.swift` 里的 `AGENTPET_PAYLOAD_BASE64`，以及覆盖它的测试。）


---

## 动画是怎么播的

公开的宠物契约定义了九条标准动画行加十六个注视姿态，每个都带**逐帧毫秒时长**。而且不均匀：`idle` 是 `280, 110, 110, 140, 140, 320`——那是一次呼吸，首末帧是中间帧的两三倍长。单一帧率表达不了，所以运行时存的是**逐帧时长**。

工作与等待是"持续状态"：整行一直循环，直到状态结束——三秒就停下的宠物在十分钟的任务里看起来像睡着了。完成与失败是"一次性时刻"：按 Codex 的播放形状整行播三遍，然后沉进呼吸，这也是它不会一直僵在某个表情上的原因。系统要求 reduced motion 时，一切定格在单帧。

播放是分层的，先命中者胜：

| 层 | 驱动源 |
|---|---|
| 1. 拖动中 | 你拖的方向——`running-left` / `running-right` |
| 2. 手势播放中 | one-shot：`jumping`、`waving` |
| 3. Agent 状态 | 上面那张表 |
| 4. 注视 | 折进 `idle`/`running`/`waving` 三行里——十六个姿态，间隔 22.5° |
| 5. 发呆 | 兜底 |

拖动压倒一切：**你手上拿着它**；指针落到宠物身上也一样——Codex 的 hover 是跳**三遍**然后接着呼吸，光标不移开就一直动（"三遍 + idle 段无限循环"是它每个状态共用的形状）。

注视不是独立一层，而是**折进上面几行里的**——这正是 Codex 自己 sprite 的写法：look frame 直接顶掉那一行的播放，而且只对 `idle`/`running`/`waving` 三行生效。所以工作中的宠物会转头看你的指针（而不是继续跑），等待输入的宠物继续等你；死区只有一个点：只要屏幕上有指针它就在看，只有指针正压在它中心时才回到自己的行。

## 宠物会说什么

动画之外，宠物还带着 Codex 原版宠物才有的消息元素：精灵上方一小块状态，用同一套词汇——**Running**、等审批时的 **Needs input**（并写出是哪个工具）、回合结束的 **Ready**、出错的 **Blocked**；出现时窗口向上生长，宠物本体的位置纹丝不动。

这一块现在是一个**会话面板**：每个开着的会话一行，同一 agent 的会话排在一起，宠物正在展示的那个排最前。每行可显示：agent 名、session id 后六位、会话名或项目名、模型（含 effort）、当前工具、上下文占用（荧光绿横条）、会话花费、5 小时 / 7 天额度用量、状态消息。每一项都可以在管理器的 Settings 里开关与排序；面板可设为常驻或只在有事发生时出现；宽度是宠物宽度的百分比（100–200%，滑杆 + 数值框 + 加减按钮），因此可以比宠物本体宽；行内文字可左/中/右对齐——**宠物本身不动**。状态消息的第二行仍是事件真正携带的信息：在等哪个工具、什么失败了，以及回合结束时**助手最后一条消息的预览**——Claude Code 通过 `last_assistant_message` 把它交给 hook，Codex 也是这么展示的。它按 Codex 的规则整理（折叠空白、截到 200 字符），只存在于内存，绝不写入任何日志文件；你输入过的内容永远不上屏。

**模型、上下文、花费、额度**是 hook 不携带的数字——Claude Code 只把它们交给状态栏命令。Settings 里可以开启"状态栏 tap"：运行时接收状态栏 JSON、只保留减字段后的几项，然后把你原有的状态栏命令原样跑过去，输出照旧。默认关闭、立即生效、一键还原、每次渲染约 +2ms，且从不读取 transcript。app 被删除时 wrapper 会发现 shim 不在，把状态栏交还给你自己的命令。

---

## 宠物从哪来

宠物属于 Codex。运行时读的就是 Codex 自己的宠物目录——`$CODEX_HOME/pets`，未设置时即 `~/.codex/pets`——并且从不写入：

```sh
npx codex-pets add <pet-id>     # 从 codex-pets.net 安装；再跑一次就是更新
rm -rf ~/.codex/pets/<pet-id>   # 移除：宠物就是一个文件夹，删掉它就是全部操作
```

目录里任何带 `pet.json` 和 spritesheet 的文件夹都算数，怎么来的都行——hatch-pet skill 生成的、手动解压的、别人分享的。Codex 旧的 `~/.codex/avatars/` 目录也在读取范围内（那里的包用 `avatar.json`），清单缺 id 或 spritesheetPath 也照 Codex 的 loader 规则回退。Pet Manager 列的就是这些目录：预览、把你选中的那只放上桌面；它自己不安装、不导入、不删除任何东西，因此本 app 与你终端的 Codex 永远不可能对"装了什么"给出两个答案。你的选择会被记住，下次启动仍是它。

---

## 性能

shim 跑在 Agent 的关键路径上，每次工具调用一次，所以这个数字**决定方案是否可行**。

| 场景 | P50 | P95 | P99 | max |
|---|---|---|---|---|
| Runtime 运行中 | **4.33 ms** | 6.27 ms | 6.59 ms | 6.90 ms |
| Runtime 未运行 | 3.81 ms | 5.62 ms | 6.51 ms | 6.53 ms |

预算 P50 < 5ms / P99 < 25ms，500 次采样。Swift 带 Foundation 启动 3.72ms，C 是 2.23ms——多花的 1.2ms 换来一个能直接用 `nc -U` 调试的 JSON 信封。

**shim 永远 exit 0。** Claude Code 把非 0 的 hook 退出码当成有语义的信号，会据此改变 Agent 行为。一只会改变你 Agent 行为的宠物，比一只漏掉事件的宠物糟糕得多。

---

## 隐私

纯本地。没有任何上传，也没有云端组件。

运行时读取 session id、工作目录、事件名。它**不读** prompt、模型输出、源码——不是过滤掉，是根本不读。写到磁盘的集成记录里只有 hook 命令和时间戳，没别的。

Oh My Pi 的扩展从另一侧遵守同一份白名单：运行时装进去的文件每个事件只发 session id、工作目录和工具名，里面没有任何一行代码会碰 prompt、工具参数或输出。

App 没运行时（重启，或 `brew upgrade` 替换 bundle 的那几秒），hook 会把未送达的事件写进 `pending-events/`，供下次启动回放。这些文件与事件日志同一条白名单（session id、目录、事件名与工具**名**；绝不包含 prompt、参数、输出、源码），权限 `0600`，上限 200 条，回放后即删。

`--log-events` 会写诊断抓包，**默认关闭**。它只保留诊断需要的字段，丢弃 `tool_input`、`tool_response`、`transcript_path`——用的是白名单，所以未来 Agent 版本新增的字段也不会默认泄漏进日志。文件权限 `0600`。

离开这台机器的请求只有一个：检查更新会读取项目在 GitHub 的公开 release feed，把 tag 与当前版本比较。它不携带任何关于你或这台机器的信息，无头运行时不会发起，且这是全部的联网面——其余一切都不与外部通信。

---

## 开发

```bash
swift build && swift test        # 547 个测试
swift run AgentPet               # 跑起来

swift run AgentPet --diagnose                      # 发现了哪些宠物，以及为什么
swift run AgentPet --diagnose --export-frames /tmp/frames
swift run AgentPet --selftest                      # 渲染每个状态并测量输出
```

`--selftest` 存在的原因是截图不一定可用：没有屏幕录制权限时，`screencapture` 只返回壁纸。它改为把每个状态通过真实 view 画进离屏缓冲、数 backing store 里的非透明像素；同时**断言宠物可以被抓住**——一只渲染完美但拖不动的宠物，看起来和正常的一模一样。

```
Sources/AgentPetCore/     纯逻辑。不依赖 AppKit，所以全部可以无头测试。
├── Domain/               AgentState, AgentEvent, AgentActivity, Confidence
├── Activity/             ActivityEngine —— 优先级、老化、焦点保持、完成停留
├── Bridge/               信封、分帧、服务端、归一化、hook 配置生成
├── Pet/                  manifest、兼容档、校验、解码
├── Integration/          配置事务、配置器、检测
├── Runtime/              AnimationResolver、拖动几何
├── Settings/             AppConfig
└── Diagnostics/          状态转移日志、事件抓包、可导出诊断包

Sources/AgentPetApp/      AppKit + SwiftUI：悬浮宠物、管理器窗口、菜单栏
Sources/agentpet-hook/    Agent 执行的 shim。必须永远 exit 0。
```

`docs/SPEC-REVIEW.md` 是本项目的设计评审——原方案的哪些结论站得住、哪些站不住，每条都附证据。`docs/ARCHITECTURE.md` 是修正后的规格。

---

## 状态

| | |
|---|---|
| 核心、宠物加载、校验、Activity 引擎 | 完成 |
| 悬浮宠物、拖动、注视、位置记忆 | 完成 |
| 宠物尺寸——Codex 自己的 112pt 与它的两端 | 完成——管理器设置里选 |
| 指针落到宠物身上播放跳跃 | 完成——Codex 的 hover，末帧停住 |
| 宠物第一次出现时自我问候并挥手 | 完成——8 秒，每只宠物一次 |
| 收纳 / 唤醒宠物 | 完成——菜单栏项，跨重启记住 |
| 事件桥接，已对着真实二进制验证 | 完成 |
| Pet Manager：列出 Codex 的宠物、预览、选用 | 完成——只读；宠物由 Codex 自己的工具链安装 |
| Agent 集成：检测、配置、移除 | Claude Code、Grok、Pi、Codex、Antigravity 与 Oh My Pi |
| Activity Center、设置、诊断导出 | 完成 |
| 会话面板：每会话一行，各项可配置 | 完成 |
| 上下文占用（读取 Claude Code 状态栏） | 完成——可选开启，包裹你已有的状态栏命令 |
| 重启/升级后不丢回合中的会话 | 完成——未送达事件在下次启动时回放 |
| 聚焦到终端窗口 | 改为打开项目目录；hook payload 里没有终端标识 |

---

## 许可

MIT。见 [LICENSE](LICENSE)。
