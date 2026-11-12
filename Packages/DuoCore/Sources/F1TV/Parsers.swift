import Foundation

/// Turns F1 TV's JSON into catalogue models. Every parser takes the whole response (with its
/// `resultObj`), reads nulls and missing keys as "", and never fails a whole list because of one
/// bad item.
public enum Parsers {
    // MARK: Items

    /// One of F1 TV's tiles as something to watch, or as a series page for a show or documentary
    /// bundle. Launchers (links to other series' pages), surveys and anything without an ID aren't.
    public static func catalogItem(_ metadataContainer: JSONValue) -> CatalogItem? {
        guard let meta = metadata(metadataContainer) else { return nil }
        let type = meta["contentType"].string
        if type == "LAUNCHER" { return nil }
        var pageId: Int?
        if type == "BUNDLE" {
            pageId = pageID(fromURI: metadataContainer["actions"][0]["uri"].string)
            if pageId == nil { return nil }
        }
        let id = meta["contentId"].int ?? 0
        if pageId == nil && id <= 0 { return nil }
        let emf = meta["emfAttributes"]
        return CatalogItem(
            contentId: id,
            title: meta["title"].string.trimmingCharacters(in: .whitespacesAndNewlines),
            subtype: meta["contentSubtype"].string,
            contentType: type,
            genre: meta["genres"][0].string,
            picturePath: nonEmpty(meta["pictureUrl"].string),
            durationSeconds: meta["duration"].int,
            year: meta["year"].int,
            meeting: emf["Meeting_Name"].string,
            start: date(ms: emf["sessionStartDate"]),
            pageId: pageId
        )
    }

    /// What is live now. Items without a content ID are dropped.
    public static func liveNow(_ json: JSONValue) -> [CatalogItem] {
        json["resultObj"]["items"].array.compactMap { item in
            guard let meta = metadata(item), let id = meta["contentId"].int, id > 0 else { return nil }
            var title = meta["titleBrief"].string
            if title.isEmpty { title = meta["title"].string }
            if title.isEmpty { title = "Live" }
            return CatalogItem(
                contentId: id,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                subtype: "LIVE",
                contentType: meta["contentType"].string,
                picturePath: nonEmpty(meta["pictureUrl"].string),
                meeting: meta["emfAttributes"]["Meeting_Name"].string
            )
        }
    }

    // MARK: Calendar

    /// The season's race weekends and tests, in F1 TV's order. Entries F1 marks as not for the
    /// schedule ("Diplay_In_Schedule" is F1's spelling) are skipped.
    public static func calendar(_ json: JSONValue) -> [Meeting] {
        json["resultObj"]["containers"].array.compactMap { container in
            guard let meta = metadata(container) else { return nil }
            let emf = meta["emfAttributes"]
            guard case .object = emf else { return nil }
            if emf["Diplay_In_Schedule"].bool == false { return nil }
            let key = emf["MeetingKey"].string
            if key.isEmpty { return nil }
            let testing = emf["IsTestEvent"].bool == true
            var place = emf["Circuit_Short_Name"].string
            if place.isEmpty { place = emf["Meeting_Country_Name"].string }
            return Meeting(
                key: key,
                round: emf["Championship_Meeting_Ordinal"].int.flatMap { !testing && $0 > 0 ? $0 : nil },
                name: emf["Meeting_Name"].string,
                place: place,
                start: isoDate(emf["Meeting_Start_Date"].string),
                end: isoDate(emf["Meeting_End_Date"].string),
                pageId: emf["PageID"].int.flatMap { $0 > 0 ? $0 : nil },
                picturePath: nonEmpty(meta["pictureUrl"].string)
            )
        }
    }

    // MARK: Weekend

