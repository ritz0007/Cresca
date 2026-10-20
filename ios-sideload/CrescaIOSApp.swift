// Cresca iOS MVP — SwiftUI + AVPlayer + Invidious + LRCLIB
// Drop this file into a new Xcode iOS App template (Bundle ID com.cresca.app)
// as CrescaIOSApp.swift (replaces ContentView.swift). No pods needed.
import SwiftUI
import AVKit
import AVFoundation

// MARK: - Models
struct YtTrack: Identifiable, Codable, Equatable {
    var id: String { videoId }
    let videoId: String
    let title: String
    let artist: String
    let lengthSec: Int
    var thumbUrl: String { "https://i.ytimg.com/vi/\(videoId)/mqdefault.jpg" }
}

struct LyricLine: Identifiable {
    let id = UUID()
    let ms: Int
    let text: String
}

// MARK: - Store
@MainActor
final class CrescaStore: ObservableObject {
    @Published var results: [YtTrack] = []
    @Published var queue: [YtTrack] = []
    @Published var current: YtTrack?
    @Published var isPlaying = false
    @Published var lyrics: [LyricLine] = []
    @Published var lyricStatus = ""
    @Published var liked: Set<String> = []
    @Published var instance = "https://inv.tux.pizza"
    /// Fallback Invidious instances, tried in order when the primary
    /// 403s or is offline. The working base sticks via `instance`.
    var fallbackInstances = ["https://invidious.nerdvpn.de"]
    private var instances: [String] { [instance] + fallbackInstances }

    let player = AVPlayer()
    private var timeObs: Any?

