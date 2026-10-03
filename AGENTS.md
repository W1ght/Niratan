# Niratan Mac Agent 指南

Niratan 是只面向 macOS 26+ 的原生语言学习 App。仓库只有一个全功能 `Niratan` target / scheme，始终同时包含小说、视频和漫画模块。

`AGENTS.md` 只保存每个任务都必须知道的产品边界、仓库特有陷阱和上下文入口。任务状态、专项操作手册、验证矩阵和调查记录放到对应 skill 或真源文档。

## 常驻边界

- Mac 用户可见行为是第一真源；iOS、Android 和上游实现只能作为参考。
- 只开发和发布原生 macOS App；不得恢复 Light、独立 Video build variant、`HOSHI_VIDEO`、非 macOS target 或跨平台桥接层。
- 优先沿用附近代码、现有 SwiftUI 页面和业务边界；AppKit 只用于窗口、菜单、输入、文件选择等必要的窄边界。
- 新增或重构 UI 时，优先使用 macOS 26 原生控件和仓库现有 Liquid Glass 组件；不得新增 SwiftUI `Material` 背景、旧式自绘 chrome 或旧系统 fallback。不要仅为统一风格改写任务范围外的稳定页面。
- 保护用户媒体、sidecar、catalog、阅读进度、Profile、词典、Anki 配置、UserDefaults、token 和 Keychain 凭据；不得用清理数据、索引或凭据掩盖 bug。迁移和 cache invalidation 必须显式、兼容且范围可证。
- 本地漫画和视频库是非破坏性索引；书架整理、刷新、移除和验证不得移动、重命名、改写或删除用户源文件。
- 保留当前工作树中与任务无关的改动。未经用户明确要求，不 commit、push、打 tag 或 release。
- 新增用户可见文案必须进入 `Localizable.xcstrings`，至少保证中文和英文正确。

## 架构不变量

- `NativeMac/` 管 App shell、窗口呈现和窄 AppKit bridge；共享业务逻辑留在 `Core/`、`Features/`、`Models/` 等现有边界。
- Reader、Video、Manga 是同一 App 内的模块边界，不是独立产物。共享查词、Popup、词典音频、快捷键和 Anki 流程不得反向依赖具体内容来源。
- Video UI 通过 `PlaybackEngine` 操作播放状态；普通 SwiftUI 层不得直接调用 mpv C API。标准构建必须保留 universal libmpv 和 YouTubeKit 资源。
- Manga 本地与远程内容统一适配到 `MangaReadingSession` / `MangaPageContentProvider`。远程来源仅允许连接用户自行管理的 Suwayomi，或在 App 内受限执行已验证的 Aidoku `.aix` WASM；Aidoku 不得获得文件系统、任意原生 API 或其他 App 数据权限，秘密只存独立 Keychain service。不得恢复 Shinsou、Java/Mihon APK、官方 `AidokuRunner`、JIT、XPC/helper 或第二套阅读器。
- Profile 相关操作必须携带解析后的显式 `profileID`，不得依赖其他窗口最后切换的隐式全局状态。
- `WordAudioPlayer` 和本地 audio 数据库只负责词典词语发音；Sasayaki 是整本有声书播放，两者不得互相 fallback。

## 仓库特有陷阱

- UI 验证只操作本次构建输出的绝对 `.app` / executable path。`moe.shishamo.hoshi` 是身份断言，不是新旧构建选择器；进程名、窗口标题和 `/Applications/Niratan.app` 都不足以证明运行了本次产物。
- 并行验证使用不同 `./script/build_and_run.sh --instance <id>` 或 DerivedData 路径；这不会隔离 UserDefaults、Application Support、Profile 或用户媒体数据。需要写入数据的验证改用 `--data-root <dir>`（仅 Debug 构建），它会把偏好设置、Application Support 和 Keychain 条目都放到该目录下。
- Reader 不得恢复触控板滑动翻页；离散鼠标滚轮翻页与精确触控板滚动是不同输入路径。
- Google Lens OCR 会上传缩小后的漫画页面，必须明确说明并由用户触发；取消、切章或替换 session 后不得写回旧结果。
- YouTubeKit 使用获准的系统 JavaScriptCore 本地路径；不得把“禁止恢复 Shinsou、官方 AidokuRunner 与非受限漫画运行时”误解成删除 YouTubeKit 或 Aidoku 兼容层所需的隔离 JavaScriptCore 资源。

## 按需上下文

代码、验证、上游同步或发布任务使用 `.codex/skills/hoshi-reader-mac-workflow/SKILL.md`；该 skill 只加载与当前范围匹配的 reference。

- `docs/TODO.md`：当前状态、下一步、阻塞项和验证入口。
- `docs/ARCHITECTURE_REFACTORING.md`：长期架构和模块边界。
- `docs/READER_REGRESSION_TESTING.md`：Reader / Manga 实际数据矩阵与数据安全。
- `docs/UPSTREAM_SYNC_QUEUE.md`：待评估的上游变更。
- `docs/CHANGELOG.md`：仅记录普通用户可见变化。

只有实现使现有真源陈述失真时才更新对应文档；不要把一次性日志、代码可直接表达的事实或重复命令清单写回根文档。

## 完成契约

- 先检查工作树和最近实现，再按影响范围运行最接近的 contract / test。
- 修改可运行 App 代码后，使用 `./script/build_and_run.sh --verify` 打开受影响模块；纯文档、纯 CI 或签名/发布编排任务按对应 reference 处理。
- Contract test 不能证明 Reader、Manga 或 Video 的视觉正确性。实际数据验证必须使用安全、可还原或 disposable 的数据；没有安全 fixture 时明确列出未验证场景，不得操作用户现有数据。
- 不声明未亲自验证的 UI、外部账户、Anki、同步或发布行为可用。
- 最终回复说明改了什么、验证了什么，以及哪些场景未验证。
