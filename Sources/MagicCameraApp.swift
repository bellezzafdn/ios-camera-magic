import SwiftUI
import AVFoundation
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

@main
struct MagicCameraApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var engine = CameraMagicEngine()

    var body: some Scene {
        WindowGroup {
            CameraView(engine: engine)
                .preferredColorScheme(.dark)
                .statusBar(hidden: true)
                .onChange(of: scenePhase) { newPhase in
                    switch newPhase {
                    case .active:
                        engine.handleAppDidBecomeActive()
                    case .inactive, .background:
                        engine.handleAppWillResignActive()
                    @unknown default:
                        break
                    }
                }
        }
    }
}

// MARK: - Generatore vettoriale ad alta risoluzione della carta (Nessun file esterno richiesto)
enum CardTextureBuilder {
    static func makeSixOfClubsCIImage() -> CIImage? {
        // Se l'utente ha inserito un file "card.jpg" nel bundle, usa quello; altrimenti disegna il 6 di Fiori nativo
        if let url = Bundle.main.url(forResource: "card", withExtension: "jpg"),
           let customCI = CIImage(contentsOf: url) {
            return customCI.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.6])
                .cropped(to: customCI.extent)
        }

        let size = CGSize(width: 630, height: 880)
        let renderer = UIGraphicsImageRenderer(size: size)

        let uiImage = renderer.image { ctx in
            let cgCtx = ctx.cgContext

            // Base cartoncino bianco puro (verrà tinto dinamicamente dal campionatore ambientale)
            let cardRect = CGRect(origin: .zero, size: size)
            let path = UIBezierPath(roundedRect: cardRect, cornerRadius: 34)
            UIColor(white: 0.99, alpha: 1.0).setFill()
            path.fill()

            let blackClub = UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)

            // Funzione per disegnare l'indice "6 ♣" negli angoli
            func drawCornerIndex(upsideDown: Bool) {
                cgCtx.saveGState()
                if upsideDown {
                    cgCtx.translateBy(x: size.width, y: size.height)
                    cgCtx.rotate(by: .pi)
                }

                let numFont = UIFont.systemFont(ofSize: 76, weight: .bold)
                let suitFont = UIFont.systemFont(ofSize: 60, weight: .regular)

                let numAttr: [NSAttributedString.Key: Any] = [.font: numFont, .foregroundColor: blackClub]
                let suitAttr: [NSAttributedString.Key: Any] = [.font: suitFont, .foregroundColor: blackClub]

                ("6" as NSString).draw(at: CGPoint(x: 36, y: 28), withAttributes: numAttr)
                ("♣︎" as NSString).draw(at: CGPoint(x: 34, y: 102), withAttributes: suitAttr)
                cgCtx.restoreGState()
            }

            drawCornerIndex(upsideDown: false)
            drawCornerIndex(upsideDown: true)

            // Funzione per disegnare i 6 semi centrali standard
            func drawPip(center: CGPoint, inverted: Bool) {
                cgCtx.saveGState()
                cgCtx.translateBy(x: center.x, y: center.y)
                if inverted { cgCtx.rotate(by: .pi) }

                let pipFont = UIFont.systemFont(ofSize: 148, weight: .regular)
                let attr: [NSAttributedString.Key: Any] = [.font: pipFont, .foregroundColor: blackClub]
                let str = "♣︎" as NSString
                let strSize = str.size(withAttributes: attr)
                str.draw(at: CGPoint(x: -strSize.width / 2, y: -strSize.height / 2), withAttributes: attr)
                cgCtx.restoreGState()
            }

            let leftX: CGFloat = 195
            let rightX: CGFloat = size.width - 195
            let topY: CGFloat = 195
            let midY: CGFloat = size.height / 2
            let botY: CGFloat = size.height - 195

            // 2 in alto (dritti), 2 al centro (dritti), 2 in basso (capovolti)
            drawPip(center: CGPoint(x: leftX, y: topY), inverted: false)
            drawPip(center: CGPoint(x: rightX, y: topY), inverted: false)
            drawPip(center: CGPoint(x: leftX, y: midY), inverted: false)
            drawPip(center: CGPoint(x: rightX, y: midY), inverted: false)
            drawPip(center: CGPoint(x: leftX, y: botY), inverted: true)
            drawPip(center: CGPoint(x: rightX, y: botY), inverted: true)
        }

        guard let cgImg = uiImage.cgImage else { return nil }
        let rawCI = CIImage(cgImage: cgImg)
        // Morbidezza ottica per fondersi coi pixel reali della fotocamera frontale
        return rawCI.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.75])
            .cropped(to: rawCI.extent)
    }
}

