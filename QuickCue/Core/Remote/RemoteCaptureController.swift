import Combine
import CoreBluetooth
import Foundation

enum CaptureTriggerSource: String, Sendable {
    case screenButton
    case systemCameraButton
    case customBLE
    case photoLibrary
}

@MainActor
protocol CaptureTriggering: AnyObject {
    var onCapture: ((CaptureTriggerSource) -> Void)? { get set }
    func start()
    func stop()
}

/// Adapter for a documented BLE GATT button. System camera-button events are handled
/// separately by SwiftUI while the viewfinder is active.
@MainActor
final class BLERemoteCaptureController: NSObject, ObservableObject, CaptureTriggering {
    @Published private(set) var status = "Не настроено"
    var onCapture: ((CaptureTriggerSource) -> Void)?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var serviceUUID: CBUUID?
    private var triggerCharacteristicUUID: CBUUID?
    private var triggerDebouncer = CaptureTriggerDebouncer()

    init(serviceUUID: String? = nil, triggerCharacteristicUUID: String? = nil) {
        self.serviceUUID = serviceUUID.map { CBUUID(string: $0) }
        self.triggerCharacteristicUUID = triggerCharacteristicUUID.map { CBUUID(string: $0) }
        super.init()
    }

    func configure(serviceUUID: String, triggerCharacteristicUUID: String) {
        let service = serviceUUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let characteristic = triggerCharacteristicUUID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.serviceUUID = service.isEmpty ? nil : CBUUID(string: service)
        self.triggerCharacteristicUUID = characteristic.isEmpty ? nil : CBUUID(string: characteristic)
        status = self.serviceUUID == nil || self.triggerCharacteristicUUID == nil
            ? "Нужны UUID совместимой BLE-кнопки"
            : "Готово к подключению"
    }

    func start() {
        guard central == nil else { return }
        guard serviceUUID != nil, triggerCharacteristicUUID != nil else {
            status = "Нужны UUID совместимой BLE-кнопки"
            return
        }
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func stop() {
        central?.stopScan()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        central = nil
        status = "Остановлено"
    }
}

extension BLERemoteCaptureController: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            guard central.state == .poweredOn, let serviceUUID else {
                status = "Bluetooth недоступен"
                return
            }
            status = "Поиск кнопки…"
            central.scanForPeripherals(withServices: [serviceUUID])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        Task { @MainActor in
            central.stopScan()
            self.peripheral = peripheral
            peripheral.delegate = self
            central.connect(peripheral)
            status = "Подключение…"
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            status = "Поиск команды…"
            if let serviceUUID { peripheral.discoverServices([serviceUUID]) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard error == nil, let triggerCharacteristicUUID else { status = "Ошибка BLE-сервиса"; return }
            peripheral.services?.forEach { peripheral.discoverCharacteristics([triggerCharacteristicUUID], for: $0) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            guard error == nil, let triggerCharacteristicUUID else { status = "Ошибка BLE-команды"; return }
            if let characteristic = service.characteristics?.first(where: { $0.uuid == triggerCharacteristicUUID }) {
                peripheral.setNotifyValue(true, for: characteristic)
                status = "Кнопка подключена"
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil else { return }
        Task { @MainActor in
            guard triggerDebouncer.accept() else { return }
            onCapture?(.customBLE)
        }
    }
}
