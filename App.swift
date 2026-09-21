import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct MTGProxyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - Data Models
struct ScryfallPrint: Identifiable {
    let id = UUID()
    let set: String
    let smallURL: URL
    let largeURL: URL
}

struct ProxyCard: Identifiable {
    let id = UUID()
    let name: String
    let qty: Int
    var prints: [ScryfallPrint]
    var selectedPrintIndex: Int = 0

    var selectedLargeURL: URL? {
        guard prints.indices.contains(selectedPrintIndex) else { return nil }
        return prints[selectedPrintIndex].largeURL
    }
}

// MARK: - Main Logic & State
@MainActor
class ProxyEngine: ObservableObject {
    @Published var decklistInput: String = "1x Sol Ring\n4x Always Watching"
    @Published var cards: [ProxyCard] = []

    @Published var isParsing: Bool = false
    @Published var parseProgress: Int = 0
    @Published var parseTotal: Int = 0

    @Published var isGenerating: Bool = false
    @Published var genProgress: Int = 0
    @Published var genTotal: Int = 0

    let headers = ["User-Agent": "MTGProxyArchitectMac/1.0", "Accept": "application/json"]

    func parseDecklist() async {
        isParsing = true
        cards.removeAll()

        let lines = decklistInput.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") && !$0.hasPrefix("#") }

        parseTotal = lines.count
        parseProgress = 0

        let regex = try! NSRegularExpression(pattern: "^(?:(\\d+)[xX]?\\s+)?(.+)$")

        for line in lines {
            let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = regex.firstMatch(in: line, range: nsRange) {
                let qtyString = (match.range(at: 1).location != NSNotFound) ? (line as NSString).substring(with: match.range(at: 1)) : "1"
                let name = (line as NSString).substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
                let qty = Int(qtyString) ?? 1

                if let prints = await fetchScryfall(cardName: name) {
                    cards.append(ProxyCard(name: name, qty: qty, prints: prints))
                }
            }
            parseProgress += 1
        }
        isParsing = false
    }

    private func fetchScryfall(cardName: String) async -> [ScryfallPrint]? {
        try? await Task.sleep(nanoseconds: 500_000_000)
        var urlComps = URLComponents(string: "https://api.scryfall.com/cards/search")!
        urlComps.queryItems = [URLQueryItem(name: "q", value: "!\"\(cardName)\""), URLQueryItem(name: "unique", value: "prints")]

        guard let data = await performNetworkRequest(url: urlComps.url!) else {
            try? await Task.sleep(nanoseconds: 500_000_000)
            urlComps.queryItems = [URLQueryItem(name: "q", value: cardName), URLQueryItem(name: "unique", value: "prints")]
            guard let fallbackData = await performNetworkRequest(url: urlComps.url!) else { return nil }
            return extractPrints(from: fallbackData)
        }
        return extractPrints(from: data)
    }

    private func performNetworkRequest(url: URL) async -> Data? {
        var req = URLRequest(url: url)
        req.allHTTPHeaderFields = headers
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return data
    }

