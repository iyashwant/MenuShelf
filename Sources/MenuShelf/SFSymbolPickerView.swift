import SwiftUI

struct SFSymbolPickerView: View {
    @Binding var selectedSymbol: String
    @Environment(\.dismiss) private var dismiss

    @State private var searchText: String = ""
    @State private var selectedCategory: SymbolCategory = .all

    private let columns = [
        GridItem(.adaptive(minimum: 56, maximum: 56), spacing: 12)
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Choose an Icon")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .top])

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search symbols", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
            .padding(.horizontal)

            Picker("Category", selection: $selectedCategory) {
                ForEach(SymbolCategory.allCases) { category in
                    Text(category.label).tag(category)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            Divider()
                .padding(.top, 8)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(filteredSymbols, id: \.self) { symbol in
                        SymbolButton(
                            symbol: symbol,
                            isSelected: selectedSymbol == symbol
                        ) {
                            selectedSymbol = symbol
                            dismiss()
                        }
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 400, idealWidth: 480, maxWidth: 560,
               minHeight: 320, idealHeight: 420, maxHeight: 520)
    }

    private var filteredSymbols: [String] {
        let base: [String]
        if selectedCategory == .all {
            base = SymbolCategory.allSymbols
        } else {
            base = selectedCategory.symbols
        }
        if searchText.isEmpty {
            return base
        }
        return base.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }
}

private struct SymbolButton: View {
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .frame(width: 48, height: 48)
                .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
                .foregroundStyle(isSelected ? Color.accentColor : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: isSelected ? 2 : 1)
                )
        }
        .buttonStyle(.plain)
        .help(symbol)
    }
}

