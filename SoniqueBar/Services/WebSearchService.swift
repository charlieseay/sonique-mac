import Foundation
import os.log

/// Provides web search fallback when Claude doesn't have current information
class WebSearchService {
    private let logger = Logger(subsystem: "com.seayniclabs.soniquebar", category: "WebSearchService")

    /// Search using DuckDuckGo Instant Answer API
    func search(query: String) async throws -> String {
        logger.info("[WebSearchService] Searching for: \(query.prefix(50))")

        // DuckDuckGo Instant Answer API (no auth required)
        guard var urlComponents = URLComponents(string: "https://api.duckduckgo.com/") else {
            throw SearchError.invalidURL
        }

        urlComponents.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "no_html", value: "1"),
            URLQueryItem(name: "skip_disambig", value: "1")
        ]

        guard let url = urlComponents.url else {
            throw SearchError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw SearchError.requestFailed
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SearchError.invalidResponse
        }

        // Extract relevant information
        var results: [String] = []

        if let abstract = json["Abstract"] as? String, !abstract.isEmpty {
            results.append("Summary: \(abstract)")
        }

        if let abstractURL = json["AbstractURL"] as? String, !abstractURL.isEmpty {
            results.append("Source: \(abstractURL)")
        }

        if let relatedTopics = json["RelatedTopics"] as? [[String: Any]] {
            for (index, topic) in relatedTopics.prefix(3).enumerated() {
                if let text = topic["Text"] as? String, !text.isEmpty {
                    results.append("Related (\(index + 1)): \(text)")
                }
            }
        }

        if results.isEmpty {
            throw SearchError.noResults
        }

        let formattedResults = results.joined(separator: "\n\n")
        logger.info("[WebSearchService] Found \(results.count) results")

        return formattedResults
    }

    /// Check if a Claude response indicates it needs web search
    static func needsWebSearch(_ response: String) -> Bool {
        let patterns = [
            "I don't have current information",
            "My knowledge cutoff",
            "I cannot access real-time",
            "As of my last update",
            "I don't have access to current"
        ]

        let lowercased = response.lowercased()
        return patterns.contains { lowercased.contains($0.lowercased()) }
    }

    enum SearchError: Error {
        case invalidURL
        case requestFailed
        case invalidResponse
        case noResults
    }
}
