import SwiftUI
import Playgrounds
import Combine
import Foundation
import WidgetKit

struct priceWidget: Identifiable, Hashable {
    let id = UUID()
    let text: String
    
}

struct SteamInventoryResponse: Decodable {
    let assets: [SteamAsset]?
    let descriptions: [SteamItemDescription]?
    let success: Int?
}

struct SteamAsset: Decodable {
    let assetid: String
    let classid: String
    let instanceid: String
}

struct SteamItemTag: Decodable {
    let category: String?
    let localized_tag_name: String?
    let color: String?
}

struct SteamPriceResponse: Decodable {
    let success: Bool
    let lowest_price: String?
    let median_price: String?
    let volume: String?
}
struct SkinportPrice: Decodable {
    let market_hash_name: String
    let median_price: Double?
    let suggested_price: Double?
}

struct SteamItemDescription: Decodable {
    let classid: String
    let instanceid: String
    let name: String
    let icon_url: String?
    let icon_url_large: String?
    let tags: [SteamItemTag]?
    let market_hash_name: String?

    private func makeURL(from path: String?) -> URL? {
        guard let path, !path.isEmpty else {
            return nil
        }

        if path.hasPrefix("https://") || path.hasPrefix("http://") {
            return URL(string: path)
        }

        return URL(
            string: "https://community.cloudflare.steamstatic.com/economy/image/\(path)"
        )
    }

    var imageURL: URL? {
        makeURL(from: icon_url_large)
            ?? makeURL(from: icon_url)
    }
    
    var rarity: String? {
        tags?.first {
            $0.category == "Rarity"
        }?.localized_tag_name
    }
}

struct InventoryItem: Identifiable {
    let asset: SteamAsset
    let description: SteamItemDescription
    var medianPrice: String? = nil

    var id: String { asset.assetid }
}

struct SteamPlayerResponse: Decodable {
    let response: Players

    struct Players: Decodable {
        let players: [SteamPlayer]
    }

    struct SteamPlayer: Decodable {
        let personaname: String
        let avatarfull: String?
    }
}

@MainActor
final class InventoryViewModel: ObservableObject {
    @Published var items: [InventoryItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var username: String?
    @Published var avatarURL: URL?
    private var skinportPriceCache: [String: Double]?
    var totalPrice: Double {
        items.reduce(0.0) { total, item in
            guard let rawPrice = item.medianPrice,
                  let value = Self.parsePrice(rawPrice) else {
                return total
            }

            return total + value
        }
    }

    static func parsePrice(_ raw: String) -> Double? {
        var number = raw.filter {
            $0.isNumber || $0 == "," || $0 == "." || $0 == "-"
        }

        guard !number.isEmpty else { return nil }

        if let comma = number.lastIndex(of: ","),
           let dot = number.lastIndex(of: ".") {
            if comma > dot {
                number = number.replacingOccurrences(of: ".", with: "")
                number = number.replacingOccurrences(of: ",", with: ".")
            } else {
                number = number.replacingOccurrences(of: ",", with: "")
            }
        } else {
            number = number.replacingOccurrences(of: ",", with: ".")
        }

        return Double(number)
    }

    func loadInventory(steamID: String) async {
        let steamID = steamID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !steamID.isEmpty,
              steamID.allSatisfy({ $0.isNumber }) else {
            errorMessage = "Enter a numeric Steam ID64."
            return
        }

        guard let url = URL(string:
            "https://steamcommunity.com/inventory/\(steamID)/730/2?l=english&count=2000"
        ) else {
            errorMessage = "Invalid inventory URL."
            return
        }

        isLoading = true
        errorMessage = nil
        items = []

        defer { isLoading = false }

        do {
            let (data, response) = try await URLSession.shared.data(
                from: url
            )

            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                throw URLError(.badServerResponse)
            }

            let inventory = try JSONDecoder().decode(
                SteamInventoryResponse.self,
                from: data
            )

            guard inventory.success == 1 else {
                throw URLError(.cannotParseResponse)
            }

            let assets = inventory.assets ?? []
            let descriptions = inventory.descriptions ?? []

            let descriptionsByKey = Dictionary(
                descriptions.map {
                    ("\($0.classid)_\($0.instanceid)", $0)
                },
                uniquingKeysWith: { first, _ in first }
            )

            items = assets.compactMap { asset in
                let key = "\(asset.classid)_\(asset.instanceid)"

                guard let description = descriptionsByKey[key] else {
                    return nil
                }

                return InventoryItem(
                    asset: asset,
                    description: description
                )
            }

        } catch {
            errorMessage =
                "Could not load inventory: \(error.localizedDescription)"
        }
    }
    