// MARK: - Motore Fotocamera + Vision + Campionamento Automatico Bordo Bianco
final class CameraMagicEngine: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var currentFrame: CGImage?
    @Published var startupBlurActive: Bool = true

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue", qos: .userInteractive)
    private let videoQueue = DispatchQueue(label: "camera.video.queue", qos: .userInteractive)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private var baseCardCI: CIImage?
    private var trickCompleted = false
    private var firstLockTime: Date?
    private var lastLockTime: Date?
    private var launchTimestamp = Date()

    // Stato angoli e colore ambientale campionati
    private var currentQuad: [CGPoint]? // [tl, tr, br, bl]
    private var smoothedRGB: (r: CGFloat, g: CGFloat, b: CGFloat) = (0.86, 0.85, 0.82)
    private var hasCalibratedColor = false

    override init() {
        super.init()
        self.baseCardCI = CardTextureBuilder.makeSixOfClubsCIImage()
        configureSession()
    }

    // Chiamato quando torni alla vera schermata Home: riattiva il velo di sfocatura per la prossima apertura
    func handleAppWillResignActive() {
        DispatchQueue.main.async {
            self.startupBlurActive = true
        }
    }

    // Chiamato quando tocchi l'icona Fotocamera dalla vera Home
    func handleAppDidBecomeActive() {
        launchTimestamp = Date()
        trickCompleted = false
        firstLockTime = nil
        lastLockTime = nil
        currentQuad = nil
        hasCalibratedColor = false

        DispatchQueue.main.async {
            self.startupBlurActive = true
        }

        sessionQueue.async {
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }

        // Timeout di sicurezza (0.42s): se apri l'app senza nessuna carta davanti, toglie comunque la sfocatura come la vera Fotocamera
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            if self.startupBlurActive {
                withAnimation(.easeOut(duration: 0.18)) {
                    self.startupBlurActive = false
                }
            }
        }
    }

    func triggerVanish() {
        guard !trickCompleted else { return }
        trickCompleted = true
        currentQuad = nil
        DispatchQueue.main.async {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    func resetTrick() {
        trickCompleted = false
        firstLockTime = nil
        lastLockTime = nil
        currentQuad = nil
        DispatchQueue.main.async {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        }
    }

    private func configureSession() {
        sessionQueue.async {
            self.session.beginConfiguration()
            self.session.sessionPreset = .hd1280x720

            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                  let input = try? AVCaptureDeviceInput(device: device),
                  self.session.canAddInput(input) else {
                self.session.commitConfiguration()
                return
            }
            self.session.addInput(input)

            // Configura 60 FPS per azzerare il motion lag
            if let format = device.formats.first(where: {
                $0.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= 60 })
            }) {
                try? device.lockForConfiguration()
                device.activeFormat = format
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 60)
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 60)
                device.unlockForConfiguration()
            }

            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: self.videoQueue)

            if self.session.canAddOutput(output) {
                self.session.addOutput(output)
            }

            if let conn = output.connection(with: .video) {
                conn.videoOrientation = .portrait
                conn.isVideoMirrored = true
            }

            self.session.commitConfiguration()
            self.session.startRunning()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let frameCI = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = frameCI.extent

        if trickCompleted {
            outputFrame(frameCI, extent: extent)
            return
        }

        let rectRequest = VNDetectRectanglesRequest()
        rectRequest.minimumAspectRatio = 0.55
        rectRequest.maximumAspectRatio = 0.85
        rectRequest.minimumSize = 0.10
        rectRequest.minimumConfidence = 0.70
        rectRequest.maximumObservations = 1

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try? handler.perform([rectRequest])

        let now = Date()

        if let obs = rectRequest.results?.first {
            if firstLockTime == nil { firstLockTime = now }
            lastLockTime = now

            let composited = applyCardOverlay(on: frameCI, observation: obs, extent: extent)
            outputFrame(composited, extent: extent)

            // SBLOCCO SINCRONIZZATO: appena il sensore ha stabilizzato l'esposizione (~0.18s dall'apertura)
            // e la carta virtuale è già disegnata e calibrata sul frame, rimuove la sfocatura iniziale!
            if startupBlurActive && now.timeIntervalSince(launchTimestamp) > 0.18 {
                DispatchQueue.main.async {
                    if self.startupBlurActive {
                        withAnimation(.easeOut(duration: 0.16)) {
                            self.startupBlurActive = false
                        }
                    }
                }
            }
        } else {
            // Verifica se l'utente ha passato la mano tra il telefono e la carta per farla sparire
            if let first = firstLockTime, let last = lastLockTime {
                let shownDuration = last.timeIntervalSince(first)
                let missingDuration = now.timeIntervalSince(last)

                if shownDuration > 0.55 && missingDuration > 0.09 {
                    triggerVanish()
                } else if missingDuration > 0.25 {
                    firstLockTime = nil
                    currentQuad = nil
                }
            }
            outputFrame(frameCI, extent: extent)
        }
    }

    private func applyCardOverlay(on frameCI: CIImage, observation: VNRectangleObservation, extent: CGRect) -> CIImage {
        guard let cardCI = baseCardCI else { return frameCI }
        let w = extent.width
        let h = extent.height

        var rawCorners = [
            CGPoint(x: observation.topLeft.x * w, y: observation.topLeft.y * h),
            CGPoint(x: observation.topRight.x * w, y: observation.topRight.y * h),
            CGPoint(x: observation.bottomRight.x * w, y: observation.bottomRight.y * h),
            CGPoint(x: observation.bottomLeft.x * w, y: observation.bottomLeft.y * h)
        ]

        // Assicura che il lato superiore [0]-[1] sia sempre il lato corto della carta (evita rotazioni di 90°)
        let d01 = hypot(rawCorners[1].x - rawCorners[0].x, rawCorners[1].y - rawCorners[0].y)
        let d12 = hypot(rawCorners[2].x - rawCorners[1].x, rawCorners[2].y - rawCorners[1].y)
        if d01 > d12 {
            rawCorners = [rawCorners[3], rawCorners[0], rawCorners[1], rawCorners[2]]
        }

        // Espande del 2.8% per coprire completamente i bordi della carta fisica sottostante
        let cx = (rawCorners[0].x + rawCorners[1].x + rawCorners[2].x + rawCorners[3].x) * 0.25
        let cy = (rawCorners[0].y + rawCorners[1].y + rawCorners[2].y + rawCorners[3].y) * 0.25
        rawCorners = rawCorners.map { p in
            CGPoint(x: cx + (p.x - cx) * 1.028, y: cy + (p.y - cy) * 1.028)
        }

        // Smoothing temporale reattivo
        if let prev = currentQuad {
            // Se la carta si è ruotata, mantiene l'ordine coerente con il frame precedente
            let distNormal = hypot(rawCorners[0].x - prev[0].x, rawCorners[0].y - prev[0].y)
            let distFlipped = hypot(rawCorners[2].x - prev[0].x, rawCorners[2].y - prev[0].y)
            if distFlipped < distNormal {
                rawCorners = [rawCorners[2], rawCorners[3], rawCorners[0], rawCorners[1]]
            }

            let alpha: CGFloat = 0.75
            rawCorners = zip(prev, rawCorners).map { oldP, newP in
                CGPoint(x: oldP.x * (1 - alpha) + newP.x * alpha,
                        y: oldP.y * (1 - alpha) + newP.y * alpha)
            }
        }
        currentQuad = rawCorners

        // CAMPIONAMENTO AUTOMATICO DEL BORDO BIANCO DELLA CARTA FISICA:
        // Estrae la carta fisica ridotta su una griglia 12x12 e prende l'88° percentile più luminoso
        // (che corrisponde sempre al cartoncino bianco reale sotto la luce della stanza, ignorando i disegni interni).
        samplePhysicalCardWhitePoint(from: frameCI, corners: rawCorners)

        let tonedCard = cardCI.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: smoothedRGB.r, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: smoothedRGB.g, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: smoothedRGB.b, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.98)
        ])

        let perspective = CIFilter.perspectiveTransform()
        perspective.inputImage = tonedCard
        perspective.topLeft = rawCorners[0]
        perspective.topRight = rawCorners[1]
        perspective.bottomRight = rawCorners[2]
        perspective.bottomLeft = rawCorners[3]

        guard let warped = perspective.outputImage else { return frameCI }
        return warped.composited(over: frameCI).cropped(to: extent)
    }

    private func samplePhysicalCardWhitePoint(from frameCI: CIImage, corners: [CGPoint]) {
        let minX = max(0, corners.map(\.x).min() ?? 0)
        let maxX = min(frameCI.extent.width, corners.map(\.x).max() ?? 0)
        let minY = max(0, corners.map(\.y).min() ?? 0)
        let maxY = min(frameCI.extent.height, corners.map(\.y).max() ?? 0)

        let boxWidth = maxX - minX
        let boxHeight = maxY - minY
        guard boxWidth > 20, boxHeight > 20 else { return }

        let gridW = 8
        let gridH = 8
        let scaleFilter = CIFilter.lanczosScaleTransform()
        scaleFilter.inputImage = frameCI.cropped(to: CGRect(x: minX, y: minY, width: boxWidth, height: boxHeight))
            .transformed(by: CGAffineTransform(translationX: -minX, y: -minY))
        scaleFilter.scale = Float(CGFloat(gridH) / boxHeight)
        scaleFilter.aspectRatio = Float((CGFloat(gridW) / boxWidth) / (CGFloat(gridH) / boxHeight))

        guard let tinyCI = scaleFilter.outputImage else { return }

        var bitmap = [UInt8](repeating: 0, count: gridW * gridH * 4)
        ciContext.render(
            tinyCI,
            toBitmap: &bitmap,
            rowBytes: gridW * 4,
            bounds: CGRect(x: 0, y: 0, width: gridW, height: gridH),
            format: .RGBA8,
            colorSpace: nil
        )

        struct Sample {
            let r: CGFloat
            let g: CGFloat
            let b: CGFloat
            let luma: CGFloat
        }

        var samples: [Sample] = []
        samples.reserveCapacity(gridW * gridH)

        for i in 0..<(gridW * gridH) {
            let idx = i * 4
            let r = CGFloat(bitmap[idx]) / 255.0
            let g = CGFloat(bitmap[idx + 1]) / 255.0
            let b = CGFloat(bitmap[idx + 2]) / 255.0
            let luma = 0.299 * r + 0.587 * g + 0.114 * b
            samples.append(Sample(r: r, g: g, b: b, luma: luma))
        }

        // Ordina per luminosità e prende i pixel tra il 75° e il 95° percentile (il vero cartoncino bianco della carta)
        samples.sort { $0.luma < $1.luma }
        let startIdx = Int(Double(samples.count) * 0.72)
        let endIdx = max(startIdx + 1, Int(Double(samples.count) * 0.94))
        let whiteSamples = samples[startIdx..<endIdx]

        let count = CGFloat(whiteSamples.count)
        let avgR = min(1.0, max(0.22, whiteSamples.reduce(0) { $0 + $1.r } / count))
        let avgG = min(1.0, max(0.22, whiteSamples.reduce(0) { $0 + $1.g } / count))
        let avgB = min(1.0, max(0.22, whiteSamples.reduce(0) { $0 + $1.b } / count))

        if !hasCalibratedColor {
            smoothedRGB = (avgR, avgG, avgB)
            hasCalibratedColor = true
        } else {
            let blend: CGFloat = 0.25
            smoothedRGB = (
                r: smoothedRGB.r * (1 - blend) + avgR * blend,
                g: smoothedRGB.g * (1 - blend) + avgG * blend,
                b: smoothedRGB.b * (1 - blend) + avgB * blend
            )
        }
    }

    private func outputFrame(_ image: CIImage, extent: CGRect) {
        if let cgImg = ciContext.createCGImage(image, from: extent) {
            DispatchQueue.main.async {
                self.currentFrame = cgImg
            }
        }
    }
}

