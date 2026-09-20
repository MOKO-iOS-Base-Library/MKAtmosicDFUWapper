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
    private let passwordTimeout: TimeInterval = 10.0

    private let passwordServiceUUID = CBUUID(string: "AA00")
    private let passwordCharcUUID = CBUUID(string: "AA04")
    private let connectPassword = "MOKOMOKO"

    private var passwordSent = false
    private var otaCharcReady = false
    private var passwordWriteTimer: DispatchSourceTimer?

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
        self.otaCharcReady = false
        self.progressBlock = progressBlock
        self.sucBlock = sucBlock
        self.failedBlock = failedBlock

        bleManager.invoke()
        bleManager.setFileLoggingEnabled(false)
        bleManager.registerBleManagerDelegate(observerName, self)

        otaManager = OtaTaskManager(bleManager: bleManager)
        otaManager?.registerObserver(observerName: observerName, observer: self)
        otaManager?.registerOtaInfoObserver(observerName: observerName, observer: self)
        otaManager?.setForceNoTestBoot(true)

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

        passwordWriteTimer?.cancel()
        passwordWriteTimer = nil

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

    private func sendConnectPassword() {
        guard let peripheral = targetPeripheral else {
            handleFailure("No peripheral connected")
            return
        }

        let passwordData = connectPassword.data(using: .utf8) ?? Data()
        bleManager.writeCharc(serviceUUID: passwordServiceUUID,
                              charcUUID: passwordCharcUUID,
                              data: passwordData,
                              isWithResp: true)

        passwordWriteTimer = DispatchSource.makeTimerSource(queue: .main)
        passwordWriteTimer?.schedule(deadline: .now() + passwordTimeout)
        passwordWriteTimer?.setEventHandler { [weak self] in
            guard let self = self else { return }
            if !self.passwordSent {
                self.handleFailure("Password authentication timeout")
            }
        }
        passwordWriteTimer?.resume()
    }

    private func tryStartOTA() {
        guard passwordSent, otaCharcReady, !isOTAStarted else { return }
        passwordWriteTimer?.cancel()
        passwordWriteTimer = nil
        otaManager?.queryInfo()
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
        sendConnectPassword()
    }

    public func OnDisconnected() {
        isConnected = false
        if !isOTAStarted && !isScanning && !isCleanedUp {
            handleFailure("Device disconnected before OTA started")
        } else if isOTAStarted && !isCallbackCalled && !isCleanedUp {
            isCallbackCalled = true
            DispatchQueue.main.async {
                self.sucBlock?()
            }
            cleanup()
        }
    }

    public func OnFoundServices(services: [CBService]) {}

    public func OnFounCharacteristics(charcs: [CBCharacteristic]) {}

    public func OnCharcteristicChanged(charc: CBCharacteristic) {}

    public func OnCharacNotifyEnabled(charc: CBCharacteristic) {}

    public func OnCharacWrote(charc: CBCharacteristic) {
        if charc.uuid == passwordCharcUUID {
            passwordSent = true
            tryStartOTA()
        }
    }

    public func OnOtaCharcSetupDone() {
        otaCharcReady = true
        tryStartOTA()
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
