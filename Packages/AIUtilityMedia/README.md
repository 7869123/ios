# AIUtilityMedia — download queue, site adapters, local tools and reverse search (P1–P4)

Current state (2026-11-14): P1–P4 are implemented and wired into the App. The queue, the Bilibili / X / Pixiv
adapters and both reverse-search providers are tested with offline samples only (shown as 未实测 in the App);
local tools run on device. The historical notes below describe earlier validation rounds.

Products: `AIUtilityMedia` (download queue, Linux-compatible) and `AIUtilityMediaApple`
(P2: `stitchImages`, `makeGIF(fromVideo:outputDirectory:options:)`, `rewriteFingerprint`; ImageIO / AVFoundation,
`unsupportedPlatform` elsewhere). See MEDIA_INTERFACES.md §9a for the P2 contract as implemented.

Current follow-up: source 1ac37c8 compiled on macOS and both unsigned iOS 26.5 SDK targets, but its Media tests
failed (9 passed / 33 failed) during sandbox initialization. The [failure evidence](../../validation/media-apple/attempt-1/README.md)
is preserved. Only Media path handling was corrected; all original tests remain, with 3 new regressions (45 total).
This fix compiled and passed all 45 tests on Linux in [42463047405](https://github.com/7869123/ios/actions/runs/42463047405)
(HEAD 334cfde, production fix 99b0d86). The [handoff](../../validation/media-apple/README.md) separates the two source versions.
The single approved Apple run is consumed; repaired macOS tests/iOS SDK compilation need another approval.

Independent Swift 6 package for iOS 17+, macOS 14+ and Linux pure logic. No external package dependencies.
Source 55be755 compiled on Swift 6.0.3/Linux and passed 42 offline tests in
[run 42453057517](https://github.com/7869123/ios/actions/runs/42453057517).
The [evidence report](../../validation/media-p1/README.md) preserves exit codes, counts and hashes.
The Linux result below applies to that earlier source, not the current fix. Real URLSession transfers and App integration remain unverified.

## App entry

```swift
let configuration = try DownloadConfiguration()
let downloads = try await DownloadManager(configuration: configuration)
let receipt = try await downloads.enqueue(link: url, selection: .automatic, options: SiteOptions())
let snapshots = await downloads.updates()
// Consume snapshots in the App's own task and return to MainActor to change UI state.
// Cancelling a subscription does not cancel a download.
```

Without `sites:` only direct HTTPS image/video/audio URLs are registered; the App also enables Bilibili, X and Pixiv. A successful HEAD with a supported MIME type is
required; HTML and unsupported sites fail explicitly. GET uses a real foreground URLSessionDownloadTask with cookies,
credentials and cache disabled. Redirects are followed manually under the same request budget. The final file's type
signature, actual length, size limit and MIME are checked before publication; this is not full decoder validation.
HEAD-unsupported servers, missing/unsupported MIME types, octet-stream guessing, background downloads and automatic
resume are not supported. The App asks iOS for the usual short background time while a download runs; leaving the
app for longer interrupts the transfer. No AI/SauceNAO credentials or paid API calls are used by the queue.

2026-11-14 behaviour changes: Retry-After is kept per origin (site, or host for direct links) and a wait past the task
deadline ends as `rateLimited`, not `timeout`; HTTP 412 is throttling and 500/502 are retryable network errors; an
oversized error body keeps its status classification; images with unknown size need 64 MiB free (not the 1 GiB file
cap); the 198.18.0.0/15 proxy fake-IP range and NAT64 addresses of public IPv4 hosts are accepted; Pixiv `/en/artworks/…`
and `member_illust.php?illust_id=…` links are recognised; control and zero-width characters are dropped from titles;
Bilibili also uses the player API's backup addresses and its Akamai mirrors; Bot 酱 results are sorted before the cut;
resolved titles are shown in snapshots for the current run only (`DownloadSnapshot.genericTitle` otherwise) and never
persisted; downloaded outputs are excluded from device backups (after a restore they are missing, not "changed").

The public `MediaSelection` and `SiteOptions` are independent. Only effective source/content options participate in
resolved deduplication. Unsupported Bilibili all-parts requests fail instead of falling back; this does not advertise
a Bilibili downloader. Site adapters (P3), Ugoira-to-GIF assembly and Apple processing (P2) and reverse search (P4) are implemented; DASH
audio/video muxing is not.
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
- After restart, every unfinished task (active or still pending) is `interrupted`, because its original runtime link
  is memory-only and nothing restored could run. Ordinals are kept. Re-enter the link (receipt `retryRequired`), then
  explicitly `retry` the returned ID; the App does both in one step. URLs cannot be reconstructed from digests. Settings changes do not mutate queued option snapshots.
- Publication journals intended outputs, renames a complete directory on the same filesystem, then commits metadata.
  Recovery removes uncommitted outputs. This is not a filesystem-wide atomic transaction or a power-loss durability claim.
- `clearHistory` drops terminal records/deduplication without deleting files. `clearHistory(keepingFiles: true)` keeps
  terminal rows that still own files (completed, deletion incomplete, a failed re-download with earlier outputs), so the UI never orphans downloads it can no longer list. Minimal UUID-to-relative-file ownership
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
Following those contracts alone is not runtime evidence; real HTTP/TLS/CDN transfers have not been tested.

## Offline tests and CI handoff

The original 42 plus 3 new path regressions all passed on Linux (45 passed, 0 skipped/failed); repaired macOS execution is pending. Fake transport,
clock, destination validation and fault injection live **only in the test target**. Production defaults use disk,
public DNS preflight and URLSession. Tests allocate unique temporary directories and do not contact real sites.

Local checks executed before the first real CI run (historical source delivery):

| Command/check | Actual result | What it does not prove |
|---|---|---|
| `scripts/prepush_check.sh origin/codex/poc-engineering-audit` (first pass) | Exit 1: fake Pixiv profile URL matched the user-path rule; replaced with a non-artwork ranking URL, retaining the route-boundary assertion | No real personal path was required; scanner rules were not weakened |
| Same command after the fixture correction | Exit 0, PRE-PUSH CHECK: PASS; 49 repository Swift files parsed; YAML/shell/resources/privacy/history checks passed | Grammar parsing is not Swift compilation |
| Python preflight scanner regression suite, run by that script | 13 passed, 0 failed | These are not the 42 media tests |
| Swift build/test at initial local delivery | NOT RUN locally; later CI passed all 42 media tests | Apple SDK and actual networking remain unverified |

Local logs are retained under the ignored `artifacts/integration/media-p1-prepush.log` and
`artifacts/integration/media-p1-prepush-final.log`. Later real CI evidence is preserved in validation/media-p1.

Executed on the authorized Linux runner (all exit codes 0):

```sh
swift --version
swift build --package-path Packages/AIUtilityMedia
swift test --package-path Packages/AIUtilityMedia
```

Keep Core and PoC regression commands unchanged. The user authorized only the Linux Media addition to core-linux;
workflow triggers and other jobs remain unchanged. Revalidation of the Darwin fix on macOS/iOS SDK requires fresh approval. Validation scope:

1. Linux `swift:6.0.3`: Media build/test commands above, added to core-linux with media-build.log/media-tests.log,
   separate media_build/media_tests exit codes and inclusion in the existing always-uploaded evidence artifact.
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

Linux source push/CI remains authorized. One build_apple dispatch was approved and executed (previews and PoC off),
preserving the existing workflow behavior; the current Darwin fix requires a separate Apple revalidation approval.
