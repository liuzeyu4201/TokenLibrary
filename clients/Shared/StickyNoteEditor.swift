import SwiftUI
import LibraryCore
import PhotosUI
import AVFoundation

#if canImport(UIKit)
import UIKit

struct StickyNoteEditor: View {
    let doc: LibraryDocument
    var store: DocumentStore
    var onPersist: () -> Void
    var onRename: (String) -> Void
    var onBeginRename: () -> Void
    var onExport: () -> Void

    @State private var editing = false
    @State private var lastSerialized = ""
    @State private var baseMarkdown = ""
    @State private var editSession:MarkdownEditSession?
    @State private var hasSaveFailure=false
    @State private var recordTask:Task<Void,Never>?
    @State private var photoTask:Task<Void,Never>?
    @State private var photoRequestID=UUID()
    @State private var isVisible=false
    @Environment(\.scenePhase) private var scenePhase
    @State private var mediaError: String?
    @State private var blocks: [NoteBlock] = []
    @State private var focused: String?
    @State private var pickingPhoto = false
    @State private var photoItem: PhotosPickerItem?
    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool
    @StateObject private var voice = VoiceSession()

    var body: some View {
        mainColumn
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(titleDraft.isEmpty ? FileNames.editingBase(doc.name, kind: doc.kind) : titleDraft)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { editorToolbar }
            .renameAction {
                titleFocused = true
            }
            .photosPicker(isPresented: $pickingPhoto, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { _, item in
                let request=UUID();photoRequestID=request
                photoTask?.cancel()
                photoTask=Task { await insertPhoto(item,request:request) }
            }
            .onAppear {
                isVisible=true
                voice.onRecordingFinished=appendRecording
                if editSession == nil || (!hasSaveFailure && NoteBlockCodec.serialize(blocks) == lastSerialized) {
                    titleDraft = FileNames.editingBase(doc.name, kind: doc.kind)
                    load(doc.markdown)
                }
            }
            .onChange(of: doc.id) { _, _ in
                titleDraft = FileNames.editingBase(doc.name, kind: doc.kind)
                load(doc.markdown)
            }
            .onChange(of: doc.name) { _, name in
                if !titleFocused {
                    titleDraft = FileNames.editingBase(name, kind: doc.kind)
                }
            }
            .onChange(of:doc.markdown) { _,value in
                if !hasSaveFailure,NoteBlockCodec.serialize(blocks) == lastSerialized { load(value) }
            }
            .onChange(of:blocks) { _,_ in _ = saveBlocks() }
            .onChange(of:scenePhase) { _,phase in
                if phase == .background { finishRecording();voice.stopPlayback();_ = saveBlocks() }
            }
            .onDisappear {
                isVisible=false;photoRequestID=UUID();photoTask?.cancel();photoTask=nil
                finishRecording();_ = saveBlocks();voice.stopPlayback();voice.onRecordingFinished=nil
            }
            .alert("媒体未完成",isPresented:Binding(get:{mediaError != nil || voice.errorMessage != nil},set:{if !$0 { mediaError=nil;voice.errorMessage=nil }})) {
                Button("知道了") { mediaError=nil;voice.errorMessage=nil }
            } message: { Text(mediaError ?? voice.errorMessage ?? "") }
    }

    private var mainColumn: some View {
        VStack(spacing: 0) {
            titleRow
            noteList
            if editing {
                if voice.isRecording {
                    RecordingBar(elapsed: voice.elapsed, action: toggleRecord)
                }
                InsertBar(
                    recording: voice.isRecording,
                    starting: voice.isStarting,
                    onText: insertText,
                    onPhoto: { pickingPhoto = true },
                    onVoice: toggleRecord
                )
            }
        }
    }

    private var noteList: some View {
        List {
            ForEach(blocks.indices, id: \.self) { index in
                stickyRow(index: index)
            }
            .onMove(perform: moveBlocks)
            .onDelete(perform: deleteBlocks)
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.interactively)
        .environment(\.editMode, .constant(editing ? .active : .inactive))
    }

    private func stickyRow(index: Int) -> some View {
        let item = blocks[index]
        return StickyCard(
            block: $blocks[index],
            editing: editing,
            selected: editing && focused == item.id,
            playing: voice.playingId == item.id,
            image: loadImage(item.path),
            onFocus: { focused = item.id },
            onPlay: { togglePlay(item) }
        )
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private var titleRow: some View {
        TextField("文件名", text: $titleDraft)
            .font(.largeTitle.bold())
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .focused($titleFocused)
            .onSubmit(commitTitle)
            .onChange(of: titleFocused) { _, focused in
                if !focused { commitTitle() }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .accessibilityLabel("文件名")
    }

    private func commitTitle() {
        let next = FileNames.stored(titleDraft, kind: doc.kind)
        titleDraft = FileNames.editingBase(next, kind: doc.kind)
        guard next != doc.name else { return }
        onRename(titleDraft)
    }

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(editing ? "预览" : "编辑") {
                if editing { finishRecording();voice.stopPlayback() }
                editing.toggle()
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("重命名") {
                    titleFocused = false
                    onBeginRename()
                }
                Button {
                    if saveBlocks() { onExport() }
                } label: {
                    Label("导出 Markdown 与附件", systemImage: "square.and.arrow.up")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .rotationEffect(.degrees(90))
            }
        }
    }

    private func load(_ markdown:String) {
        if editSession == nil {
            do { editSession=try store.beginMarkdownEdit(id:doc.id) }
            catch { mediaError=error.localizedDescription;return }
        }
        let parsed=NoteBlockCodec.parse(markdown)
        let values=parsed.isEmpty ? [NoteBlock(kind:.text)] : parsed
        baseMarkdown=markdown;lastSerialized=NoteBlockCodec.serialize(values);blocks=values
    }
    @discardableResult private func saveBlocks()->Bool {
        let value=NoteBlockCodec.serialize(blocks)
        if value == lastSerialized && !hasSaveFailure { return true }
        do {
            guard let editSession else { throw StoreError.notFound }
            switch try editSession.save(baseMarkdown:baseMarkdown,proposedMarkdown:value) {
            case .saved(let canonical,_):
                hasSaveFailure=false;load(canonical);onPersist();return true
            case .conflict:
                let firstConflict = !hasSaveFailure
                hasSaveFailure=true;onPersist()
                if firstConflict { mediaError="另一处修改与当前便签重叠。内容已保留在恢复草稿中，请到“冲突与恢复草稿”处理。" }
                return false
            }
        } catch { hasSaveFailure=true;mediaError="保存失败，当前便签仍保留：\(error.localizedDescription)";return false }
    }

    private func moveBlocks(from source: IndexSet, to dest: Int) {
        NoteBlockCodec.move(&blocks, fromOffsets: source, toOffset: dest)
    }

    private func deleteBlocks(_ idx: IndexSet) {
        blocks.remove(atOffsets: idx)
    }

    private func insertText() {
        let b = NoteBlock(kind: .text, text: "")
        NoteBlockCodec.insert(b, into: &blocks, after: focused)
        focused = b.id
    }

    private func insertPhoto(_ item: PhotosPickerItem?,request:UUID) async {
        guard let item else { return }
        defer { if photoRequestID == request { photoItem=nil } }
        do {
            guard let raw=try await item.loadTransferable(type:Data.self),let image=UIImage(data:raw),
                  let data=image.jpegData(compressionQuality:0.9) else { throw CocoaError(.fileReadCorruptFile) }
            try Task.checkCancellation()
            guard isVisible,photoRequestID == request else { return }
            let asset=try store.importAttachment(data:data,fileName:"photo.jpg",mime:"image/jpeg")
            let block=NoteBlock(kind:.image,path:asset.path)
            NoteBlockCodec.insert(block,into:&blocks,after:focused);focused=block.id
            _ = saveBlocks()
        } catch is CancellationError {} catch { if isVisible,photoRequestID == request { mediaError="无法保存图片：\(error.localizedDescription)" } }
    }

    private func finishRecording() {
        voice.cancelPendingStart();recordTask?.cancel();recordTask=nil
        if let result=voice.stopRecording() { appendRecording(result) }
    }
    private func appendRecording(_ result:VoiceRecordingResult) {
        let relative="media/"+result.url.lastPathComponent
        // Preserve the reference even if registering an attachment fails. Sync
        // can retry registration from Markdown; the recording stays reachable.
        let block=NoteBlock(kind:.voice,path:relative,duration:result.duration)
        NoteBlockCodec.insert(block,into:&blocks,after:focused);focused=block.id
        let saved=saveBlocks()
        do { _ = try store.registerAttachment(path:relative,mime:"audio/mp4") }
        catch {
            mediaError=saved ? "录音已加入本机笔记，附件待重试同步：\(error.localizedDescription)"
                : "录音文件与当前便签仍在本机，请重试保存：\(error.localizedDescription)"
        }
    }
    private func toggleRecord() {
        if voice.isRecording { finishRecording();return }
        guard !voice.isStarting else { return }
        do {
            let directory=store.root.appendingPathComponent("media",isDirectory:true)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let url=directory.appendingPathComponent(UUID().uuidString.lowercased()+".m4a")
            recordTask=Task { await voice.startRecording(url:url) }
        } catch { mediaError="无法创建录音文件：\(error.localizedDescription)" }
    }
    private func togglePlay(_ block:NoteBlock) {
        guard let path=block.path else { return }
        finishRecording()
        do { voice.togglePlay(url:try store.resolveAttachment(path:path),id:block.id) }
        catch { mediaError=error.localizedDescription }
    }

    private func loadImage(_ path: String?) -> UIImage? {
        guard let path else { return nil }
        if path.hasPrefix("data:"), let comma = path.firstIndex(of: ",") {
            let b64 = String(path[path.index(after: comma)...])
            if let data = Data(base64Encoded: b64) { return UIImage(data: data) }
        }
        guard let url=try? store.resolveAttachment(path:path) else { return nil }
        return UIImage(contentsOfFile:url.path)
    }

    private func resolve(_ path: String) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return store.root.appendingPathComponent(path)
    }
}

private struct StickyCard: View {
    @Binding var block: NoteBlock
    var editing: Bool
    var selected: Bool
    var playing: Bool
    var image: UIImage?
    var onFocus: () -> Void
    var onPlay: () -> Void

