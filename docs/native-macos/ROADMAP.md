# klogg4mac — 原生 macOS 重写：团队设计与路线图

> 目标：在 Apple Silicon 上长期可用、消除「未来不被支持」告警；用 **AppKit 原生 UI** 1:1 复刻 klogg 的功能与布局；**复用经过验证的 C++ 引擎层**，通过薄桥接连接。

---

## 1. 架构决策（已确认）

| 决策点 | 选择 | 理由 |
|---|---|---|
| UI 框架 | **AppKit (Cocoa)** | 日志主视图是自绘的、需高速滚动上百万行；NSView/NSScrollView 自绘对像素级 1:1 复刻和性能控制力最强。SwiftUI 无法胜任海量行自绘。 |
| 引擎层 | **复用 C++ 核心 + Objective-C++ 桥接** | `logdata/regex/search/settings/logging/utils/filewatch` **完全不依赖 Qt GUI**（无 `QWidget`/`QApplication`，仅用 QtCore），是多年验证的内存映射 + 索引 + 多线程搜索 + vectorscan 正则。重写它风险最高、收益最低。 |
| 语言 | UI 用 **Swift + 少量 Objective-C++**；引擎保持 **C++** | 桥接层用 Objective-C++（`.mm`）暴露 C 风格/Obj-C 接口，Swift 侧调用。 |

### 分层

```
┌─────────────────────────────────────────────┐
│  AppKit UI (Swift)                           │  ← 全部重写
│  主窗口 / 日志视图 / 搜索面板 / 对话框 / 菜单    │
├─────────────────────────────────────────────┤
│  Bridge (Objective-C++ .mm)                  │  ← 新建，薄
│  KloggEngine facade：打开文件/索引/搜索/        │
│  高亮/设置 → C++ 对象；回调/进度 → Swift        │
├─────────────────────────────────────────────┤
│  C++ Engine (复用，保持 QtCore)               │  ← 基本不动
│  logdata · regex · settings · logging ·       │
│  utils · filewatch                           │
└─────────────────────────────────────────────┘
```

**关键边界规则**：UI 层不得直接 include 任何 Qt 头；所有 Qt 类型（QString/QRegularExpression 等）在桥接层转换成 Foundation 类型（NSString/NSData/原生回调）。这样 UI 是纯原生，引擎是纯 C++，告警来源（Qt GUI 弃用 API）被彻底移除。

---

## 2. 组件清单：Qt → AppKit 映射

以现有 `src/ui` 文件为基准，逐一对应（这是「1:1 复刻」的验收清单）：

| klogg (Qt) 组件 | 职责 | AppKit 对应 |
|---|---|---|
| `mainwindow` / `mainwindowtext` / `menu` | 主窗口、菜单栏、工具栏、最近文件 | `NSWindowController` + `NSToolbar` + `NSMenu` |
| `crawlerwidget` / `tabbedcrawlerwidget` | 中央分栏：主视图+过滤视图+搜索框；多标签 | `NSSplitViewController` + `NSTabViewController`(或自绘 tab) |
| `abstractlogview` / `logmainview` / `filteredview` | **自绘海量日志行视图**（核心难点） | 自定义 `NSView` + `NSScrollView`，CoreText 绘制 |
| `overview` / `overviewwidget` | 滚动条侧的概览/小地图 | 自定义 `NSView` 叠加在滚动条旁 |
| `quickfind*` / `qfnotifications` | 增量查找栏 | 自定义 `NSView` 浮层 + `NSSearchField` |
| `highlighters*`（set/edit/dialog/menu/match） | 高亮规则系统 + 编辑对话框 | 模型层移植 + AppKit 对话框/`NSColorWell` |
| `optionsdialog` | 偏好设置 | `NSWindowController`(多 tab Preferences) |
| `predefinedfilters*` | 预定义过滤器下拉 + 对话框 | `NSComboBox`/`NSPopUpButton` + 对话框 |
| `savedsearches` / `recentfiles` / `favoritefiles` | 历史/收藏（带持久化） | 模型层移植 + `NSMenu`/列表 |
| `scratchpad` / `tabbedscratchpad` | 便签工具 | `NSTextView` + 标签 |
| `infoline` / `pathline` / `displayfilepath` | 状态行/路径显示 | `NSTextField`/自定义状态视图 |
| `colorlabelsmanager` / `encodings` | 颜色标签、编码菜单 | 模型移植 + `NSMenu` |
| `session` / `sessioninfo` | 会话恢复 | 移植到原生持久化（同格式以兼容） |
| `selection` | 文本选择逻辑 | 在自绘视图中重做选择/复制 |
| `iconloader`/`fontutils`/`viewtools`/`signalmux`/`viewinterface` | 内部管线/工具 | Swift 侧重做（多为胶水代码） |
| `decompressor` / `downloader` | 解压、打开远程文件 | 评估保留在引擎侧或用原生替代 |

---

## 3. 团队设计

> 注：这是**长周期工程**（非一次性脚本），团队按能力域划分。可对应到 harness 的 agent，也可对应真人协作者。每个角色给出明确产出物与验收口径。

### 3.1 角色

