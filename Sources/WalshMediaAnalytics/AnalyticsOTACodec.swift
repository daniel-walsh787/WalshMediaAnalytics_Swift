import Foundation

enum AnalyticsOTACodec {
    static func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func jsonDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    static func normalizedFilePath(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func isSafeFilePath(_ raw: String) -> Bool {
        let normalized = normalizedFilePath(raw)
        guard !normalized.isEmpty else { return false }
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && !part.contains(":")
        }
    }

    /// Quote an etag for `If-None-Match` as `{etag}` without double-wrapping.
    static func ifNoneMatch(_ etag: String) -> String? {
        let trimmed = etag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("W/\"") || (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) {
            return trimmed
        }
        return "\"\(trimmed)\""
    }

    static func normalizedEtag(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("W/") {
            value.removeFirst(2)
        }
        if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }
        return value.isEmpty ? nil : value
    }

    static func etagsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = normalizedEtag(lhs), let rhs = normalizedEtag(rhs) else { return false }
        return lhs == rhs
    }

    static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
        }
        if let message = object["message"] as? String, !message.isEmpty { return message }
        if let error = object["error"] as? String, !error.isEmpty { return error }
        return nil
    }

    static func needsHMAC(url: URL, appId: String) -> Bool {
        let parts = url.path.split(separator: "/").map(String.init)
        // Protected: /v1/config/{appSlug}/files/…
        // Public:     /v1/config/{tenantSlug}/{appSlug}/files/…
        guard parts.count >= 4, parts[0] == "v1", parts[1] == "config" else { return false }
        return parts[2] == appId && parts[3] == "files"
    }

    static func signedPath(for url: URL) -> String {
        if let encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
           !encoded.isEmpty {
            return encoded
        }
        let path = url.path
        return path.hasPrefix("/") ? path : "/" + path
    }

    static func resolveURL(_ raw: String, baseURL: URL) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let absolute = URL(string: trimmed), absolute.scheme != nil {
            return absolute
        }
        return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
    }

    static func decodeManifest(_ data: Data, appId: String, baseURL: URL) throws -> AnalyticsOTASnapshot {
        let dto = try jsonDecoder().decode(ManifestDTO.self, from: data)
        let flags = AnalyticsOTAFlags(values: dto.flags ?? [:])
        let files = try files(
            from: dto.files,
            appId: appId,
            tenantSlug: dto.resolvedTenantSlug,
            baseURL: baseURL
        )
        return AnalyticsOTASnapshot(
            tenantSlug: dto.resolvedTenantSlug,
            flags: flags,
            files: files
        )
    }

    static func decodeFlags(_ data: Data) throws -> AnalyticsOTAFlags {
        if let dto = try? jsonDecoder().decode(FlagsDTO.self, from: data),
           dto.flags != nil || dto.values != nil {
            return AnalyticsOTAFlags(values: dto.flags ?? dto.values ?? [:])
        }
        if let values = try? jsonDecoder().decode([String: AnalyticsOTAValue].self, from: data) {
            return AnalyticsOTAFlags(values: values)
        }
        throw AnalyticsOTAError.invalidResponse
    }

    private static func files(
        from dto: FilesDTO?,
        appId: String,
        tenantSlug: String?,
        baseURL: URL
    ) throws -> [AnalyticsOTAFile] {
        guard let dto else { return [] }
        switch dto {
        case .list(let items):
            return items.compactMap { file(from: $0, fallbackPath: nil, appId: appId, tenantSlug: tenantSlug, baseURL: baseURL) }
        case .map(let map):
            return map.keys.sorted().compactMap { key in
                file(from: map[key], fallbackPath: key, appId: appId, tenantSlug: tenantSlug, baseURL: baseURL)
            }
        }
    }

    private static func file(
        from dto: FileDTO?,
        fallbackPath: String?,
        appId: String,
        tenantSlug: String?,
        baseURL: URL
    ) -> AnalyticsOTAFile? {
        guard let dto else { return nil }
        let path = normalizedFilePath(dto.path ?? fallbackPath ?? "")
        guard isSafeFilePath(path), let etag = normalizedEtag(dto.etag ?? dto.eTag), !etag.isEmpty else {
            return nil
        }
        let url = dto.url.flatMap { resolveURL($0, baseURL: baseURL) }
            ?? constructedFileURL(path: path, appId: appId, tenantSlug: tenantSlug, isProtected: dto.isProtected, baseURL: baseURL)
        guard let url else { return nil }
        let isProtected = dto.isProtected ?? needsHMAC(url: url, appId: appId)
        return AnalyticsOTAFile(
            path: path,
            etag: etag,
            url: url,
            isProtected: isProtected,
            contentType: dto.content_type ?? dto.contentType ?? dto.mimeType,
            size: dto.size
        )
    }

    static func constructedFileURL(
        path: String,
        appId: String,
        tenantSlug: String?,
        isProtected: Bool?,
        baseURL: URL
    ) -> URL? {
        let encodedApp = AnalyticsIngestCodec.encodeURIComponent(appId)
        let encodedPath = normalizedFilePath(path)
            .split(separator: "/")
            .map { AnalyticsIngestCodec.encodeURIComponent(String($0)) }
            .joined(separator: "/")
        let relative: String
        if isProtected == false, let tenantSlug, !tenantSlug.isEmpty {
            let encodedTenant = AnalyticsIngestCodec.encodeURIComponent(tenantSlug)
            relative = "/v1/config/\(encodedTenant)/\(encodedApp)/files/\(encodedPath)"
        } else {
            relative = "/v1/config/\(encodedApp)/files/\(encodedPath)"
        }
        return URL(string: relative, relativeTo: baseURL)?.absoluteURL
    }

    static func configURL(baseURL: URL, appId: String, suffix: String) -> URL? {
        let encodedApp = AnalyticsIngestCodec.encodeURIComponent(appId)
        return URL(string: "/v1/config/\(encodedApp)/\(suffix)", relativeTo: baseURL)?.absoluteURL
    }
}

