import SwiftUI
import UIKit

/// Photos inside a note. The note text keeps only a line `[[photo:<uuid>]]`; the picture itself stays on this
/// phone, encrypted with the vault key (NotesStore). The web sees the token and says «фото на телефоне».
public enum NotePhotos {
    public static func token(_ id: String) -> String { "[[photo:\(id)]]" }

    /// The photo id when the whole line is a photo token, else nil.
    public static func id(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[[photo:"), trimmed.hasSuffix("]]") else { return nil }
        let id = String(trimmed.dropFirst(8).dropLast(2))
        guard !id.isEmpty, id.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return nil }
        return id
    }

    /// Downscaled to at most 1600 px on the long side, JPEG quality 0.7.
    static func jpeg(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, 1600 / max(longest, 1))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: 0.7)
    }

    /// The inline frame: full line width, 120 pt high, cropped to fill, rounded like DS cards, thin border.
    static func frame(_ image: UIImage?, width: CGFloat, border: UIColor) -> UIImage {
        let size = CGSize(width: max(width, 40), height: 120)
        return UIGraphicsImageRenderer(size: size).image { context in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: DS.Metrics.cardRadius)
            path.addClip()
            if let image {
                let fill = max(size.width / image.size.width, size.height / image.size.height)
                let drawn = CGSize(width: image.size.width * fill, height: image.size.height * fill)
                image.draw(in: CGRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2,
                                      width: drawn.width, height: drawn.height))
            } else {
                UIColor.secondarySystemFill.setFill()
                context.fill(rect)
            }
            border.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

/// The photo opened from a note: fullscreen, pinch to zoom, double tap resets.
struct NotePhotoViewer: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale * pinch)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .gesture(MagnifyGesture()
                    .updating($pinch) { value, state, _ in state = value.magnification }
                    .onEnded { value in scale = min(max(scale * value.magnification, 1), 5) })
                .onTapGesture(count: 2) { withAnimation { scale = 1 } }
                .accessibilityLabel("Фото из заметки")
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(16)
            .accessibilityLabel("Закрыть")
        }
    }
}
