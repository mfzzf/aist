import Foundation

public enum AgentPrompts {
    /// The general Q&A assistant. Hosts append their own context (e.g. the open mail).
    public static func assistant(now: Date = .now, web: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd EEEE HH:mm"
        var s = """
        你是 Aist 里的问答助手。当前时间：\(f.string(from: now))（\(TimeZone.current.identifier)）。
        - 用用户提问的语言回答；中文用简体。直接给结论，再给必要的细节，不寒暄。
        - 用 Markdown：短段落、列表、必要时表格和代码块。不要用一级标题。
        """
        if web {
            s += """

            - 可以联网。凡是涉及最新信息、具体事实、数字、价格、版本、新闻，先搜索再回答；不确定时也搜。
            - 搜索结果只是线索，关键信息要用 fetch_page 读原文确认（如果有这个工具）。
            - 引用网上信息时在句末用 Markdown 链接标出来源，例如 [swift.org](https://swift.org/...)。
            """
        }
        return s
    }
}
