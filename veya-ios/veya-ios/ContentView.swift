import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ControlViewModel()

    var body: some View {
        ZStack {
            background

            ScrollView {
                VStack(spacing: 16) {
                    heroCard
                    connectionCard
                    trackingModeCard
                    if viewModel.trackingMode == .faceTracking {
                        faceTrackingCard
                    } else {
                        autoHoldCard
                    }
                    motionCard
                    calibrationCard
                    statusCard
                }
                .padding(16)
            }
        }
        .onAppear {
            viewModel.connect()
        }
    }

    private var background: some View {
        LinearGradient(
            colors: [
                Color(red: 0.04, green: 0.06, blue: 0.10),
                Color(red: 0.10, green: 0.14, blue: 0.20),
                Color(red: 0.06, green: 0.08, blue: 0.12)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(Color.cyan.opacity(0.12))
                .frame(width: 240, height: 240)
                .blur(radius: 12)
                .offset(x: 80, y: -100)
        }
        .overlay(alignment: .bottomLeading) {
            Circle()
                .fill(Color.orange.opacity(0.10))
                .frame(width: 180, height: 180)
                .blur(radius: 18)
                .offset(x: -50, y: 120)
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Veya Auto Hold")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("Keeps the mounted phone pointed north and slightly upward using live compass and motion feedback.")
                .font(.system(size: 15, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.76))

            HStack(spacing: 10) {
                pill(viewModel.connectionMessage)
                if viewModel.isSending {
                    pill("Sending")
                }
            }
        }
        .cardStyle()
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Connection")

            TextField("ESP8266 IP address", text: $viewModel.espHost)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.numbersAndPunctuation)
                .padding(12)
                .foregroundStyle(.white)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                }

            HStack(spacing: 10) {
                button("Connect", systemImage: "wifi", tint: .cyan) {
                    viewModel.connect()
                }

                button("Refresh", systemImage: "arrow.clockwise", tint: .blue) {
                    viewModel.connect()
                }
            }
        }
        .cardStyle()
    }

    private var trackingModeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Tracking Mode")

            Picker("Tracking Mode", selection: trackingModeBinding) {
                ForEach(TrackingMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(viewModel.trackingMode == .faceTracking ? "Face tracking is the primary mode. The app centers the strongest detected face in the camera view." : "North/up hold uses the compass and motion sensors.")
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.76))
        }
        .cardStyle()
    }

    private var autoHoldCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Auto Hold")

            Toggle("Enable automatic north/up tracking", isOn: autoHoldBinding)
                .toggleStyle(.switch)
                .tint(.cyan)
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 8) {
                Text("Target heading: \(viewModel.desiredHeadingDegrees, format: .number.precision(.fractionLength(1)))°")
                Text("Target pitch: \(viewModel.desiredPitchDegrees, format: .number.precision(.fractionLength(1)))°")
                Text("Pan sign: \(viewModel.panDirectionSign, format: .number.precision(.fractionLength(0)))")
                Text("Tilt sign: \(viewModel.tiltDirectionSign, format: .number.precision(.fractionLength(0)))")
            }
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(.white.opacity(0.78))
        }
        .cardStyle()
    }

    private var faceTrackingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Face Tracking")

            CameraPreview(session: viewModel.cameraSession)
                .frame(height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                }

            HStack(spacing: 10) {
                metricTile(title: "Face X", value: viewModel.faceErrorX, suffix: "norm")
                metricTile(title: "Face Y", value: viewModel.faceErrorY, suffix: "norm")
            }

            HStack(spacing: 10) {
                metricTile(title: "Face Pan", value: viewModel.lastFacePanCommandDegrees, suffix: "°")
                metricTile(title: "Face Tilt", value: viewModel.lastFaceTiltCommandDegrees, suffix: "°")
            }

            Text(viewModel.faceSearchStatus)
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.78))

            Text(viewModel.faceTracking.faceDetected ? "Face detected and being tracked." : "Searching for a face.")
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.78))
        }
        .cardStyle()
    }

    private var motionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Live Sensors")

            HStack(spacing: 10) {
                metricTile(title: "Heading", value: viewModel.heading.headingDegrees, suffix: "°")
                metricTile(title: "Pitch", value: viewModel.motion.pitchDegrees, suffix: "°")
            }

            HStack(spacing: 10) {
                metricTile(title: "Heading Acc", value: viewModel.heading.accuracyDegrees, suffix: "°")
                metricTile(title: "Motion", value: viewModel.motion.isAvailable ? 1 : 0, suffix: viewModel.motion.isAvailable ? "Yes" : "No")
            }

            HStack(spacing: 10) {
                metricTile(title: "Heading Err", value: viewModel.headingErrorDegrees, suffix: "°")
                metricTile(title: "Pan Cmd", value: viewModel.lastPanCommandDegrees, suffix: "°")
            }

            HStack(spacing: 10) {
                metricTile(title: "Pitch Err", value: viewModel.pitchErrorDegrees, suffix: "°")
                metricTile(title: "Tilt Cmd", value: viewModel.lastTiltCommandDegrees, suffix: "°")
            }
        }
        .cardStyle()
    }

    private var calibrationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Calibration")

            Text(viewModel.calibrationMessage)
                .font(.system(size: 15, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.78))

            HStack(spacing: 10) {
                button("Calibrate Motor Signs", systemImage: "arrow.left.arrow.right", tint: .mint) {
                    viewModel.calibrateMotorPolarity()
                }

                button("Capture Current Pose", systemImage: "scope", tint: .orange) {
                    viewModel.captureCurrentPose()
                }
            }

            HStack(spacing: 10) {
                button("Reset To North/Up", systemImage: "location.north.line", tint: .indigo) {
                    viewModel.resetNorthAndUpDefaults()
                }
            }
        }
        .cardStyle()
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Status")

            if let status = viewModel.lastStatus {
                Text(status.message)
                    .foregroundStyle(.white.opacity(0.80))
                Text("IP: \(status.ip ?? "unknown")")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.68))
            } else {
                Text("Waiting for ESP8266 status.")
                    .foregroundStyle(.white.opacity(0.80))
            }

            if let error = viewModel.lastErrorMessage {
                Text(error)
                    .foregroundStyle(.red.opacity(0.9))
            }
        }
        .cardStyle()
    }

    private var autoHoldBinding: Binding<Bool> {
        Binding(
            get: { viewModel.autoHoldEnabled },
            set: { viewModel.toggleAutoHold($0) }
        )
    }

    private var trackingModeBinding: Binding<TrackingMode> {
        Binding(
            get: { viewModel.trackingMode },
            set: { viewModel.setTrackingMode($0) }
        )
    }

    private func metricTile(title: String, value: Double, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.62))

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value, format: .number.precision(.fractionLength(1)))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(suffix)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.68))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    private func button(_ title: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(tint.opacity(0.28), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tint.opacity(0.40), lineWidth: 1)
        }
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.12), in: Capsule())
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.62))
           // .tracking(1.2)
    }
}

private extension View {
    func cardStyle(borderColor: Color = .white.opacity(0.12)) -> some View {
        self
            .padding(16)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.20), radius: 20, x: 0, y: 10)
    }
}

#Preview {
    ContentView()
}
