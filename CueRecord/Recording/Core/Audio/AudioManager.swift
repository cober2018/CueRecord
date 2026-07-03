import Foundation
import AVFoundation
import Combine
import CoreAudio
import ScreenCaptureKit

// MARK: - 音频设备模型
struct AudioDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let deviceID: AudioDeviceID?
    let deviceUID: String?
    let screenCaptureKitDeviceID: String?
    
    static let defaultDevice = AudioDevice(
        id: "default",
        name: "Default Device",
        deviceID: nil,
        deviceUID: nil,
        screenCaptureKitDeviceID: nil
    )
}

// MARK: - 音频管理器
@MainActor
class AudioManager: ObservableObject {
    @Published var availableMicrophones: [AudioDevice] = []
    @Published var selectedMicrophone: AudioDevice = AudioDevice.defaultDevice
    @Published var isLoading = false

    private var audioDeviceListener: AudioObjectPropertyListenerBlock?
    private var refreshTask: Task<Void, Never>?
    
    // macOS版本检查
    private var supportsSCKMicrophone: Bool {
        if #available(macOS 15.0, *) {
            return true
        }
        return false
    }
    
    init() {
        print("🎤 初始化音频管理器...")
        startAudioDeviceObservation()
        Task {
            await refreshMicrophoneDevices()
        }
    }

    // MARK: - 设备热插拔监听
    private func startAudioDeviceObservation() {
        guard audioDeviceListener == nil else { return }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.scheduleMicrophoneRefresh()
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main,
            listener
        )

        if status == noErr {
            audioDeviceListener = listener
            print("🎤 已监听麦克风设备变化")
        } else {
            print("⚠️  麦克风设备监听失败: \(status)")
        }
    }

    private func scheduleMicrophoneRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await self?.refreshMicrophoneDevices()
        }
    }
    
    // MARK: - 设备枚举
    func refreshMicrophoneDevices() async {
        print("🎤 刷新麦克风设备列表...")
        isLoading = true
        
        do {
            let devices = try await enumerateAudioInputDevices()
            await MainActor.run {
                self.availableMicrophones = [AudioDevice.defaultDevice] + devices
                // 如果当前选择的设备仍在列表中，用刷新后的 ID 信息替换；否则重置为默认。
                if let refreshedSelection = self.availableMicrophones.first(where: { $0.id == selectedMicrophone.id }) {
                    self.selectedMicrophone = refreshedSelection
                } else {
                    self.selectedMicrophone = AudioDevice.defaultDevice
                }
                self.isLoading = false
                print("✅ 找到 \(devices.count) 个麦克风设备")
            }
        } catch {
            await MainActor.run {
                print("❌ 枚举音频设备失败: \(error.localizedDescription)")
                self.availableMicrophones = [AudioDevice.defaultDevice]
                self.selectedMicrophone = AudioDevice.defaultDevice
                self.isLoading = false
            }
        }
    }
    
    private func enumerateAudioInputDevices() async throws -> [AudioDevice] {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let devices = try self.getAudioInputDevices()
                    continuation.resume(returning: devices)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    nonisolated private func getAudioInputDevices() throws -> [AudioDevice] {
        var devices: [AudioDevice] = []
        let avCaptureDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
        
        // 获取所有音频设备数量
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )
        
        guard status == noErr else {
            throw NSError(domain: "AudioError", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Could not get audio device list size"
            ])
        }
        
        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array<AudioDeviceID>(repeating: 0, count: deviceCount)
        
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )
        
        guard status == noErr else {
            throw NSError(domain: "AudioError", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Could not get audio device list"
            ])
        }
        
        // 筛选输入设备
        for deviceID in deviceIDs {
            if let device = try? createAudioDevice(from: deviceID, avCaptureDevices: avCaptureDevices), isInputDevice(deviceID) {
                devices.append(device)
            }
        }
        
        return devices
    }
    
    nonisolated private func createAudioDevice(
        from deviceID: AudioDeviceID,
        avCaptureDevices: [AVCaptureDevice]
    ) throws -> AudioDevice {
        let name = try stringProperty(
            deviceID: deviceID,
            selector: kAudioDevicePropertyDeviceNameCFString,
            errorDescription: "Could not get device name"
        )
        let deviceUID = try? stringProperty(
            deviceID: deviceID,
            selector: kAudioDevicePropertyDeviceUID,
            errorDescription: "Could not get device UID"
        )
        let screenCaptureKitDeviceID = matchingAVCaptureDeviceID(
            deviceUID: deviceUID,
            name: name,
            avCaptureDevices: avCaptureDevices
        )

        return AudioDevice(
            id: deviceUID ?? String(deviceID),
            name: name,
            deviceID: deviceID,
            deviceUID: deviceUID,
            screenCaptureKitDeviceID: screenCaptureKitDeviceID
        )
    }

    nonisolated private func stringProperty(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        errorDescription: String
    ) throws -> String {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        guard status == noErr else {
            throw NSError(domain: "AudioError", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "\(errorDescription) size"
            ])
        }

        var propertyValue: Unmanaged<CFString>?
        status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &propertyValue
        )

        guard status == noErr,
              let valueRef = propertyValue?.takeRetainedValue(),
              let value = valueRef as String? else {
            throw NSError(domain: "AudioError", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: errorDescription
            ])
        }

        return value
    }

    nonisolated private func matchingAVCaptureDeviceID(
        deviceUID: String?,
        name: String,
        avCaptureDevices: [AVCaptureDevice]
    ) -> String? {
        if let deviceUID,
           let matchingDevice = avCaptureDevices.first(where: { $0.uniqueID == deviceUID }) {
            return matchingDevice.uniqueID
        }

        let sameNameDevices = avCaptureDevices.filter { $0.localizedName == name }
        if sameNameDevices.count == 1 {
            return sameNameDevices[0].uniqueID
        }

        return nil
    }
    
    nonisolated private func isInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize
        )
        
        return status == noErr && dataSize > 0
    }
    
    // MARK: - 设备选择
    func selectMicrophone(_ device: AudioDevice) {
        print("🎤 选择麦克风设备: \(device.name)")
        selectedMicrophone = device
    }
    
    // MARK: - SCK集成支持
    func getMicrophoneDeviceIDForSCK() -> String? {
        guard selectedMicrophone.id != AudioDevice.defaultDevice.id else {
            return nil  // 使用默认设备
        }

        // ScreenCaptureKit expects AVCaptureDevice.uniqueID, not CoreAudio's numeric AudioDeviceID.
        return selectedMicrophone.screenCaptureKitDeviceID ?? selectedMicrophone.deviceUID
    }
    
    // MARK: - macOS版本适配
    func getRecommendedAudioConfiguration() -> AudioConfiguration {
        if supportsSCKMicrophone {
            return AudioConfiguration(
                method: .screenCaptureKit,
                description: "Use native ScreenCaptureKit microphone support (macOS 15+)"
            )
        } else {
            return AudioConfiguration(
                method: .avAudioEngine,
                description: "Use AVAudioEngine compatibility mode (macOS 13-14)"
            )
        }
    }
}

// MARK: - 音频配置模型
struct AudioConfiguration {
    enum Method {
        case screenCaptureKit  // macOS 15+
        case avAudioEngine     // macOS 13-14 兼容
    }
    
    let method: Method
    let description: String
}
