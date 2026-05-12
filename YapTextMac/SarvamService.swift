//
//  SarvamService.swift
//  YapTextMac
//
//  Handles speech-to-text via Sarvam AI for Bengali script and Banglish (Romanized).
//  Sarvam saaras:v3 model:
//    - mode=transcribe  →  outputs Bengali script (নমস্কার, কেমন আছেন?)
//    - mode=translit    →  outputs Banglish     (Nomoshkar, kemon achen?)
//

import Foundation

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
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let audioData = try? Data(contentsOf: fileURL) else {
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
        request.timeoutInterval = 45

        var body = Data()

        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        // Saaras v3 supports the `mode` parameter (transcribe / translit / etc.)
        appendField("model", "saaras:v3")
        appendField("language_code", "bn-IN")
        appendField("mode", mode.apiMode)

        // File part — use audio/mp4 (IANA-standard MIME for M4A/MP4-AAC).
        // Sarvam's whitelist accepts audio/mp4 but rejects audio/m4a.
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
                    // Sarvam returns JSON: { "transcript": "...", "request_id": "...", ... }
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
}
