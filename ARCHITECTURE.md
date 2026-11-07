# 架构与约束

## 模块边界

```text
未来 SwiftUI App / 独立 PoC Host
  └─ AIUtilityAppleServices.AIUtilityServices（生产接线）
       ├─ KeychainCredentialStore → Security
       ├─ VisionOCRService → Apple Vision / ImageIO（本地）
       └─ AIUtilityCore
            ├─ ConfigurationCoordinator（配置事务 actor）
            ├─ TranslationEngine（翻译、输入保护）
            └─ ProviderGateway（总时限、预算、有限重试）
                 └─ OfficialAPIAdapter（按供应商选择官方协议）
                      └─ HTTPTransport → URLSession

PoCs/iOS27Capture（独立包，不被生产 Core 引用）
  SCContentSharingPicker → SCStream .audio → 本地 Speech
  → 文本 / 可选 TranslationEngine → 字幕视频帧 → AVKit PiP
```

Core 是独立 Swift Package，跨平台测试时只替换 HTTPTransport 与 CredentialStore。AppleServices 是另一独立 Package，单向依赖 Core。Apple 框架以条件编译隔离，不在 Windows 上假造 Keychain、Vision 或 ScreenCaptureKit 的实现。

## 官方协议

| 供应商 | 模型发现 | 指定模型生成 | 认证 / 特殊处理 |
|---|---|---|---|
| DeepSeek | `GET https://api.deepseek.com/models` | `POST /chat/completions` | Bearer Key；system/user messages；排除 reasoning_content |
| Anthropic | `GET https://api.anthropic.com/v1/models` | `POST /v1/messages` | Bearer Key；固定 `anthropic-version: 2026-10-21`；独立 system 字段；遍历游标 |
| OpenAI | `GET https://api.openai.com/v1/models` | `POST /v1/responses` | Bearer Key；instructions/input；`store:false`；只读取 output_text |

官方端点封装在一个实现中，共享 HTTP 机制，生成请求与响应按三家分别编码/解码。模型名完全由发现结果/调用者指定；不把目录里的任意模型视为可用的文本生成模型，也不因为“型号存在”而跳过生成验证。

OpenAI incomplete 按原因区分：max_output_tokens 为 outputTruncated，content_filter 为 contentRejected，未知原因为 malformedResponse。DeepSeek length、Anthropic max_tokens 为 outputTruncated；拒绝/过滤为 contentRejected；空文本与结构不符为 malformedResponse。只读取完成的 message 文本，不把推理文本或截断文本当成成功翻译。