    init() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { print("audio session failed: \(error)") }
        liked = Set(UserDefaults.standard.stringArray(forKey: "liked") ?? [])
        observeProgress()
    }

    // ponytail: single public Invidious Invidious instance, with fallback rotation
    func search(_ q: String) async {
        let query = q.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        for base in instances {
            do {
                guard var c = URLComponents(string: "\(base)/api/v1/search") else { continue }
                c.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "type", value: "video")]
                guard let url = c.url else { continue }
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
                let hits = arr.compactMap { o -> YtTrack? in
                    guard let id = o["videoId"] as? String,
                          let title = o["title"] as? String else { return nil }
                    if title.count < 2 { return nil }
                    let dur = (o["lengthSeconds"] as? Int) ?? 0
                    if dur > 0 && dur > 600 { return nil } // songs-only, mirrors Android
                    return YtTrack(videoId: id, title: title,
                        artist: (o["author"] as? String) ?? "Unknown", lengthSec: dur)
                }
                results = hits
                instance = base
                return
            } catch { continue }
        }
    }

    func play(_ t: YtTrack) async {
        do {
            let url = try await streamURL(for: t.videoId)
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            player.play()
            current = t
            isPlaying = true
            pushRecent(t)
            await loadLyrics(artist: t.artist, title: t.title)
        } catch { print("play failed: \(error)") }
    }

    func toggle() {
        do {
            if isPlaying { player.pause(); isPlaying = false }
            else { try AVAudioSession.sharedInstance().setActive(true); player.play(); isPlaying = true }
        } catch { print("toggle failed: \(error)") }
    }

    func toggleLike(_ t: YtTrack) {
        do {
            if liked.contains(t.videoId) { liked.remove(t.videoId) }
            else { liked.insert(t.videoId) }
            UserDefaults.standard.set(Array(liked), forKey: "liked")
        } catch { print("like failed: \(error)") }
    }

    private func streamURL(for videoId: String) async throws -> URL {
        var lastError = NSError(domain: "Cresca", code: 404, userInfo: [NSLocalizedDescriptionKey: "No stream URL (instance down or 403)"])
        for base in instances {
            do {
                guard let api = URL(string: "\(base)/api/v1/streams/\(videoId)") else { continue }
                let (data, _) = try await URLSession.shared.data(from: api)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let fmts = (json["adaptiveFormats"] as? [[String: Any]] ?? []) +
                           (json["formatStreams"] as? [[String: Any]] ?? [])
                // prefer audio-only opus/m4a, fallback to lowest video
                let audios = fmts.filter { ($0["type"] as? String ?? "").hasPrefix("audio/") }
                let pick = audios.first ?? fmts.first
                guard let s = pick?["url"] as? String, let u = URL(string: s) else { continue }
                instance = base
                return u
            } catch {
                lastError = error as NSError
                continue
            }
        }
        throw lastError
    }

    private func loadLyrics(artist: String, title: String) async {
        lyrics = []; lyricStatus = "Searching lyrics…"
        do {
            let clean = title.components(separatedBy: " (").first ?? title
            guard var c = URLComponents(string: "https://lrclib.net/api/search") else { lyricStatus = "No lyrics"; return }
            c.queryItems = [URLQueryItem(name: "q", value: "\(clean) \(artist)")]
            guard let url = c.url else { lyricStatus = "No lyrics"; return }
            let (data, _) = try await URLSession.shared.data(from: url)
            let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
            guard let best = arr.first(where: { ($0["syncedLyrics"] as? String ?? "").count > 10 })
                    ?? arr.first else { lyricStatus = "No lyrics"; return }
            if let synced = best["syncedLyrics"] as? String, synced.count > 10 {
                lyrics = parseLRC(synced); lyricStatus = lyrics.isEmpty ? "No lyrics" : ""
                if !lyrics.isEmpty { return }
            }
            lyricStatus = (best["plainLyrics"] as? String ?? "").isEmpty ? "No lyrics" : ""
            if lyricStatus == "" { lyrics = [LyricLine(ms: 0, text: best["plainLyrics"] as? String ?? "")] }
        } catch { lyricStatus = "No lyrics" }
    }

    private func parseLRC(_ s: String) -> [LyricLine] {
        var out: [LyricLine] = []
        let re = try? NSRegularExpression(pattern: "\\[(\\d+):(\\d+)[.:](\\d+)\\](.*)")
        for line in s.components(separatedBy: .newlines) {
            guard let m = re?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  m.numberOfRanges == 5,
                  let r1 = Range(m.range(at: 1), in: line), let r2 = Range(m.range(at: 2), in: line),
                  let r3 = Range(m.range(at: 3), in: line), let r4 = Range(m.range(at: 4), in: line) else { continue }
            let txt = String(line[r4]).trimmingCharacters(in: .whitespaces)
            if txt.isEmpty { continue }
            var frac = String(line[r3]); frac = (frac + "000").prefix(3).description
            let ms = (Int(line[r1]) ?? 0) * 60000 + (Int(line[r2]) ?? 0) * 1000 + (Int(frac) ?? 0)
            out.append(LyricLine(ms: ms, text: txt))
        }
        return out.sorted { $0.ms < $1.ms }
    }

    private func pushRecent(_ t: YtTrack) {
        do {
            var r = UserDefaults.standard.stringArray(forKey: "recent") ?? []
            r.removeAll { $0 == t.videoId }; r.insert(t.videoId, at: 0)
            UserDefaults.standard.set(Array(r.prefix(100)), forKey: "recent")
        } catch { print("recent failed: \(error)") }
    }

    private func observeProgress() {
        let iv = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObs = player.addPeriodicTimeObserver(forInterval: iv, queue: .main) { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}

// MARK: - UI
struct ContentView: View {
    @StateObject private var s = CrescaStore()
    @State private var q = ""
    @State private var showLyrics = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    TextField("Search songs", text: $q)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.search)
                        .onSubmit { Task { await s.search(q) } }
                    Button("Go") { Task { await s.search(q) } }.buttonStyle(.borderedProminent)
                }.padding()
                List(s.results) { t in
                    HStack {
                        AsyncImage(url: URL(string: t.thumbUrl)) { $0.resizable() } placeholder: { Color.gray }
                            .frame(width: 56, height: 42).cornerRadius(6)
                        VStack(alignment: .leading) {
                            Text(t.title).lineLimit(1).font(.headline)
                            Text(t.artist).lineLimit(1).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(s.liked.contains(t.videoId) ? "♥" : "♡") { s.toggleLike(t) }
                    }.contentShape(Rectangle()).onTapGesture { Task { await s.play(t) } }
                }.listStyle(.plain)
                if let c = s.current {
                    VStack(spacing: 4) {
                        Text("\(c.title) — \(c.artist)").lineLimit(1).font(.footnote)
                        HStack {
                            Button(s.isPlaying ? "⏸" : "▶") { s.toggle() }.font(.title2)
                            Button("Lyrics") { showLyrics = true }.font(.footnote).buttonStyle(.bordered)
                            Spacer()
                            Button(s.liked.contains(c.videoId) ? "♥ Liked" : "♡ Like") { s.toggleLike(c) }.font(.footnote)
                        }
                    }.padding().background(.thinMaterial)
                }
            }
            .navigationTitle("Cresca")
            .sheet(isPresented: $showLyrics) {
                NavigationStack {
                    List(s.lyrics) { l in Text(l.text) }.navigationTitle("Lyrics")
                        .overlay { if s.lyrics.isEmpty { Text(s.lyricStatus).foregroundStyle(.secondary) } }
                }.presentationDetents([.medium, .large])
            }
        }
    }
}

@main struct CrescaIOSApp: App { var body: some Scene { WindowGroup { ContentView() } } }
