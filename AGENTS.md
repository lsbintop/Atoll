# Agent 规则

以下规则适用于本仓库中的所有工作。

## 方案明确时直接执行

- 不要反复停留在调研、方案设计、计划编写或等待确认阶段。
- 当问题和解决方案相对明确、可靠时，直接实施，让用户验收最终结果。
- 调研深度应与不确定性和风险相匹配。阅读足够的代码以准确定位修改点后，立即执行。
- 编辑、格式化、构建、安装和启动等常规实施步骤之间，不要逐步询问用户是否继续。
- 只有在缺少必要信息、存在多个会显著影响产品行为的方案，或操作不可逆、具有破坏性、涉及安全风险、超出用户请求范围时，才需要先询问。
- 在条件允许时端到端完成任务：实现、验证、安装、启动并报告结果。

## macOS 构建和验证流程

- 禁止打开 Xcode 构建或验证应用。
- 每次验证构建前，必须终止所有正在运行的 Atoll 实例，避免旧进程争抢窗口、音频会话、权限或 Now Playing 状态。
- 必须通过命令行使用 `Release` 配置构建。
- 必须使用稳定的 Apple Development 签名配置。
- 必须将新构建的应用安装到 `/Applications/Atoll.app`。
- 安装完成后必须启动 `/Applications/Atoll.app`。
- 必须验证安装在 `/Applications` 中的应用，禁止验证从 Xcode 或 DerivedData 直接运行的应用。

使用以下流程：

```bash
pkill -x Atoll || true

xcodebuild \
  -project DynamicIsland.xcodeproj \
  -scheme DynamicIsland \
  -configuration Release \
  -derivedDataPath .derived-data-release \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=C66NCUJ476 \
  CODE_SIGN_IDENTITY="Apple Development" \
  build

rm -rf /Applications/Atoll.app
ditto .derived-data-release/Build/Products/Release/Atoll.app /Applications/Atoll.app
open /Applications/Atoll.app
```

- 只有在构建明确输出 `BUILD SUCCEEDED` 后，才能替换已安装的应用。
- 安装完成后，根据任务需要验证签名和安装版本：

```bash
codesign -dv --verbose=2 /Applications/Atoll.app
defaults read /Applications/Atoll.app/Contents/Info CFBundleShortVersionString
defaults read /Applications/Atoll.app/Contents/Info CFBundleVersion
```
