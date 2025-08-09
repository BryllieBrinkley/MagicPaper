//
//  ViewController.swift
//  MagicPaper
//
//  Created by Jibryll Brinkley on 4/28/24.
//

import UIKit
import SceneKit
import ARKit
import Vision
import AVFoundation

class ViewController: UIViewController, ARSCNViewDelegate, ARSessionDelegate {
    
    @IBOutlet var sceneView: ARSCNView!
    
    private let visionQueue = DispatchQueue(label: "vision.requests.queue")
    private var currentVideoPlaneNode: SCNNode?
    private var scanButton: UIButton!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Set the view's delegate
        sceneView.delegate = self
        sceneView.session.delegate = self
        
        // Show statistics such as fps and timing information
        sceneView.showsStatistics = true
        
        addScanButton()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        // Create a session configuration
        let configuration = ARWorldTrackingConfiguration()
        
        if let imageToTrack = ARReferenceImage.referenceImages(inGroupNamed: "NewspaperImages", bundle: Bundle.main) {
            configuration.detectionImages = imageToTrack
            configuration.maximumNumberOfTrackedImages  = 1
            print("Images added")
        }
        
        configuration.environmentTexturing = .automatic
        configuration.isAutoFocusEnabled = true
        
        // Run the view's session
        sceneView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        // Pause the view's session
        sceneView.session.pause()
    }
    // MARK: - SceneView Delegate Methods
    
    
    func renderer(_ renderer: any SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        
        let node = SCNNode()
        
        if let imageAnchor = anchor as? ARImageAnchor {
        
            let videoNode = SKVideoNode(fileNamed: "\(imageAnchor.referenceImage.name!).mp4")
            videoNode.play()
            
            let videoScene = SKScene(size: CGSize(width: 720, height: 300))
            videoNode.position = CGPoint(x: videoScene.size.width / 2, y: videoScene.size.height / 2)
            videoNode.yScale = -1.0
            videoScene.addChild(videoNode)
            
            let plane = SCNPlane(width: imageAnchor.referenceImage.physicalSize.width , height: imageAnchor.referenceImage.physicalSize.height)
            plane.firstMaterial?.diffuse.contents = videoScene

            let planeNode = SCNNode(geometry: plane)
            planeNode.eulerAngles.x  = -.pi / 2
            node.addChildNode(planeNode)
        }
        return node
    }
    
    // MARK: - Scan Any Newspaper Photo
    
    private func addScanButton() {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("Scan", for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        button.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.9)
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 8
        button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 18, bottom: 10, right: 18)
        button.addTarget(self, action: #selector(scanTapped), for: .touchUpInside)
        view.addSubview(button)
        
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            button.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16)
        ])
        
        self.scanButton = button
    }
    
    @objc private func scanTapped() {
        scanButton.isEnabled = false
        defer { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.scanButton.isEnabled = true } }
        
        // Capture a snapshot matching the view coordinate space
        let snapshot = sceneView.snapshot()
        guard let cgImage = snapshot.cgImage else { return }
        
        detectRectangleAndOverlayVideo(in: cgImage, viewImageSize: snapshot.size)
    }
    
    private func detectRectangleAndOverlayVideo(in cgImage: CGImage, viewImageSize: CGSize) {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 1
        request.minimumSize = 0.2
        request.minimumAspectRatio = 0.3
        request.quadratureTolerance = 20
        request.minimumConfidence = 0.5
        
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        visionQueue.async {
            do {
                try handler.perform([request])
                guard let observation = request.results?.first as? VNRectangleObservation else {
                    self.performFallbackOverlay()
                    return
                }
                
                // OCR to build a query
                self.recognizeText(in: cgImage) { query in
                    let searchQuery = (query?.isEmpty == false) ? query! : "breaking news"
                    self.fetchVideoURL(for: searchQuery) { url in
                        let videoURL = url ?? URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")!
                        self.placeVideoOnDetectedRectangle(observation: observation, imageSize: viewImageSize, videoURL: videoURL)
                    }
                }
            } catch {
                self.performFallbackOverlay()
            }
        }
    }
    
    private func performFallbackOverlay() {
        // If no rectangle, just place a small plane in front of the camera center
        let fallbackURL = URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")!
        DispatchQueue.main.async {
            guard let currentFrame = self.sceneView.session.currentFrame else { return }
            var translation = matrix_identity_float4x4
            translation.columns.3.z = -0.6 // 60cm in front
            let transform = simd_mul(currentFrame.camera.transform, translation)
            self.placeVideoPlane(at: transform, width: 0.25, height: 0.14, videoURL: fallbackURL)
        }
    }
    
    private func recognizeText(in cgImage: CGImage, completion: @escaping (String?) -> Void) {
        let request = VNRecognizeTextRequest { request, _ in
            let texts: [String] = (request.results as? [VNRecognizedTextObservation])?
                .compactMap { $0.topCandidates(1).first?.string }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? []
            let joined = texts.prefix(5).joined(separator: " ")
            completion(joined)
        }
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.02
        
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        visionQueue.async {
            do { try handler.perform([request]) } catch { completion(nil) }
        }
    }
    
    private func fetchVideoURL(for query: String, completion: @escaping (URL?) -> Void) {
        // Use Piped public API as a no-key YouTube proxy. If it fails, completion(nil)
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            completion(nil); return
        }
        let searchURL = URL(string: "https://piped.video/api/v1/search?q=\(encodedQuery)&region=US")!
        let task = URLSession.shared.dataTask(with: searchURL) { data, _, _ in
            guard let data = data else { completion(nil); return }
            struct SearchItem: Decodable { let id: String?; let url: String? }
            guard let items = try? JSONDecoder().decode([SearchItem].self, from: data) else { completion(nil); return }
            guard let first = items.first else { completion(nil); return }
            if let id = first.id {
                self.fetchStreamURL(for: id, completion: completion)
                return
            }
            if let urlStr = first.url, let url = URL(string: urlStr) { completion(url); return }
            completion(nil)
        }
        task.resume()
    }
    
    private func fetchStreamURL(for videoId: String, completion: @escaping (URL?) -> Void) {
        let streamsURL = URL(string: "https://piped.video/api/v1/streams/\(videoId)")!
        let task = URLSession.shared.dataTask(with: streamsURL) { data, _, _ in
            guard let data = data else { completion(nil); return }
            struct Streams: Decodable {
                struct VideoStream: Decodable { let url: String }
                let hls: String?
                let videoStreams: [VideoStream]?
            }
            guard let streams = try? JSONDecoder().decode(Streams.self, from: data) else { completion(nil); return }
            if let hls = streams.hls, let url = URL(string: hls) { completion(url); return }
            if let vs = streams.videoStreams?.first, let url = URL(string: vs.url) { completion(url); return }
            completion(nil)
        }
        task.resume()
    }
    
    private func placeVideoOnDetectedRectangle(observation: VNRectangleObservation, imageSize: CGSize, videoURL: URL) {
        // Convert Vision normalized points to view coordinates
        func toViewPoint(_ p: CGPoint) -> CGPoint {
            return CGPoint(x: p.x * imageSize.width, y: (1.0 - p.y) * imageSize.height)
        }
        let tl = toViewPoint(observation.topLeft)
        let tr = toViewPoint(observation.topRight)
        let bl = toViewPoint(observation.bottomLeft)
        let br = toViewPoint(observation.bottomRight)
        
        DispatchQueue.main.async {
            // Raycast from screen points into the real world
            let maybeTL = self.firstRaycastResult(from: tl)
            let maybeTR = self.firstRaycastResult(from: tr)
            let maybeBL = self.firstRaycastResult(from: bl)
            let maybeBR = self.firstRaycastResult(from: br)
            
            // If we have at least the center point, place a plane facing camera as a fallback
            let center = CGPoint(x: (tl.x + br.x) / 2.0, y: (tl.y + br.y) / 2.0)
            let maybeCenter = self.firstRaycastResult(from: center)
            
            if let tlR = maybeTL, let trR = maybeTR, let blR = maybeBL {
                // Build plane transform from three points
                let p1 = tlR.worldTransform.columns.3.xyz
                let p2 = trR.worldTransform.columns.3.xyz
                let p3 = blR.worldTransform.columns.3.xyz
                
                let width = simd_distance(p1, p2)
                let height = simd_distance(p1, p3)
                let centerPosition = (p1 + p2 + p3 + (maybeBR?.worldTransform.columns.3.xyz ?? p1)) / 4.0
                
                let u = simd_normalize(p2 - p1)
                let v = simd_normalize(p3 - p1)
                var n = simd_normalize(simd_cross(u, v))
                if !n.allFinite { n = simd_float3(0, 0, -1) }
                let transform = self.transform(position: centerPosition, normal: n, upHint: v)
                
                self.placeVideoPlane(at: transform, width: max(0.05, width), height: max(0.05, height), videoURL: videoURL)
            } else if let centerR = maybeCenter {
                // Approximate size using 25cm x 14cm
                self.placeVideoPlane(at: centerR.worldTransform, width: 0.25, height: 0.14, videoURL: videoURL)
            } else {
                self.performFallbackOverlay()
            }
        }
    }
    
    private func firstRaycastResult(from point: CGPoint) -> ARRaycastResult? {
        guard let query = sceneView.raycastQuery(from: point, allowing: .estimatedPlane, alignment: .any) else { return nil }
        let results = sceneView.session.raycast(query)
        return results.first
    }
    
    private func placeVideoPlane(at transform: simd_float4x4, width: CGFloat, height: CGFloat, videoURL: URL) {
        // Remove previous dynamic video plane
        currentVideoPlaneNode?.removeFromParentNode()
        
        let plane = SCNPlane(width: width, height: height)
        plane.firstMaterial?.isDoubleSided = true
        plane.firstMaterial?.diffuse.contents = UIColor.black
        
        let node = SCNNode(geometry: plane)
        node.simdTransform = transform
        
        // Prepare AVPlayer-backed SKVideoNode
        let player = AVPlayer(url: videoURL)
        let videoNode = SKVideoNode(avPlayer: player)
        let videoScene = SKScene(size: CGSize(width: 1280, height: 720))
        videoNode.position = CGPoint(x: videoScene.size.width / 2, y: videoScene.size.height / 2)
        videoNode.size = videoScene.size
        videoNode.yScale = -1.0
        videoScene.addChild(videoNode)
        
        plane.firstMaterial?.diffuse.contents = videoScene
        
        sceneView.scene.rootNode.addChildNode(node)
        currentVideoPlaneNode = node
        
        player.play()
    }
}

// MARK: - SIMD helpers
private extension simd_float4 {
    var xyz: simd_float3 { simd_float3(x, y, z) }
}

private extension ViewController {
    func transform(position: simd_float3, normal: simd_float3, upHint: simd_float3) -> simd_float4x4 {
        let zAxis = simd_normalize(-normal)
        var xAxis = simd_normalize(simd_cross(upHint, zAxis))
        if !xAxis.allFinite || simd_length(xAxis) < 1e-3 {
            xAxis = simd_normalize(simd_cross(simd_float3(0,1,0), zAxis))
        }
        let yAxis = simd_normalize(simd_cross(zAxis, xAxis))
        var transform = matrix_identity_float4x4
        transform.columns.0 = simd_float4(xAxis, 0)
        transform.columns.1 = simd_float4(yAxis, 0)
        transform.columns.2 = simd_float4(zAxis, 0)
        transform.columns.3 = simd_float4(position, 1)
        return transform
    }
}

private extension simd_float3 {
    var allFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}
