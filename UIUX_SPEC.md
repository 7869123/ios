# AIUtility UI/UX 规范

记录日期：2026-11-07。范围：`Apps/AIUtility`（SwiftUI App 层）。Core、API 服务、`PoCs/iOS27Capture` 不受本规范影响。

## 0. 设计目标（2026-11-07 修订）

- **结构**：遵循 iOS 原生系统模式。iPad 使用 `NavigationSplitView` 侧边栏，iPhone 使用 `TabView` 标签栏；页面内部用 `NavigationStack`、`List`/`Form`、`sheet`、`Toolbar` 等系统组件，系统手势、返回、安全区域和辅助功能行为都保持原样。
- **风格**：明亮、清爽的蓝·白·青配色，视觉轻快，有少量几何装饰，并保持较好的信息层次。用户希望整体观感对标《蔚蓝档案》这类明快风格；本规范只采用"明亮蓝白、轻快"这一通用方向。**所有布局、组件、装饰和图标组合均为原创，不以任何游戏的截图、素材或具体界面为参照，也不使用其图标、字体或美术资源。**
- **首要设备**：iPad mini 6（8.3 英寸，竖屏 744×1133 pt，横屏 1133×744 pt）。iPhone 继续可用，但不为迁就 iPhone 而压缩 iPad 布局。
- 这是交接文档中 UI 目标的更正：此前 STATUS.md 列出的"高保真复刻《Blue Archive》界面"不再是目标。

## 1. 参考依据

| 参考 | 用途 |
|---|---|
| Apple Human Interface Guidelines（Layout、Sidebars、Tab bars、Color、Typography、Accessibility） | 导航结构、间距、文字样式、对比度 |
| SwiftUI 系统组件 | 页面骨架与交互行为 |
| 本仓库原有页面（截图翻译、字幕翻译、设置、媒体工具） | 功能与文案，不改变业务逻辑 |

不参照任何游戏截图。

## 2. 页面映射

| 侧边栏/标签 | 页面 | 状态 | 说明 |
|---|---|---|---|
| 工作台 | `HomeView`（**本轮新增原型**） | 可预览 | 默认首页；功能入口 + 状态 |
| 截图翻译 | `ScreenshotView` | 已有 | Discord 等截图 OCR + 翻译 |
| 字幕翻译 | `SubtitleView` | 已有 | 字幕文本翻译 |
| 媒体工具 | `MediaToolsView` | 已有目录 | X / Pixiv / B站下载、GIF、拼接、指纹、搜图、下载任务，均为"规划中" |
| 设置 | `SettingsView` | 已有 | AI 供应商、Key、模型绑定、预算 |
| （首页弹层）实时字幕 · PiP | `LiveCaptionInfoSheet` | 仅状态说明 | PoC 在 `PoCs/iOS27Capture`，未接入 App，未经真机验证 |

首页磁贴只负责跳转。规划中的功能明确标为"规划中"，不显示为可用。

## 3. 组件与交互

| 组件 | 文件 | 说明 |
|---|---|---|
| `WorkspaceBackdrop` | Theme.swift | 页面背景：canvas→白色的竖向渐变，右上角细斜线纹理（`Canvas` 绘制，6% 不透明度），两处半透明光晕；不参与辅助功能 |
| `SlantBar` | Theme.swift | 自定义 `Shape` 平行四边形，作为统一的标志性装饰：卡片顶部强调条、分区标题、日期标记、侧边栏页脚 |
| `UtilityCard` | Theme.swift | 通用内容卡：白底，圆角 18，1pt 描边，柔和投影，顶部斜角强调条 |
| `FeatureTile` | HomeView.swift | 功能磁贴：44pt 图标块 + 状态胶囊 + 标题 + 两行说明（预留高度，保证网格对齐）；规划中的功能用灰色图标和灰色强调条 |
| `StatusChip` | Theme.swift | 可用 / PoC · 未经真机验证 / 规划中 |
| 首页主卡（实时字幕） | HomeView.swift | 深蓝渐变横幅 + 白字 + "了解进度"按钮，点击打开半屏 sheet |
| 供应商胶囊 | HomeView.swift | 显示截图 / 字幕当前供应商，点击跳到设置 |
| `PressableCardStyle` | Theme.swift | 按压反馈：缩放到 0.97，亮度 −3%，弹簧动画（response 0.25，damping 0.7）；开启"减弱动态效果"时不缩放 |

交互：点按磁贴切换侧边栏或标签选中项（iPad 和 iPhone 共用一个选中状态）；主卡用系统 `sheet`，提供 medium / large 两档高度。页面转场使用系统默认动画，不自定义。

## 4. 视觉参数

### 颜色

