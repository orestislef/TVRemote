import Foundation

enum RemoteCommand: String, Codable, Sendable {
    case up, down, left, right
    case ok, back, home
    case power
    case volumeUp, volumeDown, mute
    case channelUp, channelDown

    var keyCode: Int32 {
        switch self {
        case .up:          return 19   // KEYCODE_DPAD_UP
        case .down:        return 20   // KEYCODE_DPAD_DOWN
        case .left:        return 21   // KEYCODE_DPAD_LEFT
        case .right:       return 22   // KEYCODE_DPAD_RIGHT
        case .ok:          return 23   // KEYCODE_DPAD_CENTER
        case .back:        return 4    // KEYCODE_BACK
        case .home:        return 3    // KEYCODE_HOME
        case .power:       return 26   // KEYCODE_POWER
        case .volumeUp:    return 24   // KEYCODE_VOLUME_UP
        case .volumeDown:  return 25   // KEYCODE_VOLUME_DOWN
        case .mute:        return 164  // KEYCODE_VOLUME_MUTE
        case .channelUp:   return 166  // KEYCODE_CHANNEL_UP
        case .channelDown: return 167  // KEYCODE_CHANNEL_DOWN
        }
    }
}
