import Foundation

/// A server origin, without credentials, API paths, queries or fragments.
public enum ServerAddress {
    public static func normalize(_ raw: String) throws -> URL {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              var parts = URLComponents(string: value),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.port.map({ (1...65535).contains($0) }) ?? true,
              validHost(host), let originalURL = parts.url
        else { throw SyncFailure.invalidAddress }
        // URLComponents accepts a dangling colon; do not silently turn it into the default port.
        let authority = value.components(separatedBy: "://").dropFirst().joined(separator: "://").split(separator: "/", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard !authority.hasSuffix(":"), originalURL.host != nil else { throw SyncFailure.invalidAddress }
        parts.scheme = scheme
        parts.host = host.lowercased()
        parts.path = ""
        if (scheme == "https" && parts.port == 443) || (scheme == "http" && parts.port == 80) { parts.port = nil }
        guard let result = parts.url else { throw SyncFailure.invalidAddress }
        return result
    }

    private static func validHost(_ host: String) -> Bool {
        if host.hasPrefix("[") && host.hasSuffix("]") {
            let address = String(host.dropFirst().dropLast())
            guard !address.isEmpty, !address.contains("%"), !address.contains(":::"), address.filter({ $0 == ":" }).count >= 2 else { return false }
            let halves = address.components(separatedBy: "::")
            guard halves.count <= 2 else { return false }
            let groups = address.split(separator: ":", omittingEmptySubsequences: true)
            guard groups.allSatisfy({ !$0.isEmpty && $0.count <= 4 && $0.allSatisfy(\.isHexDigit) }) else { return false }
            if halves.count == 2 { return groups.count < 8 }
            return !address.hasPrefix(":") && !address.hasSuffix(":") && groups.count == 8
        }
        guard host.count <= 253, !host.contains("%"), !host.contains(":") else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                && label.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
        }) else { return false }
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            return labels.count == 4 && labels.allSatisfy({ Int($0).map({ (0...255).contains($0) }) ?? false })
        }
        return true
    }
}

public struct SyncFailure: LocalizedError, Sendable, Equatable {
    public enum Kind: String, Sendable {
        case invalidAddress, offline, timedOut, cannotConnect, certificate, insecureConnection
        case unauthorized, forbidden, conflict, remoteStateRequired, rateLimited, serviceUnavailable, server, invalidResponse, cancelled, unknown
    }
    public let kind: Kind
    public let title: String
    public let message: String
    public let recoverySuggestion: String?
    public let isRetryable: Bool
    public let statusCode: Int?
    public let retryAfter: TimeInterval?
    public let serverCode: String?
    public var errorDescription: String? { message }

    public init(kind: Kind, title: String, message: String, recoverySuggestion: String, isRetryable: Bool = false, statusCode: Int? = nil, retryAfter: TimeInterval? = nil, serverCode: String? = nil) {
        self.kind = kind
        self.title = title
        self.message = message
        self.recoverySuggestion = recoverySuggestion
        self.isRetryable = isRetryable
        self.statusCode = statusCode
        self.retryAfter = retryAfter
        self.serverCode = serverCode
    }

    public static let invalidAddress = SyncFailure(kind: .invalidAddress, title: "服务器地址不正确", message: "请输入完整的 HTTP 或 HTTPS 服务器地址。", recoverySuggestion: "例如 https://library.example.com；地址中不要包含账号、密码、接口路径、查询参数或片段。")
    public static let invalidResponse = SyncFailure(kind: .invalidResponse, title: "服务响应格式不正确", message: "服务器没有返回可识别的文档库数据。", recoverySuggestion: "请检查服务器地址和服务版本，确认这里运行的是 TokenLibrary 服务。")
    public static let remoteStateRequired = SyncFailure(kind: .remoteStateRequired, title: "需要先读取云端合并结果", message: "云端已有本机尚未读取的合并结果，本机修改和提交记录已保留。", recoverySuggestion: "请连接此资料库并再次同步；客户端会读取云端内容，安全合并后继续，重叠修改可在冲突中心处理。", isRetryable: true)

