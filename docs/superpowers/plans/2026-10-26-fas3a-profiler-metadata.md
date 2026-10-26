# Fas 3a – Profiler, metadata och upptäckt (data och logik): Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lägga grunden för Netflix-upplevelsen:
- profiler per spellista med egen historik, egna inställningar, Min lista och 👍/👎
- barnprofiler och PIN
- TMDB-metadata med träffsäker matchning och lokal cache
- motorn för upptäckt: För dig, Topp 10 i Sverige, genrer, Nyligen tillagt, liknande titlar och titlar per person
- en central anslutningsvakt
- de punkter från fas 2 som sköts upp hit

Gränssnittet i den här fasen är enkelt och funktionellt. Netflix-designen kommer i fas 3b.

**Architecture:** Det mesta är ren logik i IPTVKit och testas på Windows:
- `Personal`: profiler, Min lista och betyg
- `Metadata`: TMDB-klient, matchning och åldersgränser
- `Discovery`: rekommendationer och rader
- `StreamConnectionBroker` i PlaybackCore

Lagring på Apple-plattformar sker i IPTVPlatform: migrering v3 för metadatacache och matchningar, en PIN i Keychain under en egen service och `MetadataService`. Appen kopplar ihop allt via `ProfileSession`.

**Tech Stack:** Swift 6, SwiftUI, GRDB 7, URLSession, TMDB API v3 (Bearer-token), valfritt OMDb, XcodeGen, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-10-25-iptv-app-design.md`, avsnitten §6.6 (metadata), §6.7 (rekommendationer), §10 (profiler), §12 (stabila id:n) och §14 fas 3.

## Global Constraints

- Lägsta OS-version är tvOS, iOS och iPadOS 27. Swift 6 strict concurrency gäller, och publika typer är `Sendable`.
- Repot är publikt. Inga credentials, spellist-URL:er, API-nycklar, TMDB-token eller PIN-koder får hamna i git, CI-loggar, databasen, UserDefaults, loggar eller felmeddelanden.
- TMDB-token (`TMDB_READ_TOKEN`) och OMDb-nyckeln (`OMDB_API_KEY`) läses från Info.plist, som fylls från `Apps/Config/Secrets.xcconfig` (gitignored). Saknas en nyckel ska appen fungera utan metadata eller betyg. Den får inte krascha och inte visa fel i onödan.
- TMDB-anrop använder `language=sv-SE` med `en-US` som reserv. Token skickas i headern `Authorization: Bearer`, aldrig i URL:en.
- Bara gratisnivåer används. Vid HTTP 429 väntar klienten enligt `Retry-After` och gör högst 4 parallella anrop.
- Profiler gäller **per spellista** [Beslutat i spec §10]. Varje profil har egen historik, Min lista, 👍/👎, egna ljud- och textinställningar och egen förhandsvisningsinställning.
- Barnprofil: titlar utan åldersgräns döljs, liksom Live och Sport. PIN är valfritt per profil.
- Varje UserDefaults-nyckel ska ha **exakt en** lagringsinstans i appen. Nycklar per profil har formen `"<bas>.<profileID>"`.
- På Apple-plattformar skrivs `Core.Category`. Lägg inte till explicita beroenden på Library, GRDB eller PlaybackTestSupport i det app-hostade testmålet.
- Kod i IPTVKit testas lokalt med `source scripts/swift-env.sh && cd Packages/IPTVKit && swift test`. Övrig kod testas i CI via ett PR-utkast.

## Review Focus

1. **Titlar som TMDB matchar fel** (samma namn, olika år, remakes och titlar som inte finns hos TMDB). Under konfidenströskeln visas leverantörens egen data, aldrig fel affisch eller beskrivning. Test i Task 4: `ambiguousTitleBelowThresholdIsUnmatched`.
2. **Barnprofil och titlar utan åldersgräns.** De döljs, och inget vuxeninnehåll syns i någon rad: För dig, Topp 10, genrer, liknande titlar eller sök. Test i Task 7: `kidsProfileHidesUnratedEverywhere`.
3. **Byte av profil.** Fortsätt titta, Min lista och inställningar byts helt, och ingen data läcker mellan profiler. Test i Task 9: `switchingProfileSwapsAllPersonalState`.
4. **TMDB-token saknas eller TMDB svarar inte.** Appen fungerar med leverantörens data, och biblioteket blir aldrig tomt. Test i Task 5: `missingTokenDisablesEnrichmentGracefully`.
5. **Anslutningsgräns 1.** En förhandsvisning (fas 3b) eller en bakgrundsuppgift får aldrig blockera uppspelning, och uppspelning tar över platsen. Test i Task 3: `playbackPreemptsPreview`.

---

## Filstruktur

```
Packages/IPTVKit/
  Sources/Personal/   Profile.swift, ProfileStore.swift, PersonalStore.swift, ItemRef.swift, ProfilePinStore.swift
  Sources/Metadata/   TMDBClient.swift, TMDBDTO.swift, TitleMetadata.swift, TMDBMatcher.swift, Certification.swift, OMDbClient.swift
  Sources/Discovery/  DiscoveryEngine.swift, Candidate.swift, RowBuilder.swift
  Sources/PlaybackCore/StreamConnectionBroker.swift
  Tests/PersonalTests/ Tests/MetadataTests/(+Fixtures/tmdb_*.json) Tests/DiscoveryTests/ Tests/PlaybackCoreTests/BrokerTests.swift
