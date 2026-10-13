import SwiftUI
import UIKit

@MainActor
struct CameraView: View {
    @StateObject private var camera = CameraController()
    @State private var pinchStartZoom: CGFloat?
    @State private var pinchInvalidated = false
    @State private var isSliderEditing = false
    @State private var isExtendedZoomEnabled = false
    @State private var needsNormalZoomClamp = false
    @GestureState private var isPinching = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    private let warmWhite = Color(red: 0.97, green: 0.96, blue: 0.91)
    private let amber = Color(red: 0.96, green: 0.75, blue: 0.43)
    private let muted = Color(red: 0.65, green: 0.67, blue: 0.67)

    var body: some View {
        GeometryReader { geometry in
            let reservedHeight: CGFloat = 88 + 84 + 36 + 18 + 8
            // Use the full available width whenever height permits. Constrain both
            // dimensions to preserve the complete 3:4 portrait frame without cropping.
            let previewWidth = max(0, min(geometry.size.width - 8, (geometry.size.height - reservedHeight) * 3 / 4))

            VStack(spacing: 6) {
                preview
                    .frame(width: previewWidth, height: previewWidth * 4 / 3)
                    .frame(maxWidth: .infinity)

                zoomControls
                    .frame(height: 88)

                shutterControls
                    .frame(height: 84)

                status
                    .frame(height: 36, alignment: .top)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Color(red: 0.055, green: 0.065, blue: 0.067).ignoresSafeArea())
        .foregroundStyle(warmWhite)
        .preferredColorScheme(.dark)
        .onAppear { camera.activate() }
        .onDisappear {
            leaveExtendedZoom()
            isSliderEditing = false
            camera.deactivate()
        }
        .onChange(of: scenePhase) { _, phase in
            invalidatePinch()
            isSliderEditing = false
            if phase == .active {
                camera.activate()
                reconcileNormalZoomRange()
            } else {
                leaveExtendedZoom()
                camera.deactivate()
            }
        }
        .onChange(of: camera.currentDevice?.uniqueID) { _, _ in
            invalidatePinch()
            isSliderEditing = false
            isExtendedZoomEnabled = false
            needsNormalZoomClamp = false
        }
        .onChange(of: canZoom) { _, enabled in
            if !enabled {
                invalidatePinch()
                isSliderEditing = false
            }
        }
        .onChange(of: canSetZoom) { _, enabled in
            if enabled { reconcileNormalZoomRange() }
        }
        .onChange(of: camera.state.zoomFactor) { _, _ in
            reconcileNormalZoomRange()
        }
        .onChange(of: normalZoomUpperBound) { _, _ in
            reconcileNormalZoomRange()
        }
        .onChange(of: isPinching) { _, active in
            // GestureState also resets when iOS cancels an unfinished gesture.
            if !active {
                pinchStartZoom = nil
                pinchInvalidated = false
            }
        }
        .alert("カメラ", isPresented: errorIsPresented) {
            if camera.state.needsSettings {
                Button("設定を開く") {
                    camera.clearError()
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
            }
            Button("閉じる", role: .cancel) { camera.clearError() }
        } message: {
            Text(camera.state.errorMessage ?? "")
        }
    }

    private var cameraSwitchButton: some View {
        Button {
            invalidatePinch()
            isSliderEditing = false
            isExtendedZoomEnabled = false
            needsNormalZoomClamp = false
            camera.switchCamera()
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath.camera")
                .font(.system(size: 20, weight: .regular))
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.56), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canSwitchCamera)
        .opacity(canSwitchCamera ? 1 : 0.35)
        .accessibilityLabel("前後のカメラを切り替え")
        .accessibilityHint("現在は\(camera.state.cameraName)です")
    }

    private var preview: some View {
        ZStack(alignment: .topTrailing) {
            previewImage
            cameraSwitchButton
                .padding(10)
        }
        .contentShape(Rectangle())
        .gesture(zoomGesture)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.09), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private var previewImage: some View {
        ZStack {
            Color.black

            CameraPreview(
                session: camera.session,
                device: camera.currentDevice,
                isFrontCamera: camera.state.isFrontCamera
            )

            if !camera.state.isRunning {
                VStack(spacing: 12) {
                    Image(systemName: "camera")
                        .font(.system(size: 34, weight: .ultraLight))
                    #if targetEnvironment(simulator)
                    Text("撮影は iPhone 実機で")
                        .font(.subheadline.weight(.medium))
                    Text("シミュレータではカメラを使用できません")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(muted)
                    #else
                    Text(camera.state.isConfigured ? "カメラを再開しています" : "カメラを準備しています")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(muted)
                    #endif
                }
                .padding(20)
            }

            VStack {
                Spacer()
                Text(camera.state.silenceStatus)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(warmWhite.opacity(0.9))
                    .lineLimit(2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.56), in: Capsule())
                    .padding(10)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(previewAccessibilityLabel)
    }

    private var zoomControls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(zoomPresets, id: \.self) { factor in
                    Button {
                        guard canSetZoom else { return }
                        invalidatePinch()
                        if factor == 1 {
                            camera.resetZoom()
                        } else {
                            applyZoom(factor)
                        }
                    } label: {
                        Text("\(zoomText(factor))×")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(abs(camera.state.zoomFactor - factor) < 0.01 ? amber : warmWhite)
                            .frame(width: 44, height: 44)
                            .background {
                                if abs(camera.state.zoomFactor - factor) < 0.01 {
                                    Circle().fill(amber.opacity(0.14)).padding(4)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSetZoom || (needsNormalZoomClamp && factor != 1))
                    .accessibilityLabel(factor == 1 ? "ズームを1倍に戻す" : "ズームを\(zoomText(factor))倍にする")
                }

                Spacer(minLength: 0)

                if canExtendZoomRange {
                    Button {
                        guard canZoom else { return }
                        invalidatePinch()
                        isSliderEditing = false
                        if isExtendedZoomEnabled {
                            leaveExtendedZoom()
                        } else {
                            isExtendedZoomEnabled = true
                            needsNormalZoomClamp = false
                        }
                    } label: {
                        VStack(spacing: 2) {
                            Text(needsNormalZoomClamp ? "戻しています" : (isExtendedZoomEnabled ? "通常に戻す" : "さらに拡大"))
                                .font(.system(size: 12, weight: .medium))
                            Text("\(zoomText(isExtendedZoomEnabled || needsNormalZoomClamp ? normalZoomUpperBound : hardwareZoomUpperBound))×まで")
                                .font(.system(size: 10, design: .monospaced))
                        }
                        .foregroundStyle(amber)
                        .frame(width: 80, height: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canZoom)
                    .accessibilityLabel(needsNormalZoomClamp
                        ? "通常のズーム範囲に戻しています"
                        : (isExtendedZoomEnabled ? "通常のズーム範囲に戻す" : "さらに拡大する"))
                    .accessibilityHint(isExtendedZoomEnabled
                        ? "\(zoomText(normalZoomUpperBound))倍を超えている場合は、この倍率まで戻します"
                        : "最大\(zoomText(hardwareZoomUpperBound))倍まで調整できます。拡大すると画質や解像度が下がる場合があります")
                }
            }

            HStack(spacing: 8) {
                Text("\(zoomFactorText)×")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(amber)
                    .frame(width: 64, height: 44)
                    .minimumScaleFactor(0.75)
                    .accessibilityLabel("現在のズーム倍率")
                    .accessibilityValue("\(zoomFactorText)倍")

                Slider(value: logarithmicZoomBinding, in: 0...1, onEditingChanged: { editing in
                    invalidatePinch()
                    isSliderEditing = editing
                })
                .tint(amber)
                .frame(height: 44)
                .disabled(!canZoom)
                .accessibilityLabel("ズーム倍率の調整")
                .accessibilityValue("\(zoomFactorText)倍")
                .accessibilityHint("\(zoomText(zoomLowerBound))倍から\(zoomText(activeZoomUpperBound))倍まで調整できます")
                .accessibilityAdjustableAction { direction in
                    guard canZoom else { return }
                    invalidatePinch()
                    let step: CGFloat = camera.state.zoomFactor >= 10 ? 1 : 0.25
                    switch direction {
                    case .increment: applyZoom(camera.state.zoomFactor + step)
                    case .decrement: applyZoom(camera.state.zoomFactor - step)
                    @unknown default: break
                    }
                }
            }
        }
        .opacity(canSetZoom ? 1 : 0.45)
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .updating($isPinching) { _, active, _ in active = true }
            .onChanged { value in
                guard canZoom, !isSliderEditing else {
                    pinchStartZoom = nil
                    pinchInvalidated = true
                    return
                }
                guard !pinchInvalidated else { return }
                if pinchStartZoom == nil {
                    pinchStartZoom = camera.state.zoomFactor
                }
                if let start = pinchStartZoom {
                    applyZoom(start * value.magnification)
                }
            }
            .onEnded { value in
                if !pinchInvalidated, let start = pinchStartZoom {
                    applyZoom(start * value.magnification)
                }
                pinchStartZoom = nil
                pinchInvalidated = false
            }
    }

    private func applyZoom(_ factor: CGFloat) {
        guard canZoom, factor.isFinite else { return }
        camera.setZoomFactor(min(max(factor, zoomLowerBound), activeZoomUpperBound))
    }

    private func invalidatePinch() {
        pinchStartZoom = nil
        if isPinching { pinchInvalidated = true }
    }

    private func leaveExtendedZoom() {
        invalidatePinch()
        isExtendedZoomEnabled = false
        reconcileNormalZoomRange()
    }

    private func reconcileNormalZoomRange() {
        guard !isExtendedZoomEnabled else {
            needsNormalZoomClamp = false
            return
        }
        guard camera.state.zoomFactor > normalZoomUpperBound + 0.0001 else {
            needsNormalZoomClamp = false
            return
        }
        needsNormalZoomClamp = true
        if canSetZoom {
            camera.setZoomFactor(normalZoomUpperBound)
        }
    }

    private var logarithmicZoomBinding: Binding<Double> {
        Binding(
            get: {
                let span = log(Double(activeZoomUpperBound / zoomLowerBound))
                guard span > 0 else { return 0 }
                let factor = min(max(camera.state.zoomFactor, zoomLowerBound), activeZoomUpperBound)
                return min(max(log(Double(factor / zoomLowerBound)) / span, 0), 1)
            },
            set: { position in
                guard canZoom else { return }
                invalidatePinch()
                let span = log(Double(activeZoomUpperBound / zoomLowerBound))
                let factor = zoomLowerBound * CGFloat(exp(min(max(position, 0), 1) * span))
                applyZoom(factor)
            }
        )
    }

    private var shutterControls: some View {
        ZStack {
            Button { camera.capture() } label: {
                ZStack {
                    Circle()
                        .strokeBorder(warmWhite.opacity(canCapture ? 0.9 : 0.25), lineWidth: 2)
                        .frame(width: 80, height: 80)
                    Circle()
                        .fill(warmWhite.opacity(canCapture ? 1 : 0.23))
                        .frame(width: 66, height: 66)
                    if camera.state.isBusy {
                        ProgressView()
                            .tint(warmWhite)
                            .scaleEffect(1.15)
                    }
                }
                .frame(width: 88, height: 84)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canCapture)
            .accessibilityLabel(shutterAccessibilityLabel)
            .accessibilityHint("高画質で撮影し、写真ライブラリに保存します。消音処理は常に有効です。消音効果は端末や環境で異なります")

            if camera.pendingSave {
                HStack {
                    Spacer()
                    Button { camera.retrySave() } label: {
                        VStack(spacing: 5) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 20))
                            Text("保存を再試行")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(amber)
                        .frame(width: 82, height: 64)
                        .background(amber.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .disabled(camera.state.isBusy)
                    .accessibilityLabel("撮影済みの写真を保存し直す")
                }
            }
        }
    }

    private var status: some View {
        VStack(spacing: 2) {
            Text(camera.state.message.isEmpty
                ? (camera.state.isRunning ? "撮影できます" : "カメラを準備しています")
                : camera.state.message)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(camera.pendingSave ? amber : muted)
                .multilineTextAlignment(.center)
                .lineLimit(camera.state.isZoomed ? 1 : 2)
                .minimumScaleFactor(0.85)

            if camera.state.isZoomed {
                Text("ズーム中は画質・解像度が下がる場合があります")
                    .font(.system(size: 11))
                    .foregroundStyle(amber)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var canCapture: Bool {
        cameraReadyForInteraction && !needsNormalZoomClamp
    }

    private var canSwitchCamera: Bool {
        camera.state.canSwitchCamera && !camera.state.isBusy && !camera.pendingSave
    }

    private var canZoom: Bool {
        canSetZoom && !needsNormalZoomClamp
    }

    private var cameraReadyForInteraction: Bool {
        camera.state.isRunning && !camera.state.isBusy && !camera.pendingSave
    }

    private var canSetZoom: Bool {
        cameraReadyForInteraction && camera.state.isConfigured && hardwareZoomUpperBound > zoomLowerBound
    }

    private var zoomLowerBound: CGFloat {
        max(1, camera.state.minZoomFactor)
    }

    private var hardwareZoomUpperBound: CGFloat {
        max(zoomLowerBound, camera.state.maxZoomFactor)
    }

    private var normalZoomUpperBound: CGFloat {
        let bound = min(hardwareZoomUpperBound, max(zoomLowerBound, camera.state.systemRecommendedMaxZoomFactor))
        // Match the controller's hundredth-step precision without rounding above its normal limit.
        let reachableBound = (bound * 100).rounded(.down) / 100
        return min(hardwareZoomUpperBound, max(zoomLowerBound, reachableBound))
    }

    private var activeZoomUpperBound: CGFloat {
        isExtendedZoomEnabled ? hardwareZoomUpperBound : normalZoomUpperBound
    }

    private var canExtendZoomRange: Bool {
        hardwareZoomUpperBound > normalZoomUpperBound + 0.0001
    }

    private var zoomPresets: [CGFloat] {
        [1, 2, 5, 10].filter { $0 >= zoomLowerBound && $0 <= activeZoomUpperBound + 0.0001 }
    }

    private var zoomFactorText: String {
        zoomText(camera.state.zoomFactor)
    }

    private func zoomText(_ factor: CGFloat) -> String {
        Double(factor).formatted(.number.precision(.fractionLength(0...2)))
    }

    private var shutterAccessibilityLabel: String {
        return camera.state.isBusy ? "写真を処理しています" : "写真を撮影"
    }

    private var previewAccessibilityLabel: String {
        "カメラプレビュー。\(camera.state.cameraName)。\(camera.state.silenceStatus)。消音効果は端末や環境で異なります"
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { camera.state.errorMessage != nil },
            set: { if !$0 { camera.clearError() } }
        )
    }
}
