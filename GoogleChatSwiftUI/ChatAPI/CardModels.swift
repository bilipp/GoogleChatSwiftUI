import Foundation

// Cards v2, as sent by Chat apps.
//
// Codable rather than Decodable: a user-auth client can never *author* cards, but the
// cache re-encodes them to store the tree as a JSON blob rather than as a sprawl of
// SwiftData entities.

nonisolated struct ChatCardWithID: Codable, Sendable, Hashable {
    let cardId: String?
    let card: ChatCard?
}

nonisolated struct ChatCard: Codable, Sendable, Hashable {
    let header: CardHeader?
    let sections: [CardSection]?
    let fixedFooter: CardFixedFooter?
    let name: String?
}

nonisolated struct CardHeader: Codable, Sendable, Hashable {
    let title: String?
    let subtitle: String?
    let imageUrl: String?
    let imageAltText: String?
    /// `SQUARE` or `CIRCLE`.
    let imageType: String?
}

nonisolated struct CardSection: Codable, Sendable, Hashable {
    let header: String?
    let widgets: [CardWidget]?
    let collapsible: Bool?
    let uncollapsibleWidgetsCount: Int?
}

nonisolated struct CardFixedFooter: Codable, Sendable, Hashable {
    let primaryButton: CardButton?
    let secondaryButton: CardButton?
}

/// A widget is a union: exactly one payload field is populated.
///
/// Recursion through `columns` and `carousel` is legal for a struct because the
/// nesting goes through `Array`, which supplies the indirection.
nonisolated struct CardWidget: Codable, Sendable, Hashable {
    let textParagraph: CardTextParagraph?
    let image: CardImage?
    let decoratedText: CardDecoratedText?
    let buttonList: CardButtonList?
    let divider: CardDivider?
    let grid: CardGrid?
    let columns: CardColumns?
    let chipList: CardChipList?
    let carousel: CardCarousel?
    // Form inputs are decoded so they can be rendered disabled rather than dropped
    // silently — see CardView for why they cannot be submitted.
    let textInput: CardTextInput?
    let selectionInput: CardSelectionInput?
    let dateTimePicker: CardDateTimePicker?

    let horizontalAlignment: String?
}

nonisolated struct CardTextParagraph: Codable, Sendable, Hashable {
    let text: String?
    let maxLines: Int?
}

nonisolated struct CardImage: Codable, Sendable, Hashable {
    let imageUrl: String?
    let altText: String?
    let onClick: CardOnClick?
}

nonisolated struct CardDecoratedText: Codable, Sendable, Hashable {
    let startIcon: CardIcon?
    let endIcon: CardIcon?
    let topLabel: String?
    let text: String?
    let bottomLabel: String?
    let wrapText: Bool?
    let onClick: CardOnClick?
    let button: CardButton?
    let switchControl: CardSwitchControl?
}

nonisolated struct CardSwitchControl: Codable, Sendable, Hashable {
    let name: String?
    let value: String?
    let selected: Bool?
    /// `SWITCH` or `CHECK_BOX`.
    let controlType: String?
}

nonisolated struct CardButtonList: Codable, Sendable, Hashable {
    let buttons: [CardButton]?
}

nonisolated struct CardButton: Codable, Sendable, Hashable {
    let text: String?
    let icon: CardIcon?
    let color: CardColor?
    let onClick: CardOnClick?
    let disabled: Bool?
    let altText: String?
    /// `OUTLINED`, `FILLED`, `FILLED_TONAL`, `BORDERLESS`.
    let type: String?
}

nonisolated struct CardColor: Codable, Sendable, Hashable {
    let red: Double?
    let green: Double?
    let blue: Double?
    let alpha: Double?
}

nonisolated struct CardIcon: Codable, Sendable, Hashable {
    nonisolated struct MaterialIcon: Codable, Sendable, Hashable {
        let name: String?
    }
    let knownIcon: String?
    let iconUrl: String?
    let materialIcon: MaterialIcon?
    let altText: String?
    let imageType: String?
}

/// `onClick.card` is deliberately not decoded: it opens a nested dialog, which needs
/// an app-auth round trip this client cannot make. Omitting it also avoids a genuinely
/// recursive type with no indirection through an array.
nonisolated struct CardOnClick: Codable, Sendable, Hashable {
    let openLink: CardOpenLink?
    let action: CardAction?
}

nonisolated struct CardOpenLink: Codable, Sendable, Hashable {
    let url: String?
    /// `FULL_SIZE`, `OVERLAY`.
    let openAs: String?
}

/// Invokes a callback on the Chat *app* that sent the card.
///
/// Unreachable from here: dispatching one means authenticating as that app, not as a
/// user. Buttons carrying an action are rendered visibly disabled.
nonisolated struct CardAction: Codable, Sendable, Hashable {
    let function: String?
    let interaction: String?
}

nonisolated struct CardDivider: Codable, Sendable, Hashable {}

nonisolated struct CardGrid: Codable, Sendable, Hashable {
    nonisolated struct Item: Codable, Sendable, Hashable {
        let id: String?
        let image: CardImageComponent?
        let title: String?
        let subtitle: String?
        /// `TEXT_BELOW`, `TEXT_ABOVE`.
        let layout: String?
    }
    let title: String?
    let items: [Item]?
    let columnCount: Int?
    let onClick: CardOnClick?
}

nonisolated struct CardImageComponent: Codable, Sendable, Hashable {
    let imageUri: String?
    let altText: String?
}

nonisolated struct CardColumns: Codable, Sendable, Hashable {
    nonisolated struct Column: Codable, Sendable, Hashable {
        let horizontalSizeStyle: String?
        let horizontalAlignment: String?
        let verticalAlignment: String?
        let widgets: [CardWidget]?
    }
    let columnItems: [Column]?
}

nonisolated struct CardCarousel: Codable, Sendable, Hashable {
    let widgets: [CardWidget]?
}

nonisolated struct CardChipList: Codable, Sendable, Hashable {
    nonisolated struct Chip: Codable, Sendable, Hashable {
        let label: String?
        let icon: CardIcon?
        let onClick: CardOnClick?
        let disabled: Bool?
        let altText: String?
    }
    /// `WRAPPED` or `HORIZONTAL_SCROLLABLE`.
    let layout: String?
    let chips: [Chip]?
}

nonisolated struct CardTextInput: Codable, Sendable, Hashable {
    let name: String?
    let label: String?
    let hintText: String?
    let value: String?
    let type: String?
    let placeholderText: String?
}

nonisolated struct CardSelectionInput: Codable, Sendable, Hashable {
    nonisolated struct Item: Codable, Sendable, Hashable {
        let text: String?
        let value: String?
        let selected: Bool?
    }
    let name: String?
    let label: String?
    /// `CHECK_BOX`, `RADIO_BUTTON`, `SWITCH`, `DROPDOWN`, `MULTI_SELECT`.
    let type: String?
    let items: [Item]?
}

nonisolated struct CardDateTimePicker: Codable, Sendable, Hashable {
    let name: String?
    let label: String?
    /// `DATE_ONLY`, `TIME_ONLY`, `DATE_AND_TIME`.
    let type: String?
    let valueMsEpoch: String?
}
