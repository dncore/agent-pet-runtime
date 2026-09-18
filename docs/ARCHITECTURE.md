# Agent Pet Runtime — 修正后架构与规格

> 本文档补全 `SPEC-REVIEW.md` 中识别出的规格空洞，并作为实现的唯一事实源。
> 凡本文档与原方案 `Agent_Pet_Runtime_v0.1.md` 冲突处，**以本文档为准**。

---

## 1. 修正后的架构

原方案的 Bridge 被画成"Agent 连过来的服务器"。实测（见 `SPEC-REVIEW.md` §2.1）Agent 的交付机制是**进程派生**，因此 Bridge 必须是两段式。

```
┌────────────────────────────────────────────────────────────────────┐
│ 外部 Agent 进程（不是我们启动的，在用户自己的终端里）                  │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌─────────────────┐       │
│  │Codex     │ │Claude    │ │Grok      │ │Pi / Oh My Pi    │       │
│  └────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬────────────┘       │
│       │notify      │hook        │hook        │TS extension        │
└───────┼────────────┼────────────┼────────────┼────────────────────┘
        │            │            │            │
        └────────────┴─────┬──────┴────────────┘
                           │  spawn(argv + stdin JSON)
                           ▼
              ┌────────────────────────────┐
              │  agentpet-hook (CLI shim)  │  ← 原方案缺失的一段
              │  无状态 · 不解析 · 永不阻塞  │
              │  采集 getppid()/TTY         │
              └─────────────┬──────────────┘
                            │  UDS 单向写 (fire-and-forget)
                            ▼
              ~/Library/Application Support/AgentPetRuntime/bridge.sock
                            │
┌───────────────────────────┼────────────────────────────────────────┐
│ AgentPetRuntime.app       ▼                                        │
│  ┌──────────────────────────────────┐                              │
│  │ BridgeServer                     │  接收 · 去重 · 限流 · 隔离     │
│  └──────────────┬───────────────────┘                              │
│                 ▼                                                   │
│  ┌──────────────────────────────────┐                              │
│  │ AgentRegistry → Adapter          │  agentID 路由                 │
│  │  └─ EventNormalizer              │  rawPayload → AgentEvent      │
│  └──────────────┬───────────────────┘                              │
│                 ▼                                                   │
│  ┌──────────────────────────────────┐                              │
│  │ ActivityEngine                   │  优先级 · 老化 · 保持 · 去重   │
│  └──────────────┬───────────────────┘                              │
│                 ▼                                                   │
│  ┌──────────────────────────────────┐                              │
│  │ AnimationResolver                │  AgentState → AnimationTrack  │
│  └──────────────┬───────────────────┘                              │
│                 ▼                                                   │
│  ┌──────────────────────────────────┐                              │
│  │ FrameScheduler → NSPanel         │                              │
│  └──────────────────────────────────┘                              │
└─────────────────────────────────────────────────────────────────────┘
```

**关键差异**：Agent 从不连接我们。它们 `fork/exec` 一个 shim，shim 主动写 socket。App 未运行时，shim 把事件**减字段后落盘**（spool），下次启动回放（§5.4）；在此之前这里是"静默丢弃"，代价是升级/重启后宠物对正在运行的会话一无所知。

第四列里的两个 Agent 是同一个家族：Pi 与 Oh My Pi 都是进程内 TS 扩展（后者是前者的重命名分支，扩展 API 相同，配置目录不同，事件集也不同，见下），也都由本项目的配置器写入各自目录下的一个文件（`~/.pi/agent/extensions/agentpet.ts`、`~/.omp/agent/extensions/agentpet.ts`），安装即写文件、移除即删文件。两者真正的差别是**事件集不同**（Pi 用 `agent_settled` + `ui_prompt_start`，omp 用 `agent_end`(−`willContinue`) + 审批事件），因此生成文件由同一个模板加事件集与所有权标记等显式参数产出，见 §8.8。

---

## 2. 模块结构（修正 §16）

```
agent-pet-runtime/
├── Package.swift
├── Sources/
│   ├── AgentPetCore/                 # 纯逻辑，零 UI 依赖，100% 可测
│   │   ├── Domain/
│   │   │   ├── AgentState.swift
│   │   │   ├── AgentEvent.swift
│   │   │   ├── AgentActivity.swift
│   │   │   ├── AgentSession.swift
│   │   │   └── Confidence.swift
│   │   ├── Pet/
│   │   │   ├── PetManifest.swift      # 宽容解码
│   │   │   ├── PetDefinition.swift
│   │   │   ├── SpriteAtlas.swift
│   │   │   ├── AnimationTrack.swift
│   │   │   ├── CompatibilityProfile.swift
│   │   │   └── Validation/
│   │   │       ├── ManifestValidator.swift
│   │   │       ├── AtlasValidator.swift
│   │   │       ├── PathSafetyValidator.swift
│   │   │       └── PayloadValidator.swift
│   │   ├── Activity/
│   │   │   ├── ActivityEngine.swift
│   │   │   ├── PriorityModel.swift
│   │   │   └── ActivityClock.swift    # 可注入时钟，测试用
│   │   ├── Bridge/
│   │   │   ├── BridgeEnvelope.swift
│   │   │   └── EventDeduplicator.swift
│   │   └── Integration/
│   │       ├── ConfigTransaction.swift
│   │       ├── ExtensionConfigurator.swift   # 扩展文件类集成（Oh My Pi），见 §8.8
│   │       ├── ExtensionTemplate.swift       # 两个扩展文件共用的生成模板（事件集与所有权标记为参数）
│   │       └── IntegrationState.swift
│   ├── AgentPetApp/                   # AppKit + SwiftUI
│   └── agentpet-hook/                 # shim CLI
└── Tests/
    └── AgentPetCoreTests/
        └── Fixtures/                  # 真实 manifest / atlas 样本
```

`AgentPetCore` **不 import AppKit**。这是硬约束——保证 `swift test` 可以在无 GUI 环境下跑全部核心逻辑。

---

## 3. 动画轨道模型（依官方契约修正）

> 本节在拿到官方契约全文后**重写过**。此前基于猜测的版本有四处错误，见 §3.5。

契约来源（本机即有一份，随 ChatGPT.app 分发）：
`/Applications/ChatGPT.app/Contents/Resources/skills/skills/.curated/hatch-pet/references/`

- `codex-pet-contract.md`
- `animation-rows.md`

### 3.1 播放参数是逐帧毫秒，不是帧率

原方案只给了每行**帧数**，据此实现是错的。契约给出**每一帧的毫秒时长**，且**不均匀**：

| 行 | 帧时长 |
|---|---|
| 0 `idle` | **280, 110, 110, 140, 140, 320 ms** |
| 1 `running-right` | 120 ×7，末帧 220 |
| 2 `running-left` | 120 ×7，末帧 220 |
| 3 `waving` | 140 ×3，末帧 280 |
| 4 `jumping` | 140 ×4，末帧 280 |
| 5 `failed` | 140 ×7，末帧 240 |
| 6 `waiting` | 150 ×5，末帧 260 |
| 7 `running` | 120 ×5，末帧 220 |
| 8 `review` | 150 ×5，末帧 280 |
| 9–10 | 注视方向，见 §3.4 |

`idle` 首末帧是中间帧的 2–3 倍长——那是**呼吸**，不是匀速循环。用单一 fps 无法表达，近似会走形。

因此 `AnimationTrack` 持有 `frameDurations: [TimeInterval]`，**没有 fps 字段**。

### 3.1a Codex 的播放形状（2026-09-13 对齐，两处独立实现互证）

契约给的是**创作值**；Codex 播放时又叠了两个变换，本运行时现在照做：

1. **idle：Codex 的表是 6 倍慢速，本项目不跟。** App 端确实有 `ger = her.map(frameDurationMs * 6)`（TUI 的 `idle_animation` 同样是 1680/660/… 一档），但那个慢速版本在 Codex 里只是**状态播完后的沉降尾巴**——宠物的常态是"有任务"，idle 很少被看到。本项目的桌面宠物**大部分时间就处于 idle**：照搬 ×6 会让常驻呼吸变成 0.6fps，实测反馈"比其他状态慢、像卡住"（2026-09-13）。因此 idle 播放契约创作值 280/110/110/140/140/320，与其它状态同一节奏量级。
2. **一次性状态 = 整行播 3 遍，再落进 idle 段并从那里循环。** App：`uer` 返回 `frames: [...row, ...row, ...row, ...ger], loopStartIndex: 3 * row.length`；TUI：`app_state_animation` 同样是三遍 + `idle_animation().frames`，测试名就叫 `app_running_animation_repeats_then_settles_into_idle`。

本实现落在 `AnimationResolver` 第 3 层：`repeats > 1` 的轨道播完那几遍后交给 idle 轨（用剩余时长取帧），因此不需要"播完标记"。**但 `repeats = 1` 的轨道（running / waiting）是"持续状态"，整行一直循环**——这是对 Codex 组合的一个有意偏离，理由是实测：Codex 里 running/waiting 是*通知*，随状态更新不断重设，而本项目的状态可以持续几十分钟；照搬"三遍后沉降"会让宠物在 agent 明显还在干活时三秒就进入慢速呼吸，看起来像睡着了（用户实测反馈，2026-09-13）。"播三遍再沉降"保留给真正的一次性状态（completed → review、failed）。

**与 Codex 无法对齐的两处，均为有意保留**：拖动中的 locomotion 持续循环（Codex 的拖动是另一种状态机，且拖到一半改为发呆不合理）；`waving`/`jumping` 仍是本项目的手势层（点击问候），不套用三遍+沉降。

### 3.2 轨道分类与驱动源

| 类别 | 行 | 驱动源 |
|---|---|---|
| **State** | 0 `idle`, 5 `failed`, 6 `waiting`, 7 `running` | `AgentState` |
| **Gesture** | 3 `waving`, 4 `jumping` | 瞬时事件 / 用户点击 |
| **Locomotion** | 1 `running-right`, 2 `running-left` | **拖动方向** |
| **Look** | 9, 10（仅 V2） | **指针方位角** |

`review`（row 8）是 state 轨，但 v0.1 没有映射到它的 Agent 状态——Codex 的 review 模式尚未在 hook 中暴露。

### 3.3 状态 → 轨道映射表

契约只说明每行**是什么**，没有规定哪个状态选它。下表是本 runtime 对契约语义的解读，每条都注明依据：

| `AgentState` | row | 播放 | 依据 |
|---|---|---|---|
| `idle` | 0 | loop | "calm, low-distraction breathing/blinking loop" |
| `running` | 7 | loop | "active task work or processing, **not literal foot-running**" |
| `waitingInput` | 6 | loop | "expectant asking pose for approval, help, or user input" |
| `waitingApproval` | 6 | loop | 同上——atlas 只有一个 waiting 姿态 |
| `completed` | 8 `review` | 3 遍 → idle | Codex 自己的映射：回合完成时播 review（"focused inspection of completed output"）并发 "Ready" |
| `failed` | 5 | 3 遍 → idle | "readable error, sad, or deflated reaction"；3 遍之后落进 idle 就是"停止哭丧" |
| `paused` / `unknown` | 0 | loop | 无可展示信息 |

**`waving`（row 3）不由任何 AgentState 选择。** 契约说它是 "greeting or attention gesture"——那是对**用户**的反应，不是对 Agent 的。本 runtime 用它作为**点击宠物时的问候动作**。

`completed` 与 `failed` 走 §3.1a 的播放形状：整行三遍，然后落进 idle 段循环。**没有任何状态会冻结在最后一帧**，也不需要"once"特例——沉降本身就是停止表达。

**reduced motion**：系统要求 + 设置允许时，每一个**动画**都退化为所选中帧的第 0 帧（App 的 `uer(e, true)` 就是 `frames:[n[0]]`）。此前 `respectsReduceMotion` 只是个无人读取的设置项，现已接通。**静态姿态（`LoopMode.staticPose`）除外（2026-09-16 修正）**：注视姿态的列是"看哪个方向"的**选择**，不是时间轴上的帧，归零不是"定格"而是给出错误答案——光标在宠物右侧半屏时显示 `000`、左侧半屏时显示 `180`。见 §3.4。

### 3.4 注视方向（V2 row 9–10）——原方案标为 [未验证] 的问题

契约明确：

> Rows `9-10`: 16 clockwise look directions.
> Row `9`: `000`, `022.5`, `045`, `067.5`, `090`, `112.5`, `135`, `157.5` degrees.
> Row `10`: `180`, `202.5`, `225`, `247.5`, `270`, `292.5`, `315`, `337.5` degrees.
> `000` means up / 12 o'clock, not neutral/front.
> Neutral/front is the no-vector deadzone and falls back to idle.

**已用真实资产验证**：从本机 `some-v2-pet`（V2）导出 row 9–10 全部 16 帧，目视确认是连续顺时针的注视姿态——row 9 c0 仰视、c4 正右、row 10 c0 俯视、c7 回到左上。见 `--diagnose --export-frames`。

实现：

```
sector = floor(((angle + 11.25) mod 360) / 22.5) mod 16
row    = sector < 8 ? 9 : 10
column = sector mod 8
```

半扇区偏移让每个姿态落在扇区中心，指针在 45° 附近抖动时不会来回跳两个姿态。

"Neutral/front 是 deadzone" 的含义是：**没有方向向量时无法确定角度**，回落到 idle。本实现取指针到**精灵中心**距离小于 1pt 为 deadzone（Codex 的 `uuo = 1`），所以屏幕上有光标时宠物几乎一直在看着它。

**角度的坐标系（2026-09-16 修正）**：`LookDirection.angle` 说的是 **AppKit 屏幕坐标**——`NSEvent.mouseLocation`、`NSWindow.frame` 所在的空间，原点在主屏左下、**y 向上**，因此"上"是 `+dy`。Codex 自己是在 DOM 坐标里算这个角（y 向下，`atan2(dx, -dy)`），移植时公式照抄而调用方喂的是 AppKit 点，于是**垂直方向整体镜像**：光标在宠物上方时它低头、下方时抬头，**水平方向却是对的**——所以不容易被发现。活的指针路径此前没有任何覆盖（`--selftest` 的注视断言全部走 `aimGaze(at:)` 强制角度），修正后 `LookDirectionTests` 里有了 AppKit 空间的象限断言。别把它再改回 DOM 的符号，除非调用方换成 y 向下的点。

**注视原点是精灵中心，不是窗口中心（2026-09-16 修正）**。窗口为了面板向上长，`window.frame.midY` 比精灵中心高 `面板高/2`（一行 40pt 面板 → 20pt；四行 → 50pt；精灵本身只有 112×121），指针近时足以偏掉一整档。`petCenterProvider` 现在把 `petView.spriteRect` 的中心换算到屏幕坐标，`--selftest` 在面板拉起的现场核对这一点。

### 3.5 此前版本的四处错误

| # | 曾经的写法 | 实际 |
|---|---|---|
| 1 | 每行一个 fps（8/12/10…） | 逐帧毫秒，且首末帧显著更长 |
| 2 | V2 row 9–10 = "reserved，不播放" | 16 个注视姿态，全部使用 |
| 3 | `completed` → `waving` | → `jumping`；`waving` 是点击问候 |
| 4 | `running-right/left` = "v0.2 由拖动驱动" | v0.1 就由拖动方向驱动 |
| 5 | V2 "部分兼容"，发 warning | V2 完全支持；V1 才是"中间产物" |

契约原文甚至更强硬：

> The 8x9 `1536x1872` atlas is an intermediate assembly artifact only. Never package it as a newly hatched pet.

即 **V2 才是主格式，V1 是遗留**。本 runtime 两者都支持，但 V1 不再被当作基线。

### 3.6 播放层级

`AnimationResolver` 按此顺序决定画面，**先命中者胜**：

```
1. 拖动中        → running-left / running-right   （用户手上拿着它）
2. 手势播放中    → waving / jumping               （one-shot，播完下沉）
3. 指针停在宠物上 → jumping                        （三遍，然后接 idle 段，见下）
4. Agent 状态    → 见 §3.3                        （inactive 状态跳过）
5. 注视方向      → row 9/10                       （仅 V2，且只在 idle 兜底上，见下）
6. idle
```

