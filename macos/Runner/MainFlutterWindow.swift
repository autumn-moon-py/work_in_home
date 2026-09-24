import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  /// 关闭按钮（以及 ⌘W）只隐藏窗口，不真正关闭，进程继续常驻菜单栏。
  /// 放在原生层是因为 window_manager 的 preventClose 实测没有拦住关闭。
  override func performClose(_ sender: Any?) {
    self.orderOut(nil)
  }
}
