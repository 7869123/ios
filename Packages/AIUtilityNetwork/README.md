# AIUtilityNetwork

网络测速（Cloudflare）与 IP / DNS / WebRTC 泄漏检测的底层，App 的「工具箱 → 网络」使用它。说明、规则与局限见仓库根目录的 [NETWORK_TOOLS.md](../../NETWORK_TOOLS.md)。

- 纯逻辑（统计、测速引擎、trace / Server-Timing / ip.sb / IPIP / DNS TXT / STUN / ICE 候选解析、泄漏规则）在 Linux 编译和测试：`swift test --package-path Packages/AIUtilityNetwork`。
- `CloudflareSpeedTransport`（URLSession 计时）、`STUNClient`（Network.framework UDP）、`DNSWhoami.query`（DNS-SD）、`TunnelState.current()`、`LeakCheckRunner` 只在 Apple 平台编译。
- `LiveNetworkChecks` 默认关闭，只在 `AIUTILITY_LIVE_TESTS=1`（手动 `live_checks`）时访问真实服务。
