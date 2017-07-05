import Foundation

class LinkHelper: NSObject {

  static var version: Version = {
    if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
      return Version(version)
    }
    return Version("?.?.?")
  }()

  // MARK Private Properties

  lazy var listener: NSXPCListener = {
    let listener = NSXPCListener(machServiceName:Identifiers.helper.rawValue)
    listener.delegate = self
    return listener
  }()

  var shouldQuit = false

  // MARK Instance Methods

  func listen(){
    Log.debug("Helper \(LinkHelper.version.formatted) says hello")
    listener.resume() // Tell the XPC listener to start processing requests.

    while !shouldQuit {
      RunLoop.current.run(until: Date.init(timeIntervalSinceNow: 1))
    }
    Log.debug("Helper shutting down now.")
  }

}

// MARK: - HelperProtocol
extension LinkHelper: HelperProtocol {

  func version(reply: (String) -> Void) {
    reply(LinkHelper.version.formatted)
  }

  func createConfigDirectory(reply: (Bool) -> Void) {
    let manager = FileManager.default

    let attributes = [FileAttributeKey.posixPermissions.rawValue: 0o775]
    do {
      try manager.createDirectory(atPath: Paths.configDirectory, withIntermediateDirectories: false, attributes: attributes)
      Log.debug("Created directory yo")
      reply(true)
    } catch let error as NSError {
      Log.debug("Could not create configuration directory")
      Log.debug("Unable to create directory \(error.localizedDescription)")
      reply(false)
    }
  }

  func removeConfigDirectory(reply: (Bool) -> Void) {
    let manager = FileManager.default

    do {
      try manager.removeItem(atPath: Paths.configDirectory)
      Log.debug("Deleted directory yo")
      reply(true)
    } catch let error as NSError {
      Log.debug("Could not delete configuration directory")
      Log.debug("Unable to delete directory \(error.localizedDescription)")
      reply(false)
    }
  }

  func configureDaemon(reply: (Bool) -> Void) {
    let plist : [String: Any] = [
      "Label": Identifiers.daemon.rawValue,
      "ProgramArguments": [Paths.daemonExecutable],
      "KeepAlive": true
    ]
    let plistContent = NSDictionary(dictionary: plist)
    let success:Bool = plistContent.write(toFile: Paths.daemonPlistFile, atomically: true)

    if success {
      Log.debug("file has been created!")
      reply(true)
    }else{
      Log.debug("unable to create the file")
      reply(false)
    }
  }

  func activateDaemon(reply: (Bool) -> Void) {
    launchctl(activate: false, reply: { deactivationSuccess in
      if deactivationSuccess {
        Log.debug("Deactivated daemon so I can now go ahead and activate it...")
      } else {
        Log.debug("Deactivation failed, but that's fine, let me activate it")
      }
    })
    launchctl(activate: true, reply: reply)
  }

  func deactivateDaemon(reply: (Bool) -> Void) {
    launchctl(activate: false, reply: reply)
  }

  func implode(reply: (Bool) -> Void) {
    Log.debug("Removing helper executable...")

    do {
      try FileManager.default.removeItem(atPath: Paths.helperExecutable)
    }
    catch let error as NSError {
      Log.error("Could not delete helper executable \(error)")
      reply(false)
      return
    }

    Log.debug("Removing helper daemon...")
    let task = Process()
    task.launchPath = "/usr/bin/sudo"
    task.arguments = ["/bin/launchctl", "bootout", "system", Paths.helperPlistFile]
    task.launch()
    task.waitUntilExit()

    if task.terminationStatus == 0 {
      reply(true)
    } else {
      reply(false)
    }
  }

  // MARK Private Instance Methods

  private func launchctl(activate: Bool, reply: (Bool) -> Void) {
    Log.debug("Preparing activation of daemon...")
    let task = Process()

    // Set the task parameters
    task.launchPath = "/usr/bin/sudo"
    let subcommand = activate ? "bootstrap" : "bootout"
    task.arguments = ["/bin/launchctl", subcommand, "system", Paths.daemonPlistFile]

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    task.standardOutput = outputPipe
    task.standardError = errorPipe

    // Launch the task
    Log.debug("Activating daemon now")
    task.launch()
    task.waitUntilExit()

    let status = task.terminationStatus

    if status == 0 {
      Log.debug("Task succeeded.")
      reply(true)

    } else {
      Log.debug("Task failed \(task.terminationStatus)")

      let outdata = outputPipe.fileHandleForReading.availableData
      guard let stdout = String(data: outdata, encoding: .utf8) else {
        Log.debug("Could not read stdout")
        return
      }

      let errdata = errorPipe.fileHandleForReading.availableData
      guard let stderr = String(data: errdata, encoding: .utf8) else {
        Log.debug("Could not read stderr")
        return
      }

      Log.debug("Reason: \(stdout) \(stderr)")
      
      reply(false)
    }
  }

}

// MARK: - NSXPCListenerDelegate
extension LinkHelper: NSXPCListenerDelegate {

  func listener(_ listener:NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
    newConnection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
    newConnection.exportedObject = self;
    newConnection.invalidationHandler = (() -> Void)? {
      Log.debug("Helper lost connection, queuing up for shutdown...")
      self.shouldQuit = true
    }
    newConnection.resume()
    return true
  }

}