    /// A weekend's Formula 1 sessions and videos, from F1 TV's weekend page (its schedule also
    /// lists sessions that haven't started). When the response isn't a page with a schedule or
    /// rows, its containers are read as a `filter_MeetingKey` search result instead.
    /// `meetingName` names the weekend on its items; `now` decides which are upcoming.
    public static func weekend(_ json: JSONValue, meetingName: String? = nil, now: Date = Date()) -> WeekendContent {
        let (schedule, labelled) = weekendPage(json)
        let hasPage = !schedule.isEmpty || !labelled.isEmpty
        // Past races at this circuit belong to other weekends: a row of their own, not this one's videos.
        let containers: [JSONValue] = hasPage
            ? schedule + labelled.filter { !isArchive($0.label) }.flatMap(\.items)
            : json["resultObj"]["containers"].array

        var sessions: [CatalogItem] = []
        var videos: [CatalogItem] = []
        var seen = Set<Int>()
        var byId: [Int: CatalogItem] = [:]
        for container in containers {
            guard let meta = metadata(container), let id = meta["contentId"].int, id > 0 else { continue }
            if meta["contentType"].string == "BUNDLE" || !seen.insert(id).inserted { continue }
            let series = meta["uiSeries"].string.uppercased()
            if !series.isEmpty && series != "F1" { continue }
            let emf = meta["emfAttributes"]
            let isSession = emf["VideoType"].string == "meetingSession"
                && packageNames(container).contains { $0.hasSuffix("_Live") }
            var title = meta["titleBrief"].string
            if title.isEmpty { title = meta["title"].string }
            let item = CatalogItem(
                contentId: id,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                subtype: meta["contentSubtype"].string,
                contentType: meta["contentType"].string,
                genre: meta["genres"][0].string,
                picturePath: nonEmpty(meta["pictureUrl"].string),
                durationSeconds: meta["duration"].int,
                year: meta["year"].int,
                meeting: meetingName ?? emf["Meeting_Name"].string,
                start: date(ms: emf["sessionStartDate"])
            )
            byId[id] = item
            if isSession { sessions.append(item) } else { videos.append(item) }
        }

        func id(_ container: JSONValue) -> Int { metadata(container)?["contentId"].int ?? 0 }
        let ordered = schedule.compactMap { byId[id($0)] }
        let rows: [CatalogRow] = labelled.compactMap { label, items in
            var seenInRow = Set<Int>()
            let found = items
                .compactMap { isArchive(label) ? catalogItem($0) : byId[id($0)] }
                .filter { seenInRow.insert($0.contentId).inserted }
            return found.isEmpty ? nil : CatalogRow(title: label, items: found)
        }

        func startOrZero(_ item: CatalogItem) -> Date { item.start ?? Date(timeIntervalSince1970: 0) }
        let zero = Date(timeIntervalSince1970: 0)
        // What can be watched now leads, as on F1 TV's "Live & Replays" row: live, then the newest
        // replays, then press conferences and other undated videos in F1 TV's order, then shows
        // still to come in running order.
        let live = videos.filter { $0.isLive }
        let past = videos.filter { !$0.isLive && !$0.isUpcoming(now: now) }
        let dated = stableSorted(past.filter { startOrZero($0) > zero }) { startOrZero($0) > startOrZero($1) }
        let undated = past.filter { startOrZero($0) <= zero }
        let upcoming = stableSorted(videos.filter { !$0.isLive && $0.isUpcoming(now: now) }) { startOrZero($0) < startOrZero($1) }
        return WeekendContent(
            sessions: stableSorted(sessions) { startOrZero($0) < startOrZero($1) },
            videos: live + dated + undated + upcoming,
            schedule: stableSorted(ordered) { startOrZero($0) < startOrZero($1) },
            rows: rows
        )
    }

    // MARK: Home and collections

