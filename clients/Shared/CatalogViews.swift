import SwiftUI
import UniformTypeIdentifiers
import LibraryCore
import PDFKit

/// A result belongs to one immutable workspace/query snapshot. Moving the metadata
/// scan and disk checks off the main actor keeps typing and sheet dismissal responsive.
struct CatalogWorkspaceSearchRequest: Equatable, Sendable {
    let workspacePath: String
    let documents: [LibraryDocument]
    let query: CatalogQuery
    let sort: CatalogSort
}

struct CatalogWorkspaceSearchResult: Sendable {
    let request: CatalogWorkspaceSearchRequest
    let documents: [LibraryDocument]
    let coverage: LibrarySearchCoverage?
    let errorMessage: String?

    static func load(_ request: CatalogWorkspaceSearchRequest, store: DocumentStore) async -> Self? {
        guard !Task.isCancelled, request.workspacePath == store.root.path else { return nil }
        let work = Task.detached(priority: .userInitiated) { () -> Self? in
            guard !Task.isCancelled else { return nil }
            var indexedMatches = Set<String>()
            var coverage: LibrarySearchCoverage?
            var errorMessage: String?
            if !request.query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                do {
                    indexedMatches = Set(try store.search(query: request.query.text))
                    coverage = try store.searchCoverage()
                } catch {
                    errorMessage = "正文索引读取失败：\(error.localizedDescription)。标题和书目信息仍可搜索。"
                }
            }
            guard !Task.isCancelled else { return nil }
            let documents = request.query.results(in: request.documents, indexedMatches: indexedMatches, sort: request.sort)
            guard !Task.isCancelled else { return nil }
            return Self(request: request, documents: documents, coverage: coverage, errorMessage: errorMessage)
        }
        return await withTaskCancellationHandler {
            let result = await work.value
            return Task.isCancelled ? nil : result
        } onCancel: { work.cancel() }
    }
}

/// Shared catalog UI. The host owns navigation, sync scheduling and the document snapshot.
struct CatalogWorkspaceView: View {
    let documents: [LibraryDocument]
    let store: DocumentStore
    let parentID: String
    var onChange: () -> Void
    var onOpen: (LibraryDocument) -> Void
    var onOpenSource: ((LibraryDocument, Int?, String?) -> Void)? = nil
    var currentDeviceID: String? = nil

    @State private var section: CatalogSection = .all
    @State private var query = ""
    @State private var filters = CatalogViewFilters()
    @State private var sort: CatalogSort = .title
    @State private var filtersPresented = false
    @State private var topicID: String?
    @State private var searchResult: CatalogWorkspaceSearchResult?
    @State private var inspected: LibraryDocument?
    @State private var newTopic = false
    @State private var topicName = ""
    @State private var deletingTopic: LibraryDocument?
    @State private var errorMessage: String?

    private var availableTags: [String] {
        Array(Set(documents.filter { $0.state == "active" && $0.kind != .folder }.flatMap { $0.catalog.tags })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private var hasSelection: Bool { filters.count > 0 || sort != .title }

    private func content(_ response: CatalogWorkspaceSearchResult?) -> some View {
        let currentResults = response?.documents ?? []
        return VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CatalogSection.allCases, id: \.self) { item in
                        Button {
                            section = item; topicID = nil
                            if item == .topics { filters = CatalogViewFilters(); sort = .title }
                            if [.inbox, .reading, .archived].contains(item) { filters.archive = .all }
                            if item == .reading { filters.readingStatus = nil }
                        } label: {
                            Label(item.title, systemImage: item.symbol)
                                .font(.subheadline)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(section == item ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.07), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(section == item ? .isSelected : [])
                    }
                }
                .padding()
            }
            if let topicID, let topic = documents.first(where: { $0.id == topicID }) {
                HStack {
                    Label(topic.catalogTitle, systemImage: "square.stack.3d.up")
                    Spacer()
                    Button("查看全部") { self.topicID = nil }
                }.padding(.horizontal).padding(.bottom, 8)
            }
            if hasSelection {
                HStack(alignment: .top, spacing: 12) {
                    Text((filters.summary.isEmpty ? "" : filters.summary + " · ") + "按" + sort.title + "排序")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    Button("清除筛选") { filters = CatalogViewFilters(); sort = .title }
                        .font(.caption)
                }.padding(.horizontal).padding(.bottom, 8)
            }
            if response == nil {
                ProgressView("正在查找资料…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if currentResults.isEmpty {
                ContentUnavailableView {
                    Label(filters.count > 0 ? "没有符合条件的资料" : (query.isEmpty ? (topicID == nil ? "这里还没有资料" : "这个专题还没有资料") : "没有找到匹配资料"), systemImage: section.symbol)
                } description: {
                    Text(emptyDescription)
                    if !query.isEmpty, let coverage = response?.coverage { Text(coverage.summary) }
                } actions: {
                    if filters.count > 0 { Button("清除筛选") { filters = CatalogViewFilters() } }
                    if section == .topics { Button("新建专题") { newTopic = true } }
                    else if !query.isEmpty { Button("清除搜索") { query = "" } }
                }
            } else {
                List {
                    Section {
                        ForEach(currentResults, id: \.id) { doc in catalogRow(doc) }
                    } header: {
                        Text("\(currentResults.count) 项资料")
                    } footer: {
                        if !query.isEmpty {
                            Text((response?.coverage?.summary ?? "本机全文覆盖统计暂不可用。") + "归档资料仍可检索。")
                        }
                    }
                }
            }
        }
    }

