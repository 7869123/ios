# 独立工程审查验证证据

交付记录：2026-11-08。实际 CI 执行日期：2026-11-07。

- 验证源码：`680f3d2af9f056811b05e4db74d0492f9dd1d1d6`。
- [完整运行 42378051064](https://github.com/7869123/ios/actions/runs/42378051064)：completed / success。
- 手动输入：build_apple=true、build_poc=true、publish_previews=false。
- [机器摘要](summary.json)：真实 API job/step 状态、退出码、逐项测试计数、artifact ID/到期日、源码树与日志摘要。
- 交付文档提交在上述源码之后，不冒充新的编译结果；核对摘要中的 source_tree_or_blob 即可检查代码是否改变。

## 实际结果

| Job | ID | 结果 |
|---|---|---|
| core-linux | 128419652484 | success；Core 36 通过/1 跳过；PoC 生命周期 14 通过 |
| apple | 128419871613 | success；Core 36 通过/1 跳过；Vision 2 通过/Keychain 1 跳过；两种 SDK 构建通过 |
| poc-sdk | 128419871717 | success；macOS 生命周期 14 通过；Swift 6 Simulator/iphoneos Archive 通过；13 项预安装检查通过 |
| app | 128420238618 | success；XcodeGen、Simulator/iphoneos 构建通过；截图步骤 success，无完整交互验收 |

Core 各发现 37 个测试函数，实际 36 通过、1 live API 跳过。Swift Testing 的聚合“37 passed”含禁用项，
不应当作 37 个实际执行函数；XCTest 兼容层的 0 tests 也不是 Swift Testing 的结果。
两平台的生命周期各执行 14 个测试，未跳过；AppleServices 的 Keychain 运行时测试默认禁用。
参数化测试的参数执行不另列为新测试函数。没有新增付费 API 调用。

14 项生命周期回归覆盖：重复开始、停止期间禁止重启、并发 stop 共用释放、停止调用方取消、
迟到失败/统计/picker 回调失效、旧停止不能清理新会话，以及释放失败禁止开始、显式停止重试、并发失败不隐式重试。
这些执行的是生产 PoC 使用的共用状态机；没有用模拟缓冲或文本冒充系统采集、Speech 或 PiP 成功。

## 命令、退出码与环境

Linux Swift 6.0.3 实际执行：

```sh
swift --version
swift build --package-path Packages/AIUtilityCore
swift test --package-path Packages/AIUtilityCore
swift test --package-path PoCs/iOS27Capture
```

四个退出码均为 0，见 [core-linux](final/core-linux/exit-codes.txt)。

普通 Apple/App：macOS 26.7.2、Xcode 26.6、Swift 6.3.3、iOS SDK 26.5：

```sh
bash scripts/ci_apple.sh
bash scripts/ci_app.sh
```

Apple 的 environment/mac-core-tests/mac-services-tests/ios-simulator-build/ios-device-build 均为 0，
见 [apple](final/apple/exit-codes.txt)；App 的 environment/generate/simulator-build/device-build 均为 0，
见 [app](final/app/exit-codes.txt)。两个脚本的完整实际参数在脚本和日志中保留。

PoC：macOS 27.0.1、arm64、Xcode 27.1 (27A9275)、iphoneos/iphonesimulator 27.1。
Mac 上的 `swift test --package-path PoCs/iOS27Capture` 仅运行可移植状态机。
工程生成与构建实际命令（工作目录 PoCs/iOS27Capture）：

```sh
xcodegen generate --spec project.yml
xcodebuild -project AIUtilityCaptureProbe.xcodeproj -scheme AIUtilityCaptureProbe \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath ../../artifacts/poc-build CODE_SIGNING_ALLOWED=NO build
xcodebuild archive -project AIUtilityCaptureProbe.xcodeproj -scheme AIUtilityCaptureProbe \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -archivePath ../../artifacts/poc-archive/AIUtilityCaptureProbe.xcarchive \
  -derivedDataPath ../../artifacts/poc-archive-build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  STRIP_INSTALLED_PRODUCT=NO COPY_PHASE_STRIP=NO
```

测试/生成/模拟器/Archive 四个退出码均为 0，见 [poc](final/poc/exit-codes.txt)。打包和预安装 shell 步骤 success（退出 0），
原始 job step 状态在 summary.json；没有为失败/取消或尚未开始的命令编造退出码。
Archive 实际包含 `-swift-version 6`，无 ConformanceIsolation / SendingRisksDataRace 诊断；弃用警告仍保留。

Simulator SDK 不提供 ScreenCaptureKit，Host 在该环境明确显示占位信息。只有 iphoneos Archive、
框架链接及真实类符号检查能说明采集代码未剔除；这些依然不是系统权限或跨 App 能力的验证。

## IPA 与检查

[下载未签名 IPA artifact](https://github.com/7869123/ios/actions/runs/42378051064/artifacts/13576218828)
（保留至 2026-11-14；到期后按原源码重新生成）。实际 IPA SHA-256：

`88d7cd6035b1e9f4d937ed49450e2dba1aa38778d6c608144ebe6c265c1ff440`

[预安装日志](final/poc/preinstall-audit.log) 13/13 PASS：Bundle ID、MinimumOSVersion、两项隐私说明、
audio/screen-capture 后台模式、三个框架、两个真实类符号、未使用麦克风权限及未签名检查。
诊断 Release 保留本地符号以供核验；保留 Release 优化，不上传 dSYM 或构建缓存。
原始签名、plist、框架与符号输出在 final/poc。没有 embedded.mobileprovision，不是可直接安装的发行包。

## 失败与取消记录

- 42375947069 / 857d150：macOS 默认最低版本 12 与 Core 13 冲突；测试退出 1，未开始 iOS 构建。
- 42376094393 / a0fd2c7：生命周期和模拟器通过；iphoneos Archive 退出 65，SCStream 跨 actor 传递错误。
- 42376481364 / 518dc35：Archive 退出 0；新增符号检查因默认符号剥离失败，预安装步骤退出 1。
- 42376873996 / d05afad：四 job 通过、12 项生命周期通过；随后补充停止异常处理，没有将此结果沿用于最终源码。
- 已被新提交取代的运行如 42376436194、42377987380 等保留为 cancelled，不能当作编译失败或通过。

上述实际下载的 PoC 日志保存在 attempts/。历史 job 快照使用此前真实 API 读取记录，最终 run/job 已重新获取；
未获取到的取消任务退出码保持未知。日志统一行尾、去除行末空白，summary.json 同时保存原始和归档字节的 SHA-256，
不把规范化后的文件冒充字节完全相同的原件。IPA/ZIP、证书、缓存均未入 Git。

## 范围限制与交接

实际集成基线为 Claude d7859b0；交付前重新获取到的 Claude HEAD 为 6b335ab，后续 UI/预览提交未被覆盖。
本 PR 三点差异不含 Apps、Core、UIUX_SPEC 或截图脚本修改；预合并树检查退出 0。合入最新 UI 后仍需复验 App，
本次不声称已测试该组合。main 保持 f17d20d，不自动合并任何 PR，不 force push。

Windows 只执行源码卫生/plist、YAML、diff 和敏感模式检查；未安装 Swift，未使用 tree-sitter 替代编译。
完整 Bash 预推送脚本未在本机执行；真实构建和测试全部来自 Actions。

仍未执行：真实三家 API、Keychain 运行时、iOS 实际截图 OCR、签名安装、iPad 的系统采集/Speech/PiP/中断与资源释放测试。
当前普通 Apple ID、无法首次 USB 配对，无法开始安装。具备签名和设备条件后，可进行首次受控 PoC 实验，
依次记录选择器、非 DRM 来源的非静音 RMS/已知语句、PiP 可见性和后台持续性；不可作为产品功能验收。