    /// F1 TV's home page. Rows that need F1 TV's own account features (My List), surveys and
    /// blank rows are left out.
    public static func home(_ json: JSONValue) -> HomePage {
        var featured: [CatalogItem] = []
        var rows: [CatalogRow] = []
        for container in json["resultObj"]["containers"].array {
            guard case .array(let results) = container["retrieveItems"]["resultObj"]["containers"] else { continue }
            let items = results.compactMap(catalogItem)
            let label = container["metadata"]["label"].string
            let uri = container["retrieveItems"]["uriOriginal"].string
            let layout = container["layout"].string
            switch layout {
            case "super_hero", "hero":
                featured = items.filter { $0.pageId == nil }
            case "horizontal_thumbnail", "vertical_thumbnail", "horizontal_simple_poster":
                if items.isEmpty || isBlank(label) || uri.contains("MYLIST")
                    || label.range(of: "Survey", options: .caseInsensitive) != nil { continue }
                let tag: RowTag?
                if uri.hasPrefix("/SANDWICH") { tag = .weekend }
                else if uri.contains("objectSubtype=Replay") && !uri.contains("filter_MeetingKey") { tag = .archive }
                else { tag = nil }
                rows.append(CatalogRow(title: label, items: items, posters: layout == "horizontal_simple_poster", tag: tag))
            default:
                break
            }
        }
        return HomePage(featured: featured, rows: rows)
    }

    /// A show's or documentary's page, by F1 TV's layouts: title, subtitle, hero and rows.
    public static func collection(_ json: JSONValue) -> CollectionPage {
        var title = ""
        var description = ""
        var hero: [CatalogItem] = []
        var rows: [CatalogRow] = []
        for container in json["resultObj"]["containers"].array {
            let label = container["metadata"]["label"].string
            let items = container["retrieveItems"]["resultObj"]["containers"].array
                .compactMap(catalogItem).filter { $0.pageId == nil }
            switch container["layout"].string {
            case "title": title = label
            case "subtitle": description = label
            case "hero": hero = items
            case "horizontal_thumbnail", "vertical_thumbnail":
                if !items.isEmpty { rows.append(CatalogRow(title: isBlank(label) ? "Episodes" : label, items: items)) }
            default: break
            }
        }
        // The page's lead videos, unless the rows have them already.
        let listed = Set(rows.flatMap(\.items).map(\.contentId))
        let lead = hero.filter { !listed.contains($0.contentId) }
        return CollectionPage(
            title: title, description: description, picturePath: hero.first?.picturePath,
            rows: (lead.isEmpty ? [] : [CatalogRow(title: "Latest", items: lead)]) + rows
        )
    }

    /// A search result (the archive's race replays, a season's videos): one item per content ID,
    /// without Kids content and season "meeting" entries. Replays lead, otherwise F1 TV's order.
    public static func search(_ json: JSONValue) -> [CatalogItem] {
        var seen = Set<Int>()
        let items = json["resultObj"]["containers"].array.compactMap(catalogItem).filter {
            $0.subtype != "MEETING"
                && $0.title.range(of: "Kids", options: .caseInsensitive) == nil
                && seen.insert($0.id).inserted
        }
        return items.filter { $0.subtype == "REPLAY" } + items.filter { $0.subtype != "REPLAY" }
    }

    // MARK: Video and play

    /// A video's feeds. F1 lists none for a session with a single feed: then one default "Main feed".
    /// Throws `.badResponse` when the response has no container at all (F1 TV has no such video).
    public static func video(_ json: JSONValue) throws -> VideoDetail {
        let container = json["resultObj"]["containers"][0]
        guard let meta = metadata(container) else {
            throw F1TVError.badResponse("F1 TV has no video for this content")
        }
        let contentId = meta["contentId"].int ?? 0
        let channels: [Channel] = meta["additionalStreams"].array.compactMap { stream in
            guard let id = stream["channelId"].int else { return nil }
            let onboard = stream["type"].string == "obc"
            return Channel(
                id: id,
                isDefault: stream["default"].bool ?? false,
                isOnboard: onboard,
                title: stream["title"].string,
                racingNumber: stream["racingNumber"].int.flatMap { onboard && $0 > 0 ? $0 : nil },
                driverLastName: stream["driverLastName"].string,
                teamName: stream["teamName"].string,
                teamColorHex: stream["hex"].string
            )
        }
        var title = meta["title"].string
        if title.isEmpty { title = "Content \(contentId)" }
        return VideoDetail(
            contentId: contentId, title: title,
            channels: channels.isEmpty ? [Channel(id: nil, isDefault: true, title: "Main feed")] : channels
        )
    }

