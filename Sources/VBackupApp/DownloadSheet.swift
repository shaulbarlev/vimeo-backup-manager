import Contracts
import SwiftUI

/// Upload-date presets for the download scope.
enum DatePreset: String, CaseIterable, Identifiable {
    case allTime = "All time", last7 = "Last 7 days", last30 = "Last 30 days"
    case thisYear = "This year", lastYear = "Last year", custom = "Custom"
    var id: String { rawValue }

    /// Inclusive [from, to] for the preset; nil bounds are open. `custom` returns the given dates.
    func range(now: Date = Date(), calendar: Calendar = .current, from: Date, to: Date) -> (Date?, Date?) {
        let today = calendar.startOfDay(for: now)
        let year = calendar.component(.year, from: now)
        func startOfYear(_ y: Int) -> Date { calendar.date(from: DateComponents(year: y, month: 1, day: 1))! }
        switch self {
        case .allTime: return (nil, nil)
        case .last7: return (calendar.date(byAdding: .day, value: -6, to: today), nil)
        case .last30: return (calendar.date(byAdding: .day, value: -29, to: today), nil)
        case .thisYear: return (startOfYear(year), nil)
        case .lastYear: return (startOfYear(year - 1), startOfYear(year).addingTimeInterval(-1))
        case .custom:
            let end = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: calendar.startOfDay(for: to))
            return (calendar.startOfDay(for: from), end)
        }
    }
}

/// Builds one download: which folders, which upload dates, which videos, at which quality, with sizes and free space.
struct DownloadSheet: View {
    @Bindable var model: AppModel
    let summary: LibrarySummary
    let root: URL
    let request: AppModel.SheetRequest

    @Environment(\.dismiss) private var dismiss
    @State private var scope: DownloadScope
    @State private var quality: Quality
    @State private var preset: DatePreset = .allTime
    @State private var customFrom = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
    @State private var customTo = Date()
    @State private var search = ""

    init(model: AppModel, summary: LibrarySummary, root: URL, request: AppModel.SheetRequest) {
        self.model = model
        self.summary = summary
        self.root = root
        self.request = request
        _scope = State(initialValue: request.scope)
        _quality = State(initialValue: request.quality)
        if let from = request.scope.from { _customFrom = State(initialValue: from) }
        if let to = request.scope.to { _customTo = State(initialValue: to) }
        if let saved = request.preset.flatMap(DatePreset.init(rawValue:)) {
            _preset = State(initialValue: saved) // relative presets recompute their dates from today
        } else if request.scope.from != nil || request.scope.to != nil {
            _preset = State(initialValue: .custom)
        }
    }

    // MARK: Derived

    /// Videos this sheet can offer (before folder/date/exclusions).
    private var pool: [VideoState] {
        guard let only = request.onlyIDs else { return summary.videos }
        return summary.videos.filter { only.contains($0.id) }
    }

    private var effectiveScope: DownloadScope {
        var s = scope
        (s.from, s.to) = preset.range(from: customFrom, to: customTo)
        return s
    }

    private var inRange: [VideoState] { pool.filter(effectiveScope.inRange) }
    private var selected: [VideoState] { pool.filter(effectiveScope.matches) }

