# 网络工具：测速与泄漏检测

2026-11-21 新增（信通院测速同日接入）。代码在 `Packages/AIUtilityNetwork`（纯逻辑在 Linux 编译和测试；URLSession 计时、UDP、DNS-SD 只在 Apple 平台），界面在 `Apps/AIUtility/Sources/NetworkToolViews.swift`，入口在「工具箱 → 网络」。两个功能都标「未实测」：没有在真机上跑过。联网格式检查（`live_checks`）已在 CI 通过，只说明各服务的接口格式没变（见第 3 节）。

两个功能都只在用户点「开始」后才联网，离开页面时自动停止。

## 1. 网络测速

### Cloudflare（已实现，未实测）

| 项目 | 做法 |
|---|---|
| 服务 | `speed.cloudflare.com`：`GET /__down?bytes=N` 下载、`POST /__up` 上传、`/cdn-cgi/trace` 取节点（colo）、出口 IP 和地区 |
| 空载延迟 | 20 次 `__down?bytes=0`，每次取「首字节时间 − 服务器处理时间」（响应头 `Server-Timing: cfRequestDuration;dur=…`），报告中位数 |
| 抖动 | 相邻两次延迟之差的平均值 |
| 下载 / 上传 | 请求大小逐级增大（下载 100 KB×10、1 MB×8、10 MB×6、25 MB×4、100 MB×3；上传 100 KB×8、1 MB×6、10 MB×4、25 MB×4、50 MB×3）；某一级里有请求超过 1 秒，就不再测更大的；只计时传输本身（URLSessionTaskMetrics，不含建连；上传取「发出请求到收到响应头的时间 − 服务器处理时间 − 最短空载往返」，与「本机写完请求体」二者中较长的一个：后者只表示交给了发送缓冲区，联网检查里 100 KB 不到 1 毫秒，而 Cloudflare 对上传给的服务器计时接近 0），短于 10 毫秒的请求不计入；结果取第 90 百分位 |
| 负载下的延迟 | 下载、上传进行时每 0.4 秒测一次延迟，分别报告中位数 |
| 流量上限 | 默认 300 MB，可选 100 MB / 1 GB；下一次请求会超过上限时停止该方向，结果注明 |
| 内存 | 响应体只计数不保存（100 MB 的下载不会进内存）；上传体为全零数据 |

这套步骤参考 Cloudflare 自己的测速引擎，但不是它的代码，数值可能和 speed.cloudflare.com 网页版有差别。

### 信通院（已接入，未实测；非官方接口）

2026-11-21 按所有者整理的接口说明接入。来源：两份开源还原实现（MiaM1ku/taierspeedtest、Canary233/luci-app-cnspeedtest），所有者用自建客户端逐条请求真实服务器核对过；**没有对官方 App 抓包**。接口没有文档和兼容承诺，随时可能变。

