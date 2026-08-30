# Echo

> 基于 SwiftUI + SwiftData + LLM 的 iOS 虚拟陪伴应用（AI Virtual Companion）

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-iOS%2018%2B-lightgrey)
![Swift](https://img.shields.io/badge/Swift-SwiftUI%20%2B%20SwiftData-orange)
![Status](https://img.shields.io/badge/status-early%20development-blueviolet)

Echo 不是一个简单的聊天机器人，而是一个拥有**长期记忆、主动交互、情绪状态管理和环境感知能力**的数字伙伴。它通过健康数据、地理位置、时间与生活习惯感知你的状态，在合适的时机主动发起对话，让交流从「问答」变成「陪伴」。

> ⚠️ 这是一个个人开发的早期项目，尚未上架 App Store，不隶属于任何公司或官方产品。欢迎试用、阅读代码、提 Issue，但请知悉当前处于快速迭代阶段，接口和数据结构都可能发生变化。

## 目录

- [功能特性](#-功能特性)
- [技术架构](#-技术架构)
- [项目结构](#-项目结构)
- [快速开始](#-快速开始)（[零基础教程](GETTING_STARTED.md)）
- [配置 LLM](#️-配置-llm)
- [可选的第三方服务密钥](#-可选的第三方服务密钥)
- [工具调用与 MCP](#-工具调用与-mcp)
- [测试](#-测试)
- [文档](#-文档)
- [发展路线](#-发展路线roadmap)
- [常见问题](#-常见问题)
- [贡献](#-贡献)
- [License](#-license)

---

## ✨ 功能特性

### 💬 智能对话

- 兼容 **OpenAI Compatible API**（OpenAI / Azure / OneAPI / 本地部署模型等）
- 支持多模型配置与切换
- 支持多种端点模式（`chat_completions` 等）
- 支持流式回复与上下文管理（对话历史、记忆、日常上下文自动组装）
- 支持图片消息（内置 Vision 本地识别 + 可选的云端识别）

### 🧠 长期记忆系统

通过 `MemoryManager` 统一管理多维度记忆，让 AI 记住你，而不是每次重新认识：

- 用户画像（`UserProfile`）
- 角色设定（`CharacterProfile`）
- 关系记忆（`RelationshipMemory`）
- 长期事件（`CompanionEvent`）
- 对话摘要（`LongTermMemory` / 全局摘要 + 未总结片段双轨制）

### 🌱 主动陪伴系统

基于 `ProactiveEngagementCoordinator` 与 `SystemEventCoordinator`，Echo 会根据：

- 时间（问候时机、夜间关怀）
- 用户在线/离线状态
- 最近互动情况（沉默时长）
- 健康事件（步数、睡眠、生理周期）

主动发起：

- 上线问候
- 晚间关怀
- 健康提醒
- 事件反馈
- 沉默期暖场

所有主动行为都受 `NotificationGovernor` **硬性安全阀**约束：不打断进行中的对话、冷却期、每日上限。

### 🏥 健康感知（HealthKit）

- 读取步数、睡眠、心率变异性、生理周期等健康数据
- 健康事件检测与推送（`HealthProactiveDeliveryService`）
- LLM 健康分析生成个性化关怀文案
- 各事件独立的去重策略（HealthAlertDedup），避免重复打扰

### 📔 日记生成

- 每日对话结束后自动生成日记（`DiaryService`）
- 关键词相关性检索，对话中可自然回顾往日日记

### 🔧 工具调用 & MCP

- 模型可在回复中调用工具（`ToolCallLoop`）
- 内置工具：`WeatherTool`（天气查询）
- 支持 **MCP（Model Context Protocol）** 远程工具接入
- 「先模拟后真实」的开发模式，`MockMCPServer` 端到端测试覆盖

### 🔐 数据隐私

- 所有数据保存在**本地**（SwiftData）
- API Key 使用 **Keychain** 安全存储，不写入源码
- 数据默认保存在本地；启用云端 LLM、云端图片识别或远程 MCP 时，相应请求内容会发送到你配置的第三方服务
- 详细的数据处理说明见 [PRIVACY.md](PRIVACY.md)

---

## 🏗 技术架构

```
                      ┌──────────────────────┐
                      │  VirtualCompanionApp │ 组合根（依赖注入）
                      └──────────┬───────────┘
                                 │
                      ┌──────────▼───────────┐
                      │      AppViewModel     │ 页面状态
                      └──────────┬───────────┘
                                 │
        ┌────────────────────────▼────────────────────────┐
        │              ConversationManager                 │ 对话编排
        │   (回复生成 / 事件响应 / 用户消息 / 恢复 / 批量)   │
        └───┬────────┬──────────┬──────────┬───────────┬───┘
            │        │          │          │           │
   ┌────────▼──┐ ┌───▼────┐ ┌───▼──────┐ ┌─▼─────────┐ ┌▼───────────┐
   │ LLM 层    │ │ 记忆层  │ │ 日记层    │ │ 健康层     │ │ 工具/MCP   │
   │ LLMFactory│ │ Memory │ │ Diary    │ │ HealthKit │ │ ToolCall   │
   │ Adapter   │ │ Manager│ │ Service  │ │ Proactive │ │ Loop/Reg   │
   └───────────┘ └────────┘ └──────────┘ └───────────┘ └────────────┘
                                 │
                    ┌────────────▼────────────┐
                    │  ProactiveEngagement     │ 主动服务
                    │  Coordinator             │
                    └────────────┬────────────┘
                                 │
                    ┌────────────▼────────────┐
                    │  SystemEventCoordinator │ 事件调度
                    └─────────────────────────┘
```

### 核心技术栈

| 模块 | 技术 |
|------|------|
| UI | SwiftUI |
| 数据持久化 | SwiftData |
| 异步 | Swift Concurrency（async/await + Actor） |
| AI | OpenAI Compatible API（`CustomOpenAICompatibleAdapter`） |
| Agent | Tool Calling + MCP |
| 健康数据 | HealthKit |
| 后台任务 | BackgroundTasks |

---

## 📂 项目结构

```
echo/                          # 仓库根目录
├── Config/
│   └── Local.xcconfig.example  签名配置模板（复制为 Local.xcconfig 后本地生效，见「快速开始」）
├── echo/                      # App 主 target
│   ├── App/                   应用入口 & 生命周期（组合根，依赖注入）
│   ├── ViewModel/              AppViewModel（页面状态管理）
│   ├── Views/                  SwiftUI 页面（聊天、设置、日记、记忆、调试…）
│   ├── Features/               按业务垂直切分的 Feature 模块（Chat / Diary / Memory / Profile / Proactive / Settings / API Profile / 诊断）
│   ├── Services/                核心业务服务
│   │   ├── MCP/                MCP 客户端、JSON-RPC、流式 HTTP 传输
│   │   └── …                   对话、健康、通知、LLM、记忆、天气等
│   ├── Domain/LLM/              LLM 抽象层与工具调用协议
│   ├── Models/                  SwiftData 数据模型
│   ├── Persistence/             持久化 Store
│   ├── Protocols/                服务协议（依赖倒置接口）
│   ├── Core/                     核心逻辑（AppRuntime / Governor / Intent / Message / Logging）
│   ├── Enums/                    枚举定义
│   ├── Design/                   主题设计
│   ├── Utilities/                 工具类
│   ├── Mocks/                     模拟服务
│   └── Info.plist                 App 配置（含可选第三方密钥字段，见下文）
├── echoTests/ / echoUITests/      单元测试 & UI 测试
├── scripts/                       本地开发用的 MCP 测试服务器（`mcp_test_server.py` 等），非 App 运行时依赖
├── ARCHITECTURE.md                架构说明
├── MCP_VERIFICATION_REPORT.md     MCP 客户端功能验证记录
├── CHANGELOG.md / SECURITY.md / CONTRIBUTING.md / CODE_OF_CONDUCT.md
└── echo.xcodeproj                 Xcode 工程
```

---

## 🚀 快速开始

> 完全不写代码、只想把项目跑起来看看的朋友，直接看 [GETTING_STARTED.md](GETTING_STARTED.md)（图文向导，从安装 Xcode 讲起）。下面是给有开发经验的人看的精简版。

### 环境要求

- Xcode 16+
- iOS 18+（推荐 iPhone 16 模拟器）

### 配置签名（必须，首次 clone 后先做这一步）

签名相关的设置（Team / Bundle Identifier）抽在了一个本地专属、被 `.gitignore` 排除的 xcconfig 文件里，不会跟原作者的签名冲突，也不会因为你改了签名而污染 `git status`：

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

用文本编辑器打开 `Config/Local.xcconfig`，按注释提示填好 `DEVELOPMENT_TEAM`（你的 Apple 开发者 Team ID）和 `PRODUCT_BUNDLE_IDENTIFIER`（改成任意独一无二的字符串）。

> ⚠️ 请直接编辑 `Config/Local.xcconfig` 这个文本文件，**不要**在 Xcode 的 Signing & Capabilities 面板里改 Team / Bundle Identifier —— 那个面板会把值直接写回 `project.pbxproj`，绕过 xcconfig，又会导致本地改动被 git 追踪到。

不做这一步的话，Xcode 会在打开 / 构建项目时报错找不到 `Local.xcconfig`。

### 打开项目

```bash
open echo.xcodeproj
```

### 命令行构建 & 测试

```bash
# 构建
xcodebuild build -scheme echo -destination 'platform=iOS Simulator,name=iPhone 16'

# 单元测试
xcodebuild test -scheme echo -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:echoTests
```

### 真机运行

模拟器和真机用的是同一套签名配置（`Config/Local.xcconfig`），装真机前确认已经按上面「配置签名」填好了自己真实的 Team ID。

---

## ⚙️ 配置 LLM

Echo 使用统一的 LLM 适配器 `CustomOpenAICompatibleAdapter`，由 `LLMServiceFactory` 统一管理，可通过 **设置 → API 配置** 配置：

| 配置项 | 说明 |
|--------|------|
| Base URL | API 服务地址 |
| Model | 模型名称 |
| 端点模式 | `chat_completions` 等 |
| API Key | 密钥（存于 Keychain） |

> 兼容任何 OpenAI-compatible 服务：OpenAI、Azure OpenAI、OneAPI、vLLM、Ollama（OpenAI 兼容端点）等。

---

## 🔑 可选的第三方服务密钥

以下功能依赖第三方服务，均为**可选**，未配置时对应功能会自动降级或跳过，不影响核心聊天功能。密钥通过 `echo/Info.plist` 中的对应字段注入，仓库中默认留空，**请勿在 Info.plist 或代码中提交任何真实密钥**：

| 功能 | Info.plist 字段 | 说明 |
|------|------------------|------|
| 天气感知 | `CaiyunWeatherToken` | 留空时会走 [Open-Meteo](https://open-meteo.com/) 免费接口兜底；如需彩云天气的国内节点/分钟级降水，请到 [彩云开放平台](https://platform.caiyunapp.com) 免费申请你自己的 token 后填入 |
| 云端图像理解（Agnes） | `AGNES_AI_API_KEY` | 留空时仅使用本地 Vision 识别 |
| 图片上传中转 | `IMGBB_API_KEY` | 配合 Agnes 云端识别使用，可在 [ImgBB](https://api.imgbb.com/) 免费申请 |

---

## 🛠 工具调用与 MCP

### 工作流程

1. 设置中开启开关 **使用工具调用 (MCP)**（`AppSettings.enableMCP`，默认关闭）。
2. 开启后，`ConversationManager.generateReply` 通过 `ToolRegistry` 向模型暴露工具定义，并路由工具调用。
3. 内置工具：`WeatherTool`（get_weather），在应用入口注册。
4. 远程 MCP 工具通过 `RemoteMCPTool` 代理，使用 `ToolRegistry.makeFrom(connector:)` 注册。

> MCP 服务器地址在 **设置 → 高级选项**（需开启调试模式）配置，持久化为 `AppSettings.mcpServerURL`。

### 架构分层

| 类型 | 文件 | 角色 |
|------|------|------|
| `MockMCPServer` | `echoTests/` | 进程内模拟 MCP 服务器（tools/list + callTool） |
| `MCPConnector` | `echo/Services/` | 客户端接口：fetchTools / callTool |
| `RemoteMCPTool` | `echo/Domain/LLM/` | `LLMTool` 代理，转发执行到 connector |

> **重试策略**：仅对单次 API 调用使用 `generateWithRetry`，整个 `ToolCallLoop` 永不重试（避免副作用重复执行）。

---

## 🧪 测试

项目包含完整的单元测试与集成测试：

| 测试文件 | 覆盖内容 |
|----------|----------|
| `ConversationManagerTests` | 对话编排 |
| `ToolCallLoopTests` / `ToolCallLoopMCPTests` | 工具调用循环与 MCP 端到端 |
| `MockMCPTests` | 模拟 MCP 服务器协议 |
| `ChatMessageStoreTests` | 消息持久化 |
| `DiaryServiceTests` | 日记生成与检索 |
| `ProfileServiceTests` / `APIProfileServiceTests` | 档案与 API 配置 |
| `SettingsServiceTests` | 设置服务 |
| `ProactiveIntentDeciderTests` | 主动意图判定 |
| `AssistantMessageSequencePlannerTests` | 消息序列规划 |
| `ContactSilenceMetricsTests` | 沉默期指标 |

---

## 📖 文档

| 文档 | 内容 |
|------|------|
| [GETTING_STARTED.md](GETTING_STARTED.md) | 零基础图文教程：从安装 Xcode 到跑起来，写给完全不会写代码的人 |
| [ARCHITECTURE.md](ARCHITECTURE.md) | 更详细的分层架构说明 |
| [MCP_VERIFICATION_REPORT.md](MCP_VERIFICATION_REPORT.md) | MCP 客户端功能的验证记录（协议层 / 客户端逻辑 / 模拟器端到端） |
| [PRIVACY.md](PRIVACY.md) | 隐私政策：数据收集范围、存储位置、何时会发送给第三方服务 |
| [CHANGELOG.md](CHANGELOG.md) | 版本变更记录 |
| [SECURITY.md](SECURITY.md) | 安全政策与漏洞报告方式 |
| [CONTRIBUTING.md](CONTRIBUTING.md) | 贡献指南与开发规范 |

---

## ❓ 常见问题

**Q: 打开 / 构建时报错找不到 `Local.xcconfig`？**
这是预期行为，说明还没做「配置签名」那一步：执行 `cp Config/Local.xcconfig.example Config/Local.xcconfig`，然后编辑这个新文件填好你自己的 Team ID 和 Bundle Identifier。

**Q: 天气不显示 / 报错"缺少天气 API Token"？**
`CaiyunWeatherToken` 默认留空，此时会自动 fallback 到 [Open-Meteo](https://open-meteo.com/)。如果 fallback 也失败（比如网络环境无法访问 Open-Meteo），可以去[彩云开放平台](https://platform.caiyunapp.com)免费申请一个自己的 token 填入 `Info.plist`。

**Q: 图片识别功能用不了？**
默认走本地 Vision 识别，不需要任何密钥。云端识别（Agnes）是可选增强，需要自行配置 `AGNES_AI_API_KEY` 与 `IMGBB_API_KEY`，留空则自动跳过。

**Q: 健康数据 / 位置权限一定要开吗？**
不是必需的。拒绝对应权限后，主动关怀会失去这部分感知能力，但聊天、记忆、日记等核心功能不受影响。

**Q: 我的聊天记录、健康数据会被上传吗？**
默认全部存本地（SwiftData）。只有当你主动配置了云端 LLM / 云端图像识别 / 远程 MCP 服务器时，相应的请求内容才会发送给你自己配置的第三方服务，详见上文「数据隐私」与「可选的第三方服务密钥」。

---

## 🛣 发展路线（Roadmap）

**已完成：**

- [x] SwiftUI + SwiftData 基础框架
- [x] LLM 对话与多模型配置
- [x] 长期记忆系统（记忆分层 + 摘要）
- [x] 主动问候 / 晚间关怀 / 沉默暖场
- [x] 健康数据感知与主动关怀
- [x] 日记自动生成
- [x] 工具调用 + MCP
- [x] 图片识别（本地 Vision + 可选云端）

**规划中：**

- [ ] 更强的 Agent 规划能力
- [ ] 多模态视觉记忆
- [ ] 本地模型支持（LLM 本地推理）
- [ ] 多设备数据同步
- [ ] 更自然的人格成长系统
- [ ] 更多内置工具（日历、待办、智能家居…）

---

## 🤝 贡献

欢迎一切形式的贡献：Bug 修复、架构讨论、新功能开发、Agent 设计交流。

详见 [CONTRIBUTING.md](CONTRIBUTING.md) 与 [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)。

## 📄 License

本项目采用 [MIT License](LICENSE)。
