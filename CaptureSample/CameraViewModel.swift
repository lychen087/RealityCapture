/*
See LICENSE folder for this sample’s licensing information.

Abstract:
An observable data model that maintains state related to the camera session.
*/

import AVFoundation
import Combine
import CoreMotion
import SwiftUI

import os

private let logger = Logger(subsystem: "com.apple.sample.CaptureSample",
                            category: "CameraViewModel")

/// This is a SwiftUI observable data model class that holds all of the app's state and handles all changes
/// to that state. The app's views observe this object and update themseves to reflect changes.
class CameraViewModel: ObservableObject {
    var session: AVCaptureSession

    enum CaptureMode {
        /// The user has selected manual capture mode, which captures one
        /// image per button press.
        case manual

        /// The user has selected automatic capture mode, which captures one
        /// image every specified interval.
        case automatic(everySecs: Double)
    }

    /// This property holds a reference to the most recently captured image and its metadata. The app
    /// uses this to populate the thumbnail view.
    @Published var lastCapture: Capture? = nil

    /// Returns`true` if there's a camera available.`
    @Published var isCameraAvailable: Bool = false

    /// If `isCameraEnabled` is `true`, this property indicates whether the app is able to take
    /// high-quality photos.
    @Published var isHighQualityMode: Bool = false

    /// This property returns `true` if depth data is supported and available on this device. By default,
    /// the app tries to turn depth data on during setup and sets this to `true` if successful.
    @Published var isDepthDataEnabled: Bool = false

    /// This property returns `true` if motion data is available and enabled. By default, the app tries to
    /// enable motion data during setup and sets this to `true` if successful.
    @Published var isMotionDataEnabled: Bool = false

    /// This property  maintains references to the location of each image and its corresponding metadata in
    /// the file system.
    @Published var captureFolderState: CaptureFolderState?
    
    @Published var info: String = ""

    @Published var parametersLocked: Bool = false;
    /// This property returns the current capture mode. This property doesn't indicate whether the capture
    /// timer is currently running. When you set this to `.manual`, it cancels the timer used by automatic
    /// mode.
    @Published var captureMode: CaptureMode = .manual {
        willSet(newMode) {
            // If the app is currently in auto mode, stop any timers.
            if case .automatic = captureMode {
                stopAutomaticCapture()
                triggerEveryTimer = nil
            }
        }

        didSet {
            // After this property is set, create a timer. If the user presses
            // the capture button with automatic mode enabled, the app toggles
            // the timer.
            if case .automatic(let intervalSecs) = captureMode {
                autoCaptureIntervalSecs = intervalSecs
                triggerEveryTimer = TriggerEveryTimer(
                    triggerEvery: autoCaptureIntervalSecs,
                    onTrigger: {
                        self.capturePhotoAndMetadata()
                    },
                    updateEvery: 1.0 / 30.0,  // 30 fps.
                    onUpdate: { timeLeft in
                        self.timeUntilCaptureSecs = timeLeft
                    })
            }
        }
    }

    /// This property indicates if auto-capture is currently active. The app sets this to `true` while it's
    /// automatically capturing images using the timer.
    @Published var isAutoCaptureActive: Bool = false

    /// If `isAutoCaptureActive` is `true`, this property contains the number of seconds until the
    /// next capture trigger.
    @Published var timeUntilCaptureSecs: Double = 0

    var autoCaptureIntervalSecs: Double = 0

    var readyToCapture: Bool {
        return captureFolderState != nil &&
//            captureFolderState!.captures.count < CameraViewModel.maxPhotosAllowed &&
            self.inProgressPhotoCaptureDelegates.count < 2
    }

    var captureDir: URL? {
        return captureFolderState?.captureDir
    }
    
    static let maxPhotosAllowed = 3
    static let recommendedMinPhotos = 30
    static let recommendedMaxPhotos = 200
    static let frame_num: Double = 120
    static let rotate_time: Double = 108
    static var defaultAutomaticCaptureIntervalSecs: Double = rotate_time / frame_num
    
