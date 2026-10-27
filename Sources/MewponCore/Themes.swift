import Foundation

public struct ThemePalette: Codable, Equatable, Sendable {
    public var background: String; public var surface: String; public var text: String; public var secondary: String
    public var accent: String; public var border: String; public var selection: String
    public var success: String; public var warning: String; public var error: String
    public init(_ background: String, _ surface: String, _ text: String, _ secondary: String, _ accent: String) {
        self.background=background; self.surface=surface; self.text=text; self.secondary=secondary; self.accent=accent
        border=secondary; selection=accent; success="#36865D"; warning="#B17A27"; error="#C64D59"
    }
}
public struct MewponTheme: Codable, Identifiable, Equatable, Sendable {
    public let id: String; public let name: String; public let preferredAppearance: String
    public let light: ThemePalette; public let dark: ThemePalette
    public let glass: Bool; public let monospace: Bool; public let radius: Double; public let spacing: Double; public let animationSeconds: Double
    public func palette(dark: Bool) -> ThemePalette { dark ? self.dark : light }
    public static let builtins: [Self] = [
        .init(id:"liquid-glass",name:"Liquid Glass",preferredAppearance:"system",light:.init("#F7F9FC","#F0F3F7","#202832","#526174","#31678F"),dark:.init("#20252C","#171C23","#EDF2F8","#ADBACB","#94BDE4"),glass:true,monospace:false,radius:18,spacing:8,animationSeconds:0.12),
        .init(id:"minimal-light",name:"Minimal Light",preferredAppearance:"light",light:.init("#FCFDFE","#F1F3F6","#242B35","#546170","#365D80"),dark:.init("#22272F","#2A3039","#F0F3F8","#B6C0CD","#9ABDE1"),glass:false,monospace:false,radius:16,spacing:8,animationSeconds:0.10),
        .init(id:"midnight",name:"Midnight",preferredAppearance:"dark",light:.init("#F1F4F8","#E7ECF3","#253246","#506178","#405E8B"),dark:.init("#12171F","#1B2330","#E5ECF6","#A7B7CD","#A8BCDF"),glass:false,monospace:false,radius:18,spacing:8,animationSeconds:0.12),
        .init(id:"arctic-blue",name:"Arctic Blue",preferredAppearance:"light",light:.init("#F1F7FE","#E4EFFB","#16324F","#405B75","#315F8F"),dark:.init("#111F2D","#1B2D41","#E6F2FF","#AEC4D8","#92BCEE"),glass:false,monospace:false,radius:18,spacing:8,animationSeconds:0.12),
        .init(id:"warm-paper",name:"Warm Paper",preferredAppearance:"light",light:.init("#FAF6ED","#F0E8D9","#332C25","#64584C","#795732"),dark:.init("#27221C","#332D25","#F2E8D7","#D1BFA7","#D7AF75"),glass:false,monospace:false,radius:16,spacing:9,animationSeconds:0.10),
        .init(id:"developer",name:"Developer",preferredAppearance:"dark",light:.init("#F4F6F9","#E8EDF3","#202D3A","#4E6174","#286A72"),dark:.init("#171B22","#202731","#E4EBF4","#AFBDCE","#80C4C3"),glass:false,monospace:true,radius:12,spacing:6,animationSeconds:0)
    ]
    public static func validateImport(_ data: Data) throws -> Self {
        guard data.count <= 65_536, let object = try JSONSerialization.jsonObject(with: data) as? [String:Any] else { throw MewponError.invalid("Use a local theme JSON file smaller than 64 KB.") }
        let top: Set<String> = ["id","name","preferredAppearance","light","dark","glass","monospace","radius","spacing","animationSeconds"]
        let palette: Set<String> = ["background","surface","text","secondary","accent","border","selection","success","warning","error"]
        guard Set(object.keys) == top else { throw MewponError.invalid("Theme has missing or unsupported keys; scripts/resources are not supported.") }
        for key in ["light","dark"] {
            guard let colors=object[key] as? [String:String], Set(colors.keys)==palette, colors.values.allSatisfy({ $0.range(of:"^#[0-9A-Fa-f]{6}$",options:.regularExpression) != nil }) else { throw MewponError.invalid("Use complete semantic palettes with six-digit hex colors only.") }
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.id.range(of:"^[a-z0-9][a-z0-9-]{0,39}$",options:.regularExpression) != nil, !value.name.isEmpty, value.name.count<=60, ["system","light","dark"].contains(value.preferredAppearance), value.radius.isFinite, (8...28).contains(value.radius), value.spacing.isFinite, (4...16).contains(value.spacing), value.animationSeconds.isFinite, (0...0.3).contains(value.animationSeconds) else { throw MewponError.invalid("Invalid theme identity, layout, or animation values.") }
        for colors in [value.light,value.dark] {
            guard contrast(colors.text,colors.background)>=4.5, contrast(colors.secondary,colors.background)>=3 else { throw MewponError.invalid("Theme text contrast is too low.") }
        }
        return value
    }
    public static func contrast(_ a: String, _ b: String) -> Double {
        func luminance(_ h:String)->Double {
            guard let v=UInt32(h.dropFirst(),radix:16) else{return 0}
            func linear(_ c:UInt32)->Double {let x=Double(c)/255;return x<=0.04045 ? x/12.92:pow((x+0.055)/1.055,2.4)}
            return 0.2126*linear((v>>16)&255)+0.7152*linear((v>>8)&255)+0.0722*linear(v&255)
        }
        let x=luminance(a), y=luminance(b);return (max(x,y)+0.05)/(min(x,y)+0.05)
    }
}
