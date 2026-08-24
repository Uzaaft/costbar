import Foundation

enum ProviderAPIError: Error, LocalizedError {
    case invalidAccountID
    case invalidOrganization
    case invalidResponse
    case httpStatus(provider: String, status: Int)

    var errorDescription: String? {
        switch self {
        case .invalidAccountID:
            "The Cloudflare account ID is invalid."
        case .invalidOrganization:
            "The GitHub organization name is invalid."
        case .invalidResponse:
            "A provider returned an invalid HTTP response."
        case let .httpStatus(provider, status):
            "\(provider) returned HTTP \(status)."
        }
    }
}

@MainActor
struct ProviderAPIClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func refreshDigitalOcean(token: String, core: CostbarCore) async throws {
        let baseURL = URL(string: "https://api.digitalocean.com/v2")!
        async let balance = get(
            baseURL.appending(path: "customers/my/balance"),
            bearerToken: token,
            provider: "DigitalOcean"
        )
        async let droplets = getAllDigitalOceanDroplets(
            baseURL: baseURL,
            bearerToken: token
        )
        async let invoice = getDigitalOceanInvoiceItems(
            baseURL: baseURL,
            bearerToken: token
        )
        let (balanceData, dropletsData) = try await (balance, droplets)
        let invoiceData = await invoice
        let receivedAt = Date.now
        try core.ingest(
            providerID: "digitalocean",
            documentID: "balance",
            data: balanceData,
            receivedAt: receivedAt
        )
        try core.ingest(
            providerID: "digitalocean",
            documentID: "droplets",
            data: dropletsData,
            receivedAt: receivedAt
        )
        if let invoiceData {
            try core.ingest(
                providerID: "digitalocean",
                documentID: "invoice",
                data: invoiceData,
                receivedAt: receivedAt
            )
        }
    }

    /// The current month has no invoice yet, so DigitalOcean exposes it as the
    /// `invoice_preview` of the invoice list. Its items are what attribute spend
    /// to Droplets, Apps, and Spaces; the balance endpoint only has a total.
    ///
    /// Best effort: a token without the billing scope still produces a report.
    private func getDigitalOceanInvoiceItems(
        baseURL: URL,
        bearerToken: String
    ) async -> Data? {
        do {
            let listData = try await get(
                baseURL.appending(path: "customers/my/invoices").appending(
                    queryItems: [URLQueryItem(name: "per_page", value: "1")]
                ),
                bearerToken: bearerToken,
                provider: "DigitalOcean"
            )
            guard let list = try JSONSerialization.jsonObject(with: listData) as? [String: Any],
                  let preview = list["invoice_preview"] as? [String: Any],
                  let invoiceUUID = preview["invoice_uuid"] as? String,
                  isInvoiceUUID(invoiceUUID)
            else {
                return nil
            }

            var items: [[String: Any]] = []
            var nextURL: URL? = baseURL
                .appending(path: "customers/my/invoices/\(invoiceUUID)")
                .appending(queryItems: [
                    URLQueryItem(name: "page", value: "1"),
                    URLQueryItem(name: "per_page", value: "200"),
                ])
            var pageCount = 0

            while let pageURL = nextURL {
                pageCount += 1
                guard pageCount <= 100 else { throw ProviderAPIError.invalidResponse }
                let data = try await get(
                    pageURL,
                    bearerToken: bearerToken,
                    provider: "DigitalOcean"
                )
                guard let page = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let pageItems = page["invoice_items"] as? [[String: Any]]
                else {
                    throw ProviderAPIError.invalidResponse
                }
                items.append(contentsOf: pageItems)
                nextURL = try digitalOceanNextPage(in: page)
            }

            return try JSONSerialization.data(withJSONObject: ["invoice_items": items])
        } catch {
            return nil
        }
    }

    /// An invoice UUID is interpolated into a URL that carries the API token, so
    /// it is never allowed to contain anything but UUID characters.
    private func isInvoiceUUID(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 64
            && value.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    private func digitalOceanNextPage(in root: [String: Any]) throws -> URL? {
        let pages = (root["links"] as? [String: Any])?["pages"] as? [String: Any]
        guard let next = pages?["next"] as? String, !next.isEmpty else { return nil }
        // Never forward a bearer token to a host supplied by a response.
        guard let candidate = URL(string: next),
              candidate.scheme == "https",
              candidate.host == "api.digitalocean.com"
        else {
            throw ProviderAPIError.invalidResponse
        }
        return candidate
    }

    private func getAllDigitalOceanDroplets(
        baseURL: URL,
        bearerToken: String
    ) async throws -> Data {
        var nextURL: URL? = baseURL.appending(path: "droplets").appending(queryItems: [
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "per_page", value: "200"),
        ])
        var droplets: [[String: Any]] = []
        var pageCount = 0

        while let pageURL = nextURL {
            pageCount += 1
            guard pageCount <= 100 else { throw ProviderAPIError.invalidResponse }
            let data = try await get(
                pageURL,
                bearerToken: bearerToken,
                provider: "DigitalOcean"
            )
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pageDroplets = root["droplets"] as? [[String: Any]]
            else {
                throw ProviderAPIError.invalidResponse
            }
            droplets.append(contentsOf: pageDroplets)
            nextURL = try digitalOceanNextPage(in: root)
        }

        return try JSONSerialization.data(withJSONObject: ["droplets": droplets])
    }

    func refreshCloudflare(
        token: String,
        accountID: String,
        core: CostbarCore
    ) async throws {
        guard accountID.count == 32,
              accountID.allSatisfy(\.isHexDigit)
        else {
            throw ProviderAPIError.invalidAccountID
        }
        let url = URL(string: "https://api.cloudflare.com/client/v4/accounts")!
            .appending(path: accountID)
            .appending(path: "subscriptions")
        async let accountSubscriptions = get(
            url,
            bearerToken: token,
            provider: "Cloudflare"
        )
        async let zonePlans = getCloudflareZones(accountID: accountID, token: token)

        let subscriptions = try await accountSubscriptions
        let zones = await zonePlans
        let receivedAt = Date.now
        try core.ingest(
            providerID: "cloudflare",
            documentID: "subscriptions",
            data: subscriptions,
            receivedAt: receivedAt
        )
        if let zones {
            try core.ingest(
                providerID: "cloudflare",
                documentID: "zones",
                data: zones,
                receivedAt: receivedAt
            )
        }
    }

    /// Plan tiers (Free, Pro, Business) are billed per zone and never appear in
    /// the account subscriptions feed.
    ///
    /// Best effort: a token without Zone Read still reports its subscriptions.
    private func getCloudflareZones(accountID: String, token: String) async -> Data? {
        do {
            var zones: [[String: Any]] = []
            var page = 1

            while page <= 20 {
                let url = URL(string: "https://api.cloudflare.com/client/v4/zones")!
                    .appending(queryItems: [
                        URLQueryItem(name: "account.id", value: accountID),
                        URLQueryItem(name: "per_page", value: "50"),
                        URLQueryItem(name: "page", value: String(page)),
                    ])
                let data = try await get(url, bearerToken: token, provider: "Cloudflare")
                guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      root["success"] as? Bool == true,
                      let pageZones = root["result"] as? [[String: Any]]
                else {
                    return nil
                }
                zones.append(contentsOf: pageZones)

                let info = root["result_info"] as? [String: Any]
                guard let totalPages = info?["total_pages"] as? Int, page < totalPages else {
                    break
                }
                page += 1
            }

            return try JSONSerialization.data(withJSONObject: [
                "success": true,
                "result": zones,
            ])
        } catch {
            return nil
        }
    }

    func refreshRunpod(
        apiKey: String,
        period: Dashboard.Period,
        core: CostbarCore
    ) async throws {
        let accountURL = URL(string: "https://api.runpod.io/graphql")!
        let query = """
        query CostbarAccount {
          myself {
            clientBalance
            currentSpendPerHr
          }
        }
        """
        async let account = postJSON(
            accountURL,
            body: ["query": query],
            bearerToken: apiKey,
            provider: "Runpod"
        )
        async let pods = get(
            runpodBillingURL(resource: "pods", period: period),
            bearerToken: apiKey,
            provider: "Runpod"
        )
        async let endpoints = get(
            runpodBillingURL(resource: "endpoints", period: period),
            bearerToken: apiKey,
            provider: "Runpod"
        )
        async let networkVolumes = get(
            runpodBillingURL(resource: "networkvolumes", period: period),
            bearerToken: apiKey,
            provider: "Runpod"
        )

        let documents = try await (account, pods, endpoints, networkVolumes)
        let snapshot = try JSONSerialization.data(withJSONObject: [
            "account": try JSONSerialization.jsonObject(with: documents.0),
            "pods": try JSONSerialization.jsonObject(with: documents.1),
            "endpoints": try JSONSerialization.jsonObject(with: documents.2),
            "networkVolumes": try JSONSerialization.jsonObject(with: documents.3),
        ])
        try core.ingest(
            providerID: "runpod",
            documentID: "snapshot",
            data: snapshot
        )
    }

    func refreshVercel(
        token: String,
        teamIDOrSlug: String?,
        period: Dashboard.Period,
        core: CostbarCore
    ) async throws {
        let charges = try await get(
            vercelBillingURL(
                teamIDOrSlug: teamIDOrSlug,
                period: period
            ),
            bearerToken: token,
            provider: "Vercel",
            accept: "application/x-ndjson, application/json"
        )
        try core.ingest(
            providerID: "vercel",
            documentID: "charges",
            data: charges
        )
    }

    func refreshOpenRouter(
        apiKey: String,
        managementKey: String?,
        period: Dashboard.Period,
        core: CostbarCore
    ) async throws {
        let baseURL = URL(string: "https://openrouter.ai/api/v1")!
        let keyData = try await get(
            baseURL.appending(path: "key"),
            bearerToken: apiKey,
            provider: "OpenRouter"
        )

        var snapshot: [String: Any] = [
            "key": try JSONSerialization.jsonObject(with: keyData),
            "activity_period": [
                "start_unix": period.startUnix,
                "end_exclusive_unix": period.endExclusiveUnix,
            ],
        ]
        if let managementKey = managementKey?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !managementKey.isEmpty {
            async let credits = try? get(
                baseURL.appending(path: "credits"),
                bearerToken: managementKey,
                provider: "OpenRouter"
            )
            async let activity = try? get(
                baseURL.appending(path: "activity"),
                bearerToken: managementKey,
                provider: "OpenRouter"
            )
            let (creditsData, activityData) = await (credits, activity)
            if let creditsData {
                snapshot["credits"] = try JSONSerialization.jsonObject(with: creditsData)
            }
            if let activityData {
                snapshot["activity"] = try openRouterActivity(
                    in: activityData,
                    period: period
                )
            }
        }

        try core.ingest(
            providerID: "openrouter",
            documentID: "snapshot",
            data: try JSONSerialization.data(withJSONObject: snapshot)
        )
    }

    func refreshOpenAIOrganization(
        adminKey: String,
        period: Dashboard.Period,
        core: CostbarCore
    ) async throws {
        let costs = try await openAIPages(
            path: "organization/costs",
            queryItems: openAIReportQuery(
                period: period,
                groupBy: ["project_id", "line_item"],
                limit: 180
            ),
            adminKey: adminKey
        )
        let usage = try await openAIPages(
            path: "organization/usage/completions",
            queryItems: openAIReportQuery(period: period, groupBy: ["model"], limit: 31),
            adminKey: adminKey
        )
        let snapshot = try JSONSerialization.data(withJSONObject: [
            "period": periodJSONObject(period),
            "cost_pages": costs,
            "usage_pages": usage,
        ])
        try core.ingest(
            providerID: "openai-api",
            documentID: "organization",
            data: snapshot
        )
    }

    func refreshAnthropicOrganization(
        adminKey: String,
        period: Dashboard.Period,
        core: CostbarCore
    ) async throws {
        let costs = try await anthropicPages(
            path: "organizations/cost_report",
            queryItems: anthropicReportQuery(
                period: period,
                groupBy: ["workspace_id", "description"]
            ),
            adminKey: adminKey
        )
        let usage = try await anthropicPages(
            path: "organizations/usage_report/messages",
            queryItems: anthropicReportQuery(period: period, groupBy: ["model"]),
            adminKey: adminKey
        )
        let snapshot = try JSONSerialization.data(withJSONObject: [
            "period": periodJSONObject(period),
            "cost_pages": costs,
            "usage_pages": usage,
        ])
        try core.ingest(
            providerID: "anthropic-api",
            documentID: "organization",
            data: snapshot
        )
    }

    func refreshGitHub(
        token: String,
        organization: String,
        period: Dashboard.Period,
        core: CostbarCore
    ) async throws {
        let organization = organization.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !organization.isEmpty, organization.count <= 100,
              organization.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
        else { throw ProviderAPIError.invalidOrganization }

        let date = Date(timeIntervalSince1970: TimeInterval(period.startUnix))
        let components = Calendar.current.dateComponents([.year, .month], from: date)
        guard let year = components.year, let month = components.month else {
            throw ProviderAPIError.invalidResponse
        }
        let url = URL(string: "https://api.github.com/organizations")!
            .appending(path: organization)
            .appending(path: "settings/billing/usage")
            .appending(queryItems: [
                URLQueryItem(name: "year", value: String(year)),
                URLQueryItem(name: "month", value: String(month)),
            ])
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        let data = try await send(request, bearerToken: token, provider: "GitHub")
        try core.ingest(
            providerID: "github",
            documentID: "billing-usage",
            data: data
        )
    }

    func refreshCursor(
        adminKey: String,
        period: Dashboard.Period,
        core: CostbarCore
    ) async throws {
        let url = URL(string: "https://api.cursor.com/teams/filtered-usage-events")!
        var pages: [[String: Any]] = []
        var pageNumber = 1
        var hasNextPage = true
        while hasNextPage {
            guard pageNumber <= 100 else { throw ProviderAPIError.invalidResponse }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let credential = Data("\(adminKey):".utf8).base64EncodedString()
            request.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "startDate": period.startUnix * 1_000,
                "endDate": reportEnd(period) * 1_000,
                "page": pageNumber,
                "pageSize": 500,
            ])
            let data = try await sendAuthenticatedRequest(request, provider: "Cursor")
            guard let page = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  page["usageEvents"] is [[String: Any]]
            else { throw ProviderAPIError.invalidResponse }
            pages.append(page)
            if let pagination = page["pagination"] as? [String: Any],
               let explicit = pagination["hasNextPage"] as? Bool {
                hasNextPage = explicit
            } else if let totalPages = page["totalPages"] as? Int {
                hasNextPage = pageNumber < totalPages
            } else {
                hasNextPage = false
            }
            pageNumber += 1
        }
        let snapshot = try JSONSerialization.data(withJSONObject: [
            "period": periodJSONObject(period),
            "pages": pages,
        ])
        try core.ingest(
            providerID: "cursor",
            documentID: "usage-events",
            data: snapshot
        )
    }

    private func openAIPages(
        path: String,
        queryItems: [URLQueryItem],
        adminKey: String
    ) async throws -> [[String: Any]] {
        let baseURL = URL(string: "https://api.openai.com/v1")!.appending(path: path)
        var pages: [[String: Any]] = []
        var cursor: String?
        repeat {
            guard pages.count < 100 else { throw ProviderAPIError.invalidResponse }
            var pageQuery = queryItems
            if let cursor { pageQuery.append(URLQueryItem(name: "page", value: cursor)) }
            let data = try await get(
                baseURL.appending(queryItems: pageQuery),
                bearerToken: adminKey,
                provider: "OpenAI"
            )
            guard let page = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  page["data"] is [[String: Any]]
            else { throw ProviderAPIError.invalidResponse }
            pages.append(page)
            cursor = page["has_more"] as? Bool == true ? page["next_page"] as? String : nil
            if page["has_more"] as? Bool == true, cursor == nil {
                throw ProviderAPIError.invalidResponse
            }
        } while cursor != nil
        return pages
    }

    private func anthropicPages(
        path: String,
        queryItems: [URLQueryItem],
        adminKey: String
    ) async throws -> [[String: Any]] {
        let baseURL = URL(string: "https://api.anthropic.com/v1")!.appending(path: path)
        var pages: [[String: Any]] = []
        var cursor: String?
        repeat {
            guard pages.count < 100 else { throw ProviderAPIError.invalidResponse }
            var pageQuery = queryItems
            if let cursor { pageQuery.append(URLQueryItem(name: "page", value: cursor)) }
            var request = URLRequest(url: baseURL.appending(queryItems: pageQuery))
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue(adminKey, forHTTPHeaderField: "x-api-key")
            let data = try await sendAuthenticatedRequest(request, provider: "Anthropic")
            guard let page = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  page["data"] is [[String: Any]]
            else { throw ProviderAPIError.invalidResponse }
            pages.append(page)
            cursor = page["has_more"] as? Bool == true ? page["next_page"] as? String : nil
            if page["has_more"] as? Bool == true, cursor == nil {
                throw ProviderAPIError.invalidResponse
            }
        } while cursor != nil
        return pages
    }

    private func openAIReportQuery(
        period: Dashboard.Period,
        groupBy: [String],
        limit: Int
    ) -> [URLQueryItem] {
        [
            URLQueryItem(name: "start_time", value: String(period.startUnix)),
            URLQueryItem(name: "end_time", value: String(reportEnd(period))),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: String(limit)),
        ] + groupBy.map { URLQueryItem(name: "group_by[]", value: $0) }
    }

    private func anthropicReportQuery(
        period: Dashboard.Period,
        groupBy: [String]
    ) -> [URLQueryItem] {
        let formatter = ISO8601DateFormatter()
        return [
            URLQueryItem(
                name: "starting_at",
                value: formatter.string(from: Date(
                    timeIntervalSince1970: TimeInterval(period.startUnix)
                ))
            ),
            URLQueryItem(
                name: "ending_at",
                value: formatter.string(from: Date(
                    timeIntervalSince1970: TimeInterval(reportEnd(period))
                ))
            ),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: "31"),
        ] + groupBy.map { URLQueryItem(name: "group_by[]", value: $0) }
    }

    private func reportEnd(_ period: Dashboard.Period, now: Date = .now) -> Int64 {
        min(max(Int64(now.timeIntervalSince1970), period.startUnix + 1), period.endExclusiveUnix)
    }

    private func periodJSONObject(_ period: Dashboard.Period) -> [String: Int64] {
        [
            "start_unix": period.startUnix,
            "end_exclusive_unix": period.endExclusiveUnix,
        ]
    }

    private func openRouterActivity(
        in data: Data,
        period: Dashboard.Period
    ) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["data"] as? [[String: Any]]
        else {
            throw ProviderAPIError.invalidResponse
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let start = Date(timeIntervalSince1970: TimeInterval(period.startUnix))
        let end = Date(timeIntervalSince1970: TimeInterval(period.endExclusiveUnix))
        return [
            "data": entries.filter { entry in
                guard let value = entry["date"] as? String,
                      let date = formatter.date(from: value)
                else {
                    return false
                }
                return date >= start && date < end
            },
        ]
    }

    private func vercelBillingURL(
        teamIDOrSlug: String?,
        period: Dashboard.Period,
        now: Date = .now
    ) -> URL {
        let start = Date(timeIntervalSince1970: TimeInterval(period.startUnix))
        let periodEnd = Date(timeIntervalSince1970: TimeInterval(period.endExclusiveUnix))
        let end = min(max(now, start), periodEnd)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var queryItems = [
            URLQueryItem(name: "from", value: formatter.string(from: start)),
            URLQueryItem(name: "to", value: formatter.string(from: end)),
        ]
        if let scope = teamIDOrSlug?.trimmingCharacters(in: .whitespacesAndNewlines),
           !scope.isEmpty {
            queryItems.append(URLQueryItem(
                name: scope.hasPrefix("team_") ? "teamId" : "slug",
                value: scope
            ))
        }

        return URL(string: "https://api.vercel.com/v1/billing/charges")!
            .appending(queryItems: queryItems)
    }

    private func runpodBillingURL(
        resource: String,
        period: Dashboard.Period,
        now: Date = .now
    ) -> URL {
        let start = Date(timeIntervalSince1970: TimeInterval(period.startUnix))
        let periodEnd = Date(timeIntervalSince1970: TimeInterval(period.endExclusiveUnix))
        let end = min(max(now, start), periodEnd)
        let formatter = ISO8601DateFormatter()

        return URL(string: "https://rest.runpod.io/v1/billing")!
            .appending(path: resource)
            .appending(queryItems: [
                URLQueryItem(name: "startTime", value: formatter.string(from: start)),
                URLQueryItem(name: "endTime", value: formatter.string(from: end)),
                URLQueryItem(name: "bucketSize", value: "month"),
            ])
    }

    private func postJSON(
        _ url: URL,
        body: [String: Any],
        bearerToken: String,
        provider: String
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(
            request,
            bearerToken: bearerToken,
            provider: provider
        )
    }

    private func get(
        _ url: URL,
        bearerToken: String,
        provider: String,
        accept: String = "application/json"
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(accept, forHTTPHeaderField: "Accept")
        return try await send(
            request,
            bearerToken: bearerToken,
            provider: provider
        )
    }

    private func send(
        _ input: URLRequest,
        bearerToken: String,
        provider: String
    ) async throws -> Data {
        var request = input
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        if request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        return try await sendAuthenticatedRequest(request, provider: provider)
    }

    private func sendAuthenticatedRequest(
        _ input: URLRequest,
        provider: String
    ) async throws -> Data {
        var request = input
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderAPIError.httpStatus(provider: provider, status: http.statusCode)
        }
        return data
    }
}
