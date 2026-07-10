import SwiftUI
import Charts

// MARK: - Sidebar model

enum Section: String, CaseIterable, Identifiable {
    case home, history, insights, dictionary, snippets, style, transforms, scratchpad, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .history: return "History"
        case .insights: return "Insights"
        case .dictionary: return "Dictionary"
        case .snippets: return "Snippets"
        case .style: return "Style"
        case .transforms: return "Transforms"
        case .scratchpad: return "Scratchpad"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "square.grid.2x2"
        case .history: return "clock"
        case .insights: return "chart.bar"
        case .dictionary: return "book"
        case .snippets: return "scissors"
        case .style: return "textformat"
        case .transforms: return "wand.and.stars"
        case .scratchpad: return "note.text"
        case .settings: return "gearshape"
        }
    }
}

// MARK: - Root

struct EchoMainView: View {
    @State private var selection: Section? = .home

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selection) { section in
                NavigationLink(value: section) {
                    Label(section.title, systemImage: section.systemImage)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Echo")
            .frame(minWidth: 200)
        } detail: {
            switch selection ?? .home {
            case .home: HomeView()
            case .history: HistoryView()
            case .insights: InsightsView()
            case .dictionary: DictionaryView()
            case .snippets: SnippetsView()
            case .style: StyleView()
            case .transforms: TransformsView()
            case .scratchpad: ScratchpadView()
            case .settings: SettingsView()
            }
        }
    }
}

// MARK: - Home

struct HomeView: View {
    @State private var totals: (words: Int, transcriptions: Int, seconds: Double) = (0, 0, 0)
    @State private var streak: Int = 0
    @State private var recent: [Database.Transcription] = []
    @State private var monthCost: Database.CostBreakdown = .init(whisperUSD: 0, llmUSD: 0, audioSeconds: 0, llmInputChars: 0, llmOutputChars: 0)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Welcome back, Mathias")
                    .font(.system(size: 24, weight: .semibold))
                    .padding(.top, 8)

                HStack(spacing: 16) {
                    statCard(value: formattedWords, label: "total words")
                    statCard(value: String(format: "%.0f", wpm), label: "wpm")
                    statCard(value: "\(streak)", label: "day streak")
                    statCard(value: String(format: "$%.2f", monthCost.whisperUSD), label: "this month")
                        .help("Transcription API spend this month. Style post-processing runs on the fast chat API (Groq/OpenAI) - negligible, est. $\(String(format: "%.3f", monthCost.llmUSD)).")
                }

                Text("RECENT")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)

                if recent.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "mic.slash")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text("No transcriptions yet. Double-tap Fn to start.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 160)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    VStack(spacing: 0) {
                        ForEach(recent, id: \.id) { tx in
                            transcriptionRow(tx)
                            if tx.id != recent.last?.id { Divider() }
                        }
                    }
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: .transcriptionsChanged)) { _ in
            refresh()
        }
    }

    private func refresh() {
        totals = Database.shared.totals()
        streak = Database.shared.dayStreak()
        recent = Database.shared.recentTranscriptions(limit: 20)
        monthCost = Database.shared.costThisMonth()
    }

    private var wpm: Double {
        totals.seconds > 0 ? Double(totals.words) / (totals.seconds / 60.0) : 0
    }

    private var formattedWords: String {
        if totals.words >= 1000 {
            return String(format: "%.1fK", Double(totals.words) / 1000.0)
        }
        return "\(totals.words)"
    }

    @ViewBuilder private func statCard(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 30, weight: .semibold))
            Text(label)
                .foregroundStyle(.secondary)
                .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func transcriptionRow(_ tx: Database.Transcription) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(timeString(tx.createdAt))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
                .font(.callout.monospacedDigit())
            VStack(alignment: .leading, spacing: 2) {
                Text(tx.finalText)
                    .lineLimit(3)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    if let app = tx.appName {
                        Text(app)
                    }
                    Text("·  \(tx.wordCount) words")
                    Text("·  \(String(format: "%.1fs", tx.duration))")
                    if tx.latency > 0 {
                        Text("·  \(String(format: "%.1fs", tx.latency)) api")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tx.finalText, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Copy")
                Button {
                    Database.shared.deleteTranscription(id: tx.id)
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .help("Delete")
            }
            .opacity(0.7)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func timeString(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        guard let date = f.date(from: iso) else { return String(iso.prefix(16)) }
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            let df = DateFormatter()
            df.timeStyle = .short
            return df.string(from: date)
        }
        let df = DateFormatter()
        df.dateFormat = "MMM d"
        return df.string(from: date)
    }
}

