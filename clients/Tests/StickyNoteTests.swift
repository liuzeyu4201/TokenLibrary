import Foundation
import XCTest
@testable import LibraryCore
@testable import LibraryUI

final class NoteBlockCodecTests:XCTestCase {
    func testTextAndMediaCaptionsPreserveUserWhitespaceAcrossRepeatedRoundTrips() {
        for text in ["", " ", "\t", "\n", "\r", "text\r", "hello ", "  中文 输入  ", "\n第一行\n\n", "\t缩进\r\n下一行\r\n"] {
            let blocks=[NoteBlock(id:"text",kind:.text,text:text),
                        NoteBlock(id:"image",kind:.image,text:text,path:"media/image.jpg"),
                        NoteBlock(id:"voice",kind:.voice,text:text,path:"media/audio.m4a",duration:1.5)]
            var current=blocks
            for _ in 0..<5 {
                current=NoteBlockCodec.parse(NoteBlockCodec.serialize(current))
                XCTAssertEqual(current,blocks,"User text must survive save/reload: \(text.debugDescription)")
            }
        }
    }

    func testEveryKeystrokeAutosaveRetainsSpacesNewlinesAndChineseTextInStore() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("sticky-keystrokes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:directory) }
        let store=try DocumentStore(directory:directory)
        var blocks=[NoteBlock(id:"text",kind:.text)]
        let initial=NoteBlockCodec.serialize(blocks)
        let document=LibraryDocument(id:"note",kind:.md,parentId:"root",name:"便签.md",markdown:initial,pdfPath:nil,
                                     revision:0,localGeneration:0,state:"active",purgeAt:nil,status:.savedLocal,annotationsJSON:"[]")
        try store.saveDocument(document,enqueue:false)
        let session=try store.beginMarkdownEdit(id:document.id)
        var base=initial,expected=""
        for character in "hello world\n中文 输入 \n\n" {
            expected.append(character);blocks[0].text.append(character)
            guard case .saved(let canonical,_)=try session.save(baseMarkdown:base,proposedMarkdown:NoteBlockCodec.serialize(blocks)) else {
                return XCTFail("Sequential autosave must not conflict")
            }
            base=canonical;blocks=NoteBlockCodec.parse(canonical)
            XCTAssertEqual(blocks[0].text,expected)
        }
        let reopened=try DocumentStore(directory:directory)
        XCTAssertEqual(NoteBlockCodec.parse(try XCTUnwrap(reopened.loadDocument(id:document.id)).markdown)[0].text,expected)
        XCTAssertEqual(try reopened.pending().count,1)
    }

    func testLegacyMarkersAndCRLFFramingRemainReadable() {
        let markdown="<!--tl:text id=\"a\"-->\r\n 中文 \r\n\r\n<!--/tl:text-->\r\n\r\n<!--tl:image id=\"b\"-->\r\n![旧图片说明](media/a.jpg)\r\n<!--/tl:image-->"
        let blocks=NoteBlockCodec.parse(markdown)
        XCTAssertEqual(blocks.map(\.id),["a","b"])
        XCTAssertEqual(blocks[0].text," 中文 \r\n")
        XCTAssertEqual(blocks[1].text,"旧图片说明")
        XCTAssertEqual(blocks[1].path,"media/a.jpg")
        XCTAssertEqual(NoteBlockCodec.parse("<!--tl:text id=\"inline\"--> x <!--/tl:text-->").first?.text," x ")
    }

    func testRawMarkdownWhitespaceAndMalformedMediaAreNotDiscarded() {
        for value in ["  \n", "\n# 原始正文\n\n", "<!--tl:image id=\"broken\"-->\nnot a media link\n<!--/tl:image-->\n"] {
            let blocks=NoteBlockCodec.parse(value)
            XCTAssertEqual(blocks.count,1)
            XCTAssertEqual(blocks.first?.text,value)
            XCTAssertEqual(NoteBlockCodec.parse(NoteBlockCodec.serialize(blocks)).first?.text,value)
        }
        let middle="<!--tl:voice id=\"voice\" duration=\"2.0\"-->\n[voice](media/a.m4a)\n<!--/tl:voice-->"
        let blocks=NoteBlockCodec.parse(" raw \n\n"+middle+"\n\n tail \n")
        XCTAssertEqual(blocks.map(\.text),[" raw \n\n","","\n\n tail \n"])
    }
}

