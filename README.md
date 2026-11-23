# LX Music iOS (纯原生 SwiftUI)

基于 `lx-music-desktop` 核心业务逻辑实现的纯原生 iOS 音乐应用，**零第三方依赖**，采用 Swift + SwiftUI + `JavaScriptCore` + `AVFoundation` + `MediaPlayer` 构建，支持 **iOS 17.0+**。

## 快速开始

1. 使用 Xcode 打开工程文件：`ios/LXMusic.xcodeproj`
2. 选择 Scheme `LXMusic`，在 **Signing & Capabilities** 中配置你的 Apple Development Team（模拟器运行可跳过签名）
3. `Cmd + R` 运行应用（或 `Cmd + U` 运行 `LXMusicTests` 核心单元测试）

## 使用自定义音源（播放必配）

与 LX Music Desktop v2 一致，本应用不内置受版权保护的播放直链接口，但内置了原生 **`JavaScriptCore` 引擎**，完整实现了 `globalThis.lx` v2.0.0 规范（含 `lx.request`、`lx.on`、`lx.send`、`lx.utils.crypto/buffer/zlib` 与 `Buffer` polyfill）：

1. 进入底部 **「设置」→「自定义音源」**
2. 通过 **文件导入 (.js)** / **URL 直链下载** / **粘贴脚本代码** 导入任意兼容 LX Music v2 的自定义音源脚本
3. 导入后自动启用并显示支持的平台及音质（`128k` / `320k` / `flac` / `flac24bit`）

## 已实现核心模块

- **五大音源原生 SDK**：酷我 (`kw`)、酷狗 (`kg`)、QQ音乐 (`tx`)、网易云 (`wy`)、咪咕 (`mg`)
  - 歌曲搜索 / 歌单搜索 / 全网聚合搜索 / 热搜词 / 实时搜索建议
  - 歌单广场（排序、分类标签、链接/ID/酷狗码直开歌单）与歌单详情
  - 全平台排行榜（10~51 个细分榜单）
  - 歌词抓取与原生加解密：酷我 `mlyric` (zlib + `yeelion` XOR + 八进制逐字)、酷狗 KRC (XOR + zlib + 多语言 base64)、QQ QRC (非标 3DES + `Z_SYNC_FLUSH` zlib)、网易云 `eapi` YRC、咪咕 MRC (64 位有符号 XXTEA)
- **原生后台播放器**：`AVPlayer` + `AVAudioSession (.playback)` 后台播放、耳机拔出暂停、锁屏与控制中心封面/进度/切歌控制 (`MPNowPlayingInfoCenter` / `MPRemoteCommandCenter`)
- **完整播放状态机**：5 种播放模式（列表循环 / 随机 / 顺序 / 单曲循环 / 播完暂停）、稍后播放队列、随机已播历史、定时关闭（支持播完当前曲停止）、倍速播放、跨源自动/手动换源 (`findMusic` 9 级优先级 + 91 项版本词防误配)、预加载下一首
- **同步逐字歌词**：支持 `lxlyric` 逐字卡拉 OK 高亮、翻译 (`tlyric`)、点击任意歌词行跳转进度
- **歌单与不喜欢管理**：试听列表 / 我的收藏 / 自建歌单 / 在线歌单同步 / `.lxmc` & `.json` 备份导入导出（兼容桌面端 v1 & v2）/ `@` 与 `#` 转义规则不喜欢过滤
