//
//  MKAtmosicDFUWapper.swift
//  MKAtmosicDFUWapper
//
//  Created by aa on 2026/8/24.
//  Copyright © 2026 lovexiaoxia. All rights reserved.
//

import Foundation
import CoreBluetooth
import blelib

@objc public class MKAtmosicDFUWapper: NSObject {

    private let bleManager: BleManager = .shared
    private var otaManager: OtaTaskManager?
    private var fileUrl: URL?
    private var targetIdentifier: String?
    private var targetPeripheral: CBPeripheral?
    private var isOTAStarted = false
    private var isConnected = false
    private var isScanning = false
    private var isCallbackCalled = false
    private var isCleanedUp = false

    private var progressBlock: ((CGFloat) -> Void)?
    private var sucBlock: (() -> Void)?
    private var failedBlock: ((Error) -> Void)?

    private let observerName = "MKAtmosicDFUWapper"
    private let scanTimeout: TimeInterval = 15.0

    private let passwordServiceUUID = CBUUID(string: "AA00")
    private let passwordCharcUUID = CBUUID(string: "AA04")
    private let connectPassword = "MOKOMOKO"

    private var passwordSent = false
    private var otaCharcSetupFired = false
    private var passwordFallbackTimer: DispatchSourceTimer?

    private var waitingForReconnect = false
    private var reconnectTimeout: TimeInterval = 60.0
    private var reconnectTimer: DispatchSourceTimer?

    private var fotaTotalTimeout: TimeInterval = 300.0
    private var fotaTotalTimer: DispatchSourceTimer?

    private var fotaReconnectCount = 0
    private let maxFotaReconnects = 5

    @objc public func startOTA(filePath: String,
                               deviceIdentifier: String,
                               progressBlock: @escaping (CGFloat) -> Void,
                               sucBlock: @escaping () -> Void,
                               failedBlock: @escaping (Error) -> Void) {
        self.targetIdentifier = deviceIdentifier
        self.fileUrl = URL(fileURLWithPath: filePath)
        self.isOTAStarted = false
        self.isConnected = false
        self.isScanning = false
        self.isCallbackCalled = false
        self.isCleanedUp = false
        self.passwordSent = false
        self.otaCharcSetupFired = false
        self.waitingForReconnect = false
        self.fotaReconnectCount = 0
        self.progressBlock = progressBlock
        self.sucBlock = sucBlock
        self.failedBlock = failedBlock

        bleManager.invoke()
        bleManager.setFileLoggingEnabled(false)
        bleManager.registerBleManagerDelegate(observerName, self)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self, !self.isConnected else { return }
            self.isScanning = true
            self.bleManager.scanPeripherals()

            DispatchQueue.main.asyncAfter(deadline: .now() + self.scanTimeout) { [weak self] in
                guard let self = self, self.isScanning, !self.isConnected else { return }
                self.isScanning = false
                self.bleManager.stopScan()
                self.handleFailure("Device not found, please try again")
            }
        }
    }

    @objc public func cancel() {
        cleanup()
    }

    private func cleanup() {
        guard !isCleanedUp else { return }
        isCleanedUp = true

        passwordFallbackTimer?.cancel()
        passwordFallbackTimer = nil
        reconnectTimer?.cancel()
        reconnectTimer = nil
        fotaTotalTimer?.cancel()
        fotaTotalTimer = nil

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.isScanning {
                self.bleManager.stopScan()
            }
            self.otaManager = nil
            self.bleManager.unregisterBleManagerDelegate(self.observerName)
            self.bleManager.shutdown()
        }
    }

    private func handleFailure(_ msg: String) {
        guard !isCallbackCalled else { return }
        isCallbackCalled = true
        DispatchQueue.main.async {
            let error = NSError(domain: "com.moko.atmosicDfu",
                                code: -999,
                                userInfo: [NSLocalizedDescriptionKey: msg])
            self.failedBlock?(error)
        }
        cleanup()
    }

    private func sendConnectPassword(to charc: CBCharacteristic) {
        guard let peripheral = targetPeripheral else { return }

        let passwordData = connectPassword.data(using: .utf8) ?? Data()

        NSLog("[MKAtmosicDFU] Writing password to AA04 via peripheral.writeValue...")
        peripheral.writeValue(passwordData, for: charc, type: .withResponse)

        passwordFallbackTimer = DispatchSource.makeTimerSource(queue: .main)
        passwordFallbackTimer?.schedule(deadline: .now() + 2.0)
        passwordFallbackTimer?.setEventHandler { [weak self] in
            guard let self = self else { return }
            if !self.passwordSent {
                NSLog("[MKAtmosicDFU] OnCharacWrote not received within 2s, proceeding anyway")
                self.onPasswordConfirmed()
            }
        }
        passwordFallbackTimer?.resume()
    }

    private func onPasswordConfirmed() {
        guard !passwordSent else { return }
        passwordSent = true
        passwordFallbackTimer?.cancel()
        passwordFallbackTimer = nil

        guard !isCleanedUp else { return }

        NSLog("[MKAtmosicDFU] Password confirmed, creating OtaTaskManager...")

        otaManager = OtaTaskManager(bleManager: bleManager)
        otaManager?.registerObserver(observerName: observerName, observer: self)
        otaManager?.registerOtaInfoObserver(observerName: observerName, observer: self)
        otaManager?.setForceNoTestBoot(true)

        if otaCharcSetupFired {
            NSLog("[MKAtmosicDFU] OnOtaCharcSetupDone already fired, calling queryInfo() manually")
            otaManager?.queryInfo()
        }
    }
}

