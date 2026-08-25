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
    private var disconnectTimer: Timer?
    private var disconnectAttempts = 0

    private var progressBlock: ((CGFloat) -> Void)?
    private var sucBlock: (() -> Void)?
    private var failedBlock: ((Error) -> Void)?

    private let observerName = "MKAtmosicDFUWapper"
    private let scanTimeout: TimeInterval = 15.0
    private let maxDisconnectAttempts = 10 // 10s total

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
        self.disconnectTimer?.invalidate()
        self.disconnectTimer = nil
        self.disconnectAttempts = 0
        self.progressBlock = progressBlock
        self.sucBlock = sucBlock
        self.failedBlock = failedBlock

        bleManager.invoke()
        bleManager.registerBleManagerDelegate(observerName, self)

        otaManager = OtaTaskManager(bleManager: bleManager)
        otaManager?.registerObserver(observerName: observerName, observer: self)
        otaManager?.registerOtaInfoObserver(observerName: observerName, observer: self)
        otaManager?.setForceNoTestBoot = true

        // Wait for CBCentralManager to power on, then start scanning.
        // BleManager must discover the device itself — OnConnected needs
        // a WrapScanResult that only scanning can create.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self, !self.isConnected else { return }
            self.isScanning = true
            self.bleManager.scanPeripherals()

            // Scan timeout
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

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.isScanning {
                self.bleManager.stopScan()
            }
            self.otaManager = nil
            self.cleanupLogFile()
        }

        // Start repeated disconnect attempts.
        // BleManager auto-reconnects after OTA reboot, so we need to
        // keep disconnecting until the device fully stops reconnecting.
        startDisconnectLoop()
    }

    private func startDisconnectLoop() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.disconnectAttempts = 0
            self.disconnectTimer?.invalidate()
            self.disconnectTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
                guard let self = self else {
                    timer.invalidate()
                    return
                }
                self.disconnectAttempts += 1
                if let peripheral = self.targetPeripheral {
                    self.bleManager.disconnect(peripheral: peripheral)
                } else {
                    self.bleManager.disconnect()
                }
                if self.disconnectAttempts >= self.maxDisconnectAttempts {
                    timer.invalidate()
                    self.disconnectTimer = nil
                    self.bleManager.unregisterBleManagerDelegate(self.observerName)
                    // Delete log file after BleManager is fully idle
                    self.cleanupLogFile()
                }
            }
        }
    }

    private func cleanupLogFile() {
        let logUrl = bleManager.getCurrentLogUrl()
        try? FileManager.default.removeItem(at: logUrl)
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
    }

    public func OnDisconnected() {
        isConnected = false
        if !isOTAStarted && !isScanning && !isCleanedUp {
            handleFailure("Device disconnected before OTA started")
        } else if isOTAStarted && !isCallbackCalled && !isCleanedUp {
            // OTA started and device disconnected — firmware update complete.
            // OnFirmwareUpdatedSuccess may not fire in all SDK versions,
            // so treat post-OTA disconnection as success.
            isCallbackCalled = true
            DispatchQueue.main.async {
                self.sucBlock?()
            }
            cleanup()
        }
        // If isCleanedUp is true, the disconnect is expected (from our disconnect loop)
        // — silently ignore it.
    }

    public func OnFoundServices(services: [CBService]) {}

    public func OnFounCharacteristics(charcs: [CBCharacteristic]) {}

    public func OnCharcteristicChanged(charc: CBCharacteristic) {}

    public func OnCharacNotifyEnabled(charc: CBCharacteristic) {}

    public func OnCharacWrote(charc: CBCharacteristic) {}

    public func OnOtaCharcSetupDone() {
        // Retrieve FW OTA config first — checkArchive/startFota
        // will fail with "Need to retrive FW OTA Config" without this.
        otaManager?.queryInfo()
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
        handleFailure(errorMsg)
    }

    public func OnOverAllProgress(percentage: Float) {
        let progress = CGFloat(percentage)
        DispatchQueue.main.async {
            self.progressBlock?(progress)
        }
    }

    public func OnReconnecting() {}

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
        // FW OTA config retrieved, now safe to start OTA.
        guard let url = fileUrl else {
            handleFailure("Firmware file URL is invalid")
            return
        }
        do {
            try otaManager?.checkArchive(selectedFileUri: url)
            try otaManager?.startFota(upgradeBin: true, upgradeNvds: false)
            isOTAStarted = true
        } catch OtaError.runtimeError(let msg) {
            handleFailure(msg)
        } catch {
            handleFailure("Failed to start OTA")
        }
    }
}
