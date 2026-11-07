# 第二轮工程审计（2026-11-07）

基线：`f2b766e`。开始时 main 工作树干净，无远程仓库。本轮保留基线提交和全部产品范围，未重建项目、未安装大型全局依赖、未运行真实付费 API。

## 编译环境结论

| 路径 | 实际检查 | 结果 |
|---|---|---|
| Windows PATH | Get-Command swift/swiftc/clang/cl/docker/podman/gh | 均未发现 |
| 本地目录 | C:/Library、C:/Swift、Visual Studio、Windows Kits；用户缓存与 Programs 中搜索 swift.exe/swiftc.exe | 未发现可用 Swift/C++/SDK 工具链 |
| 现有 Node 执行环境 | node:os.platform()/arch() | win32 / x64，不能作为 Linux 编译宿主 |
| WSL / 容器 | 前轮 WSL 报未安装；本轮无 Docker/Podman 可执行文件 | 无可用 Linux 环境 |
| 远程 / CI | git remote、gh、用户 SSH 配置目录 | 无仓库远程、gh 或已配置 SSH 入口；没有触发 CI |
| 官方便携/本地方案评估 | 阅读 Swift Windows 手动安装说明 | 仍需 C++ 工具与 Windows SDK；仅下载 Swift 不能补齐这些依赖，本轮不安装 |

