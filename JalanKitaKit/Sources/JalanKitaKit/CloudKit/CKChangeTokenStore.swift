//
//  CKChangeTokenStore.swift
//  JalanKitaKit
//
//  Disk persistence for a CKServerChangeToken, shared by both platforms'
//  sync engines — CKServerChangeToken isn't Codable, so this uses
//  NSKeyedArchiver/NSKeyedUnarchiver with requiringSecureCoding: true, same
//  as both engines independently did before this was extracted.
//

import CloudKit
import Foundation

public enum CKChangeTokenStore {
    public static func load(from url: URL) -> CKServerChangeToken? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    public static func save(_ token: CKServerChangeToken?, to url: URL) {
        guard let token,
              let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        else { return }
        try? data.write(to: url, options: .atomic)
    }
}