extension AnalyticsOTACodec {
    struct ManifestDTO: Decodable {
        var tenant_slug: String?
        var tenantSlug: String?
        var app: String?
        var app_slug: String?
        var appSlug: String?
        var flags: [String: AnalyticsOTAValue]?
        var files: FilesDTO?

        var resolvedTenantSlug: String? {
            let raw = tenant_slug ?? tenantSlug
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    struct FlagsDTO: Decodable {
        var flags: [String: AnalyticsOTAValue]?
        var values: [String: AnalyticsOTAValue]?
    }

    enum FilesDTO: Decodable {
        case list([FileDTO])
        case map([String: FileDTO])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let list = try? container.decode([FileDTO].self) {
                self = .list(list)
                return
            }
            if let map = try? container.decode([String: FileDTO].self) {
                self = .map(map)
                return
            }
            self = .list([])
        }
    }

    struct FileDTO: Decodable {
        var path: String?
        var etag: String?
        var eTag: String?
        var url: String?
        var protected: Bool?
        var visibility: String?
        var content_type: String?
        var contentType: String?
        var mimeType: String?
        var size: Int?

        var isProtected: Bool? {
            if let protected { return protected }
            guard let visibility else { return nil }
            switch visibility.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "protected":
                return true
            case "public":
                return false
            default:
                return nil
            }
        }
    }
}

extension AnalyticsOTAValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Int.self) {
            self = .int(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .double(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode([AnalyticsOTAValue].self) {
            self = .array(value)
            return
        }
        if let value = try? container.decode([String: AnalyticsOTAValue].self) {
            self = .object(value)
            return
        }
        throw DecodingError.typeMismatch(
            AnalyticsOTAValue.self,
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported OTA flag JSON")
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}
