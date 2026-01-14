# macOS 窗口监控技术调研

本文档记录 macOS 平台上窗口监控和截图的技术能力，为 Agent Monitor 的功能扩展提供参考。

## 概述

macOS 提供了多种 API 来获取窗口信息和截图，但需要相应的系统权限。

| 能力 | 支持情况 | 所需权限 |
|------|----------|----------|
| 获取窗口列表 | ✅ | 屏幕录制权限 |
| 获取窗口 ID/标题 | ✅ | 屏幕录制权限 |
| 截取指定窗口 | ✅ | 屏幕录制权限 |
| 获取 Tab 信息 | 部分支持 | 辅助功能权限 + AppleScript |

## 系统 API

### 1. CGWindowListCopyWindowInfo

Core Graphics 框架提供的底层 API，可获取所有窗口信息。

**返回的窗口属性：**
- `kCGWindowNumber` - 窗口 ID
- `kCGWindowOwnerName` - 所属应用名
- `kCGWindowName` - 窗口标题
- `kCGWindowLayer` - 窗口层级（0 为普通窗口）
- `kCGWindowBounds` - 窗口位置和大小

**Objective-C 示例：**

```objc
#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>

int main() {
    CFArrayRef windowList = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID
    );

    for (NSDictionary *window in (__bridge NSArray *)windowList) {
        NSNumber *layer = window[(id)kCGWindowLayer];
        if ([layer intValue] != 0) continue;  // 只要普通窗口

        NSString *owner = window[(id)kCGWindowOwnerName];
        NSString *name = window[(id)kCGWindowName];
        NSNumber *wid = window[(id)kCGWindowNumber];

        if (!name || name.length == 0) continue;

        printf("ID:%d | %s | %s\n",
               [wid intValue],
               [owner UTF8String],
               [name UTF8String]);
    }

    CFRelease(windowList);
    return 0;
}
```

**编译命令：**
```bash
clang -framework Foundation -framework ApplicationServices window_list.m -o window_list
```

### 2. screencapture 命令行工具

macOS 自带的截图工具，支持多种模式。

```bash
# 全屏截图
screencapture screen.png

# 指定窗口截图（通过窗口 ID）
screencapture -l<windowID> window.png

# 示例：截取 ID 为 54202 的窗口
screencapture -l54202 /tmp/window.png

# 静默模式（不播放声音）
screencapture -x output.png

# 截图到剪贴板
screencapture -c

# 交互式选择窗口
screencapture -w output.png
```

### 3. CGWindowListCreateImage

编程方式截取窗口图像。

**Swift 示例：**
```swift
import Cocoa

func captureWindow(windowID: CGWindowID) -> NSImage? {
    guard let cgImage = CGWindowListCreateImage(
        .null,
        .optionIncludingWindow,
        windowID,
        [.boundsIgnoreFraming]
    ) else { return nil }

    return NSImage(cgImage: cgImage, size: NSSize(
        width: cgImage.width,
        height: cgImage.height
    ))
}
```

### 4. Accessibility API

通过 AXUIElement 可以获取更详细的 UI 元素信息。

```swift
import Cocoa

// 需要辅助功能权限
let app = AXUIElementCreateApplication(pid)
var windows: CFTypeRef?
AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
```

## 各应用支持情况

### AppleScript 支持

| 应用 | Tab 信息 | 窗口控制 | 内容获取 |
|------|----------|----------|----------|
| iTerm2 | ✅ 完整支持 | ✅ | ✅ 可获取终端输出 |
| Chrome | ✅ URL + 标题 | ✅ | ❌ 无法获取页面内容 |
| Safari | ✅ URL + 标题 | ✅ | 部分支持 |
| Claude Desktop | ❌ Electron 应用 | ❌ | ❌ |
| Cursor | ❌ Electron 应用 | ❌ | ❌ |
| VS Code | ❌ Electron 应用 | ❌ | ❌ |

### iTerm2 AppleScript 示例

```bash
# 获取所有 tab 名称
osascript -e 'tell application "iTerm2" to get name of every tab of every window'

# 获取当前 session 的内容
osascript -e 'tell application "iTerm2"
    tell current session of current window
        get contents
    end tell
end tell'

# 获取当前运行的命令
osascript -e 'tell application "iTerm2"
    tell current session of current window
        get name
    end tell
end tell'
```

### Chrome AppleScript 示例

```bash
# 获取所有窗口的活动 tab URL
osascript -e 'tell application "Google Chrome" to get URL of active tab of every window'

# 获取所有 tab 的标题
osascript -e 'tell application "Google Chrome"
    set tabList to {}
    repeat with w in windows
        repeat with t in tabs of w
            set end of tabList to title of t
        end repeat
    end repeat
    return tabList
end tell'
```

## 权限要求

### 屏幕录制权限

**检查方式：**
- 系统偏好设置 → 安全性与隐私 → 隐私 → 屏幕录制
- 或通过代码尝试截图，失败则表示无权限

**获取方式：**
- 用户手动在系统设置中授权
- 应用首次调用相关 API 时会弹出授权请求

### 辅助功能权限

**检查方式：**
```swift
AXIsProcessTrusted()  // 返回 Bool
```

**请求方式：**
```swift
let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
AXIsProcessTrustedWithOptions(options)
```

## 实际测试结果

在当前环境测试，成功获取的窗口示例：

```
ID:27166 | iTerm | ⠐ 窗口截图功能
ID:40260 | 飞书 | 飞书
ID:52476 | Google Chrome | vaxin/agent-monitor
ID:54202 | Claude | Claude
ID:82 | ChatGPT | ChatGPT
ID:45201 | OrbStack | daniel — Project Logs
```

**截图测试：**
- Claude Desktop 窗口：✅ 成功
- Chrome 窗口：✅ 成功
- iTerm2 窗口：✅ 成功

## Agent Monitor 集成方案

### 方案一：窗口发现

自动识别 Agent 相关窗口：

```swift
let agentApps = ["Claude", "Cursor", "ChatGPT", "iTerm2", "Terminal"]

func findAgentWindows() -> [WindowInfo] {
    // 扫描窗口列表
    // 匹配应用名或窗口标题关键词
    // 返回可能是 Agent 的窗口
}
```

### 方案二：截图预览

点击 session 时显示对应窗口截图：

```swift
func captureAgentWindow(sessionId: String) -> NSImage? {
    // 根据 session 信息找到对应窗口
    // 截取窗口图像
    // 返回用于预览
}
```

### 方案三：状态分析

将截图发送给 LLM 分析：

```swift
func analyzeAgentStatus(windowImage: NSImage) async -> String {
    // 将图像编码为 base64
    // 发送给多模态 LLM
    // 返回分析结果（如：正在等待输入、正在执行代码等）
}
```

## 限制与注意事项

1. **Electron 应用**：Claude Desktop、Cursor 等 Electron 应用不支持 AppleScript，只能通过窗口截图获取信息

2. **DRM 保护**：某些受保护的内容（如 Netflix）可能无法截图

3. **隐私窗口**：Chrome 隐身模式等可能有额外限制

4. **性能影响**：频繁截图可能影响系统性能，建议按需截取

5. **窗口 ID 变化**：窗口关闭重开后 ID 会变化，不能持久化存储

## 参考资料

- [Apple CGWindow Reference](https://developer.apple.com/documentation/coregraphics/quartz_window_services)
- [screencapture man page](https://ss64.com/osx/screencapture.html)
- [Accessibility API Guide](https://developer.apple.com/documentation/accessibility)
- [iTerm2 AppleScript](https://iterm2.com/documentation-scripting.html)