| 角色 | 代号 | 职责范围 | 主要产出 |
|---|---|---|---|
| **架构负责人 / 集成** | `arch` | 维护本路线图、分层边界、Xcode 工程与 CMake/C++ 库的集成、CI、签名打包 | 工程骨架、构建脚本、合并把关 |
| **桥接工程师** | `bridge` | Objective-C++ facade，QtCore↔Foundation 类型转换，线程/回调模型，进度与取消 | `KloggEngine` 桥接库 + 单元测试 |
| **核心视图工程师** | `logview` | `abstractlogview/logmainview/filteredview` 的 AppKit 自绘、滚动、选择、复制——**风险最高、最先攻坚** | 原生日志视图组件 |
| **外壳/导航工程师** | `shell` | 主窗口、菜单、工具栏、分栏、标签、状态行、最近/收藏文件 | 应用外壳 |
| **搜索/过滤工程师** | `search` | 搜索框、QuickFind 增量查找、预定义过滤器、概览 minimap | 搜索交互全链路 |
| **对话框/设置工程师** | `dialogs` | 高亮规则、偏好设置、预定义过滤器对话框、颜色标签、编码、便签 | 全部对话框与设置 UI |
| **像素复刻 / QA** | `qa` | 与原版逐屏对照（布局、间距、字体、交互、快捷键），自动化 UI 测试与回归 | 对照基线 + 测试套件 |

### 3.2 协作与依赖

```
arch  ──建工程骨架──►  所有人
bridge ──引擎接口先行──►  logview / shell / search / dialogs
logview ──核心视图组件──►  search（过滤/概览依赖视图）
shell ──窗口/分栏容器──►  logview/search/dialogs 挂载点
qa  ──贯穿全程，对每个组件出对照报告──►  反馈给各角色
```

关键路径：`arch 工程骨架` → `bridge 引擎打开/读取接口` → `logview 能渲染一个大文件` → 其余并行。

---

## 4. 分阶段路线图

### 阶段 0 — 地基（架构 + 桥接）
**目标**：Xcode 工程能链接 C++ 引擎库，桥接层能打开文件并读出行。
- `arch`：建立 Xcode 工程；用 CMake 把 `logdata/regex/settings/logging/utils/filewatch` 编成静态库（保留 QtCore，arm64）；接入 vectorscan；CI 跑通 arm64 构建。
- `bridge`：设计 `KloggEngine` facade —— 打开文件、获取行数、按行号取文本、启动/取消索引、进度回调；QString→NSString、线程模型（引擎在后台线程，回调切回主线程）。
- **验收**：命令行/最小窗口能打开一个 1GB 日志并打印行数与任意行内容。

### 阶段 1 — 核心日志视图（最高风险，单独攻坚）
**目标**：原生自绘视图能以接近原版的性能滚动百万行、选择、复制。
- `logview`：`NSScrollView` + 自定义 `NSView`，按可视区行号向桥接拉取文本，CoreText 绘制；行号栏；选择与复制；与原版一致的字体（等宽）、行高、tab 展开、换行策略。
- `qa`：建立与原版的逐像素对照基线（同一文件、同一字体）。
- **验收**：与原版并排滚动同一大文件，视觉与流畅度一致，选择/复制行为一致。

### 阶段 2 — 应用外壳
- `shell`：主窗口 + `NSToolbar` + 菜单栏（含全部快捷键）+ `NSSplitView`（主视图/过滤视图）+ 多标签 + 状态行/路径行 + 拖拽打开 + 最近/收藏文件。
- **验收**：能打开多文件多标签，布局与菜单结构与原版逐项一致。

### 阶段 3 — 搜索与过滤
- `search`：搜索输入框（正则/大小写/逆向选项）→ 桥接调用引擎搜索 → 过滤视图显示命中；QuickFind 增量查找浮层；预定义过滤器；概览 minimap（命中分布）。
- **验收**：搜索结果、计数、跳转、增量查找行为与原版一致。

### 阶段 4 — 对话框与设置
- `dialogs`：高亮规则（颜色/正则/集合）、偏好设置（多 tab）、预定义过滤器对话框、颜色标签、编码菜单、便签。设置持久化尽量复用引擎 `settings` 格式以兼容旧配置。
- **验收**：每个对话框逐项对照原版；高亮渲染效果一致。

### 阶段 5 — 收尾、打包、回归
- `arch`：universal/arm64 签名、公证、`.dmg` 打包（复用 `packaging/osx` 资源）；自动更新评估。
- `qa`：全功能回归 + 快捷键全表核对 + 大文件压力测试 + 会话恢复兼容性。
- **验收**：在最新 macOS / Apple Silicon 上无弃用告警，功能/布局 1:1。

> 顺序是硬约束；各阶段内可并行。阶段 1 建议最早启动并预留缓冲——它是整个项目成败的关键。

---

## 5. 主要风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| **海量行自绘性能**（阶段 1） | 决定项目可行性 | 最先做 PoC；按需拉取可视行；CoreText 复用 typesetter；与原版基准对比 |
| QtCore 仍被引擎依赖 | 仍需打包 Qt 库 | 可接受（QtCore 不触发 GUI 弃用告警）；UI 零 Qt 即可消除告警。若要彻底去 Qt，列为后续独立项目 |
| 桥接线程/取消模型复杂 | 卡顿、崩溃 | 桥接层统一封装后台线程 + 主线程回调 + 取消令牌；早期写单测 |
| 「1:1」标准模糊 | 反复返工 | `qa` 在阶段 1 就建立逐屏对照基线，作为唯一验收口径 |
| 自动更新/签名/公证 | 发布受阻 | 阶段 0 就跑通 CI 签名最小闭环，不留到最后 |

---

## 6. 立即可启动的第一步（待批准后执行）

1. `arch`：搭 Xcode 工程骨架 + CMake 把引擎编成 arm64 静态库，CI 跑通。
2. `bridge`：`KloggEngine` 最小 facade（打开文件 / 行数 / 取行 / 索引进度回调）。
3. `logview`：自绘视图渲染大文件的 PoC（阶段 1 攻坚的起点）。

> 本文档由架构角色维护，是各角色的事实源与验收基线。
