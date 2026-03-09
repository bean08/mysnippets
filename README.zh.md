# mysnippets（macOS）

英文版见：[README.md](README.md)

`mysnippets` 是一个原生 macOS Snippet 工具原型，整体体验更接近 Alfred / Raycast：
- 支持多级分组树
- 支持紧凑列表，并可调整行高和字体大小
- 每条 snippet 可选描述字段，可用于列表展示、搜索和导出
- 支持仅预览可见的注释块 `{{! ... }}`
- 支持类似 Raycast 的动态占位符
- 使用单文件 JSON 存储，并自动热加载

## 运行

```bash
cd mysnippets
swift run mysnippets
```

## 占位符说明

你可以在 snippet 正文里直接写占位符，程序会在复制或自动填入前展开。

当前支持的占位符：
- `{cursor}`：不会出现在最终文本里；粘贴完成后，光标会回到这个位置
- `{clipboard}`：替换为当前剪贴板文本
- `{date}`：替换为当前日期，格式跟随系统地区设置
- `{time}`：替换为当前时间，格式跟随系统地区设置
- `{datetime}`：替换为当前日期和时间，格式跟随系统地区设置
- `{uuid}`：替换为一个新的小写 UUID

补充说明：
- 如果正文里出现多个 `{cursor}`，最终只会使用最后一个位置。
- 不认识的 `{...}` 占位符会保留原样，不会被删除。
- `{{! ... }}` 注释块只用于预览提示，复制和自动填入时会被移除。

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

存储格式：
- 顶层字段包括 `version`、`groups`、`snippets`
- 分组层级通过 `groups[].parent_id` 表示
- 分组隐藏状态通过 `groups[].hidden` 表示
- snippet 正文按多行数组存储在 `snippets[].body`
- snippet 描述存储在可选字段 `snippets[].description`