// MARK: - History

struct HistoryView: View {
    @State private var query: String = ""
    @State private var results: [Database.Transcription] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("History").font(.system(size: 24, weight: .semibold))
                Spacer()
                Text("\(results.count) result\(results.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28).padding(.top, 24)

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search text, app, or words...", text: $query)
                    .textFieldStyle(.plain)
                    .onChange(of: query) { _ in refresh() }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 28).padding(.top, 12)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(results, id: \.id) { tx in
                        historyRow(tx)
                        Divider()
                    }
                    if results.isEmpty {
                        Text(query.isEmpty ? "No transcriptions yet." : "No matches for \"\(query)\"")
                            .foregroundStyle(.secondary)
                            .padding(40)
                    }
                }
                .padding(.horizontal, 28).padding(.top, 16).padding(.bottom, 32)
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: .transcriptionsChanged)) { _ in refresh() }
    }

    @ViewBuilder private func historyRow(_ tx: Database.Transcription) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(formattedDate(tx.createdAt))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(tx.finalText)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    if let app = tx.appName { Text(app) }
                    Text("·  \(tx.wordCount) words")
                    Text("·  \(String(format: "%.1fs", tx.duration))")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tx.finalText, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy")
                Button {
                    Database.shared.deleteTranscription(id: tx.id)
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).foregroundStyle(.red).help("Delete")
            }
            .opacity(0.6)
        }
        .padding(.vertical, 12)
    }

    private func refresh() {
        results = Database.shared.searchTranscriptions(query: query)
    }

    private func formattedDate(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        guard let date = f.date(from: iso) else { return iso }
        let df = DateFormatter()
        df.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "MMM d  HH:mm"
        return df.string(from: date)
    }
}

// MARK: - Insights

struct InsightsView: View {
    @State private var daily: [Database.DailyStats] = []
    @State private var topApps: [Database.AppUsage] = []
    @State private var avgLatency: Double = 0
    @State private var modelLatency: [Database.ModelLatency] = []
    @State private var rangeDays: Int = 30
    @State private var costRange: Database.CostBreakdown = .init(whisperUSD: 0, llmUSD: 0, audioSeconds: 0, llmInputChars: 0, llmOutputChars: 0)
    @State private var costAllTime: Database.CostBreakdown = .init(whisperUSD: 0, llmUSD: 0, audioSeconds: 0, llmInputChars: 0, llmOutputChars: 0)
    @State private var costsByDay: [(date: String, usd: Double)] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("Insights").font(.system(size: 24, weight: .semibold))
                    Spacer()
                    Picker("Range", selection: $rangeDays) {
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                    .labelsHidden()
                    .onChange(of: rangeDays) { _ in refresh() }
                }