2026-11-07 已核对：[DeepSeek 模型](https://api-docs.deepseek.com/api/list-models/)、[Chat Completions](https://api-docs.deepseek.com/api/create-chat-completion/)、[Anthropic 模型](https://platform.claude.com/docs/en/api/models/list)、[Messages](https://platform.claude.com/docs/en/api/messages/create)、[版本](https://platform.claude.com/docs/en/api/versioning)、[OpenAI 模型](https://developers.openai.com/api/reference/resources/models/methods/list)、[文本生成](https://developers.openai.com/api/docs/guides/text)。本轮采用 OpenAI Docs 技能核对 OpenAI 接口。接口资料核对不代表账户、模型权限或真实调用通过。

## 保存与模型切换的事务

每个供应商只使用一个 Keychain account（ProviderID.rawValue），service 默认 `com.aiutility.credentials.v1`。该条记录同时包含一个 Key 和 `[TranslationFeature: modelID]`。两个功能是 discordScreenshot / videoSubtitle，可选不同模型。

首次配置可调用 `discoverModels(candidateKey:)`，候选 Key 只存在于内存；目录读取不会保存它。`saveKey` 合并已有绑定与新绑定，对所有唯一模型进行真实生成验证，全部获得完整非空响应才写入。相同模型只验证一次；任一模型失败则不触碰旧记录。不存在旧记录且绑定为空时拒绝保存。

`switchModel` 读取现有共享 Key，只验证所改模型；成功后提交包含所有绑定的新记录。无需重输 Key。验证也受预算、取消、总时限控制。调用“Reply OK”是一次真实模型调用，可能收费；没有字符串格式验证或目录请求替代生成验证的捷径。

同供应商的并发编辑在整个验证期间返回 configurationBusy。不同供应商可独立处理，翻译可继续使用最后提交的快照。生产应在一个 service 命名空间内只创建一个长期存活的配置协调器；没有实现跨进程/多协调器事务锁。

最后一次取消检查与 Keychain 写入之间没有 await。写入是提交点，已经完成的系统写入不能被晚到的取消逆转。采用 SecItemUpdate 一次性替换完整记录，首次保存用 SecItemAdd；不会先删除旧 Key 再尝试添加。协议要求存储失败时保留旧值，测试替身也遵守该约束。

## 预算、错误、取消

CallBudget actor 在每次实际生成尝试和目录分页前扣次数，生成另预留 maxOutputTokens。默认整个服务会话最多 100 次、累计预留输出 65,536 tokens。失败、取消、超时均不返还额度，因为远端可能已执行并计费。输入有字节上限，输出参数受范围约束。

这是保守的调用/输出额度控制，**不是美元预算、全 token 计费上限或跨重启的每日账本**。输入 token、价格和服务商结算不在本轮预算中；下一阶段若需要金额预算，需引入版本化价格、供应商 usage 与持久化账本。不要通过每次新建 Services 绕过会话额度。

错误区分认证、权限、模型不可用、无效请求、额度不足、限流、过载、5xx、网络、超时、取消、结构错误、截断、拒绝、预算和存储错误。只保留白名单机器分类，不保留错误响应原文。供应商没有提供可靠机器码时不猜测用户文本中的错误原因。

默认仅对 429 和明确过载 503/529 重试一次，可配置但硬限制最多两次；遵守 Retry-After，超出允许等待则返回错误。401/403/404、500、网络异常、超时及取消不自动重试。总时限包含分页、重试和等待；底层 URLRequest 还设置单次超时。Task 取消会传播到 URLSession 和重试等待。自定义测试/扩展 Transport 也必须响应取消；结构化并发无法强行终止拒绝取消的第三方实现。

## 敏感数据

- APIKey、请求、生成结果及配置的描述/反射隐藏内容。错误中没有原始 body、认证头或源文本。生产源码没有日志调用。
- 官方 HTTPS origin 固定，拒绝重定向，不支持用户随意配置代理 API 地址；依赖平台正常 TLS 验证。
- URLSession 使用 ephemeral 配置，关闭响应缓存、Cookie 存储和凭据存储。响应大小在收取后验证；当前不是流式内存限额实现。
- Keychain 禁止云同步，使用 WhenUnlockedThisDeviceOnly。锁屏或 Keychain 不可用时返回 storageFailure，不降级到 UserDefaults/文件。锁屏连续翻译是否需要不同访问策略要由真机需求决定。
- OCR 只在设备上识别，只有明确提交的文本进入供应商请求。图像不默认上传。
- 翻译前遮蔽当前 API Key、常见 sk- 凭据、Bearer 值和默认启用的邮箱地址；使用每请求随机占位符，响应本地恢复。占位符被改写/丢失时拒绝结果。
- 脱敏是有限规则，不能保证发现所有隐私类型；普通文本翻译本身会发送到所选供应商。OpenAI store:false 也不等于供应商绝不留存数据。
- Swift String/Data 复制无法保证内存清零；本轮未宣称硬件级秘密保护、TLS 固定证书或任意内存转储防护。

## OCR

Core 的 OCRService 接收图片 Data 与语言列表，返回文本行、置信度、Vision 归一化框（左下原点）。VisionOCRService 使用 accurate VNRecognizeTextRequest，保留图片 EXIF 方向，执行在非 UI 的 worker。输入有编码大小和像素数量限制；取消请求同步传给 VNRequest，返回前再次检查取消。语言支持、阅读顺序和漫画布局需要设备样本验收。

## 后续产品边界

统一下载任务与历史应为下载/转换/搜图提供共同身份、进度、取消、重试和持久化入口，后续再确定数据库与后台下载策略。X、Pixiv 原画/Ugoira、B 站、GIF、图片指纹、多图拼接、SauceNAO/搜图 Bot 酱均保留为独立服务模块的开发范围，本轮没有用空实现注册为“已支持”。

正式 SwiftUI App 后续对接这些服务；UI 目标为 iOS 原生结构 + 原创明快蓝白青风格（UIUX_SPEC.md），不影响后端模块边界。PoC 的按钮及预览只用于技术验收。
