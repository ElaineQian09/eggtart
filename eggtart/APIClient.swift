import Foundation
import UIKit

final class APIClient {
    static let shared = APIClient()

    private let baseURL = URL(string: "https://eggtart-backend-production-2361.up.railway.app")!
    private let commentsGeneratePath = ProcessInfo.processInfo.environment["EGGTART_COMMENTS_GENERATE_PATH"] ?? "/v1/eggbook/comments/generate"
    private let tokenService = "eggtart.auth"
    private let tokenAccount = "authToken"

    private init() {}

    enum APIError: Error, LocalizedError {
        case httpStatus(code: Int, body: String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .httpStatus(let code, let body):
                return "HTTP \(code): \(body)"
            case .invalidResponse:
                return "Invalid server response"
            }
        }
    }

    struct AuthResponse: Decodable {
        let userId: String
        let token: String
        let deviceId: String
    }

    struct DevicePayload: Encodable {
        let deviceId: String
        let deviceModel: String
        let os: String
        let language: String
        let timezone: String
    }

    struct DeviceResponse: Decodable {
        let message: String
        let deviceId: String
    }

    struct MemoryPayload: Encodable {
        let type: String
        let content: String
        let importance: Double
    }

    struct MemoryResponse: Decodable {
        let message: String
    }

    struct EventCreatePayload: Encodable {
        let deviceId: String
        let recordingUrl: String?
        let audioUrl: String?
        let screenRecordingUrl: String?
        let transcript: String?
        let durationSec: Int?
        let eventAt: String?
    }

    struct EventPatchPayload: Encodable {
        let recordingUrl: String?
        let audioUrl: String?
        let screenRecordingUrl: String?
        let transcript: String?
        let durationSec: Int?
        let eventAt: String?
    }

    struct EventResponse: Decodable {
        let eventId: String
        let status: String
    }

    struct EventStatusResponse: Decodable {
        let status: String
    }

    struct WhoAmIResponse: Decodable {
        let userId: String?
    }

    struct MessageResponse: Decodable {
        let message: String
    }

    struct TodoDTO: Decodable, Identifiable {
        let id: String
        let title: String
        let isAccepted: Bool
        let isPinned: Bool
        let createdAt: String
        let updatedAt: String
    }

    struct TodosResponse: Decodable {
        let items: [TodoDTO]
    }

    struct NotificationDTO: Decodable, Identifiable {
        let id: String
        let title: String
        let todoId: String?
        let notifyAt: String
        let createdAt: String
        let updatedAt: String
    }

    struct NotificationsResponse: Decodable {
        let items: [NotificationDTO]
    }

    struct IdeaItemResponse: Decodable {
        let item: EggIdeaDTO
    }

    struct TodoItemResponse: Decodable {
        let item: TodoDTO
    }

    struct NotificationItemResponse: Decodable {
        let item: NotificationDTO
    }

    struct CommentItemResponse: Decodable {
        let item: CommentDTO
    }

    struct CommentDTO: Decodable, Identifiable {
        let id: String
        let content: String?
        let date: String
        let isCommunity: Bool?
        let createdAt: String?
        let eggName: String?
        let eggComment: String?
        let userName: String?
    }

    struct CommentsResponse: Decodable {
        let myEgg: [CommentDTO]
        let community: [CommentDTO]
    }

    struct UploadRequestPayload: Encodable {
        let contentType: String
        let filename: String?
        let sizeBytes: Int?
    }

    struct UploadResponse: Decodable {
        let uploadUrl: String
        let fileUrl: String
        let expiresAt: String
    }

    struct EggbookSyncStatusResponse: Decodable {
        let hasUpdates: Bool?
        let isProcessing: Bool?
        let updatedTabs: [String]?
        let processingTabs: [String]?
        let serverTime: String?
        let lastEventAt: String?
    }

    func authenticateAnonymous(deviceId: String) async throws -> AuthResponse {
        let payload = DevicePayload(
            deviceId: deviceId,
            deviceModel: UIDevice.current.model,
            os: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            language: Locale.preferredLanguages.first ?? Locale.current.identifier,
            timezone: timeZoneLabel()
        )

        let response: AuthResponse = try await request(
            path: "/v1/auth/anonymous",
            method: "POST",
            body: payload,
            requiresAuth: false
        )
        saveToken(response.token)
        return response
    }

    func whoAmI() async throws -> WhoAmIResponse {
        return try await request(
            path: "/v1/auth/whoami",
            method: "GET",
            body: Optional<Int>.none,
            requiresAuth: true
        )
    }

    func registerDevice(deviceId: String) async throws -> DeviceResponse {
        let payload = DevicePayload(
            deviceId: deviceId,
            deviceModel: UIDevice.current.model,
            os: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            language: Locale.preferredLanguages.first ?? Locale.current.identifier,
            timezone: timeZoneLabel()
        )
        return try await request(
            path: "/v1/devices",
            method: "POST",
            body: payload,
            requiresAuth: true
        )
    }

    func createMemory(type: String, content: String, importance: Double) async throws -> MemoryResponse {
        let payload = MemoryPayload(type: type, content: content, importance: importance)
        return try await request(
            path: "/v1/memory",
            method: "POST",
            body: payload,
            requiresAuth: true
        )
    }

    func createEvent(
        deviceId: String,
        transcript: String? = nil,
        recordingUrl: String? = nil,
        audioUrl: String? = nil,
        screenRecordingUrl: String? = nil,
        durationSec: Int? = nil
    ) async throws -> EventResponse {
        await logWhoAmIBeforeEventMutation(action: "POST /v1/events")
        let payload = EventCreatePayload(
            deviceId: deviceId,
            recordingUrl: recordingUrl,
            audioUrl: audioUrl,
            screenRecordingUrl: screenRecordingUrl,
            transcript: transcript,
            durationSec: durationSec,
            eventAt: nil
        )
        do {
            return try await request(
                path: "/v1/events",
                method: "POST",
                body: payload,
                requiresAuth: true
            )
        } catch let error as APIError {
            if shouldSelfHealDevice(error: error) {
                print("createEvent self-heal triggered: re-auth + register device + retry")
                _ = try? await authenticateAnonymous(deviceId: deviceId)
                _ = try? await registerDevice(deviceId: deviceId)
                await logWhoAmIBeforeEventMutation(action: "POST /v1/events retry")
                return try await request(
                    path: "/v1/events",
                    method: "POST",
                    body: payload,
                    requiresAuth: true
                )
            }
            throw error
        }
    }

    func patchEvent(
        eventId: String,
        transcript: String? = nil,
        recordingUrl: String? = nil,
        audioUrl: String? = nil,
        screenRecordingUrl: String? = nil,
        durationSec: Int? = nil
    ) async throws -> EventResponse {
        await logWhoAmIBeforeEventMutation(action: "PATCH /v1/events/\(eventId)")
        let payload = EventPatchPayload(
            recordingUrl: recordingUrl,
            audioUrl: audioUrl,
            screenRecordingUrl: screenRecordingUrl,
            transcript: transcript,
            durationSec: durationSec,
            eventAt: nil
        )
        return try await request(
            path: "/v1/events/\(eventId)",
            method: "PATCH",
            body: payload,
            requiresAuth: true
        )
    }

    func getEventStatus(eventId: String) async throws -> EventStatusResponse {
        return try await request(
            path: "/v1/events/\(eventId)/status",
            method: "GET",
            body: Optional<Int>.none,
            requiresAuth: true
        )
    }

    func getTodos() async throws -> [TodoDTO] {
        let response: TodosResponse = try await request(
            path: "/v1/eggbook/todos",
            method: "GET",
            body: Optional<Int>.none,
            requiresAuth: true
        )
        return response.items
    }

    func createTodo(title: String) async throws -> TodoDTO {
        struct Payload: Encodable { let title: String }
        let response: TodoItemResponse = try await request(
            path: "/v1/eggbook/todos",
            method: "POST",
            body: Payload(title: title),
            requiresAuth: true
        )
        return response.item
    }

    func acceptTodo(id: String) async throws -> TodoDTO {
        let response: TodoItemResponse = try await request(
            path: "/v1/eggbook/todos/\(id)/accept",
            method: "POST",
            body: Optional<Int>.none,
            requiresAuth: true
        )
        return response.item
    }

    func deleteTodo(id: String) async throws -> MessageResponse {
        return try await request(
            path: "/v1/eggbook/todos/\(id)",
            method: "DELETE",
            body: Optional<Int>.none,
            requiresAuth: true
        )
    }

    func updateTodo(id: String, title: String? = nil, isAccepted: Bool? = nil) async throws -> TodoDTO {
        struct Payload: Encodable {
            let title: String?
            let isAccepted: Bool?
        }
        let response: TodoItemResponse = try await request(
            path: "/v1/eggbook/todos/\(id)",
            method: "PATCH",
            body: Payload(title: title, isAccepted: isAccepted),
            requiresAuth: true
        )
        return response.item
    }

    func getNotifications() async throws -> [NotificationDTO] {
        let response: NotificationsResponse = try await request(
            path: "/v1/eggbook/notifications",
            method: "GET",
            body: Optional<Int>.none,
            requiresAuth: true
        )
        return response.items
    }

    func createNotification(title: String, notifyAt: String, todoId: String? = nil) async throws -> NotificationDTO {
        struct Payload: Encodable {
            let title: String
            let notifyAt: String
            let todoId: String?
        }
        let response: NotificationItemResponse = try await request(
            path: "/v1/eggbook/notifications",
            method: "POST",
            body: Payload(title: title, notifyAt: notifyAt, todoId: todoId),
            requiresAuth: true
        )
        return response.item
    }

    func updateNotification(id: String, notifyAt: String) async throws -> NotificationDTO {
        struct Payload: Encodable { let notifyAt: String }
        let response: NotificationItemResponse = try await request(
            path: "/v1/eggbook/notifications/\(id)",
            method: "PATCH",
            body: Payload(notifyAt: notifyAt),
            requiresAuth: true
        )
        return response.item
    }

    func deleteNotification(id: String) async throws -> MessageResponse {
        return try await request(
            path: "/v1/eggbook/notifications/\(id)",
            method: "DELETE",
            body: Optional<Int>.none,
            requiresAuth: true
        )
    }

    func getComments(date: String, days: Int = 7) async throws -> CommentsResponse {
        let path = "/v1/eggbook/comments?date=\(date)&days=\(days)"
        return try await request(
            path: path,
            method: "GET",
            body: Optional<Int>.none,
            requiresAuth: true
        )
    }

    func createComment(content: String, date: String? = nil, isCommunity: Bool? = nil) async throws -> CommentDTO {
        struct Payload: Encodable {
            let content: String
            let date: String?
            let isCommunity: Bool?
        }
        let response: CommentItemResponse = try await request(
            path: "/v1/eggbook/comments",
            method: "POST",
            body: Payload(content: content, date: date, isCommunity: isCommunity),
            requiresAuth: true
        )
        return response.item
    }

    func triggerCommentsGeneration(date: String, manual: Bool) async throws {
        print("API request: POST", commentsGeneratePath)
        let url: URL
        if commentsGeneratePath.contains("?") {
            url = URL(string: baseURL.absoluteString + commentsGeneratePath) ?? baseURL.appendingPathComponent(commentsGeneratePath)
        } else {
            url = baseURL.appendingPathComponent(commentsGeneratePath)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = loadToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = [
            "date": date,
            "manual": manual
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard 200..<300 ~= http.statusCode else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            print("API error:", http.statusCode, bodyText)
            throw APIError.httpStatus(code: http.statusCode, body: bodyText)
        }
        let bodyText = String(data: data, encoding: .utf8) ?? ""
        print("API ok: POST \(commentsGeneratePath) status:", http.statusCode, bodyText)
    }

    func getIdeas() async throws -> [EggIdeaDTO] {
        let response: EggIdeasResponse = try await request(
            path: "/v1/eggbook/ideas",
            method: "GET",
            body: Optional<Int>.none,
            requiresAuth: true
        )
        return response.items
    }

    func getEggbookSyncStatus() async throws -> EggbookSyncStatusResponse {
        return try await request(
            path: "/v1/eggbook/sync-status",
            method: "GET",
            body: Optional<Int>.none,
            requiresAuth: true
        )
    }

    func requestUpload(contentType: String, filename: String?, sizeBytes: Int?) async throws -> UploadResponse {
        let payload = UploadRequestPayload(contentType: contentType, filename: filename, sizeBytes: sizeBytes)
        return try await request(
            path: "/v1/uploads/recording",
            method: "POST",
            body: payload,
            requiresAuth: true
        )
    }

    func uploadFile(uploadUrl: String, fileUrl: URL, contentType: String) async throws {
        var request = URLRequest(url: URL(string: uploadUrl)!)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: fileUrl)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard 200..<300 ~= http.statusCode else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            print("Upload error: \(http.statusCode) \(bodyText)")
            throw URLError(.badServerResponse)
        }
        print("Upload ok:", uploadUrl)
    }

    func createIdea(title: String? = nil, content: String) async throws -> EggIdeaDTO {
        struct Payload: Encodable {
            let title: String?
            let content: String
        }
        let response: IdeaItemResponse = try await request(
            path: "/v1/eggbook/ideas",
            method: "POST",
            body: Payload(title: title, content: content),
            requiresAuth: true
        )
        return response.item
    }

    func deleteIdea(id: String) async throws -> MessageResponse {
        return try await request(
            path: "/v1/eggbook/ideas/\(id)",
            method: "DELETE",
            body: Optional<Int>.none,
            requiresAuth: true
        )
    }

    private func request<T: Decodable, B: Encodable>(
        path: String,
        method: String,
        body: B?,
        requiresAuth: Bool
    ) async throws -> T {
        print("API request:", method, path)
        let url: URL
        if path.contains("?") {
            url = URL(string: baseURL.absoluteString + path) ?? baseURL.appendingPathComponent(path)
        } else {
            url = baseURL.appendingPathComponent(path)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if requiresAuth {
            if let token = loadToken() {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        }

        if let body {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            request.httpBody = try encoder.encode(body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard 200..<300 ~= http.statusCode else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            print("API error: \(http.statusCode) \(bodyText)")
            throw APIError.httpStatus(code: http.statusCode, body: bodyText)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(T.self, from: data)
        print("API ok:", method, path, "status:", http.statusCode)
        return decoded
    }

    private func shouldSelfHealDevice(error: APIError) -> Bool {
        guard case let .httpStatus(code, body) = error else { return false }
        guard code == 404 else { return false }
        return body.localizedCaseInsensitiveContains("Device not found")
    }

    private func saveToken(_ token: String) {
        if let data = token.data(using: .utf8) {
            KeychainHelper.save(data, service: tokenService, account: tokenAccount)
        }
    }

    private func loadToken() -> String? {
        guard let data = KeychainHelper.read(service: tokenService, account: tokenAccount) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func currentToken() -> String? {
        loadToken()
    }

    func realtimeWebSocketURL() -> URL? {
        guard let token = loadToken() else { return nil }
        let base = baseURL.appendingPathComponent("v1/realtime/ws")
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "wss"
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        return components.url
    }

    private func timeZoneLabel() -> String {
        let seconds = TimeZone.current.secondsFromGMT()
        let hours = seconds / 3600
        let sign = hours >= 0 ? "+" : "-"
        return "UTC\(sign)\(abs(hours))"
    }

    private func logWhoAmIBeforeEventMutation(action: String) async {
        guard let token = loadToken(), !token.isEmpty else {
            print("whoami skipped before", action, "- no token")
            return
        }
        let url = baseURL.appendingPathComponent("v1/auth/whoami")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                print("whoami failed before", action, "- invalid response")
                return
            }
            if 200..<300 ~= http.statusCode {
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                if let decoded = try? decoder.decode(WhoAmIResponse.self, from: data),
                   let userId = decoded.userId, !userId.isEmpty {
                    print("whoami before", action, "userId:", userId)
                } else {
                    let bodyText = String(data: data, encoding: .utf8) ?? ""
                    print("whoami before", action, "status:", http.statusCode, "body:", bodyText)
                }
            } else {
                let bodyText = String(data: data, encoding: .utf8) ?? ""
                print("whoami failed before", action, "status:", http.statusCode, "body:", bodyText)
            }
        } catch {
            print("whoami error before", action, ":", error.localizedDescription)
        }
    }
}

struct EggIdeaDTO: Decodable, Identifiable {
    let id: String
    let title: String?
    let content: String
    let createdAt: String
    let updatedAt: String
}

struct EggIdeasResponse: Decodable {
    let items: [EggIdeaDTO]
}