// MARK: - Interfaccia Fotocamera iOS con Sfocatura Nativa Sincronizzata
struct CameraView: View {
    @ObservedObject var engine: CameraMagicEngine

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Feed Video Live + Sfocatura stile apertura Fotocamera iOS
            if let frame = engine.currentFrame {
                Image(decorative: frame, scale: 1.0, orientation: .up)
                    .resizable()
                    .scaledToFill()
                    .frame(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
                    .blur(radius: engine.startupBlurActive ? 26 : 0)
                    .clipped()
                    .ignoresSafeArea()
            }

            // Controlli UI Fotocamera iOS
            VStack(spacing: 0) {
                // Barra Superiore (Doppio tap segreto per resettare senza chiudere l'app)
                HStack {
                    TopIcon(symbol: "bolt.fill")
                    Spacer()
                    TopIcon(symbol: "chevron.up")
                    Spacer()
                    TopIcon(symbol: "livephoto")
                }
                .padding(.horizontal, 24)
                .padding(.top, 54)
                .padding(.bottom, 14)
                .background(Color.black.opacity(0.88))
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    engine.resetTrick()
                }

                Spacer()

                // Indicatore Zoom 1x
                Text("1x")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Color(red: 1.0, green: 0.84, blue: 0.04))
                    .frame(width: 38, height: 38)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
                    .padding(.bottom, 18)

