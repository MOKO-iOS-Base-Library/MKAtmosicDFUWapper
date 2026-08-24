//
//  AtmosicDFUWrapper.swift
//  MKAtmosicDFUWapper
//
//  Created by aa on 2026/8/24.
//  Copyright © 2026 lovexiaoxia. All rights reserved.
//

import Foundation
import CoreBluetooth
import blelib

@objc public class AtmosicDFUWrapper: NSObject {

    private let bleManager: BleManager = .shared
    private var otaManager: OtaTaskManager?
    private var peripheral: CBPeripheral?
    private var fileUrl: URL?
    private var isOTAStarted = false

    private var progressBlock: ((CGFloat) -> Void)?
    private var sucBlock: (() -> Void)?
    private var failedBlock: ((Error) -> Void)?

    private let observerName = "AtmosicDFUWrapper"

    @objc public func startOTA(filePath: String,
                               peripheral: CBPeripheral,
                               progressBlock: @escaping (CGFloat) -> Void,
                               sucBlock: @escaping () -> Void,
                               failedBlock: @escaping (Error) -> Void) {
        self.peripheral = peripheral
        self.fileUrl = URL(fileURLWithPath: filePath)
        self.isOTAStarted = false
        self.progressBlock = progressBlock
        self.sucBlock = sucBlock
        self.failedBlock = failedBlock

        bleManager.invoke()
        bleManager.registerBleManagerDelegate(observerName, self)

        otaManager = OtaTaskManager(bleManager: bleManager)
        otaManager?.registerObserver(observerName: observerName, observer: self)
        otaManager?.registerOtaInfoObserver(observerName: observerName, observer: self)

        bleManager.connect(peripheral: peripheral)
    }

    @objc public func cancel() {
        bleManager.disconnect()
        bleManager.unregisterBleManagerDelegate(observerName)
        otaManager = nil
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
extension AtmosicDFUWrapper: BleManagerDelegate {

    public func OnFoundPeripheral(wrapPeripheral: WrapScanResult) {}

    public func UpdateFoundPeripheralList(wrapPeripherals: [WrapScanResult]) {}

    public func OnConnected(wrapPeripheral: WrapScanResult, mtu: Int) {
        otaManager?.queryInfo()
    }

    public func OnDisconnected() {
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
extension AtmosicDFUWrapper: OnATTaskObserver {

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
    }

    public func OnUserDataUpdated() {}

    public func OnBankSwitchError() {
        handleFailure("Bank switch failure")
    }
}

// MARK: - OnATOTAInfoObserver
extension AtmosicDFUWrapper: OnATOTAInfoObserver {

    public func OnFwVersionQueried(fwVersion: String) {}

    public func OnOtaProtocolVersion(protocolVersion: UInt8) {}
}
