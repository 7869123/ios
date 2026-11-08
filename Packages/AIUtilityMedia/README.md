# AIUtilityMedia — P1 source delivery, compilation pending

Independent Swift 6 package for iOS 17+, macOS 14+ and Linux pure logic. No external package dependencies.
This source delivery has **not** been compiled or functionally tested. Test declarations are not test results.

## App entry

```swift
let configuration = try DownloadConfiguration()
let downloads = try await DownloadManager(configuration: configuration)
let receipt = try await downloads.enqueue(link: url, selection: .automatic, options: SiteOptions())
let snapshots = await downloads.updates()
// Consume snapshots in the App's own task and return to MainActor to change UI state.
// Cancelling a subscription does not cancel a download.
```

Only direct HTTPS image/video/audio URLs are registered by default. A successful HEAD with a supported MIME type is
required; HTML and unsupported sites fail explicitly. GET uses a real foreground URLSessionDownloadTask with cookies,
credentials and cache disabled. Redirects are followed manually under the same request budget. The final file's type
signature, actual length, size limit and MIME are checked before publication; this is not full decoder validation.
HEAD-unsupported servers, missing/unsupported MIME types, octet-stream guessing, background downloads and automatic
resume are not supported in P1. No AI/SauceNAO credentials or paid API calls are used.

The public `MediaSelection` and `SiteOptions` are independent. Only effective source/content options participate in
resolved deduplication. Unsupported Bilibili all-parts requests fail instead of falling back; this does not advertise
a Bilibili downloader. Three site adapters, GIF/Ugoira/DASH assembly, Apple processing and reverse search remain P2–P4.
There is no empty Apple target or simulated production success.

## Ownership and recovery

- One manager owns each dedicated storage namespace. All parsing, HEADs, downloads, cooldowns and automatic retries
  occupy the same FIFO slot. A conservative global cooldown supplements source/host cooldowns across signed CDN hops.
- `cancel` publishes cancellation immediately. The next task waits for the old transfer's completion acknowledgement
  and staging cleanup. Cleanup failure blocks the queue until `retryCleanup`; generation checks reject old progress.
- Each retry starts from byte zero with a new attempt ID. Progress is monotonic within an attempt/phase. No Range,
  If-Range, opaque resumeData or old `.part` concatenation is used. P1b requires separate review.
- An atomic, versioned JSON manifest contains the queue, safe identity digests, options, history and minimal file
  ownership. Original URLs, titles, signed requests, response bodies and credentials are never written to it.
  Original runtime input and signed component requests remain memory-only. History uses a generic display title.
- After restart, active work is `interrupted`. Pending order is preserved, but a task without its original runtime
  link also becomes `interrupted` when selected. Re-enter the link, then explicitly `retry` the returned ID. URLs
  cannot be reconstructed from digests. Settings changes do not mutate queued option snapshots.
- Publication journals intended outputs, renames a complete directory on the same filesystem, then commits metadata.
  Recovery removes uncommitted outputs. This is not a filesystem-wide atomic transaction or a power-loss durability claim.
- `clearHistory` drops terminal records/deduplication without deleting files. Minimal UUID-to-relative-file ownership
  remains so `deleteFiles` can remove old files without recreating history. Partial deletion returns each failure,
  removes deduplication and keeps remaining outputs deletable. The caller can compose bulk deletion.
- File lookup/deletion checks ownership, UUID-only relative paths, symlinks, regular-file type, size and (for actual
  downloads) inode identity. A retry of a missing completed output keeps other old owned files in the same task's
  deletion inventory; a later `deleteFiles` removes that inventory too.
- DNS/IP preflight rejects explicit local/private destinations and checks every redirect. URLSession resolves again,
  so **DNS rebinding/TOCTOU is not fully prevented**. OS DNS lookup and synchronous filesystem calls cannot be forcibly
  interrupted; cancellation still holds the slot until they return. No claim of a hardened untrusted-server proxy is made.

Network lifecycle implementation references: [Swift Foundation URLSession delegate contracts](https://github.com/swiftlang/swift-corelibs-foundation/blob/main/Sources/FoundationNetworking/URLSession/URLSessionDelegate.swift),
[Apple download completion documentation](https://developer.apple.com/documentation/foundation/urlsessiondownloaddelegate/urlsession(_:downloadtask:didfinishdownloadingto:)).
Following those contracts is not evidence that this package compiled or passed runtime tests.

## Offline tests and CI handoff

42 Swift Testing cases are authored in `Tests/AIUtilityMediaTests`; none have been executed yet. Fake transport,
clock, destination validation and fault injection live **only in the test target**. Production defaults use disk,
public DNS preflight and URLSession. Tests allocate unique temporary directories and do not contact real sites.

After user approval, use a Swift 6 compiler:

```sh
swift --version
swift build --package-path Packages/AIUtilityMedia
swift test --package-path Packages/AIUtilityMedia
```

Keep Core and PoC regression jobs unchanged. Claude owns workflow changes. Proposed evidence-preserving additions:

1. Linux `swift:6.0.3`: Media build/test commands above, alongside existing Core commands.
2. macOS: same Media build/test commands; record compiler version and each exit code.
3. iOS SDK, from the package directory:

   ```sh
   xcodebuild -scheme AIUtilityMedia -destination 'generic/platform=iOS Simulator' \
     -derivedDataPath ../../artifacts/media-simulator CODE_SIGNING_ALLOWED=NO build
   xcodebuild -scheme AIUtilityMedia -destination 'generic/platform=iOS' \
     -derivedDataPath ../../artifacts/media-device CODE_SIGNING_ALLOWED=NO build
   ```

   The generated Swift Package scheme and commands must be confirmed on the actual runner. These are not executed results.
4. Preserve version/build/test logs and exit-code files with `if: always()`; do not upload tokens, caches or whole homes.
   Record actual discovered/pass/fail/skip counts. Do not suppress failures, remove tests or replace this with grammar parsing.

No existing workflow includes this package yet. User permission is required **before** any Actions run; a source push
to the current PR branch automatically triggers existing Linux CI, so this batch must remain local until authorized.