// MARK: - BleManagerDelegate
extension MKAtmosicDFUWapper: BleManagerDelegate {

    public func OnFoundPeripheral(wrapPeripheral: WrapScanResult) {
        guard isScanning, !isConnected,
              let peripheral = wrapPeripheral.peripheral,
              let target = targetIdentifier else { return }

        if peripheral.identifier.uuidString == target {
            isScanning = false
            targetPeripheral = peripheral
            bleManager.stopScan()
            bleManager.connect(peripheral: peripheral)
        }
    }

    public func UpdateFoundPeripheralList(wrapPeripherals: [WrapScanResult]) {}

    public func OnConnected(wrapPeripheral: WrapScanResult, mtu: Int) {
        isConnected = true
        targetPeripheral = wrapPeripheral.peripheral

        if isOTAStarted {
            NSLog("[MKAtmosicDFU] Reconnected during FOTA, OtaTaskManager will resume upload")
            reconnectTimer?.cancel()
            reconnectTimer = nil
            waitingForReconnect = false
        } else if waitingForReconnect {
            NSLog("[MKAtmosicDFU] Reconnected after lockSession reboot")
            waitingForReconnect = false
            reconnectTimer?.cancel()
            reconnectTimer = nil
        } else {
            NSLog("[MKAtmosicDFU] Connected, waiting for characteristics...")
        }
    }

    public func OnDisconnected() {
        NSLog("[MKAtmosicDFU] OnDisconnected: isOTAStarted=\(isOTAStarted), otaManager=\(otaManager != nil), waitingForReconnect=\(waitingForReconnect)")

        isConnected = false

        if isOTAStarted && !isCallbackCalled && !isCleanedUp {
            fotaReconnectCount += 1
            NSLog("[MKAtmosicDFU] Disconnected during FOTA (reconnect #\(fotaReconnectCount)/\(maxFotaReconnects))")
            if fotaReconnectCount > maxFotaReconnects {
                handleFailure("Device reconnected too many times during FOTA, please try again")
                return
            }
            waitingForReconnect = true
            bleManager.reconnect()

            reconnectTimer?.cancel()
            reconnectTimer = DispatchSource.makeTimerSource(queue: .main)
            reconnectTimer?.schedule(deadline: .now() + reconnectTimeout)
            reconnectTimer?.setEventHandler { [weak self] in
                guard let self = self else { return }
                if self.waitingForReconnect {
                    NSLog("[MKAtmosicDFU] Reconnect timeout after \(self.reconnectTimeout)s")
                    self.handleFailure("Device did not reconnect after FOTA reboot, please try again")
                }
            }
            reconnectTimer?.resume()
        } else if otaManager != nil && !isOTAStarted && !isCallbackCalled && !isCleanedUp {
            NSLog("[MKAtmosicDFU] Disconnected after lockSession, calling reconnect...")
            waitingForReconnect = true
            bleManager.reconnect()

            reconnectTimer = DispatchSource.makeTimerSource(queue: .main)
            reconnectTimer?.schedule(deadline: .now() + reconnectTimeout)
            reconnectTimer?.setEventHandler { [weak self] in
                guard let self = self else { return }
                if self.waitingForReconnect {
                    NSLog("[MKAtmosicDFU] Reconnect timeout after \(self.reconnectTimeout)s")
                    self.handleFailure("Device did not reconnect after reboot, please try again")
                }
            }
            reconnectTimer?.resume()
        } else if !isOTAStarted && !isScanning && !isCleanedUp {
            handleFailure("Device disconnected before OTA started")
        }
    }