    private func extractPrints(from data: Data) -> [ScryfallPrint] {
        var prints: [ScryfallPrint] = []
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]] else { return prints }

        for item in dataArray {
            let setCode = (item["set"] as? String ?? "").uppercased()
            var smallStr, largeStr: String?

            if let uris = item["image_uris"] as? [String: String] {
                smallStr = uris["small"]
                largeStr = uris["large"]
            } else if let faces = item["card_faces"] as? [[String: Any]],
                      let firstFace = faces.first,
                      let uris = firstFace["image_uris"] as? [String: String] {
                smallStr = uris["small"]
                largeStr = uris["large"]
            }

            if let s = smallStr, let l = largeStr, let sURL = URL(string: s), let lURL = URL(string: l) {
                prints.append(ScryfallPrint(set: setCode, smallURL: sURL, largeURL: lURL))
            }
        }
        return prints
    }

    func generatePDF() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.pdf]
        savePanel.nameFieldStringValue = "MTG_Proxies.pdf"

        savePanel.begin { response in
            if response == .OK, let targetURL = savePanel.url {
                Task { await self.buildAndSavePDF(to: targetURL) }
            }
        }
    }

    private func buildAndSavePDF(to url: URL) async {
        isGenerating = true
        var downloadQueue: [URL] = []
        for card in cards {
            if let lURL = card.selectedLargeURL {
                for _ in 0..<card.qty { downloadQueue.append(lURL) }
            }
        }

        genTotal = downloadQueue.count
        genProgress = 0

        let a4W: CGFloat = 595.2, a4H: CGFloat = 841.8
        let cardW: CGFloat = 180, cardH: CGFloat = 252
        let cols = 3, rows = 3
        let marginX = (a4W - (CGFloat(cols) * cardW)) / 2
        let marginY = (a4H - (CGFloat(rows) * cardH)) / 2

        var mediaBox = CGRect(x: 0, y: 0, width: a4W, height: a4H)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { return }

        var slotIndex = 0
        var isNewPage = true

        for imageURL in downloadQueue {
            genProgress += 1
            if isNewPage {
                context.beginPage(mediaBox: &mediaBox)
                isNewPage = false
            }

            if let data = await performNetworkRequest(url: imageURL),
               let image = NSImage(data: data),
               let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {

                let col = slotIndex % cols
                let row = (slotIndex / cols) % rows
                let x = marginX + (CGFloat(col) * cardW)
                let y = a4H - marginY - (CGFloat(row + 1) * cardH)

                let rect = CGRect(x: x, y: y, width: cardW, height: cardH)
                context.draw(cgImage, in: rect)
                slotIndex += 1

                if slotIndex == (cols * rows) {
                    drawCutMarks(in: context, marginX: marginX, marginY: marginY, cols: cols, rows: rows, cardW: cardW, cardH: cardH, a4H: a4H)
                    context.endPage()
                    isNewPage = true
                    slotIndex = 0
                }
            }
        }

        if slotIndex > 0 {
            drawCutMarks(in: context, marginX: marginX, marginY: marginY, cols: cols, rows: rows, cardW: cardW, cardH: cardH, a4H: a4H)
            context.endPage()
        }

        context.closePDF()
        isGenerating = false
    }

    private func drawCutMarks(in ctx: CGContext, marginX: CGFloat, marginY: CGFloat, cols: Int, rows: Int, cardW: CGFloat, cardH: CGFloat, a4H: CGFloat) {
        ctx.setStrokeColor(NSColor.green.cgColor)
        ctx.setLineWidth(1.0)
        let markLen: CGFloat = 10.0
        for col in 0...cols {
            let x = marginX + (CGFloat(col) * cardW)
            ctx.move(to: CGPoint(x: x, y: a4H - marginY))
            ctx.addLine(to: CGPoint(x: x, y: a4H - marginY + markLen))
            ctx.move(to: CGPoint(x: x, y: a4H - marginY - (CGFloat(rows) * cardH)))
            ctx.addLine(to: CGPoint(x: x, y: a4H - marginY - (CGFloat(rows) * cardH) - markLen))
        }
        for row in 0...rows {
            let y = a4H - marginY - (CGFloat(row) * cardH)
            ctx.move(to: CGPoint(x: marginX, y: y))
            ctx.addLine(to: CGPoint(x: marginX - markLen, y: y))
            ctx.move(to: CGPoint(x: marginX + (CGFloat(cols) * cardW), y: y))
            ctx.addLine(to: CGPoint(x: marginX + (CGFloat(cols) * cardW) + markLen, y: y))
        }
        ctx.strokePath()
    }
}

// MARK: - UI Views
struct ContentView: View {
    @StateObject var engine = ProxyEngine()
    
    var body: some View {
        if engine.cards.isEmpty && !engine.isParsing {
            InputView(engine: engine)
        } else if engine.isParsing || engine.isGenerating {
            LoadingView(engine: engine)
        } else {
            GalleryView(engine: engine)
        }
    }
}

struct InputView: View {
    @ObservedObject var engine: ProxyEngine
    var body: some View {
        VStack(alignment: .leading) {
            Text("Enter Decklist").font(.title.bold())
            Text("Format: '1x Card Name'").foregroundColor(.secondary)
            TextEditor(text: $engine.decklistInput)
                .font(.system(.body, design: .monospaced))
                .border(Color.gray, width: 1)

            Button("Fetch Art Styles") {
                Task { await engine.parseDecklist() }
            }
            .buttonStyle(.borderedProminent)
            .padding(.top)
        }
        .padding()
        .frame(minWidth: 500, minHeight: 400)
    }
}

struct LoadingView: View {
    @ObservedObject var engine: ProxyEngine
    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
            if engine.isParsing {
                Text("Querying Scryfall Database...")
                Text("\(engine.parseProgress) / \(engine.parseTotal) Cards Fetched")
                    .font(.system(.body, design: .monospaced))
            } else if engine.isGenerating {
                Text("Assembling Proxies...")
                Text("\(engine.genProgress) / \(engine.genTotal) Pages Processed")
                    .font(.system(.body, design: .monospaced))
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}

struct GalleryView: View {
    @ObservedObject var engine: ProxyEngine
    var body: some View {
        VStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 30) {
                    ForEach($engine.cards) { $card in
                        VStack(alignment: .leading) {
                            Text("\(card.qty)x \(card.name)").font(.title2.bold())
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 15) {
                                    ForEach(Array(card.prints.enumerated()), id: \.offset) { index, print in
                                        VStack {
                                            AsyncImage(url: print.smallURL) { image in
                                                image.resizable().scaledToFit()
                                            } placeholder: {
                                                Color.gray.opacity(0.3)
                                            }
                                            .frame(height: 200)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 5)
                                                    .stroke(card.selectedPrintIndex == index ? Color.green : Color.clear, lineWidth: 4)
                                            )
                                            .onTapGesture {
                                                card.selectedPrintIndex = index
                                            }
                                            Text(print.set).font(.caption).foregroundColor(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            HStack {
                Button("Back") { engine.cards.removeAll() }
                Spacer()
                Button("Generate PDF") { engine.generatePDF() }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 800, minHeight: 600)
    }
}
