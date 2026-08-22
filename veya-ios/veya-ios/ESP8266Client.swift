import Foundation

struct ESP8266Client {
    func health(host: String) async throws -> ESP8266Status {
        try await request(host: host, path: "/health")
    }

    func state(host: String) async throws -> ESP8266Status {
        try await request(host: host, path: "/state")
    }

    func move(host: String, motor1: Double, motor2: Double) async throws -> ESP8266Status {
        let queryItems = [
            URLQueryItem(name: "m1", value: motor1.formatted(.number.precision(.fractionLength(2)))),
            URLQueryItem(name: "m2", value: motor2.formatted(.number.precision(.fractionLength(2))))
        ]
        return try await request(host: host, path: "/move", queryItems: queryItems)
    }

    func jog(host: String, delta1: Double, delta2: Double) async throws -> ESP8266Status {
        let queryItems = [
            URLQueryItem(name: "dm1", value: delta1.formatted(.number.precision(.fractionLength(2)))),
            URLQueryItem(name: "dm2", value: delta2.formatted(.number.precision(.fractionLength(2))))
        ]
        return try await request(host: host, path: "/jog", queryItems: queryItems)
    }

    func preset(host: String, name: String) async throws -> ESP8266Status {
        try await request(host: host, path: "/preset", queryItems: [
            URLQueryItem(name: "name", value: name)
        ])
    }

    func zero(host: String) async throws -> ESP8266Status {
        try await request(host: host, path: "/zero")
    }

    private func request(host: String, path: String, queryItems: [URLQueryItem] = []) async throws -> ESP8266Status {
        let url = try makeURL(host: host, path: path, queryItems: queryItems)
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "unknown error"
            throw NSError(domain: "Veya.ESP8266Client", code: httpResponse.statusCode, userInfo: [
                NSLocalizedDescriptionKey: body
            ])
        }

        return try JSONDecoder().decode(ESP8266Status.self, from: data)
    }

    private func makeURL(host: String, path: String, queryItems: [URLQueryItem]) throws -> URL {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixed = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") ? trimmed : "http://\(trimmed)"

        guard var components = URLComponents(string: prefixed) else {
            throw URLError(.badURL)
        }

        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components.url else {
            throw URLError(.badURL)
        }

        return url
    }
}

