import UIKit
import LinkPresentation

/// The poster handed to the system share sheet: the PNG (a named temp file
/// when it could be written, else the image) with the kind's share title as
/// the subject and as the preview's title.
final class PosterActivityItem: NSObject, UIActivityItemSource {
    let item: Any
    let title: String

    init(item: Any, title: String) {
        self.item = item
        self.title = title
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { item }

    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? { item }

    func activityViewController(_ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String { title }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        return metadata
    }
}
