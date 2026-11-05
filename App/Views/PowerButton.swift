import SwiftUI

/// Главная кнопка: 7 состояний, у каждого своё движение.
/// Выключено — нейтральная; подключаемся — крутится янтарная дуга; подключено — янтарь
/// растекается из центра, расходятся 2 волны, «дышит» свечение; ждём интернет — пунктир.
struct PowerButton: View {
    let state: PowerState
    /// Увеличение — встряхнуть кнопку (ошибка, подписка закончилась).
    let shake: Int
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var ripple = 0
    @State private var complete = 0
    @State private var fail = 0

    private var filled: Bool { state == .connected || state == .switching || state == .waiting }
    private var live: Bool { state == .connected || state == .switching }
    private var spinning: Bool { state == .connecting || state == .switching }

    var body: some View {
        ZStack {
            glow
            if !reduceMotion {
                RippleRing(trigger: ripple, delay: 0)
                RippleRing(trigger: ripple, delay: 0.12)
            }
            ring
            Button(action: action) { sphere }
                .buttonStyle(PressScaleStyle(scale: 0.93))
                .keyframeAnimator(initialValue: 0.0, trigger: shake) { content, x in
                    content.offset(x: reduceMotion ? 0 : x)
                } keyframes: { _ in
                    KeyframeTrack {
                        CubicKeyframe(-9, duration: 0.07)
                        CubicKeyframe(9, duration: 0.08)
                        CubicKeyframe(-7, duration: 0.08)
                        CubicKeyframe(6, duration: 0.08)
                        CubicKeyframe(-3, duration: 0.07)
                        CubicKeyframe(0, duration: 0.07)
                    }
                }
                .accessibilityLabel(accessibilityTitle)
        }
        .frame(width: 198, height: 198)
        .onChange(of: state) { old, new in
            if new == .connected && (old == .connecting || old == .switching) {
                complete += 1
                if old == .connecting { ripple += 1 }
            }
            if new == .failed { fail += 1 }
        }
    }

    private var accessibilityTitle: String {
        switch state {
        case .off, .failed: return "Включить VPN"
        case .expired: return "Подписка закончилась"
        default: return "Выключить VPN"
        }
    }

    // MARK: Свечение за кнопкой

    private var glow: some View {
        let strength = scheme == .dark ? 0.42 : 0.30
        return Circle()
            .fill(RadialGradient(colors: [Theme.tint.opacity(strength), Theme.tint.opacity(0.12), .clear],
                                 center: .center, startRadius: 0, endRadius: 150))
            .frame(width: 300, height: 300)
            .phaseAnimator(live && !reduceMotion ? [false, true] : [false]) { content, up in
                content
                    .scaleEffect(up ? 1.07 : 1)
                    .opacity(up ? 1 : 0.85)
            } animation: { _ in .easeInOut(duration: 2.1) }
            .opacity(live ? 1 : (state == .waiting ? 0.35 : 0))
            .animation(.easeInOut(duration: 0.7), value: state)
            .allowsHitTesting(false)
    }

    // MARK: Кольцо загрузки

    private var ring: some View {
        ZStack {
            Circle().stroke(Theme.fill, lineWidth: 3.5)
            if spinning {
                SpinningArc(period: 1.05, color: Theme.tint)
                    .transition(.opacity)
            } else if state == .waiting {
                SpinningArc(period: 9, color: Theme.label3, dashed: true)
                    .transition(.opacity)
            }
            // Дуга замыкается в круг и гаснет; при ошибке — красная вспышка.
            Circle().stroke(Theme.tint, lineWidth: 3.5)
                .keyframeAnimator(initialValue: 0.0, trigger: complete) { c, v in c.opacity(v) } keyframes: { _ in
                    KeyframeTrack {
                        LinearKeyframe(1, duration: 0.12)
                        LinearKeyframe(1, duration: 0.25)
                        CubicKeyframe(0, duration: 0.45)
                    }
                }
            Circle().stroke(Theme.red, lineWidth: 3.5)
                .keyframeAnimator(initialValue: 0.0, trigger: fail) { c, v in c.opacity(v) } keyframes: { _ in
                    KeyframeTrack {
                        LinearKeyframe(1, duration: 0.1)
                        LinearKeyframe(1, duration: 0.45)
                        CubicKeyframe(0, duration: 0.5)
                    }
                }
        }
        .frame(width: 184, height: 184)
        .opacity(spinning || state == .waiting ? 1 : 0.001)
        .animation(.easeOut(duration: 0.35), value: state)
        .allowsHitTesting(false)
    }

