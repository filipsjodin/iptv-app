import Foundation

struct XtreamUserInfoResponse: Decodable {
    var userInfo: XtreamUserInfo?
    enum CodingKeys: String, CodingKey { case userInfo = "user_info" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userInfo = try? c.decode(XtreamUserInfo.self, forKey: .userInfo)
    }
}

struct XtreamUserInfo: Decodable {
    @LenientInt var auth: Int?
    @LenientString var status: String?
    @LenientInt var expDate: Int?
    @LenientInt var maxConnections: Int?
    @LenientInt var activeCons: Int?
    @LenientInt var isTrial: Int?
    var allowedOutputFormats: LenientStringList

    enum CodingKeys: String, CodingKey {
        case auth, status
        case expDate = "exp_date"
        case maxConnections = "max_connections"
        case activeCons = "active_cons"
        case isTrial = "is_trial"
        case allowedOutputFormats = "allowed_output_formats"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _auth = try c.decode(LenientInt.self, forKey: .auth)
        _status = try c.decode(LenientString.self, forKey: .status)
        _expDate = try c.decode(LenientInt.self, forKey: .expDate)
        _maxConnections = try c.decode(LenientInt.self, forKey: .maxConnections)
        _activeCons = try c.decode(LenientInt.self, forKey: .activeCons)
        _isTrial = try c.decode(LenientInt.self, forKey: .isTrial)
        allowedOutputFormats = (try? c.decode(LenientStringList.self, forKey: .allowedOutputFormats)) ?? LenientStringList()
    }
}

struct XtreamCategoryDTO: Decodable {
    @LenientString var categoryID: String?
    @LenientString var categoryName: String?
    enum CodingKeys: String, CodingKey { case categoryID = "category_id", categoryName = "category_name" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _categoryID = try c.decode(LenientString.self, forKey: .categoryID)
        _categoryName = try c.decode(LenientString.self, forKey: .categoryName)
    }
}

struct XtreamVodDTO: Decodable {
    @LenientString var streamID: String?
    @LenientString var name: String?
    @LenientString var streamIcon: String?
    @LenientDouble var rating: Double?
    @LenientInt var added: Int?
    @LenientString var categoryID: String?
    @LenientString var containerExtension: String?
    @LenientInt var tmdb: Int?
    @LenientInt var year: Int?
    enum CodingKeys: String, CodingKey {
        case streamID = "stream_id", name, streamIcon = "stream_icon", rating, added
        case categoryID = "category_id", containerExtension = "container_extension", tmdb, year
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _streamID = try c.decode(LenientString.self, forKey: .streamID)
        _name = try c.decode(LenientString.self, forKey: .name)
        _streamIcon = try c.decode(LenientString.self, forKey: .streamIcon)
        _rating = try c.decode(LenientDouble.self, forKey: .rating)
        _added = try c.decode(LenientInt.self, forKey: .added)
        _categoryID = try c.decode(LenientString.self, forKey: .categoryID)
        _containerExtension = try c.decode(LenientString.self, forKey: .containerExtension)
        _tmdb = try c.decode(LenientInt.self, forKey: .tmdb)
        _year = try c.decode(LenientInt.self, forKey: .year)
    }
}

struct XtreamSeriesDTO: Decodable {
    @LenientString var seriesID: String?
    @LenientString var name: String?
    @LenientString var cover: String?
    @LenientDouble var rating: Double?
    @LenientInt var lastModified: Int?
    @LenientString var categoryID: String?
    @LenientInt var tmdb: Int?
    @LenientInt var year: Int?
    enum CodingKeys: String, CodingKey {
        case seriesID = "series_id", name, cover, rating, lastModified = "last_modified"
        case categoryID = "category_id", tmdb, year
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _seriesID = try c.decode(LenientString.self, forKey: .seriesID)
        _name = try c.decode(LenientString.self, forKey: .name)
        _cover = try c.decode(LenientString.self, forKey: .cover)
        _rating = try c.decode(LenientDouble.self, forKey: .rating)
        _lastModified = try c.decode(LenientInt.self, forKey: .lastModified)
        _categoryID = try c.decode(LenientString.self, forKey: .categoryID)
        _tmdb = try c.decode(LenientInt.self, forKey: .tmdb)
        _year = try c.decode(LenientInt.self, forKey: .year)
    }
}

struct XtreamLiveDTO: Decodable {
    @LenientString var streamID: String?
    @LenientString var name: String?
    @LenientString var streamIcon: String?
    @LenientString var epgChannelID: String?
    @LenientString var categoryID: String?
    enum CodingKeys: String, CodingKey {
        case streamID = "stream_id", name, streamIcon = "stream_icon"
        case epgChannelID = "epg_channel_id", categoryID = "category_id"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _streamID = try c.decode(LenientString.self, forKey: .streamID)
        _name = try c.decode(LenientString.self, forKey: .name)
        _streamIcon = try c.decode(LenientString.self, forKey: .streamIcon)
        _epgChannelID = try c.decode(LenientString.self, forKey: .epgChannelID)
        _categoryID = try c.decode(LenientString.self, forKey: .categoryID)
    }
}

