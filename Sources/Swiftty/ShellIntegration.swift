import Foundation
import RexKit

/// Builds the options Swiftty passes to Rex when it creates a shell.
///
/// The shell may run on another machine, so instead of pointing at files on
/// this Mac, the shell starts through a small `sh` launcher that writes the
/// integration scripts on whichever machine it runs on, then starts the
/// user's own shell (zsh or bash) with them loaded.
enum ShellIntegration {
    private static func resource(_ path: String) -> String {
        guard let base = Bundle.module.url(forResource: "ShellIntegration", withExtension: nil),
              let data = FileManager.default.contents(atPath: base.appendingPathComponent(path).path)
        else {
            NSLog("Swiftty: shell integration resource missing: \(path)")
            return ""
        }
        return data.base64EncodedString()
    }

    /// The launcher script, with the integration files embedded.
    static let launcher: String = {
        let zsh = resource("swiftty.zsh")
        let zshenv = resource("zsh/.zshenv")
        let bash = resource("bash/swiftty.bash")
        return """
        d="${XDG_CACHE_HOME:-$HOME/.cache}/swiftty/shell"
        mkdir -p "$d/zsh" "$d/bash" 2>/dev/null
        dec() { base64 -d 2>/dev/null || base64 -D; }
        printf %s '\(zsh)' | dec > "$d/swiftty.zsh"
        printf %s '\(zshenv)' | dec > "$d/zsh/.zshenv"
        printf %s '\(bash)' | dec > "$d/bash/swiftty.bash"
        s="$SHELL"
        if [ -z "$s" ]; then
          s=$(dscl . -read "/Users/$(id -un)" UserShell 2>/dev/null | awk '{print $2}')
          [ -z "$s" ] && s=$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7)
          [ -z "$s" ] && s=/bin/sh
        fi
        case "$s" in
          */zsh)
            if [ -n "${ZDOTDIR+x}" ]; then export SWIFTTY_ORIG_ZDOTDIR="$ZDOTDIR"; fi
            export ZDOTDIR="$d/zsh" SWIFTTY_INTEGRATION_DIR="$d"
            exec "$s" -l ;;
          */bash)
            exec "$s" --rcfile "$d/bash/swiftty.bash" -i ;;
          *)
            exec "$s" -l ;;
        esac
        """
    }()

    /// Options for `com.superlogical.terminal.shell`.
    static func shellOptions(cwd: String?) -> JSONValue {
        var options: [String: JSONValue] = [
            "shell": "none",
            "command": ["/bin/sh", "-c", .string(launcher)],
        ]
        if let cwd, !cwd.isEmpty { options["cwd"] = .string(cwd) }
        return .object(options)
    }

    /// The user's login shell on this Mac.
    static var userShell: String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell { return String(cString: shell) }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }
}
