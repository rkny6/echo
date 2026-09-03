# Changelog

本项目所有重要的变更都会记录在此文件中。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### 新增
- 项目开源准备：MIT License、贡献指南、行为准则、安全政策
- 完整中文 README：包含功能特性、技术架构、快速开始、LLM 配置、MCP 说明、测试列表、发展路线
- 文档中项目名统一为小写 `echo`

### 修复
- 修正 `.gitignore`：移除误添加的源码目录忽略规则，改为仅忽略 Xcode 用户数据、构建产物、临时文件与 API 密钥占位符

### 安全
- API Key 采用 Keychain 存储，`Info.plist` 中的秘钥字段保持为空并在 `.gitignore` 中忽略

## [0.1.0] - 2026-08-23

### 新增
- SwiftUI + SwiftData 基础框架
- 基于 OpenAI Compatible API 的 LLM 对话（多模型、多端点模式）
- 长期记忆系统（用户画像、关系记忆、事件、全局摘要 + 未总结片段双轨制）
- 主动陪伴系统（上线问候、晚间关怀、沉默暖场、健康提醒）
- HealthKit 健康数据感知与事件检测
- 日记自动生成与关键词检索
- 工具调用（`ToolCallLoop`）与内置天气工具（`WeatherTool`）
- MCP（Model Context Protocol）远程工具接入与模拟测试
- 图片消息支持（本地 Vision + 可选云端识别）
- 单元测试与集成测试基础设施（含 MockMCP 端到端测试）
## 2026-08-27 — Application-layer refactor

- Replaced the monolithic `AppViewModel` orchestration layer with small feature facades (`ChatFeature`, `ProfileFeature`, `APIProfileFeature`, `SettingsFeature`, `DiaryFeature`, `MemoryFeature`, `DiagnosticsFeature`, `ProactiveFeature`).
- Kept the existing SwiftUI View-facing API and domain services intact to preserve behavior while reducing cross-domain coupling in the UI layer.
- Added `ARCHITECTURE.md` documenting the new application structure and migration rules.
- Clarified the privacy statement: local-first storage does not imply that cloud LLM/image/MCP requests stay on-device.
- Tracked `echo/Info.plist` in the release tree so a clean clone contains the Xcode app configuration.
