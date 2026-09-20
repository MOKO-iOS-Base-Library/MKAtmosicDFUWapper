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
        self.progressBlock = progressBlock
        self.sucBlock = sucBlock
        self.failedBlock = failedBlock

        bleManager.invoke()
        bleManager.setFileLoggingEnabled(false)
        bleManager.registerBleManagerDelegate(observerName, self)

        // 关键：先不创建 OtaTaskManager！
        // 等密码写入成功后再创建，防止它自动触发 queryInfo → lockSession

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

    /// 写入连接密码到 AA04
    private func sendConnectPassword(to charc: CBCharacteristic) {
        guard let peripheral = targetPeripheral else { return }

        let passwordData = connectPassword.data(using: .utf8) ?? Data()

        NSLog("[MKAtmosicDFU] Writing password to AA04 via peripheral.writeValue...")
        peripheral.writeValue(passwordData, for: charc, type: .withResponse)

        // 备用定时器：如果 2 秒内没收到 OnCharacWrote 回调，也继续
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

    /// 密码确认后，创建 OtaTaskManager 并启动 OTA 流程
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

        // OnOtaCharcSetupDone 可能已经触发过了
        if otaCharcSetupFired {
            NSLog("[MKAtmosicDFU] OnOtaCharcSetupDone already fired, calling queryInfo() manually")
            otaManager?.queryInfo()
        }
        // 否则 OtaTaskManager 会在 OnOtaCharcSetupDone 时自动调 queryInfo()
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
        NSLog("[MKAtmosicDFU] Connected, waiting for characteristics...")
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

    public func OnFounCharacteristics(charcs: [CBCharacteristic]) {
        // 特征值发现后，找到 AA04 并写入密码
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
        if charc.uuid == passwordCharcUUID {
            NSLog("[MKAtmosicDFU] Password write confirmed by device!")
            onPasswordConfirmed()
        }
    }

    public func OnOtaCharcSetupDone() {
        NSLog("[MKAtmosicDFU] OnOtaCharcSetupDone")
        // 如果 OtaTaskManager 已创建，它自己的 override 会自动调 queryInfo()
        // 如果还没创建（密码未确认），标记事件已触发，等密码确认后手动调 queryInfo()
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
