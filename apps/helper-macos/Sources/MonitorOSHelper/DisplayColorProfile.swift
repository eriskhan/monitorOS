import ColorSync
import CoreGraphics
import Foundation

enum MonitorOSDisplayColorProfile {
    private enum InitializationResult {
        case applied
        case alreadyCustomized
        case notRegistered
        case failed(String)
    }

    private static let registrationAttempts = 50

    @MainActor
    static func initializeDisplayP3IfNeeded(
        displayID: CGDirectDisplayID
    ) async {
        for attempt in 0..<registrationAttempts {
            switch initializeOnce(displayID: displayID) {
            case .applied:
                print(
                    "monitorOS Helper: ColorSync profile initialized to Display P3"
                )
                return

            case .alreadyCustomized:
                print(
                    "monitorOS Helper: keeping existing ColorSync profile selection"
                )
                return

            case .notRegistered:
                if attempt + 1 < registrationAttempts {
                    try? await Task.sleep(for: .milliseconds(100))
                    continue
                }

                fputs(
                    "monitorOS Helper: ColorSync did not register iMac 5K; " +
                    "leaving its profile unchanged\n",
                    stderr
                )
                return

            case let .failed(message):
                fputs(
                    "monitorOS Helper: Display P3 profile initialization failed: " +
                    "\(message)\n",
                    stderr
                )
                return
            }
        }
    }

    static func selfTest() -> Bool {
        let noCustomProfiles: NSDictionary = [:]
        let existingCustomProfiles: NSDictionary = [
            "default": NSURL(fileURLWithPath: "/tmp/monitoros-test.icc"),
        ]

        guard shouldInitialize(customProfiles: nil),
              shouldInitialize(customProfiles: noCustomProfiles),
              !shouldInitialize(customProfiles: existingCustomProfiles),
              let displayP3Name =
                kColorSyncDisplayP3Profile?.takeUnretainedValue(),
              let profile = ColorSyncProfileCreateWithName(
                displayP3Name
              )?.takeRetainedValue(),
              ColorSyncProfileGetURL(profile, nil) != nil
        else {
            return false
        }

        return true
    }

    private static func initializeOnce(
        displayID: CGDirectDisplayID
    ) -> InitializationResult {
        guard let displayUUID =
            CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue()
        else {
            return .failed("could not create display UUID")
        }

        guard let deviceClass =
                kColorSyncDisplayDeviceClass?.takeUnretainedValue(),
              let customProfilesKey =
                kColorSyncCustomProfiles?.takeUnretainedValue(),
              let defaultProfileKey =
                kColorSyncDeviceDefaultProfileID?.takeUnretainedValue(),
              let displayP3Name =
                kColorSyncDisplayP3Profile?.takeUnretainedValue()
        else {
            return .failed("required ColorSync constants are unavailable")
        }

        guard let rawDeviceInfo = ColorSyncDeviceCopyDeviceInfo(
            deviceClass,
            displayUUID
        ) else {
            return .notRegistered
        }
        let deviceInfo = rawDeviceInfo.takeRetainedValue() as NSDictionary

        let customProfiles = deviceInfo.object(
            forKey: customProfilesKey
        ) as? NSDictionary
        guard shouldInitialize(customProfiles: customProfiles) else {
            return .alreadyCustomized
        }

        guard let profile =
                ColorSyncProfileCreateWithName(
                    displayP3Name
                )?.takeRetainedValue(),
              let profileURL =
                ColorSyncProfileGetURL(
                    profile,
                    nil
                )?.takeUnretainedValue()
        else {
            return .failed("system Display P3 profile could not be resolved")
        }

        let profileInfo = [
            defaultProfileKey as String: profileURL as URL,
        ] as CFDictionary

        guard ColorSyncDeviceSetCustomProfiles(
            deviceClass,
            displayUUID,
            profileInfo
        ) else {
            return .failed("ColorSyncDeviceSetCustomProfiles returned false")
        }

        return .applied
    }

    private static func shouldInitialize(
        customProfiles: NSDictionary?
    ) -> Bool {
        customProfiles?.count ?? 0 == 0
    }
}
