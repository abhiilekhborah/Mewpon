import SwiftUI
import AppKit
import MewponCore

struct SearchIndexSettings:View {
    @State private var folders:[URL]=[]
    @State private var status=""
    @State private var working=false
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            Text("Spotlight searches filenames. Add specific folders to search PDF and text contents locally; excerpts and aliases stay on this Mac.").font(.caption).foregroundStyle(.secondary)
            ForEach(folders,id:\.path){Text($0.path).font(.caption).textSelection(.enabled)}
            HStack {
                Button("Add folder…"){choose()}
                Button("Refresh index"){run{await AuthorizedSearch.shared.refresh(force:true)}}.disabled(folders.isEmpty)
                Button("Remove folders and index",role:.destructive){run{try await AuthorizedSearch.shared.clear()}}.disabled(folders.isEmpty)
            }.disabled(working)
            Text(status).font(.caption).foregroundStyle(.secondary)
            Text("Bounded to 5,000 supported files per folder and short excerpts. Changes refresh in the background after searches, at most once per 30 seconds, or immediately with Refresh. Images and Office contents are not indexed.").font(.caption).foregroundStyle(.secondary)
        }.task{folders=await AuthorizedSearch.shared.roots()}
    }
    private func choose(){
        let panel=NSOpenPanel();panel.canChooseFiles=false;panel.canChooseDirectories=true;panel.allowsMultipleSelection=false
        panel.message="Allow Mewpon to keep a local text index of PDF and text files in this folder."
        panel.begin{response in if response == .OK,let url=panel.url{run{try await AuthorizedSearch.shared.authorize(url)}}}
    }
    private func run(_ action:@escaping @Sendable() async throws ->Void){
        working=true;status="Updating local index…"
        Task{do{try await action();status="Index updated. Results are limited to readable supported files."}catch{status=error.localizedDescription};folders=await AuthorizedSearch.shared.roots();working=false}
    }
}
