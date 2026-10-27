import Foundation

public enum WebAddress {
    public static func validated(_ text:String) throws ->URL {
        guard text.count<=2000,!text.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}),let parts=URLComponents(string:text),let host=parts.host,!host.isEmpty,parts.user==nil,parts.password==nil,parts.scheme?.lowercased()=="https" || parts.scheme?.lowercased()=="http" && ["localhost","127.0.0.1","[::1]"].contains(host),let url=parts.url else{throw MewponError.invalid("Use an HTTPS address without embedded credentials. Local development HTTP is allowed only for loopback.")}
        return url
    }
    public static func search(_ text:String) throws ->URL {
        guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,text.count<=1000 else{throw MewponError.invalid("Enter a short web search query.")}
        var parts=URLComponents(string:"https://duckduckgo.com/")!;parts.queryItems=[URLQueryItem(name:"q",value:text)]
        return parts.url!
    }
}
public enum InformationIntents {
    public static func translation(_ input:String)->RoutingDecision? {
        guard input.count<=4000 else{return nil}
        var raw=input.trimmingCharacters(in:.whitespacesAndNewlines)
        if raw.lowercased().hasPrefix("please "){raw=String(raw.dropFirst(7))}
        let lower=raw.lowercased()
        for (prefix,language) in [("translate to hindi:","hi"),("translate into hindi:","hi"),("translate to english:","en"),("translate into english:","en")] where lower.hasPrefix(prefix) {
            let text=String(raw.dropFirst(prefix.count)).trimmingCharacters(in:.whitespacesAndNewlines)
            guard !text.isEmpty else{return .needsClarification("Include the text after the colon.")}
            return .deterministic(.tool(.init(name:"translate_text",arguments:["text":.string(text),"language":.string(language)])))
        }
        return nil
    }
    public static func classify(_ input:String)->RoutingDecision? {
        let raw=input.trimmingCharacters(in:.whitespacesAndNewlines),lower=raw.lowercased()
        func tool(_ name:String,_ arguments:[String:String])->RoutingDecision{.deterministic(.tool(ToolCall(name:name,arguments:arguments.mapValues(JSONValue.string))))}
        if let translated=translation(input){return translated}
        if lower.hasPrefix("open https://") || lower.hasPrefix("open http://") {
            let address=String(raw.dropFirst(5));guard (try? WebAddress.validated(address)) != nil else{return .needsClarification("Use an HTTPS URL without credentials, or a local loopback HTTP URL.")}
            return tool("open_url",["action":"open","value":address])
        }
        for prefix in ["search the web for ","search web for "] where lower.hasPrefix(prefix){return tool("open_url",["action":"search","value":String(raw.dropFirst(prefix.count))])}
        if ["news headlines","latest news","world news"].contains(lower){return tool("online_news",["topic":"world"])}
        if ["sports headlines","sports news"].contains(lower){return tool("online_news",["topic":"sport"])}
        if ["weather","what's the weather","what is the weather"].contains(lower){return .needsClarification("Which city and country? Live weather uses Open-Meteo online after network access is enabled.")}
        for prefix in ["weather in ","what's the weather in ","what is the weather in "] where lower.hasPrefix(prefix) {
            let place=String(raw.dropFirst(prefix.count)),parts=place.split(separator:",",maxSplits:1).map{String($0).trimmingCharacters(in:.whitespaces)}
            guard !place.contains(" and "),let first=parts.first,!first.isEmpty else{return nil}
            return tool("weather",["location":parts[0],"country":parts.count==2 ? parts[1].uppercased():"none","day":"today"])
        }
        return nil
    }
}

public enum OnlineIntentScope {
    public static func forbidsNetwork(_ request:String)->Bool {
        let text=CommandNormalizer.normalize(request)
        return ["offline","no internet","without internet","don't use the internet","do not use the internet","no network"].contains(where:text.contains)
    }
    /// Standing online permission covers only literals from the current user request.
    /// Derived private/context queries must be reviewed separately by the user.
    public static func covers(tool:String,arguments:[String:JSONValue],request:String)->Bool {
        guard !forbidsNetwork(request) else{return false}
        let text=CommandNormalizer.normalize(request)
        switch tool {
        case "online_news":return ["news","headlines","sports"].contains(where:text.contains)
        case "weather":
            guard ["weather","forecast","temperature","rain"].contains(where:text.contains),let city=arguments["location"]?.string,city.count>=2 else{return false}
            let allowed=CharacterSet.letters.union(.nonBaseCharacters).union(.whitespaces).union(CharacterSet(charactersIn:"-.'’"))
            guard city.unicodeScalars.allSatisfy({allowed.contains($0)}) else{return false}
            let pattern="(?<![\\p{L}\\p{N}])"+NSRegularExpression.escapedPattern(for:city)+"(?![\\p{L}\\p{N}])"
            return request.range(of:pattern,options:[.regularExpression,.caseInsensitive,.diacriticInsensitive]) != nil
        case "open_url":
            guard let action=arguments["action"]?.string,let value=arguments["value"]?.string,!value.isEmpty else{return false}
            if action=="open"{return request.contains(value) && ["open ","browse ","visit ","go to "].contains(where:text.contains)}
            return action=="search" && ["search web","search the web","search online"].contains(where:text.contains) && request.contains(value)
        default:return false
        }
    }
}
