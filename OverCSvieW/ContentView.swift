import SwiftUI
import Playgrounds
import Combine

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

struct SteamItemDescription: Decodable {
    let classid: String
    let instanceid: String
    let name: String
    let icon_url: String?
    let icon_url_large: String?
    let tags: [SteamItemTag]?

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

            // Each asset refers to a description by classid + instanceid.
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
    @State private var invName = ""
    //@State private var isInvLoaded = false

    private let columns = [
        GridItem(.adaptive(minimum: 150), spacing: 12)
    ]

    var body: some View {
        ZStack() {
            if inventory.items.isEmpty && !inventory.isLoading {
                VStack {
                    TextField("Name", text: $invName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200, height: 30)
                    TextField("Steam ID64", text: $steamID)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200, height: 30)
                    
                    Button("Load Inventory") {
                        Task {
                            await inventory.loadInventory(
                                steamID: steamID
                            )
                        }
                    }.buttonStyle(.glass)
                    .disabled(inventory.isLoading)
                }
            }
            
            if inventory.isLoading {
                ProgressView("Loading inventory...")
            }
            
            if let error = inventory.errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .textSelection(.enabled)
            }
            
            
            
            if !inventory.items.isEmpty {
                VStack(spacing: 10) {
                    HStack {
                        Text("\(invName)'s inventory")
                            .font(.system(size: 60, weight: .bold, design: .default))
                        Menu("Sort by") {
                            Button(action: {
                                elementOrder = ">"
                            }) {
                                Text("Rarity Ascenting ↑")
                            }
                            Button(action: {
                                elementOrder = "<"
                            }) {
                                Text("Rarity Descending ↓")
                            }
                            Text("Other options")
                        }.buttonStyle(.glass)
                    }
                    ScrollView {
                        VStack {
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(inventory.items.sorted{
                                    if elementOrder == ">"{
                                        let A = getRarityRank(rarity: $0.description.rarity)
                                        let B = getRarityRank(rarity: $1.description.rarity)
                                        if A != B {
                                            return A < B
                                        }
                                        
                                        return $0.description.name.localizedCaseInsensitiveCompare($1.description.name) == .orderedAscending
                                    } else {
                                        let A = getRarityRank(rarity: $0.description.rarity)
                                        let B = getRarityRank(rarity: $1.description.rarity)
                                        if A != B {
                                            return B < A
                                        }
                                        
                                        return $0.description.name.localizedCaseInsensitiveCompare($1.description.name) == .orderedDescending
                                    }
                                }) { item in
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 18)
                                            .frame(width: 150, height: 10)
                                            .foregroundStyle(getRarityColor(rarity: item.description.rarity ?? "unknown"))
                                            .padding(.top, 100)
                                        RoundedRectangle(cornerRadius: 18)
                                            .foregroundStyle(.thinMaterial)
                                            .frame(width: 150, height: 150)
                                        Rectangle()
                                            .frame(width: 150, height: 40)
                                            .foregroundStyle(getRarityColor(rarity: item.description.rarity ?? "unknown"))
                                            .padding(.top, 160)
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
                                        
                                    }.frame(width: 150, height: 150)
                                        .clipShape(RoundedRectangle(cornerRadius: 18))
                                }
                            }
                            Text("\(inventory.items.count) items loaded")
                                .padding(.top, 50)
                        }
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 500, minHeight: 400)
    }
}

#Preview {
    ContentView()
}
