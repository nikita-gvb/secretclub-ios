import SwiftUI
import VisionKit

struct QRScannerSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    private var scannerAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if scannerAvailable {
                    QRScannerView { value in
                        if app.login(with: value) {
                            dismiss()
                        } else {
                            error = "В QR-коде нет ссылки на подписку"
                        }
                    }
                    .ignoresSafeArea()
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.fill").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Камера недоступна. Разрешите доступ в Настройках или вставьте ссылку вручную.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .padding(32)
                }
                if let error {
                    VStack {
                        Spacer()
                        Text(error)
                            .font(.onest(15, .medium, relativeTo: .subheadline))
                            .padding(12)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.bottom, 40)
                    }
                }
            }
            .navigationTitle("Сканируйте QR-код")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
    }
}

struct QRScannerView: UIViewControllerRepresentable {
    var onFound: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {
        if !vc.isScanning { try? vc.startScanning() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onFound: (String) -> Void
        private var lastValue: String?

        init(onFound: @escaping (String) -> Void) {
            self.onFound = onFound
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let code) = item, let value = code.payloadStringValue, value != lastValue {
                    lastValue = value
                    onFound(value)
                    return
                }
            }
        }
    }
}