**注视不是独立一层，而是折进别的行里的**（2026-09-14 照抄 Codex；2026-09-17 两次摘除后只剩 idle）：Codex 的 mascot 只在将要播放的行是 `idle`/`running`/`waving` 时才把 look frame 传下去（`lookFrame: animates ? lookFrame : null`），而 sprite 元素**用 look frame 直接顶掉那一行的播放**（`if (n != null) { backgroundPosition = Glo(n, rows); return }`，定时器根本不启动）。本项目**把这三行里的两行都摘掉了**，理由只有一个：注视姿态是**单帧静态**，被它顶掉的那一行在指针位于屏幕上时（也就是一直）**内容整个消失**。

- **`running` 摘掉（2026-09-17，用户实测）**：顶掉 idle 和 running 用的是**同一个格子**，所以在有 look 行的宠物（V2）身上，干活时和发呆时画出来的**是同一张图**，唯一表示"在干活"的状态恰好成了唯一看不见的那个。现在照播 row 7。
- **`waving` 摘掉（同日，用户点名）**：`waving` 是本项目的手势层——点击问候、以及**初次登场的那次挥手**。被注视顶掉时，宠物的"你好"被画成一次凝视，连菜单里的 `Preview Animation → waving` 也看不到挥手。现在两处都真播 row 3（自检在**钉住方向**的情况下断言这件事，因为真实使用中指针从不在宠物中心）。
- 剩下的只有 **idle 兜底**：没有任何东西要表达的宠物，才交给指针。`waiting` / `failed` / `review`、跳跃、拖拽 locomotion 本来就不在 Codex 的集合里，该播什么播什么（所以"等待你输入"的宠物不会被光标带走）；
- 一个 moment（`completed`/`failed`）播完沉入 idle 尾段时，Codex 的状态仍是 `review`/`failed`，因此**不**接受注视——本项目照此实现；
- 死区是 **1pt**（Codex 的 `uuo = 1`：`Math.hypot(r, i) <= 1` 才算"没有方向"），所以屏幕上有光标时空闲的宠物基本一直在看着它——这是原版行为，不是 bug；
- 注视只对 V2 有（V1 没有 look 行）：Codex 用 `if (n !== r4.version) return null` 挡住，本项目用 `hasLookDirections`。

与 idle 时长（§3.1a）同一类取舍：**照抄 Codex 输给"宠物读得出状态"**。两处都是用户实测报回来的，别在不看一整轮活儿、不看一次开场的情况下改回去。

**第 3 层是照抄 Codex 的**（2026-09-14 补，同日修正）。Codex 的 mascot 组件是 `state: hovered ? "jumping" : state`；至于这一行怎么播，真正的出处是它构造轨道的 `Ulo(state, hasLookFrame)`：

```js
if (hasLookFrame) return { frames: [row[0]], loopStartIndex: null };   // 注视：单帧
if (state === 'idle') return { frames: idleFrames, loopStartIndex: 0 };
let r = [...row, ...row, ...row];
return { frames: [...r, ...idleFrames], loopStartIndex: r.length };    // 其余每个状态
```

**除 idle 与注视单帧之外，每个状态都是"三遍 + idle 段，从 idle 段起无限循环"**——jumping 也不例外。所以光标停在宠物上：跳三遍（约 2.5 秒）**然后接着呼吸，直到光标离开**，不是跳一次然后冻在落地帧。本项目第一版读漏了 `loopStartIndex`（只看定时器里 `if (t.loopStartIndex != null) … else { a = null }` 那一行就下了结论），把 jumping/waving 当成 one-shot 播一遍，用户实测指出后才查回 `Ulo`。现在 `waving`/`jumping` 与 `failed`/`review` 一样是 **moment（`repeats = 3`、`loop: .loop`）**，三层（状态/手势/hover）共用 `AnimationResolver.moment(_:elapsed:)` 这个"三遍 → idle 段"的实现。拖动（第 1 层）与手势（第 2 层）都排在 hover 上面；**放下宠物时重新起跳**（`endDrag` 重置 hover 计时）。追踪区域只覆盖精灵本体，面板上方不算 hover。

两条容易写错的规则：

- **inactive 状态必须跳过而不是返回**。`idle` 是兜底，不是"有话说"的状态。若在第 3 层就返回 idle 轨道，决策提前结束，注视永远轮不到——宠物会永远直视前方。
- **one-shot 播完必须下沉**。只对 `failed` 下沉、对 `completed` 不下沉，会让庆祝动作永久冻结（这个 bug 在实现时真实出现过，被测试抓住）。

拖动的方向判定：横向位移取符号；**竖向拖动保持原方向**——atlas 没有"向上走"的行，光标一抖就翻转会像故障。

---

## 4. Activity Engine 数值规格（补齐 §11.1）

原方案列出了机制名但没有一个数值。以下是 v0.1 的完整规格，**全部通过 `ActivityClock` 注入时间，因此可确定性测试**。

### 4.1 优先级类

```swift
enum PriorityClass: Int, Comparable {
    case attention = 0   // 用户被阻塞，最高
    case failure   = 1
    case active    = 2
    case settled   = 3
    case inactive  = 4
}
```

| `AgentState` | Class | 说明 |
|---|---|---|
| `waitingInput` | `.attention` | 回合结束，轮到用户 |
| `waitingApproval` | `.attention` | 权限提示，通常短暂 |
| `failed` | `.failure` | |
| `running` | `.active` | |
| `completed` | `.settled` | |
| `idle` / `unknown` / `paused` | `.inactive` | |

同类内 tie-break（按顺序比较，先满足者胜）：

1. `waitingInput` 优先于 `waitingApproval`（前者是"该你了"，后者常被自动批准）
2. `enteredStateAt` 更早者胜（先来先服务）
3. `agentID` 字典序（保证完全确定性，避免测试 flaky）

### 4.2 老化（aging）

```
agingThreshold = 90s         // 在非 attention 类中停留超过此值
promotionStep  = 1 class     // 提升一级
maxPromotions  = 2           // 最多提升 2 级
```

目的：一个 10 分钟前 `failed` 的会话，不应该被一个刚刚开始的 `running` 压过去。
`attention` 类不参与老化（已在最高级）。

> **注意**：老化**不能提升到 `.attention` 之上**，也不改变 `attention` 内部顺序。

### 4.3 焦点保持（focus hold）

```
focusHold      = 3.0s   // 绝对保底：刚获得焦点的活动 3s 内不可被抢占
urgentOverride = 1.0s   // 例外：抢占者 ∈ .attention 且当前 ∈ {.settled,.inactive}
```

`urgentOverride` 的存在是为了让"用户被阻塞"能立刻打断"完成动画"或"空闲"，同时不打断正在 `running` 的展示（避免闪烁）。

### 4.4 完成停留（completion dwell）

```
completionDwell = 4.0s   // completed 状态至少展示 4s 才可让位给更低优先级
```

避免「任务完成 → 立刻跳回 idle」的突兀感。

### 4.5 静默超时（stale TTL）

事件流可能中断（Agent 崩溃、终端被杀）。每个状态的静默容忍度不同：

| 当前状态 | 静默阈值 | 超时后转为 |
|---|---|---|
| `running` | **5min** | `unknown` |
| `unknown` | 60s | `idle` |
| `waitingInput` | 不超时 | — （用户可能离开很久） |
| `waitingApproval` | 5min | `unknown` |
| `completed` | `completionDwell` | `idle` |
| `failed` | 10min | `idle` |
| `idle` | — | — |

**`running` 为什么是 5 分钟而不是 30 秒（2026-09-14 修正）**：hook 只在工具调用前后触发，而**单次** Bash 工具可以跑 2 分钟（默认超时上限 10 分钟）、子 Agent 可以跑更久，中间一个事件都没有。30 秒的阈值意味着宠物在 Agent 明明还在干活时放弃动画——这是"宠物不准"的直接来源。代价：会话在回合中被杀（终端被关且没有 `SessionEnd`）时，会以 `running` 多演 5 分钟才沉降。两害相权取其轻。

### 4.5a 会话的保留上限：一天（2026-09-14 修正）

状态超时管的是**状态**，不是**存在**。`SessionEnd` 是唯一干净的结束信号，而终端被杀、agent 崩溃、只装了 status-line tap 没装 hook 的会话都不发它——这三个字典（`activities` / `arrivalOrder` / `lastSeen`）于是只增不减，`currentFocus()` 又把整张表每帧走一遍：实测 2000 个残留会话时单次 `currentFocus()` 4.4 ms，等于 60 fps 下 **263 ms/s 的纯 CPU**，而它们全都看不见（面板 10 分钟就不画 idle 行了，管理器 Activity 列表却还在列）。

现在 `expireStale()` 末尾回收**超过 `silentSessionLifetime`（24h）没被听到**的会话，判据是 `AgentActivity.lastHeardAt = max(updatedAt, context.capturedAt)`——与面板判断"这行还值不值得画"用的是同一个量，status-line reading 证明会话还活着但不算状态变化。三个字典一起清，焦点若在其中则一并清除。

为什么是 24h 而不是面板的 10 分钟：这是**会话不再存在**的时刻，不是"不值得画"的时刻。`waitingInput` 没有静默超时（用户可能离开很久，§4.5），跨夜必须还在——8 小时的测试用例继续通过；一天是上限，不是判决：还活着的 agent 下一个 hook 就会重建它，只是算作新的到达（`arrivalOrder` 一并清掉了）。

测试：`ActivityEngineTests` 四条——50 个被杀会话 23h 时还在、25h 后清空；持续上报 30 小时的不被回收；只有 status-line reading 的会话保持存活且状态不变；复活会话按新到达排序。

### 4.5b 只宣布了自己的会话不建行（2026-09-14 修正）

`SessionStart` 是唯一一个**只证明"有个进程启动了"**的事件，而进程不一定是用户启动的：
Claude Code 的后台 daemon 会**预热**会话（`claude bg-spare` + `bg-pty-host`），
预热进程铸造 session id、触发 `SessionStart`，然后坐在那里等被 claim。
本机取证（2026-09-14 18:14，用户报告"app 还是有一个不存在的 activity"）：

| 证据 | 结果 |
|---|---|
| `~/.claude/session-env/0f45f4b5-…` | 18:14 创建，空 |
| `~/.claude/jobs/0f45f4b5/` | 18:14 创建，除空 `tmp/` 外什么都没有（真实 job 有 `state.json` + `timeline.jsonl`） |
| `/tmp/cc-daemon-501/…/rv/0f45f4b5.sock` | 18:14 创建（与 `spare/8c856c04.*` 同时） |
| `~/.claude/projects/**/0f45f4b5*.jsonl` | **不存在** |
| 进程 | **不存在** |

它触发 `SessionStart` → `resultingState == .idle` → 引擎为未知 session 建 activity。
于是管理器 Activity 列表出现一行 `claude-code · idle · <uuid>`，面板里 10 分钟
（`idleRowLifetime`），列表里 24 小时（`silentSessionLifetime`，§4.5a）——
而且**永远不会被任何后续事件替换**，因为那个会话永远不会说话。

规则：**未知 session 的 `sessionStarted` 不创建 activity**（计入 `droppedEventCount`），
已知 session 仍可被它刷新并落到 `idle`。这正是删掉启动扫描（973c700）时写下的那句不对称：
**真的在干活的会话下一个 hook 会自己报到，而没人能填的空行永远不会结束**。
`contextUpdate` 是例外，仍然建行：一行 status line **正在渲染**是当下的活体证明，
`SessionStart` 只说明某个进程曾经启动（§6.5）。
代价：新开的 `claude` 要等第一句话才出现在列表里；停在提示符上的会话照旧不显示。

测试：`ActivityEngineTests` 两条——单独一条 `SessionStart` 之后 `allActivities()` 为空、`currentFocus()` 为 nil；
已知 session 收到 `SessionStart` 仍然刷新 `lastHeardAt`。

### 4.6 Session 去重

```
dedupeKey = (agentID, sessionID)
```

- 同一 key 同时最多存在一个 `AgentActivity`。
- 新事件到达时**原地更新**，不新建。
- 若 `state` 未变：保留 `enteredStateAt`（不打断老化计时与保持窗口）。
- 若 `state` 改变：重置 `enteredStateAt`。
- 事件乱序（`updatedAt` 早于当前）时**丢弃**，不产生状态回退。

### 4.7 多 Pet 模式（保持方案 §11.2 不变）

Multi Pet 不做全局抢占，按 `agentID` 静态绑定：

```
Pet A ← agentID X 的所有 activity
Pet B ← agentID Y 的所有 activity
```

只共享 ActivityEngine 的状态源，不共享焦点。绑定的 agentID 相同时回退到单 Pet 抢占规则。

---

## 5. Bridge Wire Protocol（补齐 §6.5）

### 5.1 信封格式

shim 投递的是**带版本的信封**，不是已解析的事件：

```json
{
  "v": 1,
  "shimVersion": "0.1.0",
  "agentID": "claude-code",
  "eventName": "PreToolUse",
  "receivedAt": "2026-09-12T01:23:45.678Z",
  "proc": {
    "ppid": 48213,
    "pid": 48214,
    "tty": "/dev/ttys004"
  },
  "rawPayload": "eyJzZXNzaW9uX2lkIjoiYWJjIiwi..."   // base64(原始 stdin 字节)
}
```

设计要点：

| 字段 | 理由 |
|---|---|
| `v` | 协议版本。未知版本 → 丢弃并记一条诊断，**不崩溃** |
| `agentID` / `eventName` | 由 argv 写死，不依赖 payload 解析 |
| `proc` | **shim 的 `getppid()` 就是 Agent 进程**。这是唯一免费可靠的进程关联方式 |
| `rawPayload` | base64 原始字节。**App 侧才解析**，解析失败被隔离在单个 Adapter 内 |

`rawPayload` 用 base64 而非嵌套 JSON 的原因：Agent 的 payload 可能不是合法 JSON（有些 hook 传纯文本），嵌套会导致整个信封解码失败。

**payload 有两个来源，不是一个**（2026-09-15 新增）：hook 类 Agent 按契约把 payload 写在 stdin 上，shim 读它；**进程内的报送方**（Pi 与 Oh My Pi 的扩展，§8.8）改从环境变量 `AGENTPET_PAYLOAD_BASE64` 交给 shim，shim 优先读它——两个扩展都跑在 Agent 自己的运行时里，都有同一个竞态。原因是一次实测：扩展跑在 Agent 自己的运行时里，往管道写数据要排在事件循环上，而 Agent 可能正占着它——spawn 之后忙等 30ms 再写，shim 的 stdin 等待（20ms）就已经超时，事件到达时 payload 为空、**没有 session id**，宠物上会多出一行永远填不上的会话。环境变量由内核在 spawn 时交付，没有可迟到的余地；stdin 那条路照旧，Claude Code / Grok / Codex 一个字节都不变。覆盖测试：`BridgeEndToEndTests.environmentPayload`（stdin 保持打开且永不写入，事件仍须完整到达）。

### 5.1a 实测延迟（2026-09-12，arm64 / macOS 15.7.9）

shim 位于 Agent 的关键路径上，因此这些数字是**决定方案是否可行**的指标，而不是参考值。

| 场景 | P50 | P95 | P99 | max |
|---|---|---|---|---|
| **Runtime 运行中**（正常路径） | **4.33 ms** | 6.27 ms | 6.59 ms | 6.90 ms |
| Runtime 未运行（connect 失败） | 3.81 ms | 5.62 ms | 6.51 ms | 6.53 ms |

预算 P50 < 5ms / P99 < 25ms，**通过**。n=500 时无任何样本超过 8ms。

语言选择依据（最小可执行文件冷启动实测）：

| 实现 | 启动 |
|---|---|
| C | 2.23 ms |
| Swift（仅 Darwin） | 2.56 ms |
| **Swift + Foundation（采用）** | **3.72 ms** |

选 Foundation 而非裸 Darwin：JSON 信封可以用 `nc -U` 直接调试，而换来的 1.2ms 在 5ms 预算内可以承受。

> **注意**：首次调用实测出现过一次 58ms 离群值，发生在 App 刚启动、正在加载并解码 Pet 的瞬间。稳定后（n=500）最大值降到 6.90ms。如果后续观察到周期性尖刺，应检查 App 主线程是否有阻塞工作。

### 5.1b Claude Code 事件映射（依实测修正）

原始映射是**猜的**，且是用户报告 "多个 Claude 运行时宠物卡在等待输入" 的根因。

实测依据：
- 从本机 `claude` 二进制（2.1.268）提取的**完整事件列表**
- 实际 hook payload 抓包（`--log-events`，用自己的会话当样本）
- 同机 `Otty.app` 的成熟实现作交叉验证
  （`/Applications/Otty.app/Contents/Resources/agent-integration/`）

