# 在 iOS 16 上构建 Fish Pocket

上游是 iOS 17 起的工程（`app/project.yml` 的 `deploymentTarget`、README 的"需要 iOS 17 或更高版本"）。
这个分支把部署目标降到 **iOS 16.1**，让停在 iOS 16.x 的设备（iPhone 8 / 8 Plus / X 等）也能装。

构建产物是**未签名 ipa**，通过 GitHub Actions 的 macOS runner 出包，不需要 Apple 开发者账号。

## 为什么是 16.1，不是 16.0

灵动岛和锁屏 Live Activity 用的 **ActivityKit 从 iOS 16.1 才有**，widget 扩展（`DshLiveActivity`）整个就是 Live Activity，
部署目标设 16.0 会直接编译不过。能装 16.0 的设备都能升到 16.1，实际上损失的用户是零：iPhone 8 / X 这一代最终版本是 16.7.x。

## 改了什么

`@Observable`（Observation 框架）是 iOS 17 的核心。它在 iOS 16 上不存在，且 SwiftUI 对它的自动观察也依赖 iOS 17 的运行时，
只能整体换回 `ObservableObject` + `@Published`（SwiftUI 从 iOS 13 起就有的机制）。

| 改动 | 处数 | 说明 |
|---|---|---|
| `@Observable` 类 → `ObservableObject` | 40 个类 | 含 `AppModel`、`SessionModel`、`RemoteStore` 等核心模型 |
| 存储属性加 `@Published` | 286 个 | `let`、`@ObservationIgnored`、`lazy`、`weak` 属性按原语义跳过 |
| `@Environment(X.self)` → `@EnvironmentObject` | 186 处 | 184 处 `AppModel`、2 处 `WatchModel` |
| `.environment(app)` → `.environmentObject(app)` | 6 处 | 注入点（含 `ImageRenderer` 里的一个） |
| `@State` 持有模型 → `@StateObject` | 15 处 | 只改引用这 40 个模型的，值类型保持 `@State` |
| `@Bindable` → `@ObservedObject` | 6 处 | `$model.property` 绑定语义不变 |
| `withObservationTracking` → Combine 订阅 | 5 处 | Live Activity / Watch / Widget / 分享面板 / 远程提醒的派生快照 |
| `ContentUnavailableView` → `CompatContentUnavailableView` | 40 处 | 见 `Shared/Compat.swift` |
| 双参数 `onChange` → `onChangeCompat` | 87 处 | 只有读旧值的调用点需要改，单参/零参走系统 API |
| `onGeometryChange` → `onGeometryChangeCompat` | 27 处 | iOS 18 API，用 `GeometryReader` + `PreferenceKey` 重建 |
| `Animation.snappy` / `.smooth` → 兼容版本 | 58 处 | iOS 17；之前用等时长 spring / easeInOut 代替 |
| `.topBarTrailing` / `.topBarLeading` → `.navigationBarTrailing` / `.navigationBarLeading` | 30 处 | iOS 17 的 `ToolbarItemPlacement` |
| `scrollBounceBehavior` / `presentationBackground` / `presentationCornerRadius` / `presentationBackgroundInteraction` | 8 + 8 处 | iOS 16.4 API，16.0–16.3 上退化为默认行为 |
| `defaultScrollAnchor` | 7 处 | iOS 17；16.4 以下无锚点，`ConversationView` 自己滚到底 |
| `symbolEffect` / `phaseAnimator` / `toolbar(removing:)` / `scrollClipDisabled` / `scrollIndicatorsFlash` / `contentShape(.hoverEffect)` | 各 1–2 处 | 纯视觉或辅助，逐处用 `#available` 或 no-op 兜底 |

已经在 `#available(iOS 26.0, *)` / `#available(iOS 18.0, *)` 里写好的部分（AlarmKit、`glassEffect`、`safeAreaBar`、
`onScrollGeometryChange`、`WorkbenchBeside` 的 inspector）**没有动**：它们在 iOS 16 上本来就走 else 分支。

新增文件：

- `app/Shared/Compat.swift`：iOS 16 的兼容层（`ContentUnavailableView`、`onChange`、`onGeometryChange`、动画、sheet 修饰符）。
- `app/DshIOS/ModelChangePublisher.swift`：把 `AppModel` 及其嵌套模型的 `objectWillChange` 合成一条，供派生快照订阅。
- `.github/workflows/unsigned-ipa.yml`：出未签名 ipa 的工作流。