enum SymbolCategory: String, CaseIterable, Identifiable {
    case all
    case folders
    case apps
    //case work // Combined into apps or general
    case actions
    case media
    case system
    case communication
    case nature
    case objects

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All"
        case .folders: "Folders"
        case .apps: "Apps"
        case .actions: "Actions"
        case .media: "Media"
        case .system: "System"
        case .communication: "Comm"
        case .nature: "Nature"
        case .objects: "Objects"
        }
    }

    static var allSymbols: [String] {
        allCases.flatMap { $0.symbols }.uniqued()
    }

    var symbols: [String] {
        switch self {
        case .all:
            return []
        case .folders:
            return [
                "folder", "folder.fill",
                "doc", "doc.fill", "doc.text", "doc.text.fill",
                "archivebox", "archivebox.fill",
                "tray", "tray.fill", "tray.2", "tray.2.fill",
                "cabinet", "cabinet.fill",
                "shippingbox", "shippingbox.fill",
                "backpack", "backpack.fill",
                "briefcase", "briefcase.fill",
                "suitcase", "suitcase.fill",
                "bag", "bag.fill",
                "basket", "basket.fill",
                "takeoutbag.and.cup.and.straw",
                "bag.circle", "bag.circle.fill",
            ]
        case .apps:
            return [
                "app", "app.fill",
                "square.grid.2x2", "square.grid.2x2.fill",
                "squares.leading.rectangle",
                "rectangle.3.group", "rectangle.3.group.fill",
                "apps.iphone", "apps.iphone.badge.plus",
                "macwindow", "macwindow.on.rectangle",
                "command", "command.square", "command.square.fill",
                "terminal", "terminal.fill",
                "hammer", "hammer.fill",
                "wrench.and.screwdriver", "wrench.and.screwdriver.fill",
                "gearshape", "gearshape.fill", "gearshape.2", "gearshape.2.fill",
                "gear", "gear.circle", "gear.circle.fill",
                "slider.horizontal.3",
                "switch.2",
                "dial.low", "dial.medium", "dial.high",
                "cursorarrow",
                "hand.tap",
                "cursorarrow.click",
                "eye", "eye.fill",
                "lasso",
                "paintbrush", "paintbrush.fill",
                "pencil", "pencil.circle", "pencil.circle.fill",
            ]
        case .actions:
            return [
                "plus", "plus.circle", "plus.circle.fill", "plus.square", "plus.square.fill",
                "minus", "minus.circle", "minus.circle.fill", "minus.square", "minus.square.fill",
                "xmark", "xmark.circle", "xmark.circle.fill", "xmark.square", "xmark.square.fill",
                "checkmark", "checkmark.circle", "checkmark.circle.fill", "checkmark.square", "checkmark.square.fill",
                "arrow.right", "arrow.left", "arrow.up", "arrow.down",
                "arrow.clockwise", "arrow.counterclockwise",
                "arrow.2.squarepath",
                "arrow.triangle.2.circlepath",
                "arrow.up.arrow.down",
                "arrow.left.arrow.right",
                "arrow.uturn.left", "arrow.uturn.right",
                "arrow.up.and.down",
                "arrow.left.and.right",
                "magnifyingglass",
                "magnifyingglass.circle", "magnifyingglass.circle.fill",
                "sparkle", "sparkles",
                "star", "star.fill", "star.circle", "star.circle.fill",
                "heart", "heart.fill", "heart.circle", "heart.circle.fill",
                "bolt", "bolt.fill", "bolt.circle", "bolt.circle.fill",
                "flame", "flame.fill",
                "power",
                "play", "play.fill", "play.circle", "play.circle.fill",
                "pause", "pause.fill", "pause.circle", "pause.circle.fill",
                "stop", "stop.fill", "stop.circle", "stop.circle.fill",
                "record.circle", "record.circle.fill",
                "bookmark", "bookmark.fill",
                "pin", "pin.fill",
                "link", "link.circle", "link.circle.fill",
                "paperclip",
                "scissors",
                "doc.on.doc", "doc.on.doc.fill",
                "doc.on.clipboard", "doc.on.clipboard.fill",
                "trash", "trash.fill", "trash.circle", "trash.circle.fill",
            ]
        case .media:
            return [
                "photo", "photo.fill",
                "photo.on.rectangle", "photo.on.rectangle.angled",
                "camera", "camera.fill", "camera.circle", "camera.circle.fill",
                "video", "video.fill", "video.circle", "video.circle.fill",
                "music.note", "music.note.list",
                "play.rectangle", "play.rectangle.fill",
                "film", "film.fill",
                "tv", "tv.fill",
                "speaker", "speaker.fill", "speaker.wave.2", "speaker.wave.2.fill",
                "headphones", "headphones.circle", "headphones.circle.fill",
                "radio", "radio.fill",
                "mic", "mic.fill", "mic.circle", "mic.circle.fill",
                "waveform", "waveform.circle", "waveform.circle.fill",
                "book", "book.fill", "book.closed", "book.closed.fill",
                "text.book.closed", "text.book.closed.fill",
            ]
        case .system:
            return [
                "house", "house.fill", "house.circle", "house.circle.fill",
                "lock", "lock.fill", "lock.circle", "lock.circle.fill", "lock.open", "lock.open.fill",
                "key", "key.fill",
                "bell", "bell.fill", "bell.circle", "bell.circle.fill", "bell.badge", "bell.badge.fill",
                "clock", "clock.fill",
                "timer", "timer.circle", "timer.circle.fill",
                "calendar", "calendar.circle", "calendar.circle.fill",
                "sun.max", "sun.max.fill",
                "moon", "moon.fill", "moon.circle", "moon.circle.fill",
                "cloud", "cloud.fill", "cloud.sun", "cloud.sun.fill", "cloud.moon", "cloud.moon.fill",
                "tag", "tag.fill",
                "flag", "flag.fill", "flag.circle", "flag.circle.fill",
                "location", "location.fill", "location.circle", "location.circle.fill",
                "globe",
                "network",
                "wifi", "wifi.circle", "wifi.circle.fill",
                "antenna.radiowaves.left.and.right",
                "chart.bar", "chart.bar.fill",
                "chart.pie", "chart.pie.fill",
                "chart.line.uptrend.xyaxis",
                "dollarsign", "dollarsign.circle", "dollarsign.circle.fill",
                "creditcard", "creditcard.fill",
                "gift", "gift.fill",
                "cart", "cart.fill",
                "bag.badge.plus", "bag.badge.minus",
            ]
        case .communication:
            return [
                "envelope", "envelope.fill", "envelope.circle", "envelope.circle.fill",
                "paperplane", "paperplane.fill", "paperplane.circle", "paperplane.circle.fill",
                "message", "message.fill", "message.circle", "message.circle.fill",
                "bubble.left", "bubble.left.fill",
                "phone", "phone.fill", "phone.circle", "phone.circle.fill",
                "video", "video.fill",
                "person", "person.fill", "person.circle", "person.circle.fill",
                "person.2", "person.2.fill",
                "person.3", "person.3.fill",
                "shareplay",
                "megaphone", "megaphone.fill",
                "exclamationmark.bubble", "exclamationmark.bubble.fill",
                "quote.bubble", "quote.bubble.fill",
                "at", "at.circle", "at.circle.fill",
                "number", "number.circle", "number.circle.fill",
            ]
        case .nature:
            return [
                "leaf", "leaf.fill",
                "tree", "tree.fill",
                "flower",
                "sun.min", "sun.min.fill",
                "sun.max", "sun.max.fill",
                "moon.stars", "moon.stars.fill",
                "cloud.rain", "cloud.rain.fill",
                "cloud.bolt", "cloud.bolt.fill",
                "cloud.snow", "cloud.snow.fill",
                "snowflake",
                "wind",
                "tornado",
                "hurricane",
                "drop", "drop.fill",
                "flame",
                "mountain.2", "mountain.2.fill",
                "sailboat", "sailboat.fill",
                "car", "car.fill",
                "bus", "bus.fill",
                "tram", "tram.fill",
                "airplane", "airplane.circle", "airplane.circle.fill",
                "bolt.car", "bolt.car.fill",
                "bicycle",
                "figure.walk", "figure.run", "figure.hiking",
                "pawprint", "pawprint.fill",
                "hare", "hare.fill",
                "tortoise", "tortoise.fill",
                "fish", "fish.fill",
                "bird", "bird.fill",
            ]
        case .objects:
            return [
                "lightbulb", "lightbulb.fill", "lightbulb.slash", "lightbulb.slash.fill",
                "flashlight.off.fill", "flashlight.on.fill",
                "lamp.desk", "lamp.desk.fill",
                "lamp.floor", "lamp.floor.fill",
                "lamp.ceiling", "lamp.ceiling.fill",
                "crown", "crown.fill",
                "diamond", "diamond.fill",
                "cube", "cube.fill",
                "pyramid", "pyramid.fill",
                "scope",
                "gamecontroller", "gamecontroller.fill",
                "dice", "dice.fill",
                "puzzlepiece", "puzzlepiece.fill",
                "graduationcap", "graduationcap.fill",
                "studentdesk",
                "stethoscope",
                "syringe",
                "pills", "pills.fill",
                "cross", "cross.fill",
                "bandage", "bandage.fill",
                "keyboard", "keyboard.fill",
                "printer", "printer.fill",
                "scanner", "scanner.fill",
                "faxmachine", "faxmachine.fill",
                "display", "display.2",
                "laptopcomputer",
                "desktopcomputer",
                "ipad", "iphone",
                "watch",
                "airpods", "airpodspro",
                "headphones",
                "tv",
                "airplayvideo", "airplayaudio",
                "hifispeaker", "hifispeaker.fill",
                "medal", "medal.fill",
                "trophy", "trophy.fill",
                "giftcard",
                "ticket", "ticket.fill",
                "die.face.1", "die.face.2", "die.face.3", "die.face.4", "die.face.5", "die.face.6",
                "cup.and.saucer", "cup.and.saucer.fill",
                "mug", "mug.fill",
                "wineglass", "wineglass.fill",
                "birthday.cake", "birthday.cake.fill",
            ]
        }
    }
}

private extension Array where Element == String {
    func uniqued() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