@MainActor
final class StickyVoiceSessionTests:XCTestCase {
    @MainActor private final class Audio:VoiceAudioBackend {
        var permissions:[CheckedContinuation<Bool,Never>]=[]
        var starts=0,stops=0,deactivations=0,playStarts=0,playStops=0
        var recordingTime:TimeInterval=2.5
        var recordingURL:URL?
        var interrupted:(@MainActor ()->Void)?
        var finished:(@MainActor (Bool)->Void)?
        var failRecord=false,failPlay=false
        func requestPermission() async -> Bool { await withCheckedContinuation { permissions.append($0) } }
        func allow(_ allowed:Bool=true) { permissions.removeFirst().resume(returning:allowed) }
        func startRecording(url:URL,onInterrupted:@escaping @MainActor ()->Void) throws {
            starts+=1;if failRecord { throw CocoaError(.fileWriteUnknown) }
            recordingURL=url;interrupted=onInterrupted
        }
        func stopRecording()->VoiceRecordingResult? {
            stops+=1;defer { recordingURL=nil;interrupted=nil }
            return recordingURL.map { VoiceRecordingResult(url:$0,duration:recordingTime) }
        }
        func startPlayback(url:URL,onFinished:@escaping @MainActor (Bool)->Void) throws {
            playStarts+=1;if failPlay { throw CocoaError(.fileReadCorruptFile) };finished=onFinished
        }
        func stopPlayback() { playStops+=1;finished=nil }
        func deactivate() { deactivations+=1 }
    }
    private let url=URL(fileURLWithPath:"/tmp/synthetic-recording-no-file-access.m4a")
    private func start(_ voice:VoiceSession,_ audio:Audio) async -> Task<Void,Never> {
        let task=Task { await voice.startRecording(url:url) }
        while audio.permissions.isEmpty { await Task.yield() }
        return task
    }

    func testPermissionCancellationAndDuplicateTapNeverStartHiddenRecorder() async {
        let audio=Audio()
        let subject=VoiceSession(backend:audio)
        let first=await start(subject,audio)
        XCTAssertTrue(subject.isStarting)
        await subject.startRecording(url:url)
        XCTAssertEqual(audio.permissions.count,1)
        subject.cancelPendingStart();first.cancel();audio.allow();await first.value
        XCTAssertFalse(subject.isStarting);XCTAssertFalse(subject.isRecording);XCTAssertEqual(audio.starts,0)
        XCTAssertNil(subject.errorMessage)
    }

    func testOlderPermissionCompletionCannotOverrideNewRequest() async {
        let audio=Audio()
        let subject=VoiceSession(backend:audio)
        let old=await start(subject,audio);subject.cancelPendingStart()
        let latest=Task { await subject.startRecording(url:url) }
        while audio.permissions.count<2 { await Task.yield() }
        audio.allow();await old.value
        XCTAssertTrue(subject.isStarting);XCTAssertEqual(audio.starts,0)
        audio.allow();await latest.value
        XCTAssertTrue(subject.isRecording);XCTAssertEqual(audio.starts,1)
        XCTAssertEqual(subject.stopRecording()?.duration,2.5)
    }

    func testStopAndInterruptionFinalizeExactlyOnceAndReleaseAudioSession() async {
        let audio=Audio()
        let voice=VoiceSession(backend:audio)
        var results:[VoiceRecordingResult]=[];voice.onRecordingFinished={ results.append($0) }
        let task=await start(voice,audio);audio.allow();await task.value
        let oldInterruption=audio.interrupted
        audio.interrupted?()
        XCTAssertFalse(voice.isRecording);XCTAssertEqual(results,[VoiceRecordingResult(url:url,duration:2.5)])
        XCTAssertEqual(audio.stops,1);XCTAssertNil(voice.stopRecording());XCTAssertGreaterThan(audio.deactivations,0)
        let next=await start(voice,audio);audio.allow();await next.value
        oldInterruption?()
        XCTAssertTrue(voice.isRecording);XCTAssertEqual(results.count,1)
        XCTAssertNotNil(voice.stopRecording());XCTAssertEqual(audio.stops,2)
    }

    func testPlaybackFinalizesRecordingAndIgnoresOlderPlayerCompletion() async {
        let audio=Audio()
        let voice=VoiceSession(backend:audio)
        var saved:[VoiceRecordingResult]=[];voice.onRecordingFinished={ saved.append($0) }
        let task=await start(voice,audio);audio.allow();await task.value
        voice.togglePlay(url:url,id:"first")
        XCTAssertFalse(voice.isRecording);XCTAssertEqual(saved.count,1);XCTAssertEqual(voice.playingId,"first")
        let old=audio.finished
        voice.togglePlay(url:url,id:"second");old?(true)
        XCTAssertEqual(voice.playingId,"second")
        audio.finished?(true)
        XCTAssertNil(voice.playingId);XCTAssertGreaterThan(audio.deactivations,0)
    }

    func testDeniedPermissionAndBackendFailuresHaveRecoverableFeedback() async {
        let audio=Audio()
        let subject=VoiceSession(backend:audio)
        let denied=await start(subject,audio);audio.allow(false);await denied.value
        XCTAssertTrue(subject.errorMessage?.contains("麦克风权限") == true)
        XCTAssertFalse(subject.isRecording);XCTAssertFalse(subject.isStarting);XCTAssertEqual(audio.starts,0)
        audio.failRecord=true
        let failed=await start(subject,audio);audio.allow();await failed.value
        XCTAssertTrue(subject.errorMessage?.contains("无法录音") == true);XCTAssertFalse(subject.isRecording)
        audio.failPlay=true;subject.togglePlay(url:url,id:"missing")
        XCTAssertTrue(subject.errorMessage?.contains("无法播放") == true);XCTAssertNil(subject.playingId)
        XCTAssertGreaterThan(audio.deactivations,0)
    }
}