| Token | 值 | 用途 | 白底对比度 |
|---|---|---|---|
| `brand` | #1A8FE3 | 填充、装饰、渐变 | 3.5:1（只用于装饰和大字） |
| `brandStrong` | #0B6FC2 | 文字、图标、全局 tint | 5.2:1 ✅ AA |
| `aqua` | #3CCBE6 | 渐变末端、光晕 | 仅装饰 |
| `ink` | #14283C | 标题文字 | ≈15:1 ✅ |
| `canvas` | #F2F8FD | 页面底色 | — |
| `planned` | #5B6B7B | 规划中状态 | 5.5:1 ✅ |
| `poc` | #A85F00 | PoC 状态 | 4.9:1 ✅ |
| `brandGradient` | brand → aqua | 仅装饰条和光晕，不放白字 | — |
| `deepGradient` | brandStrong → brand | 主卡、图标块（白字/白图标） | 5.2–3.5:1；主卡标题为 title2 粗体（大字） |

当前固定为浅色模式（沿用原有 `.preferredColorScheme(.light)`）；深色模式在后续页面完成后统一设计。

### 文字（Dynamic Type 文字样式，不写死字号）

| 用途 | 样式 |
|---|---|
| 页面标题 | `.largeTitle.bold()` |
| 主卡标题 | `.title2.bold()` |
| 分区标题 | `.title3.bold()` |
| 磁贴标题 | `.headline` |
| 说明文字 | `.subheadline` / `.footnote`，secondary |
| 日期与标签 | `.caption.semibold`，`.caption2.semibold` |

### 尺寸与布局

| 参数 | 值 |
|---|---|
| 页面边距 | 24 pt |
| 内容最大宽度 | 1080 pt（首页）、900 pt（表单页） |
| 网格间距 / 卡片内间距 | 16 pt / 18–20 pt |
| 圆角 | 卡片 18，主卡 22，图标块 12，胶囊全圆 |
| 斜角强调条 | 40×4 pt，斜率 0.35 |
| 投影 | brand 6%，半径 12，y 4；主卡 25%，半径 18，y 8 |
| 磁贴网格 | `GridItem(.adaptive(minimum: 230))` |

iPad mini 6 上的预期列数（扣除边距和间距后计算）：
- 横屏显示侧边栏时，详情区约 813 pt → 每行 3 个磁贴；
- 竖屏侧边栏收起时，744 pt → 每行 2 个磁贴；
- iPhone → 每行 1 个磁贴。

首页标题区用 `ViewThatFits`：空间够时标题和供应商胶囊横排，不够时竖排。

## 5. 实现方式

- SwiftUI（iOS 17+），自定义 `Shape`（`SlantBar`）、`Canvas`（背景纹理）、`ButtonStyle`（按压反馈）、`ViewThatFits`、`LazyVGrid`。
- 图标全部使用 SF Symbols，不引入第三方或游戏素材，所以本轮没有新增 Assets 资源目录；以后加入自有原创素材时再建立 `Assets.xcassets` 和组件映射表。
- 设计 token 集中在 `UtilityTheme`；数值改动须同时更新本文件。

## 6. 与 iOS 原生默认样式的差异及原因

| 差异 | 原因 |
|---|---|
| 首页用自定义卡片网格，没有用系统 `List` | 首页是功能总览，网格在 iPad 上信息密度更合适；其他页面仍以系统组件为主 |
| 自定义背景纹理、光晕和斜角强调条 | 建立统一的明快风格识别 |
| 自定义按压缩放 | 卡片式按钮需要明显的按压反馈；"减弱动态效果"开启时会关闭 |
| 暂时固定浅色模式 | 沿用原有设置，深色模式待统一设计 |

## 7. 视觉对照与验收

1. **CI 截图**：`app` job 构建后运行 `scripts/app_screenshots.sh`。它在 iPad mini 模拟器和一台 iPhone 模拟器上启动 App，截取首页的竖屏和横屏（横屏通过仅在 Debug 构建生效的启动参数 `-AIUtilityPreviewLandscape` 旋转），上传为 artifact `app-screenshots-<run_id>-<attempt>`。注意：模拟器是 iPad mini（A17 Pro），尺寸与 iPad mini 6 相同（744×1133 pt），但不是 iPad mini 6 真机。
2. **人工审核清单**：
   - 横屏每行 3 个、竖屏每行 2 个磁贴；
   - 文字没有截断，说明文字的行高对齐；
   - 状态胶囊准确（规划中的功能不显示为可用）；
   - 主卡白字清晰；
   - 安全区域内没有内容被遮挡。
3. **辅助功能**：
   - 对比度按第 4 节表格；
   - 用最大号 Dynamic Type 检查是否换行、溢出；
   - VoiceOver：磁贴合并朗读标题、状态和说明；分区标题带 header 属性；供应商胶囊有完整标签；
   - "减弱动态效果"开启时不缩放。
4. **偏差记录**：审核意见记录在 PR #1，并回写本文件的 token 或布局参数。

## 8. 后续计划（等首页审核通过后再做）

1. 把截图翻译、字幕翻译、设置、媒体工具页面统一到新 token 和组件（这些页面已沿用新的 `UtilityCard` 和背景）。
2. 设计深色模式。
3. 规划媒体工具各子页面和下载任务页面的结构（功能本身仍未实现）。
4. 实时字幕 PoC 真机验证通过后，再设计 App 内的控制页面。
