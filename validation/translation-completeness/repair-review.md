# 编译失败后的修复审查（已完成真实复编译）

分支 codex/translation-completeness。用户先要求修好，随后批准编译/修复重试至通过。被测源 05508ba，[42739095920](https://github.com/7869123/ios/actions/runs/42739095920) 已全部 success，没有创建/合并 PR 或读取/整合 Claude 分支。原源码审查与首轮失败证据保留，最新验证见 [attempt-2](attempt-2/README.md)。

## 首轮编译诊断

证据：[42647207277](https://github.com/7869123/ios/actions/runs/42647207277)、[首轮摘要和完整日志](attempt-1/README.md)。日志行号对应被测源 `0ee791b`，不是修复后行号。

| 源文件及原行号 | 真实诊断 | 保留的修复 |
|---|---|---|
| APIConfigurationFeatureTests.swift：10、25、73、92 | 嵌套 #require 递归展开 | 先读取 body，再解析 JSON，最后独立 require |
| APIConfigurationFeatureTests.swift：114 | throwing store.read 在宏展开中缺 try | 先以 try 读取存储值，再对局部值 require |
| TranslationFeatureTests.swift：129 | 同上 | 同上 |
| TranslationReliabilityTests.swift：174 | 嵌套 #require 递归展开 | 读取、JSON 解析、require 分步 |

修复 `6aa6f64` 已覆盖这 7 处位置；原三份文件的 @Test/#expect/#require 数量均未减少。再次搜索未发现 require 内再嵌套 require、expect 内嵌套 require 或 require(store.read…) 的同类表达式；之后 42739095920 已真实编译测试模块并执行通过，编译证据与源码复核区分记录。

## 补修：被 ASR 修正推翻的旧尾句

源码：Packages/AIUtilityCore/Sources/AIUtilityCore/SubtitleTranslationSession.swift 的 SubtitleSegmenter.ingest。

原路径：已提交“Committed sentence.” → 尚未提交“ obsolete tail” → final/partial 改写了已提交前缀。旧实现直接 return，旧尾句仍留在 hypothesis，后续稳定 flush、下个 utterance 或迟到 final 可能提交已失效文字。

新路径：保留已发布前缀，清除旧尾句并推进 sequence/timestamp 水位；final 同时 retire 当前 utterance。partial 后若出现兼容已发布前缀的新假设，可继续翻译新尾句。不能对齐的修正内容明确舍弃，不凭空拼接、修改旧字幕或发送错误尾句。

新增回归位于 TranslationReliabilityTests.swift：

- subtitleInvalidatedFinalCannotFlushOrLeakIntoNextUtterance：两组参数覆盖先 flush/直接后续事件；旧 final 不得重放，下一 utterance 仅产生新句。
- subtitleInvalidatedPartialDropsTailAndAdvancesSequenceBeforeRecovery：丢弃旧尾句、屏蔽低序号迟到事件、静默 flush 不产出、兼容 final 仅提交 corrected tail。

新增 2 个测试声明、3 组场景；原测试/断言保留。当前 Core 有 83 个 @Test 声明，真实 Linux/macOS 逐项结果均为 82 通过/1 跳过/0 失败，不把声明数作为通过数量。两个新测试均已执行，为同步纯文本归约，不请求 API、不依赖 Speech 或设备。

## 验证边界与交接

- 已执行本地 Swift 静态语法/源码卫生/plist 检查，88 文件，退出 0；git diff --check 退出 0。没有本地 Swift 工具链，不安装 Windows Swift。
- 当前生产分段修复与测试修复已在 05508ba 真实编译/执行通过。首轮 0ee791b 的 Core test=1/执行 0 记录不改写；最新 Apple/PoC SDK/App 全部成功并生成未签名 IPA，仍无真机结论。
- 没有修改公开类型/方法签名。行为变化仅为被推翻的未提交尾句清理；Claude 接口调用不变。没有修改 UI、AppleServices、PoC、workflow、scripts、工具版本或依赖。
- 原首轮 evidence 不改写；本次按用户授权只触发 1 个新 run，无需再重跑。真实 API、Keychain、ASR 缓存补送/边界识别、跨 App 音频、PiP 与后台仍需独立运行证据。UI actor 隔离警告与 PoC 弃用警告完整保留，不修改越权文件。
