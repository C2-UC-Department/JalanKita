//
//  PermissionsStepView.swift
//  JalanKita iOS
//
//  Camera, location, and microphone permissions, each explained in one
//  plain sentence, per §6.1.1. Also collects the surveyor's name, since
//  every recorded Session needs a real Surveyor identity.
//

import AVFoundation
import CoreLocation
import SwiftUI

struct PermissionsStepView: View {
    @Environment(AppModel.self) private var model
    let onContinue: () -> Void

    @State private var surveyorName: String = ""
    @State private var cameraGranted = false
    @State private var microphoneGranted = false
    @State private var locationRequested = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Selamat datang di JalanKita")
                        .font(.largeTitle.weight(.bold))
                    Text("Rekam kondisi jalan seperti dashcam. Aplikasi ini merekam saja — analisis dilakukan nanti di kantor.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("NAMA SURVEYOR")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    TextField("Nama Anda", text: $surveyorName)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: surveyorName) { _, newValue in
                            model.setSurveyorName(newValue)
                        }
                }

                VStack(spacing: 16) {
                    permissionRow(
                        icon: "camera.fill",
                        title: "Kamera",
                        explanation: "Merekam video jalan ke depan selama survei.",
                        granted: cameraGranted
                    ) {
                        AVCaptureDevice.requestAccess(for: .video) { granted in
                            Task { @MainActor in cameraGranted = granted }
                        }
                    }
                    permissionRow(
                        icon: "location.fill",
                        title: "Lokasi",
                        explanation: "Mencatat jejak GPS sepanjang perjalanan agar rekaman bisa dipetakan.",
                        granted: locationRequested
                    ) {
                        CLLocationManager().requestWhenInUseAuthorization()
                        locationRequested = true
                    }
                    permissionRow(
                        icon: "mic.fill",
                        title: "Mikrofon",
                        explanation: "Merekam audio bersama video sebagai bagian dari rekaman survei.",
                        granted: microphoneGranted
                    ) {
                        AVCaptureDevice.requestAccess(for: .audio) { granted in
                            Task { @MainActor in microphoneGranted = granted }
                        }
                    }
                }

                Button("Lanjutkan") { onContinue() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .disabled(surveyorName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .onAppear { surveyorName = model.surveyorName }
    }

    private func permissionRow(
        icon: String, title: String, explanation: String, granted: Bool, action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 36)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(explanation).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Button(granted ? "Diizinkan" : "Izinkan", action: action)
                .buttonStyle(.bordered)
                .disabled(granted)
        }
    }
}