当前 build 派发 **15 个事件**：

```
SessionStart  SessionEnd  UserPromptSubmit
PreToolUse    PostToolUse  PreCompact      PostCompact
PermissionRequest  Notification  Stop  StopFailure
SubagentStart  SubagentStop  TaskCompleted  TeammateIdle
```

修正内容：

| 事件 | 原映射（错） | 现映射 | 依据 |
|---|---|---|---|
| `Notification` | `waitingInput`（**永不过期**） | 仅 `permission_prompt` → `waitingApproval`；其余**不改变状态** | `notification_type` 有 4 种取值：`permission_prompt` `idle_prompt` `auth_success` `elicitation_dialog`。把提醒当"等待输入"会让宠物永久卡住 |
| `PermissionRequest` | 未安装 | `waitingApproval` | 这是**唯一**真正的"被阻塞"信号 |
| `StopFailure` | 未安装 | `failed` | 否则失败和成功无法区分 |
| `Stop` | `completed` | `completed`，但**4 秒后沉降为 idle**，且后台任务运行时降级为 `working` | `Stop` 每回合都触发，不是会话结束 |
| `TaskCompleted` | 未安装 | `completed` | 这才是"任务真的做完了" |
| `SubagentStart` | 未安装 | `working` | 主 Agent 继续跑 |
| `completed` 状态 | 永不超时 | 4 秒后 → `idle` | 否则每个回过的会话都永远显示"已完成" |

**根因说明**：`Notification` 是**杂类事件**，`idle_prompt` 只是"Agent 静了一会儿"的提醒。
把它映射到永不超时的 `waitingInput`，导致只要开过两个会话，宠物就永久显示"等待输入"。
现在唯一会保持的注意状态是 `waitingApproval`——因为那是 Agent **真的无法继续**。

**`Stop` 的后台任务抑制**：`Stop` 在主 Agent 让出控制权时就触发，而后台子 Agent 可能还在跑。
payload 里的 `background_tasks` 若含 `status: running`，说明任务未完成，映射降级为 `working`。
（此技巧来自 Otty 的实现注释，已在本机二进制中确认 `background_tasks` 字段存在。）

**Grok 冲突**：Grok Build 会扫描并信任 `~/.claude/settings.json`，
因此安装在其中的 Claude hook **也会在 Grok 事件上执行**。
shim 现检测 `GROK_HOOK_NAME` 环境变量（Grok 的 hook runner 注入，Claude Code 自身不设）
并把 agentID 改判为 `grok`。

### 5.1c Hook 配置热加载 —— 实测结论

**Claude Code 每次派发 hook 时重新读取 `~/.claude/settings.json`，不是启动时读一次。**

实测方法：`SubagentStart` / `SubagentStop` 原先**不在这套 hook 配置里**，
是在一个已运行数小时的会话存活期间通过 `--configure` 新增的。
新增后 spawn 一个子 agent，两个事件**在同一进程（ppid 未变）中正常触发**。

**产品含义**：配置完不需要重启 Agent——正在跑的任务不会被中断。

**一个需要注意的边界**：hook 是热加载的，但**已发生的状态不会追溯**。
引擎里残留的旧状态会一直挂着直到该 session 发出下一个事件。
UI 因此需要一个显式的 `Clear Activities` 动作。

### 5.2 Session 关联策略

**hook payload 不含终端窗口标识**（见 `SPEC-REVIEW.md` §3.3）。v0.1 的关联顺序：

```
1. payload.session_id        ← 最可靠，若 Agent 提供
2. proc.ppid                 ← shim 采集的 Agent PID
3. (agentID, cwd)            ← 最弱，同目录多会话会冲突
```

`FocusTarget` 只承诺 `open(cwd)`。Accessibility 窗口聚焦推迟到 v0.2。

### 5.3 去重

```swift
dedupeKey = hash(agentID, eventName, sessionID, payloadEventID)
```

`payloadEventID` 从 payload 中尽力提取（如 `tool_use_id`、`call_id`）。提取不到时退化为：

```
同 (agentID, sessionID, eventName) 在 500ms 内只接受第一条
```

### 5.4 未送达事件（spool）——2026-09-14 新增

**问题**：`quit` 后重启、或 `brew upgrade --cask`（先 TERM 掉旧 App 再替换 bundle）期间，hook 照常触发但 socket 不存在，事件被丢弃。结果是宠物重启后对"几秒前还在回合中的会话"一无所知，要等那个会话的下一个 hook 才知道——长工具调用是几分钟之后，多会话时更是只有一部分会陆续报到。用户报告为"重启/升级后无法准确获取 agent 状态，activity 只能抓到部分 session"。

**方案**：shim 投递失败时把事件写进 spool，App 启动时回放。

| 属性 | 取值 | 理由 |
|---|---|---|
| 位置 | `~/Library/Application Support/AgentPetRuntime/pending-events/` | 与 socket 同目录，测试可用 `AGENTPET_SPOOL` 覆盖 |
| 内容 | `EventCapture.sanitizedPayload` 减字段后的信封 | **落盘 = 必须过日志同一条白名单**：`session_id`/`sessionId`、cwd、`tool_name`/`toolName`、notification_type 等（两套拼写见下）；prompt、tool_input/response、last_assistant_message 一律不写 |
| 白名单的两种拼写 | `session_id`/`tool_name`（Claude Code 的 hook）与 `sessionId`/`toolName`（camelCase 的线协议：Grok 实捕信封如此；Antigravity 用的是 `conversationId` 与嵌套 `toolCall.name`，不在这对里） | 2026-09-15 实测漏掉第二种的后果（收敛前 omp 扩展发的是 `sessionId`）：spool 里的事件丢掉 session id，重启回放时该会话以进程名成行，**和它自己的真实行并列**（一行永远填不上）。白名单刻意保持手写而不从 profile 推导——`UserPromptSubmit` 的 `summaryField` 就是用户 prompt，推导式白名单会把 prompt 一起放上盘 |
| 权限 | 文件 0600、目录 0700 | 与事件日志同一标准（不用 `Data.write(.atomic)`：原子写会先建临时文件，权限是 umask 而不是我们的） |
| 上限 | 200 条，超出删最旧 | 文件名前缀是 16 位零填充毫秒时间戳（**不能用 `%016d`**：该格式读 32 位参数，毫秒时间戳会被截断成负数，排序反转、剪枝删掉最新的） |
| 回放 | 启动时 drain，按 `receivedAt` 升序 | 与实时事件走同一条 `BridgeCoordinator.deliver`，因此计数、`--log-events`、归一化行为完全一致；读完即删 |
| 语义 | 回放事件保留**原始时间戳** | 引擎的静默超时按事件自身年龄计算：一小时前的 `working` 回放出来会立刻过期，而不是把宠物点亮 |

回放与实时事件在时间上可能交错：同一个 session 若实时事件先到，旧的回放事件会被引擎乱序保护丢弃（§4.6）——结局仍然是最新状态胜出。

### 5.5 socket 的归属：会应答的 socket 不是我们的（2026-09-14 修正）

原实现 `BridgeServer.start()` **无条件 `unlink(socketURL.path)` 再 bind**。注释写的理由是"崩溃留下的 socket 会让 bind 失败"——对，但它同时意味着：**第二个实例会把正在运行的实例的 socket 删掉**。所有 hook 都连这一个固定路径，所以旧实例从此一个事件都收不到（它的 fd 指向已被 unlink 的 inode，谁也连不进来），直到用户重启它。手工再启动一次 App、`open -n`、或用户从终端跑二进制，都会触发。

现在 bind 之前先**探测**：

| 探测结果 | 动作 | 理由 |
|---|---|---|
| `connect()` 成功（有人在听） | 不 unlink，等待交接，超时后抛 `alreadyRunning` | 抢过来 = 让用户正看着的那只宠物变聋 |
| `connect()` 失败（文件在，没人听） | unlink 后照常 bind | 崩溃残留正是 unlink 存在的意义 |
| 文件不存在 | 照常 bind | 首次启动 |

**等待（`handoverWait` 1s，每 200ms 重探一次）是为升级路径准备的**：cask 先 SIGTERM 旧 App 再装新包，两者可能短暂并存。若没有这段等待，"修好抢 socket"反而会让升级后的新实例起不来 bridge——比原来更糟。

判定用 `connect()` 而不是"文件是否存在"：崩溃残留的文件存在但拒绝连接（ECONNREFUSED），活的 runtime 会应答。探测连接立刻关闭，服务端把它当作一个来了又走的 peer（不写任何东西，不产生"畸形帧"）。

失败面：`BridgeSocketError` 实现了 `CustomStringConvertible`（这些字符串要出现在 Event Bridge 菜单和诊断包里，写的是"发生了什么"而不是"抛了哪个 case"），`BridgeCoordinator` 在 `--verbose` 下额外打一行 stderr——**没有事件和 bridge 起不来，从外面看是一模一样的**，这正是它以前难被发现的原因。

测试：`BridgeEndToEndTests` 里两条——"第二个 runtime 不碰会应答的 socket"（随后用真实 shim 投递，断言仍是第一个收到）与"崩溃残留的 socket 会被回收"（手工 bind 后 close，制造出崩溃留下的那种文件）。

### 5.6 accept 的失败 ≠ 监听结束（2026-09-14 修正）

原 `acceptLoop`：

```swift
let client = accept(fd, nil, nil)
if client < 0 { return }   // "listening socket closed"
```

注释只对了一半：`accept` 的错误里 `EINTR`、`ECONNABORTED`、`EPROTO` 只是**这一个连接**失败了，`EMFILE`/`ENFILE` 是**进程**没描述了。把它们一律当成"监听套接字已关闭"，意味着一次 fd 耗尽就等于：accept 线程退出、socket 文件还在、内核仍接受 `connect`（backlog 有空位时）——但**再也不会有人读**，菜单照样显示 "● Listening"，`status.error` 是 nil，所有 hook 的连接失败后写进 spool 要等到**下次启动**才回放。实测（本机，`RLIMIT_NOFILE` 降到 64，另一个进程持有 70 条连接）复现过：桥接对剩余进程寿命永久死亡。

现在按 errno 分类：`retryNow` / `outOfDescriptors`（退避 100ms 重试，只在进入时报告一次）/ `fatal`（退出，且只在 `isRunning` 时报告——`stop()` 关 fd 也会走到这里，那不是故障）。同时：

- **连接数上限 64**：每条连接是一个线程加一个描述符，没有上限的"每连接一个线程"本身就是把 fd 表打满的路径。超限时立刻 `close` 并报告一次。
- **`SO_RCVTIMEO` 5s**：连接后不说话的对端会一直握着线程；hook 要么立刻发完一帧要么不发。
- **`BridgeServer.isAccepting`**：accept 线程退出时置 false，`BridgeCoordinator.isListening = status.isListening && isAccepting`，菜单与诊断包都改用它——"listening" 必须意味着有人在那儿 accept。
- **主进程抬高 `RLIMIT_NOFILE` 到 4096**（`main.swift`）：GUI 进程由 launchd 启动，软上限只有 256。

`hasListener()`（§5.5）用的是 `connect()`，所以它证明的是"内核里有 listening socket"，不是"有活着的 accept 循环"：在 accept 线程已死而 backlog 未满的状态下它会返回 true，第二个实例于是报告"另一个 runtime 持有 socket"。措辞已改成只陈述已知事实（"holds the bridge socket"），不再断言对方"正在接收事件"。

测试：`BridgeTests` 的 "Bridge accept failures" 三条分类用例（可恢复/退避/致命）。

**线程没起来的那条连接（2026-09-14 补）**：`Thread.start()` 没有失败返回值——系统不肯给线程时，什么都不跑，`readLoop` 的 `defer close` 也就永不执行，那条描述符与连接计数会被留到进程结束（每次丢一格上限）。现在连接在创建线程前先记进 `unclaimed`，线程体的第一件事是 `claim` 它；accept 循环每轮用 `BridgeServer.abandoned(_:now:)` 扫一遍超过 1 秒仍未被认领的（纯函数，有测试），关掉并归还计数。`stop()` 也会收尾所有未认领的连接。

---

## 6. Pet 来源与生命周期（2026-09-13 修正）

### 6.1 唯一的来源：Codex 自己的 pet 目录

```
$CODEX_HOME/                      # 未设置 CODEX_HOME 时即 ~/.codex/
├── pets/<folder>/                # 目录名不必等于 id；manifest 的 id 才是主键
│   ├── pet.json
│   └── spritesheet.webp          # 文件名由 spritesheetPath 指定，缺省即此
└── avatars/<folder>/             # 旧位置，Codex 仍在读
    ├── avatar.json               # 同一格式；id/displayName 可缺省，回退见下
    └── spritesheet.webp
```

运行时**只读**这两个目录，任何情况下都不写入。`CODEX_HOME` 是**替换**而不是追加（与 `codex-pets` CLI、hatch-pet skill 一致）；两个都搜会列出终端 Codex 根本加载不了的 pet。`pets/` 后扫，因此两边同名时以 `pets/` 的包为准——与 Codex 的 picker 一致（它也是先 `avatars` 后 `pets` 覆盖同名条目）。

清单字段的回退照抄 Codex 的 loader（`codex-rs/tui/src/pets/model.rs`）：`id` 缺省取目录名（旧 `avatar.json` 就是这么写的），`displayName` 缺省取 id，`spritesheetPath` 缺省 `spritesheet.webp`。目录名当 id 时仍须通过本项目的 id 校验——`Clippy/` 这样的大写目录若无显式 id 会被跳过，而不是被悄悄改名：本项目存进 config 的每个 id 都要能原样匹配回来。

增 / 改 / 删都不由本项目做：

| 操作 | 标准做法 |
|---|---|
| 安装 | `npx codex-pets add <pet-id>`（codex-pets.net；整包用 `add-collection <slug>`） |
| 更新 | 再跑一次 `add`：它直接覆盖 `pet.json` 与 `spritesheet.webp`（实测 codex-pets@0.3.0 的 installer 就是 `mkdir -p` + `writeFile`） |
| 移除 | 删除 `$CODEX_HOME/pets/<folder>/`。生态里没有 remove 命令；Codex TUI 只有 "Disable terminal pets"（不加载，也不删除） |
| 其他来源 | 手动解压、hatch-pet skill 生成后直接写入——只要目录里有合法 `pet.json` + spritesheet 即可 |

实测 codex-cli 0.153.4 没有任何 pet 子命令，TUI 只有交互式 picker；`codex-pets` CLI 只有 `add` 与 `add-collection`。所以"移除"在标准生态里**就是删目录**，本项目不为此发明第二套语义。

### 6.2 本项目只写一样东西：用户选了哪只

`config.json` 的 `pet.defaultPetID`（`~/Library/Application Support/AgentPetRuntime/config.json`）。启动时按 id 在上面那个目录里解析；解析不到（pet 被删除）则回退第一只，不报错、也不清除旧值——重新装回来即恢复原选择。`--pet <id>` 是仅本次运行的覆盖，不写回。

这是 app 与 pet 唯一的状态关系：**不复制、不注册、不记哈希**。

### 6.3 为什么删掉运行时的自有存储（2026-09-13 反转）

v0.1 实现过一份自有存储（`Application Support/AgentPetRuntime/pets/`，带 provenance metadata、staging 安装事务、Import / Upgrade / Uninstall）。**已整体删除。** 理由：

- **两套列表必然漂移**：用户用 Codex 的标准工具装了一只 pet，本 app 要等一次 Import 才看得到；两个"已安装"列表给出不同答案，是设计缺陷。
- **来源不可复制**：Import 把 `~/.codex/pets/<id>` 复制一份，Codex 侧一更新副本就过期，同一只 pet 出现两个内容哈希。
- **选择入口在 Codex**：终端里跑哪只由 Codex 的 picker 决定，桌面这只由本 app 决定；但"有没有这只 pet"两边读同一份目录，才不会出现两个答案。
- 删除的代价只是一套安装事务、一份元数据格式和 20 个测试。加载与校验（§7）不变——非法包与 Codex 一样**不加载**，不做兜底；但 2026-09-17 起会被**列出来并说明原因**（§7.4），"不兜底"不等于"不吭声"。

`docs/SPEC-REVIEW.md` §2.5 / §3.5 保留了当时的 store 结论，已在该文标注反转。

### 6.4 宠物旁的提示元素（2026-09-13 移植自 Codex）

