//
//  CalibrationStepView.swift
//  JalanKita iOS
//
//  §6.1.3 — park, photograph something of known width, enter that width.
//  Skippable but recommended: without it, downstream reports can only
//  show damage as a percentage of the road surface, not real m². The
//  actual pixel-to-metres math lives in a sibling repo, not this app —
//  this screen only captures and stores the frame + width value.
//

import SwiftUI
import JalanKitaKit

struct CalibrationStepView: View {
    @Environment(AppModel.self) private var model
    let onFinish: () -> Void
    let onSkip: () -> Void

    @State private var capture = CalibrationCaptureController()
    @State private var mountLabel = ""
    @State private var widthText = ""
    @State private var cameraError: String?

    var body: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Kalibrasi skala")
                    .font(.largeTitle.weight(.bold))
                Text("Ini memungkinkan kami melaporkan kerusakan dalam meter persegi asli, bukan persentase.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)

            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(Color.black)
                if let image = capture.capturedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                } else {
                    CameraPreviewView(session: capture.session)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                if let cameraError {
                    Text(cameraError)
                        .foregroundStyle(.white)
                        .padding()
                }
            }
            .frame(height: 260)
            .padding(.horizontal)

            VStack(alignment: .leading, spacing: 10) {
                TextField("Label pemasangan (mis. Toyota Avanza — dasbor)", text: $mountLabel)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    TextField("Lebar objek (meter)", text: $widthText)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.decimalPad)
                    Button(capture.capturedImage == nil ? "Ambil foto" : "Ambil ulang") {
                        capture.capture { _ in }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal)

            Spacer()

            VStack(spacing: 10) {
                Button("Simpan kalibrasi") { save() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .disabled(capture.capturedImage == nil || Double(widthText.replacingOccurrences(of: ",", with: ".")) == nil)

                Button("Lewati untuk sekarang") { onSkip() }
                    .font(.footnote)
            }
            .padding(.horizontal)
        }
        .padding(.vertical)
        .task {
            do {
                try capture.configureIfNeeded()
                capture.start()
            } catch {
                cameraError = "Kamera tidak tersedia."
            }
        }
        .onDisappear { capture.stop() }
    }

    private func save() {
        guard let image = capture.capturedImage,
              let width = Double(widthText.replacingOccurrences(of: ",", with: "."))
        else { return }

        let filename = "calibration_\(UUID().uuidString).jpg"
        let url = model.store.calibrationFrameURL(filename: filename)
        if let data = image.jpegData(compressionQuality: 0.9) {
            try? data.write(to: url)
        }

        let profile = CalibrationProfile(
            mountLabel: mountLabel.isEmpty ? "Pemasangan tanpa nama" : mountLabel,
            knownWidthMeters: width,
            frameFilename: filename,
            createdAt: Date(),
            surveyorID: model.surveyorName.isEmpty ? "unknown" : model.surveyorName
        )
        model.saveCalibration(profile)
        onFinish()
    }
}
