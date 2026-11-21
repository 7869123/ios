# 网络工具：测速与泄漏检测

2026-11-21 新增。代码在 `Packages/AIUtilityNetwork`（纯逻辑在 Linux 编译和测试；URLSession 计时、UDP、DNS-SD 只在 Apple 平台），界面在 `Apps/AIUtility/Sources/NetworkToolViews.swift`，入口在「工具箱 → 网络」。两个功能都标「未实测」：没有在真机上跑过，联网格式检查（`live_checks`）也还没有跑。

两个功能都只在用户点「开始」后才联网，离开页面时自动停止。

## 1. 网络测速

### Cloudflare（已实现，未实测）

| 项目 | 做法 |
|---|---|
| 服务 | `speed.cloudflare.com`：`GET /__down?bytes=N` 下载、`POST /__up` 上传、`/cdn-cgi/trace` 取节点（colo）、出口 IP 和地区 |
| 空载延迟 | 20 次 `__down?bytes=0`，每次取「首字节时间 − 服务器处理时间」（响应头 `Server-Timing: cfRequestDuration;dur=…`），报告中位数 |
| 抖动 | 相邻两次延迟之差的平均值 |
| 下载 / 上传 | 请求大小逐级增大（下载 100 KB×10、1 MB×8、10 MB×6、25 MB×4、100 MB×3；上传 100 KB×8、1 MB×6、10 MB×4、25 MB×4、50 MB×3）；某一级里有请求超过 1 秒，就不再测更大的；只计时传输本身（URLSessionTaskMetrics，不含建连），短于 10 毫秒的请求不计入；结果取第 90 百分位 |
| 负载下的延迟 | 下载、上传进行时每 0.4 秒测一次延迟，分别报告中位数 |
| 流量上限 | 默认 300 MB，可选 100 MB / 1 GB；下一次请求会超过上限时停止该方向，结果注明 |
| 内存 | 响应体只计数不保存（100 MB 的下载不会进内存）；上传体为全零数据 |

这套步骤参考 Cloudflare 自己的测速引擎，但不是它的代码，数值可能和 speed.cloudflare.com 网页版有差别。

### 信通院（规划中，未接入）

信通院没有公开的测速接口，官方测速在「全球网测」「泰尔网测」App 里。所有者决定先抓包、再按实际请求接入。接入前界面上选「信通院」只显示「规划中」，不发出任何请求（`NetworkToolError.notConfigured` 预留）。

抓包时需要的信息：

1. 测速开始前获取服务器列表的请求：完整 URL、方法、请求头（去掉 Token、Cookie、设备号）、响应 JSON 的结构（可以把 IP、ID 换成假值）。
2. 延迟（ping）测试：用的是 HTTP、TCP 还是 ICMP；HTTP 的话给 URL。
3. 下载测试：URL 的样子（有没有大小参数）、并发连接数、单个文件多大。
4. 上传测试：URL、方法、Content-Type、单次上传多大。
5. 是否需要登录或签名参数（如 `sign=`、`token=`、时间戳），签名怎么生成（如果看得出来）。
6. App 若启用证书固定（Charles / Proxyman 显示握手失败），抓不到明文时告诉我，我们再换方式。

## 2. 泄漏检测（已实现，未实测）

一次检测同时做下面几件事，然后按规则给出结论：

| 检测 | 方法 | 联系的服务 |
|---|---|---|
| 网页出口（HTTPS） | 访问 Cloudflare trace（默认线路、强制 IPv4 的 `1.1.1.1`、强制 IPv6 的 `[2606:4700:4700::1111]`）、`api.ip.sb/geoip`、`myip.ipip.net`（国内网站视角，用来看分流） | Cloudflare、ip.sb、IPIP |
| UDP（STUN） | Network.framework 直接发 RFC 5389 Binding 请求，读 XOR-MAPPED-ADDRESS | `stun.cloudflare.com:3478`、`stun.l.google.com:19302` |
| 网页 WebRTC | 屏幕外的 WKWebView（临时数据存储，内联页面）建 RTCPeerConnection，收集 ICE 候选地址 | 同上两个 STUN 服务器 |
| DNS 解析器 | 通过系统解析器（DNS-SD）查 Akamai 诊断域名 `whoami.ds/ipv4/ipv6.akahelp.net` 的 TXT 记录，得到替你查询的解析器地址和转发的客户端网段（ECS） | Akamai |
| 地区 / 网络 | 上面查到的公网地址（最多 12 个）发给 `api.ip.sb/geoip/<ip>` 查国家和 ASN | ip.sb |
| VPN / 代理 | 系统代理设置里的 `__SCOPED__` 接口（utun、ipsec、ppp、tap、tun）和 HTTP 代理开关 | 不联网 |

结论规则（`LeakAnalysis`，Linux 有测试）：

- 只有开着 VPN / 代理时，不一致才算「可能泄漏」；没开时只作为信息显示。
- WebRTC / UDP：STUN 或 WebRTC 看到的公网地址，和同一地址族（IPv4 / IPv6 分开比）的网页出口不同 → 可能泄漏。网页 WebRTC 直接列出局域网地址（没有用 mDNS 隐藏）→ 信息。
- DNS：解析器所在国家不在网页出口的国家里 → 可能泄漏。没取到解析器时如实说明。
- IPv6：IPv6 出口和 IPv4 出口属于不同 ASN → IPv6 可能绕过 VPN / 代理。
- 分流：国内网站看到的地址和国外网站不同 → 信息（使用分流规则的代理通常如此）。

已知局限（真机测试时重点看）：

- VPN 识别依据系统网络设置；部分系统版本即使没开 VPN 也可能列出 utun 接口（会被误判为开着 VPN），App 内置代理或路由器上的代理看不到。
- 任播（anycast）解析器如 1.1.1.1、8.8.8.8 的地区查询结果可能和实际服务节点不一致，会导致 DNS 误报。
- WebRTC 候选地址收集最多等 6 秒；系统可能弹出「本地网络」权限（Info.plist 已有 `NSLocalNetworkUsageDescription` 说明），拒绝后通常只少了局域网地址。
- 结论只根据这几项观测推断，不能证明没有其他泄漏途径。

界面默认把 IP 显示成 `203.0.*.*` / `2001:db8:…`，打开「显示完整 IP」才显示全部，方便截图分享。

## 3. 测试与验证

| 层级 | 内容 | 状态 |
|---|---|---|
| Linux（core-linux） | 统计、测速引擎（假传输：逐级停止、流量上限、过短请求、进度、取消、错误分类）、trace / Server-Timing / ip.sb / IPIP / TXT 解析、STUN（RFC 5769 IPv4 / IPv6 向量）、ICE 候选、VPN 接口分类、泄漏规则 | 待 CI |
| macOS（apple） | 同上测试 + 模拟器 / 真机 SDK 编译 | 待 CI |
| 联网格式（`live_checks`） | `LiveNetworkChecks`：三条 trace、ip.sb、IPIP、1 MB 下载 / 100 KB 上传、两个 STUN、三条 DNS TXT；报告只写地址族和节点，不写地址 | 未跑 |
| 真机 | 见 DEVICE_TEST_CHECKLIST.md 第 11A、11B 节 | 未验证 |
