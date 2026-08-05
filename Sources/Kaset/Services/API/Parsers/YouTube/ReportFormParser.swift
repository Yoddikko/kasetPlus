import Foundation

/// Parses YouTube's `flag/get_form` response into a `YouTubeReportForm`.
///
/// The web report dialog is a modal (`reportFormModalRenderer`) wrapping a
/// `reasonSelectorRenderer` whose `optionSelectableItemRenderer` rows are the
/// selectable reasons. Each row carries a localized label and, on its tap/submit
/// endpoint, the opaque `params` to POST back to `flag/flag`.
///
/// The exact wrapper renderers have drifted across YouTube revisions, so the
/// parse is defensive: it collects every reason-bearing row anywhere in the
/// response and pulls the title from whichever modal/selector node carries one.
enum ReportFormParser {
    static func parse(_ data: [String: Any]) -> YouTubeReportForm {
        // YouTube usually delivers the form inside an `openPopupAction` popup
        // (the modal), sometimes directly at `actions[]`. Walk the whole tree so
        // either shape works.
        let root: Any = data["actions"] ?? data

        var reasons: [YouTubeReportForm.Reason] = []
        var seen: Set<String> = []
        Self.collectReasons(in: root, reasons: &reasons, seen: &seen)

        return YouTubeReportForm(
            title: Self.firstFormTitle(in: root),
            reasons: reasons
        )
    }

    // MARK: - Reasons

    private static func collectReasons(
        in value: Any,
        reasons: inout [YouTubeReportForm.Reason],
        seen: inout Set<String>
    ) {
        if let dict = value as? [String: Any] {
            if let row = dict["optionSelectableItemRenderer"] as? [String: Any],
               let reason = Self.reason(fromSelectableItem: row),
               seen.insert(reason.submitParams).inserted
            {
                reasons.append(reason)
            }

            for nested in dict.values {
                Self.collectReasons(in: nested, reasons: &reasons, seen: &seen)
            }
        } else if let array = value as? [Any] {
            for element in array {
                Self.collectReasons(in: element, reasons: &reasons, seen: &seen)
            }
        }
    }

    private static func reason(fromSelectableItem row: [String: Any]) -> YouTubeReportForm.Reason? {
        guard let label = YouTubeItemParser.text(from: row["text"])
            ?? YouTubeItemParser.text(from: row["title"]),
            !label.isEmpty
        else {
            return nil
        }

        // The submit token lives on the row's selection/submit endpoint. Across
        // revisions it has been keyed under a few endpoint names; accept any.
        guard let submitParams = Self.firstFlagParams(in: row) else {
            return nil
        }

        let id = (row["itemId"] as? String)
            ?? (row["reasonId"] as? String)
            ?? submitParams

        return YouTubeReportForm.Reason(
            id: id,
            label: label,
            submitParams: submitParams
        )
    }

    /// The first `params` string carried by a `flag/flag` submit endpoint under
    /// the given node — tolerant of the wrapper endpoint name (`flagAction`,
    /// `flagEndpoint`, `getReportFormEndpoint`, or the generic
    /// `serviceEndpoint.flagEndpoint`).
    private static func firstFlagParams(in value: Any) -> String? {
        if let dict = value as? [String: Any] {
            for key in ["flagEndpoint", "flagAction", "getReportFormEndpoint", "reportEndpoint"] {
                if let endpoint = dict[key] as? [String: Any],
                   let params = endpoint["params"] as? String,
                   !params.isEmpty
                {
                    return params
                }
            }
            for nested in dict.values {
                if let params = Self.firstFlagParams(in: nested) {
                    return params
                }
            }
        } else if let array = value as? [Any] {
            for element in array {
                if let params = Self.firstFlagParams(in: element) {
                    return params
                }
            }
        }
        return nil
    }

    // MARK: - Title

    private static func firstFormTitle(in value: Any) -> String? {
        if let dict = value as? [String: Any] {
            for key in ["reportFormModalRenderer", "reasonSelectorRenderer"] {
                if let renderer = dict[key] as? [String: Any],
                   let title = YouTubeItemParser.text(from: renderer["title"]),
                   !title.isEmpty
                {
                    return title
                }
            }
            for nested in dict.values {
                if let title = Self.firstFormTitle(in: nested) {
                    return title
                }
            }
        } else if let array = value as? [Any] {
            for element in array {
                if let title = Self.firstFormTitle(in: element) {
                    return title
                }
            }
        }
        return nil
    }
}
