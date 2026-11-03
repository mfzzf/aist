import AistAI
import Foundation

enum WebError: LocalizedError {
    case http(Int)
    case unreadable(String)
    var errorDescription: String? {
        switch self {
        case let .http(code): "网页返回 HTTP \(code)"
        case let .unreadable(why): why
        }
    }
}

/// A browser-like UA: several sites (and DuckDuckGo's HTML endpoint) refuse unknown clients.
let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

func postJSON(_ url: URL, _ body: [String: Any], bearer: String) async throws -> [String: Any] {
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.timeoutInterval = 30
    req.setValue("application/json", forHTTPHeaderField: "content-type")
    req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
    req.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, response) = try await URLSession.shared.data(for: req)
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200 else { throw WebError.http(code) }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

/// Serialises DuckDuckGo requests with a small gap between them.
actor DDGGate {
    static let shared = DDGGate()
    private var last = Date.distantPast
    private var busy = false

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        while busy { try await Task.sleep(for: .milliseconds(100)) }
        busy = true
        defer { busy = false; last = .now }
        let wait = 0.8 - Date.now.timeIntervalSince(last)
        if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
        return try await body()
    }
}

enum WebSearch {
    static func deepseek(_ query: String, key: String) async throws -> [WebSource] {
        let json = try await postJSON(URL(string: "https://api.deepseek.com/v1/tools/search")!, ["query": query, "count": 6], bearer: key)
        return (json["results"] as? [[String: Any]] ?? []).compactMap { r in
            guard let url = r["url"] as? String else { return nil }
            var snippet = (r["summary"] as? String ?? "").replacingOccurrences(of: "\n\n", with: "\n")
            if snippet.count > 700 { snippet = String(snippet.prefix(700)) + "…" }
            if let date = (r["date"] as? String)?.prefix(10) { snippet = "(\(date)) " + snippet }
            return WebSource(url: url, title: r["title"] as? String ?? url, snippet: snippet)
        }
    }

    static func tavily(_ query: String, key: String) async throws -> [WebSource] {
        let json = try await postJSON(URL(string: "https://api.tavily.com/search")!, ["query": query, "max_results": 6], bearer: key)
        return (json["results"] as? [[String: Any]] ?? []).compactMap { r in
            guard let url = r["url"] as? String else { return nil }
            return WebSource(url: url, title: r["title"] as? String ?? url, snippet: r["content"] as? String)
        }
    }

    /// DuckDuckGo rate-limits bursts (HTTP 202 + a challenge page), so requests go one at a time and
    /// fall back from the html endpoint to the lite one.
    static func duckduckgo(_ query: String) async throws -> [WebSource] {
        try await DDGGate.shared.run {
            if let r = try? await ddgPost("https://html.duckduckgo.com/html/", query), !r.isEmpty { return parseDuckDuckGo(r) }
            try await Task.sleep(for: .milliseconds(600))
            let lite = try await ddgPost("https://lite.duckduckgo.com/lite/", query)
            let results = parseDuckDuckGoLite(lite)
            if results.isEmpty, lite.contains("anomaly") || lite.isEmpty {
                throw WebError.unreadable("DuckDuckGo 暂时拒绝了请求（访问太频繁），稍后再试或在设置里换个搜索来源")
            }
            return results
        }
    }