                if daily.isEmpty {
                    emptyState
                } else {
                    wordsPerDayChart
                    wpmChart
                    HStack(alignment: .top, spacing: 16) {
                        topAppsCard
                        latencyCard
                    }
                    if modelLatency.count > 1 {
                        modelLatencyCard
                    }
                    costsCard
                    costPerDayChart
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: .transcriptionsChanged)) { _ in refresh() }
    }

    private func refresh() {
        daily = Database.shared.dailyStats(days: rangeDays).reversed()
        topApps = Database.shared.topApps(days: rangeDays, limit: 8)
        avgLatency = Database.shared.averageLatency(days: rangeDays)
        modelLatency = Database.shared.latencyByModel(days: rangeDays)
        costRange = Database.shared.costLast(days: rangeDays)
        costAllTime = Database.shared.costAllTime()
        costsByDay = Database.shared.costsByDay(days: rangeDays)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("Not enough data yet").foregroundStyle(.secondary)
            Text("Charts appear once you have a few dictations.").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var wordsPerDayChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WORDS PER DAY").font(.caption).foregroundStyle(.secondary)
            Chart(daily, id: \.date) { day in
                BarMark(
                    x: .value("Day", day.date),
                    y: .value("Words", day.wordCount)
                )
                .foregroundStyle(Color.accentColor.gradient)
            }
            .frame(height: 200)
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var wpmChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WORDS PER MINUTE").font(.caption).foregroundStyle(.secondary)
            Chart(daily, id: \.date) { day in
                LineMark(
                    x: .value("Day", day.date),
                    y: .value("WPM", day.wpm)
                )
                .foregroundStyle(Color.accentColor)
                .interpolationMethod(.catmullRom)
                PointMark(
                    x: .value("Day", day.date),
                    y: .value("WPM", day.wpm)
                )
                .foregroundStyle(Color.accentColor)
            }
            .frame(height: 160)
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var topAppsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TOP APPS").font(.caption).foregroundStyle(.secondary)
            if topApps.isEmpty {
                Text("(none yet)").foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(Array(topApps.enumerated()), id: \.offset) { _, app in
                    HStack {
                        Text(app.appName).lineLimit(1)
                        Spacer()
                        Text("\(app.wordCount)").foregroundStyle(.secondary).font(.callout.monospacedDigit())
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var costsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("API SPEND").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "$%.2f", costRange.whisperUSD))
                        .font(.system(size: 30, weight: .semibold))
                    Text("last \(rangeDays) days").foregroundStyle(.secondary).font(.callout)
                }
                Divider().frame(height: 50)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "$%.2f", costAllTime.whisperUSD))
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("all-time").foregroundStyle(.secondary).font(.callout)
                }
                Spacer()
            }
            HStack(spacing: 18) {
                costBadge("Transcription", value: costRange.whisperUSD,
                          note: String(format: "%.1f min audio", costRange.audioSeconds / 60))
                costBadge("Styling (est.)", value: costRange.llmUSD,
                          note: "chat API - negligible")
            }
            Text("Headline spend is transcription only. Style post-processing runs on the fast chat API (Groq/OpenAI); the styling figure is an indicative estimate at 1 token ≈ 4 chars. Transcription priced per row by model.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func costBadge(_ label: String, value: Double, note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(label).font(.callout.weight(.medium))
                Text(String(format: "$%.3f", value)).font(.callout.monospacedDigit())
            }
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var costPerDayChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SPEND PER DAY").font(.caption).foregroundStyle(.secondary)
            Chart(costsByDay, id: \.date) { row in
                BarMark(
                    x: .value("Day", row.date),
                    y: .value("USD", row.usd)
                )
                .foregroundStyle(Color.green.gradient)
            }
            .frame(height: 160)
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var latencyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AVG API LATENCY").font(.caption).foregroundStyle(.secondary)
            Text(String(format: "%.2f s", avgLatency))
                .font(.system(size: 30, weight: .semibold))
            Text("Time from Fn stop to text inserted (Whisper roundtrip only).")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Latency compared across the models you've actually used - the tool for
    /// picking a default. Fastest model first.
    private var modelLatencyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LATENCY BY MODEL").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(modelLatency.enumerated()), id: \.offset) { _, row in
                HStack {
                    Text(row.model).font(.system(.body, design: .monospaced))
                    Spacer()
                    Text("\(row.count) rec").font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "%.2f s", row.avgLatencySeconds))
                        .font(.body.weight(.semibold))
                        .frame(width: 70, alignment: .trailing)
                }
            }
            Text("Average roundtrip per model over the range. Dictate the same phrases under each model to compare fairly.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Dictionary

struct DictionaryView: View {
    @StateObject private var vocab = VocabStore.shared
    @State private var newSpoken = ""
    @State private var newTarget = ""
    @State private var newTerm = ""
    @State private var scopedSpoken = ""
    @State private var scopedTarget = ""
    @State private var scopedAppId: String = ""

    /// Running apps with a window, for the per-app scope picker.
    private var runningApps: [(bundleId: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier, let name = app.localizedName else { return nil }
                return (id, name)
            }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Dictionary")
                    .font(.system(size: 24, weight: .semibold))

                section("REPLACEMENTS") {
                    Text("When I say the first phrase, write the second.")
                        .foregroundStyle(.secondary)
                        .font(.callout)

                    HStack(spacing: 8) {
                        TextField("What I say (e.g. InSync)", text: $newSpoken)
                            .textFieldStyle(.roundedBorder)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("What to write (e.g. Inseanq)", text: $newTarget)
                            .textFieldStyle(.roundedBorder)
                        Button("Add") {
                            vocab.addReplacement(spoken: newSpoken, write: newTarget)
                            newSpoken = ""; newTarget = ""
                        }
                        .disabled(newSpoken.isEmpty || newTarget.isEmpty)
                    }

                    VStack(spacing: 0) {
                        ForEach(vocab.data.replacements.sorted(by: { $0.key < $1.key }), id: \.key) { spoken, target in
                            HStack {
                                Text(spoken).frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                                Text(target).frame(maxWidth: .infinity, alignment: .leading)
                                Button {
                                    vocab.removeReplacement(spoken: spoken)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.red)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            Divider()
                        }
                    }
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                section("PER-APP REPLACEMENTS") {
                    Text("Replacements that only apply when dictating into a specific app.")
                        .foregroundStyle(.secondary).font(.callout)
                    HStack(spacing: 8) {
                        TextField("What I say", text: $scopedSpoken).textFieldStyle(.roundedBorder)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("What to write", text: $scopedTarget).textFieldStyle(.roundedBorder)
                    }
                    HStack(spacing: 8) {
                        Picker("App", selection: $scopedAppId) {
                            Text("Pick an app...").tag("")
                            ForEach(runningApps, id: \.bundleId) { app in
                                Text(app.name).tag(app.bundleId)
                            }
                        }
                        .pickerStyle(.menu).labelsHidden()
                        Button("Add") {
                            let name = runningApps.first(where: { $0.bundleId == scopedAppId })?.name
                            vocab.addScopedReplacement(spoken: scopedSpoken, target: scopedTarget,
                                                       appBundleId: scopedAppId.isEmpty ? nil : scopedAppId,
                                                       appName: name)
                            scopedSpoken = ""; scopedTarget = ""; scopedAppId = ""
                        }
                        .disabled(scopedSpoken.isEmpty || scopedTarget.isEmpty || scopedAppId.isEmpty)
                    }
                    let list = vocab.data.scopedReplacements ?? []
                    if !list.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(list, id: \.self) { item in
                                HStack {
                                    Text(item.spoken).frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                                    Text(item.target).frame(maxWidth: .infinity, alignment: .leading)
                                    if let app = item.appName {
                                        Text(app).font(.caption).foregroundStyle(.secondary)
                                            .padding(.horizontal, 8).padding(.vertical, 2)
                                            .background(Color(NSColor.controlBackgroundColor).opacity(0.7))
                                            .clipShape(Capsule())
                                    }
                                    Button { vocab.removeScopedReplacement(item) }
                                    label: { Image(systemName: "trash") }
                                        .buttonStyle(.borderless).foregroundStyle(.red)
                                }
                                .padding(.horizontal, 16).padding(.vertical, 10)
                                Divider()
                            }
                        }
                        .background(Color(NSColor.controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }

                section("BIAS TERMS") {
                    Text("Words sent to Whisper as a hint so it spells them correctly from the start.")
                        .foregroundStyle(.secondary)
                        .font(.callout)

                    HStack(spacing: 8) {
                        TextField("Add a term...", text: $newTerm)
                            .textFieldStyle(.roundedBorder)
                        Button("Add") {
                            vocab.addTerm(newTerm); newTerm = ""
                        }.disabled(newTerm.isEmpty)
                    }

                    FlowLayout(spacing: 6) {
                        ForEach(vocab.data.terms, id: \.self) { term in
                            HStack(spacing: 4) {
                                Text(term)
                                Button {
                                    vocab.removeTerm(term)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color(NSColor.controlBackgroundColor))
                            .clipShape(Capsule())
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }
}

// MARK: - Transforms

struct TransformsView: View {
    @StateObject private var store = TransformsStore.shared
    @State private var editing: Transform?
    @State private var showingAdd = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Transforms")
                    .font(.system(size: 24, weight: .semibold))
                Text("One-off LLM rewrites. Use the menubar (right-click 🎙 → Use for next recording) to apply one to your next dictation. It resets to Default afterwards.")
                    .foregroundStyle(.secondary)

                if let next = store.nextRecordingOverride {
                    HStack {
                        Image(systemName: "wand.and.stars")
                        Text("Next recording will use **\(next.name)**")
                        Spacer()
                        Button("Clear") { store.nextRecordingOverride = nil }
                            .buttonStyle(.borderless)
                    }
                    .padding(12)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                HStack {
                    Spacer()
                    Button {
                        showingAdd = true
                    } label: {
                        Label("Add Transform", systemImage: "plus")
                    }
                }

                VStack(spacing: 10) {
                    ForEach(store.data.transforms) { transform in
                        transformRow(transform)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $editing) { transform in
            EditTransformSheet(transform: transform) { updated in
                store.update(updated); editing = nil
            } onCancel: { editing = nil }
                .frame(width: 560, height: 460)
        }
        .sheet(isPresented: $showingAdd) {
            EditTransformSheet(transform: Transform(name: "", description: "", systemPrompt: "")) { new in
                store.add(name: new.name, description: new.description, systemPrompt: new.systemPrompt)
                showingAdd = false
            } onCancel: { showingAdd = false }
                .frame(width: 560, height: 460)
        }
    }

    @ViewBuilder private func transformRow(_ t: Transform) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(t.name).font(.headline)
                Text(t.description).foregroundStyle(.secondary).font(.callout)
            }
            Spacer()
            HStack(spacing: 4) {
                Button {
                    store.nextRecordingOverride = t
                } label: { Image(systemName: "play.fill") }
                .help("Use for next recording")
                .buttonStyle(.borderless)
                Button { editing = t } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                Button { store.remove(id: t.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct EditTransformSheet: View {
    @State var transform: Transform
    let onSave: (Transform) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(transform.name.isEmpty ? "New Transform" : "Edit Transform").font(.headline)
            TextField("Name", text: $transform.name).textFieldStyle(.roundedBorder)
            TextField("Description (shown in menubar)", text: $transform.description).textFieldStyle(.roundedBorder)
            Text("SYSTEM PROMPT").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $transform.systemPrompt)
                .font(.system(size: 12, design: .monospaced))
                .padding(6)
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(NSColor.separatorColor), lineWidth: 0.5))
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") { onSave(transform) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(transform.name.isEmpty || transform.systemPrompt.isEmpty)
            }
        }
        .padding(20)
    }
}

// MARK: - Snippets

struct SnippetsView: View {
    @StateObject private var store = SnippetsStore.shared
    @State private var editing: Snippet?
    @State private var newTrigger = ""
    @State private var newExpansion = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Snippets")
                    .font(.system(size: 24, weight: .semibold))
                Text("When the trigger phrase appears in a dictation, Echo expands it into the template below.")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 10) {
                    Text("ADD SNIPPET").font(.caption).foregroundStyle(.secondary)
                    TextField("Trigger phrase (e.g. \"signatur\")", text: $newTrigger)
                        .textFieldStyle(.roundedBorder)
                    TextEditor(text: $newExpansion)
                        .font(.system(size: 13))
                        .frame(minHeight: 80)
                        .padding(6)
                        .background(Color(NSColor.textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(NSColor.separatorColor), lineWidth: 0.5))
                    HStack {
                        Spacer()
                        Button("Add") {
                            store.add(trigger: newTrigger, expansion: newExpansion)
                            newTrigger = ""; newExpansion = ""
                        }
                        .disabled(newTrigger.isEmpty || newExpansion.isEmpty)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                if store.data.snippets.isEmpty {
                    Text("No snippets yet.").foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 10) {
                        ForEach(store.data.snippets) { snippet in
                            snippetRow(snippet)
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $editing) { snippet in
            EditSnippetSheet(snippet: snippet) { updated in
                store.update(updated)
                editing = nil
            } onCancel: {
                editing = nil
            }
            .frame(width: 520, height: 360)
        }
    }

    @ViewBuilder private func snippetRow(_ snippet: Snippet) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(snippet.trigger).font(.system(.body, design: .monospaced)).bold()
                Text(snippet.expansion)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .font(.callout)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text("\(snippet.hits) uses").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Button { editing = snippet } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless)
                    Button { store.remove(id: snippet.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct EditSnippetSheet: View {
    @State var snippet: Snippet
    let onSave: (Snippet) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Snippet").font(.headline)
            TextField("Trigger", text: $snippet.trigger)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $snippet.expansion)
                .font(.system(size: 13))
                .padding(6)
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(NSColor.separatorColor), lineWidth: 0.5))
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") { onSave(snippet) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(snippet.trigger.isEmpty || snippet.expansion.isEmpty)
            }
        }
        .padding(20)
    }
}

// MARK: - Style

struct StyleView: View {
    @StateObject private var store = StyleStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Style")
                    .font(.system(size: 24, weight: .semibold))
                Text("Post-processing applied to each dictation. Pick one as your default. \"Raw\" skips it for fastest results.")
                    .foregroundStyle(.secondary)

                VStack(spacing: 12) {
                    ForEach(StylePreset.all) { preset in
                        styleCard(preset)
                    }
                }
                .padding(.top, 8)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func styleCard(_ preset: StylePreset) -> some View {
        let isDefault = preset.id == store.defaultStyleId
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(preset.name).font(.headline)
                if isDefault {
                    Text("Default")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.18))
                        .clipShape(Capsule())
                        .foregroundStyle(.tint)
                }
                Spacer()
                if !isDefault {
                    Button("Set as Default") {
                        store.defaultStyleId = preset.id
                    }
                    .buttonStyle(.borderless)
                }
            }
            Text(preset.description).foregroundStyle(.secondary)
            if !preset.systemPrompt.isEmpty {
                DisclosureGroup("System prompt") {
                    Text(preset.systemPrompt)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isDefault ? Color.accentColor : .clear, lineWidth: 1.5)
        )
    }
}

