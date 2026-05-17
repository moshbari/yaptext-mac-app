//
//  SarvamService.swift
//  YapTextMac
//
//  Handles speech-to-text via Sarvam AI for Bengali script and Banglish (Romanized).
//  Sarvam saaras:v3 model:
//    - mode=transcribe  →  outputs Bengali script (নমস্কার, কেমন আছেন?)
//    - mode=translit    →  outputs Banglish     (Nomoshkar, kemon achen?)
//
//  Long-audio handling:
//    Sarvam's /speech-to-text REST endpoint caps audio at ~30 seconds. For
//    recordings longer than that, this service transparently splits the
//    audio into ~28-second chunks using AVAssetExportSession, transcribes
//    each chunk in parallel, and stitches the transcripts back together
//    in chronological order. The caller sees one seamless string and never
//    knows the audio was chopped.
//

import Foundation
import AVFoundation

class SarvamService {

    // Distinct modes the Mac app supports for Sarvam.
    enum SarvamMode {
        case bengali       // mode=transcribe, language_code=bn-IN
        case banglish      // mode=translit,   language_code=bn-IN

        var apiMode: String {
            switch self {
            case .bengali:  return "transcribe"
            case .banglish: return "translit"
            }
        }

        var label: String {
            switch self {
            case .bengali:  return "Bengali"
            case .banglish: return "Banglish"
            }
        }
    }

    // Result types
    enum SarvamResult {
        case success(String)
        case failure(String)
    }

    private let endpoint = URL(string: "https://api.sarvam.ai/speech-to-text")!

    // Sarvam real-time STT cap is 30s. We chunk under that with a small safety margin.
    private let chunkSeconds: Double = 28.0
    // Anything at or below this duration is sent as a single call (no chunking).
    private let singleCallLimitSeconds: Double = 29.0

    // ============================================================
    // Public entry point — auto-chunks long audio transparently.
    // ============================================================
    /// Sends recorded audio file to Sarvam STT and returns the transcript.
    /// - Parameters:
    ///   - fileURL: local m4a audio file
    ///   - apiKey: Sarvam API subscription key
    ///   - mode: .bengali for Bengali script, .banglish for Romanized
    ///   - completion: called on main thread with .success(text) or .failure(reason)
    func transcribe(
        fileURL: URL,
        apiKey: String,
        mode: SarvamMode,
        completion: @escaping (SarvamResult) -> Void
    ) {
        guard !apiKey.isEmpty else {
            DispatchQueue.main.async { completion(.failure("Sarvam API key not set. Add it in Settings.")) }
            return
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            DispatchQueue.main.async { completion(.failure("Could not read audio file")) }
            return
        }

        // Detect duration via AVURLAsset (works for local m4a/aac files).
        let asset = AVURLAsset(url: fileURL)
        let durationSec = CMTimeGetSeconds(asset.duration)

        // If duration is unknown or short → single call.
        if !durationSec.isFinite || durationSec <= 0 || durationSec <= singleCallLimitSeconds {
            transcribeSingle(fileURL: fileURL, apiKey: apiKey, mode: mode, completion: completion)
            return
        }

        // Long audio → split, transcribe in parallel, merge.
        NSLog("SarvamService: long audio %.2fs → chunking", durationSec)
        splitAudio(asset: asset) { [weak self] chunkURLs in
            guard let self = self else { return }
            guard !chunkURLs.isEmpty else {
                DispatchQueue.main.async {
                    completion(.failure("Audio splitting failed. Please try again."))
                }
                return
            }
            NSLog("SarvamService: split into %d chunks", chunkURLs.count)
            self.transcribeChunks(chunkURLs: chunkURLs, apiKey: apiKey, mode: mode, completion: completion)
        }
    }