    private static func ddgPost(_ endpoint: String, _ query: String) async throws -> String {
        var req = URLRequest(url: URL(string: endpoint)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "q", value: query)]
        req.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw WebError.http(code) }
        let html = String(decoding: data, as: UTF8.self)
        return html.contains("result__a") || html.contains("result-link") ? html : ""
    }

    /// lite.duckduckgo.com: `<a rel="nofollow" href="URL" class='result-link'>Title</a>` … `<td class='result-snippet'>…</td>`.
    static func parseDuckDuckGoLite(_ html: String) -> [WebSource] {
        let link = try! NSRegularExpression(pattern: #"<a[^>]*href="([^"]+)"[^>]*class='result-link'[^>]*>(.*?)</a>"#, options: [.dotMatchesLineSeparators])
        let snippet = try! NSRegularExpression(pattern: #"class='result-snippet'[^>]*>(.*?)</td>"#, options: [.dotMatchesLineSeparators])
        let ns = html as NSString
        let full = NSRange(location: 0, length: ns.length)
        let snippets = snippet.matches(in: html, range: full)
        var out: [WebSource] = []
        for (i, m) in link.matches(in: html, range: full).enumerated() {
            let href = HTMLText.decode(ns.substring(with: m.range(at: 1)))
            guard href.hasPrefix("http"), !href.contains("duckduckgo.com") else { continue }
            let title = HTMLText.decode(HTMLText.stripTags(ns.substring(with: m.range(at: 2)))).trimmingCharacters(in: .whitespacesAndNewlines)
            let snip = i < snippets.count
                ? HTMLText.decode(HTMLText.stripTags(ns.substring(with: snippets[i].range(at: 1)))).trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
            out.append(WebSource(url: href, title: title, snippet: snip))
            if out.count == 8 { break }
        }
        return out
    }

    /// Result links look like `<a … class="result__a" href="//duckduckgo.com/l/?uddg=<encoded>&…">Title</a>`,
    /// followed by `<a class="result__snippet" …>snippet</a>`.
    static func parseDuckDuckGo(_ html: String) -> [WebSource] {
        let link = try! NSRegularExpression(pattern: #"<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#, options: [.dotMatchesLineSeparators])
        let snippet = try! NSRegularExpression(pattern: #"class="result__snippet"[^>]*>(.*?)</a>"#, options: [.dotMatchesLineSeparators])
        let ns = html as NSString
        let links = link.matches(in: html, range: NSRange(location: 0, length: ns.length))
        let snippets = snippet.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var out: [WebSource] = []
        for (i, m) in links.enumerated() {
            var href = ns.substring(with: m.range(at: 1))
            if href.hasPrefix("//") { href = "https:" + href }
            if let comps = URLComponents(string: href.replacingOccurrences(of: "&amp;", with: "&")),
               let target = comps.queryItems?.first(where: { $0.name == "uddg" })?.value {
                href = target
            }
            guard href.hasPrefix("http"), !href.contains("duckduckgo.com/y.js") else { continue } // ads
            let title = HTMLText.decode(HTMLText.stripTags(ns.substring(with: m.range(at: 2))))
            let snip = i < snippets.count ? HTMLText.decode(HTMLText.stripTags(ns.substring(with: snippets[i].range(at: 1)))) : nil
            out.append(WebSource(url: href, title: title, snippet: snip))
            if out.count == 8 { break }
        }
        return out
    }
}

struct WebPage: Sendable {
    var title: String
    var text: String
}

enum WebFetch {
    static func deepseek(_ url: URL, key: String) async throws -> WebPage {
        let json = try await postJSON(URL(string: "https://api.deepseek.com/v1/tools/fetch")!, ["url": url.absoluteString], bearer: key)
        guard let content = json["content"] as? String, !content.isEmpty else { throw WebError.unreadable("没有读到内容") }
        return WebPage(title: json["title"] as? String ?? url.host ?? url.absoluteString, text: content)
    }

    static func native(_ url: URL) async throws -> WebPage {
        var req = URLRequest(url: url)
        req.timeoutInterval = 25
        req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        req.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw WebError.http(code) }
        let type = http?.value(forHTTPHeaderField: "content-type")?.lowercased() ?? ""
        if type.contains("pdf") { throw WebError.unreadable("这是 PDF，暂时读不了") }
        if type.hasPrefix("image/") || type.hasPrefix("video/") || type.hasPrefix("audio/") {
            throw WebError.unreadable("不是网页（\(type)）")
        }
        let body = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        if type.contains("html") || body.prefix(500).lowercased().contains("<html") {
            return HTMLText.page(body, fallbackTitle: url.host ?? url.absoluteString)
        }
        return WebPage(title: url.lastPathComponent.isEmpty ? (url.host ?? "") : url.lastPathComponent, text: body)
    }
}

/// HTML → readable text without WebKit (which wants the main thread). Good enough for an LLM.
enum HTMLText {
    static func page(_ html: String, fallbackTitle: String) -> WebPage {
        let title = first(#"<title[^>]*>(.*?)</title>"#, in: html).map { decode(stripTags($0)) } ?? fallbackTitle
        var body = html
        // Prefer the main content when the page marks it.
        for tag in ["article", "main"] {
            if let inner = first("<\(tag)[^>]*>(.*)</\(tag)>", in: html), inner.count > 500 { body = inner; break }
        }
        return WebPage(title: title.trimmingCharacters(in: .whitespacesAndNewlines), text: text(body))
    }

    static func text(_ html: String) -> String {
        var s = html
        for tag in ["script", "style", "noscript", "svg", "nav", "footer", "header", "aside", "form", "iframe", "template"] {
            s = replace("<\(tag)\\b[^>]*>.*?</\(tag)>", in: s, with: " ")
        }
        s = replace("<!--.*?-->", in: s, with: "")
        for level in 1...4 { s = replace("<h\(level)\\b[^>]*>", in: s, with: "\n\n" + String(repeating: "#", count: level) + " ") }
        s = replace(#"<li\b[^>]*>"#, in: s, with: "\n- ")
        s = replace(#"<(br|/p|/div|/h\d|/li|/tr|/section|/article|/blockquote|/pre)\b[^>]*>"#, in: s, with: "\n")
        s = replace(#"<a\b[^>]*href="(https?://[^"]+)"[^>]*>(.*?)</a>"#, in: s, with: "$2")
        s = decode(stripTags(s))
        s = replace(#"[ \t\u{00A0}]+"#, in: s, with: " ")
        s = replace(#"\n\s*\n\s*(\n\s*)+"#, in: s, with: "\n\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stripTags(_ s: String) -> String { replace("<[^>]+>", in: s, with: "") }

    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        let named = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
                     "&mdash;": "—", "&ndash;": "–", "&hellip;": "…", "&middot;": "·", "&ldquo;": "“", "&rdquo;": "”",
                     "&lsquo;": "‘", "&rsquo;": "’", "&copy;": "©"]
        for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }
        let numeric = try! NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")
        let ns = out as NSString
        var result = ""
        var last = 0
        for m in numeric.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let hex = ns.substring(with: m.range(at: 1)) == "x"
            let n = UInt32(ns.substring(with: m.range(at: 2)), radix: hex ? 16 : 10)
            result += n.flatMap { Unicode.Scalar($0) }.map { String(Character($0)) } ?? ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    private static func first(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let m = re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) else { return nil }
        return (s as NSString).substring(with: m.range(at: 1))
    }

    private static func replace(_ pattern: String, in s: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
    }
}
