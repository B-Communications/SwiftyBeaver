//
//  FileDestination.swift
//  SwiftyBeaver
//
//  Created by Sebastian Kreutzberger on 05.12.15.
//  Copyright © 2015 Sebastian Kreutzberger
//  Some rights reserved: http://opensource.org/licenses/MIT
//

import Foundation
import Gzip

open class FileDestination: BaseDestination {

    public var logFileURL: URL?
    public var syncAfterEachWrite: Bool = false
    public var colored: Bool = false {
        didSet {
            if colored {
                // bash font color, first value is intensity, second is color
                // see http://bit.ly/1Otu3Zr & for syntax http://bit.ly/1Tp6Fw9
                // uses the 256-color table from http://bit.ly/1W1qJuH
                reset = "\u{001b}[0m"
                escape = "\u{001b}[38;5;"
                levelColor.verbose = "251m"     // silver
                levelColor.debug = "35m"        // green
                levelColor.info = "38m"         // blue
                levelColor.warning = "178m"     // yellow
                levelColor.error = "197m"       // red
            } else {
                reset = ""
                escape = ""
                levelColor.verbose = ""
                levelColor.debug = ""
                levelColor.info = ""
                levelColor.warning = ""
                levelColor.error = ""
            }
        }
    }
    
    // LOGFILE ROTATION
    // ho many bytes should a logfile have until it is rotated?
    // default is 5 MB. Just is used if logFileAmount > 1
    public var logFileMaxSize = (5 * 1024 * 1024)
    // Number of log files used in rotation, default is 1 which deactivates file rotation
    public var logFileAmount = 1
    public static var defualtRollover = false
    public static var noOfLogFiles = 100 // Number of log files used in rotation
    public static var maxInterval = 60 * 60 //1h
    public static var maxLogFilesize = (10 * 1024 * 1024) // 10MB
        
    public static let dateFormatter = DateFormatter()

    override public var defaultHashValue: Int {return 2}
    let fileManager = FileManager.default


