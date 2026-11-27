import AppKit

// writing to an engine that has just exited raises SIGPIPE, which would end the app: the write throws instead
signal(SIGPIPE, SIG_IGN)
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