    var body: some View {
        let request = CatalogWorkspaceSearchRequest(workspacePath: store.root.path, documents: documents,
                                                   query: filters.query(section: section, text: query, topicID: topicID), sort: sort)
        let response = searchResult?.request == request ? searchResult : nil
        return content(response)
        .navigationTitle("个人资料库")
        .searchable(text: $query, prompt: "标题、作者、正文、摘录")
        .toolbar {
            Button { filtersPresented = true } label: {
                Label(filters.count == 0 ? "筛选与排序" : "筛选（\(filters.count)）", systemImage: "line.3.horizontal.decrease.circle")
            }.accessibilityValue("\(filters.count) 项条件，按\(sort.title)排序")
            Button { newTopic = true } label: { Label("新建专题", systemImage: "folder.badge.plus") }
        }
        .sheet(isPresented: $filtersPresented) {
            CatalogFilterSheet(initial: filters, initialSort: sort, section: section, tags: availableTags) { updated, sorting in
                filters = updated; sort = sorting; filtersPresented = false
            }
            .id(store.root.path)
        }
        .alert("新建专题", isPresented: $newTopic) {
            TextField("例如：分布式系统", text: $topicName)
            Button("取消", role: .cancel) { topicName = "" }
            Button("创建") {
                perform {
                    let created = try store.createCatalogTopic(name: topicName, parentID: parentID)
                    topicName = ""; section = .all; topicID = created.id; filters = CatalogViewFilters()
                }
            }
        } message: { Text("专题收集相关书籍、论文与笔记，加入专题不会复制或移动文件。") }
        .sheet(isPresented: Binding(get: { inspected != nil }, set: { if !$0 { inspected = nil } })) {
            if let item = inspected {
            NavigationStack {
                CatalogInspectorView(document: item, documents: documents, store: store, onChange: onChange, onOpen: {
                    inspected = nil
                    onOpen($0)
                }, onOpenSource: { source, page, hash in
                    inspected = nil
                    if let onOpenSource { onOpenSource(source, page, hash) }
                    else { onOpen(source) }
                }, currentDeviceID: currentDeviceID)
                .id(store.root.path + "/" + item.id)
            }
            .frame(minWidth: 340, minHeight: 520)
            }
        }
        .confirmationDialog("删除专题？", isPresented: Binding(get: { deletingTopic != nil }, set: { if !$0 { deletingTopic = nil } }), titleVisibility: .visible) {
            Button("删除专题，保留资料", role: .destructive) {
                guard let topic = deletingTopic else { return }
                perform { try store.trash(id: topic.id) }
                deletingTopic = nil
            }
            Button("取消", role: .cancel) { deletingTopic = nil }
        } message: {
            Text("专题进入回收站，成员资料与引用保留。旧版本中放在专题文件夹里的文件会移到上一级，不会被删除。")
        }
        .alert("未能完成操作", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("知道了", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .onChange(of: store.root) { _, _ in
            inspected = nil; deletingTopic = nil; newTopic = false; topicName = ""; filtersPresented = false
            filters = CatalogViewFilters(); sort = .title
            section = .all; topicID = nil; query = ""; searchResult = nil
        }
        .task(id: request) {
            if !request.query.text.isEmpty {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            }
            guard let result = await CatalogWorkspaceSearchResult.load(request, store: store), !Task.isCancelled else { return }
            searchResult = result
            if let message = result.errorMessage { errorMessage = message }
        }
    }

    private func catalogRow(_ doc: LibraryDocument) -> some View {
        HStack(spacing: 12) {
            Button {
                if doc.isCatalogTopic { topicID = doc.id; section = .all }
                else { onOpen(doc) }
            } label: { CatalogDocumentRow(document: doc) }
            .buttonStyle(.plain)
            Spacer(minLength: 4)
            Button { inspected = doc } label: { Image(systemName: "info.circle") }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(doc.catalogTitle) 的资料详情")
            Menu { catalogActions(doc) } label: {
                Label("更多", systemImage: "ellipsis.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("\(doc.catalogTitle) 的更多操作")
            .accessibilityIdentifier("catalog-actions-\(doc.id)")
        }
        .contextMenu { catalogActions(doc) }
    }

    @ViewBuilder
    private func catalogActions(_ doc: LibraryDocument) -> some View {
        Button("资料详情") { inspected = doc }
        if doc.catalog.inbox { Button("整理完成") { perform { _ = try store.markCatalogOrganized(id: doc.id) } } }
        Button(doc.catalog.archived ? "恢复整理" : "归档") {
            perform { _ = try store.setCatalogArchived(id: doc.id, archived: !doc.catalog.archived) }
        }
        if let topicID {
            Button("移出此专题") { perform { _ = try store.setCatalogTopic(id: doc.id, topicID: topicID, included: false) } }
        }
        if doc.isCatalogTopic {
            Button("删除专题", role: .destructive) { deletingTopic = doc }
        }
    }

    private var emptyDescription: String {
        if filters.count > 0 { return "尝试减少筛选条件，或清除筛选后查看全部资料。" }
        if !query.isEmpty { return "尝试标题、作者或摘录中的词语；未下载的文件不参与正文搜索。" }
        if topicID != nil { return "打开资料详情，在“整理”中勾选此专题；加入专题不会复制或移动原件。" }
        switch section {
        case .inbox: return "新导入的资料在这里整理。阅读不需要等到信息填写完成。"
        case .topics: return "为研究问题创建专题。同一资料可以加入多个专题。"
        case .archived: return "归档资料长期保留，可以搜索、阅读和恢复整理。"
        case .reading: return "在资料详情中设为“在读”，即可从这里继续阅读。"
        default: return "导入 PDF 或创建笔记后，在资料详情中选择书籍、论文或笔记。"
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); onChange() }
        catch { errorMessage = error.localizedDescription }
    }
}

private struct CatalogViewFilters: Equatable {
    var author = ""
    var tag = ""
    var yearFrom = ""
    var yearTo = ""
    var readingStatus: CatalogReadingStatus?
    var archive: CatalogArchiveFilter = .all
    var availability: CatalogAvailabilityFilter = .all
    var count: Int {
        [!author.isEmpty, !tag.isEmpty, !yearFrom.isEmpty || !yearTo.isEmpty, readingStatus != nil, archive != .all, availability != .all].filter { $0 }.count
    }
    var summary: String {
        var parts: [String] = []
        if !author.isEmpty { parts.append("作者：" + author) }
        if !tag.isEmpty { parts.append("标签：" + tag) }
        if !yearFrom.isEmpty || !yearTo.isEmpty { parts.append("年份：" + (yearFrom.isEmpty ? "不限" : yearFrom) + "—" + (yearTo.isEmpty ? "不限" : yearTo)) }
        if let readingStatus { parts.append(readingStatus.title) }
        if archive != .all { parts.append(archive.title) }
        if availability != .all { parts.append(availability.title) }
        return parts.joined(separator: " · ")
    }
    var validationMessage: String? {
        for value in [yearFrom, yearTo] where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let year = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)), (1...9999).contains(year) else { return "年份请输入 1—9999，留空表示不限。" }
        }
        if let start = Int(yearFrom.trimmingCharacters(in: .whitespacesAndNewlines)), let end = Int(yearTo.trimmingCharacters(in: .whitespacesAndNewlines)), start > end { return "起始年份不能晚于结束年份。" }
        return nil
    }
    func query(section: CatalogSection, text: String, topicID: String?) -> CatalogQuery {
        CatalogQuery(section: section, text: text, topicID: topicID, tag: tag.isEmpty ? nil : tag, readingStatus: readingStatus,
                     author: author.isEmpty ? nil : author, yearFrom: Int(yearFrom), yearTo: Int(yearTo), archive: archive, availability: availability)
    }
    mutating func normalize() {
        author = author.trimmingCharacters(in: .whitespacesAndNewlines); tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        yearFrom = yearFrom.trimmingCharacters(in: .whitespacesAndNewlines); yearTo = yearTo.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct CatalogFilterSheet: View {
    let section: CatalogSection
    let tags: [String]
    let apply: (CatalogViewFilters, CatalogSort) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CatalogViewFilters
    @State private var sorting: CatalogSort
    @State private var validation: String?
    init(initial: CatalogViewFilters, initialSort: CatalogSort, section: CatalogSection, tags: [String], apply: @escaping (CatalogViewFilters, CatalogSort) -> Void) {
        self.section = section; self.tags = tags; self.apply = apply
        _draft = State(initialValue: initial); _sorting = State(initialValue: initialSort)
    }
    private var tagSuggestions: [String] {
        Array(tags.filter { draft.tag.isEmpty || $0.range(of: draft.tag, options: [.caseInsensitive, .diacriticInsensitive]) != nil }.prefix(8))
    }
    var body: some View {
        NavigationStack {
            Form {
                if section != .topics {
                    Section("书目信息") {
                        TextField("作者或机构名称", text: $draft.author)
                        TextField("起始年份（可留空）", text: $draft.yearFrom)
                        TextField("结束年份（可留空）", text: $draft.yearTo)
                        TextField("标签完整名称", text: $draft.tag)
                        if !draft.tag.isEmpty { Button("清除标签条件") { draft.tag = "" } }
                        if !tagSuggestions.isEmpty {
                            ScrollView(.horizontal, showsIndicators: true) {
                                HStack {
                                    ForEach(tagSuggestions, id: \.self) { tag in
                                        Button(tag) { draft.tag = tag }.buttonStyle(.bordered)
                                            .accessibilityLabel("筛选标签：" + tag)
                                    }
                                }.padding(.vertical, 4)
                            }
                        }
                        Text("作者按名称匹配；标签按完整名称匹配。输入文字可查找标签建议。未填写年份的资料不会出现在年份筛选结果中。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("阅读与保存") {
                        if section != .reading {
                            Picker("阅读状态", selection: $draft.readingStatus) {
                                Text("不限").tag(Optional<CatalogReadingStatus>.none)
                                ForEach(CatalogReadingStatus.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                            }
                        }
                        if ![.reading, .inbox, .archived].contains(section) {
                            Picker("归档状态", selection: $draft.archive) {
                                ForEach(CatalogArchiveFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                        }
                        Picker("本机原件", selection: $draft.availability) {
                            ForEach(CatalogAvailabilityFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        Text("原件已下载与有可搜索文字不同；扫描 PDF 也可以在本机阅读。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("排序") {
                    Picker("顺序", selection: $sorting) {
                        ForEach(section == .topics ? [.title] : CatalogSort.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                if let validation { Section { Text(validation).foregroundStyle(.red).accessibilityLabel(validation) } }
                Section { Button("重置全部条件和排序") { draft = CatalogViewFilters(); sorting = .title; validation = nil } }
            }
            .navigationTitle("筛选与排序")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        draft.normalize()
                        if let error = draft.validationMessage { validation = error; return }
                        apply(draft, sorting)
                    }
                }
            }
        }.frame(minWidth: 340, minHeight: 520)
    }
}

private struct CatalogDocumentRow: View {
    let document: LibraryDocument
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: document.catalog.category.symbol).font(.title2).foregroundStyle(.tint)
                .frame(width: 32).padding(.top, 3)
            VStack(alignment: .leading, spacing: 5) {
                Text(document.catalogTitle).font(.headline).multilineTextAlignment(.leading)
                if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                HStack(spacing: 8) {
                    if document.catalog.archived { Label("归档", systemImage: "archivebox") }
                    else if document.catalog.inbox { Label("待整理", systemImage: "tray") }
                    if document.kind != .folder { Text(document.catalog.readingStatus.title) }
                    Text(document.status.rawValue)
                }.font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
    private var subtitle: String {
        let m = document.catalog
        return [m.authors.joined(separator: "、"), m.year.map(String.init) ?? "", m.publication]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

enum CatalogDocumentSelectionPurpose: String, Identifiable {
    case related, excerptNote
    var id: String { rawValue }
    var title: String { self == .related ? "选择相关资料" : "选择摘录笔记" }
}

struct CatalogSelectionCandidate: Identifiable {
    let id: String
    let title: String
    let filename: String
    let folderPath: String
    let typeLabel: String
    let symbol: String
    let archived: Bool
    let searchText: String
}

enum CatalogDocumentSelection {
    static func candidates(in documents: [LibraryDocument], source: LibraryDocument,
                           purpose: CatalogDocumentSelectionPurpose, inventory: LegacyLibraryInventory? = nil) -> [CatalogSelectionCandidate] {
        let scope = CatalogLibraryScope(documents: documents + (documents.contains { $0.id == source.id } ? [] : [source]), inventory: inventory)
        let byID = Dictionary(documents.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let sourceRelatedIDs = Set(source.catalog.relatedIDs)
        return documents.compactMap { item in
            guard item.state == "active", item.id != source.id, item.kind != .folder, scope.contains(item.id, alongside: source.id) else { return nil }
            let metadata = item.catalog
            switch purpose {
            case .related:
                guard !sourceRelatedIDs.contains(item.id), !metadata.relatedIDs.contains(source.id) else { return nil }
            case .excerptNote:
                guard item.kind == .md, !metadata.archived else { return nil }
            }
            let path = folderPath(for: item, byID: byID, virtualRoots: scope.virtualRoots)
            let type = metadata.category.title + " · " + (item.kind == .pdf ? "PDF" : "Markdown")
            let title = item.catalogTitle
            return CatalogSelectionCandidate(id: item.id, title: title, filename: item.name, folderPath: path,
                typeLabel: type, symbol: metadata.category.symbol, archived: metadata.archived,
                searchText: [title, item.name, metadata.originalFilename, path, type, metadata.authors.joined(separator: " ")].joined(separator: " "))
        }.sorted { lhs, rhs in
            for (left, right) in [(lhs.title, rhs.title), (lhs.folderPath, rhs.folderPath), (lhs.filename, rhs.filename)] {
                let order = left.localizedStandardCompare(right)
                if order != .orderedSame { return order == .orderedAscending }
            }
            return lhs.id < rhs.id
        }
    }

    static func matching(_ candidates: [CatalogSelectionCandidate], query: String) -> [CatalogSelectionCandidate] {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return candidates.filter { candidate in terms.allSatisfy { candidate.searchText.localizedStandardContains($0) } }
    }

    private static func folderPath(for document: LibraryDocument, byID: [String: LibraryDocument], virtualRoots: Set<String>) -> String {
        var cursor = document.parentId
        var names: [String] = []
        var visited: Set<String> = [document.id]
        while !cursor.isEmpty && !(virtualRoots.contains(cursor) && byID[cursor] == nil) {
            guard visited.insert(cursor).inserted else {
                return (["目录关系异常"] + names.reversed()).joined(separator: " / ")
            }
            guard let parent = byID[cursor], parent.kind == .folder else {
                return (["目录尚未载入"] + names.reversed()).joined(separator: " / ")
            }
            names.append(parent.name)
            cursor = parent.parentId
        }
        return (["资料库"] + names.reversed()).joined(separator: " / ")
    }
}

private struct CatalogSelectionCandidateRow: View {
    let candidate: CatalogSelectionCandidate

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: candidate.symbol).foregroundStyle(.tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(candidate.title).font(.headline).multilineTextAlignment(.leading)
                Text("文件：" + candidate.filename).font(.caption).foregroundStyle(.secondary)
                Text(candidate.folderPath).font(.caption).foregroundStyle(.secondary)
                Text(candidate.typeLabel + (candidate.archived ? " · 已归档" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct CatalogDocumentSelectionSheet: View {
    let purpose: CatalogDocumentSelectionPurpose
    let candidates: [CatalogSelectionCandidate]
    let selectedID: String
    var onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    init(purpose: CatalogDocumentSelectionPurpose, candidates: [CatalogSelectionCandidate], selectedID: String,
         onSelect: @escaping (String) -> Void) {
        self.purpose = purpose
        self.candidates = candidates
        self.selectedID = selectedID
        self.onSelect = onSelect
    }

    var body: some View {
        let matches = CatalogDocumentSelection.matching(candidates, query: query)
        NavigationStack {
            List {
                if purpose == .excerptNote {
                    Section {
                        Button {
                            onSelect("")
                        } label: {
                            HStack {
                                Label("新建阅读笔记", systemImage: "square.and.pencil")
                                Spacer()
                                if selectedID.isEmpty { Image(systemName: "checkmark") }
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                Section {
                    if matches.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(query.isEmpty ? "没有可选资料" : "没有匹配的资料").font(.headline)
                            Text(query.isEmpty
                                 ? (purpose == .related ? "当前资料及已关联的资料不会重复显示。" : "可选择未归档的 Markdown 笔记，或新建阅读笔记。")
                                 : "尝试文件名、所在目录、作者或资料类型。")
                                .font(.subheadline).foregroundStyle(.secondary)
                            if !query.isEmpty { Button("清除搜索") { query = "" } }
                        }.padding(.vertical, 8)
                    }
                    ForEach(matches) { candidate in
                        Button { onSelect(candidate.id) } label: {
                            HStack {
                                CatalogSelectionCandidateRow(candidate: candidate)
                                if selectedID == candidate.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                } header: { Text("\(matches.count) 项" + (purpose == .excerptNote ? "可用笔记" : "可关联资料")) }
            }
            .navigationTitle(purpose.title)
            .searchable(text: $query, prompt: "标题、文件名、目录、作者")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.keyboardShortcut(.cancelAction) } }
        }
        .frame(minWidth: 320, idealWidth: 580, minHeight: 420, idealHeight: 640)
    }
}

/// Labels never infer that an unknown device is the current device. The host passes
/// its identity; previews and other hosts can still present a neutral device record.
struct CatalogReadingPositionPresentation: Equatable {
    let id: String
    let title: String
    let summary: String
    let updatedAt: Date

    init(position: CatalogReadingPosition, currentDeviceID: String?) {
        id = position.id
        if position.deviceID == "manual" {
            title = "手动记录"
        } else if let currentDeviceID,
                  position.deviceID.caseInsensitiveCompare(currentDeviceID) == .orderedSame {
            title = "本机自动记录"
        } else {
            let source = currentDeviceID == nil ? "设备记录" : "其他设备"
            title = source + " · " + String(position.deviceID.prefix(8))
        }
        summary = position.summary
        updatedAt = position.updatedAt
    }
}

private struct CatalogReadingPositionRow: View {
    let record: CatalogReadingPositionPresentation

    private var updated: String {
        record.updatedAt.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(record.title).font(.subheadline.weight(.semibold))
            Text(record.summary)
            Text("更新于 \(updated)").font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(record.title + "，阅读位置")
        .accessibilityValue(record.summary + "，更新于 " + updated)
        .accessibilityIdentifier("catalog-reading-position-" + record.id)
    }
}

/// Resolve the current hierarchy using only recorded roots. An inventory supplies
/// legacy virtual root identities, never permission to promote arbitrary orphans.
struct CatalogLibraryScope {
    let virtualRoots: Set<String>
    private let roots: [String: String]

    init(documents: [LibraryDocument], inventory: LegacyLibraryInventory? = nil) {
        virtualRoots = Set(inventory?.rootIDs ?? ["root"])
        let byID = Dictionary(documents.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var resolved: [String: String] = [:], invalid = Set<String>()
        for start in byID.keys {
            var cursor = start, visited = Set<String>(), chain: [String] = [], root: String?
            while visited.insert(cursor).inserted {
                if cursor != start, let parent = byID[cursor], parent.kind != .folder { break }
                if let known = resolved[cursor] { root = known; break }
                if invalid.contains(cursor) { break }
                guard let item = byID[cursor] else {
                    if virtualRoots.contains(cursor) { root = cursor }
                    break
                }
                guard item.state == "active" else { break }
                chain.append(cursor)
                if item.parentId.isEmpty {
                    if item.kind == .folder && !item.isCatalogTopic { root = item.id }
                    break
                }
                cursor = item.parentId
            }
            if let root { for id in chain { resolved[id] = root } }
            else { invalid.formUnion(chain) }
        }
        roots = resolved
    }

    func contains(_ id: String, alongside sourceID: String) -> Bool {
        guard let root = roots[sourceID] else { return false }
        return roots[id] == root
    }
}

struct CatalogInspectorDraft {
    private(set) var baseline: CatalogMetadata
    var metadata: CatalogMetadata
    var authors: String
    var tags: String
    var year: String

    init(_ metadata: CatalogMetadata = CatalogMetadata()) {
        baseline = metadata; self.metadata = metadata
        authors = metadata.authors.joined(separator: "、")
        tags = metadata.tags.joined(separator: "、")
        year = metadata.year.map(String.init) ?? ""
    }

    var isDirty: Bool {
        CatalogMetadataEdit(baseline: baseline, proposed: metadata).isDirty
            || authors != baseline.authors.joined(separator: "、")
            || tags != baseline.tags.joined(separator: "、")
            || year != (baseline.year.map(String.init) ?? "")
    }

    mutating func save(id: String, kind: DocKind, store: DocumentStore) throws -> LibraryDocument {
        let trimmed = year.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || Int(trimmed) != nil else { throw CatalogError.invalidMetadata }
        func split(_ text: String) -> [String] {
            text.components(separatedBy: CharacterSet(charactersIn: ",，、;；"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        var proposed = metadata
        proposed.category = kind == .folder ? .topic : metadata.category
        proposed.authors = split(authors); proposed.year = Int(trimmed); proposed.tags = split(tags)
        let saved = try store.updateCatalog(id: id, edit: CatalogMetadataEdit(baseline: baseline, proposed: proposed))
        self = CatalogInspectorDraft(saved.catalog)
        return saved
    }
}

enum CatalogInspectorDestination {
    case done, document(LibraryDocument), source(LibraryDocument, Int?, String?)
}

struct CatalogInspectorNavigation {
    enum Decision { case save, discard, cancel }
    private(set) var pending: CatalogInspectorDestination?

    mutating func request(_ destination: CatalogInspectorDestination, dirty: Bool) -> CatalogInspectorDestination? {
        if dirty { pending = destination; return nil }
        pending = nil
        return destination
    }

    mutating func resolve(_ decision: Decision, save: () throws -> Void) throws -> CatalogInspectorDestination? {
        guard let destination = pending else { return nil }
        if decision == .cancel { pending = nil; return nil }
        if decision == .save { try save() }
        // A failed save leaves both the destination and the caller's draft intact.
        pending = nil
        return destination
    }
}

struct CatalogRelatedEntry: Identifiable {
    let id: String
    let document: LibraryDocument?
    static func entries(source: LibraryDocument, documents: [LibraryDocument]) -> [Self] {
        let byID = Dictionary(documents.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let ids = Set(source.catalog.relatedIDs).union(documents.filter { ["active", "trashed"].contains($0.state) && ($0.purgeAt.map { $0 > Date() } ?? true) && $0.catalog.relatedIDs.contains(source.id) }.map(\.id)).subtracting([source.id])
        return ids.sorted().map { Self(id: $0, document: byID[$0]) }
    }
}

struct CatalogInspectorView: View {
    let document: LibraryDocument
    let documents: [LibraryDocument]
    let store: DocumentStore
    var onChange: () -> Void
    var onOpen: (LibraryDocument) -> Void
    var onOpenSource: ((LibraryDocument, Int?, String?) -> Void)? = nil
    var currentDeviceID: String? = nil

    @State private var current: LibraryDocument?
    @Environment(\.dismiss) private var dismiss
    @State private var form = CatalogInspectorDraft()
    @State private var navigation = CatalogInspectorNavigation()
    @State private var confirmLeave = false
    @State private var confirmReload = false
    @State private var quote = ""
    @State private var comment = ""
    @State private var page = ""
    @State private var targetNoteID = ""
    @State private var excerptOperationID = UUID().uuidString.lowercased()
    @State private var excerptRefreshNeeded = false
    @State private var relatedTargetID = ""
    @State private var documentSelection: CatalogDocumentSelectionPurpose?
    @State private var errorMessage: String?
    @State private var notice = ""
    @State private var sourceStates: [String: CatalogSourceState] = [:]
    @State private var revisionPicker = false

    private var doc: LibraryDocument { current ?? document }
    private var inventory: LegacyLibraryInventory? { try? store.legacyLibraryInventory() }
    private var topics: [LibraryDocument] {
        let scope = CatalogLibraryScope(documents: documents, inventory: inventory)
        return documents.filter { $0.state == "active" && $0.isCatalogTopic && scope.contains($0.id, alongside: doc.id) && (!$0.catalog.archived || doc.catalog.topicIDs.contains($0.id)) }
    }
    private var notes: [CatalogSelectionCandidate] { CatalogDocumentSelection.candidates(in: documents, source: doc, purpose: .excerptNote, inventory: inventory) }
    private var sources: [CatalogSelectionCandidate] { CatalogDocumentSelection.candidates(in: documents, source: doc, purpose: .related, inventory: inventory) }

    var body: some View {
        Form {
            if doc.catalog.archived {
                Section {
                    Label("已归档 · 原件和关联仍保留", systemImage: "archivebox")
                    Button("恢复整理") { perform { _ = try store.setCatalogArchived(id: doc.id, archived: false) } }
                }
            }
            metadataSection
            organizationSection
            if doc.kind != .folder {
                readingSection
                excerptComposer
                referencesSection
                sourceSection
            }
            if !notice.isEmpty {
                Section {
                    Text(notice).foregroundStyle(.secondary).accessibilityLabel(notice)
                    if excerptRefreshNeeded { Button("重新载入资料") { refreshAfterSavedExcerpt() } }
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $revisionPicker, allowedContentTypes: [.pdf], allowsMultipleSelection: false) { result in
            replacePDFOriginal(result)
        }
        .navigationTitle("资料详情")
        .interactiveDismissDisabled(hasUnsavedInputs)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("完成") { requestLeave(.done) } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存资料信息") { saveDraft() }
                    .disabled(doc.catalog.archived || !hasDraftChanges || doc.state != "active")
                    .accessibilityLabel("保存资料信息")
            }
        }
        .confirmationDialog("有尚未保存的输入", isPresented: $confirmLeave, titleVisibility: .visible) {
            if !hasUnsubmittedExcerpt { Button("保存并继续") { resolveLeave(.save) } }
            Button("放弃未保存输入", role: .destructive) { resolveLeave(.discard) }
            Button("继续编辑", role: .cancel) { resolveLeave(.cancel) }
        } message: {
            if hasUnsubmittedExcerpt {
                Text("摘录或评论还未加入笔记。请继续编辑并点击“创建阅读笔记”或“加入所选笔记”保存；书目信息可用“保存资料信息”保存。放弃会丢弃未保存的书目、摘录和评论，已保存内容仍保留。")
            } else {
                Text("标题、作者、年份等书目信息尚未保存。放弃会丢弃这些表单修改，已保存的摘录和整理操作会保留。")
            }
        }
        .onAppear { receive(documents.first(where: { $0.id == document.id }) ?? document) }
        .onChange(of: document.id) { _, _ in
            current = document; loadDraft(); quote = ""; comment = ""; page = ""
            targetNoteID = ""; relatedTargetID = ""; notice = ""; sourceStates = [:]
            documentSelection = nil
            excerptOperationID = UUID().uuidString.lowercased(); excerptRefreshNeeded = false
        }
        .onChange(of: documents) { _, latest in
            if let updated = latest.first(where: { $0.id == document.id }) { receive(updated) }
        }
        .task(id: doc.metadataJSON) { await refreshSourceStates() }
        .task(id: documents) { await refreshSourceStates() }
        .sheet(item: $documentSelection) { purpose in
            CatalogDocumentSelectionSheet(purpose: purpose, candidates: purpose == .related ? sources : notes,
                selectedID: purpose == .related ? relatedTargetID : targetNoteID) { id in
                    if purpose == .related { relatedTargetID = id }
                    else { targetNoteID = id }
                    documentSelection = nil
                }
                .id(store.root.path + "/" + doc.id + "/" + purpose.rawValue)
        }
        .alert("未能保存", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("知道了", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .alert("重新载入资料信息？", isPresented: $confirmReload) {
            Button("保留输入", role: .cancel) {}
            Button("重新载入", role: .destructive) {
                do {
                    guard let latest = try store.loadDocument(id: document.id), latest.state == "active" else { throw CatalogError.notFound }
                    current = latest; loadDraft(); notice = "已载入最新资料信息。"
                } catch { errorMessage = error.localizedDescription }
            }
        } message: { Text("将放弃当前表单中尚未保存的修改，重新显示本机最新信息。已保存的资料不会被更改。") }
    }

    private var metadataSection: some View {
        Section {
            inspectorTextField("显示标题（留空使用文件名）", text: $form.metadata.title)
            if doc.kind != .folder {
                inspectorField("资料类型") {
                    Picker("资料类型", selection: $form.metadata.category) {
                        ForEach(CatalogCategory.allCases.filter { $0 != .topic }, id: \.self) { Text($0.title).tag($0) }
                    }.labelsHidden().accessibilityLabel("资料类型")
                }
                inspectorTextField("作者（用逗号分隔）", text: $form.authors)
                inspectorTextField("出版年份", text: $form.year)
                inspectorTextField("出版社 / 期刊 / 会议", text: $form.metadata.publication)
                inspectorTextField("ISBN", text: $form.metadata.isbn)
                inspectorTextField("DOI", text: $form.metadata.doi)
                inspectorTextField("来源网址", text: $form.metadata.sourceURL)
                inspectorTextField("标签（用逗号分隔）", text: $form.tags)
                inspectorTextField("摘要或简介", text: $form.metadata.abstract, lines: 3...8)
            } else {
                inspectorTextField("专题说明", text: $form.metadata.abstract, lines: 3...8)
            }
            Button("保存资料信息") { saveDraft() }.disabled(doc.catalog.archived || !hasDraftChanges || doc.state != "active")
            if hasDraftChanges {
                Text("资料信息尚未保存；请点“完成”选择保存或放弃后离开。").font(.caption).foregroundStyle(.secondary)
                Button("重新载入最新信息") { confirmReload = true }
            }
        } header: { Text("资料信息") } footer: {
            Text("资料标题与原文件名分开保存。作者、年份等信息可以稍后补充。")
        }
    }

    private var organizationSection: some View {
        Section("整理") {
            if doc.catalog.inbox { Button("整理完成，移出收件箱") { perform { _ = try store.markCatalogOrganized(id: doc.id) } } }
            if doc.kind != .folder {
                if topics.isEmpty { Text("尚无专题，可在资料库中新建。 ").foregroundStyle(.secondary) }
                ForEach(topics, id: \.id) { topic in
                    Toggle(topic.catalogTitle + (topic.catalog.archived ? "（已归档）" : ""), isOn: Binding(get: { doc.catalog.topicIDs.contains(topic.id) }, set: { included in
                        perform { _ = try store.setCatalogTopic(id: doc.id, topicID: topic.id, included: included) }
                    }))
                }
                ForEach(doc.catalog.topicIDs.filter { id in !topics.contains(where: { $0.id == id }) }, id: \.self) { id in
                    HStack {
                        Text("专题已删除或尚未载入").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("移除关联") { perform { _ = try store.setCatalogTopic(id: doc.id, topicID: id, included: false) } }
                    }
                }
            } else {
                Text("专题成员通过“加入专题”关联，移出专题不会删除原件。 ").font(.caption).foregroundStyle(.secondary)
            }
            if !doc.catalog.archived { Button("归档") { perform { _ = try store.setCatalogArchived(id: doc.id, archived: true) } } }
            if doc.kind == .pdf && doc.state == "active" && !doc.catalog.archived {
                Button("更换 PDF 原件") { revisionPicker = true }
                    .accessibilityLabel("更换 PDF 原件")
                Text("更换后仍是同一份资料。旧批注和摘录位置会标成待核对，上一份原件不会被覆盖。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func replacePDFOriginal(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let url):
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try PDFImportValidation.read(url: url)
                let outcome = try store.replacePDFOriginal(id: doc.id, data: data, fileName: url.lastPathComponent)
                current = outcome.document
                notice = outcome.reviewMessage
                onChange()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var readingSection: some View {
        Section("阅读") {
            inspectorField("阅读状态") {
                Picker("阅读状态", selection: Binding(get: { doc.catalog.readingStatus }, set: { status in
                    perform { _ = try store.updateCatalog(id: doc.id) { $0.readingStatus = status } }
                })) { ForEach(CatalogReadingStatus.allCases, id: \.self) { Text($0.title).tag($0) } }
                    .labelsHidden().accessibilityLabel("阅读状态")
            }
            if !doc.catalog.readingPositions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(doc.catalog.readingPositions) { position in
                        CatalogReadingPositionRow(record: CatalogReadingPositionPresentation(position: position, currentDeviceID: currentDeviceID))
                    }
                }.accessibilityElement(children: .contain)
            }
            if doc.kind == .pdf {
                inspectorTextField("页码（从 1 开始）", text: $page)
                Button("记录阅读位置") {
                    perform {
                        guard let value = Int(page), value > 0 else { throw CatalogError.invalidPage }
                        let hash = try doc.pdfPath.map { try DocumentStore.catalogFileHash(URL(fileURLWithPath: $0)) }
                        let count = doc.pdfPath.flatMap { PDFDocument(url: URL(fileURLWithPath: $0))?.pageCount }
                        _ = try store.recordCatalogReadingPosition(id: doc.id, deviceID: "manual", pageIndex: value - 1, totalPages: count, fileHash: hash)
                    }
                }
            }
        }
    }

    private var excerptComposer: some View {
        Section {
            inspectorTextField("摘录原文（可留空，仅记想法）", text: $quote, lines: 3...8)
            inspectorTextField("我的评论", text: $comment, lines: 2...6)
            if doc.kind == .pdf { inspectorTextField("来源页码（可选，从 1 开始）", text: $page) }
            selectionButton(purpose: .excerptNote)
            Button(targetNoteID.isEmpty ? "创建阅读笔记" : "加入所选笔记") { addExcerpt() }
                .disabled((quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                          || (!targetNoteID.isEmpty && !notes.contains { $0.id == targetNoteID }))
        } header: { Text("摘录与思考") } footer: {
            Text("保留原文、自己的评论和来源页码。输入摘录或评论后，请加入笔记保存；也可点“完成”选择放弃未保存输入。原件变更后会提示位置待核对。")
        }
    }

    @ViewBuilder private var referencesSection: some View {
        Section("来源摘录") {
            if doc.catalog.excerpts.isEmpty { Text("这份资料还没有引用摘录。 ").foregroundStyle(.secondary) }
            ForEach(doc.catalog.excerpts) { excerpt in
                VStack(alignment: .leading, spacing: 8) {
                    if !excerpt.quote.isEmpty { Text(excerpt.quote).textSelection(.enabled) }
                    if !excerpt.comment.isEmpty { Text("我的评论：" + excerpt.comment).foregroundStyle(.secondary) }
                    Text(excerpt.sourceLabel).font(.caption)
                    sourceButton(excerpt)
                }.padding(.vertical, 5)
            }
        }
        Section("引用此资料的笔记") {
            let backlinks = documents.filter { $0.state == "active" && ($0.catalog.sourceIDs.contains(doc.id) || $0.catalog.excerpts.contains { $0.sourceID == doc.id }) }
            if backlinks.isEmpty { Text("加入阅读笔记后，引用会出现在这里。 ").foregroundStyle(.secondary) }
            ForEach(backlinks, id: \.id) { item in Button(item.catalogTitle) { requestLeave(.document(item)) } }
        }
        Section("相关资料") {
            ForEach(CatalogRelatedEntry.entries(source: doc, documents: documents)) { entry in
                HStack {
                    if let item = entry.document, item.state == "active" {
                        Button { requestLeave(.document(item)) } label: {
                            Text(item.catalogTitle).fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        VStack(alignment: .leading) {
                            Text(entry.document?.catalogTitle ?? "资料已删除或尚未载入")
                            Text(entry.document?.state == "trashed" ? "已在回收站，关联仍保留。" : "原资料当前不可用，仍可移除关联。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("移除关联") { perform { _ = try store.setCatalogRelated(id: doc.id, targetID: entry.id, included: false) } }
                        .accessibilityLabel("移除与“\(entry.document?.catalogTitle ?? entry.id)”的关联")
                }
            }
            selectionButton(purpose: .related)
            Button("添加关联") { perform { _ = try store.setCatalogRelated(id: doc.id, targetID: relatedTargetID, included: true); relatedTargetID = "" } }
                .disabled(!sources.contains { $0.id == relatedTargetID })
        }
    }

    private func selectionButton(purpose: CatalogDocumentSelectionPurpose) -> some View {
        let selectedID = purpose == .related ? relatedTargetID : targetNoteID
        let candidate = (purpose == .related ? sources : notes).first { $0.id == selectedID }
        return Button { documentSelection = purpose } label: {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(purpose == .related ? "选择资料" : "加入笔记").font(.caption).foregroundStyle(.secondary)
                    if let candidate { CatalogSelectionCandidateRow(candidate: candidate) }
                    else if selectedID.isEmpty { Text(purpose == .related ? "搜索并选择相关资料" : "新建阅读笔记") }
                    else { Text("原选择已不可用，请重新选择").foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var sourceSection: some View {
        Section("原件与保存状态") {
            inspectorValue("原文件名", value: doc.catalog.originalFilename.isEmpty ? doc.name : doc.catalog.originalFilename)
            inspectorValue("本机状态", value: doc.kind == .pdf ? (doc.pdfPath.map { FileManager.default.fileExists(atPath: $0) } == true ? "已保存到本机" : "原件尚未下载") : "正文已保存到本机")
            inspectorValue("同步状态", value: doc.status.rawValue)
            if !doc.catalog.sourceURL.isEmpty, let url = URL(string: doc.catalog.sourceURL), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                Link("打开来源网站", destination: url)
            }
            Text("归档不等于备份成功。同步状态以服务器确认为准。 ").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// An explicit vertical field avoids the macOS Form label column taking width
    /// away from controls in a narrow sheet. The control keeps its own AX label.
    private func inspectorField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).accessibilityHidden(true)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
    }

    private func inspectorTextField(_ title: String, text: Binding<String>, lines: ClosedRange<Int> = 1...1) -> some View {
        inspectorField(title) {
            TextField("", text: text, axis: lines.upperBound > 1 ? .vertical : .horizontal)
                .lineLimit(lines).textFieldStyle(.roundedBorder)
                .accessibilityLabel(title)
        }
    }

    private func inspectorValue(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title).accessibilityValue(value)
    }

    @ViewBuilder private func sourceButton(_ excerpt: CatalogExcerpt) -> some View {
        let state = sourceStates[excerpt.id] ?? .checking
        if let source = documents.first(where: { $0.id == excerpt.sourceID && $0.state == "active" }) {
            Button(state.title) {
                if onOpenSource != nil, state == .available { requestLeave(.source(source, excerpt.pageIndex, excerpt.fileHash)) }
                else { requestLeave(.document(source)) }
            }.disabled(state == .checking)
            if state == .fileChanged || state == .unverifiedVersion { Text("保留摘录文字；请核对原文件的对应位置。 ").font(.caption).foregroundStyle(.orange) }
        } else { Label(state.title, systemImage: "link.badge.plus").font(.caption).foregroundStyle(.secondary) }
    }

    private var hasDraftChanges: Bool { form.isDirty }
    private var hasUnsubmittedExcerpt: Bool { !quote.isEmpty || !comment.isEmpty }
    private var hasUnsavedInputs: Bool { hasDraftChanges || hasUnsubmittedExcerpt }

    private func receive(_ latest: LibraryDocument) {
        let dirty = hasDraftChanges
        current = latest
        if !dirty { loadDraft() }
        else if latest.catalog != form.baseline {
            notice = "资料有新的已保存信息；你的表单输入仍保留，保存时会合并未冲突的字段。"
        }
    }

    private func loadDraft() { form = CatalogInspectorDraft(doc.catalog) }

    private func requestLeave(_ destination: CatalogInspectorDestination) {
        if let immediate = navigation.request(destination, dirty: hasUnsavedInputs) { leave(immediate) }
        else { confirmLeave = true }
    }

    private func resolveLeave(_ decision: CatalogInspectorNavigation.Decision) {
        do {
            if let destination = try navigation.resolve(decision, save: persistDraft) { leave(destination) }
        } catch { errorMessage = error.localizedDescription }
    }

    private func leave(_ destination: CatalogInspectorDestination) {
        dismiss()
        switch destination {
        case .done: break
        case .document(let item): onOpen(item)
        case .source(let item, let page, let hash):
            if let onOpenSource { onOpenSource(item, page, hash) } else { onOpen(item) }
        }
    }

    private func refreshSourceStates() async {
        let excerpts = doc.catalog.excerpts
        let store = store
        do {
            let states = try await Task.detached(priority: .utility) { try store.catalogSourceStates(for: excerpts) }.value
            guard !Task.isCancelled else { return }
            sourceStates = states
        } catch { errorMessage = "无法核对来源文件：\(error.localizedDescription)" }
    }

    private func persistDraft() throws {
        current = try form.save(id: doc.id, kind: doc.kind, store: store)
        onChange()
        notice = "资料信息已保存到本机。"
    }

    private func saveDraft() {
        do { try persistDraft() }
        catch { errorMessage = error.localizedDescription }
    }

    private func addExcerpt() {
        // Stale queued clicks after a successful save must not start a new write.
        guard !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            let result = try CatalogActionFeedback.save({
                let trimmed = page.trimmingCharacters(in: .whitespacesAndNewlines)
                let pageNumber = Int(trimmed)
                guard trimmed.isEmpty || (pageNumber ?? 0) > 0 else { throw CatalogError.invalidPage }
                if targetNoteID.isEmpty {
                    return try store.createCatalogNote(sourceID: doc.id, quote: quote, comment: comment, pageIndex: pageNumber.map { $0 - 1 }, noteID: excerptOperationID)
                }
                return try store.appendCatalogExcerpt(noteID: targetNoteID, sourceID: doc.id, quote: quote, comment: comment, pageIndex: pageNumber.map { $0 - 1 }, excerptID: excerptOperationID)
            }, refresh: { try reloadAfterExcerpt() })
            quote = ""; comment = ""; excerptOperationID = UUID().uuidString.lowercased()
            excerptRefreshNeeded = result.refreshError != nil
            notice = "已保存到“\(result.value.catalogTitle)”。"
            if let error = result.refreshError { notice += "资料详情刷新未完成：\(error) 不必重复保存，可重新载入。" }
            requestLeave(.document(result.value))
        } catch { errorMessage = error.localizedDescription }
    }
    private func reloadAfterExcerpt() throws {
        guard let latest = try store.loadDocument(id: document.id) else { throw CatalogError.notFound }
        receive(latest); onChange()
    }
    private func refreshAfterSavedExcerpt() {
        do { try reloadAfterExcerpt(); excerptRefreshNeeded = false; notice = "摘录已保存，资料详情已刷新。" }
        catch { notice = "摘录已保存，资料详情仍无法刷新：\(error.localizedDescription) 不必重复保存。" }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); if let latest = try store.loadDocument(id: document.id) { receive(latest) }; onChange() }
        catch { errorMessage = error.localizedDescription }
    }
}
