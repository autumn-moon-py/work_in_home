import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // 关闭窗口不等于退出：应用常驻菜单栏，退出走菜单里的「退出」
    return false
  }
}