Codex 的 ambient pet 带一个 notification：四种状态、一行标签、可选第二行正文。TUI 的 PR #21206 自己写明 "The ambient text overlay is currently disabled" —— 数据模型与触发逻辑是完整的，绘制被暂时关掉（所以 TUI 的测试断言标签**不**出现在终端缓冲里）；Codex App 里这个元素是可见的。本运行时把模型完整移植过来，并自己绘制。

| kind | 标签 | 回退正文 | 生命周期 | 触发（Codex → 本项目） |
|---|---|---|---|---|
| running | Running | Thinking | 3 分钟 | 回合开始 → `.running` |
| waiting | Needs input | Needs input | 24 小时 | 审批 / elicitation → `.waitingApproval`、`.waitingInput` |
| review | Ready | Ready | 7 天 | 回合完成（Codex 的正文 = 助手消息预览） → `.completed` |
| failed | Blocked | Blocked | 1 小时 | 出错 → `.failed` |

- **正文 == 标签 → 只画一行，否则两行**：Codex 用同样的字符串比较决定终端里占一行还是两行（`notification_height`）。running 的回退正文是 "Thinking"，所以它总是两行。
- **生命周期从设置时刻起算，状态不变就不重新计时**：渲染循环 60fps，若每帧重打时间戳，一条消息会被无限续命。过期即不再显示，直到状态再次变化。
- **正文来源**（2026-09-13 修订）：`review` 填助手消息预览——Claude Code 的 `Stop` 自带 `last_assistant_message`（该字段存在的目的就是让 hook 不必去读 transcript），归一化时按 Codex 的 `agent_turn_preview` 处理：折叠空白、截到 200 个字符（按 grapheme 截，emoji 不会被劈开）。`waiting`/`failed` 填工具名 / 错误文本。`running` 仍然不填：那里的 `summary` 是用户 prompt，把用户输入摆到悬浮窗上不是本项目的取舍。
- **预览只进内存，绝不落盘**：`last_assistant_message` 不在事件日志白名单里（`EventCapture.capturableKeys`），测试断言它既不在名单、也不会出现在记录中。抓包里它只以 `_omitted_keys` 的名字出现。
- **画在精灵上方，窗口向上生长、原点不动**：等价于 Codex 在精灵上方预留终端行，而不是盖在 transcript 上。窗口高度 = 默认 156pt + 31pt（一行）或 46pt（两行）；`hitTest` 只认精灵区域，点提示文字不会拖动宠物。
- **与动画的关系**：Codex 用 notification 同时驱动动画（running/waiting/review/failed 行）；本项目的动画已由 Activity Engine 的状态表驱动，提示元素只补文字与生命周期，不再重复驱动动画。

### 6.5 会话面板（2026-09-14）

单一提示元素被推广成**每个会话一行**的面板：同一 agent 的会话相邻，组与组之间按各自最优会话的排名排序（即 §4.1 的优先级），组内同样按排名——需要用户的会话永远在最上面，与宠物动画的焦点一致（`ActivityEngine.rankedActivities()` 就是 `currentFocus` 用的那个排序）。

| 项 | 内容 | 数据来源 |
|---|---|---|
| `agent` | 显示名 | `AgentProfiles.displayName` |
| `session` | session id **后六位** | `AgentActivity.sessionID` |
| `task` | 会话名 > 仓库名 > 目录名 | 状态栏 tap（名字/仓库）或 `focusTarget`（cwd） |
| `model` | 模型显示名，有 effort 时拼 `· level` | 状态栏 tap |
| `tool` | 当前工具，**仅 `running` 时显示** | 规则的 `toolNameField`（**不是** `summary`） |
| `context` | 百分比 + 荧光绿横条（#39FF14） | 状态栏 tap；无 tap 则该项不画 |
| `cost` | 会话估计花费 `$x.xx` | 状态栏 tap |
| `limits` | `5h 41% · 7d 13%` | 状态栏 tap |
| `message` | §6.4 的标签（+ 正文） | 每个会话自己的状态 |

**字号、宽度、对齐（2026-09-14 追加，2026-09-16 扩展）**：基准行高 18pt，agent 11.5pt semibold、其余 10.5pt、session 用等宽；面板宽度 = 宠物宽度的百分比（设置里 100–300%，滑杆 + 数值框 + 加减按钮，默认 200%），文字可宽于宠物本体。**对齐是"面板相对宠物"的锚定边，不是行内文字对齐**（2026-09-18 改语义，用户指出）：left = 面板左缘贴宠物左缘向右长，right = 右缘贴右缘向左长，center = 居中（窗口一直以来的行为）；**行内文字永远左对齐**。窗口仍然等于面板，所以精灵不再居中于窗口：`Alignment.spriteOriginX(inWindowWidth:petWidth:)` / `windowOriginX(forSpriteX:...)`（Core，带测试）给出偏移与还原，`PetView.spriteRect`（尾巴、hitTest、追踪区、注视原点都跟着它）、`resizeWindow`、`savePosition` 全用它；存档存的仍是**精灵自己的左缘**，否则一次 left、一次 right 地退出就会把宠物一点点挪走。**整块面板按一个比例缩放**（2026-09-16 起，2026-09-18 改为全面板）：字号设置以"默认 112pt 宠物下的点数"记（默认 10.5pt = 它一直以来的大小，范围 8–20pt），实际大小 = 设置值 × 宠物宽/112，设置界面同时显示换算后的值。**这个比例乘在面板画出的每一个数字上**（`MessagePanelLayout.Metrics`）：四种字体（agent 11.5/其余 10.5/等宽 10.5）、行高 18、行距 2、内边距 9、项间距 8、气泡尾 4、圆角与文字内缩、图标宽 13 与 SF Symbol 点数、上下文条 46×7、各项宽度上限与 `minimumItemWidth`。默认设置 + 默认宠物时比例恰好是 1，所以老用户的面板逐像素不动——这条不变式是硬要求，改完要用 dump 比像素（2026-09-18 实测 200% 全项、255% 用户配置两种都是 0 像素差异）。**面板宽度与窗口也乘同一比例**（2026-09-18，用户决定）：字号设置是整块面板的**缩放**，20pt 时同一 255% 面板宽 1.9 倍（286 → 543pt），否则行会被要求在没变宽的盒子里装下放大 1.9 倍的内容——实测就是绿条压到状态措辞上。注意乘的是**设置值相对默认的倍数**（`设置/10.5`），不是 `Metrics.scale`：后者已经含宠物那一份，而面板宽度本来就跟着宠物走，乘两次会让 224pt 宠物的面板变成四倍宽。为什么不是"只跟宠物"（2026-09-16 的原决定）：消息单独放大时，一行里出现两种字号（20pt 的措辞旁边是 10.5pt 的任务名与 7pt 的条），宠物越大元数据相对越小，读起来像 bug 而不是像默认（用户报告，2026-09-18）。**字号调大不能让状态措辞变少**（2026-09-18 修正）：行的挤压从前把消息和其它灵活项一样压到那一档的常数地板（34pt），于是在 112pt 宠物、255% 宽、20pt 时消息只剩 123pt，而"Needs input"加省略号要 127pt——**把字号调大反而比默认字号少看见一截状态词**（用户报告）。现在消息声明自己的地板：标签宽度 + 省略号宽度（正文可以截，标签不行），挤压先动"只会念名字"的项（任务名、工具名）。**这份声明是全有或全无**：行只有在"其余每一项都保住自己的 `minimumWidth` 之后还剩得下整份措辞"时才付，付不起就退回常数地板 34pt——只付一部分等于什么都没买到（措辞照样被截），却让旁边的项白白让出宽度。

**列、宽度与自动缩放（2026-09-18，用户新规格）规则与理由**：

- **列宽一致（表格化）**：每行按**同一组列**排布，列 = 设置里的项顺序；每列宽度取"带这一项的行"里最宽的一格（`Item.fitWidth`，普通项 = 自身自然宽），某行没有这一项就**留空**，后面的列不左移。此前每行各自挤压，同一个 session id 长一个字符就把该行后面所有项推走，读起来像几张面板叠在一起（用户报告）。挤压也一并移到列上（`columns(for:)` + `squeezed(_:into:)`）：先灵活列、再各自地板、之下整列丢弃 —— 一次性算好，所有行拿同一份答案。
- **fit 到内容（`fitsText`，默认开）**：面板宽 = clamp(内容宽, 宠物宽, 上限)；上限 = 宽度设置 × 宠物 × 字号倍数（`maximumPanelWidth`），auto 时为默认百分比。内容宽 = Σ列 `fitWidth` + chrome。**消息列的 `fitWidth` = 标签 + 省略号 + 固定正文位（`baseMessageDetailAllowance` 120pt × 缩放）**：正文最多 200 字，按整条算面板会永远顶在上限、且每条新消息都改一次宽度；按"只算标签"算，正文又永远没地方画（用户报告的两个极端）。固定的一段位让"在等哪个工具 / 什么失败了 / 助手最后一句"看得见，同时宽度只跟短列走。**下限是宠物宽**：面板是宠物脚下那块地方，不该比宠物窄。
- **宽度调速（`PanelWidthGovernor`，Core，纯值类型 + 单测）**：宽度由内容决定，而内容随事件变（Running ↔ Needs input、正文到达、会话开关）——变宽**立即**生效（新信息不能被截），变窄要等内容**持续**窄 2 秒（从第一次想变窄算起，中途又变宽就重新计时）。否则气泡每隔几秒横抽一下，比固定宽度难看得多。
- **自动缩放（`autoScale`，默认关）**：开启时面板按宠物用**默认比例**画 —— 文字取默认字号（10.5pt@112pt，于是它跟着宠物走）、宽度上限取默认百分比（200% × 宠物）；`widthPercent` 与 `messageFontSize` 两个控件置灰、保留用户值但不生效（用户决定）。关掉即恢复手动值。

规则与理由：

- **"当前工具"只来自 `toolNameField`，绝不取 `title`**：`summary` 可能是用户 prompt（`UserPromptSubmit` 的 summaryField 正是 `prompt`），而面板悬浮在所有窗口之上。为此 `AgentActivity.toolName` 是独立字段，只由声明了 `toolNameField: "tool_name"` 的规则填充。
- **完成/失败的行显示正文，running 的行不显示**——与 §6.4 同一条取舍。
- **行让出空间有优先级**（2026-09-18，用户报告）：挤压按这个顺序收走空间 —— ① **消息的正文**（措辞下的预览，是面板里唯一的"赠品"而不是内容）→ ② **只报名字的列**（session id、模型、工具、占用、花费、额度）→ ③ **任务名** → ④ 最后才是**状态措辞本身**。按列在列表里的顺序收（原先的"先动灵活项"）会让任务永远第一个挨刀：把面板调宽，"proj…"还是"proj…"，多出来的宽度全给了消息正文（实测 255%→300% 逐像素复核）。`--selftest` 钉住它：255%、12pt 的行里任务名的列必须 ≥ 它自己的自然宽。
- **状态措辞永远完整，或被整个丢掉**（2026-09-18）：`Item.preferredWidth` 是"挤压碰到这一项之前先保住多少"，默认 `minimumItemWidth`（34pt）——所以除消息外每一项的行为与从前逐字节相同；消息把它设成 `width(标签 + "…")`，因为"Needs input"被切成"Needs inpu…"等于没说话。挤压的地板 = `preferredWidth ≤ (budget − (ΣminimumWidth − 自己的)) ? preferredWidth : minimumItemWidth`：前一项是"其余每项都保住自己的下限之后还剩多少"，回到旧的常数说明行付不起整份措辞——付一半等于没付，还白白让旁边的项变窄。于是没有新的丢弃、也没有新的溢出：默认字号下的整幅渲染逐像素不变（200% 全项、255% 用户配置两种都实测 0 像素差异）。`--selftest` 在 20pt、255% 的现场核对"drawn ≥ 标签 + 省略号"。
- **idle 行有寿命**：终端被关掉时不会有 `SessionEnd`，一行"闲置会话"如果常驻，就会在宠物旁边飘一辈子。闲置行（`state == .idle`）在 `max(updatedAt, context.capturedAt)` 之后 10 分钟消失；状态栏还在报数的会话因此一直可见（它确实还活着）。
- **`alwaysVisible=false`** 时，面板仅在存在非 idle 会话时出现；出现后显示全部行。
- **窗口横向也要长**：窗口按锚定边生长，底边不动——这样宠物在屏幕上纹丝不动。位置持久化存的是**精灵自己的左缘**（见上面 `Alignment` 的两个换算函数），否则宽面板一次、窄面板一次地退出会把宠物一步步挪走。
- **管理器窗口的尺寸**（2026-09-18，用户报告）：默认 **900×680**、最小 **760×520**、并**记住用户拖出来的尺寸**（`manager.window.size`，存 content 尺寸，和宠物位置一样进 UserDefaults）。原来的 860×580 太矮：Pets 页是"240pt 预览 + 轨道选择 + 名称描述 + 信息网格 + 按钮"一长条，`Use on Desktop`/`Reveal in Finder` 落在折叠线以下，窗口看起来却没有截断的迹象。尺寸在 **`windowDidResize` 里就写**，不能只在 `windowWillClose`：管理器开着被退出时不会触发 close。
- **Pets 页的高亮属于 model，不属于页面**（2026-09-18，用户报告）：`AgentPetModel.highlightedPetID` 记住高亮的 pet，切到别的 tab 再回来还是同一只（页面被 SwiftUI 拆掉重建也不会忘）；首次进入（nil）时默认落在 `currentPetID`，即桌面上正在跑的那只。只在内存里：重启后应该看到"现在正在用的那只"，而不是上次点开看过的那只。
- **宠物尺寸是 Codex 自己的连续滑杆**（2026-09-14 引入，2026-09-16 改成滑杆）：此前窗口硬编码 144×156pt，是 Codex 的 **1.29 倍**（不是 DPI 问题——两边都是 point，只是数字不同）。Codex 自己的设置是 `avatar-overlay-mascot-width-px`，默认 **112**、范围 **80–224**，设置页里就是一根 80–224 的连续滑杆，渲染规则 `width: var(--codex-pet-width); aspect-ratio: 192/208`。本项目 2026-09-14 先做成了它的两端加默认值三档，2026-09-16 改回**同一根滑杆（80–224，默认 112，步进 4）**——三档只是当时的简化，Codex 没有档位。窗口即宠物（精灵按 aspect-fit 填满），面板宽度是宠物宽度的百分比，所以**面板跟着一起缩放**：默认 112pt 宠物 + 默认 200% 时面板最宽 224pt，宠物拉到 224pt 就是 448pt，300% 时 672pt——旧代码里那两个固定上限（288pt 的默认面板、520pt 的窗口）都已不再适用，超出窗口宽度的部分照旧截断文本。
- **配置**（`AppConfig.messagePanel`）：`alwaysVisible` + 有序 `items`（开关与顺序即数组顺序）+ `widthPercent` + `messageFontSize` + `alignment`；宠物尺寸在 `AppConfig.pet.width`（点数）。逐字段 `decodeIfPresent`：`AppConfig`、`PetConfig`、`MessagePanelConfig` 各自实现——合成解码会让"旧版本写下的配置文件缺新键"变成整份配置解码失败，而 store 拒绝半读，结果就是用户的所有设置被静默重置。`pet.width` 还兼容旧键 `"size": "small|standard|large"`（映射 80/112/224，只读不写；旧键用一个独立的 `LegacyKeys` 读，因为带无对应存储属性的 coding key 会让合成编码器直接编译不过）。**新增 item kind 时不需要迁移**：解码时把 items 里不存在的 kind 追加到末尾（管理器只能开关、不能删除条目，所以"缺失"只可能意味着"旧文件"）。
- **重建时机**：每次事件 + 至多每秒一次（状态机会按时钟老化，只在事件时重建会错过它）。管理器不参与：[`MainWindow` 的 1s ticker] 只刷管理器的副本，宠物自己走这条路径。
- **诊断行与画面同源**：`--verbose` 的 `[pet] panel:` 行用与绘制相同的 `MessagePanelLayout.items(for:config:)` 构造，不会打印用户已关掉的项。
- **布局按 (panel, config) 记忆**（2026-09-14）：`AppDelegate.resizeWindow` 每帧都要 plan，而建一张 plan 要逐个 item 量文字（实测 5 行×9 项 = 460 µs，60 fps 下 27.6 ms/s）。面板与配置是"按事件变"而不是"按帧变"的量，所以 `MessagePanelLayout.plan` 记住上一条结果，命中时只做一次相等比较（实测 1.5 µs，约 0.1 ms/s）。