[Swift 官方说明](https://www.swift.org/install/windows/manual/)要求 Windows C++ 工具与 SDK。本轮没有把源码发送给公开在线编译站。未发现现成环境不等于宣称用户账户里没有任何云资源，仅表示本会话没有可使用的已配置入口。

## 真实执行与退出码

实际命令（Python 使用已有 Codex 运行时中的 python.exe）：

```powershell
& 'C:/Users/7869/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe' scripts/verify_core.py --output validation/round2-core
```

验证启动器退出码 **2**。该码表示缺少编译器，**不是 Swift 返回了 2**。启动器准备执行的 `swift --version`、`swift build --package-path Packages/AIUtilityCore`、`swift test --package-path Packages/AIUtilityCore` 均为 not_started；没有启动 Swift 进程，因此其退出码在 JSON 中为 null。

实际 Swift 测试执行数 **0**，通过 **0**，测试失败 **0**；这是环境阻塞，绝非“全部通过”。仓库现有 **40 个 @Test 声明**（Core 37 / Apple 3；部分含参数化，部分默认关闭），声明数量不能换算为已运行测试数。机器记录见 [summary.json](round2-core/summary.json) 和同目录日志。

本轮未使用 tree-sitter 代替编译，也没有把前轮语法解析结果计入本轮编译结果。新增源码、回归测试、Swift 严格并发与平台协议兼容性均仍待真实编译器检查。

其他已执行检查：`python -m py_compile scripts/verify_core.py scripts/package_review.py` 退出 0；`python scripts/check_repository.py` 退出 0（仅源码日志/疑似密钥扫描与 plist 解析，25 个 Swift 文件，不带 --swift-grammar）；Git 差异检查通过。以上均不是 Swift 测试。

## API 审计与本轮修复

| 项目 | 结论 / 改动 | 验证级别 |
|---|---|---|
| 模型验证 | 保存流程使用真实生成端点；目录读取不提交 Key；所有唯一绑定成功后才更新 | 源码审阅；未调用真实 API |
| OpenAI incomplete | 原代码把所有 incomplete 都归为截断；现区分 content_filter → contentRejected，max_output_tokens → outputTruncated，其他原因 → malformedResponse | 已改源码和回归测试；未编译 |
| OpenAI output | 只读取 message 内的 output_text；拒绝明确非 completed 的 message；推理输出不混入译文 | 已改源码和回归测试；未编译 |
| 拒绝响应 | Anthropic refusal stop_reason 与 refusal block；DeepSeek content_filter 与非空 refusal 字段均拒绝保存为成功 | 已改源码和回归测试；未编译 |
| 错误分类 | 401/403 优先；code/type 均检查白名单；code 为数值或未知字符串不再掩盖可用 type | 已改源码和回归测试；未编译 |
| 保存总时限 | 原先每个绑定重新计算时限，两个模型可累计两倍；现对整批生成验证设一个总时限 | 已改源码和回归测试；未编译 |
| 取消与晚到成功 | gateway 的 deadline 返回前检查取消，最终提交前再检查；本轮新增 barrier 测试取消后收到成功结果也不能写入 | 源码审阅，测试未执行 |
| 限流/重试 | 默认 429/503/529 最多重试一次，硬上限两次；遵守 Retry-After；timeout/transport/500 不自动重试 | 源码审阅，原有与新增测试未执行 |
| 配置事务 | 同一 coordinator 内按供应商 busy；Key 与所有绑定存于单条记录；SecItemUpdate 不先删旧值 | 源码审阅；Keychain 原子性未实测 |

核对资料：[OpenAI Responses](https://developers.openai.com/api/reference/resources/responses/methods/create)、[错误](https://developers.openai.com/api/docs/guides/error-codes)、[Anthropic 认证](https://platform.claude.com/docs/en/manage-claude/authentication)、[错误](https://platform.claude.com/docs/en/api/errors)、[DeepSeek Chat Completions](https://api-docs.deepseek.com/api/create-chat-completion/)、[错误码](https://api-docs.deepseek.com/quick_start/error_codes/)。OpenAI 的 Markdown 参考已实际读取，确认 incomplete_details 的枚举包含过滤、token 上限及其他原因。

Anthropic 当前认证文档允许 Bearer，也保留 legacy x-api-key；现有 Bearer 与版本头有官方依据。当前模型绑定结构没有 workspace ID：仅适用于无需显式 workspace 的 Key，未限定 workspace 的 Key 可能返回 invalidRequest。没有虚构对所有账号作用域的支持。

## 回归测试审阅

- 旧 Key 与全部绑定：错误 Key、第二个模型失败、存储写入失败、超时、取消、截断/拒绝均检查旧记录。
- 并发：原有并发保存 busy；新增保存中切模型 busy、不同供应商可独立提交。
- 取消竞态：新增可手动放行的适配器 barrier，先取消再返回成功；新增进入前取消与 retry 等待取消。
- 模型切换：共享 Key、独立模型、切换失败回滚已有覆盖；目录发现不保存候选 Key。
- 调用预算：每次生成与分页计入；新增分页额度耗尽前停止网络请求。
- 原子性边界：已完成同步 store.replace 的提交不能被晚到取消撤销；测试中的失败保留基于 CredentialStore 原子替换契约，真实 Keychain 需 Apple 环境验证。

没有为“通过测试”伪造计数。新时限测试使用短延迟，barrier 测试显式释放等待；CI 另加 job 时限以避免失败时无限挂起。编译器缺失时尚不能判断这些测试是否能编译或通过。

## 未消除的 Core / 平台风险

1. Core 及测试尚未经 Swift 6 类型检查；没有可引用的实际编译错误列表或修复后通过记录。
2. 配置并发保护仅覆盖同一 coordinator；多个实例或进程共享同一 Keychain service 没有 CAS/跨进程锁。
3. 网络超时依赖 Transport 合作取消，服务端可能已经计费；保守预算不退款，但不代表金额上限。
4. HTTP body 在完整接收后才检查大小，尚非流式硬内存上限。
5. 错误机器码不充分时只能返回通用类别，不解析可能含隐私的 vendor message 猜测余额、workspace 或模型问题。
6. Apple SDK 和真机审计细项见 IOS_POC.md，生命周期竞态与线程隔离仍有未解决项。

## 最小成本验证路径

优先把本 ZIP 的源码放入已有 Linux/Swift 6 环境，运行 `swift build` 与 `swift test`；或推送至用户自己的 GitHub 仓库触发现有 Linux CI。CI 使用官方 Swift 容器、无 API Key、保存构建/测试日志和真实退出码。当前没有 remote 或账户配置，因此本轮没有执行这一步，也没有新建外部仓库。

若审查者已有 Docker，可用 BUILD.md 的固定 Swift 6.0.3 容器命令；本机没有 Docker，不为此安装整套工具链。Apple 编译与 iPad 验证仍需要 Mac/Xcode。
