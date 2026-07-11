//
//  CodesignCheck.swift
//
//  Created by Erik Berglund on 2018-10-01.
//  Copyright © 2018 Erik Berglund. All rights reserved.
//

import Foundation
import Security

enum CodesignCheckError: Error {
    case message(String)
}

struct CodesignCheck {

    /// The privileged service must only accept this exact application identity.
    /// Matching a certificate alone would also admit unrelated apps signed by
    /// the same developer certificate.
    static let clientRequirement = #"identifier "com.lukerow.Pearcleaner" and anchor apple generic and certificate leaf[subject.OU] = "68583N3MNF""#

    static func clientIsPearcleaner(pid: pid_t) throws -> Bool {
        var guestCode: SecCode?
        try executeSecFunction {
            SecCodeCopyGuestWithAttributes(
                nil,
                [kSecGuestAttributePid: pid] as CFDictionary,
                [],
                &guestCode
            )
        }

        guard let guestCode else {
            throw CodesignCheckError.message("SecCodeCopyGuestWithAttributes returned no code")
        }

        var requirement: SecRequirement?
        try executeSecFunction {
            SecRequirementCreateWithString(clientRequirement as CFString, [], &requirement)
        }

        guard let requirement else {
            throw CodesignCheckError.message("SecRequirementCreateWithString returned no requirement")
        }

        return SecCodeCheckValidity(guestCode, [], requirement) == errSecSuccess
    }

    private static func executeSecFunction(_ secFunction: () -> (OSStatus) ) throws {
        let osStatus = secFunction()
        guard osStatus == errSecSuccess else {
            throw CodesignCheckError.message(String(describing: SecCopyErrorMessageString(osStatus, nil)))
        }
    }

}