### 6.5a 初次登场的问候（2026-09-14 补，照抄 Codex）

Codex 的悬浮宠物第一次出现时会弹一条 **8 秒**的临时通知（title `Hi, I'm {petName}`，body `I'm here to help keep your ChatGPT sessions moving`），mascot 状态是 **waving**，并且**每只宠物只问候一次**（持久化 key `first-awake-pet-notification-avatar-ids`）。本项目照此实现：`MessagePanel.Greeting.introduction(petName:)` + `Greeting.lifetime = 8`，`loadPet` 成功时若该 pet id 未问候过就 `controller.introduce(petName:)`（挥手一次 + 面板里那一行）。与 Codex 的差异只有一处：body 去掉了产品名（"sessions moving"，因为这里看的是 CLI agent）。**诊断运行（`--selftest`/`--diagnose`）不问候也不记账**——那会花掉用户真正的那一次。已问候的 id 存在 UserDefaults（`pet.greeted.ids`，与窗口位置同类，属于记账而不是设置）。

问候行是 `MessagePanel` 里唯一**不属于任何会话**的行，所以 `MessagePanelLayout.items` 现在会跳过内容为空的 agent/session 项——否则那一行会画出空白的 agent 名和 session 尾号。它也必须能在"没有任何会话"和 `alwaysVisible=false` 时出现：宠物在说自己，不是在显示会话。

### 6.5b 收纳 / 唤醒（2026-09-14 补，照抄 Codex）

Codex 的设置页有 `Tuck Away Pet` / `Wake Pet`（`petVisible`，默认 true）。本项目放在菜单栏（状态菜单与右键菜单同源）：`Tuck Pet Away` / `Wake Pet`，持久化在 `AppConfig.pet.visible`。收纳时窗口 `orderOut` 并 `controller.stop()`（看不见的帧不值得算），唤醒时 `orderFrontRegardless()` 并重新起帧。**应用始终留在菜单栏**——那是唯一的回来的路。

### 6.5c 管理器的窗口：关掉之后 SwiftUI 不再更新它（2026-09-14 修正）

管理器窗口从不释放（AppKit 保留已关闭的窗口与整棵 SwiftUI 树，§6.8 已证），于是留下两个问题：详情页的 30 Hz 预览定时器在关窗后继续空转；整棵视图树在窗口重新打开后可能不再收到 `@Published` 更新。

用探针（`PreviewTimerProbe`）逐条确认过的部分：

- 关窗后定时器继续跑（实测关窗后 0.2 秒内 31 次 tick）；
- 让定时器每次 tick 检查 `window?.isVisible`，它在下一次 tick 就自行停止（实测 0 次 tick）——**这是定时器的修法**，每个预览在窗口离开屏幕后付出一次 tick 的代价；
- 视图树在窗口重新打开后**不会**因为 `@Published` 变化而收到 `updateNSView`——但探针进程不是真正的 app bundle，它的窗口在这个会话里始终拿不到 window server 的"可见"状态（`occlusionState` 恒为 false），而 SwiftUI 对不可见窗口本来就跳过更新，所以"重新打开后是否恢复更新"这一条**探针没能定死**。

因此修法选了不依赖这个答案的那条：**每次重新打开都换一棵新的视图树**（`window.contentViewController = NSHostingController(...)`，旧的随之释放、其定时器已自行停止）。新树必然更新，也就同时覆盖了"旧树其实已经冻结"的可能；代价是每次重开要重新解码一次缩略图（8 只约 140 ms，实测单张 17 ms）。管理器当前所在的标签页因此搬进了 model（`AgentPetModel.section`）——`@State` 会随重建丢失，用户上次停在 Agents 页不该被重置。

**"重开后旧树会不会恢复"这个问题，自检现在每次都会问，并打印答案**（`RenderSelfTest.checkReopenedWindow`：开窗 → 改 model → 计数 `updateNSView` → 关窗 → 重开 → 再计数；基线不过就跳过）。在无头/后台会话里它必然跳过——实测该环境下 `window.isVisible == true` 而 `occlusionState` 恒为 false，即窗口从未被 window server 判定为可见，而 SwiftUI 对不可见窗口本来就跳过更新，于是"冻结"与"没合成"无法区分。**在一个正常桌面会话里跑 `AgentPet --selftest`，那一行会给出 yes/no**；若是 yes，说明这次重建只是保险而非必需（可以再讨论去掉），若是 no，它就是必需的。

### 6.5d 面板里的 agent 列是字形，管理器窗口的侧边栏开关进了工具栏（2026-09-14）

**agent 列**：原来画的是 `displayName`（"Claude Code" 在 11.5pt semibold 下约 75pt），在默认 112pt 宠物、200% 面板（224pt）里占掉三分之一。改成 **SF Symbols 字形**（claude-code `asterisk`、codex `terminal`、grok `bolt`、pi `function`、antigravity `sparkles`、omp `sum`、其余 `pawprint`），固定 13pt 宽；完整名字仍在 `Item.primary` 里，供 `--verbose` 的 `[pet] panel:` 行与图像的无障碍描述使用。

**为什么不用各家 logo**：Claude / OpenAI / xAI 的商标属于各自公司，第三方 app 把它们的标识画进 UI 会同时碰到商标（暗示背书/关联）与美术作品著作权两个问题——这类事要么拿到书面许可，要么别做。SF Symbols 是 Apple 授权给 Apple 平台 app 使用的通用字形，与任何厂商标识都不相像，所以没有这个问题。**同一条规则也适用于其它任何视图**（2026-09-14）：本项目所有 UI 一律不用 emoji，字形只来自 SF Symbols（面板里的 agent 列、管理器 Activity 列、菜单栏兜底图标、菜单里的警告图标）。**这条是决定，不是权宜**：如果将来想用真 logo，先取得许可，别默默换上去。

**侧边栏开关**：用户报"位置在展开/收起时跳动太大"。实测发现根本原因是**那个窗口压根没有工具栏**（`window.toolbar == nil`）——SwiftUI 只在视图声明了 toolbar 内容时才给窗口装工具栏，没有它 `NavigationSplitView` 就退回到"在侧边栏面板里自己画一个开关"，于是开关的位置随侧边栏列的显隐整体横移约一列宽（170pt）。修法是补上惯例的那一半：`MainWindowView` 声明 `.toolbar { ToolbarItem(placement: .navigation) { … } }`（开关自己控制 `columnVisibility` 绑定），窗口设 `toolbarStyle = .unified`（标题与工具栏同一行的常规样式），并补上 View 菜单里的 `Toggle Sidebar`（⌃⌘S）与 `Enter Full Screen`（⌃⌘F）。侧边栏显隐因此和当前标签页一样存进 model（`AgentPetModel.showsSidebar`），重建视图树时不会复位。自检现在量这件事：开关在工具栏里，且收起/展开两态的坐标一致（实测 (91,592) 两态相同）。

**未能在本会话验证的一点**：SwiftUI 退回画的那个 in-content 开关是否随工具栏出现而消失——它由 SwiftUI 自己绘制，不进 AppKit 视图树，而本会话的窗口拿不到 window server 的可见状态（§6.5c），截图手段也不可用。若升级后看到两个开关，说明它没消失，那就把我们的按钮去掉、改用别的方式绑定。

### 6.5e 管理器的 ⌘,：只加在主菜单，不挂状态栏菜单（2026-09-18）

**决定**：`Settings…` 进主菜单（app menu，⌘,），动作是把管理器的 section 设成 Settings 再打开管理器（`AppDelegate.openSettings`）。不新增窗口、不新增设置页，只是把已有的 Settings 那一节接到一个键上。

**为什么不是状态栏菜单**：那条路按仓内既有结论不挂键等价，结论写在代码里（`makeMenu` 的注释）：附件型 app 加上一个不接受焦点的宠物面板，从来不是活动 app，那里的快捷键按不响；广告一个按不动的快捷键比不广告更糟。该菜单里现存的唯一例外是 `Quit` 的 ⌘Q（`AppDelegate.swift:1045`）——它是否真能在菜单跟踪中触发未验证，也不构成本轮的依据（登记为遗留项）。主菜单只在 app 前台时显示，而对这只 app 而言那恰好等于"管理器窗口开着"，所以 ⌘, 真正的用武之地就是**人已经在管理器里、想一步跨到 Settings**，而不是"宠物在桌面上飘着时按 ⌘,"。（后者只有全局热键能做到，而那会把 ⌘, 从系统里所有 app 手里抢走，不做。）

**用户报"按 ⌘, 要等约 1 秒才切到 Settings"（2026-09-18，复现、定位、修掉）**：分层计时发现三块主线程同步开销叠在一起，正好是那 1 秒：① `openManager()` 的 `refreshAll()` 里 `refreshAgents()` 给每个已注册 agent 起一个 `--version` 进程（实测 445–705ms）；② `MainWindowView.onAppear` 又调一次 `refreshAll()`，于是"开一次管理器"这笔开销付**两遍**；③ `show()` 对**已经在屏幕上的**窗口也无条件重建 `contentViewController`（整棵 SwiftUI 树，实测 200–357ms）——重建本来只为"窗口关过再打开"才有意义（§6.5c：离屏窗口 SwiftUI 不再更新）。修法三处，都是"只做这一步需要的事"：`show()` 只在窗口**不在屏上**时重建；删掉视图里的 `onAppear { model.refreshAll() }`（开窗代码已经先刷过，一次开窗只刷一次）；`openSettings()` 在管理器已经开着时不再走 `openManager()`，只把窗口提到前面。结果（自检直接打印动作耗时）：已经开着时 ⌘, 动作 **0–2ms**（修前 652ms）；关着时打开仍约 0.8–0.9s（探测 0.5–0.6s + 建窗 0.3s；进程里第一次开窗的冷启动实测到 2.0s）——那是"每 agent 一个 `--version` 进程"的探测与建窗的既有代价，这次没动（要动就该把探测挪出主线程，那是另一件事；本轮没做）。对应的自检断言：这一按**不得**重建视图树（比较 `window.contentViewController` 的同一性），且动作耗时必须 < 250ms——把重建改回去即失败（实测报出 357ms）。

**"不在屏上"这个判据与诊断运行**：`--selftest` 等诊断运行从不把管理器上屏（上游同日加的 `presents = !HeadlessMode.isActive` 守卫，为的是不把用户从正在打字的地方拽走），于是"在屏上"在那里恒为假。`isOpen` 因此把 `HeadlessMode` 也算作开着：那里没有屏幕要维持，重建只会让自检去量一个用户永远遇不到的重建——实测不这样写，`checkSettingsShortcut` 的第二次按键会走开窗路径而报"重建了视图树"。同时自检找窗口改用**同一性**而不是"按标题找可见窗口"：`close()` 过的管理器窗口（`isReleasedWhenClosed = false`）仍在 `NSApp.windows` 里，而诊断运行里没有任何窗口是可见的，两件事叠加会让标题查找认错窗口。

**自检证据**（`RenderSelfTest.checkSettingsShortcut`，每次 `--selftest` 都跑）：走真菜单 + 真按键事件——先 `NSApplication.sendEvent`（app 自己的键等价通路：事件交给主菜单，主菜单按 key equivalent 匹配再派发），只有它没送达时才退回 `NSMenu.performKeyEquivalent(with:)`，并把**实际送达的那条路打印出来**，不假定；本机全部按键都由 `sendEvent` 送达（管理器窗口一开，app 就是活动 app）。断言的是：主菜单里有那个 ⌘, 项且修饰键恰好是 `.command`（多一个 ⌥ 就是另一个快捷键，菜单匹配不到等于没做）；管理器关着时 ⌘, 打开它并落在 Settings；**已经开在 Activity 的同一个窗口**被移到 Settings；窗口副标题（`navigationSubtitle` → `window.subtitle`）跟着变——模型变了不等于窗口变了，而标题栏与侧边栏读的是同一个 section，重绘了标题栏就是重绘了侧边栏；以及**焦点在 Settings 的数字输入框里时快捷键照样触发**（字段编辑器成为 first responder 后，用窗口自己的另一个菜单快捷键 ⌃⌘S 验证——此处 section 已在 Settings，⌘, 没有可观测的变化，而侧边栏开关可观测）。

**反证**（实测，用来证明这些自检不是空转）：把菜单项的 action 从 `openSettings` 换成 `openManager` → 两条断言都失败（管理器开在 Activity）；把菜单项整行删掉 → 直接报"主菜单里没有任何 ⌘, 项"；把上面那条焦点断言按下的键换成**字段编辑器自己占用的** ⌘A（Select All）→ 字段确实吃掉了它、断言失败（`field editor focused: true`），说明这条断言能分辨"字段吃掉"与"字段没吃掉"。

**未验证**：管理器最小化到 Dock 之后按 ⌘, 会不会被叫回来。本环境拒绝最小化窗口（实测 `miniaturize(nil)` 之后 `isMiniaturized` 仍为 `false`），自检因此打印一行 `– not checked` 而不假定结果。一手文档也答不了：Apple 对 `makeKeyAndOrderFront` 只说"移到最前并成为 key window"，对 `deminiaturize` 只说"还原 Dock 里的窗口"，没有一边说前者会顺手做后者——所以这里没有加那行"保险"代码。

### 6.6 状态栏 tap：上下文用量的唯一来源（2026-09-14）

hook payload **不含**任何 token 计数——在 2.1.268 的二进制里逐字段确认过：`used_percentage` / `context_window` 只出现在**状态栏** JSON 的 schema 中（`context_window.used_percentage`、`context_window_size`、`total_input_tokens`、`session_name`、`workspace.repo.name`）。这个数字只有 Claude Code 自己算得对：上下文窗口大小取决于模型，而网关背后的模型名外部无从得知（本机实测同一条会话已占用 302k token）。

因此 tap 的做法是**包住用户已有的状态栏命令**，而不是替换它：

```
statusLine.command = "<shim>" --agent claude-code --statusline --original <base64(原命令)>
```

- shim 依次做两件事：把 stdin 的 JSON **减字段**（`session_id` / `session_name` / `used_percentage` / `window` / `tokens` / `repo 或 project 目录名`，与原命令无关的 transcript_path、cost、rate_limits 全部丢弃），投递到 bridge；然后 `bash -c` 运行原命令，**stdin 原样传入、stdout/stderr 原样透传、退出码原样返回**。Claude Code 看到的仍是它原来的状态栏。
- **永不 spool**：状态栏每次渲染都会被调用，spool 会被同一事实的副本淹没。投递失败即丢弃。
- **协议**：`Statusline` 事件 → 规则 kind `.contextUpdate` → `AgentEvent.context`。引擎里它走独立路径：**不改状态、不刷新 `updatedAt`、不参与超时**——状态栏在提示符处也在渲染，若算作"活着"，用户中断的回合会永远显示 running。它同时是"这个会话存在"的证据：对未知会话会创建一条 `idle` 活动（这就是重启后面板能立刻列全开会话的原因）。
- **敏感度**：`session_name` 是用户自己起的名字（`/rename`），显示在用户自己的屏幕上，但不进任何日志（不在 `EventCapture.capturableKeys`，也不在 shim 的归约之外）。
- **事务与可撤销**：走与 hook 相同的 `ConfigTransaction`；`entriesPresent` 检查"现在文件里的命令是否仍是我们写的那条"；若用户后来自己改了状态栏则显示 drifted，卸载时**不动别人的东西**。记录里 `statusLine.original` 保存原命令用于还原；没有原命令时卸载会把 `statusLine` 键整个删掉（不留空壳）。
- **幂等与去嵌套**：重装时先解包——识别依据是 `--original` 的 base64 内容而不是 shim 路径，所以 app 换位置后重装得到的是"包住原命令的新 wrapper"，而不是"wrapper 套 wrapper"。
- **自毁保护（2026-09-14）**：wrapper 是 `if [ -x <shim> ]; then …; else <原命令>; fi`。用户 `brew uninstall` 把 app（连同 shim）删掉时，状态栏自动退回他们自己的命令——否则他们的提示符会试图执行一个不存在的路径。fallback 单独成行而不是跟在 `;` 后面：原命令以 `#` 注释结尾时会把后面的东西一起吞掉。
- **字段范围（对齐官方文档）**：tap 之后 `SessionContext` 覆盖 `context_window.used_percentage/context_window_size/total_input_tokens`、`model.display_name`、`effort.level`、`cost.total_cost_usd`、`rate_limits.five_hour/seven_day.used_percentage`、`session_name`、`workspace.repo.name/project_dir`。**不取**：`transcript_path`（绝不）、`prompt_id`、`cost` 的时长/行数、`rate_limits.*.resets_at`、`prompt_cache.*`、`workspace.added_dirs/git_worktree/host/owner`、`exceeds_200k_tokens`、`thinking`、`fast_mode`、`output_style`、`version`。`session_name` 可能是 AI 生成的会话标题（模型输出）——与助手预览同一决策：只进内存、上屏，不落盘。
- **成本（实测 2026-09-14，release，arm64）**：裸命令 `sh -c` 6.21ms/次；经 wrapper（shim + bash + 管道）8.19ms/次，即 **tap 只加约 2ms**（hook 事件本身约 7.3ms，同量级）。Claude Code 每次渲染都会调用、300ms 去抖；这个数字必须守住。**注意**：`Foundation.Process` 在本机每次 spawn 要 ~65ms（同一命令 `posix_spawn` 2.15ms / `Process` 66.78ms）——最初版本用 Process 直接给状态栏加了 68ms，已改为 `posix_spawn` + 管道。谁再改这里，先跑基准。
- **生效时机**：Claude Code 会热重载设置——文档原话 "reloads settings automatically and runs your script as soon as you save the file"，改 `command` 会立即用新命令重跑一次。因此 enable/disable 不需要重启会话。