    // ============================================================
    // Single-call path (the original, unchanged Sarvam call)
    // ============================================================
    private func transcribeSingle(
        fileURL: URL,
        apiKey: String,
        mode: SarvamMode,
        completion: @escaping (SarvamResult) -> Void
    ) {
        guard let audioData = try? Data(contentsOf: fileURL) else {
            DispatchQueue.main.async { completion(.failure("Could not read audio file")) }
            return
        }
        guard audioData.count > 1000 else {
            DispatchQueue.main.async { completion(.failure("Recording too short. Try again.")) }
            return
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "api-subscription-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        var body = Data()

        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        appendField("model", "saaras:v3")
        appendField("language_code", "bn-IN")
        appendField("mode", mode.apiMode)

        // File part — Sarvam's whitelist accepts audio/mp4 but rejects audio/m4a.
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.mp4\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure("Network error: \(error.localizedDescription)"))
                    return
                }
                guard let http = response as? HTTPURLResponse, let data = data else {
                    completion(.failure("Invalid response from Sarvam"))
                    return
                }
                if http.statusCode == 200 {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let transcript = json["transcript"] as? String {
                        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                        if cleaned.isEmpty {
                            completion(.failure("No speech detected. Try again."))
                        } else {
                            completion(.success(cleaned))
                        }
                    } else {
                        let raw = String(data: data, encoding: .utf8) ?? ""
                        completion(.failure("Could not parse Sarvam response: \(String(raw.prefix(100)))"))
                    }
                } else if http.statusCode == 401 || http.statusCode == 403 {
                    completion(.failure("Invalid Sarvam API key. Check Settings."))
                } else if http.statusCode == 413 {
                    completion(.failure("Audio too long. Sarvam REST limit is ~30s — speak shorter clips."))
                } else if http.statusCode == 429 {
                    completion(.failure("Sarvam rate limited. Wait and try again."))
                } else {
                    let raw = String(data: data, encoding: .utf8) ?? "Unknown"
                    completion(.failure("Sarvam error (\(http.statusCode)): \(String(raw.prefix(120)))"))
                }
            }
        }.resume()
    }

    // ============================================================
    // Split audio into ~chunkSeconds slices using AVAssetExportSession
    // ============================================================
    private func splitAudio(asset: AVURLAsset, completion: @escaping ([URL]) -> Void) {
        let totalSeconds = CMTimeGetSeconds(asset.duration)
        guard totalSeconds.isFinite, totalSeconds > 0 else {
            completion([])
            return
        }

        let chunkCount = Int(ceil(totalSeconds / chunkSeconds))
        let tmpDir = FileManager.default.temporaryDirectory
        let groupID = UUID().uuidString

        var indexedURLs: [(Int, URL)] = []
        let lock = NSLock()
        let group = DispatchGroup()

        for i in 0..<chunkCount {
            let startSec = Double(i) * chunkSeconds
            let endSec = min(startSec + chunkSeconds, totalSeconds)
            let startTime = CMTime(seconds: startSec, preferredTimescale: 600)
            let endTime = CMTime(seconds: endSec, preferredTimescale: 600)
            let timeRange = CMTimeRange(start: startTime, end: endTime)

            let outURL = tmpDir.appendingPathComponent("yaptext_\(groupID)_chunk_\(String(format: "%03d", i)).m4a")
            try? FileManager.default.removeItem(at: outURL)

            guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                continue
            }
            exporter.outputURL = outURL
            exporter.outputFileType = .m4a
            exporter.timeRange = timeRange

            group.enter()
            exporter.exportAsynchronously {
                if exporter.status == .completed {
                    lock.lock()
                    indexedURLs.append((i, outURL))
                    lock.unlock()
                } else {
                    NSLog("SarvamService: export failed for chunk %d status=%d error=%@",
                          i, exporter.status.rawValue, String(describing: exporter.error))
                }
                group.leave()
            }
        }

        group.notify(queue: .global()) {
            let sorted = indexedURLs.sorted { $0.0 < $1.0 }.map { $0.1 }
            completion(sorted)
        }
    }

    // ============================================================
    // Transcribe an array of chunk files in parallel and stitch results.
    // ============================================================
    private func transcribeChunks(
        chunkURLs: [URL],
        apiKey: String,
        mode: SarvamMode,
        completion: @escaping (SarvamResult) -> Void
    ) {
        var indexedResults: [(Int, String)] = []
        var firstError: String? = nil
        let lock = NSLock()
        let group = DispatchGroup()

        for (i, url) in chunkURLs.enumerated() {
            group.enter()
            transcribeSingle(fileURL: url, apiKey: apiKey, mode: mode) { result in
                switch result {
                case .success(let text):
                    lock.lock()
                    indexedResults.append((i, text))
                    lock.unlock()
                case .failure(let reason):
                    lock.lock()
                    if firstError == nil { firstError = reason }
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            // Clean up the chunk temp files
            for url in chunkURLs {
                try? FileManager.default.removeItem(at: url)
            }

            // If every chunk failed, surface the first error
            if indexedResults.isEmpty {
                completion(.failure(firstError ?? "Transcription failed."))
                return
            }

            let merged = indexedResults
                .sorted { $0.0 < $1.0 }
                .map { $0.1.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if merged.isEmpty {
                completion(.failure("No speech detected. Try again."))
            } else {
                completion(.success(merged))
            }
        }
    }
}