// MARK: - Settings

struct SettingsView: View {
    @State private var soundEnabled: Bool = AudioFeedback.isEnabled
    @State private var loginItemEnabled: Bool = LoginItem.isEnabled
    @State private var loginItemError: String?
    @State private var hotkeyId: String = UserDefaults.standard.string(forKey: "echo.hotkey") ?? HotkeyOption.fn.rawValue
    @StateObject private var style = StyleStore.shared
    @StateObject private var config = ConfigStore.shared
    @State private var openaiKeyInput = ""
    @State private var groqKeyInput = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Settings")
                    .font(.system(size: 24, weight: .semibold))

                VStack(alignment: .leading, spacing: 12) {
                    Text("DEFAULT STYLE").font(.caption).foregroundStyle(.secondary)
                    Picker("Style", selection: $style.defaultStyleId) {
                        ForEach(StylePreset.all) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    Text("Applied after Whisper, before vocab replacements. Manage presets in the Style section.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 12) {
                    Text("HOTKEY").font(.caption).foregroundStyle(.secondary)
                    Picker("Push-to-talk key", selection: $hotkeyId) {
                        ForEach(HotkeyOption.allCases) { opt in
                            Text(opt.displayName).tag(opt.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: hotkeyId) { v in
                        UserDefaults.standard.set(v, forKey: "echo.hotkey")
                        NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
                    }
                    Text("Double-tap to start recording. Single tap to stop and transcribe.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 12) {
                    Text("STARTUP").font(.caption).foregroundStyle(.secondary)
                    Toggle("Launch Echo at login", isOn: $loginItemEnabled)
                        .onChange(of: loginItemEnabled) { v in
                            do { try LoginItem.setEnabled(v); loginItemError = nil }
                            catch { loginItemError = error.localizedDescription }
                        }
                    if let err = loginItemError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    } else {
                        Text(LoginItem.statusDescription).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 12) {
                    Text("FEEDBACK").font(.caption).foregroundStyle(.secondary)
                    Toggle("Play sound when recording starts/stops", isOn: $soundEnabled)
                        .onChange(of: soundEnabled) { v in AudioFeedback.setEnabled(v) }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 12) {
                    Text("TRANSCRIPTION PROVIDER").font(.caption).foregroundStyle(.secondary)
                    Picker("Provider", selection: Binding(
                        get: { config.activeProvider.rawValue },
                        set: { config.setProvider(TranscriptionProvider(rawValue: $0) ?? .openai) }
                    )) {
                        ForEach(TranscriptionProvider.allCases) { p in
                            Text("\(p.displayName)  ·  $\(String(format: "%.4f", p.pricePerMinute))/min").tag(p.rawValue)
                        }
                    }
                    .pickerStyle(.menu).labelsHidden()
                    Text("Echo uses your selected provider for transcription. Both expose the same Whisper API. Groq is currently ~4.5x cheaper than OpenAI and faster.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                let modelProvider = config.activeProvider
                VStack(alignment: .leading, spacing: 12) {
                    Text("TRANSCRIPTION MODEL").font(.caption).foregroundStyle(.secondary)
                    Picker("Model", selection: Binding(
                        get: { config.model(for: modelProvider) },
                        set: { config.setModel($0, for: modelProvider) }
                    )) {
                        ForEach(modelProvider.availableModels) { m in
                            Text("\(m.label)  ·  $\(String(format: "%.4f", m.usdPerMinute))/min").tag(m.id)
                        }
                    }
                    .pickerStyle(.menu).labelsHidden()
                    Text("Model used for \(modelProvider.displayName). Faster/cheaper vs. more accurate - compare real latency per model under Insights.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                providerKeyCard(.openai, input: $openaiKeyInput)
                providerKeyCard(.groq, input: $groqKeyInput)

                VStack(alignment: .leading, spacing: 12) {
                    Text("BACKUP").font(.caption).foregroundStyle(.secondary)
                    Text("Export or import all dictionary, snippet, style, and transform settings as a single JSON file. History and API key are not included.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Export...") { exportBackup() }
                        Button("Import...") { importBackup() }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 12) {
                    Text("DATABASE").font(.caption).foregroundStyle(.secondary)
                    Text("~/.jarvis-voice/db.sqlite").font(.system(.body, design: .monospaced))
                    Button("Reveal in Finder") {
                        let url = FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent(".jarvis-voice/db.sqlite")
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func providerKeyCard(_ provider: TranscriptionProvider, input: Binding<String>) -> some View {
        let existing = config.apiKey(for: provider)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(provider.displayName.uppercased()) API KEY").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if existing != nil {
                    Text("Configured").font(.caption).foregroundStyle(.green)
                } else {
                    Text("Not configured").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let key = existing, key.count > 12 {
                Text("\(key.prefix(7))...\(key.suffix(4))")
                    .font(.system(.body, design: .monospaced))
            }
            HStack {
                SecureField("Paste \(provider.displayName) key...", text: input)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    config.setApiKey(input.wrappedValue, for: provider)
                    input.wrappedValue = ""
                }
                .disabled(input.wrappedValue.isEmpty)
                if existing != nil {
                    Button(role: .destructive) {
                        config.setApiKey("", for: provider)
                    } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).foregroundStyle(.red)
                }
            }
            Link("Get a \(provider.displayName) key", destination: provider.signupURL)
                .font(.caption)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "echo-backup-\(dateStamp()).json"
        if panel.runModal() == .OK, let url = panel.url {
            do { try BackupManager.exportToFile(at: url) }
            catch { presentError(error) }
        }
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let names = try BackupManager.importFromFile(at: url)
                let alert = NSAlert()
                alert.messageText = "Backup imported"
                alert.informativeText = "Imported: \(names.joined(separator: ", "))\n\nQuit and reopen Echo to ensure all sections reflect the new data."
                alert.runModal()
            } catch { presentError(error) }
        }
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }

    private func dateStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return f.string(from: Date())
    }
}

// MARK: - Scratchpad

struct ScratchpadView: View {
    @State private var text: String = ""
    @State private var saveDebounce: DispatchWorkItem?
    @State private var lastSavedAt: Date?

    private var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".jarvis-voice/scratchpad.txt")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Scratchpad").font(.system(size: 24, weight: .semibold))
                Spacer()
                Text(savedLabel)
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: { Label("Copy All", systemImage: "doc.on.doc") }
                Button(role: .destructive) {
                    text = ""
                } label: { Label("Clear", systemImage: "trash") }
            }
            .padding(.horizontal, 28).padding(.top, 24)

            Text("A free-form notes area. Auto-saves to ~/.jarvis-voice/scratchpad.txt.")
                .foregroundStyle(.secondary)
                .padding(.horizontal, 28)

            TextEditor(text: $text)
                .font(.system(size: 14))
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .onChange(of: text) { _ in scheduleSave() }
        }
        .onAppear(perform: load)
    }

    private var savedLabel: String {
        guard let at = lastSavedAt else { return "" }
        let secs = Int(Date().timeIntervalSince(at))
        if secs < 5 { return "Saved" }
        if secs < 60 { return "Saved \(secs)s ago" }
        return "Saved \(secs / 60)m ago"
    }

    private func load() {
        if let raw = try? String(contentsOf: fileURL, encoding: .utf8) {
            text = raw
            lastSavedAt = Date()
        }
    }

    /// Debounce: write 500ms after the last keystroke. Cheap I/O so we don't
    /// risk losing notes on crash.
    private func scheduleSave() {
        saveDebounce?.cancel()
        let work = DispatchWorkItem {
            try? text.write(to: fileURL, atomically: true, encoding: .utf8)
            lastSavedAt = Date()
        }
        saveDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}

// MARK: - FlowLayout for term chips

/// Simple wrapping HStack. Lays children left-to-right and wraps when the
/// row runs out of horizontal space.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, rowHeight: CGFloat = 0, totalHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                x = 0; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: .init(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