### 6.7 其他 agent 的状态行能力（2026-09-14 调研，逐本机二进制取证）

面板里 tap 才能提供的项（model/context/cost/limits）在各 agent 上的可得性，按本机安装的具体版本来确认，不靠文档转述：

| Agent | 版本 | 机制 | 结论 |
|---|---|---|---|
| Claude Code | 2.1.268 | `statusLine.command`，stdin 传 JSON（§6.6） | **已实现**：tap 直接读取 |
| Grok Build | 1.0.24 | `[ui.status_line]`，`type = "command"` 时**同一套 JSON 契约**（二进制内置示例：`echo '{"session_id":"t",...,"context_window":{"used_percentage":25}}' \| ./statusline.sh`），300ms 去抖、启动时读取 `config.toml` | **已接线**：`GrokStatusLine` 往 `config.toml` 追加 `[ui.status_line]`（`type = "command"`，命令打印空以保持终端外观），独立开关，见 §6.7b |
| Codex | codex-cli 0.153.4 | `tui.status_line = [...]` 只有**内置项**（`context-used` 等，无自定义命令）；`notify` hook 的 payload 不含任何 token 数据 | **不可得**：唯一的替代是读 rollout/transcript，本项目不读 |
| Pi | @earendil-works/pi-coding-agent | 扩展 API 暴露 `ctx.getContextUsage()`、`ctx.sessionManager.getEntries()`（token 统计）、`ctx.model`（类型定义原文："Context usage on ctx.getContextUsage(), token stats on ctx.sessionManager.getEntries(), model info on ctx.model"） | **已接线**：`PiConfigurator` 装入 `~/.pi/agent/extensions/agentpet.ts`（与 Oh My Pi 同源同一个模板），每次结算发一条 `context_update` |
| Oh My Pi | 18.1.22（`@oh-my-pi/pi-coding-agent`） | 与 Pi 同一套扩展 API（`ctx.getContextUsage()` / `ctx.model`），扩展由本项目装入（§8.8） | **已接线**：与 Pi 的扩展同源同一个模板，每次 settle 也发一条 `context_update`（同一套减字段形状） |

所有 agent 共同的**不做**：不读 transcript、不读 rollout 文件、不猜窗口大小——这正是 Claude Code 的 `used_percentage` 值得专门包一层的原因（网关模型窗口只有它知道）。

事件面（hooks）的可得性已补测，见 §6.7b（2026-09-15）。

### 6.7b 其他 agent 的事件接口（2026-09-15 调研，扩展 §6.7）

§6.7 量的是**面板数据**（model/context/cost/limits）的可得性；这一节补**事件面**（会话、回合、工具、等待、失败）。证据来自本机二进制、随发行版分发的官方文档与线上官方文档；未运行任何被测 agent 的会话，行为验证留到接线时（先测清单在节尾）。四家的共同点：**没有一家需要读 transcript/rollout**，"不读内容文件"的契约一条都不用破。

- **Grok Build 1.0.24：可完整接线（事件 + 状态行）。** hooks 的官方载体是 **JSON**：`~/.grok/hooks/*.json`（全局、永远信任、无需项目信任），`config.toml` 内联 `[[hooks.<Event>]]` 只是替代写法（`~/.grok/docs/user-guide/10-hooks.md`）。§6.7 表里"TOML 挡住 Grok"只对**状态行**成立。15 个事件，比 Claude 多 `StopCancelled`（中断）、`PostToolUseFailure`、`PermissionDenied`；`Stop.lastAssistantMessage` 就是面板要的正文（文档原话：hooks 不必解析 transcript）；会话结束时额外一次 `Stop`（`reason != "end_turn"`）必须过滤。信封以 camelCase 为主但**别名并不统一**（实捕，2026-09-15）：`session_id` / `hook_event_name` / `permission_mode` / `transcript_path` 有 snake 别名，tool 事件连 `tool_name` / `tool_input` / `tool_use_id` 都有；而 `lastAssistantMessage` / `backgroundTasks` / `notificationType` 是纯 camelCase。`AgentProfiles.swift` 的 grok profile 已按实捕字段换成独立规则表（2026-09-15 Phase 1；fixtures 在 `Tests/AgentPetCoreTests/Fixtures/grok/`）。
  **compat 是否真的在跑：已定案（2026-09-15 实测）**——headless 会话用假 socket 截获 7 帧，全部经 shim 的 `GROK_HOOK_NAME` 改判以 `agent=grok` 投递（该改判早已在 shim 里，见 §5.1b 附近）。此前"查无痕迹"是因为 hook 成功不写日志、而 grok 无记录文件。**Phase 2 已接线（2026-09-15）**：`GrokConfigurator` 写 `~/.grok/hooks/agentpet.json`（14 个事件，含 `StopCancelled`），并在 `~/.grok/config.toml` 末尾追加 `[compat.claude] hooks = false`（`TOMLSectionEdit` + `ConfigTransaction.performText`：只追加、记录实际追加字节、按字节精确删除；用户自己已写的 `[compat.claude]` 表则拒绝并回滚这次调用写的 hooks 文件）。实机验收：`grok inspect --json` exit 0、`externalCompat` 里 claude/hooks `enabled: false`、14 条属于我们的 hooks 生效、真实会话后 `--status` 显示 Connected；`--unconfigure` 后 `config.toml` **字节级还原**（sha256 前后一致）。
  **Phase 3 状态行已接线（2026-09-15）**：`GrokStatusLine`（独立 record `grok-statusline`、独立开关，同 Claude tap 的 opt-in 原则）往 `config.toml` 追加一个 `[ui.status_line]`（`type = "command"`，命令=`if [ -x shim ]; then shim --agent grok --statusline; fi`——**打印空**，行永不出现，终端外观零变化；自毁保护沿用 Claude tap 的写法）。shim 零改动：`runStatusLineTap` 无 `--original` 时打印空并正常投递，`reducedStatusPayload` 的键与 grok statusline payload 全部同名（实捕核对）。**已知验证边界**：状态行命令只在 TUI 的 agent view 活跃时被调用（官方文档），headless 会话不会触发——本机实测 `grok -p` 只产生钩子帧、无 Statusline 帧。因此这一跳由 shim 侧 e2e（`grokStatusLineMode`：打印空 + 投递 + contextUpdate 归一化）加金样块文本测试覆盖，grok 是否真的调用它属官方文档行为，留待用户的第一次真实 TUI 会话（面板出现 Grok 的 model/context 即验收）。
  **Pi 已接线（2026-09-15）**：`PiConfigurator` 写运行时独有的 `~/.pi/agent/extensions/agentpet.ts`——纯 JS（node 内建 `child_process`/`path`）、标记头、**无 npm、无 settings 编辑**（Otty 的 `otty-integration.ts` 是同款先例）；卸载按**记录条目**判定（与 Oh My Pi 同一条规则，见 §8.8）并先备份再删；覆盖前仍认标记头——用户自己的文件拒绝覆盖。扩展（与 Oh My Pi 的扩展同源同一个生成模板，见 §8.8）**只在结算点报 `agent_settled`**（`agent_end` 之后 Pi 还可能自动重试/压缩/续跑，profile 不再映射 `agent_end`/`turn_end`，改为覆盖扩展实际发送的事件集）；上下文在结算时以 `{session_id, tokens, window, used_percentage, model}` 上报——与状态行 tap 同一归约形状，`used_percentage` 由 `ctx.getContextUsage()` ÷ `ctx.model.contextWindow` 自算。实机验收：真实 pi 会话（headless）经假 socket 截获 5 帧——`session_start` / `agent_start` / `agent_settled` / `context_update`（`{"tokens":6,"model":"Claude Opus 4.8","window":1000000}`）/ `session_shutdown`，模型调用因本机 provider bearer 过期报 401 而未能跑工具；工具分支由**假宿主 harness**（node 直接 drive 已安装的扩展文件）补齐 `tool_execution_start` 帧；真实投递后 `--status` 显示 Connected。**坑**：pi 的 `-p` 非交互模式会等待 stdin EOF——脚本里必须 `< /dev/null`，否则静默挂起。
  **吸收 PR #1 的三件机制（2026-09-15，作者 CaffreySun，均带回归测试）**：① `ConfigTransaction.pruneBackups` 改按**文件 mtime** 剪枝——按名字剪枝在多来源备份目录里会把本次调用刚生成的备份立刻删掉（`agentpet.json.*` 永远排在 `settings.json.*` 前；本仓库的备份目录从 Grok 接线起就是多来源，属活 bug）；② `EventCapture.capturableKeys` 增加 `sessionId`/`toolName` camelCase 拼写——否则进程内扩展的事件落 spool 时丢 session id、回放时该会话以进程名多出一行填不上的行（白名单仍保持手写、不从 profile 推导，理由见注释）；③ shim 的 payload 增加第二来源 `AGENTPET_PAYLOAD_BASE64`（**stdin 契约一字未动**，钩子类 agent 不受影响）——进程内扩展往管道写数据排在 agent 自己的事件循环上，实测忙 30ms 即错过 shim 的 20ms stdin 等待、事件丢 session id；环境变量在 spawn 时由内核交付，无此竞态。**Pi 扩展已切换到该机制**（模板测试钉住 `AGENTPET_PAYLOAD_BASE64`，并断言不含 `child.stdin`）。Oh My Pi 本体支持即 PR #1（本分支）：§8.8 记其扩展文件类集成，§6.7 的 omp 行与两份 README 同步为「已接线」。
  **Codex 已接线（2026-09-15）**：`JSONHookConfigurator` 直接复用——`~/.codex/hooks.json` 与 Claude 的 `settings.json` 是同一 schema（`{"hooks": {"<Event>": [{matcher, hooks: […]}]}}`），写入 12 个事件（`SessionStart/End`、`UserPromptSubmit`、`Pre/PostToolUse`、`PermissionRequest`、`Pre/PostCompact`、`SubagentStart/Stop`、`Stop`、`Interrupt`），与本机 Otty 已有的 4 条条目合并、卸载只删自己。profile 按二进制 wire structs 的字段重写（`session_id`/`hook_event_name`/`model`/`permission_mode`/`tool_*`；`cwd` 见官方字段表；`last_assistant_message` 未承诺——有则预览、无则无）；`Interrupt` → completed；`Notification`/`TaskCompleted`/`StopFailure` 在 Codex 不存在，规则一并去除。新增 `AgentIntegrationProfile.postConfigureHint`：Codex 的信任门是用户自己的动作，configure 后 CLI 与管理器状态栏都会打印 "run /hooks to review and trust them once"。实机验收：`codex doctor` exit 0（22 ok · 0 warn · 0 fail）、合并/卸载/重装全过且 Otty 的条目逐字节保留。**待用户动作**：在 Codex TUI 里 `/hooks` 信任一次事件才会流动；之后可用假 socket 实捕信封，把 fixtures 从"二进制推导"升级为"实捕"。另注意 codex 会自动更新（本机在取证当天 0.153.4 → 0.154.0）。