## 和上游的行为差异

这些是 iOS 16 拿不到的语义，不是 bug，但要知道：

1. **打开长会话可能从顶部开始**：`defaultScrollAnchor` 是 iOS 17 的，iOS 16 上由 `ConversationView` 自己 `scrollTo` 到底，
   首帧偶尔会先闪一下顶部。
2. **滚动跟随只在 iOS 18+ 生效**：`BottomFollow` 原本就依赖 `onScrollGeometryChange`，上游在 iOS 17 上也是这个行为（代码里的注释写着）。
3. **嵌套模型的刷新粒度变粗**：`@Observable` 会追踪到"读了哪个属性"，`ObservableObject` 只到"这个对象变了"。
   Live Activity / 小组件 / 手表快照现在订阅 `AppModel` + `account` + `fishPocket` + `cordis` + `remote` 五条，
   重算更频繁但结果一致（各自 `apply` 里有去重）。
4. **动画细节**：`symbolEffect`、`phaseAnimator`、`snappy` 在 iOS 16 上是等效替代，观感略有差别。
5. **`@Published` 不覆盖嵌套集合的元素**：例如 `BrowserModel.tabs` 里某个 `Tab` 自己的 `@Published` 变化不会让父视图重绘，
   读那个 `Tab` 的视图要自己 `@ObservedObject`。项目里浏览器页签是这样做的。

## 出包：GitHub Actions

`.github/workflows/unsigned-ipa.yml` 触发方式：手动 `Run workflow`，或推送到 `ios16-support` 分支。

它做的事和 Xcode Cloud 一样（直接复用仓库自己的 `app/ci_scripts/ci_post_clone.sh`：装 xcodegen / cmake / Node 24，
下载 nodejs-mobile、Python、FFmpeg，编译 libgit2，组装引擎，生成工程），然后：

```bash
xcodebuild -project DshIOS.xcodeproj -scheme DshIOS \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$RUNNER_TEMP/DshIOS.xcarchive" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  archive
```

再把 `DshIOS.app` 装进 `Payload/` 打成 ipa，作为 artifact 上传，保留 7 天。

**Xcode 版本**：工作流优先选 `Xcode_26*`，没有才用最新的。这套代码调用 AlarmKit、`glassEffect`、`safeAreaBar`，
必须有 iOS 26 SDK（Xcode 26+）才编得过；但 Xcode 27 的最低支持部署目标可能已经是 iOS 17，届时会把 16.1 目标当成非法。
两个条件同时满足的是 **Xcode 26.x**，所以优先固定它。

## 安装（未签名 ipa）

- **TrollStore**（iOS 14.0–16.6.1 / 17.0，永久签名，最适合这条路）：把 ipa 传到手机，用 TrollStore 打开安装。
- **Sideloadly / AltStore / 爱思助手**：需要你自己的 Apple ID 重签。注意本 App 带 HealthKit、HomeKit、
  Sign in with Apple 和 App Group 的 entitlement，免费个人证书不支持这几项，重签时要在工具里去掉对应 entitlement，
  否则签名会失败或装上打不开（去掉后对应的"本机能力"不可用，其余功能正常）。

## 没验证的部分

这台构建机是 Linux，没有 Xcode，**以下都只能到 macOS 上第一次编译才知道**：

- 全量类型检查。这里做过的验证是：AST 语法解析与改前逐文件对比，新增语法错误 0；`@Observable` / `import Observation`
  残留 0；未加 `@Published` 的存储属性逐个核对过，只剩 1 个纯内部标志（`NodeEngine.started`）。
- `NodeMobile.xcframework`（nodejs-mobile 24.20.0-0）的最低 iOS 版本。Python 3.15.2 已确认是 13.0，Node 这个包没查到。
  若它的 `MinimumOSVersion` 高于 16.1，链接会警告、运行会 dyld 失败，届时只能用更低的 nodejs-mobile 版本。
- watchOS 10 的 `DshWatch` 嵌在 iOS 16.1 的宿主里，Xcode 是否拒绝归档。若报错，把 `project.yml` 里 `DshIOS` 的
  `- target: DshWatch` 依赖和 `DshWatch` 整个 target 删掉即可，iOS 16 设备本来也装不了 watchOS 10 的手表 App。
- `SwiftTerm 1.10.0` 的 `platforms` 声明（仓库打不开，未取到）。若它要求 iOS 17，SwiftPM 会直接报错。
