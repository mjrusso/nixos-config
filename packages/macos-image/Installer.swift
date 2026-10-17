import AppKit
import Virtualization

struct ImageConfiguration: Decodable {
    let cpuCount: Int
    let memoryMiB: UInt64
    let diskGiB: UInt64
    let macAddress: String
    let user: String
}

struct BuildError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

@available(macOS 27.0, *)
@MainActor
@main
final class Installer: NSObject, @MainActor VZVirtualMachineDelegate {
    private var virtualMachine: VZVirtualMachine?
    private var window: NSWindow?

    static func configuration(bundle: URL, image: ImageConfiguration) throws -> VZVirtualMachineConfiguration {
        guard let hardware = VZMacHardwareModel(dataRepresentation: try Data(contentsOf: bundle.appendingPathComponent("HardwareModel"))),
              hardware.isSupported,
              let identifier = VZMacMachineIdentifier(dataRepresentation: try Data(contentsOf: bundle.appendingPathComponent("MachineIdentifier"))),
              let mac = VZMACAddress(string: image.macAddress) else {
            throw BuildError("Invalid or unsupported macOS platform files")
        }
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardware
        platform.machineIdentifier = identifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: bundle.appendingPathComponent("AuxiliaryStorage"))

        let config = VZVirtualMachineConfiguration()
        config.platform = platform
        config.bootLoader = VZMacOSBootLoader()
        config.cpuCount = image.cpuCount
        config.memorySize = image.memoryMiB * 1024 * 1024
        let disk = VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(
            url: bundle.appendingPathComponent("disk.raw"), readOnly: false))
        config.storageDevices = [disk]
        let network = VZVirtioNetworkDeviceConfiguration()
        network.macAddress = mac
        network.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [network]
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1280, heightInPixels: 800, pixelsPerInch: 80)]
        config.graphicsDevices = [graphics]
        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        try config.validate()
        return config
    }

    func execute() async throws {
        let args = CommandLine.arguments
        guard args.count == 4, ["install", "provision"].contains(args[1]) else {
            throw BuildError("Usage: macos-image-native install BUNDLE IPSW | provision BUNDLE PASSWORD_FILE")
        }
        guard VZVirtualMachine.isSupported else { throw BuildError("Virtualization is unavailable on this host") }
        let bundle = URL(fileURLWithPath: args[2], isDirectory: true)
        let image = try JSONDecoder().decode(ImageConfiguration.self, from: Data(contentsOf: bundle.appendingPathComponent("image.json")))

        if args[1] == "install" {
            let ipsw = URL(fileURLWithPath: args[3])
            let restore = try await VZMacOSRestoreImage.image(from: ipsw)
            guard restore.operatingSystemVersion.majorVersion >= 27 else {
                throw BuildError("The IPSW must contain macOS 27 or later")
            }
            guard let requirements = restore.mostFeaturefulSupportedConfiguration else {
                throw BuildError("This host does not support the selected restore image")
            }
            guard image.cpuCount >= requirements.minimumSupportedCPUCount,
                  image.memoryMiB * 1024 * 1024 >= requirements.minimumSupportedMemorySize else {
                throw BuildError("The recipe allocates less CPU or memory than this restore image requires")
            }
            try requirements.hardwareModel.dataRepresentation.write(to: bundle.appendingPathComponent("HardwareModel"))
            try VZMacMachineIdentifier().dataRepresentation.write(to: bundle.appendingPathComponent("MachineIdentifier"))
            _ = try VZMacAuxiliaryStorage(creatingStorageAt: bundle.appendingPathComponent("AuxiliaryStorage"), hardwareModel: requirements.hardwareModel)
            let diskURL = bundle.appendingPathComponent("disk.raw")
            guard FileManager.default.createFile(atPath: diskURL.path, contents: nil) else {
                throw BuildError("Could not create the VM disk")
            }
            let disk = try FileHandle(forWritingTo: diskURL)
            try disk.truncate(atOffset: image.diskGiB * 1024 * 1024 * 1024)
            try disk.close()
            let version = restore.operatingSystemVersion
            let versionString = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            let metadata: [String: Any] = [
                "version": versionString,
                "build": restore.buildVersion,
                "minimumCPUCount": requirements.minimumSupportedCPUCount,
                "minimumMemorySize": requirements.minimumSupportedMemorySize,
            ]
            try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
                .write(to: bundle.appendingPathComponent("restore.json"))
            let vm = VZVirtualMachine(configuration: try Self.configuration(bundle: bundle, image: image))
            let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipsw)
            print("Installing macOS \(versionString) (\(restore.buildVersion))...")
            fflush(stdout)
            let progress = installer.progress
            let started = ProcessInfo.processInfo.systemUptime
            let progressTask = Task { @MainActor in
                while !Task.isCancelled {
                    let percent = String(format: "%.1f", progress.fractionCompleted * 100)
                    let elapsed = Int(ProcessInfo.processInfo.systemUptime - started)
                    print("macOS installation: \(percent)% (\(elapsed / 60)m \(elapsed % 60)s elapsed)")
                    fflush(stdout)
                    try await Task.sleep(for: .seconds(5))
                }
            }
            defer { progressTask.cancel() }
            try await installer.install()
            print("macOS installation completed")
            fflush(stdout)
            exit(EXIT_SUCCESS)
        }

        let vm = VZVirtualMachine(configuration: try Self.configuration(bundle: bundle, image: image))
        virtualMachine = vm
        vm.delegate = self
        let view = VZVirtualMachineView()
        view.virtualMachine = vm
        view.capturesSystemKeys = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        window.title = "macOS image provisioning"
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        self.window = window
        let provisioning = VZMacGuestProvisioningOptions()
        provisioning.fullName = image.user
        provisioning.username = image.user
        provisioning.password = try String(contentsOfFile: args[3], encoding: .utf8)
        provisioning.enablesRemoteLogin = true
        provisioning.logsInAutomatically = false
        let options = VZMacOSVirtualMachineStartOptions()
        try options.setGuestProvisioning(provisioning)
        try await vm.start(options: options)
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) { exit(EXIT_SUCCESS) }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        fputs("macos-image: \(error.localizedDescription)\n", stderr)
        exit(EXIT_FAILURE)
    }

    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let installer = Installer()
        Task { @MainActor in
            do {
                try await installer.execute()
            } catch {
                fputs("macos-image: \(error.localizedDescription)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }
        withExtendedLifetime(installer) { application.run() }
    }
}
