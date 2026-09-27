import SwiftUI
import LibraryCore

struct ConflictResolutionView: View {
    @ObservedObject var model:AppModel
    @State private var conflicts:[LibraryConflict]=[]
    @State private var drafts:[EditorDraft]=[]
    @State private var selected:LibraryConflict?
    @State private var selectedDraft:EditorDraft?
    @State private var error:String?
    var body:some View {
        List {
            if !drafts.isEmpty {
                Section("恢复草稿 · 可离线处理") {
                    ForEach(drafts) { draft in
                        Button { selectedDraft=draft } label: {
                            VStack(alignment:.leading,spacing:6) {
                                Text(draft.name)
                                Text(draft.reason).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical,6)
                            .frame(maxWidth:.infinity,alignment:.leading)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
            if !conflicts.isEmpty {
                Section("同步冲突") {
                    ForEach(conflicts) { conflict in
                        Button { selected=conflict } label: {
                            VStack(alignment:.leading,spacing:6) {
                                Text(model.documents.first(where:{$0.id == conflict.objectId})?.catalogTitle ?? "需要处理的资料")
                                Text("双方内容均已保留，比较后选择保留方式。").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical,6)
                            .frame(maxWidth:.infinity,alignment:.leading)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("冲突与恢复草稿")
        .overlay {
            if let error { InkUnavailable(title: "无法读取恢复材料", symbol: "exclamationmark.triangle", message: error) { EmptyView() } }
            else if conflicts.isEmpty && drafts.isEmpty { InkUnavailable(title: "没有待处理内容", symbol: "checkmark.circle", message: "可以继续编辑和同步。") { EmptyView() } }
        }
        .onAppear(perform:reload)
        .onChange(of:model.documents) { _,_ in reload() }
        .sheet(item:$selected) { conflict in
            ConflictDetailView(conflict:conflict,model:model,onResolved:{selected=nil;reload();model.catalogChanged()})
        }
        .sheet(item:$selectedDraft) { draft in
            EditorDraftDetailView(draft:draft,store:model.store,parentID:model.rootFor(model.currentFolder),onRecovered:{ document in
                selectedDraft=nil;reload();model.catalogChanged();model.openDocument(document)
            },onDiscarded:{ selectedDraft=nil;reload() })
        }
    }
    func reload() {
        do { conflicts=try model.store.conflicts();drafts=try model.store.editorDrafts();error=nil }
        catch { self.error=error.localizedDescription }
    }
}

private struct EditorDraftDetailView:View {
    let draft:EditorDraft
    let store:DocumentStore
    let parentID:String
    var onRecovered:(LibraryDocument)->Void
    var onDiscarded:()->Void
    @Environment(\.dismiss) private var dismiss
    @State private var error:String?
    @State private var confirmingDiscard=false
    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    Text(draft.reason).foregroundStyle(.secondary)
                    if draft.kind == .md {
                        Text("你的编辑草稿").font(.headline)
                        Text(draft.proposedMarkdown).font(.system(.body,design:.monospaced)).textSelection(.enabled)
                        DisclosureGroup("查看保存时的另一版本") { Text(draft.currentMarkdown).textSelection(.enabled) }
                    } else {
                        Text("已保留 \(draft.proposedAnnotations.count) 条批注和原 PDF 版本信息。")
                        ForEach(draft.proposedAnnotations,id:\.id) { annotation in
                            Text("第 \(annotation.pageIndex+1) 页 · \(annotation.text)").textSelection(.enabled)
                        }
                    }
                    Text("恢复会新建副本，保留现有资料和回收站状态。PDF 批注只恢复到原文件版本。").font(.caption).foregroundStyle(.secondary)
                    if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    HStack(spacing: 10) {
                        Button("恢复为新副本") {
                            do { onRecovered(try store.recoverEditorDraftAsCopy(id:draft.id,parentId:parentID)) }
                            catch { self.error=error.localizedDescription }
                        }.buttonStyle(InkButtonStyle(prominent: true))
                        Button("删除此恢复草稿",role:.destructive) { confirmingDiscard=true }
                            .buttonStyle(InkButtonStyle())
                    }
                }.padding(20)
            }.navigationTitle(draft.name)
            .toolbar { Button("稍后处理") { dismiss() }.buttonStyle(InkButtonStyle()) }
        }.frame(minWidth:320,minHeight:450)
        .confirmationDialog("永久删除此恢复草稿？",isPresented:$confirmingDiscard,titleVisibility:.visible) {
            Button("删除草稿",role:.destructive) {
                do { try store.discardEditorDraft(id:draft.id);onDiscarded() }
                catch { self.error=error.localizedDescription }
            }
        }
    }
}

private struct ConflictDetailView: View {
    let conflict: LibraryConflict
    @ObservedObject var model: AppModel
    var onResolved: ()->Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft=""
    @State private var busy=false
    @State private var error:String?
    var local:[String:Any] { snapshot(conflict.localJSON) }
    var remote:[String:Any] { snapshot(conflict.remoteJSON) }
    var base:[String:Any] { snapshot(conflict.baseJSON) }
    var isMarkdown:Bool { local["markdownSource"] != nil || remote["markdownSource"] != nil }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    Text("比较两个版本后再保存。处理期间原内容与双方修改都会保留。")
                        .foregroundStyle(.secondary)
                    ViewThatFits(in:.horizontal) {
                        HStack(alignment:.top,spacing:12) {
                            snapshotView("本机",value:local).frame(minWidth:220)
                            snapshotView("服务器",value:remote).frame(minWidth:220)
                            if isMarkdown { mergeColumn.frame(minWidth:240) }
                        }
                        VStack(alignment:.leading,spacing:16) {
                            snapshotView("本机",value:local)
                            snapshotView("服务器",value:remote)
                            if isMarkdown { mergeColumn }
                        }
                    }
                    if isMarkdown {
                        DisclosureGroup("查看相对共同版本的源码变化") {
                            VStack(alignment:.leading,spacing:16) {
                                SourceDifference(title:"本机",base:base["markdownSource"] as? String ?? "",changed:local["markdownSource"] as? String ?? "")
                                SourceDifference(title:"服务器",base:base["markdownSource"] as? String ?? "",changed:remote["markdownSource"] as? String ?? "")
                            }
                        }
                    }
                    if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    if model.client == nil { Text("请先重新连接服务器，再提交冲突处理结果。原内容仍保留在本机。").foregroundStyle(.secondary) }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            Button("保留本机版本") { resolve(.local) }.buttonStyle(InkButtonStyle())
                            Button("采用服务器版本") { resolve(.remote) }.buttonStyle(InkButtonStyle())
                            if isMarkdown { Button("保存合并内容") { resolve(.customMarkdown(draft)) }.buttonStyle(InkButtonStyle(prominent: true)) }
                        }
                        .padding(.vertical, 2)
                    }
                    .disabled(busy || model.client == nil)
                    if busy { ProgressView("正在保存处理结果…") }
                }.padding(20)
            }
            .background(LibraryPalette.paper)
            .navigationTitle("比较与解决冲突")
            .toolbar { Button("稍后处理") { dismiss() }.buttonStyle(InkButtonStyle()).disabled(busy) }
        }
        .frame(minWidth:320,minHeight:540)
        .onAppear { draft=local["markdownSource"] as? String ?? "" }
    }
    private var mergeColumn: some View {
        VStack(alignment:.leading,spacing:8) {
            Text("合并结果").font(.headline)
            Text("保存前可以改这段文字。未提交前不会标为已同步。")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text:$draft)
                .font(.system(.body,design:.monospaced))
                .frame(minHeight:220)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(LibraryPalette.paper, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(LibraryPalette.ink.opacity(0.28), lineWidth: 1) }
                .accessibilityLabel("合并后的 Markdown")
        }
        .padding(14)
        .frame(maxWidth:.infinity,alignment:.leading)
        .background(LibraryPalette.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(LibraryPalette.ink.opacity(0.18), lineWidth: 1) }
    }
    @ViewBuilder func snapshotView(_ title:String,value:[String:Any])->some View {
        VStack(alignment:.leading,spacing:8) {
            Text(title).font(.headline)
            Text(value["name"] as? String ?? "未命名")
            if value["state"] as? String == "trashed" { Label("已移入回收站", ink: "trash") }
            if let text=value["markdownSource"] as? String { Text(text).font(.system(.caption,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }
            if let annotations=value["annotations"] as? [Any] { Text("\(annotations.count) 条 PDF 批注") }
            if let metadata=value["metadata"] as? [String:Any],let title=metadata["title"] as? String,!title.isEmpty { Text("资料标题：\(title)") }
        }
        .padding(14)
        .frame(maxWidth:.infinity,alignment:.topLeading)
        .background(LibraryPalette.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(LibraryPalette.ink.opacity(0.18), lineWidth: 1) }
    }
    func snapshot(_ json:String)->[String:Any] { (try? JSONSerialization.jsonObject(with:Data(json.utf8))) as? [String:Any] ?? [:] }
    func resolve(_ resolution:ConflictResolution) {
        guard let client=model.client else { return }
        busy=true;error=nil
        let store=model.store
        Task {
            do { try await client.resolveConflict(conflict,resolution:resolution,store:store);busy=false;onResolved() }
            catch { self.error=SyncFailure.from(error).localizedDescription;busy=false }
        }
    }
}

private struct SourceDifference: View {
    let title:String
    let base:String
    let changed:String
    private var rows:[DiffRow] {
        let old=base.components(separatedBy:"\n"),new=changed.components(separatedBy:"\n")
        let difference=new.difference(from:old)
        var removed=Set<Int>(),added=Set<Int>()
        for change in difference {
            switch change { case let .remove(offset,_,_):removed.insert(offset);case let .insert(offset,_,_):added.insert(offset) }
        }
        var output:[DiffRow]=[],i=0,j=0
        while i<old.count || j<new.count {
            if i<old.count,removed.contains(i) { output.append(DiffRow(kind:-1,text:old[i]));i+=1 }
            else if j<new.count,added.contains(j) { output.append(DiffRow(kind:1,text:new[j]));j+=1 }
            else if j<new.count { output.append(DiffRow(kind:0,text:new[j]));i+=1;j+=1 }
            else { break }
        }
        return output
    }
    var body: some View {
        VStack(alignment:.leading,spacing:2) {
            Text(title).font(.headline)
            ForEach(Array(rows.enumerated()),id:\.offset) { _,row in
                Text((row.kind<0 ? "− " : row.kind>0 ? "+ " : "  ")+row.text)
                    .font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                    .foregroundStyle(row.kind<0 ? Color.red : row.kind>0 ? Color.green : Color.primary)
                    .frame(maxWidth:.infinity,alignment:.leading)
            }
        }
    }
    private struct DiffRow { let kind:Int;let text:String }
}