/// `info` i ett avsnitt. Fälten är toleranta; hela objektet kan saknas eller ha fel typ (Xtream skickar ibland `[]`).
struct XtreamEpisodeInfoDTO: Decodable {
    @LenientString var movieImage: String?
    @LenientString var plot: String?
    @LenientInt var durationSecs: Int?
    @LenientString var duration: String?
    enum CodingKeys: String, CodingKey {
        case movieImage = "movie_image", plot, durationSecs = "duration_secs", duration
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _movieImage = try c.decode(LenientString.self, forKey: .movieImage)
        _plot = try c.decode(LenientString.self, forKey: .plot)
        _durationSecs = try c.decode(LenientInt.self, forKey: .durationSecs)
        _duration = try c.decode(LenientString.self, forKey: .duration)
    }
}

struct XtreamEpisodeDTO: Decodable {
    @LenientString var id: String?
    @LenientInt var episodeNum: Int?
    @LenientString var title: String?
    @LenientString var containerExtension: String?
    @LenientInt var season: Int?
    var info: XtreamEpisodeInfoDTO?
    enum CodingKeys: String, CodingKey {
        case id, episodeNum = "episode_num", title, containerExtension = "container_extension", season, info
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _id = try c.decode(LenientString.self, forKey: .id)
        _episodeNum = try c.decode(LenientInt.self, forKey: .episodeNum)
        _title = try c.decode(LenientString.self, forKey: .title)
        _containerExtension = try c.decode(LenientString.self, forKey: .containerExtension)
        _season = try c.decode(LenientInt.self, forKey: .season)
        info = try? c.decode(XtreamEpisodeInfoDTO.self, forKey: .info)
    }
}

/// `episodes` är antingen ett objekt nycklat på säsongsnummer eller en array av arrayer.
struct XtreamSeriesInfoResponse: Decodable {
    /// (säsongsnyckel om känd, rader)
    var groups: [(season: Int?, rows: [XtreamEpisodeDTO])] = []

    enum CodingKeys: String, CodingKey { case episodes }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { Int(stringValue) }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { self.stringValue = String(intValue) }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let arrays = try? c.decode([[LenientRow<XtreamEpisodeDTO>]].self, forKey: .episodes) {
            groups = arrays.map { (season: nil, rows: $0.compactMap(\.value)) }
        } else if let obj = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: .episodes) {
            for key in obj.allKeys {
                let rows = (try? obj.decode([LenientRow<XtreamEpisodeDTO>].self, forKey: key)) ?? []
                groups.append((season: Int(key.stringValue), rows: rows.compactMap(\.value)))
            }
        } else if c.contains(.episodes), (try? c.decodeNil(forKey: .episodes)) != true {
            throw DecodingError.dataCorruptedError(forKey: .episodes, in: c, debugDescription: "episodes")
        }
    }
}

/// En rad i en lista som kan avgöra om den är användbar (används för att avslöja felsidor som `{"error":{...}}`).
protocol XtreamRow: Decodable, Sendable {
    var isValidRow: Bool { get }
}
extension XtreamCategoryDTO: XtreamRow { var isValidRow: Bool { categoryID != nil && categoryName != nil } }
extension XtreamVodDTO: XtreamRow { var isValidRow: Bool { streamID != nil && name != nil } }
extension XtreamSeriesDTO: XtreamRow { var isValidRow: Bool { seriesID != nil && name != nil } }
extension XtreamLiveDTO: XtreamRow { var isValidRow: Bool { streamID != nil && name != nil } }

/// Svar från `get_short_epg`: `epg_listings` kan saknas eller ha fel typ.
struct XtreamShortEPGResponse: Decodable {
    var listings: [XtreamEpgListingDTO]
    enum CodingKeys: String, CodingKey { case listings = "epg_listings" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rows = (try? c.decode([LenientRow<XtreamEpgListingDTO>].self, forKey: .listings)) ?? []
        listings = rows.compactMap { $0.value }
    }
}

/// Ett program i korta tablån. Titel och beskrivning är base64; tider är unix-sekunder eller text (UTC).
struct XtreamEpgListingDTO: Decodable {
    @LenientString var title: String?
    @LenientString var description: String?
    @LenientString var start: String?
    @LenientString var end: String?
    @LenientInt var startTimestamp: Int?
    @LenientInt var stopTimestamp: Int?
    enum CodingKeys: String, CodingKey {
        case title, description, start, end
        case startTimestamp = "start_timestamp", stopTimestamp = "stop_timestamp"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _title = try c.decode(LenientString.self, forKey: .title)
        _description = try c.decode(LenientString.self, forKey: .description)
        _start = try c.decode(LenientString.self, forKey: .start)
        _end = try c.decode(LenientString.self, forKey: .end)
        _startTimestamp = try c.decode(LenientInt.self, forKey: .startTimestamp)
        _stopTimestamp = try c.decode(LenientInt.self, forKey: .stopTimestamp)
    }
}
