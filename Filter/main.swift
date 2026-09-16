import Foundation
import NetworkExtension

autoreleasepool {
    NEProvider.startSystemExtensionMode()
    ControlService.shared.start()
}

dispatchMain()