    var body: some View {
        cardBody
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(Color.black)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(cardStroke)
            .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
            .environment(\.colorScheme, .light)
            .onTapGesture(perform: onFocus)
    }

    @ViewBuilder
    private var cardBody: some View {
        switch block.kind {
        case .text:
            textBody
        case .image:
            VStack(alignment: .leading, spacing: 10) {
                imageBody
                caption
            }
        case .voice:
            VStack(alignment: .leading, spacing: 10) {
                voiceBody
                caption
            }
        }
    }

    @ViewBuilder
    private var textBody: some View {
        if editing {
            TextField("便签", text: $block.text, axis: .vertical)
                .font(.body)
                .foregroundStyle(Color.black)
                .lineLimit(1...20)
                .accessibilityLabel("文字便签")
                .accessibilityIdentifier("sticky-text-"+block.id)
        } else {
            Text(block.text.isEmpty ? "空白便签" : block.text)
                .foregroundStyle(block.text.isEmpty ? Color.black.opacity(0.35) : Color.black)
        }
    }

    @ViewBuilder
    private var imageBody: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel(block.text.isEmpty ? "图片便签" : "图片便签，"+block.text)
                .accessibilityIdentifier("sticky-image-"+block.id)
        } else {
            Label("图片便签", systemImage: "photo")
                .foregroundStyle(.secondary)
        }
    }

    private var voiceBody: some View {
        HStack(spacing: 12) {
            Button(action: onPlay) {
                Image(systemName: playing ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 36))
            }
            .accessibilityIdentifier("sticky-voice-"+block.id+"-play")
            .accessibilityLabel(playing ? "停止播放语音便签" : "播放语音便签")
            .accessibilityValue(Self.clock(block.duration ?? 0)+(block.text.isEmpty ? "" : "，"+String(block.text.prefix(36))))
            VStack(alignment: .leading, spacing: 4) {
                Text("语音便签").font(.headline)
                Text(Self.clock(block.duration ?? 0))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var caption: some View {
        if editing {
            TextField("写点文字…", text: $block.text, axis: .vertical)
                .font(.body)
                .foregroundStyle(Color.black)
                .lineLimit(1...8)
        } else if !block.text.isEmpty {
            Text(block.text)
                .font(.body)
                .foregroundStyle(Color.black)
        }
    }

    private var cardStroke: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(selected ? Color.accentColor.opacity(0.55) : Color.black.opacity(0.12), lineWidth: selected ? 2 : 1)
    }

    static func clock(_ t: Double) -> String {
        let s = Int(t.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct RecordingBar: View {
    var elapsed: TimeInterval
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Text("录音中 \(StickyCard.clock(elapsed))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text("点这里停止")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.red.opacity(0.9))
        }
        .buttonStyle(.plain)
    }
}

private struct InsertBar: View {
    var recording: Bool
    var starting: Bool
    var onText: () -> Void
    var onPhoto: () -> Void
    var onVoice: () -> Void
    var body: some View {
        HStack {
            Menu {
                Button("文字便签", systemImage: "note.text", action: onText)
                Button("图片", systemImage: "photo", action: onPhoto)
                Button(starting ? "等待麦克风授权…" : (recording ? "停止录音" : "语音"), systemImage: recording ? "stop.circle.fill" : "mic", action: onVoice)
                    .disabled(starting)
            } label: {
                Label("插入", systemImage: "plus.circle.fill")
                    .font(.body.weight(.semibold))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
}

#endif

struct VoiceRecordingResult: Equatable {
    let url:URL
    let duration:TimeInterval
}

enum VoiceRecordingFileError: LocalizedError {
    case unreadable, empty
    var errorDescription: String? {
        switch self {
        case .unreadable: return "录音文件不完整或无法读取，未加入笔记。请重试录音。"
        case .empty: return "这次录音没有可播放的声音片段，未加入笔记。请重试录音。"
        }
    }
}

/// Reads a finalized file only. It never starts an audio session or a microphone.
enum VoiceRecordingFile {
    static func result(url: URL) throws -> VoiceRecordingResult {
        do {
            let file = try AVAudioFile(forReading: url)
            let frames = file.length, rate = file.processingFormat.sampleRate
            guard frames > 0 else { throw VoiceRecordingFileError.empty }
            guard rate.isFinite, rate > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096) else {
                throw VoiceRecordingFileError.unreadable
            }
            // Check decodable data at both ends with bounded memory/work. A
            // header alone must not become a fictitious 0.2-second recording.
            let count = AVAudioFrameCount(min(frames, 4_096))
            try file.read(into: buffer, frameCount: count)
            guard buffer.frameLength == count else { throw VoiceRecordingFileError.unreadable }
            if frames > Int64(count) {
                file.framePosition = frames - Int64(count)
                try file.read(into: buffer, frameCount: count)
                guard buffer.frameLength == count else { throw VoiceRecordingFileError.unreadable }
            }
            let duration = Double(frames) / rate
            guard duration.isFinite, duration > 0 else { throw VoiceRecordingFileError.empty }
            return VoiceRecordingResult(url: url, duration: duration)
        } catch let error as VoiceRecordingFileError { throw error }
        catch { throw VoiceRecordingFileError.unreadable }
    }
}

@MainActor
protocol VoiceAudioBackend: AnyObject {
    func requestPermission() async -> Bool
    var recordingTime:TimeInterval { get }
    func startRecording(url:URL,onInterrupted:@escaping @MainActor ()->Void) throws
    func stopRecording() throws -> VoiceRecordingResult?
    func startPlayback(url:URL,onFinished:@escaping @MainActor (Bool)->Void) throws
    func stopPlayback()
    func deactivate()
}

/// Owns request identity and finalization independently of a SwiftUI sheet.
/// Tests inject a backend without requesting microphone or playback access.
@MainActor
final class VoiceSession: ObservableObject {
    @Published var errorMessage:String?
    @Published private(set) var isRecording=false
    @Published private(set) var isStarting=false
    @Published private(set) var elapsed:TimeInterval=0
    @Published private(set) var playingId:String?
    var onRecordingFinished:((VoiceRecordingResult)->Void)?
    private let backend:any VoiceAudioBackend
    private var requestID:UUID?
    private var recordingID:UUID?
    private var playbackID:UUID?
    private var timerTask:Task<Void,Never>?

    init(backend:any VoiceAudioBackend) { self.backend=backend }
    #if canImport(UIKit)
    convenience init() { self.init(backend:IOSVoiceAudioBackend()) }
    #endif

    func startRecording(url:URL) async {
        guard !isRecording,!isStarting else { return }
        let request=UUID();requestID=request;isStarting=true;errorMessage=nil
        let allowed=await backend.requestPermission()
        guard requestID == request else { return }
        requestID=nil;isStarting=false
        guard !Task.isCancelled else { return }
        guard allowed else { errorMessage="没有麦克风权限，请在系统设置中允许录音后重试。";return }
        stopPlayback()
        let recording=UUID();recordingID=recording
        do {
            try backend.startRecording(url:url) { [weak self] in
                guard let self,self.recordingID == recording else { return }
                if let result=self.stopRecording() {
                    self.onRecordingFinished?(result)
                    self.errorMessage="录音已中断，已录制的片段已结束，请核对笔记中的录音。"
                } else if self.errorMessage == nil { self.errorMessage="录音已中断，没有可恢复的音频，请重试。" }
            }
            isRecording=true;elapsed=0
            timerTask=Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for:.milliseconds(200)) } catch { return }
                    guard let self,self.recordingID == recording,self.isRecording else { return }
                    self.elapsed=self.backend.recordingTime
                }
            }
        } catch {
            recordingID=nil;isRecording=false;backend.deactivate()
            errorMessage="无法录音：\(error.localizedDescription)"
        }
    }

    func cancelPendingStart() { requestID=nil;isStarting=false }

    func stopRecording()->VoiceRecordingResult? {
        cancelPendingStart()
        guard isRecording else { return nil }
        recordingID=nil;isRecording=false;timerTask?.cancel();timerTask=nil;elapsed=0
        defer { backend.deactivate() }
        do { return try backend.stopRecording() }
        catch {
            errorMessage=error.localizedDescription
            return nil
        }
    }

    func stopPlayback() {
        playbackID=nil;backend.stopPlayback();playingId=nil
        if !isRecording { backend.deactivate() }
    }

    func togglePlay(url:URL,id:String) {
        cancelPendingStart()
        if let result=stopRecording() { onRecordingFinished?(result) }
        if playingId == id { stopPlayback();return }
        stopPlayback()
        let playback=UUID();playbackID=playback
        do {
            try backend.startPlayback(url:url) { [weak self] success in
                guard let self,self.playbackID == playback else { return }
                self.stopPlayback()
                if !success { self.errorMessage="录音播放已中断，请重新播放。" }
            }
            playingId=id
        } catch { stopPlayback();errorMessage="无法播放录音，请检查附件是否已同步：\(error.localizedDescription)" }
    }
}