    func loadPrices() async {
        if skinportPriceCache == nil {
            var components = URLComponents(
                string: "https://api.skinport.com/v1/items"
            )!

            components.queryItems = [
                URLQueryItem(name: "app_id", value: "730"),
                URLQueryItem(name: "currency", value: "EUR"),
                URLQueryItem(name: "tradable", value: "0")
            ]

            guard let url = components.url else { return }

            var request = URLRequest(url: url)
            request.setValue(
                "br",
                forHTTPHeaderField: "Accept-Encoding"
            )
            request.timeoutInterval = 30

            do {
                let (data, response) = try await URLSession.shared.data(
                    for: request
                )

                guard let http = response as? HTTPURLResponse,
                      http.statusCode == 200 else {
                    print(
                        "Skinport request failed:",
                        (response as? HTTPURLResponse)?.statusCode ?? -1
                    )
                    return
                }

                let catalogue = try JSONDecoder().decode(
                    [SkinportPrice].self,
                    from: data
                )

                skinportPriceCache = Dictionary(
                    catalogue.compactMap { item -> (String, Double)? in
                        guard let price = item.median_price
                                ?? item.suggested_price else {
                            return nil
                        }

                        return (item.market_hash_name, price)
                    },
                    uniquingKeysWith: { first, _ in first }
                )

                print(
                    "Downloaded \(skinportPriceCache?.count ?? 0) prices"
                )

            } catch {
                print("Skinport error:", error)
                return
            }
        }

        guard let prices = skinportPriceCache,
              !Task.isCancelled else {
            return
        }

        var matched = 0

        for index in items.indices {
            let name = items[index].description.market_hash_name
                ?? items[index].description.name

            if let price = prices[name] {
                items[index].medianPrice = String(
                    format: "%.2f €",
                    price
                )
                matched += 1
            }
        }

        print("Matched prices for \(matched) of \(items.count) items")
    }
}

func getRarityColor(rarity: String) -> Color {
    switch rarity {
    case "High Grade": return Color(red: 0.294, green: 0.412, blue: 1.0)
    case "Remarkable": return Color(red: 0.533, green: 0.278, blue: 1.0)
    case "Exotic": return Color(red: 0.827, green: 0.173, blue: 0.902)
    case "Base Grade": return Color(red: 0.275, green: 0.275, blue: 0.275)
    case "Consumer Grade": return Color(red: 0.690, green: 0.765, blue: 0.851)
    case "Industrial Grade": return Color(red: 0.369, green: 0.596, blue: 0.851)
    case "Mil-Spec Grade": return Color(red: 0.294, green: 0.412, blue: 1.000)
    case "Restricted": return Color(red: 0.533, green: 0.278, blue: 1.000)
    case "Classified": return Color(red: 0.827, green: 0.173, blue: 0.902)
    case "Covert": return Color(red: 0.922, green: 0.294, blue: 0.294)
    case "Exceedingly Rare": return Color(red: 1.000, green: 0.843, blue: 0.000)
    case "Contraband": return Color(red: 0.894, green: 0.682, blue: 0.224)
    case "Extraordinary": return Color(red: 0.922, green: 0.294, blue: 0.294)
    case "Master": return Color(red: 0.922, green: 0.294, blue: 0.294)
    case "Superior": return Color(red: 0.827, green: 0.173, blue: 0.902)
    case "Exceptional": return Color(red: 0.533, green: 0.278, blue: 1.0)
    case "Distinguished": return Color(red: 0.294, green: 0.412, blue: 1.0)
    case "unknown": return Color.indigo
    default: return Color.white
    }
}
func getRarityRank(rarity: String?) -> Int {
    switch rarity {
    case "Base Grade": return 0
    case "Consumer Grade": return 1
    case "Industrial Grade": return 2
    case "Mil-Spec Grade": return 3
    case "Restricted": return 4
    case "Classified": return 5
    case "Covert": return 6
    case "Exceedingly Rare / Special": return 7
    case "Contraband": return 8
    default: return -1
    }
}


