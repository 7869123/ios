# 媒体工具变更通知：P1 Linux 验证批次

用户已批准 28c449d 接口并授权 P1；随后明确授权仅在 swift.yml 的 core-linux job
新增 AIUtilityMedia build/test，沿用现有日志、退出码、artifact 写法及失败门槛。
不修改 workflow 触发条件或其他 job；本轮不运行 macOS。

## 工具变化

- 新增独立 AIUtilityMedia Swift 6 包：真实 HTTPS 直链下载、自动路由、全局 FIFO 单任务、
  取消/从头重试、请求预算/限流、选项规范化/去重、持久化历史、文件删除及部分失败结果。
- 新增 MediaSelection + SiteOptions，两个 enqueue 重载；核心 AI 配置及 Core/AppleServices 公共 API 不变。
- 新增 42 项离线 Swift Testing 用例；普通测试只注入测试传输，不访问真实站点或付费 API。
- 生产仅注册直链；B站、X、Pixiv、Ugoira/GIF、图片处理、SauceNAO/搜图 Bot 酱均保留后续范围，
  未接入 App、未标为可用；断点续传仍属单独审核的 P1b。
- 不修改 Claude 的界面、壁纸、布局、资源及任何 iOS 27 PoC 源码。

## 本次 CI 变化

在 core-linux 原有命令之后追加：

```sh
swift build --package-path Packages/AIUtilityMedia
swift test --package-path Packages/AIUtilityMedia
```

输出 media-build.log、media-tests.log；exit-codes.txt 增加 media_build/media_tests。
两者退出码必须为 0，失败仍保留同一 artifact 中的全部日志；不上传缓存或凭据。
原有 Core 和生命周期测试继续执行。未改变 Linux 容器版本、超时、权限或任何触发条件。

首次源码推送时尚无新包 CI 结论；现已取得真实结果，见下节及 STATUS.md。
Linux 通过也不代表 Apple SDK 编译、App 接线或 iPad 真机功能已验证。

## 首次真实 Linux CI 已通过

源码 55be755，[42453057517](https://github.com/7869123/ios/actions/runs/42453057517) success：
Media 42 通过/0 跳过/0 失败，Core 36 通过/1 live API 跳过，生命周期 14 通过；六个命令退出码全为 0。
Apple/App/PoC SDK job 按原条件跳过；未运行 macOS。没有编译/测试失败，也没有删减媒体测试。
[证据和校验摘要](validation/media-p1/README.md)；本次追加仅更新文档/证据，Swift 源码不变。
