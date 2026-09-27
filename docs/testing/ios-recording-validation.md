# U9：录音输入隔离、收尾时长与验收边界

2026-09-27，本轮只读核验指定 iOS 模拟器的音频路由、Xcode/Device Hub 版本与官方说明，并修复已确认的录音文件收尾问题。没有启动录音、采集环境声音、改变麦克风权限或系统输入路由，也没有读取个人音频。

## 当前原生录音的真实阻碍

本机为 Xcode **27.0 / 27A266a**，Device Hub **27.0 / 255.2.6.6**。Apple 的 [Xcode 27 发布说明](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes) 列出问题 175714711：“Sound Output and Input for simulators cannot be set to None.” 这与此前在系统 Inspector 选择 None 后仍显示 System/default 的原生观察一致，不能据菜单里出现 None 推断输入已经静音。

指定模拟器 `CDC55D3E-C4BB-43A3-B3C1-8789492A1D08` 的只读 `simctl io … enumerate` 明确显示 Guest Audio Input 和 Output 都连接 Default Host Audio Device；列出的输入只有物理麦克风，没有纯合成虚拟源。审计证明 `/tmp/tokenlibrary-u9-audio-readonly-audit.json` 记录版本与路由，不保留设备所有者名称。`simctl help io` 只提供枚举和显示相关操作，没有文件音频输入注入命令。

当前 [Device Hub 环境配置文档](https://developer.apple.com/documentation/xcode/configuring-the-environment-of-a-simulated-device) 支持从 Device > Sound > Sound Input 或 Inspector 选择输入设备，System 使用 Mac 的当前输入；没有声称可以把 WAV 文件直接作为麦克风来源。把合成 WAV 导入笔记、播放 WAV、调低输出音量都不能证明麦克风未采集环境声音。

因此本轮无法提供一条已经证明安全隔离的“选择 None→实际录音”步骤。后续原生成功录音需要先有可独立确认只输出合成信号的输入设备，并确认模拟器实际绑定它，才可另行验证 App 权限、录音和后台收尾。当前没有安装驱动、添加虚拟设备或修改任何隐私否决来绕过这一条件。已有权限拒绝反馈与合成 WAV 离线播放仍按 [iOS 便签与语音](ios-notes.md) 的限定结果记录，不算录制成功。

## 确认并修复的收尾时长错误

[StickyNoteEditor.swift](../../clients/Shared/StickyNoteEditor.swift) 原 `IOSVoiceAudioBackend.stopRecording` 在 `audioRecorderDidFinishRecording` 或编码错误之后仍读取 `AVAudioRecorder.currentTime`，再用至少 0.2 秒生成结果。本机 SDK `AVAudioRecorder.h` 明确 currentTime 只在录制期间有效；完成代理发生于录制已结束/停止之后。原代码因此不能可靠报告完成路径的真实时长，还可能把只有文件头的失败文件作为 0.2 秒语音块。

新 `VoiceRecordingFile.result` 在 recorder 停止、文件完成后读取 `AVAudioFile.length / processingFormat.sampleRate`，验证正的帧数/采样率，并以固定 4096 帧缓冲核对开头与末尾能解码。1 帧、10 ms 等很短但有效的片段保留实际时长，不强行补到 0.2 秒；不存在、空、截断文件头或无样本的文件显示明确错误，不加入空白片段。验证不改写失败文件，不全量把长录音载入内存；它验证时长和两端可读性，**不等于完整音频所有中间数据的损坏扫描**。

Backend 的收尾可以抛出文件错误，`VoiceSession` 仍先结束录制状态、取消计时，并确保释放音频会话；失败不交付语音块，下一次有效录音仍能正常收尾。已有请求/录音身份守卫保留，旧完成回调不能结束新片段。当前修复没有引入文件充当麦克风的假录制路径，也没有扩展录音格式或路由功能。

## 无麦克风自动证据

新增 [VoiceRecordingFileTests.swift](../../clients/Tests/VoiceRecordingFileTests.swift) 只在临时目录生成低幅度 440 Hz PCM，使用真实 AVAudioFile 编码/读取 AAC 文件；不创建 AVAudioRecorder、不调用音频会话、系统授权、实际播放或采样。

- 2 秒 PCM 和 AAC 按真实文件帧数得到时长，AAC 包含正常编码收尾。
- 10 ms 与单帧 PCM 不被改成 0.2 秒。
- 无效内容、0 字节、0 帧、截断 WAV 文件头、只有头没有样本均失败，原文件字节保留。
- 可控完成回调发生时后端计时已为 0，仍从真实 2 秒合成文件交付一次；重复/旧回调不重复交付。
- 文件收尾失败不交付、释放会话；下一段有效 10 ms 文件可用，旧回调不停止它。

03:07:24，新增 5 项与既有 StickyVoiceSession 5 / NoteBlockCodec 4 一起 **14 项全部通过，0 失败**，0.167 秒。日志 `/tmp/tokenlibrary-voice-finalization-tests.log`。既有权限取消、迟到允许、重复点击、播放替换和中断身份测试依旧使用可控 VoiceAudioBackend，不能替代系统 AVAudioSession 通知或麦克风录制。

Apple 的 [离线音频处理示例](https://developer.apple.com/documentation/avfaudio/performing-offline-audio-processing) 允许在 manual offline 模式断开音频硬件，由代码/文件驱动处理。这可用于额外编码、解码、波形和时长测试；它不是 AVAudioRecorder 的真实输入设备，也不能证明系统权限、实际后台中断、来电或路由切换已通过。现有 scenePhase/background、onDisappear、预览/播放切换均有明确停止与保存调用；自动测试只验证调用后的会话状态，不驱动 UIKit 前后台事件。成功原生录音和真实设备音频中断仍保留待验。

03:07:53，后续完整 `clients` 回归 **108 项通过，0 失败、0 跳过**，用例合计 5.460 秒：`/tmp/tokenlibrary-voice-finalization-full-client-tests.log`。该 SwiftPM 套运行 macOS 分支，证明纯文件 AVFoundation 与共享会话逻辑；iOS backend 的 UIKit 分支仍须后续原生目标编译，不能据此写成 iOS 真实录制通过。03:04 已封存验证包早于此改动，本节修复尚未包含其中。

后续03:17合并音频与导航的双端包已实际构建封存，iOS UIKit音频backend编译成功、strict签名/entitlements检查通过，126产品源码构建前后hash一致；03:14完整客户端111项也包含上述音频回归。此后续证据补齐编译边界，仍不表示成功麦克风录制或真实后台中断已原生通过。