                // Barra Inferiore (Tocca in basso per sparizione manuale d'emergenza)
                VStack(spacing: 22) {
                    HStack(spacing: 22) {
                        Text("CINEMA")
                        Text("VIDEO")
                        Text("FOTO").foregroundColor(Color(red: 1.0, green: 0.84, blue: 0.04))
                        Text("RITRATTO")
                        Text("PANO")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))

                    HStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(white: 0.14))
                            .frame(width: 48, height: 48)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.15), lineWidth: 1))

                        Spacer()

                        ZStack {
                            Circle()
                                .stroke(Color.white, lineWidth: 4)
                                .frame(width: 74, height: 74)
                            Circle()
                                .fill(Color.white)
                                .frame(width: 60, height: 60)
                        }

                        Spacer()

                        Circle()
                            .fill(Color.white.opacity(0.14))
                            .frame(width: 48, height: 48)
                            .overlay(
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundColor(.white)
                            )
                    }
                    .padding(.horizontal, 34)
                }
                .padding(.top, 14)
                .padding(.bottom, 42)
                .background(Color.black.opacity(0.92))
                .contentShape(Rectangle())
                .onTapGesture {
                    engine.triggerVanish()
                }
            }
            .ignoresSafeArea()
        }
    }
}

struct TopIcon: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 30, height: 30)
            .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1.5))
    }
}
