import SwiftUI

/// Renders a Chat app's Card v2.
///
/// Read-mostly by necessity. Buttons that open links work; buttons that invoke an
/// `action` call back into the Chat app that sent them, which requires authenticating
/// *as that app*. A user-auth client cannot dispatch them, so they render disabled
/// with an explanation rather than pretending to work.
struct CardView: View {
    let card: ChatCard

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header = card.header {
                CardHeaderView(header: header)
                Divider()
            }

            ForEach(Array((card.sections ?? []).enumerated()), id: \.offset) { index, section in
                if index > 0 { Divider() }
                CardSectionView(section: section)
            }

            if let footer = card.fixedFooter {
                Divider()
                HStack(spacing: 8) {
                    if let primary = footer.primaryButton {
                        CardButtonView(button: primary, emphasised: true)
                    }
                    if let secondary = footer.secondaryButton {
                        CardButtonView(button: secondary, emphasised: false)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
            }
        }
        .frame(maxWidth: 460, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
    }
}

private struct CardHeaderView: View {
    let header: CardHeader

    var body: some View {
        HStack(spacing: 10) {
            if let url = header.imageUrl.flatMap(URL.init(string:)) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Rectangle().fill(.quaternary)
                }
                .frame(width: 36, height: 36)
                .clipShape(header.imageType == "CIRCLE" ? AnyShape(.circle) : AnyShape(.rect(cornerRadius: 6)))
                .accessibilityLabel(header.imageAltText ?? "")
            }

            VStack(alignment: .leading, spacing: 1) {
                if let title = header.title {
                    Text(title).font(.headline).lineLimit(2)
                }
                if let subtitle = header.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
    }
}

private struct CardSectionView: View {
    let section: CardSection

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header = section.header {
                Text(CardTextRenderer.attributed(header))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(visibleWidgets.enumerated()), id: \.offset) { _, widget in
                CardWidgetView(widget: widget)
            }

            if hiddenCount > 0 {
                Button(isExpanded ? "Show less" : "Show \(hiddenCount) more") {
                    isExpanded.toggle()
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(10)
    }

    private var allWidgets: [CardWidget] { section.widgets ?? [] }

    /// Collapsible sections show `uncollapsibleWidgetsCount` widgets until expanded.
    /// Chat defaults that to 1 when the section is collapsible but omits the count.
    private var visibleWidgets: [CardWidget] {
        guard section.collapsible == true, !isExpanded else { return allWidgets }
        let shown = max(1, section.uncollapsibleWidgetsCount ?? 1)
        return Array(allWidgets.prefix(shown))
    }

    private var hiddenCount: Int {
        guard section.collapsible == true else { return 0 }
        let shown = max(1, section.uncollapsibleWidgetsCount ?? 1)
        return max(0, allWidgets.count - shown)
    }
}

private struct CardWidgetView: View {
    let widget: CardWidget

    var body: some View {
        Group {
            if let paragraph = widget.textParagraph {
                Text(CardTextRenderer.attributed(paragraph.text ?? ""))
                    .font(.callout)
                    .lineLimit(paragraph.maxLines.map { $0 > 0 ? $0 : Int.max })
                    .frame(maxWidth: .infinity, alignment: .leading)

            } else if let image = widget.image {
                CardImageView(image: image)

            } else if let decorated = widget.decoratedText {
                CardDecoratedTextView(decorated: decorated)

            } else if let list = widget.buttonList {
                CardButtonRow(buttons: list.buttons ?? [])

            } else if widget.divider != nil {
                Divider()

            } else if let grid = widget.grid {
                CardGridView(grid: grid)

            } else if let columns = widget.columns {
                CardColumnsView(columns: columns)

            } else if let chips = widget.chipList {
                CardChipRow(chips: chips.chips ?? [])

            } else if let carousel = widget.carousel {
                // Rendered as a vertical stack: a horizontal pager inside an already
                // scrolling transcript fights the outer scroll view.
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array((carousel.widgets ?? []).enumerated()), id: \.offset) { _, item in
                        CardWidgetView(widget: item)
                    }
                }

            } else if let input = widget.textInput {
                CardInputPlaceholder(
                    label: input.label ?? input.name ?? "Text input",
                    detail: input.value ?? input.hintText ?? input.placeholderText
                )

            } else if let selection = widget.selectionInput {
                CardInputPlaceholder(
                    label: selection.label ?? selection.name ?? "Selection",
                    detail: selection.items?.compactMap(\.text).joined(separator: ", ")
                )

            } else if let picker = widget.dateTimePicker {
                CardInputPlaceholder(
                    label: picker.label ?? picker.name ?? "Date picker",
                    detail: picker.type
                )

            } else {
                // A widget type this version does not know. Naming it beats rendering
                // nothing, which would look like a broken card.
                Text("Unsupported card content")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
    }