    private var shown: [VideoState] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? inRange : inRange.filter { $0.video.title.localizedCaseInsensitiveContains(q) }
    }

    private func toDownload(_ q: Quality) -> [VideoState] { selected.filter { $0.needsDownload(q) } }

    private func size(_ videos: [VideoState], _ q: Quality) -> SizeEstimate {
        videos.reduce(SizeEstimate(bytes: 0, exact: true)) { $0 + q.size(of: $1.video) }
    }

    private var freeBytes: Int64? {
        (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    // MARK: Body

    var body: some View {
        let pending = toDownload(quality)
        let pendingSize = size(pending, quality)
        let fits = freeBytes.map { pendingSize.bytes < $0 } ?? true

        VStack(alignment: .leading, spacing: 16) {
            Text(request.title).font(.title2.weight(.semibold))

            HStack(alignment: .top, spacing: 20) {
                folderPicker.frame(width: 220)
                VStack(alignment: .leading, spacing: 10) {
                    datePicker
                    videoList
                }
            }

            Divider()

            HStack(alignment: .top, spacing: 28) {
                qualityPicker
                VStack(alignment: .leading, spacing: 6) {
                    Text("Selected: \(Format.count(selected.count)) videos").font(.headline)
                    Text("Already at \(quality.label) or better: \(Format.count(selected.count - pending.count))")
                        .foregroundStyle(.secondary)
                    Text("To download: \(Format.count(pending.count)) · \(Format.estimate(pendingSize))")
                        .font(.headline)
                    if let free = freeBytes {
                        Label("Free on this drive: \(Format.bytes(free))",
                              systemImage: fits ? "checkmark.circle" : "xmark.octagon.fill")
                            .foregroundStyle(fits ? Color.secondary : Color.red)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Download \(Format.estimate(pendingSize))") {
                    let ids = pending.map(\.id)
                    model.download(ids: ids, quality: quality, scope: request.onlyIDs == nil ? effectiveScope : nil,
                                   preset: preset.rawValue)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(pending.isEmpty || !fits)
            }
        }
        .padding(20)
        .frame(minWidth: 980, minHeight: 640)
    }

    // MARK: Sections

    private var folderPicker: some View {
        let paths = summary.folders.map(\.path)
        let counts = Dictionary(grouping: pool, by: \.folderPath).mapValues(\.count)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Folders").font(.headline)
            Toggle("All folders", isOn: Binding(
                get: { scope.folderPaths == nil },
                set: { scope.folderPaths = $0 ? nil : [] }))
            List(paths, id: \.self) { path in
                Toggle(isOn: Binding(
                    get: { scope.folderPaths?.contains(path) ?? true },
                    set: { on in
                        var set = scope.folderPaths ?? Set(paths)
                        if on { set.insert(path) } else { set.remove(path) }
                        scope.folderPaths = set.count == paths.count ? nil : set
                    })) {
                    HStack {
                        Text(path).lineLimit(1)
                        Spacer()
                        Text(Format.count(counts[path] ?? 0)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            .listStyle(.bordered)
        }
    }

    private var datePicker: some View {
        HStack(spacing: 12) {
            Text("Uploaded").font(.headline)
            Picker("Uploaded", selection: $preset) {
                ForEach(DatePreset.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 150)
            if preset == .custom {
                DatePicker("From", selection: $customFrom, displayedComponents: .date)
                DatePicker("To", selection: $customTo, in: customFrom..., displayedComponents: .date)
            }
            Spacer()
            TextField("Search titles", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
        }
    }

    private var videoList: some View {
        let rows = shown
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(Format.count(rows.count)) videos in range").foregroundStyle(.secondary)
                Spacer()
                Button("Select All Shown") { scope.excludedIDs.subtract(rows.map(\.id)) }
                Button("Deselect All Shown") { scope.excludedIDs.formUnion(rows.map(\.id)) }
            }
            Table(rows) {
                TableColumn("") { v in
                    Toggle("", isOn: Binding(
                        get: { !scope.excludedIDs.contains(v.id) },
                        set: { on in if on { scope.excludedIDs.remove(v.id) } else { scope.excludedIDs.insert(v.id) } }))
                        .labelsHidden()
                }
                .width(24)
                TableColumn("Title") { v in Text(v.video.title).lineLimit(1) }
                    .width(min: 140, ideal: 220)
                TableColumn("Uploaded") { v in Text(v.video.created, format: .dateTime.year().month().day()).monospacedDigit() }
                    .width(100)
                TableColumn("Folder") { v in Text(v.folderPath).lineLimit(1).foregroundStyle(.secondary) }
                    .width(min: 70, ideal: 90)
                TableColumn("Size") { v in
                    Text(Format.estimate(quality.size(of: v.video)))
                        .monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(90)
                TableColumn("Have") { v in
                    HStack(spacing: 5) {
                        Circle().fill(v.category.color).frame(width: 8, height: 8)
                        Text(v.local == nil ? "—" : v.category.label).lineLimit(1)
                    }
                }
                .width(min: 90, ideal: 110)
            }
        }
    }

    private var qualityPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Quality").font(.headline)
            Picker("Quality", selection: $quality) {
                ForEach(Quality.allCases, id: \.self) { q in
                    let pending = toDownload(q)
                    Text("\(q.label)  ·  \(Format.count(pending.count)) videos  ·  \(Format.estimate(size(pending, q)))")
                        .monospacedDigit()
                        .tag(q)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }
}