#if canImport(UIKit)
@MainActor
private final class IOSVoiceAudioBackend:NSObject,VoiceAudioBackend,AVAudioPlayerDelegate,AVAudioRecorderDelegate {
    private var recorder:AVAudioRecorder?
    private var player:AVAudioPlayer?
    private var recordingInterrupted:(@MainActor ()->Void)?
    private var playbackFinished:(@MainActor (Bool)->Void)?
    private var interruptionObserver:NSObjectProtocol?
    private var active=false
    private var sessionID=UUID()
    var recordingTime:TimeInterval { recorder?.currentTime ?? 0 }

    func requestPermission() async -> Bool { await AVAudioApplication.requestRecordPermission() }
    private func activate(_ category:AVAudioSession.Category,options:AVAudioSession.CategoryOptions=[]) throws {
        let audio=AVAudioSession.sharedInstance()
        try audio.setCategory(category,mode:.default,options:options)
        try audio.setActive(true);active=true
        if interruptionObserver == nil {
            let sessionID=UUID();self.sessionID=sessionID
            interruptionObserver=NotificationCenter.default.addObserver(forName:AVAudioSession.interruptionNotification,object:audio,queue:.main) { [weak self] notice in
                let raw=notice.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
                Task { @MainActor [weak self] in
                    guard let self,self.sessionID == sessionID else { return }
                    if let callback=self.recordingInterrupted { callback() }
                    else { self.playbackFinished?(false) }
                }
            }
        }
    }
    func startRecording(url:URL,onInterrupted:@escaping @MainActor ()->Void) throws {
        try activate(.playAndRecord,options:[.defaultToSpeaker])
        let value=try AVAudioRecorder(url:url,settings:[
            AVFormatIDKey:Int(kAudioFormatMPEG4AAC),AVSampleRateKey:44100,
            AVNumberOfChannelsKey:1,AVEncoderAudioQualityKey:AVAudioQuality.high.rawValue,
        ])
        value.delegate=self;recorder=value;recordingInterrupted=onInterrupted
        guard value.prepareToRecord(),value.record() else { _=try? stopRecording();throw CocoaError(.fileWriteUnknown) }
    }
    func stopRecording() throws -> VoiceRecordingResult? {
        guard let value=recorder else { return nil }
        let url=value.url
        recorder=nil;recordingInterrupted=nil;value.delegate=nil;value.stop()
        // currentTime is valid only while recording. Finish/error delegates
        // may arrive after the recorder stopped, so inspect the closed file.
        return try VoiceRecordingFile.result(url:url)
    }
    func startPlayback(url:URL,onFinished:@escaping @MainActor (Bool)->Void) throws {
        try activate(.playback)
        let value=try AVAudioPlayer(contentsOf:url)
        player=value;playbackFinished=onFinished;value.delegate=self
        guard value.prepareToPlay(),value.play() else { throw CocoaError(.fileReadCorruptFile) }
    }
    func stopPlayback() { player?.delegate=nil;player?.stop();player=nil;playbackFinished=nil }
    func deactivate() {
        sessionID=UUID()
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver);self.interruptionObserver=nil }
        guard active else { return }
        try? AVAudioSession.sharedInstance().setActive(false,options:[.notifyOthersOnDeactivation]);active=false
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player:AVAudioPlayer,successfully flag:Bool) {
        Task { @MainActor [weak self] in
            guard self?.player === player else { return }
            self?.playbackFinished?(flag)
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player:AVAudioPlayer,error:Error?) {
        Task { @MainActor [weak self] in
            guard self?.player === player else { return }
            self?.playbackFinished?(false)
        }
    }
    nonisolated func audioRecorderDidFinishRecording(_ recorder:AVAudioRecorder,successfully flag:Bool) {
        Task { @MainActor [weak self] in
            guard self?.recorder === recorder else { return }
            self?.recordingInterrupted?()
        }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder:AVAudioRecorder,error:Error?) {
        Task { @MainActor [weak self] in
            guard self?.recorder === recorder else { return }
            self?.recordingInterrupted?()
        }
    }
}
#endif
