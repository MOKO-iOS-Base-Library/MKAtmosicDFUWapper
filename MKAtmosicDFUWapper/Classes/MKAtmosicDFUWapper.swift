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
    private var peripheral: CBPeripheral?
    private var fileUrl: URL?
    private var isOTAStarted = false
    private var isConnected = false

    private var progressBlock: ((CGFloat) -> Void)?
    private var sucBlock: (() -> Void)?
    private var failedBlock: ((Error) -> Void)?

    private let observerName = "MKAtmosicDFUWapper"
    private let maxConnectAttempts = 5
    private let connectInterval: TimeInterval = 1.0

    @objc public func startOTA(filePath: String,
                               peripheral: CBPeripheral,
                               progressBlock: @escaping (CGFloat) -> Void,
                               sucBlock: @escaping () -> Void,
                               failedBlock: @escaping (Error) -> Void) {
        self.peripheral = peripheral
        self.fileUrl = URL(fileURLWithPath: filePath)
        self.isOTAStarted = false
        self.isConnected = false
        self.progressBlock = progressBlock
        self.sucBlock = sucBlock
        self.failedBlock = failedBlock

        bleManager.invoke()
        bleManager.registerBleManagerDelegate(observerName, self)

        otaManager = OtaTaskManager(bleManager: bleManager)
        otaManager?.registerObserver(observerName: observerName, observer: self)
        otaManager?.registerOtaInfoObserver(observerName: observerName, observer: self)

        let identifier = peripheral.identifier.uuidString
        tryConnect(deviceIdentifier: identifier, attempt: 0)
    }

    /// invoke() creates a CBCentralManager that needs ~1s to reach .poweredOn.
    /// Use connect(deviceIdentifier:) so blelib's own CBCentralManager retrieves
    /// the peripheral by UUID instead of reusing a CBPeripheral from another
    /// CBCentralManager.
    private func tryConnect(deviceIdentifier: String, attempt: Int) {
        if attempt >= maxConnectAttempts {
            handleFailure("Bluetooth is not ready, please try again")
            return
        }
        if isConnected { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + connectInterval) { [weak self] in
            guard let self = self, !self.isConnected else { return }
            self.bleManager.connect(deviceIdentifier: deviceIdentifier)
            self.tryConnect(deviceIdentifier: deviceIdentifier, attempt: attempt + 1)
        }
    }

    @objc public func cancel() {
        bleManager.disconnect()
        bleManager.unregisterBleManagerDelegate(observerName)
        otaManager = nil
        cleanupLogFile()
    }

    private func cleanupLogFile() {
        let logUrl = bleManager.getCurrentLogUrl()
        try? FileManager.default.removeItem(at: logUrl)
    }

    private func handleFailure(_ msg: String) {
        DispatchQueue.main.async {
            let error = NSError(domain: "com.moko.atmosicDfu",
                                code: -999,
                                userInfo: [NSLocalizedDescriptionKey: msg])
            self.failedBlock?(error)
        }
    }
}

// MARK: - BleManagerDelegate
extension MKAtmosicDFUWapper: BleManagerDelegate {

    public func OnFoundPeripheral(wrapPeripheral: WrapScanResult) {}

    public func UpdateFoundPeripheralList(wrapPeripherals: [WrapScanResult]) {}

    public func OnConnected(wrapPeripheral: WrapScanResult, mtu: Int) {
        isConnected = true
        otaManager?.queryInfo()
    }

    public func OnDisconnected() {
        isConnected = false
        if !isOTAStarted {
            handleFailure("Device disconnected before OTA started")
        }
    }

    public func OnFoundServices(services: [CBService]) {}

    public func OnFounCharacteristics(charcs: [CBCharacteristic]) {}

    public func OnCharcteristicChanged(charc: CBCharacteristic) {}

    public func OnCharacNotifyEnabled(charc: CBCharacteristic) {}

    public func OnCharacWrote(charc: CBCharacteristic) {}

    public func OnOtaCharcSetupDone() {
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
        DispatchQueue.main.async {
            self.sucBlock?()
        }
        cleanupLogFile()
    }

    public func OnUserDataUpdated() {}

    public func OnBankSwitchError() {
        handleFailure("Bank switch failure")
    }
}

// MARK: - OnATOTAInfoObserver
extension MKAtmosicDFUWapper: OnATOTAInfoObserver {

    public func OnFwVersionQueried(fwVersion: String) {}

    public func OnOtaProtocolVersion(protocolVersion: UInt8) {}
}
