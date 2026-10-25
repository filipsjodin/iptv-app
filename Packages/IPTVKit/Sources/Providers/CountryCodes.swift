/// Land- och språkkoder som IPTV-leverantörer vanligen använder som prefix (`SE: `, `|EN| `, `[UK] `).
/// Bara dessa koder tolkas som landsprefix, så att namn som `CSI: Miami` eller `BBC: News` lämnas orörda.
enum CountryCodes {
    static func contains(_ code: String) -> Bool { known.contains(code) }

    private static let known: Set<String> = {
        // ISO 3166-1 alpha-2 (utan tvetydiga som TV) samt UK.
        let countries = """
        AD AE AF AL AM AO AR AT AU AZ BA BD BE BG BH BR BY CA CH CL CN CO CR CU CY CZ DE DK DO DZ EC EE EG ES ET \
        FI FR GB GE GH GR GT HK HN HR HU ID IE IL IN IQ IR IS IT JM JO JP KE KG KH KR KW KZ LB LK LT LU LV LY MA \
        MD ME MK MM MN MT MX MY NG NI NL NO NP NZ OM PA PE PH PK PL PR PS PT PY QA RO RS RU SA SD SE SG SI SK SN \
        SO SV SY TH TJ TM TN TR TW TZ UA UG UK US UY UZ VE VN YE ZA ZW
        """
        // ISO 639-1 som ofta förekommer som språkprefix.
        let languages = """
        AF AR BG BN BS CS DA DE EL EN ES ET FA FI FR HE HI HR HU HY ID IS IT JA KA KK KO KU LT LV MK ML MS NB NL \
        NN NO PA PL PT RO RU SK SL SQ SR SV TA TE TG TH TL TR UK UR UZ VI ZH
        """
        // Längre koder som leverantörer använder.
        let extras = "USA GBR SWE NOR DEU FRA ESP ITA TUR POR NLD DNK FIN POL RUS ARA ARB LAT EXYU NORDIC"
        return Set([countries, languages, extras].flatMap { $0.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init) })
    }()
}
