import SwiftUI

#if os(iOS)
import AVKit

/// System audio-output picker (iPhone speaker, Bluetooth, AirPlay…). Choosing the phone's own speaker avoids
/// the 150–300 ms delay that Bluetooth speakers add.
struct RoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = UIColor(white: 1, alpha: 0.45)
        v.activeTintColor = UIColor(Theme.accent)
        v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif
