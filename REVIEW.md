# 给后续 AI / 工程审查者

先阅读 STATUS.md 和 validation/github-actions/README.md。**当前 Core 已通过真实 Linux Swift 6.0.3 编译和单元测试：36 通过、1 跳过、0 失败。** Apple SDK、真实 API 和 iPad 功能仍未验证。早期第二轮 ZIP e2ac66b 的“0 项执行”是历史状态，不能混用于当前版本。

使用 scripts/package_review.py 生成的 ZIP 包含其 HEAD 的全部受 Git 跟踪文件、验证记录与 `AIUtility-history.bundle`。不包含 .git 工作目录、构建缓存、Python 依赖、环境变量或真实 API Key。`REVIEW_MANIFEST.json` 给出提交、逐文件 SHA-256 和 bundle 校验值；包外 `.zip.sha256` 校验整个 ZIP。

直接解压即可检查源码。若要恢复第一轮和第二轮提交：

```sh
git clone AIUtility-history.bundle AIUtility-with-history
cd AIUtility-with-history
git log --oneline
swift --version
swift build --package-path Packages/AIUtilityCore
swift test --package-path Packages/AIUtilityCore
```

请先修复真实编译/测试失败，再扩展功能。重点审查：Swift 6 Sendable/协议隔离与 Swift Testing 宏、取消后晚到结果、Key 与两功能模型的原子提交、三家错误与拒绝/截断解析、总验证时限。

有 Apple SDK 后再检查 IOS_POC.md 的符号和生命周期竞态；不要声称 iPad mini 6 / iPadOS 27.2 已通过测试。下载器、截图翻译、实时字幕及《Blue Archive》UI 都必须保留在产品范围。
