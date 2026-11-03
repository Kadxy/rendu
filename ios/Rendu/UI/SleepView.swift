import SwiftUI

/// Sleep as Health lists it: by night ("Sep 17–18"), one row per stage and
/// source ("REM · 3 intervals (41min)"), then the stage's intervals, then
/// one sample's details.
struct SleepNightsView: View {
    let services: AppServices
    let type: ServerType

    @State private var samples: [ServerSample] = []
    @State private var next: String?
    @State private var loading = false
    @State private var failure: String?

    private static let pageSize = 1000

    var body: some View {
        let nights = SleepNight.group(samples)
        List {
            ForEach(nights) { night in
                Section {
                    ForEach(night.rows) { row in
                        NavigationLink {
                            SleepIntervalsView(night: night, row: row)
                        } label: {
                            HStack(spacing: 14) {
                                SourceIcon(sample: row.samples[0])
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: row.stage.title)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Text(verbatim: SleepFormat.intervals(row.samples.count, duration: row.duration))
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } header: {
                    Text(verbatim: night.title)
                }
            }
            if next != nil {
                Button {
                    Task { await load() }
                } label: {
                    HStack {
                        Text("Load More")
                        if loading {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(loading)
            }
        }
        .overlay {
            if samples.isEmpty, loading {
                ProgressView()
            } else if samples.isEmpty, let failure {
                ContentUnavailableView {
                    Label("Unable to Connect to Server", systemImage: "exclamationmark.icloud")
                } description: {
                    Text(verbatim: failure)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            }
        }
        .navigationTitle(Text(verbatim: HealthUIStrings.localized("ALL_DATA_TITLE") ?? "All Recorded Data"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if samples.isEmpty { await load() }
        }
    }

    private func load() async {
        guard let base = services.settings.baseURL else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await services.uploader.serverSamples(
                base: base, token: services.settings.key, type: type.type, limit: Self.pageSize, cursor: next
            )
            samples += page.samples
            next = page.next
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// One stage's intervals in one night, newest first.
private struct SleepIntervalsView: View {
    let night: SleepNight
    let row: SleepNight.Row

    var body: some View {
        List {
            Section {
                ForEach(row.samples.sorted { ($0.start ?? .distantPast) > ($1.start ?? .distantPast) }) { sample in
                    NavigationLink {
                        SampleDetailView(sample: sample)
                    } label: {
                        HStack {
                            Text(verbatim: SleepFormat.duration(sample.duration))
                            Spacer(minLength: 12)
                            Text(verbatim: SleepFormat.timeRange(sample))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            } header: {
                Text(verbatim: row.stage.intervalsTitle(night.title))
            }
        }
        .navigationTitle(Text(verbatim: HealthUIStrings.localized("ALL_DATA_TITLE") ?? "All Recorded Data"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The device a sample came from, as Health marks it (a watch, a phone),
/// or a generic app glyph.
struct SourceIcon: View {
    let sample: ServerSample

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 20))
            .foregroundStyle(.blue)
            .frame(width: 26)
    }

    private var symbol: String {
        let product =
            sample.json["sourceRevision"]?["productType"]?.string
            ?? sample.json["device"]?["model"]?.string ?? ""
        if product.hasPrefix("Watch") { return "applewatch" }
        if product.hasPrefix("iPhone") { return "iphone" }
        if product.hasPrefix("iPad") { return "ipad" }
        return "app.fill"
    }
}

/// A night of sleep: samples starting from 18:00 one day to 18:00 the next
/// belong to that night, so a night's sleep shows under one header.
struct SleepNight: Identifiable {
    struct Row: Identifiable {
        let stage: SleepStage
        let source: String
        var samples: [ServerSample]
        var id: String { "\(stage.rawValue)|\(source)" }
        var duration: TimeInterval { samples.reduce(0) { $0 + $1.duration } }
    }

    /// The evening the night starts.
    let day: Date
    var rows: [Row]
    var id: Date { day }

    var title: String {
        let next = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        return (day ..< next).formatted(.interval.month(.abbreviated).day().locale(SampleFormat.appLocale))
    }

    static func group(_ samples: [ServerSample]) -> [SleepNight] {
        let calendar = Calendar.current
        var nights: [Date: [String: Row]] = [:]
        for sample in samples {
            guard let start = sample.start else { continue }
            let day = calendar.startOfDay(for: start.addingTimeInterval(-18 * 3600))
            let stage = SleepStage(rawValue: sample.json["valueName"]?.string ?? "") ?? .asleepUnspecified
            let source = sample.sourceName ?? ""
            let key = "\(stage.rawValue)|\(source)"
            nights[day, default: [:]][key, default: Row(stage: stage, source: source, samples: [])].samples.append(sample)
        }
        return
            nights
            .map { day, rows in
                SleepNight(
                    day: day,
                    rows: rows.values.sorted {
                        ($0.stage.order, $0.source) < ($1.stage.order, $1.source)
                    })
            }
            .sorted { $0.day > $1.day }
    }
}

/// HKCategoryValueSleepAnalysis, named as the Health app names it
/// (HealthUIStrings), in Health's order.
enum SleepStage: String, CaseIterable {
    case inBed, awake, asleepREM, asleepCore, asleepDeep, asleepUnspecified

    var order: Int { Self.allCases.firstIndex(of: self)! }

    /// HealthUI's string key for the stage.
    private var key: String {
        switch self {
        case .inBed: "IN_BED"
        case .awake: "AWAKE"
        case .asleepREM: "ASLEEP_REM"
        case .asleepCore: "ASLEEP_CORE"
        case .asleepDeep: "ASLEEP_DEEP"
        case .asleepUnspecified: "ASLEEP_UNSPECIFIED"
        }
    }

    var title: String { HealthUIStrings.localized(key) ?? rawValue }

    /// "REM Intervals: Sep 17–18".
    func intervalsTitle(_ night: String) -> String {
        HealthUIStrings.format(key + "_INTERVALS", night) ?? "\(title): \(night)"
    }
}

enum SleepFormat {
    /// "7min", "2hr 25min".
    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .brief
        formatter.zeroFormattingBehavior = .dropAll
        var calendar = Calendar.current
        calendar.locale = SampleFormat.appLocale
        formatter.calendar = calendar
        return formatter.string(from: max(seconds, 60)) ?? ""
    }

    /// "4 intervals (7min)", "4个时间间隔（7分钟）".
    static func intervals(_ count: Int, duration: TimeInterval) -> String {
        let intervals = HealthUIStrings.intervals(count)
        return HealthUIStrings.chinese ? "\(intervals)（\(Self.duration(duration))）" : "\(intervals) (\(Self.duration(duration)))"
    }

    /// "06:39 - 06:41".
    static func timeRange(_ sample: ServerSample) -> String {
        guard let start = sample.start, let end = sample.end else { return "" }
        let style = Date.FormatStyle(date: .omitted, time: .shortened).locale(SampleFormat.appLocale)
        return "\(start.formatted(style)) - \(end.formatted(style))"
    }
}

extension ServerSample {
    var duration: TimeInterval {
        guard let start, let end else { return 0 }
        return end.timeIntervalSince(start)
    }
}