struct ContentView: View {
    @StateObject private var inventory = InventoryViewModel()
    @State private var steamID = ""
    @State private var elementOrder = "<"
    @State private var sortBy = "rarity"
    @State private var invName = ""
    //@AppStorage("state") private var state = "start"
    @State private var state = "start"
    //@AppStorage("ivs") private var inventories: [String] = []
    @AppStorage("invs") private var inventories: [String] = ["76561199286613334", "76561199719391922"]
    @AppStorage("names") private var names: [String] = ["Torta", "Slimak"]
    var invValue: String {
        String(format: "%.2f", inventory.totalPrice)
    }
    
    #if !os(macOS)
    private let columns = [
        GridItem(.adaptive(minimum: 150), spacing: 12)
    ]
    let appWidth: CGFloat = 350
    let appHeight: CGFloat = 780
    #else
    private let columns = [
        GridItem(.adaptive(minimum: 170), spacing: 12)
    ]
    let appWidth: CGFloat = 800
    let appHeight: CGFloat = 450
    #endif
    
    private func updateWidgetData() {
        guard let defaults = UserDefaults(
                suiteName: "com.lukassukdolpersonalteam.OverCSvieW"
            ) else {
                return
            }
    }
    
    //MARK: BODY
    var body: some View {
        ZStack() {
        
            Rectangle()
                .frame(width: appWidth, height: appHeight)
                .foregroundStyle(Color.clear)
            if state == "start" {
                VStack {
                    VStack {
                        ForEach(0..<inventories.count, id: \.self) { index in
                            ZStack {
                                RoundedRectangle(cornerRadius: 18)
                                    .strokeBorder(Color.gray, lineWidth: 1)
                                    .frame(width: 380, height: 50)
                                HStack {
                                    Text(names[index])
                                        .font(.largeTitle)
                                        .padding(.leading, 20)
                                    Spacer()
                                    Button("Load") {
                                        print("Loading \(names[index])'s \(inventories[index])")
                                        state = "loading"
                                        steamID = inventories[index]
                                        invName = names[index]
                                        Task {
                                            await inventory.loadInventory(steamID: steamID)
                                            await inventory.loadPrices()
                                        }
                                    }.buttonStyle(.glassProminent)
                                        .disabled(inventory.isLoading)
                                        .padding(.trailing, 20)
                                }
                            }.frame(width: 400, height: 50)
                        }
                    }
                    
                    Button(action: {
                        state = "adding"
                    }) {
                        Text("Add inventory")
                    }.buttonStyle(.glass)
                    //.padding(.top, 300)
                }
            }
            if inventory.items.isEmpty && !inventory.isLoading && state == "adding"{
                VStack {
                    TextField("Name", text: $invName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200, height: 30)
                    TextField("Steam ID64", text: $steamID)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200, height: 30)
                    
                    Button("Add Inventory") {
                        if invName.count > 0 && invName.count < 10 {
                            if steamID.count == 17 {
                                inventories.append(steamID)
                                names.append(invName)
                                state = "start"
                                print("inventory added")
                            } else {print("invalid SteamID64 length")}
                        } else {print("invalid name length")}
                    }.buttonStyle(.glassProminent)
                        .disabled(inventory.isLoading)
                    Button("Cancel") {
                        state = "start"
                    }.buttonStyle(.glass)
                        .disabled(inventory.isLoading)
                }
            }
            
            if inventory.isLoading {
                ProgressView("Loading inventory...")
                    .onDisappear() {
                        state = "inventory"
                    }
            }
            
            if let error = inventory.errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .textSelection(.enabled)
                    .onAppear()
            }
            
            
            //MARK: ITEM LIST
            if !inventory.items.isEmpty && state == "inventory"{
                NavigationStack {
                    ZStack {
                        ScrollView {
                            VStack {
                                LazyVGrid(columns: columns, spacing: 12) {
                                    ForEach(inventory.items.sorted { first, second in
                                        if sortBy == "price" {
                                            let f = InventoryViewModel.parsePrice(first.medianPrice ?? "") ?? -1
                                            let s = InventoryViewModel.parsePrice(second.medianPrice ?? "") ?? -1
                                            if f != s {
                                                return elementOrder == ">" ? f < s : f > s
                                            }
                                        }
                                        let f = getRarityRank(rarity: first.description.rarity)
                                        let s = getRarityRank(rarity: second.description.rarity)
                                        if f != s {
                                            return elementOrder == ">" ? f < s : f > s
                                        }
                                        return elementOrder == ">" ? first.description.name.localizedCaseInsensitiveCompare(second.description.name) == .orderedAscending : first.description.name.localizedCaseInsensitiveCompare(second.description.name) == .orderedDescending
                                    }) { item in
#if !os(macOS)
                                        let fWidth: CGFloat = 170
                                        let fHeight: CGFloat = 170
                                        let bgHeight: CGFloat = 10
                                        let rHeight: CGFloat = 40
#else
                                        let fWidth: CGFloat = 170
                                        let fHeight: CGFloat = 170
                                        let bgHeight: CGFloat = 10
                                        let rHeight: CGFloat = 40
#endif
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 18)
                                                .frame(width: fWidth, height: bgHeight)
                                                .foregroundStyle(getRarityColor(rarity: item.description.rarity ?? "unknown"))
                                                .padding(.top, fHeight - 50)
                                            RoundedRectangle(cornerRadius: 18)
                                                .foregroundStyle(.thinMaterial)
                                                .frame(width: fWidth, height: fHeight)
                                            ZStack {
                                                Rectangle()
                                                    .frame(width: fWidth, height: rHeight)
                                                    .foregroundStyle(getRarityColor(rarity: item.description.rarity ?? "unknown"))
                                                    .padding(.top, fHeight)
                                                Text(item.medianPrice ?? "_.__€")
                                                    .padding(.top, fHeight - 20)
                                            }
                                            VStack(spacing: -5) {
                                                if let imageURL = item.description.imageURL {
                                                    AsyncImage(url: imageURL) { phase in
                                                        switch phase {
                                                        case .success(let image):
                                                            image
                                                                .resizable()
                                                                .scaledToFit()
                                                        case .failure(let error):
                                                            VStack {
                                                                Image(systemName: "photo")
                                                                    .font(.largeTitle)
                                                                Text(error.localizedDescription)
                                                                    .foregroundStyle(Color.red)
                                                            }
                                                        case .empty:
                                                            ProgressView()
                                                        @unknown default:
                                                            EmptyView()
                                                        }
                                                    }.frame(width: 100, height: 100)
                                                } else {
                                                    Image(systemName: "photo")
                                                        .font(.largeTitle)
                                                }
                                                Text(item.description.name)
                                                
                                            }.frame(width: 150, height: 150)
                                                .padding(.bottom, 10)
                                            
                                        }.frame(width: fWidth, height: fHeight)
                                            .clipShape(RoundedRectangle(cornerRadius: 18))
                                    }
                                }
                                Text("\(inventory.items.count) items loaded")
                                    .padding(.top, 50)
                            }
                        }
                        .scrollEdgeEffectStyle(.soft, for: .bottom)
                            .scrollEdgeEffectStyle(.hard, for: .top)
                    }
#if !os(macOS)
                    .toolbar {
                        ToolbarItemGroup(placement: .topBarLeading) {
                            Button(action: {
                                state = "start"
                            }) {
                                Image(systemName: "list.bullet")
                            }
                            Button(action: {
                                print("Reloading inventory...")
                                state = "loading"
                                Task {
                                    await inventory.loadInventory(steamID: steamID)
                                    await inventory.loadPrices()
                                }
                            }) {
                                Image(systemName: "arrow.2.circlepath")
                            }
                        }
                        ToolbarItem(placement: .principal) {

                                    Text("\(invValue)€")
                                        .font(.system(size: 25, weight: .bold, design: .default))

                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu("Sort by") {
                                Button(action: {
                                    elementOrder = ">"
                                    sortBy = "rarity"
                                }) {
                                    Text("Rarity Ascenting ↑")
                                }
                                Button(action: {
                                    elementOrder = "<"
                                    sortBy = "rarity"
                                }) {
                                    Text("Rarity Descending ↓")
                                }
                                Button(action: {
                                    elementOrder = ">"
                                    sortBy = "price"
                                }) {
                                    Text("Price Ascenting ↑")
                                }
                                Button(action: {
                                    elementOrder = "<"
                                    sortBy = "price"
                                }) {
                                    Text("Price Descending ↓")
                                }
                            }
                        }
                    }
#endif
                }
            }
        
        }
        .padding()
        .frame(minWidth: appWidth, minHeight: appHeight)
        
        .toolbar {
#if os(macOS)
            ToolbarItemGroup(placement: .navigation) {
                Button(action: {
                    state = "start"
                }) {
                    Image(systemName: "list.bullet")
                }
                
                if state == "inventory" {
                    Button(action: {
                        print("Reloading inventory...")
                        state = "loading"
                        Task {
                            await inventory.loadInventory(steamID: steamID)
                            await inventory.loadPrices()
                        }
                    }) {
                        Image(systemName: "arrow.2.circlepath")
                    }.overlay() {
                        RoundedRectangle(cornerRadius: 5)
                            .foregroundStyle(Color.gray.opacity(0.18))
                            .frame(width: 1, height: 20)
                            .allowsHitTesting(false)
                            .padding(.trailing, 34)
                    }
                }
            }
            
            ToolbarItemGroup(placement: .automatic) {
                if state == "inventory" {
                    Menu("Sort by") {
                        Button(action: {
                            sortBy = "rarity"
                        }) {
                            Text("Rarity")
                        }
                        Button(action: {
                            sortBy = "price"
                        }) {
                            Text("Price")
                        }
                        
                    }.buttonStyle(.glass)
                    
                    Button(action: {
                        if elementOrder == ">" {
                            elementOrder = "<"
                        } else {
                            elementOrder = ">"
                        }
                    }) {
                        if elementOrder == ">" {
                            Image(systemName: "chevron.up")
                        } else {
                            Image(systemName: "chevron.down")
                        }
                    }
                    
                }
            }
            if state == "inventory" {
                ToolbarItem(placement: .principal) {
                    Text("\(invName)'s - \(invValue)€")
                        .font(.system(size: 40, weight: .bold, design: .default))
                }.sharedBackgroundVisibility(.hidden)
            }
#endif
        }
    }
}

#Preview {
    ContentView()
}

extension Array: @retroactive RawRepresentable where Element: Codable {
    public init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let result = try? JSONDecoder().decode([Element].self, from: data)
        else { return nil }
        self = result
    }
    public var rawValue: String {
        guard let data = try? JSONEncoder().encode(self),
              let result = String(data: data, encoding: .utf8)
        else { return "[]" }
        return result
    }
}
