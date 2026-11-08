import AppKit
import Contracts
import SwiftUI
import UniformTypeIdentifiers

extension Category {
    /// Fixed colors, in bar order.
    var color: Color {
        switch self {
        case .original: .green
        case .fullResolution: .teal
        case .lower: .yellow
        case .missing: .gray
        case .unreachable: .red
        }
    }
}

/// Table rows need identity. A folder path is unique within one library.
extension FolderSummary: Identifiable {
    public var id: String { path }
}

extension SyncPhase {
    var caption: String {
        switch self {
        case .listingVimeo(let videos, let total):
            total.map { "Reading Vimeo: \(Format.count(videos)) of \(Format.count($0)) videos" } ?? "Connecting to Vimeo…"
        case .scanningDisk(let done, let total): "Scanning the backup folder: \(Format.count(done)) of \(Format.count(total))"
        case .relocating(let done, let total): "Moving relocated files: \(Format.count(done)) of \(Format.count(total))"
        case .downloading(let p): "Downloading \(Format.count(p.index)) of \(Format.count(p.total)): \(p.title)"
        case .throttled(let resumeAt): "Throttled by Vimeo, resuming \(Format.relative(resumeAt))"
        case .refreshingMetadata(let done, let total): "Refreshing details: \(Format.count(done)) of \(Format.count(total))"
        case .writingStatus: "Writing status.txt"
        }
    }

    /// Progress for the phases that have one; nil shows an indeterminate bar.
    var fraction: Double? {
        switch self {
        case .scanningDisk(let done, let total), .relocating(let done, let total), .refreshingMetadata(let done, let total):
            total > 0 ? Double(done) / Double(total) : nil
        case .downloading(let p): p.overallFraction
        case .listingVimeo(let videos, let total): total.flatMap { $0 > 0 ? Double(videos) / Double($0) : nil }
        case .throttled, .writingStatus: nil
        }
    }
}

