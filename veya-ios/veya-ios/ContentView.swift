import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ControlViewModel()

    var body: some View {
        ZStack {
            background

            ScrollView {
                VStack(spacing: 16) {
                    headerCard
                    connectionCard
                    motionCard
                    targetCard
                    liveCard
                    if let lastStatus = viewModel.lastStatus {
                        statusCard(status: lastStatus)
                    }
                    if let error = viewModel.lastErrorMessage {
                        errorCard(message: error)
                    }
                }
                .padding(16)
            }
        }
        .onAppear {
            if viewModel.zeroReference == .zero, viewModel.motion.isAvailable {
                viewModel.zeroReference = viewModel.motion
            }
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

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Veya")
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("Drive the 2-axis stand over Wi-Fi from this iPad, then swap in person tracking later without changing the hardware link.")
                .font(.system(size: 15, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))

            HStack(spacing: 10) {
                statusPill
                if viewModel.isSending {
                    statusPill(text: "Sending")
                }
            }
        }
        .cardStyle()
    }

    private var statusPill: some View {
        statusPill(text: viewModel.connectionMessage)
    }

    private func statusPill(text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.12), in: Capsule())
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardTitle("Connection")

            TextField("ESP8266 IP address", text: $viewModel.espHost)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.numbersAndPunctuation)
                .padding(12)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .foregroundStyle(.white)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                }

            HStack(spacing: 10) {
                actionButton(title: "Connect", systemImage: "wifi", tint: .cyan) {
                    viewModel.connect()
                }

                actionButton(title: "Zero Hardware", systemImage: "scope", tint: .orange) {
                    viewModel.zeroHardware()
                }
            }
        }
        .cardStyle()
    }

    private var motionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardTitle("Motion")

            motionGrid

            HStack(spacing: 10) {
                actionButton(title: "Calibrate Zero", systemImage: "target", tint: .mint) {
                    viewModel.calibrateMotionZero()
                }

                Toggle("Live Hold", isOn: liveHoldBinding)
                .toggleStyle(.switch)
                .tint(.cyan)
                .foregroundStyle(.white)
            }
        }
        .cardStyle()
    }

    private var motionGrid: some View {
        VStack(spacing: 12) {
            HStack {
                metricTile(title: "Yaw", value: viewModel.motion.yawDegrees, suffix: "°")
                metricTile(title: "Pitch", value: viewModel.motion.pitchDegrees, suffix: "°")
            }

            HStack {
                metricTile(title: "Roll", value: viewModel.motion.rollDegrees, suffix: "°")
                metricTile(title: "Available", value: viewModel.motion.isAvailable ? 1 : 0, suffix: viewModel.motion.isAvailable ? "Yes" : "No")
            }
        }
    }

    private func metricTile(title: String, value: Double, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value, format: .number.precision(.fractionLength(1)))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(suffix)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
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

    private var targetCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardTitle("Targets")

            sliderRow(
                title: "Motor 1",
                value: $viewModel.manualTarget.motor1Degrees,
                range: -160...160
            )

            sliderRow(
                title: "Motor 2",
                value: $viewModel.manualTarget.motor2Degrees,
                range: -160...160
            )

            HStack(spacing: 10) {
                actionButton(title: "Home", systemImage: "house", tint: .blue) {
                    viewModel.sendHome()
                }
                actionButton(title: "Look Up", systemImage: "arrow.up", tint: .indigo) {
                    viewModel.sendLookUp()
                }
                actionButton(title: "Send", systemImage: "paperplane.fill", tint: .green) {
                    viewModel.sendManualTarget()
                }
            }
        }
        .cardStyle()
    }

    private var liveCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardTitle("Live Loop")

            Text("When Live Hold is enabled, the app uses Core Motion as a lightweight feedback loop. That keeps the protocol ready for later person tracking.")
                .font(.system(size: 15, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.72))

            HStack(spacing: 10) {
                metricTile(title: "Command M1", value: viewModel.commandTarget.motor1Degrees, suffix: "°")
                metricTile(title: "Command M2", value: viewModel.commandTarget.motor2Degrees, suffix: "°")
            }
        }
        .cardStyle()
    }

    @ViewBuilder
    private func statusCard(status: ESP8266Status) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            cardTitle("ESP8266 Status")

            Text(status.message)
                .foregroundStyle(.white.opacity(0.8))

            Text("IP: \(status.ip ?? "unknown")")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.white.opacity(0.7))

            HStack(spacing: 10) {
                metricTile(title: "M1 Target", value: status.motor1.targetDeg, suffix: "°")
                metricTile(title: "M2 Target", value: status.motor2.targetDeg, suffix: "°")
            }
        }
        .cardStyle()
    }

    private func errorCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            cardTitle("Error")
            Text(message)
                .foregroundStyle(.white.opacity(0.82))
        }
        .cardStyle(borderColor: Color.red.opacity(0.35))
    }

    private func sliderRow(title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .foregroundStyle(.white)
                Spacer()
                Text(value.wrappedValue, format: .number.precision(.fractionLength(1)))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
            }

            Slider(value: value, in: range, step: 0.5)
                .tint(.cyan)
        }
        .padding(12)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    private func actionButton(title: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
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

    private func cardTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.62))
            .tracking(1.2)
    }

    private var liveHoldBinding: Binding<Bool> {
        Binding(
            get: { viewModel.liveHoldEnabled },
            set: { newValue in
                viewModel.setLiveHoldEnabled(newValue)
            }
        )
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