    func setIntervalSecs(sec: Double)
    {
        CameraViewModel.defaultAutomaticCaptureIntervalSecs = sec
        print("CameraViewModel.defaultAutomaticCaptureIntervalSecs: \(CameraViewModel.defaultAutomaticCaptureIntervalSecs)")
        captureMode = .automatic(everySecs: CameraViewModel.defaultAutomaticCaptureIntervalSecs)
    }
    func getIntervalSecs() -> Double
    {
        return CameraViewModel.defaultAutomaticCaptureIntervalSecs
    }

    init() {
        session = AVCaptureSession()
        // This is an asynchronous call that begins all setup. It sets
        // up the camera device, motion device (gravity), and ensures correct
        // permissions.
        startSetup()
    }

    /// This method advances through the available capture modes, updating `captureMode`.
    /// This method must be called from the main thread.
    func advanceToNextCaptureMode() {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        switch captureMode {
        case .manual:
            captureMode = .automatic(everySecs: CameraViewModel.defaultAutomaticCaptureIntervalSecs)
        case .automatic(_):
            captureMode = .manual
        }
    }
    func getWhiteBalanceGains() -> Double
    {
        let currentGains = self.videoDeviceInput?.device.deviceWhiteBalanceGains
            
        let temperatureAndTint = self.videoDeviceInput?.device.temperatureAndTintValues(for: currentGains!)
        
        return Double(temperatureAndTint!.temperature)
    }
    
    func setWhiteBalanceGains(temperature: Float) {
        let tint = calculateTint(for: temperature)
        
        let temperatureAndTint = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: temperature, tint: tint)
        
        let whiteBalanceGains = self.videoDeviceInput?.device.deviceWhiteBalanceGains(for: temperatureAndTint)
        
        let validGains = clampGains(whiteBalanceGains!, for: self.videoDeviceInput!.device)
        