/// The root screen: what is backed up, at what quality, and what is wrong.
struct OverviewView: View {
    @Bindable var model: AppModel
    @State private var choosingFolder = false
    @State private var showUnreachable = false
    @State private var showLocalOnly = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let s = model.summary {
                    header(s)
                    banner
                    bar(s)
                    legend(s)
                    complete(s)
                    folderTable(s)
                    lists(s)
                } else {
                    emptyHeader
                    banner
                    notChecked
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.isSyncing { progressStrip }
        }
        .toolbar { toolbar }
        .sheet(item: $model.sheet) { request in
            if let summary = model.summary, let root = model.root {
                DownloadSheet(model: model, summary: summary, root: root, request: request)
            }
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.setRoot(url) }
        }
    }

    // MARK: Header and problems

    private func header(_ s: LibrarySummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(s.accountName) · \(Format.count(s.total)) videos · \(Format.bytes(s.localBytes)) local")
                .font(.title2.weight(.semibold))
            (checked("Vimeo checked", s.vimeoCheckedAt) + Text("  ·  ") + checked("disk scanned", s.diskScannedAt))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.root?.lastPathComponent ?? "Vimeo Backup")
                .font(.title2.weight(.semibold))
            Text(model.root?.path ?? "")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    /// "Vimeo checked 3 minutes ago", or "Vimeo checked never" with "never" in red.
    private func checked(_ label: String, _ date: Date?) -> Text {
        guard let date else {
            return Text("\(label) ") + Text("never").foregroundStyle(.red)
        }
        return Text("\(label) \(Format.relative(date))")
    }

    /// Red banner for problems and the last error. Closing it hides these texts until a new one appears.
    @ViewBuilder private var banner: some View {
        let problems = model.visibleProblems
        if !problems.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(problems.count == 1 ? "1 problem" : "\(problems.count) problems",
                          systemImage: "exclamationmark.octagon.fill")
                        .font(.headline)
                    Spacer()
                    if let ids = model.summary?.mismatchedIDs, !ids.isEmpty {
                        Button("Re-download \(Format.count(ids.count))") {
                            model.openDownload(title: "Re-download broken originals", onlyIDs: Set(ids))
                        }
                        .disabled(model.isSyncing)
                    }
                    Button("Send Logs…") { model.sendLogs() }
                    Button { model.dismissProblems() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .help("Dismiss")
                }
                ForEach(Array(problems.enumerated()), id: \.offset) { _, text in
                    Text(text).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .foregroundStyle(.white)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: Bar, legend, completeness

    /// One stacked bar, fixed category order. Non-zero segments keep at least 3 pt.
    private func bar(_ s: LibrarySummary) -> some View {
        let counts = Category.allCases.map { s.stats[$0]?.count ?? 0 }
        return GeometryReader { geo in
            let widths = BarLayout.widths(counts: counts, width: geo.size.width)
            HStack(spacing: 0) {
                ForEach(Category.allCases.indices, id: \.self) { i in
                    Rectangle()
                        .fill(Category.allCases[i].color)
                        .frame(width: widths[i])
                }
            }
        }
        .frame(height: 28)
        .background(Color.secondary.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func legend(_ s: LibrarySummary) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
            ForEach(Category.allCases, id: \.self) { cat in
                let stat = s.stats[cat] ?? CategoryStat()
                GridRow {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(cat.color)
                        .frame(width: 14, height: 14)
                    Text(cat.label)
                    Text(Format.count(stat.count))
                        .monospacedDigit()
                        .gridColumnAlignment(.trailing)
                    Text(Format.percent(stat.count, of: s.total))
                        .monospacedDigit()
                        .gridColumnAlignment(.trailing)
                    Text(sizeText(cat, stat, s))
                        .monospacedDigit()
                        .foregroundStyle(cat == .unreachable ? .secondary : .primary)
                    action(cat, stat.count)
                }
            }
        }
    }

    private func sizeText(_ cat: Category, _ stat: CategoryStat, _ s: LibrarySummary) -> String {
        switch cat {
        case .missing: (s.missing.exact ? "" : "≈") + Format.bytes(s.missing.bytes) + " as originals"
        case .unreachable: ""
        default: Format.bytes(stat.bytes)
        }
    }

    @ViewBuilder private func action(_ cat: Category, _ count: Int) -> some View {
        let ids = Set(model.summary?.videos.filter { $0.category == cat }.map(\.id) ?? [])
        if cat == .lower, count > 0 {
            Button("Upgrade \(Format.count(count))…") { model.openDownload(title: "Upgrade lower-resolution copies", onlyIDs: ids) }
                .disabled(model.isSyncing)
        } else if cat == .missing || cat == .unreachable, count > 0 {
            Button("Download \(Format.count(count))…") { model.openDownload(title: "Download \(cat.label.lowercased())", onlyIDs: ids) }
                .disabled(model.isSyncing)
        }
    }

    private func complete(_ s: LibrarySummary) -> some View {
        Text("Complete: \(Format.count(s.completeCount)) / \(Format.count(s.total)) (\(Format.percent(s.completeCount, of: s.total)))")
            .font(.title.weight(.semibold))
            .monospacedDigit()
    }

    // MARK: Folders

    private func folderTable(_ s: LibrarySummary) -> some View {
        Table(of: FolderSummary.self) {
            TableColumn("Folder") { Text($0.path) }
                .width(min: 160, ideal: 220)
            TableColumn("Videos") { folder in
                Text(Format.count(folder.total)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70)
            TableColumn("Orig %") { share($0, .original) }
            TableColumn("Full %") { share($0, .fullResolution) }
            TableColumn("Lower %") { share($0, .lower) }
            TableColumn("Missing %") { share($0, .missing) }
            TableColumn("Size") { folder in
                Text(Format.bytes(folder.bytes)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 80)
        } rows: {
            ForEach(s.folders) { TableRow($0) }
        }
        .frame(height: 260)
    }

    private func share(_ folder: FolderSummary, _ cat: Category) -> some View {
        Text(Format.percent(folder.stats[cat]?.count ?? 0, of: folder.total, decimals: 0))
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: Lists

    private func lists(_ s: LibrarySummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DisclosureGroup(isExpanded: $showUnreachable) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(s.failures, id: \.videoID) { failure in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(failure.title)
                                    Text(failure.reason).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 12)
                                if let url = Format.vimeoURL(failure.videoID) {
                                    Link(url.absoluteString, destination: url).font(.caption)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 200)
            } label: {
                Text("Unreachable · \(s.failures.count)").font(.headline)
            }

            DisclosureGroup(isExpanded: $showLocalOnly) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(s.localOnly, id: \.url) { file in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.url.lastPathComponent)
                                Text(Format.bytes(file.sizeBytes)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 12)
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([file.url])
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            } label: {
                Text("Local only, removed on Vimeo · \(s.localOnly.count)").font(.headline)
            }
        }
    }

    // MARK: Not checked yet

    @ViewBuilder private var notChecked: some View {
        if model.isSyncing {
            VStack(spacing: 10) {
                ProgressView()
                Text("Checking…").font(.title3.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
            notCheckedIdle
        }
    }

    private var notCheckedIdle: some View {
        VStack(spacing: 10) {
            Text("Not checked yet").font(.title3.weight(.semibold))
            Button("Check now") { model.refresh() }
                .disabled(model.isSyncing || model.root == nil)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: Progress and toolbar

    private var progressStrip: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.phase?.caption ?? "Checking for yt-dlp updates…")
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if case .downloading(let p) = model.phase {
                    ProgressView(value: p.videoFraction) {
                        Text("This video").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let fraction = model.phase?.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Format.progressLine(phase: model.phase, clock: model.clock, now: context.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Button(isDownloading ? "Stop" : "Cancel") { model.cancel() }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private var isDownloading: Bool {
        if case .downloading = model.phase { return true }
        if case .throttled = model.phase { return true }
        return false
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { choosingFolder = true } label: {
                Label(model.root?.lastPathComponent ?? "Choose Folder…", systemImage: "folder")
                    .labelStyle(.titleAndIcon)
            }
            .help("Change backup folder")
            .disabled(model.isSyncing)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { model.refresh() } label: {
                Label("Check now", systemImage: "arrow.clockwise")
            }
            .disabled(model.isSyncing || model.root == nil)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { model.openDownload() } label: {
                Label("Download…", systemImage: "arrow.down.circle")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(model.isSyncing || model.summary == nil)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { model.showHelp = true } label: { Label("Getting Started", systemImage: "questionmark.circle") }
                .help("Getting started")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Repeat Last Download…") { model.repeatLastDownload() }
                    .disabled(model.isSyncing || model.summary == nil || model.lastDownload == nil)
                Divider()
                Button("Send Logs…") { model.sendLogs() }
                    .disabled(model.root == nil)
                Divider()
                Button("Sign Out of Vimeo") { model.signOut() }
                    .disabled(model.isSyncing)
            } label: {
                Label("Account", systemImage: "person.crop.circle")
            }
        }
    }
}