    /// The stream to play. Throws `.badResponse` when F1 TV sends no usable `url`.
    public static func play(_ json: JSONValue) throws -> PlayInfo {
        let result = json["resultObj"]
        guard let url = URL(string: result["url"].string), !result["url"].string.isEmpty else {
            throw F1TVError.badResponse("PLAY returned no stream URL")
        }
        return PlayInfo(
            url: url,
            licenseURL: URL(string: result["laURL"].string).flatMap { result["laURL"].string.isEmpty ? nil : $0 },
            streamType: result["streamType"].string
        )
    }

    // MARK: Helpers

    /// The tile's `metadata` object, or nil when it is missing or not an object.
    private static func metadata(_ container: JSONValue) -> JSONValue? {
        if case .object = container["metadata"] { return container["metadata"] }
        return nil
    }

    private static func nonEmpty(_ s: String) -> String? { s.isEmpty ? nil : s }

    private static func isBlank(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isArchive(_ label: String) -> Bool {
        label.range(of: "Archive", options: .caseInsensitive) != nil
    }

    /// Milliseconds since 1970 as a date; nil for missing, zero or negative.
    private static func date(ms: JSONValue) -> Date? {
        guard case .number(let d) = ms, d > 0 else {
            if case .string = ms, let n = ms.int, n > 0 { return Date(timeIntervalSince1970: Double(n) / 1000) }
            return nil
        }
        return Date(timeIntervalSince1970: d / 1000)
    }

    private static func isoDate(_ s: String) -> Date {
        ISO8601DateFormatter().date(from: s) ?? Date(timeIntervalSince1970: 0)
    }

    /// The number in `/PAGE/<n>/` of an F1 TV action URI.
    private static func pageID(fromURI uri: String) -> Int? {
        guard let range = uri.range(of: "/PAGE/") else { return nil }
        let rest = uri[range.upperBound...]
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard rest.dropFirst(digits.count).first == "/" else { return nil }
        return Int(digits)
    }

    private static func packageNames(_ container: JSONValue) -> [String] {
        container["platformVariants"].array.flatMap { variant in
            variant["technicalPackages"].array.map { $0["packageName"].string }
        }
    }

    /// F1 TV's weekend page: its Formula 1 schedule events and its labelled rows, in its order.
    /// F1 Academy and blank rows are left out.
    private static func weekendPage(_ json: JSONValue) -> ([JSONValue], [(label: String, items: [JSONValue])]) {
        var schedule: [JSONValue] = []
        var rows: [(label: String, items: [JSONValue])] = []
        for container in json["resultObj"]["containers"].array {
            guard case .array(let results) = container["retrieveItems"]["resultObj"]["containers"] else { continue }
            switch container["layout"].string {
            case "interactive_schedule":
                let group = results.first { $0["eventName"].string == "FORMULA 1" }
                    ?? results.first { $0["eventName"].string == "ALL" }
                if let group { schedule += group["events"].array }
            case "horizontal_thumbnail":
                let label = container["metadata"]["label"].string
                if isBlank(label) || label.range(of: "Academy", options: .caseInsensitive) != nil { continue }
                rows.append((label, results))
            default:
                break
            }
        }
        return (schedule, rows)
    }

    /// A sort that keeps equal elements in their original order.
    private static func stableSorted<T>(_ items: [T], by areInIncreasingOrder: (T, T) -> Bool) -> [T] {
        items.enumerated()
            .sorted { a, b in
                if areInIncreasingOrder(a.element, b.element) { return true }
                if areInIncreasingOrder(b.element, a.element) { return false }
                return a.offset < b.offset
            }
            .map(\.element)
    }
}
