import Cocoa
import FlutterMacOS
import ServiceManagement

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    setupLoginItemChannel(flutterViewController)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  /// 开机自启动通道。用 SMAppService 注册应用自身，不需要额外的 helper bundle；
  /// 这套 API 从 macOS 13 起才有，更早的系统一律回 "unsupported"。
  private func setupLoginItemChannel(_ controller: FlutterViewController) {
    FlutterMethodChannel(
      name: "win_share/login_item",
      binaryMessenger: controller.engine.binaryMessenger
    ).setMethodCallHandler { call, result in
      switch call.method {
      case "status":
        result(Self.loginItemStatusName)
      case "setEnabled":
        let value = (call.arguments as? [String: Any])?["value"] as? Bool ?? false
        result(Self.setLoginItemEnabled(value))
      case "openSystemSettings":
        if #available(macOS 13.0, *) {
          SMAppService.openSystemSettingsLoginItems()
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static var loginItemStatusName: String {
    guard #available(macOS 13.0, *) else { return "unsupported" }
    switch SMAppService.mainApp.status {
    case .enabled: return "enabled"
    case .requiresApproval: return "requiresApproval"
    case .notFound: return "notFound"
    default: return "notRegistered"
    }
  }

  /// 返回注册后的状态名；失败时把 NSError 原文交给 Dart，避免只看到一句"失败"
  private static func setLoginItemEnabled(_ value: Bool) -> Any? {
    guard #available(macOS 13.0, *) else {
      return FlutterError(
        code: "unsupported",
        message: "开机自启动需要 macOS 13 及以上",
        details: nil
      )
    }
    let service = SMAppService.mainApp
    do {
      if value {
        try service.register()
      } else {
        try service.unregister()
      }
    } catch {
      let nsError = error as NSError
      return FlutterError(
        code: "\(nsError.domain) \(nsError.code)",
        message: nsError.localizedDescription,
        details: nsError.localizedFailureReason
      )
    }
    return loginItemStatusName
  }

  /// 关闭按钮（以及 ⌘W）只隐藏窗口，不真正关闭，进程继续常驻菜单栏。
  /// 放在原生层是因为 window_manager 的 preventClose 实测没有拦住关闭。
  override func performClose(_ sender: Any?) {
    self.orderOut(nil)
  }
}