    public static func from(_ error: Error) -> SyncFailure {
        if let failure = error as? SyncFailure { return failure }
        if let transfer = error as? TransferError {
            switch transfer {
            case .hashMismatch:
                return SyncFailure(kind: .invalidResponse, title: "附件校验失败", message: "附件内容与校验值不一致，未使用可能损坏的数据。", recoverySuggestion: "请再次同步；若持续失败，请检查云端附件或重新导入本机原文件。", isRetryable: true)
            case .missingFile, .invalidPath:
                return SyncFailure(kind: .unknown, title: "无法读取此库的附件", message: transfer.localizedDescription, recoverySuggestion: "请在当前资料库重新导入附件，或连接原资料库下载。")
            case .tooLarge:
                return SyncFailure(kind: .unknown, title: "附件超过大小限制", message: transfer.localizedDescription, recoverySuggestion: "请压缩文件或拆分为小于 50 MB 的附件后重新导入。")
            }
        }
        if error is SessionVaultError {
            return SyncFailure(kind: .unknown, title: "无法访问安全登录信息", message: "系统未允许读取或保存此登录会话。", recoverySuggestion: "请解锁设备后重新登录；本机资料仍然保留。")
        }
        if let storeError = error as? StoreError {
            switch storeError {
            case .operationContextChanged:
                return SyncFailure(kind: .conflict, title: "待同步操作属于另一连接", message: "服务器地址、文档库版本或设备身份与原请求不一致，已保留本机修改。", recoverySuggestion: "请使用原来的连接和设备身份重试；切换文档库前需要先处理待同步操作。")
            case .staleOperation:
                return SyncFailure(kind: .conflict, title: "本机操作已变化", message: "回执与本机待同步操作不一致，已保留本机修改。", recoverySuggestion: "请重新连接并检查待同步状态。")
            case .notFound: break
            }
        }
        if let legacy = error as? SyncError, case let .http(code, _) = legacy { return http(code: code) }
        if error is CancellationError {
            return SyncFailure(kind: .cancelled, title: "已取消", message: "连接操作已取消。", recoverySuggestion: "需要时可再次连接。")
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return from(CancellationError())
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
                return SyncFailure(kind: .offline, title: "当前没有网络", message: "无法连接网络，本机保存的数据不受影响。", recoverySuggestion: "连接 Wi-Fi 或允许蜂窝数据后重试。", isRetryable: true)
            case .timedOut:
                return SyncFailure(kind: .timedOut, title: "连接超时", message: "服务器未在规定时间内响应。", recoverySuggestion: "检查网络和服务器运行状态后重试。", isRetryable: true)
            case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .networkConnectionLost:
                return SyncFailure(kind: .cannotConnect, title: "无法连接服务器", message: "服务器暂时无法访问。", recoverySuggestion: "检查地址、端口和网络，确认服务器已启动后重试。", isRetryable: true)
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired:
                return SyncFailure(kind: .certificate, title: "安全连接失败", message: "无法验证服务器的 HTTPS 证书。", recoverySuggestion: "检查设备时间、服务器域名和证书配置，然后重新连接。")
            case .appTransportSecurityRequiresSecureConnection:
                return SyncFailure(kind: .insecureConnection, title: "需要安全连接", message: "系统阻止了当前 HTTP 连接。", recoverySuggestion: "请使用服务器的 HTTPS 地址。")
            case .badURL, .unsupportedURL:
                return invalidAddress
            case .badServerResponse, .cannotParseResponse, .cannotDecodeContentData, .cannotDecodeRawData:
                return invalidResponse
            default: break
            }
        }
        return SyncFailure(kind: .unknown, title: "连接未完成", message: "连接过程中发生了未知错误。", recoverySuggestion: "请重新连接；如果持续出现，请检查服务器状态。")
    }

    static func http(code: Int, retryAfter: TimeInterval? = nil, serverCode: String? = nil) -> SyncFailure {
        if code == 426 && serverCode == "PROTOCOL_UNSUPPORTED" {
            return SyncFailure(kind: .server, title: "客户端与服务器版本不兼容", message: "服务器不支持此客户端使用的同步协议。本机资料和待提交修改仍然保留。", recoverySuggestion: "更新客户端或服务器至相互兼容的版本后，再重新连接。", statusCode: code, retryAfter: retryAfter, serverCode: serverCode)
        }
        if code == 409 && serverCode == "NAME_CONFLICT" {
            return SyncFailure(kind: .conflict, title: "这个位置已有同名资料", message: "云端未保存此操作，本机内容已保留。", recoverySuggestion: "请为资料换一个名称或移到其他专题，再次同步。", statusCode: code, retryAfter: retryAfter, serverCode: serverCode)
        }
        if code == 422 && serverCode == "VALIDATION" {
            return SyncFailure(kind: .conflict, title: "资料信息需要调整", message: "名称、所属文件夹或附件不符合服务器要求，本机内容已保留。", recoverySuggestion: "请检查资料名称、目标文件夹和附件，修改后再次同步。", statusCode: code, retryAfter: retryAfter, serverCode: serverCode)
        }
        switch code {
        case 401:
            return SyncFailure(kind: .unauthorized, title: "需要重新登录", message: "账号密码不正确，或登录状态已失效。", recoverySuggestion: "检查账号和密码后重新登录。", statusCode: code, retryAfter: retryAfter, serverCode: serverCode)
        case 403:
            return SyncFailure(kind: .forbidden, title: "没有访问权限", message: "服务器拒绝了此次访问。", recoverySuggestion: "请确认当前账号具有访问此文档库的权限。", statusCode: code, retryAfter: retryAfter, serverCode: serverCode)
        case 409:
            return SyncFailure(kind: .conflict, title: "云端状态已变化", message: "当前操作与云端状态不一致。", recoverySuggestion: "重新连接并检查冲突后再操作。", statusCode: code, retryAfter: retryAfter, serverCode: serverCode)
        case 429:
            return SyncFailure(kind: .rateLimited, title: "请求过于频繁", message: "服务器暂时限制了请求频率。", recoverySuggestion: "请稍后重试。", isRetryable: true, statusCode: code, retryAfter: retryAfter, serverCode: serverCode)
        case 503:
            return SyncFailure(kind: .serviceUnavailable, title: "服务器暂时不可用", message: "服务可能正在启动、维护或备份，本机数据仍然保留。", recoverySuggestion: "等待服务恢复后重试。", isRetryable: true, statusCode: code, retryAfter: retryAfter, serverCode: serverCode)
        case 408, 500, 502, 504:
            return SyncFailure(kind: .server, title: "服务器暂时出错", message: "服务器暂时无法完成请求（HTTP \(code)）。", recoverySuggestion: "稍后重试；如持续出现，请检查服务器。", isRetryable: true, statusCode: code, retryAfter: retryAfter, serverCode: serverCode)
        default:
            return SyncFailure(kind: .server, title: "服务器拒绝了请求", message: "请求未成功（HTTP \(code)）。", recoverySuggestion: "检查服务器地址、服务版本和请求内容后再试。", statusCode: code, retryAfter: retryAfter, serverCode: serverCode)
        }
    }

    static func parseRetryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.allSatisfy(\.isNumber), let seconds = TimeInterval(value), seconds.isFinite { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

public struct SyncRetryPolicy: Sendable {
    public let maxAttempts: Int
    public let initialDelay: TimeInterval
    public let maxDelay: TimeInterval
    public init(maxAttempts: Int = 3, initialDelay: TimeInterval = 0.35, maxDelay: TimeInterval = 2) {
        self.maxAttempts = min(max(maxAttempts, 1), 5)
        self.initialDelay = initialDelay.isFinite ? min(max(initialDelay, 0), 10) : 0.35
        self.maxDelay = maxDelay.isFinite ? min(max(maxDelay, 0), 10) : 2
    }
    public static let none = SyncRetryPolicy(maxAttempts: 1)

    func delay(afterAttempt attempt: Int, failure: SyncFailure) -> TimeInterval? {
        guard failure.isRetryable, attempt < maxAttempts else { return nil }
        if let requested = failure.retryAfter {
            // A long maintenance window belongs in UI; never retry earlier than Retry-After.
            guard requested <= maxDelay else { return nil }
            return max(requested, min(initialDelay * pow(2, Double(attempt - 1)), maxDelay))
        }
        return min(initialDelay * pow(2, Double(attempt - 1)), maxDelay)
    }
}

public struct ServerReadiness: Codable, Sendable, Equatable {
    public let ready: Bool
    public let maintenance: Bool
}