- **Pi 0.85.1：可完整接线，改动最小。** 单个 `.ts` 放 `~/.pi/agent/extensions/` 即自动发现、可 `/reload`（pi 包内 `docs/extensions.md`）；只用 node 内建模块，**不需要 npm 包**——registry 旧注"装包是重操作"不成立。事件全覆盖，`ctx.getContextUsage()`（`extensions.md:1066`）给上下文，`ctx.model` 给模型。注意 `agent_settled` 才是"真正停下"（`agent_end` 之后还可能自动重试/压缩/续跑），把完成映射到 `agent_end` 会在这些窗口误报。本机先例：Otty 的 `~/.pi/agent/extensions/otty-integration.ts`（detached spawn、session id 取会话文件 basename，可照抄）。
- **Codex 0.153.4：事件面已补全，两道坎。** `codex features list` 里 `hooks` 已是 `stable`；官方 hooks 在 `~/.codex/hooks.json`（JSON、Claude 同形 schema 与 payload；事件含 `PermissionRequest` / `Interrupt` / `Subagent*` / `Pre/PostCompact`）。坎一：非托管 hooks 必须在 TUI `/hooks` **人工 review + trust**，按 hook 内容 hash 记录、改动即失效重审，没有程序化信任（openai/codex#21615 仍开放）——"写完了配置"不等于"在跑"；`allow_managed_hooks_only` 之类的企业策略可直接封掉用户钩子。坎二：仍无自定义状态行，§6.7 表里 Codex 那行（面板数据不可得）**继续成立**。另：`~/.codex/hooks.json` 本机已被 Otty 占用（`_otty` 标记），写入必须合并、不碰别人的条目。
- **Antigravity（2.0 + CLI，2026-05-19 I/O 起）：官方接口存在，但只到"部分"。** 官方 hooks（antigravity.google/docs/hooks）：`hooks.json`，全局 `~/.gemini/config/hooks.json`、工作区 `.agents/`；格式是命名映射（`{"<名>": {"PreToolUse": [...], …}}`），我们只占一个 key，合并与卸载语义最干净；只有 5 个事件：`PreToolUse` / `PostToolUse` / `PreInvocation` / `PostInvocation` / `Stop`。信封带 `conversationId`（=会话 id）、`workspacePaths`、`modelName`；`Stop` 带 `terminationReason`（`model_stop` / `max_steps_exceeded` / `error`，能分完成与失败）和 `fullyIdle`（后台未完，对应 Claude 的 background_tasks 抑制）。**没有 SessionStart/SessionEnd，没有等待输入事件**——宠物画不出"需要你"，这是与 Claude 最主要的差距。官方状态行（/docs/cli/statusline）：`~/.gemini/antigravity-cli/settings.json` 的 `statusLine`（`type = "command"`），payload 含 `session_id`、`model.display_name`、`context_window.used_percentage`——与 Claude 的状态行契约同形，shim 第三度复用。接口还年轻：2026-08 仍在改 hook 排序、同步 hooks、参数改写、compaction 钩子；全局路径近期从 `~/.gemini/antigravity-cli/hooks.json` 修到 `~/.gemini/config/hooks.json`（以装好的版本实测为准）。IDE 2.0 是否读同一 `hooks.json`：文档是产品级、changelog 有 IDE 生命周期 hook 条目，中高置信、待实测。已死的路：VS Code 扩展兼容在 2.0 被移除；语言服务器 `exa.language_server_pb` gRPC（需 CSRF token，本机旧日志可见该服务）是逆向面，**不做**。本机未装 CLI（`agy`，`~/.local/bin/agy`）。
  **Antigravity 已接线（2026-09-15 实测 + 实现）**：本机装 `agy` 1.2.3 并登录（免费档即可）。**未登录时 `agy -p` 停在鉴权环节、agent 循环不启动、任何 hook 都不触发**（实测：弹 OAuth URL 等 60 秒超时）。捕获用临时探针 hooks.json + 假 socket（事后全部清除、settings.json 按 sha256 逐字节还原），推翻/补足了官方文档：hooks.json 命名映射中**工具事件是 matcher 分组、其余是扁平 handler 列表**；payload 是 protojson camelCase；**`SessionStart` 真实存在**（二进制 proto 有、文档事件表没有，实测触发，载荷只带 common 字段）；**`PostToolUse` 注册但从不触发**（3 个工具 0 次）；`Stop` 的 `terminationReason` 实测为 `NO_TOOL_CALL`（不是文档示例的 `model_stop`），proto 里的 `finalModelOutput` 实捕没有；`executionNum` 恒 0。其他实测：hook 失败 **fail-open**（一次脚本全丢失的运行里 agent 照样 SUCCESS、错误只进日志）；钩子 stdout 契约"必须回 JSON"而 PreToolUse 的 `decision` 是**必填**、没有 no-op 一档——当初"**`{}` 经单命令 allowlist 的工具调用实测为无副作用答案**"这条结论是**错的**（下面 2026-09-17 的纠正）；钩子进程 cwd = hooks.json 所在目录；环境里注入 `ANTIGRAVITY_CONVERSATION_ID`（shim 据此改判，同 `GROK_HOOK_NAME` 的手法）。实现：`AntigravityConfigurator`（命名钩子 `agentpet`，**6 事件**，`SessionStart/PreInvocation/PostInvocation/Stop/SessionEnd` 扁平 + `PostToolUse` 分组；**不注册 `PreToolUse`**，理由见下）+ profile（点路径读 `toolCall.name`、数组取首读 `workspacePaths[]`、`fullyIdle: false` 抑制完成、`error` 非空判失败、`terminationReason` 不参与过滤）+ shim 对 antigravity 钩子回 `{}`（唯一允许写 stdout 的例外，注释写明契约）+ 状态行 tap（`--render-row` 渲染 `dir │ model │ N% ctx` 替代内置行；**headless 不触发状态行**，TUI 验收留给用户）。规则引擎为它扩了三个通用件：**点路径字段读取、数组取首、`suppressedWhenFalseField`/`requiresNonEmptyField` 两个条件**。实机验收：`--configure antigravity` 写入 hooks.json、真实会话经真 shim 投递 4 帧（SessionStart/PreInvocation/PostInvocation/Stop，全部 `agent=antigravity`）、卸载/重装干净（空文件壳 `{}` 与 grok 同款，注释在案）。
  **纠正（2026-09-17，用户 issue #3/#4）：`PreToolUse` 是必填表态的门，观察者站在那儿会把 agent 的工具调用全部锁死。** 契约（二进制内嵌 + 装机自带 `agy-customizations/docs/hooks.md`）把它写成 `decision` **required**，只有 `allow/deny/ask/force_ask`——没有"无意见"；实现里**缺 decision = 拒绝**。外部复现：一位用户用一个只打印 `{}` 的 PreToolUse 钩子拿到 `tool call denied by pre-tool hook:`、**reason 为空**（crossby#147，agy 1.1.14；正对 agy 自己的模板 `tool call denied by pre-tool hook: %s` 插空 reason；同类报告 ai-memory#352；cmux#8921 证明**钩子挂住/超时同样 deny**，即"失败只有加载不进去时才 fail-open"）。我们的 shim 对 antigravity 的每个事件都回 `{}`，于是 0.10.0 的集成**把每一次工具调用都判死**：模型侧看到 `Error invalid tool call: … (invalid_args) tool call denied with reason:`、用户侧只看到 `Tool call denied by pre-tool hook:`（两层文案对齐见 antigravity-cli#575，也解释了为什么两处粘贴的冒号后面都是空的——用户面对的 UI 本来就不带 reason）。**两条教训**：①任何"必须表态"的钩子事件都不能注册，观察者只能挂在不需要表态的事件上（`PostToolUse` 的契约就是 `{}`，`Stop` 明说"其它值都放行"，这两类安全）；②**契约的必填字段不能拿"实测看起来没事"豁免**——那次实测用的是 allowlist 放行的调用，很可能根本没走到表态分支，而它却当了真。修复：不再注册 `PreToolUse`（profile 照旧读它，兼容老配置与用户自己加的钩子），并加了启动迁移 `removeObsoleteEntries`（`AgentConfigurator` 默认返回 nil，`AgentIntegrationService` 在启动时调用，UI 底部条留一行说明）：只摘自己记录过的那几条、只在文件仍是当初写下的样子时动手（用户改过就交给健康检查报 drift），**且不重新指向 shim**——否则并排跑一个开发版就会把已安装版本的钩子抢过去。
- §6.7 的旧注里唯一还站得住的：**Codex 的面板数据不可得**。"Grok 是 TOML 所以不能动""Codex 只有 notify""Pi 要装包"三条都已被上面的证据取代。

**接线时的先测清单（行为验证，全部留到实现时）**：Grok compat 是否在实际会话里重放我们的钩子（开 pet 跑一次 grok，看 Activity 是否出现贴错标签的会话）；Codex `Stop` 是否带最后一条助手消息（官方字段表未列，旧版 notify 有 `last-assistant-message`）；Pi 内置权限提示是否走 `ui_prompt_start`；Antigravity 的 IDE 2.0 是否读同一 `hooks.json`、状态行 payload 是否含 cost（2026-08-26 changelog 提到 cost metrics，文档示例未见）。

### 6.8 管理器的预览：一行一张静止图，详情页才留图集（2026-09-14 修正）

Pets 页原本为**每个已装 pet** 保有一份解码后的 `SpriteFrames`（1536×1872 的图集 = 11 MB 像素，而 `makeCGImage` 还会让 CGImage 自己再持有一份拷贝，实测 12.3–14.3 MB/pet），理由是"列表重绘时现解码会卡"。代价是管理器内存随用户装了多只宠物线性增长：8 只 ≈ 100 MB，50 只 ≈ 600 MB。

**而这些内存没有归还路径**：`windowWillClose` 里丢掉窗口引用、清 `contentViewController`、`isReleasedWhenClosed = true`——三种写法都试过（探针 `WindowCloseProbe`），AppKit 保留着已关闭窗口（`NSApp.windows` 仍在列表里）以及它的 SwiftUI 视图树，闭窗后窗口、hosting controller、视图**一个都没释放**。所以修法不是"释放窗口"，而是让被保留的东西变便宜：

- 列表行要的只是 40pt 的静止画面 → `PetLibrary.thumbnail(of:fitting:)` 解码一次、把 idle 第 0 帧画进小 context，得到一张几十 KB 的 `NSImage`，图集随即释放（实测：8 只宠物列表 ≈ 4 MB，且不再随装机量增长）。
- 详情页是唯一真正播放动画的地方 → 只为**选中**的那只保留 `SpriteFrames`（一张图集），换选择即释放。
- 行不再各持一个 30 Hz 定时器（20 只 = 630 次/秒的唤醒），只有详情页那一个还在跑。

残留：详情页那一个 30 Hz 定时器在窗口关闭后仍在跑（视图树不会被拆），一次唤醒 30/s——相对宠物本体的 60 Hz 帧循环可忽略；要彻底停掉需要一个由管理器关闭事件驱动的 `isAnimating` 标志。

---

## 7. 校验规格（补齐 §8.4 "Validate atlas"）

### 7.1 校验顺序（短路，前面失败不执行后面）

```
1. ManifestValidator
   ├─ JSON 可解析
   ├─ 必需字段存在: id, displayName, spritesheetPath
   │   (description 缺失时用 displayName 兜底，不报错)
   ├─ id 非空、匹配 ^[a-z0-9][a-z0-9._-]{0,63}$
   ├─ spriteVersionNumber 可选：1/2 与实测尺寸互为校验，矛盾即拒绝；
   │   缺失或为其它值（3、0…）→ 忽略，按尺寸判定（§7.4）
   └─ 未知字段 → 忽略（不报错）

2. PathSafetyValidator
   ├─ spritesheetPath 规范化后仍在 package root 内
   ├─ 无符号链接逃逸（对每一段路径段做 lstat）
   └─ 无绝对路径

3. PayloadValidator
   ├─ 白名单: .json .webp .png .jpg .jpeg .gif .txt .md
   ├─ 黑名单: .sh .command .app .dylib .so .scpt .workflow
   ├─ 任何带可执行位 (mode & 0o111) 的文件 → 拒绝
   └─ 忽略: .DS_Store, .* 前缀, run/, .agentpet/

4. AtlasValidator
   ├─ 可解码
   ├─ 尺寸 == profile 期望 (V1 1536x1872 / V2 1536x2288)
   ├─ 存在 alpha 通道
   ├─ 每行前 N 帧非空 (N = contract 帧数)
   └─ 每行第 N 帧起完全透明
```

### 7.2 未使用单元格必须透明的原因

这是官方 validator 的硬要求，也是最容易出的问题。若未使用单元格残留像素，播放器在切换到短行（如 `waving` 只有 4 帧）时会画出第 5、6 帧的残影。**必须在安装时拦截，运行时不做防御。**

### 7.3 性能约束

`1536 × 1872` 解码后约 11 MB RGBA。校验必须**逐行采样 + 分块解码**，不整张载入后再遍历。§20 的 "Pet Manager 安装/预览过程不阻塞主 Pet Renderer" 隐含此要求。

### 7.4 版本判定（2026-09-17 重写；§9.4 的"降级兼容"已作废）

**判定的权威是实测尺寸，manifest 里的 `spriteVersionNumber` 只是交叉校验**（`PetManifest.resolveProfile`）：

| 情况 | 行为 |
|---|---|
| 无 `spriteVersionNumber`（生态常态——本机 8 只里 7 只没有，Codex TUI 的 loader 连这个字段都不读） | 按尺寸判定：1536×1872 → V1，1536×2288 → V2 |
| `spriteVersionNumber` 为 1 或 2，且与尺寸一致 | 同上，声明只作确认 |
| `spriteVersionNumber` 与尺寸**矛盾** | **拒绝**，不猜；拒绝原因里同时给出声明的版本与实测尺寸 |
| `spriteVersionNumber` 为其它值（3、0…） | 忽略，按尺寸判定 |
| `spriteVersionNumber` 类型写错（`"2"` 字符串） | manifest 解码失败 → 拒绝；`PetManifestError.describe` 会点名是哪个字段（`“spriteVersionNumber” is not the right type (expected Int)`），手写 manifest 的人需要的正是这一半 |
| 尺寸不匹配任何 profile | 拒绝 |

**V2 是完整支持，不是"部分兼容"**：row 0–10 全部播放，row 9–10 是十六个注视姿态（§3.4、§3.5 第 5 行）。

**拒绝必须说出来。** 发现过程拆成了两半：哪些目录该扫是 App 的事（`PetLibrary`），扫出来什么、为什么跳过是 Core 的事（`PetLibraryScanner`），因为后者要能被无头测试。`scan()` 返回 `entries` + `skipped(name / root / reason)`——**以前是 `try? ... else continue`，一个包被拒后在管理器里没有行、日志里没有字、`--diagnose` 里没有名，用户看到的只有"我的宠物不见了"**；矛盾版本、类型写错、不是图像的 spritesheet 全都落在这一格里。没有 manifest 的目录不算 pet（构建产物、随手解压的目录），依旧静默跳过。`PetPackageError` / `PetManifestError` / `ImageDecodingError` 都带 `message`，把 case 拼成一句话——诊断文本住在 Core，和 `SessionContext` 的标签同一个理由：不依赖屏幕也能测。

理由有三个出口，同一份数据：

| 出口 | 何时被看到 |
|---|---|
| `--diagnose` 的 `Skipped N folder(s)…` | 交 bug 报告时；干净库不打印这一节 |
| 管理器的 "Not listed" 一栏（`PetsView.skippedRow`） | 用户自己翻宠物列表时 |
| 启动时"没有可用宠物"的提示（`presentNoPets`） | 最可能的时刻：一只都加载不出来。**以前它说的是"那个目录里什么都没有"——而用户的文件夹就在里面**，现在改成点名每个被拒的文件夹和原因；`--selftest` 等无头路径打印同一段文字（`HeadlessMode` 挡住 modal，否则 CI 会挂死） |

---

## 8. 集成配置事务（补齐 §5.4 / §7.3）

### 8.1 协议

```swift
protocol ConfigTransaction {
    func snapshot() async throws -> ConfigSnapshot
    func apply(_ edits: [ConfigEdit], snapshot: ConfigSnapshot) async throws
    func validate() async throws -> ValidationResult
    func rollback(to snapshot: ConfigSnapshot) async throws
    func commit() async throws
}
```

### 8.2 执行序列

```
1. snapshot()
   ├─ 读原文件字节 → 存 backups/<agent>/<ts>/
   └─ 记录 (mtime, size, sha256)

2. apply()
   ├─ 在内存中构造完整结果（不增量改写）
   ├─ 写 <file>.agentpet-tmp
   └─ rename(tmp, file)          ← 原子

3. validate()
   └─ 重新解析文件，确认我们写的条目存在且格式合法

4. commit()  |  rollback(to:)
   ├─ commit   → 删除 .agentpet-tmp，保留 backup
   └─ rollback → rename(backup, file)
```

### 8.3 并发修改检测

Agent 自己会写配置（Claude Code 的 settings.json 存了大量状态）。因此：

- `apply()` 前复查 `(mtime, size, sha256)` 与 snapshot 是否一致
- **不一致 → 放弃本次事务，重新 snapshot，最多重试 2 次**
- 仍失败 → 报 `ConfigurationError.concurrentModification`，不强行写入

### 8.4 幂等性实现（§6.3 要求但未定义）

**不靠字符串匹配 command 路径**（App 移动位置即失配）。方案：

1. 配置条目用绝对路径写入 shim，`command` 形如 `/Applications/AgentPetRuntime.app/Contents/MacOS/agentpet-hook --agent claude-code --event PreToolUse`
2. `integrations/<agent-id>.json` 中记录**我们写入的确切条目内容**
3. `configure()` 先读集成状态：若已配置且当前文件中的条目与记录一致 → **no-op**
4. `uninstall()` 按记录内容精确匹配删除，**绝不删除匹配不到的条目**

这样即使 App 被移动，uninstall 仍能找到旧条目（记录里存着旧路径）；重新 configure 会先清理旧条目再写新条目。

### 8.5 集成状态文件

```json
{
  "schemaVersion": 1,
  "agentID": "claude-code",
  "integrationVersion": "1",
  "status": "configured",
  "configuredAt": "2026-09-12T01:00:00Z",
  "lastValidatedAt": "2026-09-12T01:00:00Z",
  "lastEventAt": "2026-09-12T02:30:00Z",
  "configFingerprint": "sha256:...",
  "writtenEntries": [
    { "file": "~/.claude/settings.json",
      "path": "hooks.PreToolUse[2]",
      "content": { "matcher": "*", "hooks": [ { "type": "command", "command": "...", "timeout": 5 } ] } }
  ],
  "capabilities": ["detect","configure","uninstall","test","liveEvents"]
}
```

**不写入**：API Key、OAuth token、prompt 内容、模型配置。

### 8.6 持久化状态 vs 派生状态（2026-09-14 修正 health 判据）

```
持久化（写 integrations/<agent>.json）:
    notConfigured | configured | configureFailed
    lastEventAt   ← 唯一持久化的运行时事实：最后一次收到事件的时间戳（限流写，≥10s/次）

派生（每次从现实重新计算，不持久化）:
    detected      ← 可执行文件在哪
    connected     ← configured + 条目在位 + 曾经收到过事件（本次或历史）
    degraded      ← configured + 条目在位 + 至今一个事件都没收到
    disconnected  ← configured + 条目在位 + 配置文件里我们的条目已消失
```

**判据是"证据"，不是"新鲜度"**：hook 只在回合前后触发，空闲的 Agent 安静几分钟到几小时都正常。原来的判据是"30 秒内有过事件"，于是用户每次停下来读回答，卡片就报 `Degraded — no events have arrived recently`；重启后（时间戳只在内存里）更是必然误报。因此 `lastEventAt` 落盘、`Degraded` 只保留"装好 hook 后从未收到过任何事件"这一种真正需要处理的情况，"最后事件时间"作为**事实**显示在行内，而不是结论。

`Degraded` 的文案据此改为可操作的："Hooks are installed, but no event has ever reached the pet. Agents read their hooks at startup, so restart it once."

UI 显示的组合状态：

| 持久化 | 派生 | 显示 |
|---|---|---|
| — | 未检测到 | `Not Detected` |
| notConfigured | detected | `Detected` + [Configure] |
| configured | connected | `Connected` ●（行内显示最后事件时间） |
| configured | degraded | `Degraded` ● (黄) + 提示重启 Agent |
| configured | disconnected | `Needs Attention` ! + [Reconfigure] |
| configureFailed | — | `Error` + [Fix] |