Packages/IPTVPlatform/
  Sources/Library/AppDatabase.swift (v3), MetadataStore.swift, MetadataService.swift
  Sources/Secrets/KeychainProfilePinStore.swift
Apps/Shared/
  Profiles/ ProfileSession.swift, WhoIsWatchingView.swift, ProfileEditorView.swift, PinEntryView.swift
  AppModel.swift (ändras), Player/* (now playing, broker), Config/AppInfo.plist (TMDB/OMDb-nycklar)
Apps/Config/Secrets.xcconfig.template (TMDB_READ_TOKEN, OMDB_API_KEY)
```

---

### Task 1: Personal – profiler, Min lista och betyg

**Files:** Create `Packages/IPTVKit/Sources/Personal/*.swift`, `Tests/PersonalTests/*`. Modify `Package.swift`: target och product `Personal`, med beroenden på Core och PlaybackCore.

**Interfaces:**
- Produces:
  - `struct Profile: Codable, Hashable, Identifiable, Sendable { id: UUID; playlistID: UUID; name: String; avatar: String; isKids: Bool; hasPin: Bool; createdAt: Date }`. `avatar` är namnet på en SF Symbol eller en emoji. PIN-koden lagras aldrig här.
  - `protocol ProfileStore: Sendable`:
    - `func profiles(playlistID: UUID) -> [Profile]`
    - `func save(_: Profile)`
    - `func delete(id: UUID)`
    - `func lastUsed(playlistID: UUID) -> UUID?`
    - `func setLastUsed(_: UUID, playlistID: UUID)`
  - `UserDefaultsProfileStore(defaults:key: "profiles.v1")` och `InMemoryProfileStore`.
  - `struct ItemRef: Codable, Hashable, Sendable { kind: ContentKind; providerID: String }`
  - `enum Rating: String, Codable { case up, down }`
  - `protocol PersonalStore: Sendable`:
    - `func myList() -> [ItemRef]` (nyast först)
    - `func toggleMyList(_: ItemRef) -> Bool` (returnerar om posten finns kvar i listan)
    - `func isInMyList(_:) -> Bool`
    - `func rating(_:) -> Rating?`
    - `func setRating(_: Rating?, for: ItemRef)`
    - `func ratings() -> [ItemRef: Rating]`
  - `UserDefaultsPersonalStore(defaults:key:)`. Nyckeln är `"personal.v1.<profileID>"`, och kapaciteten är 1000 poster i Min lista respektive 2000 betyg.
  - `protocol ProfilePinStore: Sendable`:
    - `func setPin(_: String?, profileID: UUID) throws`
    - `func verify(_: String, profileID: UUID) throws -> Bool`
    - `func removePin(profileID: UUID) throws`
  - `InMemoryProfilePinStore`.
  - `enum ProfileKeys`:
    - `static func progress(_ id: UUID) -> String` = `"userstate.progress.v1.\(id)"`
    - `static func settings(_ id: UUID) -> String` = `"settings.playback.v1.\(id)"`
    - `static func personal(_ id: UUID) -> String`
  - `enum ProfileMigration { static func migrateLegacy(defaults: UserDefaults, playlists: [UUID], profiles: ProfileStore) -> [UUID: Profile] }`:
    - Skapar profilen "Profil 1" (avatar "person.crop.circle") för varje spellista som saknar profiler.
    - Flyttar posterna för spellistan från den globala `"userstate.progress.v1"` till profilens nyckel.
    - Kopierar `"settings.playback.v1"` till profilens inställningar.
    - Tar bort de globala nycklarna först när alla spellistor är migrerade.
    - Är idempotent.

- [ ] **Step 1: Skriv tester som misslyckas**

```swift
@Test func profilesArePerPlaylistAndOrdered() { /* två spellistor → profiles(playlistID:) visar bara spellistans profiler, sorterade efter createdAt */ }
@Test func myListToggleAndOrder() { /* toggle a, b → [b, a]; toggle a igen → [b]; isInMyList(a) == false */ }
@Test func ratingsSetAndClear() { /* setRating(.up, x); rating(x) == .up; setRating(nil, x) → nil */ }
@Test func personalStoresAreIsolatedPerProfile() { /* två profiler med olika nycklar → Min lista och betyg delas inte */ }
@Test func legacyMigrationMovesProgressPerPlaylist() {
    // globala progress-poster för spellista A och B samt globala inställningar → efter migrering har varje spellista profilen "Profil 1",
    // A:s poster ligger i A-profilens nyckel och B:s i B-profilens, inställningarna är kopierade och de globala nycklarna borttagna
}
@Test func legacyMigrationIsIdempotent() { /* migrera två gånger → oförändrat, inga dubbla profiler */ }
@Test func pinStoreVerifies() { /* setPin("1234") → verify("1234") true, verify("0000") false, removePin → hasPin false */ }
@Test func corruptDataYieldsEmpty() { /* skräpdata under nycklarna → tomma listor, ingen krasch */ }
```

- [ ] **Step 2:** Kör `swift test --filter PersonalTests`. Förväntat resultat: FAIL.
- [ ] **Step 3:** Implementera. Lagringen är trådsäker med lås och `@unchecked Sendable` (med en kommentar om varför), och den sparar en JSON-blob per nyckel.
- [ ] **Step 4:** Kör `swift test`. Förväntat resultat: PASS. Pusha och kontrollera att `kit-tests` i CI är grönt.
- [ ] **Step 5:** Commit: `feat(personal): profiler, Min lista, betyg och migrering till profilnycklar`.

---

### Task 2: Keychain-PIN och separerade Keychain-services

**Files:** Create `Packages/IPTVPlatform/Sources/Secrets/KeychainProfilePinStore.swift` och `Tests/SecretsTests/KeychainProfilePinStoreTests.swift`. Modify `Package.swift`, där Secrets får beroende på Personal.

**Interfaces:**
- Consumes: `ProfilePinStore` (Task 1).
- Produces: `KeychainProfilePinStore(service: String = "se.sjodin.iptv.profilepin")`.
  - PIN-koden sparas som en saltad SHA-256-hash. Den beräknas med `CryptoKit.SHA256`, som finns på Apple, och saltet är 16 slumpbytes som lagras tillsammans med hashen.
  - `verify` jämför i konstant tid.
  - Använder **inte** spellistornas service. Det skyddar mot städningen i `AppModel.load()`, som raderar alla UUID-konton under `se.sjodin.iptv.playlist`.

- [ ] **Step 1: Skriv tester som misslyckas**

```swift
@Test func pinRoundTripAndWrongPin() throws { /* unik service per test; set, verify ok/fel, remove */ }
@Test func pinStoredHashedNotPlain() throws { /* läs den råa Keychain-posten → innehåller inte "1234" i klartext */ }
@Test func playlistSweepDoesNotTouchPins() throws { /* KeychainCredentialStore(service: playlist).allPlaylistIDs() innehåller inte profil-id:n som har PIN */ }
```

- [ ] **Step 2–4:** Pusha och kontrollera att CI går från RED till GREEN.
- [ ] **Step 5:** Commit: `feat(secrets): PIN per profil i egen Keychain-service`.

---

### Task 3: StreamConnectionBroker

**Files:** Create `Packages/IPTVKit/Sources/PlaybackCore/StreamConnectionBroker.swift` och `Tests/PlaybackCoreTests/BrokerTests.swift`.

**Interfaces:**
- Produces:
  - `enum StreamPurpose: Int, Comparable, Sendable { case download = 0, preview = 1, playback = 2 }`
  - `final class StreamLease: Sendable { let id: UUID; let purpose: StreamPurpose; let playlistID: UUID }`
  - `actor StreamConnectionBroker`:
    - `init()`
    - `func setLimit(_ limit: Int?, playlistID: UUID)`. `nil` betyder okänd gräns, som behandlas som **1**.
    - `func acquire(_ purpose: StreamPurpose, playlistID: UUID, onRevoke: @escaping @Sendable () async -> Void) async -> StreamLease?`
    - `func release(_ lease: StreamLease)`
  - Regler:
    - **Uppspelning** får alltid en plats. Om gränsen är nådd återkallas lägre syften: först nedladdningar, sedan förhandsvisningar. Brokern anropar deras `onRevoke` och väntar på det, och `onRevoke` ska stänga strömmen och vänta tills den är stängd. Därefter tilldelas platsen.
    - Om gränsen är nådd av **andra uppspelningar** återkallas den äldsta uppspelningen.
    - **Förhandsvisning** får `nil` direkt om ingen plats finns. Den tränger aldrig undan något.
    - **Nedladdning** får en plats bara om den är ledig, och annars `nil`. Köhanteringen ligger i fas 7.
    - Leasingar som släpps eller återkallas räknas inte längre.

- [ ] **Step 1: Skriv tester som misslyckas**

```swift
@Test func previewGetsNilWhenFull() async { /* gräns 1, uppspelning håller platsen → acquire(.preview) == nil */ }
@Test func playbackPreemptsPreview() async {
    // gräns 1: förhandsvisning håller platsen → acquire(.playback) anropar förhandsvisningens onRevoke (som väntar 50 ms), lease returneras efter onRevoke, revoke anropad exakt en gång
}
@Test func playbackPreemptsOldestPlayback() async { /* gräns 1: två uppspelningar i följd → den första återkallas */ }
@Test func unknownLimitTreatedAsOne() async { /* utan setLimit → andra förhandsvisningen ger nil */ }
@Test func limitTwoAllowsPlaybackPlusPreview() async { }
@Test func releaseFreesSlot() async { }
@Test func perPlaylistIsolation() async { /* gränserna gäller per spellista */ }
```

- [ ] **Step 2:** Kör `swift test --filter BrokerTests`. Förväntat resultat: FAIL.
- [ ] **Step 3:** Implementera. Återkallningen sker utanför actorns kritiska avsnitt. Markera leasingen som "revoking", anropa `await onRevoke()` och ta sedan bort den. Två samtidiga `acquire(.playback)` får inte återkalla samma lease två gånger.
- [ ] **Step 4:** Kör `swift test`. Förväntat resultat: PASS.
- [ ] **Step 5:** Commit: `feat(playback-core): StreamConnectionBroker med prioritet och återkallning`.

---

### Task 4: Metadata – TMDB-klient, DTO:er, matchning och åldersgränser

**Files:** Create `Packages/IPTVKit/Sources/Metadata/*.swift` och `Tests/MetadataTests/*` (fixturer `tmdb_*.json` med fejkade men realistiska svar). Modify `Package.swift`: target och product `Metadata`, med beroenden på Core och Providers (för `HTTPClient` och `TitleCleaner`).

**Interfaces:**
- Produces:
  - `struct TitleMetadata: Codable, Sendable, Equatable`. Fälten är `tmdbID: Int`, `kind: ContentKind`, `title: String`, `originalTitle: String?`, `overview: String?`, `year: Int?`, `runtimeMinutes: Int?`, `genres: [Genre]`, `voteAverage: Double?`, `voteCount: Int?`, `popularity: Double?`, `posterPath: String?`, `backdropPath: String?`, `logoPath: String?`, `cast: [Person]` (högst 15), `directors: [Person]`, `creators: [Person]`, `keywords: [String]`, `certification: String?`, `ageLimit: Int?`, `recommendations: [Int]`, `similar: [Int]`, `imdbID: String?`, `seasons: [SeasonSummary]` och `language: String`.
    - `struct Genre: Codable, Hashable { id: Int; name: String }`
    - `struct Person: Codable, Hashable { id: Int; name: String; character: String?; profilePath: String? }`
    - `struct SeasonSummary: Codable, Hashable { number: Int; episodeCount: Int; name: String? }`
  - `struct TMDBSearchResult: Codable, Sendable { id: Int; title: String; originalTitle: String?; year: Int?; popularity: Double; kind: ContentKind }`
  - `struct TMDBClient: Sendable`, med `init(token: String, http: HTTPClient, language: String = "sv-SE", fallbackLanguage: String = "en-US")` och metoderna:
    - `func search(_ query: String, year: Int?, kind: ContentKind) async throws -> [TMDBSearchResult]`
    - `func details(id: Int, kind: ContentKind) async throws -> TitleMetadata`. Använder `append_to_response` med `credits,keywords,recommendations,similar,images,release_dates|content_ratings,external_ids`. Om `overview` saknas på sv-SE hämtas en-US-översikten.
    - `func trending(kind: ContentKind, window: TrendingWindow = .week) async throws -> [Int]`
    - `func popular(kind: ContentKind, region: String = "SE") async throws -> [Int]`
  - `enum TMDBError: Error, Equatable { case unauthorized, rateLimited(retryAfter: Double?), notFound, http(Int), invalidResponse, unavailable }`. Inga URL:er eller token i felen.
  - `HTTPClient` utökas med `func get(_ url: URL, headers: [String: String]) async throws -> (Data, Int, [String: String])` och en standardimplementation. Existerande `get(_:)` behålls.
  - `struct MatchResult: Sendable, Equatable { tmdbID: Int?; confidence: Double }`
  - `enum TMDBMatcher`:
    - `static let threshold = 0.75`
    - `static func match(_ title: CleanTitle, kind: ContentKind, candidates: [TMDBSearchResult]) -> MatchResult`
    - Poängsättning: normaliserad titellikhet (Levenshtein-ratio över gemener, diakritiska tecken bortskalade, interpunktion borttagen) mot `title` och `originalTitle`, där den bästa räknas. Årsmatchning ger +0,15 vid exakt år, +0,05 vid ±1 och −0,25 om året skiljer mer än 1. Popularitet bryter bara oavgjort. Om två kandidater ligger inom 0,05 av varandra och saknar årsstöd blir det **ingen träff** (tvetydigt).
  - `enum Certification`:
    - `static func ageLimit(from releaseDates: [String: [String]], preferredCountry: String = "SE", fallback: String = "US") -> (certification: String?, age: Int?)`
    - Mappning för SE: "Btl" ger 0, "7" ger 7, "11" ger 11 och "15" ger 15. Mappning för US (film): G ger 0, PG ger 7, PG-13 ger 13, R ger 17 och NC-17 ger 18. TV-Y och TV-G ger 0, TV-Y7 ger 7, TV-PG ger 10, TV-14 ger 14 och TV-MA ger 17. Okänt ger `nil`.
    - `static let kidsMaxAge = 11`
  - `struct OMDbClient: Sendable`, med `init(apiKey: String, http: HTTPClient)` och `func ratings(imdbID: String) async throws -> ExternalRatings` (`imdb: Double?`, `rottenTomatoes: Int?`). Nyckeln skickas som query-parameter, eftersom OMDb kräver det. Den redigeras bort i fel och får aldrig loggas.

- [ ] **Step 1: Skriv tester som misslyckas** (fixturer och `StubHTTPClient`)

```swift
@Test func searchParsesYearsAndKinds() async throws { /* fixtur tmdb_search_movie.json → year från release_date "2024-02-27" ger 2024 */ }
@Test func tokenOnlyInHeaderNeverInURL() async throws { /* stubben fångar URL och headers: URL:en innehåller inte token, headern "Authorization" == "Bearer <token>" */ }
@Test func detailsMapsEverything() async throws { /* tmdb_movie_details.json: genrer, cast(15), regissör, nyckelord, rekommendationer, imdbID, certifiering SE "11" ger ålder 11 */ }
@Test func overviewFallsBackToEnglish() async throws { /* sv-svaret har tom overview → ett andra anrop med en-US, overview fylls */ }
@Test func rateLimitedSurfacesRetryAfter() async { /* 429 + Retry-After 2 → TMDBError.rateLimited(retryAfter: 2) */ }
@Test(arguments: [
  ("Dune: Part Two", 2024, [("Dune: Part Two", 2024, 500.0), ("Dune", 2021, 300.0)], 1),   // index för förväntad kandidat
  ("Dune", nil,           [("Dune", 2021, 300.0), ("Dune", 1984, 40.0)], -1),             // tvetydigt utan år → ingen träff
  ("Dune", 1984,          [("Dune", 2021, 300.0), ("Dune", 1984, 40.0)], 1),
  ("Bron", 2011,          [("The Bridge", 2011, 50.0, originalTitle: "Bron")], 0),
  ("Okänd film xyz", nil, [("Helt annat", 2010, 10.0)], -1),
])
func matching(...) { }
@Test func ambiguousTitleBelowThresholdIsUnmatched() { /* likhet 0,6 → tmdbID nil */ }
@Test func certificationMapping() { /* SE före US; bara US ger US-mappning; inget → nil */ }
@Test func omdbKeyRedactedInErrors() async { /* misslyckat anrop → String(describing: error) innehåller inte nyckeln */ }
```

- [ ] **Step 2:** Kör `swift test --filter MetadataTests`. Förväntat resultat: FAIL.
- [ ] **Step 3:** Implementera. Lägg till Levenshtein som en ren intern funktion.
- [ ] **Step 4:** Kör `swift test`. Förväntat resultat: PASS. Kontrollera att CI är grönt.
- [ ] **Step 5:** Commit: `feat(metadata): TMDB-klient, matchning, åldersgränser och OMDb`.

---

### Task 5: Metadatacache i databasen och MetadataService

**Files:** Modify `Packages/IPTVPlatform/Sources/Library/AppDatabase.swift`, där migrering v3 läggs till. Create `MetadataStore.swift`, `MetadataService.swift` och `Tests/LibraryTests/MetadataStoreTests.swift`, `MetadataServiceTests.swift`. Modify `Package.swift`, där Library får beroende på Metadata.

**Interfaces:**
- Consumes: `TMDBClient`, `TMDBMatcher`, `TitleMetadata` och `Certification` från Task 4, samt `TitleCleaner` och `LibraryStore`.
- Produces:
  - Migreringen `"v3"` skapar fyra tabeller:
    - `tmdbTitle(kind TEXT, tmdbID INTEGER, language TEXT, json TEXT NOT NULL, fetchedAt REAL NOT NULL, PRIMARY KEY(kind, tmdbID))`
    - `tmdbMatch(playlistID TEXT REFERENCES playlist(id) ON DELETE CASCADE, kind TEXT, providerID TEXT, tmdbID INTEGER, confidence REAL NOT NULL, attemptedAt REAL NOT NULL, PRIMARY KEY(playlistID, kind, providerID))`
    - `titleGenre(kind TEXT, tmdbID INTEGER, genreID INTEGER, PRIMARY KEY(kind, tmdbID, genreID))`, med indexet `titleGenre_genre(genreID)`
    - `tmdbList(name TEXT PRIMARY KEY, ids TEXT NOT NULL, fetchedAt REAL NOT NULL)`
    
    Matchningar ligger i en egen tabell och överlever därför `replaceCatalog`.
  - `final class MetadataStore: Sendable` med metoderna:
    - `func metadata(kind:tmdbID:) throws -> TitleMetadata?`
    - `func saveMetadata(_: TitleMetadata, now: Date) throws`, som också fyller `titleGenre`
    - `func match(playlistID:kind:providerID:) throws -> (tmdbID: Int?, confidence: Double, attemptedAt: Date)?`
    - `func saveMatch(...) throws`
    - `func list(_ name: String) throws -> (ids: [Int], fetchedAt: Date)?`
    - `func saveList(_ name: String, ids: [Int], now: Date) throws`
    - `func unmatchedItems(playlistID:kind:limit:) throws -> [(providerID: String, title: String, year: Int?, providerTMDBID: Int?)]`. Returnerar poster som saknar en matchrad, eller vars matchning saknar id och är äldre än 7 dagar.
    - `func items(playlistID: UUID, kind: ContentKind, genreID: Int, limit: Int) throws -> [LibraryItem]`
    - `func items(playlistID: UUID, kind: ContentKind, tmdbIDs: [Int]) throws -> [LibraryItem]`, i samma ordning som indata och bara poster som finns i spellistan
    - `func tmdbID(playlistID:kind:providerID:) throws -> Int?`. Leverantörens `tmdbID` vinner, därefter matchningen.
  - `actor MetadataService`:
    - `init(store: MetadataStore, library: LibraryStore, client: TMDBClient?, now: @escaping @Sendable () -> Date = Date.init)`. Om `client` är `nil` är berikning avstängd.
    - `func metadata(playlistID: UUID, kind: ContentKind, providerID: String) async -> TitleMetadata?`. Läser från cachen och hämtar annars. TTL är 30 dagar, och vid fel returneras gammal cache.
    - `func enrich(playlistID: UUID, batch: Int = 200) async -> Int`. Bearbetar omatchade poster i bakgrunden med högst 4 parallella anrop och respekterar `rateLimited`. Returnerar antalet nya matchningar.
    - `func refreshLists() async`. Hämtar `trending.movie`, `trending.series`, `popular.movie.SE` och `popular.series.SE` med en TTL på 12 timmar.
    - `var isEnabled: Bool`

- [ ] **Step 1: Skriv tester som misslyckas** (CI)

```swift
@Test func matchesSurviveCatalogRefresh() throws { /* saveMatch → replaceCatalog med samma film → match finns kvar */ }
@Test func providerTMDBIDWins() throws { /* film med tmdbID 42 från leverantören → tmdbID(...) == 42 utan matchrad */ }
@Test func genreQueryReturnsOnlyPlaylistItems() throws { }
@Test func tmdbIDListKeepsOrderAndFilters() throws { /* [5, 3, 9] där 9 saknas i spellistan → items för 5, 3 */ }
@Test func enrichMatchesAndCaches() async throws { /* stubbad TMDB: 3 filmer → 2 matchade (en tvetydig), metadata sparad, titleGenre fylld */ }
@Test func staleCacheUsedWhenTMDBFails() async throws { }
@Test func missingTokenDisablesEnrichmentGracefully() async throws { /* client nil → metadata returnerar nil, enrich returnerar 0, inga fel */ }
@Test func migrationV2ToV3KeepsData() throws { /* v2-databas med rader → migrera → befintlig data intakt, nya tabeller finns */ }
```

- [ ] **Step 2–4:** Pusha och kontrollera att CI går från RED till GREEN. Prestandatestet från fas 1 ska fortfarande hålla.
- [ ] **Step 5:** Commit: `feat(library): metadatacache, matchningar och MetadataService`.

---

### Task 6: Discovery – rader och rekommendationer

**Files:** Create `Packages/IPTVKit/Sources/Discovery/*.swift` och `Tests/DiscoveryTests/*`. Modify `Package.swift`: target `Discovery`, med beroenden på Core, Metadata, Personal och PlaybackCore.

**Interfaces:**
- Produces:
  - `struct Candidate: Sendable, Hashable { ref: ItemRef; tmdbID: Int?; title: String; genres: [Int]; castIDs: [Int]; directorIDs: [Int]; keywords: [String]; ageLimit: Int?; addedAt: Date?; popularity: Double? }`
  - `struct Signals: Sendable { watched: [ItemRef: Double]; ratings: [ItemRef: Rating]; myList: Set<ItemRef>; recommendationsFor: [ItemRef: [Int]] }`. Värdet i `watched` är andelen sedd, 0 till 1.
  - `enum DiscoveryEngine`:
    - `static func forYou(candidates: [Candidate], signals: Signals, limit: Int) -> [ItemRef]`
      - Profilvikter: sedd ≥ 0,9 ger +1, 👍 ger +2, Min lista ger +1 och 👎 ger −3.
      - Varje kandidat får poäng som summan av vikterna gånger överlappet, med genre 1,0, skådespelare 0,6, regissör 0,8 och nyckelord 0,4. Till det läggs +1,5 om kandidatens tmdbID finns i `recommendationsFor` för en titel med positiv vikt.
      - Titlar som redan är sedda (≥ 0,9) och titlar med 👎 tas bort. Kandidater med samma tmdbID som en titel med 👎 straffas också.
      - Oavgjort bryts med popularitet. Om signaler saknas faller funktionen tillbaka på popularitet.
    - `static func topTen(rankedTMDBIDs: [Int], candidates: [Candidate]) -> [ItemRef]`. Returnerar de första 10 som finns i spellistan.
    - `static func byGenre(_ genreID: Int, candidates: [Candidate], limit: Int) -> [ItemRef]`, sorterad efter popularitet.
    - `static func recentlyAdded(candidates: [Candidate], limit: Int) -> [ItemRef]`, efter `addedAt` i fallande ordning.
    - `static func similar(to: Candidate, candidates: [Candidate], tmdbSimilar: [Int], limit: Int) -> [ItemRef]`. TMDB-listan kommer först, därefter genre- och nyckelordsöverlapp, och titeln själv utesluts.
    - `static func byPerson(_ personID: Int, candidates: [Candidate]) -> [ItemRef]`
    - `static func kidsFilter(_: [Candidate], maxAge: Int = Certification.kidsMaxAge) -> [Candidate]`. Titlar utan `ageLimit` tas bort.
  - `enum RowID: Hashable, Sendable { case continueWatching, forYou, topTen(ContentKind), recentlyAdded(ContentKind), myList, genre(Int, ContentKind) }`. Raderna byggs i appen.

- [ ] **Step 1: Skriv tester som misslyckas**

```swift
@Test func forYouPrefersLikedGenresAndCast() { }
@Test func forYouExcludesWatchedAndDisliked() { }
@Test func forYouUsesTMDBRecommendations() { }
@Test func forYouFallsBackToPopularityWithoutSignals() { }
@Test func topTenKeepsRankAndSkipsMissing() { /* rankade [5, 1, 9, ...], 9 saknas → [5, 1, ...] högst 10 */ }
@Test func similarExcludesSelfAndPrefersTMDB() { }
@Test func kidsFilterDropsUnratedAndAdult() { /* ålder nil, 15, 7 → bara 7 */ }
@Test func deterministicOrdering() { /* samma indata → samma utdata, och lika poäng bryts med ref */ }
```

- [ ] **Step 2–4:** Kör lokalt och kontrollera att det går från RED till GREEN. Kontrollera även CI.
- [ ] **Step 5:** Commit: `feat(discovery): För dig, topp 10, genrer, liknande och per person`.

---

### Task 7: Upptäckt i Library – kandidater och rader per profil

**Files:** Create `Packages/IPTVPlatform/Sources/Library/DiscoveryService.swift` och `Tests/LibraryTests/DiscoveryServiceTests.swift`.

**Interfaces:**
- Consumes: `MetadataStore` och `MetadataService` (Task 5), `DiscoveryEngine`, `Candidate` och `Signals` (Task 6), `PersonalStore` (Task 1), `UserStateStore` och `LibraryStore`.
- Produces: `final class DiscoveryService: Sendable` med:
  - `init(library: LibraryStore, metadata: MetadataStore)`
  - `func candidates(playlistID: UUID, kind: ContentKind) throws -> [Candidate]`. Byggs i **en** SQL-fråga per typ, med en join mot matchningar och cachad metadata. Resultatet cachas i minnet per spellista tills nästa import eller berikning, och `invalidate(playlistID:)` tömmer cachen.
  - `func rows(playlistID: UUID, profile: Profile, personal: PersonalStore, userState: UserStateStore, kinds: [ContentKind]) throws -> [(RowID, [LibraryItem])]`. Ordningen på Hem är: För dig, Topp 10 filmer, Topp 10 serier, Nyligen tillagt, Min lista och genrer (de 8 största genrerna i spellistan). Fortsätt titta kommer från appen.
  - `func similar(playlistID:kind:providerID:limit:) throws -> [LibraryItem]`
  - `func byPerson(playlistID:personID:) throws -> [LibraryItem]`
  - `func search(...)`: befintlig sökning med barnfiltret tillämpat för barnprofiler.
  - **Barnprofil:** alla rader, liknande titlar, sökning och titlar per person går genom `kidsFilter`, och Live och Sport utesluts.

- [ ] **Step 1: Skriv tester som misslyckas**

```swift
@Test func kidsProfileHidesUnratedEverywhere() throws { /* bibliotek med ålder 7, 15 och nil → barnprofilens rader, sökning, liknande och per person innehåller bara 7 */ }
@Test func rowsOrderAndGenreSelection() throws { }
@Test func topTenUsesCachedTMDBList() throws { }
@Test func candidatesSingleQueryPerformance() throws { /* 120 000 filmer → candidates < 1,5 s i release (körs i nattlig prestandasvit) */ }
@Test func myListRowOnlyExistingTitles() throws { }
```

- [ ] **Step 2–4:** Pusha och kontrollera att CI och Nightly går från RED till GREEN.
- [ ] **Step 5:** Commit: `feat(library): DiscoveryService med rader per profil och barnfilter`.

---

### Task 8: Profilsession i appen och anslutningsvakten

**Files:** Create `Apps/Shared/Profiles/ProfileSession.swift`, `WhoIsWatchingView.swift`, `ProfileEditorView.swift` och `PinEntryView.swift`. Modify `AppModel.swift`, `Player/PlayerScreen*.swift`, `Settings/SettingsView.swift`, `Localizable.xcstrings` och `project.yml` (produkterna Personal, Metadata och Discovery). Test: `Apps/SharedTests/ProfileSessionTests.swift`.

**Interfaces:**
- Consumes: Task 1–7.
- Produces:
  - `@MainActor @Observable final class ProfileSession`:
    - `let profile: Profile`
    - `let userState: UserStateStore`
    - `let personal: PersonalStore`
    - `var settings: PlaybackSettings`
    
    Den skapas av `AppModel.select(profile:)`. Det finns exakt en instans per profil, och `AppModel` cachar instanserna i en dictionary.
  - `AppModel` utökas med:
    - `var activeProfile: ProfileSession?`
    - `func profiles(for playlistID: UUID) -> [Profile]`
    - `func addProfile(...)`, `func updateProfile(...)` och `func deleteProfile(_:)`. `deleteProfile` rensar profilens nycklar och PIN.
    - `func select(profile: Profile, pin: String?) async throws`. Kastar `ProfileError.wrongPin` vid fel PIN.
    - `let broker = StreamConnectionBroker()`
    - `let metadata: MetadataService`
    - `let discovery: DiscoveryService`
    - `userState` och `settings` på `AppModel` blir delegeringar till `activeProfile`. Befintliga anrop ändras till profilsessionen.
  - Vid start:
    - `ProfileMigration.migrateLegacy` körs.
    - Har spellistan flera profiler visas "Vem tittar?". Har den en enda profil utan PIN väljs den automatiskt.
    - Gränsen sätts från `accountInfo` med `broker.setLimit`.
    - `metadata.enrich` och `refreshLists` startar i bakgrunden efter import och vid start, med lägsta prioritet.
  - Uppspelning:
    - `PlayerScreen` begär `broker.acquire(.playback, …)` innan sessionen startar.
    - `onRevoke` anropar `session.stopAndWait()` och stänger spelaren med meddelandet "Uppspelningen avbröts av en annan uppspelning".
    - Leasingen släpps vid stängning.
  - **Barnprofil:** Live-fliken döljs.
  - Inställningar:
    - Profilhantering med namn, avatar (12 SF Symbols), barnprofil och PIN (4 siffror).
    - Ett byte av profil sker via "Byt profil".
    - TMDB-status: aktiverad, saknar nyckel eller antal matchade titlar.

- [ ] **Step 1: Skriv tester som misslyckas**

```swift
@MainActor @Test func switchingProfileSwapsAllPersonalState() async { /* profil A: progress, Min lista och motor = vlc; profil B tom → välj B → continueWatching tom, myList tom, motor automatisk; välj A igen → allt tillbaka */ }
@MainActor @Test func singleProfileWithoutPinAutoSelected() async { }
@MainActor @Test func wrongPinRejected() async { }
@MainActor @Test func deleteProfileClearsKeysAndPin() async { }
@MainActor @Test func onePersistentStoreInstancePerProfile() async { /* select(A), select(B), select(A) → samma objektidentitet för A:s userState */ }
@MainActor @Test func playbackAcquiresAndReleasesLease() async { /* FakeEngine/TestEngine: öppna → lease finns, stäng → släppt */ }
@MainActor @Test func kidsProfileHidesLive() async { }
@MainActor @Test func legacyDataMigratedOnFirstLaunch() async { }
```

- [ ] **Step 2–4:** Pusha och kontrollera att CI går från RED till GREEN.
- [ ] **Step 5:** Commit: `feat(app): profiler, Vem tittar?, PIN, anslutningsvakt och metadata i bakgrunden`.

---

### Task 9: Funktionell upptäckt i appen och uppskjutna punkter från fas 2

**Files:** Modify `Apps/Shared/LibraryBrowserView.swift`, `Detail/*.swift`, `ContinueWatchingRow.swift`, `Player/AVPlayerHost.swift`, `Packages/IPTVPlayback/Sources/VLCEngine/VLCPlayerEngine.swift` och `Apps/Config/*`. Test: `Apps/SharedTests/DiscoveryUITests.swift` (modelltester).

**Interfaces / innehåll:**
- **Hem (funktionell lista, designen kommer i 3b):** raderna från `DiscoveryService.rows` plus Fortsätt titta, som vertikala sektioner med horisontella listor. Ett val öppnar detaljsidan.
- **Detaljsidor:**
  - Visar TMDB-metadata när den finns: beskrivning, betyg (TMDB samt IMDb och Rotten Tomatoes om OMDb-nyckel finns), genrer, åldersgräns, skådespelare och regissör.
  - Knapparna "Min lista" och 👍/👎 kopplas till `PersonalStore`.
  - Visar "Liknande titlar". Ett klick på en person ger en lista med "Allt med <namn>".
- **Fortsätt titta:** filtret per typ tillämpas **före** gränsen på 20.
- **Now Playing på iOS:** sätt `externalMetadata` (titel) från app-targetet när `AVPlayerItem.responds(to: #selector(setter: AVPlayerItem.externalMetadata))`. VLC får titeln via `MPNowPlayingInfoCenter`, och AVPlayer rör inte den.
- **VLC-frigöring:** ingen lokal stark referens till spelaren får finnas kvar på huvudtråden efter överlämningen till bakgrundskön.
- **Nycklar:** `Secrets.xcconfig.template` får `TMDB_READ_TOKEN =` och `OMDB_API_KEY =`, och `AppInfo.plist` läser `$(TMDB_READ_TOKEN)` och `$(OMDB_API_KEY)`. README beskriver hur du skapar ett gratis TMDB-konto och en "API Read Access Token".

- [ ] **Step 1: Skriv tester som misslyckas**

```swift
@MainActor @Test func homeRowsForProfile() async { /* stubbad discovery → rader i rätt ordning, och Fortsätt titta först när det finns */ }
@MainActor @Test func myListAndRatingsFromDetail() async { }
@MainActor @Test func continueWatchingFiltersBeforeLimit() async { /* 25 seriposter, 3 filmposter → Filmer-fliken visar 3 */ }
@MainActor @Test func detailFallsBackToProviderData() async { /* metadata saknas → titel och affisch från leverantören, ingen krasch */ }
```

- [ ] **Step 2–4:** Pusha och kontrollera att CI går från RED till GREEN.
- [ ] **Step 5:** Commit: `feat(app): funktionell upptäckt, Min lista och betyg, now playing och uppskjutna fas 2-punkter`.

---

### Task 10: Fasavslut – README och testlista

- [ ] **Step 1:** Lägg till i README:
  - **Avsnittet "TMDB och OMDb"** med stegen för att skaffa nycklar och var de ska ligga (`Apps/Config/Secrets.xcconfig`, aldrig i git).
  - **Testlista fas 3a:**
    - Skapa två profiler och en barnprofil med PIN.
    - Profilerna har separat historik och Min lista.
    - Barnprofilen visar inget utan åldersgräns och har ingen Live-flik.
    - Metadata dyker upp efter en stund.
    - För dig ändras efter 👍.
    - Topp 10 visar bara titlar som finns i spellistan.
    - En uppspelning tar över en förhandsvisning (testas i 3b).
- [ ] **Step 2:** Kör `gitleaks detect --config .gitleaks.toml`, som ska ge `no leaks found`, och kontrollera att CI är grönt.
- [ ] **Step 3:** Commit: `docs: TMDB-nycklar och testlista för fas 3a`.
