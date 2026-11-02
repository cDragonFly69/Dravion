import Foundation
import Observation
import Speech
import AVFoundation
import RelayCore

@MainActor @Observable
final class RelaySpeechInput {
    private(set) var isRecording = false
    private(set) var transcript = ""
    var error: String?
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var recognition: SFSpeechRecognitionTask?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var hasTap = false

    func start() async throws {
        guard !isRecording else { return }
        let permission = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard permission == .authorized else { throw RelayError.invalid("请在系统设置中允许 Dravion 使用语音识别。") }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw RelayError.invalid("请在系统设置中允许 Dravion 使用麦克风。") }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")), recognizer.isAvailable else {
            throw RelayError.invalid("系统语音识别当前不可用，请稍后重试或输入文字。")
        }
        stop(); error = nil; transcript = ""
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RelayError.invalid("当前没有可用的音频输入设备。") }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        hasTap = true
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, failure in
            Task { @MainActor in
                guard let self else { return }
                if let result { self.transcript = result.bestTranscription.formattedString }
                if let failure, self.isRecording { self.error = failure.localizedDescription; self.stop() }
                else if result?.isFinal == true { self.stop() }
            }
        }
        do { engine.prepare(); try engine.start(); isRecording = true }
        catch { stop(); throw error }
    }
    func stop() {
        isRecording = false
        engine.stop()
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        request?.endAudio(); recognition?.cancel(); recognition = nil; request = nil
    }
    func clear() { stop(); transcript = "" }
}