        do {
            try self.videoDeviceInput?.device.lockForConfiguration()
            let duration = self.videoDeviceInput?.device.exposureDuration
            let iso: Float = (self.videoDeviceInput?.device.iso)!
            
            
            let currentISO = self.videoDeviceInput?.device.iso
            guard let currentExposureDuration = self.videoDeviceInput?.device.exposureDuration else {
                        print("can't get currentExposureDuration")
                        self.videoDeviceInput?.device.unlockForConfiguration()
                        return
                    }
            guard let currentWhiteBalanceGains = self.videoDeviceInput?.device.deviceWhiteBalanceGains else {
                        print("can't get currentExposureDuration")
                        self.videoDeviceInput?.device.unlockForConfiguration()
                        return
                    }
            if (parametersLocked){
                print("parametersLocked: \(parametersLocked)")
                print("current iso \(String(describing: iso)), current_duration: \(String(describing: duration))")
                let settings: [String: Any] = [
                            "iso": currentISO!,
                            "exposureDuration": CMTimeGetSeconds(currentExposureDuration),
                            "whiteBalanceRedGain": currentWhiteBalanceGains.redGain,
                            "whiteBalanceGreenGain": currentWhiteBalanceGains.greenGain,
                            "whiteBalanceBlueGain": currentWhiteBalanceGains.blueGain
                        ]
                let data = try JSONSerialization.data(withJSONObject: settings, options: .prettyPrinted)
                let filePath = self.captureDir!.appendingPathComponent("cameraSettings.json")
                
                print("[toggleCameraParametersLock] save to \(filePath)")
                try data.write(to: filePath)
                self.videoDeviceInput?.device.setWhiteBalanceModeLocked(with: validGains, completionHandler: nil)
                self.info = String(describing: validGains)
            }
            self.videoDeviceInput?.device.unlockForConfiguration()
        } catch {
            print("Failed to lock device for configuration: \(error)")
        }
    }
    
    func calculateTint(for temperature: Float) -> Float {
        let baseTint: Float = 0
        let temperatureFactor: Float = (temperature - 5000) / 1000
        return baseTint + temperatureFactor * 10
    }

    func clampGains(_ gains: AVCaptureDevice.WhiteBalanceGains, for device: AVCaptureDevice) -> AVCaptureDevice.WhiteBalanceGains {
        var clampedGains = gains
        clampedGains.redGain = max(1.0, min(gains.redGain, device.maxWhiteBalanceGain))
        clampedGains.greenGain = max(1.0, min(gains.greenGain, device.maxWhiteBalanceGain))
        clampedGains.blueGain = max(1.0, min(gains.blueGain, device.maxWhiteBalanceGain))
        return clampedGains
    }

    func toggleCameraParametersLock() {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        parametersLocked = !parametersLocked
        do{
            //acquire exclusive access to the device’s configuration properties
            try self.videoDeviceInput?.device.lockForConfiguration()
            self.videoDeviceInput?.device.exposureMode = parametersLocked ? .locked : .continuousAutoExposure
            self.videoDeviceInput?.device.whiteBalanceMode = parametersLocked ? .locked : .continuousAutoWhiteBalance
            logger.log("switch Exposure to \(self.parametersLocked)")
            let duration = self.videoDeviceInput?.device.exposureDuration
            let iso: Float = (self.videoDeviceInput?.device.iso)!
            
            
            let currentISO = self.videoDeviceInput?.device.iso
            guard let currentExposureDuration = self.videoDeviceInput?.device.exposureDuration else {
                        print("can't get currentExposureDuration")
                        self.videoDeviceInput?.device.unlockForConfiguration()
                        return
                    }
            guard let currentWhiteBalanceGains = self.videoDeviceInput?.device.deviceWhiteBalanceGains else {
                        print("can't get currentExposureDuration")
                        self.videoDeviceInput?.device.unlockForConfiguration()
                        return
                    }
            self.info = String(describing: currentWhiteBalanceGains)
            
            self.videoDeviceInput?.device.unlockForConfiguration()
            if (parametersLocked){
                print("parametersLocked: \(parametersLocked)")
                print("current iso \(String(describing: iso)), current_duration: \(String(describing: duration))")
                let settings: [String: Any] = [
                            "iso": currentISO!,
                            "exposureDuration": CMTimeGetSeconds(currentExposureDuration),
                            "whiteBalanceRedGain": currentWhiteBalanceGains.redGain,
                            "whiteBalanceGreenGain": currentWhiteBalanceGains.greenGain,
                            "whiteBalanceBlueGain": currentWhiteBalanceGains.blueGain
                        ]
                let data = try JSONSerialization.data(withJSONObject: settings, options: .prettyPrinted)
                let filePath = self.captureDir!.appendingPathComponent("cameraSettings.json")
                
                print("[toggleCameraParametersLock] save to \(filePath)")
                try data.write(to: filePath)
            }
        }
        catch{
            logger.log("ERROR: \(String(describing: error.localizedDescription))")
        }
    }
    
    func applyCurrentCameraSettings(captureDirPath: URL)
    {
        do {
            let pathComponents = captureDirPath.pathComponents
            let subPathComponents = pathComponents.prefix(pathComponents.count - 1)
            var newPath = subPathComponents.joined(separator: "/")
            print("[applyCurrentCameraSettings] newPath: \(newPath)")
            let secondToLastComponent = pathComponents[pathComponents.count - 1]
            print("[applyCurrentCameraSettings] secondToLastComponent: \(secondToLastComponent)")
            
            // Assuming you want to add a specific date-time string as in your comment
            newPath += "/\(secondToLastComponent)"
            print("[applyCurrentCameraSettings] newPath 2: \(newPath)")
            let newPathURL = URL(fileURLWithPath: newPath)
            let filePath = newPathURL.appendingPathComponent("cameraSettings.json")

            
            
            print("[applyCurrentCameraSettings] read from \(filePath)")
            let data = try Data(contentsOf: filePath)
                // turn jsonfile into dictionary!
                guard let settings = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                      let iso = settings["iso"] as? Float,
                      let exposureDurationSeconds = settings["exposureDuration"] as? Double,
                      let redGain = settings["whiteBalanceRedGain"] as? Float,
                      let greenGain = settings["whiteBalanceGreenGain"] as? Float,
                      let blueGain = settings["whiteBalanceBlueGain"] as? Float else {
                    print("can't read camera setting!!!")
                    return
                }
            
            let exposureDuration = CMTimeMakeWithSeconds(exposureDurationSeconds, preferredTimescale: 1000000)
            let whiteBalanceGains = AVCaptureDevice.WhiteBalanceGains(redGain: redGain, greenGain: greenGain, blueGain: blueGain)
            self.info = String(describing: whiteBalanceGains)
            print("parametersLocked: \(parametersLocked)")
            parametersLocked = true
            print("current iso \(String(describing: iso)), current_duration: \(String(describing: exposureDuration))")
            print("white balance gains \(String(describing: whiteBalanceGains))")
            guard let device = self.videoDeviceInput?.device else {
                    print("can't get device!!!")
                    return
                }
                
            let minISO = device.activeFormat.minISO
            let maxISO = device.activeFormat.maxISO
            let clampedISO = min(max(iso, minISO), maxISO)
            
            
            try self.videoDeviceInput?.device.lockForConfiguration()
            
            if ((self.videoDeviceInput?.device.isExposureModeSupported(.custom)) != nil) {
                self.videoDeviceInput?.device.setExposureModeCustom(duration: exposureDuration, iso: clampedISO) { time in
                    print("exposure set!!!")
                }
            }

            if ((self.videoDeviceInput?.device.isWhiteBalanceModeSupported(.locked)) != nil) {
                self.videoDeviceInput?.device.setWhiteBalanceModeLocked(with: whiteBalanceGains) { time in
                    print("White balance set!!!")
                }
            }
            
            if (parametersLocked){
                print("parametersLocked: \(parametersLocked)")
                print("current iso \(String(describing: iso)), current_duration: \(String(describing: duration))")
                let settings: [String: Any] = [
                            "iso": iso,
                            "exposureDuration": exposureDurationSeconds,
                            "whiteBalanceRedGain": redGain,
                            "whiteBalanceGreenGain": greenGain,
                            "whiteBalanceBlueGain": blueGain
                        ]
                let data = try JSONSerialization.data(withJSONObject: settings, options: .prettyPrinted)
                let filePath = self.captureDir!.appendingPathComponent("cameraSettings.json")
                
                print("[toggleCameraParametersLock] save to \(filePath)")
                try data.write(to: filePath)
            }
            self.videoDeviceInput?.device.unlockForConfiguration()
        }
        catch{
            logger.log("ERROR: \(String(describing: error.localizedDescription))")
        }
    }

    /// When the user presses the capture button, this method is called.
    /// If captureMode is `.manual`, this method triggers a single image capture.
    /// If captureMode is `.automatic`, this method toggles the automatic capture timer on and off.
    func captureButtonPressed() {
        switch captureMode {
        case .manual:
            capturePhotoAndMetadata()
        case .automatic:
            guard triggerEveryTimer != nil else { return }
            if triggerEveryTimer!.isRunning {
                stopAutomaticCapture()
            } else {
                startAutomaticCapture()
            }
        }
    }

    /// This method creates a new capture dictionary and resets the app's capture folder state. It doesn't
    /// change any`AVCaptureSession` settings.
    func requestNewCaptureFolder() {
        logger.log("Requesting new capture folder...")

        // Invalidate the old state on the main thread, which causes the app
        // to update its UI.
        DispatchQueue.main.async {
            self.lastCapture = nil
        }

        // Create a directory in the file system on a background thread, then
        // publish it on the main thread.
        sessionQueue.async {
            do {
                let newCaptureFolder = try CameraViewModel.createNewCaptureFolder()
                logger.log("Created new capture folder: \"\(String(describing: self.captureDir))\"")
                DispatchQueue.main.async {
                    logger.info("Publishing new capture folder: \"\(String(describing: self.captureDir))\"")
                    self.captureFolderState = newCaptureFolder
                }
            } catch {
                logger.error("Can't create new capture folder!")
            }
        }
    }

    func addCapture(_ capture: Capture) {
        logger.log("Received a new capture id=\(capture.id)")

        // Cache the most recent capture on the main queue.
        DispatchQueue.main.async {
            self.lastCapture = capture
        }

        // Write files in the background.
        guard self.captureDir != nil else {
            return
        }
        sessionQueue.async {
            do {
                // Write the files, then reload the folder to keep it in sync.
                try capture.writeAllFiles(to: self.captureDir!)
                self.captureFolderState?.requestLoad()
            } catch {
                logger.error("Can't write capture id=\(capture.id) error=\(String(describing: error))")
            }
        }
    }

    func removeCapture(captureInfo: CaptureInfo, deleteData: Bool = true) {
        logger.log("Remove capture called on \(String(describing: captureInfo))...")
        captureFolderState?.removeCapture(captureInfo: captureInfo, deleteData: deleteData)
    }

    /// This method starts the setup process, which runs asynchronously. This method requests camera
    /// access if the user hasn't yet granted it.
    func startSetup() {
        do {
            captureFolderState = try CameraViewModel.createNewCaptureFolder()
        } catch {
            setupResult = .cantCreateOutputDirectory
            logger.error("Setup failed!")
            return
        }

        // If authorization fails, set setupResult to .unauthorized.
        requestAuthorizationIfNeeded()
        sessionQueue.async {
            self.configureSession()
        }

        if motionManager.isDeviceMotionAvailable {
            motionManager.startDeviceMotionUpdates()
            DispatchQueue.main.async {
                self.isMotionDataEnabled = true
            }
        } else {
            logger.warning("Device motion data isn't available!")
            DispatchQueue.main.async {
                self.isMotionDataEnabled = false
            }
        }
    }

    func startSession() {
        dispatchPrecondition(condition: .onQueue(.main))
        logger.log("Starting session...")
        sessionQueue.async {
            self.session.startRunning()
            self.isSessionRunning = self.session.isRunning
        }
    }

    func pauseSession() {
        dispatchPrecondition(condition: .onQueue(.main))
        logger.log("Pausing session...")
        sessionQueue.async {
            self.session.stopRunning()
            self.isSessionRunning = self.session.isRunning
        }
        // Stop auto-capturing if the capture screen is no longer showing.
        if isAutoCaptureActive {
            stopAutomaticCapture()
        }
    }

    // MARK: - Private State

    let previewWidth = 512
    let previewHeight = 512
    let thumbnailWidth = 512
    let thumbnailHeight = 512

    // This is the unique identifier for the next photo. This value must be
    // unique within a session.
    private var photoId: UInt32 = 0
    
    //new
    ///exposure, white balance parameters
    private var duration: CMTime? = AVCaptureDevice.currentExposureDuration
    private var iso: Float? = AVCaptureDevice.currentISO
    private var whiteBalanceGains: AVCaptureDevice.WhiteBalanceGains? = AVCaptureDevice.currentWhiteBalanceGains
    
    //modified .quality => .speed
    private var photoQualityPrioritizationMode: AVCapturePhotoOutput.QualityPrioritization =
        .quality

    private static let cameraShutterNoiseID: SystemSoundID = 1108

    private enum SessionSetupResult {
        case inProgress
        case success
        case cantCreateOutputDirectory
        case notAuthorized
        case configurationFailed
    }

    private enum SessionSetupError: Swift.Error {
        case cantCreateOutputDirectory
        case notAuthorized
        case configurationFailed
    }

    private enum SetupError: Error {
        case failed(msg: String)
    }

    /// This method processes the session setup results asynchronously.
    private var setupResult: SessionSetupResult = .inProgress {
        didSet {
            logger.log("didSet setupResult=\(String(describing: self.setupResult))")
            if case .inProgress = setupResult { return }
            if case .success = setupResult {
                DispatchQueue.main.async {
                    self.isCameraAvailable = true
                }
            } else {
                DispatchQueue.main.async {
                    self.isCameraAvailable = false
                }
            }
        }
    }

    private var videoDeviceInput: AVCaptureDeviceInput? = nil

    /// This private property holds the current state of the session. The app uses this to pause the app
    /// when it goes into the background and to resume the app when it comes back to the foreground.
    private var isSessionRunning = false

    /// This queue is used to communicate with the session and other session objects.
    private let sessionQueue = DispatchQueue(label: "CameraViewModel: sessionQueue")

    private let motionManager = CMMotionManager()

    private var photoOutput = AVCapturePhotoOutput()

    /// This property holds references to active `PhotoCaptureProcessor` instances. The app removes
    /// instances when the corresponding capture is complete.
    private var inProgressPhotoCaptureDelegates = [Int64: PhotoCaptureProcessor]()

    /// This helper class is used during automatic mode to trigger image captures.  When the app is in
    /// manual mode, it's `nil`.
    private var triggerEveryTimer: TriggerEveryTimer? = nil

    // MARK: - Private Functions

    private func capturePhotoAndMetadata() {
        logger.log("Capture photo called...")
        dispatchPrecondition(condition: .onQueue(.main))

        /// This property retrieves and stores the video preview layer's video orientation on the main
        /// queue before starting the session queue. This ensures that UI elements can be accessed on
        /// the main thread.
        let videoPreviewLayerOrientation = session.connections[0].videoOrientation

        sessionQueue.async {
            if let photoOutputConnection = self.photoOutput.connection(with: .video) {
                photoOutputConnection.videoOrientation = videoPreviewLayerOrientation
            }
            var photoSettings = AVCapturePhotoSettings()

            // Request HEIF photos if supported and enable high-resolution photos.
            if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                photoSettings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            }

            // Turn off the flash. The app relies on ambient lighting to avoid specular highlights.
            if self.videoDeviceInput!.device.isFlashAvailable {
                photoSettings.flashMode = .off
            }

            // Turn on high-resolution, depth data, and quality prioritzation mode.
            photoSettings.isHighResolutionPhotoEnabled = true

            if #available(iOS 15.4, *) {
                // Enable depth data delivery if supported
                if self.photoOutput.isDepthDataDeliverySupported {
                    photoSettings.isDepthDataDeliveryEnabled = true
                } else {
                    logger.warning("Depth data delivery is not supported.")
                }
            } else {
                // For older iOS versions, enable depth data delivery if supported
                photoSettings.isDepthDataDeliveryEnabled = self.photoOutput.isDepthDataDeliveryEnabled
            }
            
            photoSettings.photoQualityPrioritization = self.photoQualityPrioritizationMode

            // Request that the camera embed a depth map into the HEIC output file.
            photoSettings.embedsDepthDataInPhoto = true

            // Specify a preview image.
            if !photoSettings.__availablePreviewPhotoPixelFormatTypes.isEmpty {
                photoSettings.previewPhotoFormat = [
                    kCVPixelBufferPixelFormatTypeKey: photoSettings.__availablePreviewPhotoPixelFormatTypes.first!,
                    kCVPixelBufferWidthKey: self.previewWidth,
                    kCVPixelBufferHeightKey: self.previewHeight
                ] as [String: Any]
                logger.log("Found available previewPhotoFormat: \(String(describing: photoSettings.previewPhotoFormat))")
            } else {
                logger.warning("Can't find preview photo formats! Not setting...")
            }

            // Tell the camera to embed a preview image in the output file.
            photoSettings.embeddedThumbnailPhotoFormat = [
                AVVideoCodecKey: AVVideoCodecType.jpeg,
                AVVideoWidthKey: self.thumbnailWidth,
                AVVideoHeightKey: self.thumbnailHeight
            ]

            DispatchQueue.main.async {
                self.isHighQualityMode = photoSettings.isHighResolutionPhotoEnabled && photoSettings.photoQualityPrioritization == .quality
            }

            self.photoId += 1
            let photoCaptureProcessor = self.makeNewPhotoCaptureProcessor(photoId: self.photoId,
                                                                          photoSettings: photoSettings)

            // The photo output holds a weak reference to the photo capture
            // delegate, so it also stores it in an array, which maintains a
            // strong reference so the system won't deallocate it.
            self.inProgressPhotoCaptureDelegates[photoCaptureProcessor.requestedPhotoSettings.uniqueID] = photoCaptureProcessor
            logger.log("inProgressCaptures=\(self.inProgressPhotoCaptureDelegates.count)")
            self.photoOutput.capturePhoto(with: photoSettings, delegate: photoCaptureProcessor)
        }
    }


    private func makeNewPhotoCaptureProcessor(
        photoId: UInt32, photoSettings: AVCapturePhotoSettings) -> PhotoCaptureProcessor {

        let photoCaptureProcessor = PhotoCaptureProcessor(
            with: photoSettings,
            model: self,
            photoId: photoId,
            motionManager: self.motionManager,
            willCapturePhotoAnimation: {
                AudioServicesPlaySystemSound(CameraViewModel.cameraShutterNoiseID)
            },
            completionHandler: { photoCaptureProcessor in
                // When the capture is complete, remove the reference to the
                // completed photo capture delegate.
                self.sessionQueue.async {
                    self.inProgressPhotoCaptureDelegates.removeValue(
                        forKey: photoCaptureProcessor.requestedPhotoSettings.uniqueID)
                    logger.log("inProgressCaptures=\(self.inProgressPhotoCaptureDelegates.count)")
                }
            }, photoProcessingHandler: { _ in
            }
        )
        return photoCaptureProcessor
    }

    /// This method starts the automatic capture timer, which the app only uses when the user enables
    /// `.automatic` mode.
    private func startAutomaticCapture() {
        dispatchPrecondition(condition: .onQueue(.main))
        precondition(triggerEveryTimer != nil)

        logger.log("Start Auto Capture.")
        guard !triggerEveryTimer!.isRunning else {
            logger.error("Timer was already set!  Not setting again...")
            return
        }
        triggerEveryTimer!.start()
        isAutoCaptureActive = true
    }

    /// This method stops the automatic capture timer.
    private func stopAutomaticCapture() {
        dispatchPrecondition(condition: .onQueue(.main))
        logger.log("Stop Auto Capture!")

        isAutoCaptureActive = false
        triggerEveryTimer?.stop()
    }

    private static func createNewCaptureFolder() throws -> CaptureFolderState {
        guard let newCaptureDir = CaptureFolderState.createCaptureDirectory() else {
            throw SetupError.failed(msg: "Can't create capture directory!")
        }
        return CaptureFolderState(url: newCaptureDir)
    }

    private func requestAuthorizationIfNeeded() {
        // Check the camera's authorization status.
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            // The user has previously granted access to the camera, so there's
            // no need to do more.
            break

        case .notDetermined:
            // The app hasn't asked the user to grant video access.
            // Suspend the session queue to delay setup until the app requests
            // access.
            sessionQueue.suspend()
            AVCaptureDevice.requestAccess(for: .video, completionHandler: { granted in
                if !granted {
                    self.setupResult = .notAuthorized
                }
                self.sessionQueue.resume()
            })

        default:
            // The user previously denied access.
            setupResult = .notAuthorized
        }
    }
    
    
    
    //new
    ///if the device support custom exposure mode, apply specified duration and iso, else set to locked exposure mode.
    private func setExposure(device: AVCaptureDevice) {
        duration = AVCaptureDevice.currentExposureDuration
        iso = AVCaptureDevice.currentISO
//        private var whiteBalanceGains: AVCaptureDevice.WhiteBalanceGains? = AVCaptureDevice.currentWhiteBalanceGains
        info = String(self.iso!)
        
        if device.isExposureModeSupported(.custom) {
            logger.log("setExposure")
            do{
                try device.lockForConfiguration()
                    
                device.setExposureModeCustom(duration: self.duration!, iso: self.iso!) { (_) in
                    logger.log("Done Exposure")
                }
                device.unlockForConfiguration()
            }
            catch{
                logger.log("ERROR: \(String(describing: error.localizedDescription))")
            }
        }
        else {
            do{
                try device.lockForConfiguration()
                
                logger.log("custom exposure mode not supported.")
                device.exposureMode = .locked
                
                device.unlockForConfiguration()
            }
            catch{
                logger.log("ERROR: \(String(describing: error.localizedDescription))")
            }
        }
    }
    
    //new
    ///if the device support locked white balance mode, apply specified white balance gains, else set to auto white balance mode.
    private func setWhiteBalance(device: AVCaptureDevice) {
        ///set white balance gains (locked mode)
        whiteBalanceGains = AVCaptureDevice.currentWhiteBalanceGains
        logger.log("setWhiteBalance")
        
        if device.isWhiteBalanceModeSupported(.locked) {
            do{
                try device.lockForConfiguration()
                    
                device.setWhiteBalanceModeLocked(with: self.whiteBalanceGains!) { (_) in
                    logger.log("Done white balance")
                }
                device.unlockForConfiguration()
            }
            catch{
                logger.log("ERROR: \(String(describing: error.localizedDescription))")
            }
        }
        else {
            do{
                try device.lockForConfiguration()
                    
                logger.log("locked white balance mode not supported.")
                device.whiteBalanceMode = .autoWhiteBalance
                    
                device.unlockForConfiguration()
            }
            catch{
                logger.log("ERROR: \(String(describing: error.localizedDescription))")
            }
        }
    }

    private func configureSession() {
        // Make sure setup hasn't failed.
        guard setupResult == .inProgress else {
            logger.error("Setup failed, can't configure session!  result=\(String(describing: self.setupResult))")
            return
        }

        // Start a new configuration and commit it.
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .photo

        do {
            let videoDeviceInput = try AVCaptureDeviceInput(
                device: getVideoDeviceForPhotogrammetry())
            
            logger.log("before setting!")
//            new
//            setExposure(device: videoDeviceInput.device)
//            setWhiteBalance(device: videoDeviceInput.device)
            logger.log("after setting!")
            
            
            if session.canAddInput(videoDeviceInput) {
                session.addInput(videoDeviceInput)
                self.videoDeviceInput = videoDeviceInput
            } else {
                logger.error("Couldn't add video device input to the session.")
                setupResult = .configurationFailed
                return
            }
        } catch {
            logger.error("Couldn't create video device input: \(String(describing: error))")
            setupResult = .configurationFailed
            return
        }

        do {
            try addPhotoOutputOrThrow()
        } catch {
            logger.error("Error: adding photo output = \(String(describing: error))")
            setupResult = .configurationFailed
            return
        }

        // Set the observed property so that depth data is available on the main thread.
        DispatchQueue.main.async {
            self.isDepthDataEnabled = self.photoOutput.isDepthDataDeliveryEnabled
            self.isHighQualityMode = self.photoOutput.isHighResolutionCaptureEnabled
                && self.photoOutput.maxPhotoQualityPrioritization == .quality
        }

        // Setup was successful, so set this value to tell the UI to enable
        // the capture buttons.
        setupResult = .success
    }
    
    private func addPhotoOutputOrThrow() throws {
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)

            // Prefer high resolution and maximum quality, with depth.
            photoOutput.isHighResolutionCaptureEnabled = true
            
            if #available(iOS 15.4, *) {
                // Check if LiDAR depth data delivery is supported
                if photoOutput.isDepthDataDeliverySupported {
                    photoOutput.isDepthDataDeliveryEnabled = true
                } else {
                    logger.warning("LiDAR depth data delivery is not supported.")
                }
            } else {
                // For older iOS versions, enable depth data delivery if supported
                photoOutput.isDepthDataDeliveryEnabled = photoOutput.isDepthDataDeliverySupported
            }
            
            photoOutput.maxPhotoQualityPrioritization = .quality
        } else {
            logger.error("Could not add photo output to the session")
            throw SessionSetupError.configurationFailed
        }
    }

    private func getVideoDeviceForPhotogrammetry() throws -> AVCaptureDevice {
        var defaultVideoDevice: AVCaptureDevice?

        // try to get LiDAR depth camera
        if #available(iOS 15.4, *) {
            if let lidarDevice = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) {
                logger.log(">>> Got LiDAR depth camera!")
                defaultVideoDevice = lidarDevice
            } else {
                logger.error("LiDAR depth camera is unavailable.")
                throw SessionSetupError.configurationFailed
            }
        } else {
            // Fallback on earlier versions
            // Specify dual camera to get access to depth data.
            if let dualCameraDevice = AVCaptureDevice.default(.builtInDualCamera, for: .video,
                                                              position: .back) {
                logger.log(">>> Got back dual camera!")
                defaultVideoDevice = dualCameraDevice
            } else if let dualWideCameraDevice = AVCaptureDevice.default(.builtInDualWideCamera,
                                                                    for: .video,
                                                                    position: .back) {
                logger.log(">>> Got back dual wide camera!")
                defaultVideoDevice = dualWideCameraDevice
           } else if let backWideCameraDevice = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                                         for: .video,
                                                                         position: .back) {
                logger.log(">>> Can't find a depth-capable camera: using wide back camera!")
                defaultVideoDevice = backWideCameraDevice
            }
        }
        guard let videoDevice = defaultVideoDevice else {
                    logger.error("Back video device is unavailable.")
                    throw SessionSetupError.configurationFailed
                }
        
        return videoDevice
    }
}
