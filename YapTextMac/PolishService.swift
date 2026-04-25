import Foundation
import Combine

class PolishService: ObservableObject {
    
    let objectWillChange = ObservableObjectPublisher()
    
    var isPolishing: Bool = false { willSet { objectWillChange.send() } }
    var polishedText: String = "" { willSet { objectWillChange.send() } }
    var errorMessage: String? = nil { willSet { objectWillChange.send() } }
    
    // MARK: - Tones
    
    enum Tone: String, CaseIterable {
        case fixOnly = "Fix Only"
        case friendlyPro = "Friendly Pro"
        case executive = "Executive"
        case supportive = "Supportive"
        case creator = "Creator"
        case academic = "Academic"
        case simple = "Simple"
        case concise = "Concise"
        case elaborate = "Elaborate"
        case email = "Email"
        case message = "Message"
        
        var icon: String {
            switch self {
            case .fixOnly: return "checkmark.circle"
            case .friendlyPro: return "face.smiling"
            case .executive: return "briefcase"
            case .supportive: return "heart"
            case .creator: return "sparkles"
            case .academic: return "graduationcap"
            case .simple: return "text.alignleft"
            case .concise: return "scissors"
            case .elaborate: return "text.append"
            case .email: return "envelope"
            case .message: return "message"
            }
        }
        
        var systemPrompt: String {
            switch self {
            case .fixOnly:
                return "Fix grammar, spelling, and punctuation errors in the following text. Remove filler words like um, uh, like, you know, basically, and unnecessary repetition. Keep the original voice, tone, word choices, and meaning exactly the same. Do NOT rephrase or restructure sentences unless they are grammatically broken. Break into short paragraphs for readability if the text is long. Return only the corrected text, nothing else."
                
            case .friendlyPro:
                return "Clean up the following text to sound warm but professional. Fix grammar, spelling, and remove filler words like um, uh, like, you know. Keep the speaker's original words and phrasing as much as possible. Do NOT completely rewrite or add words the speaker didn't say. Just polish what's there into a friendly, professional version. Return only the cleaned text, nothing else."
                
            case .executive:
                return "Clean up the following text to sound clear, confident, and executive. Fix grammar, spelling, and remove filler words. Tighten where it rambles, but keep the speaker's original voice and key points. Do NOT completely rewrite or add words the speaker didn't say. Use direct, decisive language. Return only the cleaned text, nothing else."
                
            case .supportive:
                return "Clean up the following text to sound warm, supportive, and empathetic. Fix grammar, spelling, and remove filler words. Keep the speaker's original meaning, voice, and phrasing as much as possible. Do NOT completely rewrite or add words the speaker didn't say. Just gently polish into a kind, caring version. Return only the cleaned text, nothing else."
                
            case .creator:
                return "Clean up the following text to sound natural, engaging, and conversational — like a content creator talking to their audience. Fix grammar, spelling, and remove filler words. Keep the speaker's personality, original phrasing, and voice intact. Do NOT completely rewrite or add words the speaker didn't say. Return only the cleaned text, nothing else."
                
            case .academic:
                return "Clean up the following text to sound clear, precise, and academic. Fix grammar, spelling, and remove filler words. Keep the speaker's original arguments and voice as much as possible — just elevate the language slightly to be more formal and structured. Do NOT add ideas the speaker didn't say. Return only the cleaned text, nothing else."
                
            case .simple:
                return "Clean up the following text and rephrase it in plain, simple language anyone can understand. Fix grammar, spelling, and remove filler words. Keep the speaker's original meaning intact, but use shorter words and shorter sentences. Do NOT add ideas the speaker didn't say. Return only the cleaned text, nothing else."
                
            case .concise:
                return "Clean up the following text and make it as concise as possible without losing meaning. Fix grammar, spelling, and remove filler words. Cut redundancy and tighten sentences. Keep the speaker's original points and voice. Do NOT add ideas the speaker didn't say. Return only the cleaned text, nothing else."
                
            case .elaborate:
                return "Clean up the following text and elaborate on it slightly to add helpful context and clarity, while staying true to what the speaker said. Fix grammar, spelling, and remove filler words. Expand bare phrases into clearer sentences but do NOT invent new ideas, claims, or opinions the speaker didn't express. Return only the cleaned text, nothing else."
                
            case .email:
                return "Clean up the following text and format it as a professional email. Fix grammar, spelling, and remove filler words. Add a brief greeting and sign-off if appropriate. Keep the speaker's original message, voice, and key points. Do NOT add ideas the speaker didn't say. Return only the formatted email body, nothing else."
                
            case .message:
                return "Clean up the following text and format it as a casual, friendly chat message. Fix grammar, spelling, and remove filler words. Keep it short, natural, and conversational — like a text or Slack message. Keep the speaker's original meaning and voice. Do NOT add ideas the speaker didn't say. Return only the cleaned message, nothing else."
            }
        }
    }
    
    // MARK: - Polish API Call
    
    func polish(text: String, tone: Tone, apiKey: String) {
        guard !text.isEmpty else {
            errorMessage = "Nothing to polish — record something first."
            return
        }
        guard !apiKey.isEmpty else {
            errorMessage = "Set your OpenAI API key in Settings first."
            return
        }
        
        isPolishing = true
        errorMessage = nil
        polishedText = ""
        
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        
        let payload: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [
                ["role": "system", "content": tone.systemPrompt],
                ["role": "user", "content": text]
            ],
            "temperature": 0.5
        ]
        
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            self.isPolishing = false
            self.errorMessage = "Could not build request."
            return
        }
        request.httpBody = body
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.isPolishing = false
                
                if let error = error {
                    self?.errorMessage = "Network error: \(error.localizedDescription)"
                    return
                }
                guard let http = response as? HTTPURLResponse, let data = data else {
                    self?.errorMessage = "Invalid response from server."
                    return
                }
                
                if http.statusCode == 200 {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let choices = json["choices"] as? [[String: Any]],
                       let first = choices.first,
                       let message = first["message"] as? [String: Any],
                       let content = message["content"] as? String {
                        self?.polishedText = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    } else {
                        self?.errorMessage = "Could not read polished text from response."
                    }
                } else if http.statusCode == 401 {
                    self?.errorMessage = "Invalid API key. Check Settings."
                } else if http.statusCode == 429 {
                    self?.errorMessage = "Rate limited. Wait a moment and try again."
                } else {
                    let raw = String(data: data, encoding: .utf8) ?? "Unknown"
                    self?.errorMessage = "API error (\(http.statusCode)): \(String(raw.prefix(120)))"
                }
            }
        }.resume()
    }
}