    private var alignment: Alignment {
        switch widget.horizontalAlignment {
        case "CENTER": .center
        case "END": .trailing
        default: .leading
        }
    }
}

private struct CardImageView: View {
    let image: CardImage

    @State private var isViewerPresented = false

    var body: some View {
        let content = AsyncImage(url: image.imageUrl.flatMap(URL.init(string:))) { phase in
            switch phase {
            case .success(let loaded):
                loaded.resizable().scaledToFit()
            case .failure:
                placeholder(systemImage: "photo.badge.exclamationmark")
            default:
                placeholder(systemImage: "photo")
            }
        }
        .frame(maxWidth: 420, maxHeight: 280)
        .clipShape(.rect(cornerRadius: 8))
        .accessibilityLabel(image.altText ?? "Image")

        // A card that names its own click target keeps it — that link is the bot's
        // intent. Everything else opens the picture itself, in the app.
        if let url = image.onClick?.openLink?.url.flatMap(URL.init(string:)) {
            Link(destination: url) { content }
        } else if let source = image.imageUrl.flatMap(URL.init(string:)) {
            Button { isViewerPresented = true } label: { content }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help("Open image")
                .accessibilityLabel("Open \(image.altText ?? "image")")
                .sheet(isPresented: $isViewerPresented) {
                    ImageViewer(
                        title: image.altText ?? "Image",
                        source: .remote(source),
                        fileName: source.lastPathComponent
                    )
                }
        } else {
            content
        }
    }

    private func placeholder(systemImage: String) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.quaternary)
            .frame(height: 120)
            .overlay { Image(systemName: systemImage).foregroundStyle(.secondary) }
    }
}

private struct CardDecoratedTextView: View {
    let decorated: CardDecoratedText

