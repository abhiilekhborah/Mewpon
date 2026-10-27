import Foundation

public enum LocalInformation {
    private static let units:[String:(Dimension,String)] = {
        var result:[String:(Dimension,String)]=[:]
        func add(_ names:[String],_ unit:Dimension,_ group:String){for name in names{result[name]=(unit,group)}}
        add(["m","meter","meters","metre","metres"],UnitLength.meters,"length")
        add(["km","kilometer","kilometers","kilometre","kilometres"],UnitLength.kilometers,"length")
        add(["cm","centimeter","centimeters"],UnitLength.centimeters,"length")
        add(["mi","mile","miles"],UnitLength.miles,"length")
        add(["ft","foot","feet"],UnitLength.feet,"length")
        add(["in","inch","inches"],UnitLength.inches,"length")
        add(["kg","kilogram","kilograms"],UnitMass.kilograms,"mass")
        add(["g","gram","grams"],UnitMass.grams,"mass")
        add(["lb","lbs","pound","pounds"],UnitMass.pounds,"mass")
        add(["oz","ounce","ounces"],UnitMass.ounces,"mass")
        add(["c","°c","celsius"],UnitTemperature.celsius,"temperature")
        add(["f","°f","fahrenheit"],UnitTemperature.fahrenheit,"temperature")
        add(["k","kelvin"],UnitTemperature.kelvin,"temperature")
        add(["s","sec","second","seconds"],UnitDuration.seconds,"duration")
        add(["min","minute","minutes"],UnitDuration.minutes,"duration")
        add(["h","hour","hours"],UnitDuration.hours,"duration")
        add(["l","liter","liters","litre","litres"],UnitVolume.liters,"volume")
        add(["ml","milliliter","milliliters"],UnitVolume.milliliters,"volume")
        add(["us gallon","us gallons"],UnitVolume.gallons,"volume")
        add(["km/h","kph"],UnitSpeed.kilometersPerHour,"speed")
        add(["mph"],UnitSpeed.milesPerHour,"speed")
        add(["m/s"],UnitSpeed.metersPerSecond,"speed")
        return result
    }()
    public static func convert(_ value:Double,from:String,to:String) throws ->Double {
        guard value.isFinite,abs(value)<=1e15,let source=units[from.lowercased()],let target=units[to.lowercased()],source.1==target.1 else{throw MewponError.invalid("Choose compatible length, mass, temperature, duration, volume or speed units. Currency exchange and ambiguous gallons are not inferred.")}
        let converted=Measurement(value:value,unit:source.0).converted(to:target.0).value
        guard converted.isFinite else{throw MewponError.invalid("Conversion is outside the supported range.")}
        return converted
    }
    public static func zone(_ text:String)->TimeZone? {
        let aliases=["india":"Asia/Kolkata","delhi":"Asia/Kolkata","mumbai":"Asia/Kolkata","kolkata":"Asia/Kolkata","guwahati":"Asia/Kolkata","london":"Europe/London","new york":"America/New_York","los angeles":"America/Los_Angeles","tokyo":"Asia/Tokyo","sydney":"Australia/Sydney","paris":"Europe/Paris","utc":"Etc/UTC","gmt":"Etc/GMT"]
        guard !["CST","IST","PST","EST","BST"].contains(text.uppercased()) else{return nil}
        let id=aliases[text.lowercased()] ?? text
        guard aliases[text.lowercased()] != nil || id.contains("/") else{return nil}
        return TimeZone(identifier:id)
    }
    public static func classify(_ input:String)->RoutingDecision? {
        var text=CommandNormalizer.normalize(input)
        for prefix in ["please ","can you ","could you "] where text.hasPrefix(prefix){text=String(text.dropFirst(prefix.count))}
        for prefix in ["time in ","what time is it in ","what's the time in "] where text.hasPrefix(prefix) {
            let zone=String(text.dropFirst(prefix.count))
            guard Self.zone(zone) != nil else{return .needsClarification("Specify a supported city or IANA time zone, for example Europe/London. Ambiguous abbreviations such as CST are not guessed.")}
            return .deterministic(.tool(.init(name:"time_zone",arguments:["zone":.string(zone)])))
        }
        let pattern="^(?:convert )?(-?[0-9]+(?:[.][0-9]+)?) ?([a-z°/ ]+?) (?:to|in) ([a-z°/ ]+)$"
        guard let regex=try? NSRegularExpression(pattern:pattern),let match=regex.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)) else{return nil}
        func field(_ i:Int)->String{Range(match.range(at:i),in:text).map{String(text[$0])} ?? ""}
        guard let value=Double(field(1)),(try? convert(value,from:field(2),to:field(3))) != nil else{return nil}
        return .deterministic(.tool(.init(name:"unit_conversion",arguments:["value":.string(field(1)),"from":.string(field(2)),"to":.string(field(3))])))
    }
}
public struct UnitConversionTool:AssistantTool {
    public let spec=ToolSpec("unit_conversion","Offline deterministic conversion of compatible length, mass, temperature, duration, volume and speed units; never exchange rates.",fields:["value":"Finite number","from":"Source unit","to":"Target compatible unit"])
    public init(){}
    public func execute(arguments:[String:JSONValue]) async throws ->ToolResult {
        guard let value=Double(arguments["value"]?.string ?? ""),let from=arguments["from"]?.string,let to=arguments["to"]?.string else{throw MewponError.invalid("Specify a number and compatible units.")}
        let result=try LocalInformation.convert(value,from:from,to:to)
        return ToolResult(true,String(format:"%.8g",value)+" "+from+" = "+String(format:"%.8g",result)+" "+to)
    }
}
public struct TimeZoneTool:AssistantTool {
    public let spec=ToolSpec("time_zone","Actual current date/time in an explicit supported city or IANA timezone, using native daylight-saving rules.",fields:["zone":"City alias or exact IANA timezone"])
    public init(){}
    public func execute(arguments:[String:JSONValue]) async throws ->ToolResult {
        guard let zone=LocalInformation.zone(arguments["zone"]?.string ?? "") else{throw MewponError.invalid("Choose an exact supported city or IANA timezone.")}
        let formatter=DateFormatter();formatter.timeZone=zone;formatter.dateStyle = .full;formatter.timeStyle = .long
        return ToolResult(true,formatter.string(from:.now)+" ("+zone.identifier+")")
    }
}
