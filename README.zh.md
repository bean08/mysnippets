# mysnippets

[English README](README.md) · 许可证：[Apache-2.0](LICENSE)

`mysnippets` 是一个原生 macOS Snippet 管理工具，支持分层组织、动态占位符和键盘优先的快速插入面板。

## 功能特性

- 基于 SwiftUI + AppKit 的原生 macOS 应用
- 三栏管理界面：分组、片段列表、预览
- 支持全局快速唤起和分层分组导航
- 快速插入面板补充了更清晰的左右分栏层次和更干净的圆角视觉
- 支持 snippet 描述字段，可用于搜索和导出
- 支持仅预览可见的注释块 `{{! ... }}`
- 支持类似 Raycast 的动态占位符
- 支持自定义 `snippets.json` 存储路径
- 支持打包为同时兼容 Apple Silicon 和 Intel 的通用 macOS 应用

## 环境要求

- macOS 13.0 或更高版本
- Xcode / Swift 5.9 及以上工具链

## 开发运行

```bash
cd mysnippets
swift run mysnippets
```

## 打包

```bash
cd mysnippets
./scripts/package-macos.sh
```

输出文件：

- `dist/mysnippets.app`
- `dist/mysnippets.dmg`

该脚本会分别构建 `arm64` 和 `x86_64` 的 release 二进制，再合并成一个通用应用包。

## 占位符说明

当前支持：

- `{cursor}`：不会出现在最终文本中；粘贴后光标会回到这里
- `{clipboard}`：插入当前剪贴板文本
- `{date}`：按系统地区格式插入当前日期
- `{time}`：按系统地区格式插入当前时间
- `{datetime}`：按系统地区格式插入当前日期和时间
- `{uuid}`：插入新的小写 UUID

补充说明：

- 如果出现多个 `{cursor}`，最终只使用最后一个位置。
- 未识别的 `{...}` 会原样保留。
- `{{! ... }}` 注释块仅用于预览，复制和自动填入时会被移除。

示例：

```text
标题：{clipboard}
创建时间：{datetime}

摘要：
{cursor}
```

## 存储

默认存储文件：

- `~/Documents/mysnippets/snippets.json`

你也可以在 `设置 -> 存储文件` 中改成任意 `snippets.json` 完整路径，支持 `~`。

存储结构：

- 顶层字段：`version`、`groups`、`snippets`
- 分组层级：`groups[].parent_id`
- 分组启用/禁用状态：`groups[].hidden`
- 正文多行内容：`snippets[].body`
- 可选描述字段：`snippets[].description`

## 发布

- 当前版本：`0.0.4`（来自 [`VERSION`](VERSION)）
- 推荐 Git tag：`v0.0.4`
- `v0.0.4` 最新变更：
  - 移除了快速插入面板里冗余的提示文案和侧边栏刷新按钮
  - 排序拖拽把手改为仅在悬停时显示
  - 优化了快速插入面板的圆角和左右分栏对比度
- 变更记录见：[CHANGELOG.md](CHANGELOG.md)

## 许可证

本项目采用 Apache License 2.0，详见 [LICENSE](LICENSE)。