    // MARK: Шар

    private var sphere: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Theme.sphereTop, Theme.sphereMid, Theme.sphereBottom],
                                     center: UnitPoint(x: 0.5, y: 0.27), startRadius: 0, endRadius: 112))
                .overlay(Circle().strokeBorder(LinearGradient(colors: [Theme.sphereHighlight, .clear], startPoint: .top, endPoint: .center), lineWidth: 1))
                .shadow(color: live ? Theme.tintDeep.opacity(0.75) : Theme.sphereShadow,
                        radius: live ? 28 : 25, y: 20)

            Circle()
                .fill(RadialGradient(colors: [Theme.tintLight, Theme.tint, Theme.tintDeep],
                                     center: UnitPoint(x: 0.5, y: 0.24), startRadius: 0, endRadius: 104))
                .overlay(Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .clear], startPoint: .top, endPoint: .center), lineWidth: 1.5))
                .scaleEffect(filled ? 1 : 0.02)
                .opacity(filled ? (state == .waiting ? 0.38 : 1) : 0)
                .animation(reduceMotion ? .easeInOut(duration: 0.3) : .spring(response: 0.55, dampingFraction: 0.9), value: filled)
                .animation(.easeInOut(duration: 0.4), value: state == .waiting)

            Image(systemName: "power")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(iconColor)
                .modifier(PulseModifier(active: state == .connecting && !reduceMotion))
                .animation(.easeInOut(duration: 0.45), value: state)
        }
        .frame(width: 152, height: 152)
        .contentShape(Circle())
    }

    private var iconColor: Color {
        switch state {
        case .connected, .switching: return Theme.onTint
        case .waiting: return Theme.label
        case .connecting: return Theme.ink
        case .expired: return Theme.label3
        case .off, .failed: return Theme.iconOff
        }
    }
}

/// Дуга 1/5 круга, крутится с постоянной скоростью; dashed — пунктирное кольцо ожидания.
struct SpinningArc: View {
    let period: Double
    let color: Color
    var dashed = false

    var body: some View {
        TimelineView(.animation(minimumInterval: dashed ? 0.05 : nil)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let angle = (t.truncatingRemainder(dividingBy: period) / period) * 360
            Group {
                if dashed {
                    Circle().stroke(color, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, dash: [3, 13.3]))
                } else {
                    Circle().trim(from: 0, to: 0.2)
                        .stroke(color, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                }
            }
            .rotationEffect(.degrees(angle))
        }
    }
}

/// Волна от кнопки в момент подключения: расходится до 195% и гаснет.
private struct RippleRing: View {
    let trigger: Int
    let delay: Double

    struct Value {
        var scale: CGFloat = 1
        var opacity: Double = 0
    }

    var body: some View {
        Circle()
            .stroke(Theme.tint, lineWidth: 2)
            .frame(width: 152, height: 152)
            .keyframeAnimator(initialValue: Value(), trigger: trigger) { content, v in
                content.scaleEffect(v.scale).opacity(v.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    LinearKeyframe(1, duration: max(0.001, delay))
                    CubicKeyframe(1.95, duration: 1.0)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(0, duration: max(0.001, delay))
                    LinearKeyframe(0.7, duration: 0.02)
                    CubicKeyframe(0, duration: 1.0)
                }
            }
            .allowsHitTesting(false)
    }
}
