import Foundation
import IOKit

public enum OpticalDriveIdentity {
    /// Model + firmware from the actual BSD device's I/O Registry ancestors.
    /// No serial number is persisted. An unidentified drive never inherits another drive's offset.
    public static func identifier(device: String) -> String? {
        guard device.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil else { return nil }
        var entry = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, device))
        guard entry != 0 else { return nil }
        var fields: [String: String] = [:]
        for _ in 0..<24 {
            let characteristics = IORegistryEntryCreateCFProperty(entry, "Device Characteristics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
            for key in ["Vendor Identification", "Product Identification", "Product Revision Level"] where fields[key] == nil {
                if let value = (IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String) ?? characteristics?[key] as? String {
                    let normalized = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    if !normalized.isEmpty { fields[key] = normalized }
                }
            }
            if let vendor = fields["Vendor Identification"], let model = fields["Product Identification"], let firmware = fields["Product Revision Level"] {
                IOObjectRelease(entry)
                return "\(vendor) | \(model) | \(firmware)"
            }
            var parent: io_registry_entry_t = 0
            let status = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            guard status == KERN_SUCCESS, parent != 0 else { return nil }
            entry = parent
        }
        IOObjectRelease(entry)
        return nil
    }
}
