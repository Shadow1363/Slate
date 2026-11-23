@preconcurrency import AVFoundation
import Foundation

/// 16 kHz mono Float32 audio, what Whisper takes.
public enum AudioSamples {
    public static let sampleRate: Double = 16_000

    public static var format: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    }

    /// Reads any audio file AVFoundation can open (m4a, mp3, wav, aiff, caf…)
    /// and resamples it to 16 kHz mono.
    public static func load(_ url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw VoiceError.unreadableAudio(error.localizedDescription)
        }
        let input = file.processingFormat
        guard file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw VoiceError.unreadableAudio("the file is empty")
        }
        do {
            try file.read(into: buffer)
        } catch {
            throw VoiceError.unreadableAudio(error.localizedDescription)
        }
        return try convert(buffer)
    }

    /// One buffer in any format resampled to 16 kHz mono.
    public static func convert(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        let output = format
        if buffer.format == output {
            return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        guard let converter = AVAudioConverter(from: buffer.format, to: output) else {
            throw VoiceError.unreadableAudio("unsupported format \(buffer.format)")
        }
        let ratio = output.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else {
            throw VoiceError.unreadableAudio("out of memory")
        }
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            throw VoiceError.unreadableAudio(error?.localizedDescription ?? "conversion failed")
        }
        return Array(UnsafeBufferPointer(start: converted.floatChannelData![0], count: Int(converted.frameLength)))
    }

    /// The samples as a 16-bit PCM WAV file.
    public static func wav(_ samples: [Float], sampleRate: Int = Int(sampleRate)) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let byteCount = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))              // fmt chunk size
        append(UInt16(1))               // PCM
        append(UInt16(1))               // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))  // byte rate
        append(UInt16(2))               // block align
        append(UInt16(16))              // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(byteCount))
        data.reserveCapacity(data.count + byteCount)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            append(Int16(clamped * Float(Int16.max)))
        }
        return data
    }

    /// Root-mean-square loudness, 0…1, for a level meter.
    public static func level(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += channel[index] * channel[index] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        // Speech sits around -40…-10 dBFS; map that onto the meter.
        let decibels = 20 * log10(max(rms, 0.000_01))
        return max(0, min(1, (decibels + 50) / 40))
    }
}