    public func OnFoundServices(services: [CBService]) {}

    public func OnFounCharacteristics(charcs: [CBCharacteristic]) {
        if isOTAStarted {
            NSLog("[MKAtmosicDFU] FOTA in progress, skipping password - OtaTaskManager handles reconnect")
            return
        }
        if waitingForReconnect {
            NSLog("[MKAtmosicDFU] Reconnected - skipping password")
            return
        }
        for charc in charcs {
            if charc.uuid == passwordCharcUUID {
                NSLog("[MKAtmosicDFU] Found AA04 characteristic, sending password...")
                sendConnectPassword(to: charc)
                break
            }
        }
    }

    public func OnCharcteristicChanged(charc: CBCharacteristic) {}

    public func OnCharacNotifyEnabled(charc: CBCharacteristic) {}

    public func OnCharacWrote(charc: CBCharacteristic) {
        NSLog("[MKAtmosicDFU] OnCharacWrote: \(charc.uuid.uuidString)")
        if charc.uuid == passwordCharcUUID && !isOTAStarted {
            NSLog("[MKAtmosicDFU] Password write confirmed by device!")
            onPasswordConfirmed()
        }
    }

    public func OnOtaCharcSetupDone() {
        NSLog("[MKAtmosicDFU] OnOtaCharcSetupDone")
        if otaManager == nil {
            otaCharcSetupFired = true
            NSLog("[MKAtmosicDFU] OtaTaskManager not yet created, flag set for later")
        }
    }
}

// MARK: - OnATTaskObserver
extension MKAtmosicDFUWapper: OnATTaskObserver {

    public func OnTaskCompleted(completedTask: ATTask) {}

    public func OnTaskProgress(progressTask: ATTask, percentage: Float) {
        let progress = CGFloat(percentage)
        DispatchQueue.main.async {
            self.progressBlock?(progress)
        }
    }

    public func OnTaskError(errorTask: ATTask, errorMsg: String) {
        NSLog("[MKAtmosicDFU] OnTaskError: \(errorMsg)")
        if errorMsg.contains("unexpected event") {
            NSLog("[MKAtmosicDFU] Ignoring unexpected event error during lockSession reboot")
            return
        }
        handleFailure(errorMsg)
    }

    public func OnOverAllProgress(percentage: Float) {
        let progress = CGFloat(percentage)
        DispatchQueue.main.async {
            self.progressBlock?(progress)
        }
    }

    public func OnReconnecting() {
        NSLog("[MKAtmosicDFU] OnReconnecting...")
    }

    public func OnFirmwareUpdatedSuccess() {
        guard !isCallbackCalled else { return }
        isCallbackCalled = true
        DispatchQueue.main.async {
            self.sucBlock?()
        }
        cleanup()
    }

    public func OnUserDataUpdated() {}

    public func OnBankSwitchError() {
        handleFailure("Bank switch failure")
    }
}

// MARK: - OnATOTAInfoObserver
extension MKAtmosicDFUWapper: OnATOTAInfoObserver {

    public func OnFwVersionQueried(fwVersion: String) {}

    public func OnOtaProtocolVersion(protocolVersion: UInt8) {
        if isOTAStarted {
            NSLog("[MKAtmosicDFU] OnOtaProtocolVersion after reconnect (already started), skipping startFota")
            return
        }
        NSLog("[MKAtmosicDFU] OnOtaProtocolVersion: \(protocolVersion), starting FOTA...")
        guard let url = fileUrl else {
            handleFailure("Firmware file URL is invalid")
            return
        }
        do {
            try otaManager?.checkArchive(selectedFileUri: url)
            try otaManager?.startFota(upgradeBin: true, upgradeNvds: false)
            isOTAStarted = true
            NSLog("[MKAtmosicDFU] FOTA started, isOTAStarted=true")

            fotaTotalTimer = DispatchSource.makeTimerSource(queue: .main)
            fotaTotalTimer?.schedule(deadline: .now() + fotaTotalTimeout)
            fotaTotalTimer?.setEventHandler { [weak self] in
                guard let self = self else { return }
                if !self.isCallbackCalled {
                    NSLog("[MKAtmosicDFU] FOTA total timeout after \(self.fotaTotalTimeout)s")
                    self.handleFailure("Firmware update timed out, please try again")
                }
            }
            fotaTotalTimer?.resume()
        } catch OtaError.runtimeError(let msg) {
            handleFailure(msg)
        } catch {
            handleFailure("Failed to start OTA")
        }
    }
}