| 步骤 | 做法 | 依据 |
|---|---|---|
| 出口定位 | `GET https://dlcv2.cnspeedtest.cn:8443/dataServer/getIpLocSP.php`，返回 `IP\|["中国","省","市","","运营商"]\|…`；失败时依次试 `dlc.duoweisoft.com:8096`、`dlcv2.duoweisoft.com:8088`（明文 HTTP） | 实测 |
| 节点表 | `GET …/dataServer/mobilematch_many.php?ip=…&network=4&province=…&city=…&wifioper=…&mobileoperid=…&ipv6=0&model=Android&pkg=com.cnspeedtest.globalspeed`，JSON 数组（`hostip`、`port` 为字符串） | 实测 |
| 选节点 | 对每个节点做一次 TCP 握手，按快慢排序，依次申请会话（最多 4 个）；`-1-` 先当作坏节点、换下一个 | 实测（有节点恒返回 `-1-`） |
| 会话 | `GET http://节点:端口/speed/dovalid?key=&flag=true&bandwidth=200&model=Android&imei=…&time=…&app=globalspeed&token=…&pkg=…`，返回 `1-<uuid>`；签名 `md5(md5("model=Android&imei=" + imei) + md5("stime=" + time + "&band=200&rand=12345555"))`；时间取 `dlc.duoweisoft.com:8096/dataServer/time.php`，取不到用本机时间 | 实测 |
| 设备号 | 每次测速随机生成 15 位数字（`35` 开头、Luhn 校验位），不发送本机任何标识 | 服务端只校验格式 |
| 延迟 | 到节点端口的 TCP 握手时间，8 次取中位数；抖动同 Cloudflare 的算法 | **推断**（没有协议依据） |
| 下载 | 8 条连接各发 `GET /speed/File(1G).dl?r=<unix 秒>&key=<uuid>`，节点发完 1 GB 断开就重连；约 10 秒 | URL 实测；并发数**推断** |
| 上传 | 4 条连接各发 `POST /speed/doAnalsLoad.do`（`Key` 头带 uuid，multipart 固定 boundary `00content0boundary00`，声明 `Content-Length: 900000000`），然后持续发送随机数据；约 8 秒 | **部分实测**：跑通，但整理时只测到很低的上传值，可能偏低 |
| 结果 | 每 0.5 秒取一次区间速度，去掉前 2 秒预热后取平均；另给出峰值区间 | — |
| 释放 | `POST http://节点:端口/speed/dovalid?key=<uuid>`；拿到会话后无论成功、失败还是点「停止」都会释放 | 实测 |

实现要点：

- 节点是 IP 地址加端口的明文 HTTP，URLSession（App Transport Security）会拦截，所以数据面用 Network.framework 的 TCP 连接手写 HTTP（`NetworkCAICTTransport`、`HTTPWire`），不需要在 Info.plist 放宽 ATS。HTTPS 控制服务器仍用 URLSession。
- 请求头按接口要求以官方安卓客户端的身份发出（`User-Agent`、`pkg`）。
- 流量上限对两边都生效：下载最多用上限的 75%，上传用剩下的；达到就提前结束并在结果里注明。
- 同一出口 IP 要跑完整个会话：测速中切换网络或代理出口会让节点返回 403。
- `dovalid` 有频率限制：App 内两次信通院测速至少间隔 30 秒。
- MD5 用纯 Swift 实现（Linux 没有 CryptoKit），用 RFC 1321 向量和 Python `hashlib` 交叉核对；签名向量也来自 `hashlib`。
- 连续 3 次连接失败的线程不再重连，避免对拒绝的节点反复请求。

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
| Linux（core-linux） | 统计、测速引擎（假传输：逐级停止、流量上限、过短请求、进度、取消、错误分类）、trace / Server-Timing / ip.sb / IPIP / TXT 解析、STUN（RFC 5769 IPv4 / IPv6 向量）、ICE 候选、VPN 接口分类、泄漏规则；信通院：MD5、签名、设备号、定位 / 节点表 / 会话回复解析、请求报文、HTTP 报文解析（含 chunked），以及假节点上的完整流程（选第一个能给会话的最快节点、正常结束 / 流量上限 / 停止都释放 key、没有可用节点） | 通过（58 项，[Actions 44914960833](https://github.com/7869123/ios/actions/runs/44914960833)） |
| macOS（apple） | 同上测试 + 模拟器 / 真机 SDK 编译 | 通过（同一次运行） |
| 联网格式（`live_checks`） | `LiveNetworkChecks`：三条 trace、ip.sb、IPIP、1 MB 下载 / 100 KB 上传、两个 STUN、三条 DNS TXT、信通院出口定位与节点列表（CI 机房在国外，节点表可能为空）；报告只写地址族和数量，不写地址 | 通过（同一次运行；IPv6 在 CI 机房不可用，属预期；信通院节点表返回 1 个节点） |
| 真机 | 见 DEVICE_TEST_CHECKLIST.md 第 11A、11B 节 | 未验证 |
