//
//  File.swift
//  
//
//  Created by Michael on 23/12/2023.
//

import Foundation
@_implementationOnly import CoreBluetooth

extension CatPrinter {
    struct BluetoothInfo {
        let peripheral: CBPeripheral
        let service: CBService
        let characteristic: CBCharacteristic
    }
}