    var body: some View {
        let row = HStack(alignment: .center, spacing: 10) {
            if let icon = decorated.startIcon {
                CardIconView(icon: icon)
            }

            VStack(alignment: .leading, spacing: 1) {
                if let top = decorated.topLabel, !top.isEmpty {
                    Text(CardTextRenderer.attributed(top))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(CardTextRenderer.attributed(decorated.text ?? ""))
                    .font(.callout)
                    .lineLimit(decorated.wrapText == true ? nil : 1)
                if let bottom = decorated.bottomLabel, !bottom.isEmpty {
                    Text(CardTextRenderer.attributed(bottom))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            if let control = decorated.switchControl {
                // Read-only: flipping it would submit an action to the sending app.
                Toggle("", isOn: .constant(control.selected ?? false))
                    .labelsHidden()
                    .disabled(true)
                    .help("Interactive card controls need the Chat app that sent them")
            } else if let button = decorated.button {
                CardButtonView(button: button, emphasised: false)
            } else if let icon = decorated.endIcon {
                CardIconView(icon: icon)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if let url = decorated.onClick?.openLink?.url.flatMap(URL.init(string:)) {
            Link(destination: url) { row }.buttonStyle(.plain)
        } else {
            row
        }
    }
}

private struct CardButtonRow: View {
    let buttons: [CardButton]

    var body: some View {
        // Wrapping rather than a single row: cards routinely carry four or five
        // buttons, which would otherwise force the whole card wider than its bounds.
        FlowLayout(spacing: 6) {
            ForEach(Array(buttons.enumerated()), id: \.offset) { _, button in
                CardButtonView(button: button, emphasised: button.type == "FILLED")
            }
        }
    }
}

private struct CardButtonView: View {
    let button: CardButton
    let emphasised: Bool

    var body: some View {
        if let url = button.onClick?.openLink?.url.flatMap(URL.init(string:)) {
            Link(destination: url) { label }
                .buttonStyle(emphasised ? AnyButtonStyle(.borderedProminent) : AnyButtonStyle(.bordered))
                .controlSize(.small)
                .disabled(button.disabled == true)
        } else {
            // Action-only button: unreachable without app auth.
            Button(action: {}) { label }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(true)
                .help("This button runs an action in the app that sent the card, which this client can't invoke")
        }
    }

    private var label: some View {
        HStack(spacing: 4) {
            if let icon = button.icon {
                CardIconView(icon: icon, size: 12)
            }
            Text(button.text ?? button.altText ?? "Open")
                .font(.caption)
        }
    }
}

/// Lets a button style be chosen at runtime, which `buttonStyle` otherwise forbids.
private struct AnyButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: PrimitiveButtonStyle>(_ style: S) {
        make = { configuration in
            AnyView(Button(configuration).buttonStyle(style))
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}

private struct CardChipRow: View {
    let chips: [CardChipList.Chip]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                chipView(chip)
            }
        }
    }

    @ViewBuilder
    private func chipView(_ chip: CardChipList.Chip) -> some View {
        let content = HStack(spacing: 4) {
            if let icon = chip.icon { CardIconView(icon: icon, size: 11) }
            Text(chip.label ?? chip.altText ?? "")
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary, in: .capsule)

        if let url = chip.onClick?.openLink?.url.flatMap(URL.init(string:)) {
            Link(destination: url) { content }
        } else {
            content.opacity(chip.disabled == true ? 0.5 : 1)
        }
    }
}

private struct CardGridView: View {
    let grid: CardGrid

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = grid.title {
                Text(title).font(.caption.weight(.semibold))
            }
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 8),
                    count: max(1, grid.columnCount ?? 2)
                ),
                spacing: 8
            ) {
                ForEach(Array((grid.items ?? []).enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 3) {
                        if let uri = item.image?.imageUri.flatMap(URL.init(string:)) {
                            AsyncImage(url: uri) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Rectangle().fill(.quaternary)
                            }
                            .frame(height: 72)
                            .clipShape(.rect(cornerRadius: 6))
                        }
                        if let title = item.title {
                            Text(title).font(.caption).lineLimit(2)
                        }
                        if let subtitle = item.subtitle {
                            Text(subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }
}

private struct CardColumnsView: View {
    let columns: CardColumns

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(Array((columns.columnItems ?? []).enumerated()), id: \.offset) { _, column in
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array((column.widgets ?? []).enumerated()), id: \.offset) { _, widget in
                        CardWidgetView(widget: widget)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct CardIconView: View {
    let icon: CardIcon
    var size: CGFloat = 16

    var body: some View {
        if let url = icon.iconUrl.flatMap(URL.init(string:)) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Color.clear
            }
            .frame(width: size, height: size)
            .clipShape(icon.imageType == "CIRCLE" ? AnyShape(.circle) : AnyShape(.rect))
        } else {
            Image(systemName: symbolName)
                .font(.system(size: size))
                .foregroundStyle(.secondary)
                .accessibilityLabel(icon.altText ?? "")
        }
    }

    /// Maps Chat's built-in icon names onto SF Symbols. Unmapped names — including
    /// most Material icon names — fall back to a neutral glyph rather than nothing.
    private var symbolName: String {
        let key = (icon.knownIcon ?? icon.materialIcon?.name ?? "").uppercased()
        return Self.symbols[key] ?? "circle.fill"
    }

    private static let symbols: [String: String] = [
        "AIRPLANE": "airplane", "BOOKMARK": "bookmark", "BUS": "bus", "CAR": "car",
        "CLOCK": "clock", "CONFIRMATION_NUMBER_ICON": "ticket", "DESCRIPTION": "doc.text",
        "DOLLAR": "dollarsign.circle", "EMAIL": "envelope", "EVENT_SEAT": "chair",
        "FLIGHT_ARRIVAL": "airplane.arrival", "FLIGHT_DEPARTURE": "airplane.departure",
        "HOTEL": "bed.double", "HOTEL_ROOM_TYPE": "bed.double", "INVITE": "calendar.badge.plus",
        "MAP_PIN": "mappin", "MEMBERSHIP": "person.crop.circle.badge.checkmark",
        "MULTIPLE_PEOPLE": "person.2", "PERSON": "person", "PHONE": "phone",
        "RESTAURANT_ICON": "fork.knife", "SHOPPING_CART": "cart", "STAR": "star",
        "STORE": "storefront", "TICKET": "ticket", "TRAIN": "tram", "VIDEO_CAMERA": "video",
        "VIDEO_PLAY": "play.rectangle",
        // Common Material names, since Chat apps increasingly send these instead.
        "CHECK_CIRCLE": "checkmark.circle", "ERROR": "exclamationmark.triangle",
        "WARNING": "exclamationmark.triangle", "INFO": "info.circle",
        "SCHEDULE": "clock", "LINK": "link", "SEND": "paperplane",
    ]
}

/// Shown for form widgets, which cannot be submitted from a user-auth client.
private struct CardInputPlaceholder: View {
    let label: String
    let detail: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption.weight(.medium))
                if let detail, !detail.isEmpty {
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(.quaternary, in: .rect(cornerRadius: 6))
        .help("Card forms are submitted by the app that sent them, which this client can't act as")
    }
}
