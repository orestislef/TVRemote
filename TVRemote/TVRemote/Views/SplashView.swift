import SwiftUI

struct SplashView: View {
    @State private var iconScale: CGFloat = 0.5
    @State private var iconOpacity: Double = 0
    @State private var ringScale: CGFloat = 0.3
    @State private var ringOpacity: Double = 0
    @State private var titleOffset: CGFloat = 30
    @State private var titleOpacity: Double = 0
    @State private var pulseScale: CGFloat = 1.0
    @State private var waveScale: CGFloat = 0.5
    @State private var waveOpacity: Double = 0

    let onFinished: () -> Void

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [Color(red: 0, green: 0, blue: 0.5), .black],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                ZStack {
                    // Expanding wave rings
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .stroke(Color.white.opacity(0.15), lineWidth: 2)
                            .scaleEffect(waveScale + CGFloat(i) * 0.3)
                            .opacity(waveOpacity * (1 - Double(i) * 0.3))
                    }
                    .frame(width: 160, height: 160)

                    // Outer ring
                    Circle()
                        .stroke(
                            AngularGradient(
                                colors: [.blue, .cyan, .blue],
                                center: .center
                            ),
                            lineWidth: 3
                        )
                        .frame(width: 130, height: 130)
                        .scaleEffect(ringScale)
                        .opacity(ringOpacity)
                        .rotationEffect(.degrees(ringOpacity * 360))

                    // Icon
                    Image(systemName: "tv.and.mediabox")
                        .font(.system(size: 52, weight: .medium))
                        .foregroundStyle(.white)
                        .scaleEffect(iconScale)
                        .opacity(iconOpacity)
                        .scaleEffect(pulseScale)
                }

                // Title
                VStack(spacing: 8) {
                    Text("TVRemote")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("Control your TV from anywhere")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .offset(y: titleOffset)
                .opacity(titleOpacity)

                Spacer()
                Spacer()
            }
        }
        .onAppear {
            runAnimation()
        }
    }

    private func runAnimation() {
        // Phase 1: Icon appears
        withAnimation(.spring(duration: 0.6, bounce: 0.4)) {
            iconScale = 1.0
            iconOpacity = 1.0
        }

        // Phase 2: Ring expands
        withAnimation(.easeOut(duration: 0.5).delay(0.2)) {
            ringScale = 1.0
            ringOpacity = 1.0
        }

        // Phase 3: Title slides up
        withAnimation(.spring(duration: 0.5, bounce: 0.3).delay(0.4)) {
            titleOffset = 0
            titleOpacity = 1.0
        }

        // Phase 4: Wave rings pulse out
        withAnimation(.easeOut(duration: 0.8).delay(0.5)) {
            waveScale = 1.2
            waveOpacity = 1.0
        }

        // Phase 5: Gentle pulse on icon
        withAnimation(.easeInOut(duration: 0.6).delay(0.7).repeatCount(2, autoreverses: true)) {
            pulseScale = 1.08
        }

        // Dismiss after animation completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            onFinished()
        }
    }
}
