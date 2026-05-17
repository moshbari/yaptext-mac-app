//
//  SarvamService.swift
//  YapTextMac
//
//  Bengali / Banglish transcription, routed through the YapText API server
//  on Railway (same endpoint the iOS app uses). The server holds the Sarvam
//  key, handles long-audio chunking, and returns one coherent transcript
//  with proper punctuation across the whole recording.
//
//  Why not call Sarvam directly anymore:
//    Sarvam's /speech-to-text REST endpoint caps audio at ~30s. Chunking on
//    the client splits a single utterance into N parallel calls, each with
//    no cross-chunk context — Sarvam can't punctuate or capitalize across
//    the seams, so long recordings came back as one run-on paragraph.
//    The Railway server uses Sarvam's batch path (or equivalent) and gives
//    us one transcript with correct punctuation regardless of length.
//
//  The public transcribe(...) signature is unchanged so TranscriptionManager
//  needs no edits. The `apiKey` parameter is now ignored (server-side keys)
//  but kept for source compatibility; the Settings "Sarvam key" field is
//  effectively dormant for this path.
//

import Foundation

class SarvamService {

    // Distinct modes the Mac app supports for Sarvam (matched server-side).
    enum SarvamMode {
        case bengali       // → language=bengali  (Sarvam mode=transcribe)
        case banglish      // → language=banglish (Sarvam mode=translit)

        /// What the server expects in the `language` multipart field.
        var apiLanguage: String {
            switch self {
            case .bengali:  return "bengali"
            case .banglish: return "banglish"
            }
        }

        var label: String {
            switch self {
            case .bengali:  return "Bengali"
            case .banglish: return "Banglish"
            }
        }
    }

    enum SarvamResult {
        case success(String)
        case failure(String)
    }

    // ============================================================
    // YapText API (Railway) — same backend the iOS app talks to
    // ============================================================

    /// Base URL of the YapText proxy. Sarvam + OpenAI keys live on the server.
    private let apiBaseURL = "https://yaptext-api-production.up.railway.app"

    /// Shared app secret sent in `X-App-Secret`. Raises the bar against
    /// casual scraping; the real protection is server-side rate limiting.
    /// Same value the iOS build uses — see iOS Shared/Config.swift.
    private let appSecret = "6cf0dbc29b678a29f462c945b1f09c15fc02ae03d07d626071912fc1c09e7e61"

    // ============================================================
    // Public entry point — unchanged signature
    // ============================================================
    /// Sends recorded audio file to the YapText server and returns the transcript.
    /// - Parameters:
    ///   - fileURL: local m4a audio file
    ///   - apiKey: IGNORED. Kept for source compatibility with older callers.
    ///             The server holds the Sarvam subscription key.
    ///   - mode: .bengali for Bengali script, .banglish for Romanized
    ///   - completion: called on main thread with .success(text) or .failure(reason)
    func transcribe(
        fileURL: URL,
        apiKey: String,
        mode: SarvamMode,
        completion: @escaping (SarvamResult) -> Void
    ) {
        _ = apiKey  // intentionally unused — see header doc

        guard FileManager.default.fileExists(atPath: fileURL.path),
              let audioData = try? Data(contentsOf: fileURL) else {
            DispatchQueue.main.async { completion(.failure("Could not read audio file")) }
            return
        }
        guard audioData.count > 1000 else {
            DispatchQueue.main.async { completion(.failure("Recording too short. Try again.")) }
            return
        }

        let boundary = "yaptext-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "\(apiBaseURL)/transcribe")!)
        request.httpMethod = "POST"
        request.setValue(appSecret, forHTTPHeaderField: "X-App-Secret")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        // Long recordings can take ~real-time on the server, so allow generous slack.
        request.timeoutInterval = 300

        var body = Data()

        // language field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(mode.apiLanguage)\r\n".data(using: .utf8)!)

        // audio file field (iOS uses audio/m4a here — server accepts it)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"audio.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
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
                    completion(.failure("Invalid response from server"))
                    return
                }
                if http.statusCode == 200 {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let text = (json["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                        if text.isEmpty {
                            completion(.failure("No speech detected. Try again."))
                        } else {
                            completion(.success(text))
                        }
                    } else {
                        let raw = String(data: data, encoding: .utf8) ?? ""
                        completion(.failure("Could not parse server response: \(String(raw.prefix(100)))"))
                    }
                } else if http.statusCode == 401 {
                    completion(.failure("App auth failed. Update YapText to the latest version."))
                } else if http.statusCode == 429 {
                    completion(.failure("Server busy. Wait and try again."))
                } else {
                    var msg = "Server error (\(http.statusCode))"
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let err = json["error"] as? String {
                        msg = err
                    }
                    completion(.failure(String(msg.prefix(120))))
                }
            }
        }.resume()
    }
}
