# 贡献指南

欢迎为 Echo 项目贡献代码！本指南将帮助您快速开始。

## 目录

- [开发环境](#开发环境)
- [代码风格](#代码风格)
- [开发流程](#开发流程)
- [提交规范](#提交规范)
- [分支策略](#分支策略)
- [测试](#测试)
- [Pull Request 要求](#pull-request-要求)
- [问题报告](#问题报告)

## 开发环境

请确保您的开发环境满足 [README](README.md) 中列出的要求：

- Xcode 16+
- iOS 18+ 模拟器

克隆仓库后，先按 README 的「配置签名」一节把 `Config/Local.xcconfig.example` 复制为 `Config/Local.xcconfig` 并填好你自己的 Team ID / Bundle Identifier，否则 Xcode 打开或构建项目会报错找不到该文件。签名相关的改动请只编辑 `Config/Local.xcconfig`（已被 `.gitignore` 排除），不要在 Xcode 的 Signing & Capabilities 面板里改，否则会绕过 xcconfig 直接写回 `project.pbxproj`，产生不该提交的本地差异。

## 代码风格

- **Swift**：遵循 [Swift API 设计指南](https://www.swift.org/documentation/api-design-guidelines/)。
- **命名**：使用清晰、描述性的名称。
  - 变量、函数、枚举成员：`lowerCamelCase`
  - 类型、协议：`UpperCamelCase`
- **格式化**：使用 Xcode 内置的代码格式化（`Editor → Structure → Re-Indent`）。
- **注释**：对复杂逻辑使用 `///` 文档注释说明「为什么」这样做。

## 开发流程

1. **Fork** 本仓库到你自己的 GitHub 账号。
2. **Clone** 到本地：
   ```bash
   git clone git@github.com:your-username/echo.git
   cd echo
   ```
3. **创建特性分支**（基于最新的 `main`）：
   ```bash
   git checkout -b feature/your-feature-name
   ```
4. **编写代码与测试**。
5. **本地验证**（见下文「测试」一节）。
6. **提交 & 推送**：
   ```bash
   git add .
   git commit -m "feat: add your feature description"
   git push origin feature/your-feature-name
   ```
7. **打开 Pull Request**，描述清楚改动内容与动机。

## 提交规范

我们采用 [Conventional Commits](https://www.conventionalcommits.org/) 风格的提交信息：

```
<type>(<scope>): <description>
```

| Type | 用途 |
|------|------|
| `feat` | 新功能 |
| `fix` | Bug 修复 |
| `docs` | 仅文档变更 |
| `refactor` | 重构（不改变外部行为） |
| `test` | 新增或修改测试 |
| `chore` | 构建、依赖、工具等杂项 |

示例：

```
feat(conversation): add reply streaming support
fix(notification): prevent duplicate health alerts
docs: update README with MCP configuration
```

## 分支策略

- `main`：主分支，始终可构建、可运行、可发布。
- 所有特性、修复都在独立分支上进行，通过 Pull Request 合入。

## 测试

在提交代码前，请确保所有单元测试都能通过：

```bash
xcodebuild test \
  -scheme echo \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

涉及新增逻辑时，请尽量补充相应的单元测试（项目已有完整的测试基础设施与 MCP 模拟服务器）。

## Pull Request 要求

- 标题简明，描述改动内容。
- 说明改动**原因**与**影响范围**。
- 如果涉及 UI 变更，请附带截图（可选）。
- 确保通过所有 CI 检查（如配置了 GitHub Actions）。
- 保持 PR 小而聚焦，一个 PR 只做一件事。

## 问题报告

如果您发现了 Bug 或有改进建议，请在 [Issues](https://github.com/rkny6/echo/issues) 页面提交。

请包含以下信息：

- **环境**：Xcode 版本、iOS 版本、设备型号
- **复现步骤**
- **预期行为与实际行为**
- 如可能，附上日志或截图