管理窗口打开期间，卡片和 Activity 列表由 1s ticker 驱动重新求值（复用已有的 detection 结果，不重复 spawn `--version`）；此前卡片只是"打开那一刻的快照"，会在事件不断到达时继续显示"没有事件"。

### 8.7 可执行文件到哪儿找（2026-09-14 修正：GUI 的 PATH 不是终端的 PATH）

`Not Detected` 曾是 pi 在本机的常态，原因不在 agent 本身：

- Finder / 登录项启动的 .app 由 launchd 拉起，`PATH` 是 `/usr/bin:/bin:/usr/sbin:/sbin`；
  终端里那个 PATH（fnm / nvm / pnpm / …）在 app 进程里**根本不存在**。
- 本机 pi 由 fnm 安装，真实位置 `~/.local/share/fnm/node-versions/<ver>/installation/bin/pi`。
  终端能看到它，只是靠 fnm 给每个 shell 建的临时软链目录
  `~/.local/state/fnm_multishells/<pid>_<ts>/bin`（PID 命名、随 shell 生灭）——不能作为搜索依据。
- 实测（同一台机器）：终端下 `--status` 四个 agent 全 ●；`env -i HOME=$HOME PATH=/usr/bin:/bin`
  下只有 pi 变 ○。claude / codex / grok 是 Mach-O 原生二进制，且恰好落在固定目录里，
  把这个缺陷盖住了。

`AgentDetector.defaultSearchPaths()` 现在在 PATH **之后**追加各版本管理器的默认目录：

```
~/.local/share/fnm/node-versions/*/installation/bin    按目录名里的版本号，新的在前
~/.nvm/versions/node/*/bin                             同上
~/.volta/bin   ~/.bun/bin   ~/Library/pnpm   ~/.asdf/shims   ~/.local/share/mise/shims
```

三条理由，写给下一个想改这里的人：

1. **顺序由我们定，不交给文件系统**：通配目录按名字里的数字排序，否则同一台机器两次启动
   可能报出不同版本的路径。`newestFirst` 有测试（`AgentDetectorTests`）。
2. **PATH 排在枚举目录之前**：从终端启动时，shell 自己解析出的那一条比我们枚举的更准；
   枚举目录只兜 launchd 那种"什么都没有"的情况。
3. **不解析 login shell 的 PATH**（`$SHELL -lic 'echo $PATH'`）：能覆盖自建目录，但本机实测
   **461 ms**，还要执行用户的 rc 文件——有副作用（fnm env 会写状态目录）、rc 卡住就只能超时放弃。
   用一个会超时的不确定换一个罕见场景不值。**代价明确接受**：非默认位置（如 `~/opt/node/bin`）
   检测不到，这是有意的取舍，不是遗漏。

版本探针（`--version`）继承的 PATH 里也追加了这些目录：版本管理器装的 CLI 通常是脚本
（`pi` 的 shebang 是 `#!/usr/bin/env node`），没有 node 就退 127，表现为"检测到了但没有版本号"。
实测 `env -i PATH=/usr/bin:/bin pi --version` → `env: node: No such file or directory`。

另外 `Specification.extraSearchPaths` 此前是个**死字段**（声明、赋值、注释都在，没有读取方），
现已接上：先扫 agent 自己的 extra，再扫全局表。

### 8.8 扩展文件类集成：Pi 与 Oh My Pi（2026-09-15 新增）

前面七节讲的是**改别人的文件**（Claude Code 的 JSON hook 表）。Pi 与 Oh My Pi 是另一类：它们各自在会话启动时加载自己扩展目录下的 `*.ts`（`~/.pi/agent/extensions/`、`~/.omp/agent/extensions/`），所以集成是**一个完全属于运行时的文件**——安装即写、移除即删、不需要解析任何既有格式，也不可能与用户的配置打架。两者共用同一个生成模板（**事件集**与**所有权标记**为参数）。除路径、所有权标记的**字符串**、拒绝覆盖时抛出的错误值以及文件头那段代价说明外，本节细节对 Pi 同样成立；其余差别只在事件集那张表。

（本机实证：omp 18.1.22，`@oh-my-pi/pi-coding-agent`；扩展加载走 Bun 的原生 import，语法错误只跳过该文件，handler 抛错被框架吞掉并记录。Oh My Pi 是 Pi 的重命名分支，`piConfig.configDir` 从 `~/.pi/agent` 变成 `~/.omp/agent`，扩展 API 相同，但**事件集不同**——这正是生成文件以事件集为参数的原因。）

#### 文件与所有权

| 项 | 取值 |
|---|---|
| 路径 | `~/.omp/agent/extensions/agentpet.ts`（由 `ExtensionFileConfigurator` 决定） |
| 所有权标记 | 文件头一行固定文本：omp 是 `// agentpet-runtime extension`，Pi 是 `// agentpet-extension v1`（模板参数之一）——**不含路径**，所以 App 搬家后旧文件仍被认作自己的；它只用于「覆盖前是否是自己人」 |
| 记录的条目 | `WrittenEntry(file:, event: "agentpet.ts", command: "// shim: <shim> --agent omp")`——两个 Agent 的条目都是这行注释（`ExtensionTemplate.markerLine`），判据是**这一整行是否还在文件里**，也就是文件是否仍与记录一致。文件里那行被改写（手工改、或被另一次 Configure 换成了别的 shim 路径）→ `entriesPresent` 为假 → 卡片报 disconnected，直到用户重新 Configure。**App 自己搬家不在其中**：记录与文件是同一次 Configure 一起写的，两者会一直一致；判定从不拿 `record.shimPath` 去和"当前 shim 路径"比对——该字段只在 uninstall 时用于保留原值 |
| 幂等 | 生成文本与磁盘内容逐字节相同 → 不写、不备份、`didChange = false` |
| 拒绝覆盖 | 目标文件存在但不带所有权标记 → 抛 `ConfigurationError.foreignFile`，原文件一字节不动 |
| 移除 | 只在文件仍含**记录里那行** `// shim:` 时才删（判据是那一行，不是"文件没被人动过"：用户在其上追加内容并不会让它留下）。删除前先备份（走 `ConfigTransaction.backUp`，与 JSON 事务同一个备份目录、同一套命名：`<文件名>.<epoch>.<sha8>`），所以连用户追加的部分也能取回。那行被改掉/删掉、或记录为空 → 不删，报 `didChange = false`。**这条规则两个 Agent 共用**（`PiConfigurator` 同样按记录条目判定存在与移除）；v0.9.6 的旧记录无需分支：它记的是标记行，旧文件里仍有那一行，于是照样报存在、照样能干净移除 |

生成文本由 `AgentPetExtension.source(agentID:shimPath:)` 拼出（不是随包资源）：能被测试逐条断言，也能在不安装任何东西的情况下读全文——与 `HookSetup.claudeCodeJSON` 同样的理由。它自己只是把参数交给**两个扩展文件共用的模板** `ExtensionTemplate.source(agentID:shimPath:events:marker:)`：两个 Agent 的扩展 API 相同，事件集是显式参数（agent id 与所有权标记也是），其余（shim 调用、会话 id、上下文读数、环境变量通道）全部共享。Pi 的配置器（`PiConfigurator`）走同一个模板的 `.pi` 分支。

| 用途 | Pi 0.85 发 | Oh My Pi 18 发 |
|---|---|---|
| "被扣住了" | `ui_prompt_start`（自己的提示框在屏上） | `tool_approval_requested` / `ask` 工具 |
| 一轮结束 | `agent_settled` | `agent_end`（丢掉 `willContinue` 为真的那些） |

一条普通 `agent_end` 在 Pi 上不是结算（之后还可能自动重试或续跑），而 `agent_settled` 在 omp 18.1.22 里**不存在**（逐事件核对过），所以一个文件不可能同时正确；模板按事件集参数化正是为此。写入走 `ConfigTransaction.performText`（快照 → 备份 → 原子写 → 读回验证 → 失败回滚），与 JSON 事务同一套纪律、同一份代码。

#### 上报什么

扩展监听八个事件、发送九个（多出来的是每次结算后那条上下文读数），全部由它自己发给 shim（`--agent omp --event <名>`）。payload 只有 `session_id` 与 `cwd`；带工具名的那几个事件（`tool_execution_start` 与两个审批事件）多一个 `toolName`。

| 扩展发 | 归一化为 | 依据 |
|---|---|---|
| `tool_approval_requested` | `.waitingApproval` | 工具被扣住等用户批准（对应权限提示） |
| `tool_execution_start` 且 toolName 为 `ask` | `.waitingInput` | `ask` 工具本身就是问用户 |
| `agent_start` / `tool_execution_start` / `tool_execution_end` / `tool_approval_resolved` | `.working` | 干活中；`tool_execution_end` 同时是"答完问题"的下落点 |
| `agent_end` | `.completed` | 每轮 prompt 一次；payload 里 `willContinue` 为真（已排好重试）时扩展**不发** |
| `session_start` | `.sessionStarted` | 引擎按 §4.5b 不建行，只刷新已知会话 |
| `session_shutdown` | `.sessionClosed` | 会话结束 |
| `context_update`（结算时发送，不监听事件） | `.contextUpdate` | 只描述会话：模型、上下文占用——与状态行 tap 同一归约形状，不改变状态 |

`whenToolName` 是为这条映射新加的规则条件（`NormalizationRule` 上第三个"仅当某字段等于某值"，前两个是 `whenNotificationType` 与 `whenReason`）：同一事件的窄规则必须排在其通用规则**之前**。

不映射且**故意不订阅**：`turn_start`/`turn_end`（Oh My Pi 的 turn 是一次模型调用，不是一轮 prompt）、`message_*`、`session_compact` 等——后者携带模型输出，而本项目不读模型输出。

#### 只上报，不设卡

omp 的扩展是**进程内**的，能改 Agent 行为，所以边界必须写死：文件里没有注册任何 `tool_call`（该事件 fail-closed——handler 抛错会拦掉工具），没有 `sendMessage`（注入消息），没有 `node:fs`（碰用户文件），没有 `ctx.ui`（弹窗），所有 handler 都不返回值并各自 try/catch。注册集合本身由 `OhMyPiNormalizationTests.registeredEventsAreKnown` 钉住（源码里注册的事件必须逐字等于声明的八个，且每个都有归一化规则），四条"不设卡"的承诺由 `ExtensionInstallationTests.reportsOnly` 做文本断言。

**一处代价必须写明**：omp 的 `hasLifecycleHandlers`（`src/speculation/host.ts:60-67`）只看四个工具生命周期事件——`tool_call`、`tool_result`、`tool_approval_requested`、`tool_approval_resolved`；**任意扩展**在其中之一上有 handler，实验性的推测本地读（`tools.speculativeExecution.enabled`，默认 false）就不跑。本扩展占的是后两个（审批→`waitingApproval`/`Needs input`），所以代价是真实的；只注册 `session_start` 之类的扩展不会触发它。这条写进了装出来的文件头，以及 README。

#### 已知边界

- 子代理会话若也派发扩展事件，会作为独立 session 出现在面板上（本项目不读 Agent 内部状态，无法可靠区分主/子会话）；实测 `-p` 模式下未出现。
- 面板的**费用**一项对 Oh My Pi 没有数据源（扩展不发 `cost_usd`）；模型与上下文占用随每次结算的 `context_update` 上报（§6.7）。
- 扩展在**会话启动时**加载：装完要新起一个 omp 会话才生效。UI 的 degraded / disconnected 文案按机制分支，正是为这句话。

#### 真机验证（2026-09-15）

`--configure omp` 写文件 → 起一个真实 omp 会话（`omp -p`，`AGENTPET_SOCKET` 指向一个打印信封的 UDS 监听）→ 得到按序的 `session_start / agent_start / tool_execution_start(bash) / tool_execution_end / agent_end / session_shutdown`，每个信封都带同一个 session id 与 `/tmp` 工作目录 → `--unconfigure omp` 后文件消失、目录里另外两个扩展原样、`--status` 回到 `extension: 0`。

---

## 9. 常量汇总

集中在一处便于调参。

```swift
enum RuntimeConstants {
    // Activity Engine
    static let agingThreshold  : TimeInterval = 90
    static let maxPromotions   : Int = 2
    static let focusHold       : TimeInterval = 3.0
    static let urgentOverride  : TimeInterval = 1.0
    static let completionDwell : TimeInterval = 4.0

    // 静默超时
    static let runningStale    : TimeInterval = 300   // 单次工具调用可以跑好几分钟
    static let unknownStale    : TimeInterval = 60
    static let approvalStale   : TimeInterval = 300
    static let failedStale     : TimeInterval = 600
    // 会话保留上限（与状态无关，见 §4.5a）：一天没被听到就不再保留
    static let silentSessionLifetime : TimeInterval = 86_400

    // 初次问候（= Codex 的 first-awake：8 秒、每只宠物一次、waving）
    static let greetingLifetime : TimeInterval = 8

    // 宠物尺寸（= Codex 的 avatar-overlay-mascot-width-px：范围与默认值，滑杆）
    static let petWidthMinimum  = 80
    static let petWidthMaximum  = 224
    static let petWidthDefault  = 112

    // Bridge
    static let bridgeProtocolVersion = 1
    static let dedupeWindow    : TimeInterval = 0.5
    static let shimTimeout     : TimeInterval = 0.1
    static let maximumConnections : Int = 64          // 每连接一线程一描述符
    static let bridgeReadTimeout  : TimeInterval = 5  // 连上却不说话的对端
    static let descriptorBackoff  : TimeInterval = 0.1 // EMFILE 后的重试间隔（§5.6）

    // 事件捕获（--log-events）
    static let captureMaxBytes : Int = 8 * 1024 * 1024   // 超过即轮转为 <path>.1
    static let threadStartGrace : TimeInterval = 1        // 线程未认领连接的宽限（§5.6）

    // 未送达事件
    static let spoolMaxEvents  : Int = 200
    static let spoolDirectory  = "pending-events"

    // 集成
    static let lastEventPersistInterval : TimeInterval = 10   // 时间戳落盘的限流窗口
    static let maxBackups      : Int = 10

    // 扩展文件类集成（§8.8）
    static let extensionFileName = "agentpet.ts"                      // <agent dir>/extensions/agentpet.ts
    static let extensionOwnershipMarker = "// agentpet-runtime extension"   // omp 用；Pi 用 "// agentpet-extension v1"

    // 校验
    static let maxPackageBytes = 64 * 1024 * 1024
}
```

---

## 10. 与原方案的决策差异汇总

| 项 | 原方案 | 本方案 | 理由 |
|---|---|---|---|
| Bridge 方向 | Agent 连接 server | 双向：shim 出站 + socket 入站 | 实测 Agent 只支持进程派生 |
| `PetState` 层 | 独立 5 态状态机 | **删除**，`AgentState → AnimationTrack` 直连 | 中间层无信息增量，只是多一套词汇 |
| atlas 行驱动 | 隐含 9 行 ← 9 态 | 4 行状态驱动 + 3 行手势 + 2 行位移 | 行语义与状态语义不同构 |
| V2 atlas | 不定义为稳定，倾向拒绝 | **降级兼容**，播放 row 0–8 | 用户已有 V2 资产 |
| `~/.codex/pets` | 未提及 | **唯一的 pet 来源**，只读 | 与 Codex TUI、`codex-pets` CLI 读同一目录，两个答案的问题不复存在 |
| 卸载安全 | "不删源目录" | **不适用**：本项目不持有 pet，增删改都在 Codex 侧 | 自有存储已删除（§6.3） |
| ADR-009 XPC | 保留 | **删除** | v0.1 无第三方代码需隔离 |
| 开发顺序 | P0 状态机 → P2 Activity | **合并为一个里程碑** | 状态机的输入由 Activity Engine 决定，不能分开 |
| 集成机制 | 只有"编辑 agent 的配置文件"一种 | **两种**：hook 表（改别人的文件）与扩展文件（写自己的文件） | Oh My Pi 只支持后者；硬套 JSON 事务会被迫去改一个不存在的表（§8.8） |
| shim 的 payload 来源 | 只有 stdin | stdin **或** `AGENTPET_PAYLOAD_BASE64` | 进程内报送方写管道会被 Agent 的事件循环拖到超时，实测丢 payload（§5.1、§8.8） |
