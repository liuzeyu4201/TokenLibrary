import XCTest
import AVFoundation
@testable import LibraryUI

@MainActor final class VoiceRecordingFileTests: XCTestCase {
    private func directory() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("voice-file-only-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        return root
    }
    private func wav(frames:Int,rate:Int=44_100)->Data {
        var data=Data()
        func text(_ value:String) { data.append(contentsOf:value.utf8) }
        func u16(_ value:UInt16) { var x=value.littleEndian;withUnsafeBytes(of:&x) { data.append(contentsOf:$0) } }
        func u32(_ value:UInt32) { var x=value.littleEndian;withUnsafeBytes(of:&x) { data.append(contentsOf:$0) } }
        text("RIFF");u32(UInt32(36+frames*2));text("WAVEfmt ");u32(16);u16(1);u16(1)
        u32(UInt32(rate));u32(UInt32(rate*2));u16(2);u16(16);text("data");u32(UInt32(frames*2))
        for n in 0..<frames {
            let sample=Int16(sin(Double(n)*440*2*Double.pi/Double(rate))*400)
            u16(UInt16(bitPattern:sample))
        }
        return data
    }
    private func file(_ bytes:Data,_ root:URL,name:String="synthetic.wav") throws -> URL {
        let url=root.appendingPathComponent(name);try bytes.write(to:url);return url
    }
    func testValidAndVeryShortSyntheticPCMUseActualFramesWithoutDurationFloor() throws {
        let root=try directory()
        for frames in [88_200,441,1] {
            let url=try file(wav(frames:frames),root,name:"\(frames).wav")
            let result=try VoiceRecordingFile.result(url:url)
            XCTAssertEqual(result.url,url)
            XCTAssertEqual(result.duration,Double(frames)/44_100,accuracy:0.000_001)
        }
    }
    func testSyntheticAACUsesFinalizedFileDuration() throws {
        let root=try directory(),url=root.appendingPathComponent("synthetic.m4a")
        try autoreleasepool {
            let format=try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate:44_100,channels:1))
            let buffer=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:88_200))
            buffer.frameLength=88_200
            let samples=try XCTUnwrap(buffer.floatChannelData?[0])
            for n in 0..<88_200 { samples[n]=Float(sin(Double(n)*440*2*Double.pi/44_100)*0.01) }
            let output=try AVAudioFile(forWriting:url,settings:[AVFormatIDKey:Int(kAudioFormatMPEG4AAC),AVSampleRateKey:44_100,AVNumberOfChannelsKey:1],commonFormat:.pcmFormatFloat32,interleaved:false)
            try output.write(from:buffer)
        }
        let file=try AVAudioFile(forReading:url)
        let result=try VoiceRecordingFile.result(url:url)
        XCTAssertEqual(result.duration,Double(file.length)/file.processingFormat.sampleRate,accuracy:0.000_001)
        XCTAssertEqual(result.duration,2,accuracy:0.04)
    }
    func testInvalidEmptyAndTruncatedAudioNeverBecomePlaceholderBlocks() throws {
        let root=try directory()
        let cases:[(String,Data)]=[("invalid.wav",Data("not audio".utf8)),("empty.wav",Data()),
            ("zero-frames.wav",wav(frames:0)),("truncated-header.wav",Data(wav(frames:88_200).prefix(30))),
            ("header-without-samples.wav",Data(wav(frames:88_200).prefix(44)))]
        for (name,bytes) in cases {
            let url=try file(bytes,root,name:name)
            XCTAssertThrowsError(try VoiceRecordingFile.result(url:url),name)
            XCTAssertEqual(try Data(contentsOf:url),bytes,"Validation preserves failure material")
        }
    }
    private final class FileBackend:VoiceAudioBackend {
        let url:URL
        var stops=0,deactivations=0
        var interrupted:(@MainActor ()->Void)?
        init(url:URL) { self.url=url }
        var recordingTime:TimeInterval { 0 } // A recorder that has already completed.
        func requestPermission() async -> Bool { true } // No system permission request.
        func startRecording(url:URL,onInterrupted:@escaping @MainActor ()->Void) throws { interrupted=onInterrupted }
        func stopRecording() throws -> VoiceRecordingResult? { stops+=1;return try VoiceRecordingFile.result(url:url) }
        func startPlayback(url:URL,onFinished:@escaping @MainActor (Bool)->Void) throws {}
        func stopPlayback() {}
        func deactivate() { deactivations+=1 }
    }
    func testCompletionAfterRecorderClockResetsDeliversValidatedFileExactlyOnce() async throws {
        let url=try file(wav(frames:88_200),directory()),backend=FileBackend(url:url),voice=VoiceSession(backend:backend)
        var results:[VoiceRecordingResult]=[];voice.onRecordingFinished={ results.append($0) }
        await voice.startRecording(url:url)
        let late=backend.interrupted
        backend.interrupted?();late?()
        XCTAssertEqual(results,[VoiceRecordingResult(url:url,duration:2)])
        XCTAssertEqual(backend.stops,1);XCTAssertFalse(voice.isRecording);XCTAssertNil(voice.stopRecording())
        XCTAssertGreaterThan(backend.deactivations,0)
    }
    func testFailedFinalizationReleasesSessionAndDoesNotDeliverOrOverwriteAValidNextClip() async throws {
        let root=try directory(),url=try file(Data("invalid finalized recording".utf8),root)
        let backend=FileBackend(url:url),voice=VoiceSession(backend:backend)
        var results:[VoiceRecordingResult]=[];voice.onRecordingFinished={ results.append($0) }
        await voice.startRecording(url:url)
        let old=backend.interrupted;backend.interrupted?()
        XCTAssertTrue(results.isEmpty);XCTAssertFalse(voice.isRecording)
        XCTAssertTrue(voice.errorMessage?.contains("未加入笔记") == true)
        XCTAssertGreaterThan(backend.deactivations,0)
        try wav(frames:441).write(to:url)
        await voice.startRecording(url:url);old?()
        XCTAssertTrue(voice.isRecording)
        let result=try XCTUnwrap(voice.stopRecording())
        XCTAssertEqual(result.duration,0.01,accuracy:0.000_001)
        XCTAssertEqual(backend.stops,2)
        XCTAssertNil(voice.errorMessage)
    }
}
