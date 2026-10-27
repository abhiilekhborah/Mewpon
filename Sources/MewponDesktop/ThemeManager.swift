import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MewponCore

extension ThemePalette {
    static func native(_ hex: String) -> NSColor {
        let v=UInt32(hex.dropFirst(),radix:16) ?? 0
        return NSColor(srgbRed:Double((v>>16)&255)/255,green:Double((v>>8)&255)/255,blue:Double(v&255)/255,alpha:1)
    }
    func color(_ hex:String)->Color {Color(nsColor:Self.native(hex))}
}
@MainActor final class ThemeManager: ObservableObject {
    static let shared=ThemeManager()
    @Published private(set) var selectedID:String
    @Published private(set) var custom:[MewponTheme]
    @Published var issue:String?
    var changed:(()->Void)?
    private let defaults:UserDefaults
    init(defaults:UserDefaults = .standard) {
        self.defaults=defaults
        let loaded=(defaults.array(forKey:"customThemeData") as? [Data] ?? []).compactMap {try? MewponTheme.validateImport($0)}
        custom=loaded
        let saved=defaults.string(forKey:"mewponTheme") ?? "liquid-glass"
        selectedID=(MewponTheme.builtins+loaded).contains(where:{$0.id==saved}) ? saved:"liquid-glass"
    }
    var themes:[MewponTheme] {MewponTheme.builtins+custom}
    var current:MewponTheme {themes.first{$0.id==selectedID} ?? MewponTheme.builtins[0]}
    func preferredScheme(appearance:String)->ColorScheme? {
        let chosen=appearance=="system" ? current.preferredAppearance:appearance
        return chosen=="light" ? .light:chosen=="dark" ? .dark:nil
    }
    func scheme(appearance:String,system:ColorScheme)->ColorScheme {
        let chosen=appearance=="system" ? current.preferredAppearance:appearance
        return chosen=="light" ? .light:chosen=="dark" ? .dark:system
    }
    func apply(_ id:String) throws {
        guard themes.contains(where:{$0.id==id}) else{throw MewponError.invalid("Unknown theme. Choose one of the available themes.")}
        let start=ContinuousClock.now
        guard selectedID != id else{return}
        selectedID=id;defaults.set(id,forKey:"mewponTheme");changed?()
        Task{await PerformanceProfiler.shared.record("theme.apply_assignment",since:start)}
    }
    func importTheme() {
        let panel=NSOpenPanel();panel.allowedContentTypes=[.json]
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do {
            guard (try url.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? Int.max <= 65_536 else{throw MewponError.invalid("Choose a theme smaller than 64 KB.")}
            let theme=try MewponTheme.validateImport(Data(contentsOf:url))
            guard !MewponTheme.builtins.contains(where:{$0.id==theme.id}),custom.count<12 else{throw MewponError.invalid("Use a unique custom ID; up to 12 custom themes are supported.")}
            custom.removeAll{$0.id==theme.id};custom.append(theme)
            defaults.set(try custom.map{try JSONEncoder().encode($0)},forKey:"customThemeData")
            try apply(theme.id);issue=nil
        }catch{issue=error.localizedDescription}
    }
}
struct ThemeGallery:View {
    @ObservedObject private var manager=ThemeManager.shared
    var body:some View {
        Section("Themes") {
            LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible()),GridItem(.flexible())],spacing:10) {
                ForEach(manager.themes) {theme in
                    let p=theme.palette(dark:theme.preferredAppearance=="dark")
                    Button {try? manager.apply(theme.id)} label:{
                        VStack(alignment:.leading,spacing:8) {
                            HStack(spacing:4) {
                                Circle().fill(p.color(p.accent)).frame(width:9,height:9)
                                RoundedRectangle(cornerRadius:3).fill(p.color(p.secondary).opacity(0.5)).frame(width:50,height:5)
                                Spacer()
                            }.frame(height:24)
                            HStack {Text(theme.name).font(.system(size:11,weight:.medium,design:theme.monospace ? .monospaced:.default));Spacer(minLength:2);if manager.selectedID==theme.id{Image(systemName:"checkmark.circle.fill").font(.system(size:12)).foregroundStyle(p.color(p.accent))}}
                        }.foregroundStyle(p.color(p.text)).padding(10).background(p.color(p.background),in:RoundedRectangle(cornerRadius:9))
                            .overlay(RoundedRectangle(cornerRadius:9).stroke(p.color(manager.selectedID==theme.id ? p.accent:p.border).opacity(manager.selectedID==theme.id ? 1:0.25),lineWidth:manager.selectedID==theme.id ? 2:1))
                    }.buttonStyle(.plain).accessibilityLabel("Use "+theme.name+" theme").accessibilityAddTraits(manager.selectedID==theme.id ? .isSelected:[])
                }
            }
            HStack {Text("Current: "+manager.current.name).font(.caption);Spacer();Button("Import local JSON…"){manager.importTheme()}}
            if let issue=manager.issue{Text(issue).font(.caption).foregroundStyle(.orange)}
        }
    }
}
struct ThemeTool:AssistantTool {
    let spec=ToolSpec("mewpon_theme","Switch Mewpon's own theme immediately. Does not change macOS appearance or recolor the avatar.",fields:["theme":"liquid-glass, minimal-light, midnight, arctic-blue, warm-paper, developer"],capability:.appearance)
    func execute(arguments:[String:JSONValue]) async throws ->ToolResult {
        try await MainActor.run {try ThemeManager.shared.apply(arguments["theme"]!.string!);return ToolResult(true,"Theme: "+ThemeManager.shared.current.name+".")}
    }
}
