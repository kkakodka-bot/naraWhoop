import Foundation
import WhoopStore
import NoopPush

@MainActor
final class ServerComputeSessionCoordinator: ObservableObject {
    @Published private(set) var results: [String: ServerCanonicalFamilyResult] = [:]
    @Published private(set) var pending: Set<String> = []
    @Published private(set) var lastError: String?
    private var pumping = false
    private var activeScope: ServerComputeOutbox.Scope?
    private var retryTask: Task<Void, Never>?

    func resume(model: AppModel) {
        guard retryTask == nil else { return }
        retryTask = Task { [weak self, weak model] in
            while !Task.isCancelled {
                guard let self, let model else { return }
                await self.drain(model: model)
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func enqueue(request: ServerComputeRequest, model: AppModel) async {
        guard model.isAccountRuntimeActive, let context = CloudRuntimeIdentity.snapshot().context else { return }
        let local = model.repo.deviceId
        let source = CloudPushSettings.sourceId(scope: context.scope)
        guard let store = await model.repo.storeHandle(), model.isAccountRuntimeActive,
              CloudRuntimeIdentity.snapshot().context == context else {
            lastError = "Session storage is unavailable. Raw capture continues."
            return
        }
        do {
            try ServerComputeOutbox.saveDraft(request, scope: .init(project: context.scope.projectURL,
                owner: context.scope.userID, source: source, localDevice: local), db: store.registryWriter)
            pending.insert(request.id)
            resume(model: model)
            await drain(model: model)
        } catch { lastError = "Session request could not be saved; raw capture is retained." }
    }

    func drain(model: AppModel) async {
        guard !pumping, model.isAccountRuntimeActive, let context = CloudRuntimeIdentity.snapshot().context else { return }
        let local = model.repo.deviceId
        let source = CloudPushSettings.sourceId(scope: context.scope)
        guard let canonical = CanonicalScoreTransport.canonicalDevice(owner: context.scope.userID, localDevice: local),
              let store = await model.repo.storeHandle(), model.isAccountRuntimeActive,
              CloudRuntimeIdentity.snapshot().context == context else { return }
        let scope = ServerComputeOutbox.Scope(project: context.scope.projectURL, owner: context.scope.userID, source: source, device: canonical)
        if activeScope != scope { activeScope = scope; results = [:]; pending = [] }
        pumping = true; defer { pumping = false }
        do {
            let outbox = try ServerComputeOutbox(db: store.registryWriter, scope: scope)
            try outbox.bindDrafts(.init(project: context.scope.projectURL, owner: context.scope.userID, source: source, localDevice: local))
            results = try outbox.results()
            let items = try outbox.pending()
            pending = Set(items.map { $0.request.id })
            let identity = try await CanonicalScoreTransport.capture()
            for item in items {
                guard identity.isCurrent, model.isAccountRuntimeActive, model.repo.deviceId == local,
                      identity.context == context, activeScope == scope else { return }
                let request = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item.request))
                _ = try await CanonicalScoreTransport.request(identity: identity, path: "/compute-requests",
                    body: JSONSerialization.data(withJSONObject: ["deviceId": local, "request": request]))
                let bytes = try await CanonicalScoreTransport.request(identity: identity, path: "/compute-requests",
                    query: [.init(name: "deviceId", value: local), .init(name: "requestId", value: item.request.id)])
                guard identity.isCurrent, model.isAccountRuntimeActive, model.repo.deviceId == local,
                      activeScope == scope, !Task.isCancelled else { return }
                let response = try JSONDecoder().decode(Response.self, from: bytes)
                guard response.requestID == item.request.id else { throw ServerComputeOutbox.Failure.scope }
                if let result = response.result {
                    try outbox.accept(result, for: item)
                    results[item.request.id] = result
                    pending.remove(item.request.id)
                }
            }
            lastError = nil
        } catch { lastError = "Server session result pending. Capture and upload continue." }
    }
    private struct Response: Decodable {
        let requestID: String
        let result: ServerCanonicalFamilyResult?
        enum CodingKeys: String, CodingKey { case requestID = "request_id", result }
    }
    func retire() { retryTask?.cancel(); retryTask = nil; activeScope = nil; results = [:]; pending = []; lastError = nil }
}