    public init(logFileURL: URL? = nil) {
        FileDestination.dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let logFileURL = logFileURL {
            self.logFileURL = logFileURL
            super.init()
            return
        }

        // platform-dependent logfile directory default
        var baseURL: URL?
        #if os(OSX)
            if let url = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
                baseURL = url
                // try to use ~/Library/Caches/APP NAME instead of ~/Library/Caches
                if let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String {
                    do {
                        if let appURL = baseURL?.appendingPathComponent(appName, isDirectory: true) {
                            try fileManager.createDirectory(at: appURL,
                                                            withIntermediateDirectories: true, attributes: nil)
                            baseURL = appURL
                        }
                    } catch {
                        print("Warning! Could not create folder /Library/Caches/\(appName)")
                    }
                }
            }
        #else
            #if os(Linux)
                baseURL = URL(fileURLWithPath: "/var/cache")
            #else
                // iOS, watchOS, etc. are using the caches directory
                if let url = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
                    baseURL = url
                }
            #endif
        #endif

        if let baseURL = baseURL {
            self.logFileURL = baseURL.appendingPathComponent("swiftybeaver.log", isDirectory: false)
        }
        super.init()
    }

    // append to file. uses full base class functionality
    override public func send(_ level: SwiftyBeaver.Level, msg: String, thread: String,
        file: String, function: String, line: Int, context: Any? = nil) -> String? {
        let formattedString = super.send(level, msg: msg, thread: thread, file: file, function: function, line: line, context: context)

        if let str = formattedString {
            _ = validateSaveFile(str: str)
        }
        return formattedString
    }
    
    // check if filesize is bigger than wanted and if yes then rotate them
    func validateSaveFile(str: String) -> Bool {
        if self.logFileAmount > 1 {
            guard let url = logFileURL else { return false }
            let filePath = url.path
            if FileManager.default.fileExists(atPath: filePath) == true {
                do {
                    // Get file size
                    let attr = try FileManager.default.attributesOfItem(atPath: filePath)
                    let fileSize = attr[FileAttributeKey.size] as! UInt64
                    // Do file rotation
                    if fileSize > logFileMaxSize {
                        rotateCompressFile(filePath)
                    }
                } catch {
                    print("validateSaveFile error: \(error)")
                }
            }
        }
        return saveToFile(str: str)
    }

    private func rotateCompressFile(_ filePath: String) {
        let firstIndex = 1
        let pathname = (filePath as NSString).deletingLastPathComponent
        let filename = (filePath as NSString).lastPathComponent
        let foldername = (filename as NSString).deletingPathExtension
        let compressedPath = String.init(format: "%@/%@", pathname, foldername)
        
        do {
            // rotate files
            if var content = try? FileManager.default.contentsOfDirectory(atPath: compressedPath) {
                if FileDestination.defualtRollover {
                    if content.count == FileDestination.noOfLogFiles {
                        // Delete the last file
                        let suffix = String.init(format: "%d.gz", FileDestination.noOfLogFiles)
                        for (index, file) in content.enumerated() {
                            if file.hasSuffix(suffix) {
                                let lastFile = String.init(format: "%@/%@", compressedPath, file)
                                try FileManager.default.removeItem(atPath: lastFile)
                                content.remove(at: index)
                            }
                        }
                    }
                    } else {
                    for (index, file) in content.enumerated() {
                        let start = file.firstIndex(of: "-")!
                        let end = file.lastIndex(of: "-")!
                        var strDate = String(file[start..<end])
                        strDate.removeFirst()
                        let creationDate = FileDestination.dateFormatter.date(from: strDate)
                        let interval = Int(ceil(abs(creationDate!.timeIntervalSinceNow)))
                                                
                        if interval > FileDestination.maxInterval {
                            let path = String.init(format: "%@/%@", compressedPath, file)
                            try FileManager.default.removeItem(atPath: path)
                            content.remove(at: index)
                        }
                    }
                }
                
                // Move the current file to next index
                for file in content {
                    let start = file.lastIndex(of: "-")!
                    let end = file.lastIndex(of: ".")!
                    var strIndex = String(file[start..<end])
                    strIndex.removeFirst()
                    let index = (strIndex as NSString).intValue
                    let oldFile = String.init(format: "%@/%@", compressedPath, file)
                    let newFile = String.init(format: "%@/%@-%d.gz", compressedPath, String(file[..<start]), index + 1)
                    try FileManager.default.moveItem(atPath: oldFile, toPath: newFile)
                }
            }

            // Finally, compress the current file
            let attributes = try FileManager.default.attributesOfItem(atPath: filePath)
            let date = FileDestination.dateFormatter.string(from: (attributes[FileAttributeKey.creationDate] as! Date))

            // raw data
            let data = try Data(contentsOf: URL(fileURLWithPath: filePath))

            if FileManager.default.fileExists(atPath: compressedPath) == false {
                try FileManager.default.createDirectory(atPath: compressedPath, withIntermediateDirectories: false, attributes: nil)
            }

            let compressedFile = String.init(format: "%@/%@-%@-%d.gz", compressedPath, foldername, date, firstIndex)
            let compressedData = try data.gzipped()
            try compressedData.write(to: URL(fileURLWithPath: compressedFile))

            // Delete the raw data file
            try FileManager.default.removeItem(atPath: filePath)
        } catch {
            print("rotateCompressFile error: \(error)")
        }
    }
        
    /// appends a string as line to a file.
    /// returns boolean about success
    func saveToFile(str: String) -> Bool {
        guard let url = logFileURL else { return false }

        let line = str + "\n"
        guard let data = line.data(using: String.Encoding.utf8) else { return false }

        return write(data: data, to: url)
    }

    private func write(data: Data, to url: URL) -> Bool {
        
        #if os(Linux)
            return true
        #else
        var success = false
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var error: NSError?
        coordinator.coordinate(writingItemAt: url, error: &error) { url in
            do {
                if fileManager.fileExists(atPath: url.path) == false {

                    let directoryURL = url.deletingLastPathComponent()
                    if fileManager.fileExists(atPath: directoryURL.path) == false {
                        try fileManager.createDirectory(
                            at: directoryURL,
                            withIntermediateDirectories: true
                        )
                    }
                    fileManager.createFile(atPath: url.path, contents: nil)

                    #if os(iOS) || os(watchOS)
                    if #available(iOS 10.0, watchOS 3.0, *) {
                        var attributes = try fileManager.attributesOfItem(atPath: url.path)
                        attributes[FileAttributeKey.protectionKey] = FileProtectionType.none
                        try fileManager.setAttributes(attributes, ofItemAtPath: url.path)
                    }
                    #endif
                }

                let fileHandle = try FileHandle(forWritingTo: url)
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                if syncAfterEachWrite {
                    fileHandle.synchronizeFile()
                }
                fileHandle.closeFile()
                success = true
            } catch {
                print("SwiftyBeaver File Destination could not write to file \(url).")
            }
        }

        if let error = error {
            print("Failed writing file with error: \(String(describing: error))")
            return false
        }

        return success
        #endif
    }

    /// deletes log file.
    /// returns true if file was removed or does not exist, false otherwise
    public func deleteLogFile() -> Bool {
        guard let url = logFileURL, fileManager.fileExists(atPath: url.path) == true else { return true }
        do {
            try fileManager.removeItem(at: url)
            return true
        } catch {
            print("SwiftyBeaver File Destination could not remove file \(url).")
            return false
        }
    }
}
