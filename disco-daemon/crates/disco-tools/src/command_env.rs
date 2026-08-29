//! 桌面 App 启动的外部 CLI 环境。
//!
//! LaunchServices 启动的 macOS App 不会继承用户登录 shell 配置的 PATH。
//! 这里统一 CLI 的查找路径和子进程 PATH，避免“找到启动器却找不到 node/bun”的不一致。
//! 后端适配（codex / claude / opencode）与 shell / search 执行器都使用本模块，
//! 让 GUI 启动的 daemon 能发现用户工具链。

use std::collections::HashSet;
use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};

use tokio::process::Command;

/// 在桌面应用与用户 shell 的常见路径中寻找 CLI。
pub fn find_executable(name: &str) -> Option<PathBuf> {
    let candidate = Path::new(name);
    if candidate.components().count() > 1 {
        // 带路径分隔符：按字面路径检查（CLAUDE_PATH 等覆盖入口）
        return is_executable(candidate).then(|| candidate.to_path_buf());
    }

    find_in_directories(name, &executable_search_paths())
}

/// 按顺序在目录列表中查找可执行文件，第一个可用的胜出。
fn find_in_directories(name: &str, directories: &[PathBuf]) -> Option<PathBuf> {
    directories
        .iter()
        .map(|directory| directory.join(name))
        .find(|candidate| is_executable(candidate))
}

/// 判断路径是否可作为可执行文件启动：常规文件且（unix 上）带可执行位。
///
/// 只查 `is_file()` 会被同名的非可执行文件“抢先”，因此 unix 上额外要求
/// 任一执行位（0o111）存在；非 unix 平台退回只查文件存在。
fn is_executable(path: &Path) -> bool {
    if !path.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        path.metadata()
            .map(|metadata| metadata.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
    }
    #[cfg(not(unix))]
    {
        true
    }
}

/// 创建可运行本地 CLI 的命令，并补全启动器所需的 PATH。
pub fn command(executable: impl AsRef<OsStr>) -> Command {
    let executable = executable.as_ref();
    let mut command = Command::new(executable);
    if let Some(path) = runtime_path(Path::new(executable)) {
        command.env("PATH", path);
    }
    command
}

/// 创建标准库子进程命令，并补全启动器所需的 PATH。
pub fn std_command(executable: impl AsRef<OsStr>) -> std::process::Command {
    let executable = executable.as_ref();
    let mut command = std::process::Command::new(executable);
    if let Some(path) = runtime_path(Path::new(executable)) {
        command.env("PATH", path);
    }
    command
}

fn executable_search_paths() -> Vec<PathBuf> {
    build_search_paths(
        configured_shell_path().as_deref(),
        std::env::var_os("PATH").as_deref(),
        std::env::var_os("HOME").as_deref(),
    )
}

fn runtime_path(executable: &Path) -> Option<OsString> {
    let mut directories = executable_search_paths();
    append_executable_parent(&mut directories, executable);
    deduplicate_paths(&mut directories);
    std::env::join_paths(directories).ok()
}

/// 把可执行文件自身的父目录追加到 PATH 末尾（最低优先级）。
///
/// 对 CLAUDE_PATH 这类指向自定义目录的启动器，其兄弟工具（捆绑的 node/bun 等）
/// 因此不会遮蔽系统中的同名工具；若该目录已在搜索路径中，`deduplicate_paths`
/// 保留首次出现的位置，优先级不变。裸命令名（无父目录）不追加任何内容。
fn append_executable_parent(directories: &mut Vec<PathBuf>, executable: &Path) {
    if let Some(parent) = executable
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
    {
        directories.push(parent.to_path_buf());
    }
}

fn build_search_paths(
    shell_path: Option<&OsStr>,
    inherited_path: Option<&OsStr>,
    home: Option<&OsStr>,
) -> Vec<PathBuf> {
    let mut directories = Vec::new();
    for path in [shell_path, inherited_path].into_iter().flatten() {
        directories.extend(std::env::split_paths(path));
    }
    if let Some(home) = home.map(PathBuf::from) {
        directories.extend([
            home.join(".local/bin"),
            home.join(".opencode/bin"),
            home.join(".codex/bin"),
            home.join(".bun/bin"),
            home.join(".cargo/bin"),
            home.join(".local/share/mise/shims"),
            home.join(".volta/bin"),
            home.join(".npm-global/bin"),
        ]);
    }
    directories.extend([
        PathBuf::from("/opt/homebrew/bin"),
        PathBuf::from("/usr/local/bin"),
        PathBuf::from("/usr/bin"),
        PathBuf::from("/bin"),
    ]);

    deduplicate_paths(&mut directories);
    directories
}

fn deduplicate_paths(paths: &mut Vec<PathBuf>) {
    let mut seen = HashSet::new();
    paths.retain(|path| seen.insert(path.clone()));
}

const RC_FILES: &[&str] = &[
    ".zshenv",
    ".zprofile",
    ".zshrc",
    ".bash_profile",
    ".profile",
];

/// 从常见的 shell 启动文件中提取 PATH 前缀。
///
/// 这是无副作用的回退：不执行用户 shell 配置，避免 Provider 校验被 shell 插件阻塞。
fn configured_shell_path() -> Option<OsString> {
    let home = std::env::var("HOME").ok()?;
    let mut prefixes = parse_shell_path_prefixes(Path::new(&home), RC_FILES);
    let inherited_path = std::env::var("PATH").unwrap_or_default();
    prefixes.push(inherited_path);
    std::env::join_paths(prefixes).ok()
}

/// 解析 rc 文件中 `export PATH=` / `PATH=` 的赋值行，按文件与行顺序返回前置目录段。
///
/// 解析有明确边界：前缀取到 `$PATH` / `${PATH}` 为止，支持 `$HOME` / `~` 展开；
/// `$(...)` 命令替换与 `path+=` 等写法无法无副作用求值，整行跳过
/// （继承的 PATH 仍作为基底保留，不会因此缺失系统目录）。
fn parse_shell_path_prefixes(home: &Path, rc_files: &[&str]) -> Vec<String> {
    let home_str = home.to_string_lossy();
    let mut prefixes = Vec::new();

    for rc_file in rc_files {
        let Ok(contents) = std::fs::read_to_string(home.join(rc_file)) else {
            continue;
        };
        for line in contents.lines().map(str::trim) {
            let Some(value) = line
                .strip_prefix("export PATH=")
                .or_else(|| line.strip_prefix("PATH="))
            else {
                continue;
            };
            let value = value
                .trim()
                .trim_matches(|character| character == '\'' || character == '"');
            if value.contains("$(") {
                // 命令替换的结果无法静态获知，跳过整行
                continue;
            }
            let prefix = value
                .split("$PATH")
                .next()
                .unwrap_or(value)
                .split("${PATH}")
                .next()
                .unwrap_or(value)
                .replace("${HOME}", &home_str)
                .replace("$HOME", &home_str)
                .replace('~', &home_str)
                .trim_end_matches(':')
                .to_owned();
            if !prefix.is_empty() {
                prefixes.push(prefix);
            }
        }
    }

    prefixes
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir() -> PathBuf {
        std::env::temp_dir().join(format!("disco_command_env_{}", uuid::Uuid::new_v4()))
    }

    #[cfg(unix)]
    fn make_executable(path: &Path) {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }

    #[test]
    fn search_paths_cover_gui_missing_user_directories() {
        let directories = build_search_paths(
            Some(OsStr::new("/Users/example/.nvm/bin:/usr/bin")),
            Some(OsStr::new("/usr/bin:/bin")),
            Some(OsStr::new("/Users/example")),
        );

        assert_eq!(directories[0], PathBuf::from("/Users/example/.nvm/bin"));
        assert!(directories.contains(&PathBuf::from("/Users/example/.local/bin")));
        assert!(directories.contains(&PathBuf::from("/opt/homebrew/bin")));
    }

    #[cfg(unix)]
    #[test]
    fn find_in_directories_skips_non_executable_and_prefers_first() {
        let root = temp_dir();
        let first = root.join("first");
        let second = root.join("second");
        std::fs::create_dir_all(&first).unwrap();
        std::fs::create_dir_all(&second).unwrap();

        // 第一个目录有同名文件但未设执行位 —— 应被跳过
        std::fs::write(first.join("tool"), "not executable").unwrap();
        // 第二个目录才是真正可执行的
        let second_tool = second.join("tool");
        std::fs::write(&second_tool, "#!/bin/sh\necho ok\n").unwrap();
        make_executable(&second_tool);

        assert_eq!(
            find_in_directories("tool", &[first.clone(), second.clone()]),
            Some(second_tool.clone())
        );
        // 全部不可执行时返回 None
        assert_eq!(find_in_directories("tool", &[first]), None);

        std::fs::remove_dir_all(&root).ok();
    }

    #[cfg(unix)]
    #[test]
    fn find_executable_literal_path_requires_executable_file() {
        let root = temp_dir();
        std::fs::create_dir_all(&root).unwrap();
        let tool = root.join("tool");
        std::fs::write(&tool, "bin").unwrap();

        // 未设执行位 -> None
        assert_eq!(find_executable(tool.to_str().unwrap()), None);

        make_executable(&tool);
        assert_eq!(find_executable(tool.to_str().unwrap()), Some(tool.clone()));

        // 不存在的路径 -> None
        assert_eq!(
            find_executable(root.join("missing").to_str().unwrap()),
            None
        );

        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn append_executable_parent_semantics() {
        // 裸命令名（parent 为空路径）不追加
        let mut dirs = vec![PathBuf::from("/usr/bin")];
        append_executable_parent(&mut dirs, Path::new("tool"));
        assert_eq!(dirs, vec![PathBuf::from("/usr/bin")]);

        // 带父目录：追加到末尾（最低优先级）
        let mut dirs = vec![PathBuf::from("/usr/bin")];
        append_executable_parent(&mut dirs, Path::new("/custom/bin/tool"));
        assert_eq!(
            dirs,
            vec![PathBuf::from("/usr/bin"), PathBuf::from("/custom/bin")]
        );

        // 已在搜索路径中的目录：dedup 保留首次出现的位置
        let mut dirs = vec![PathBuf::from("/custom/bin"), PathBuf::from("/usr/bin")];
        append_executable_parent(&mut dirs, Path::new("/custom/bin/tool"));
        deduplicate_paths(&mut dirs);
        assert_eq!(
            dirs,
            vec![PathBuf::from("/custom/bin"), PathBuf::from("/usr/bin")]
        );
    }

    #[test]
    fn parse_shell_path_prefixes_respects_order_and_expansions() {
        let root = temp_dir();
        let home = root.join("home");
        std::fs::create_dir_all(&home).unwrap();

        std::fs::write(
            home.join(".zshenv"),
            "export PATH=\"$HOME/.local/bin:$PATH\"\n",
        )
        .unwrap();
        std::fs::write(
            home.join(".zshrc"),
            "export PATH='$HOME/.npm-global/bin:$PATH'\n             export NVM_DIR=\"$HOME/.nvm\"\n             export PATH=$(echo /derived/dir):$PATH\n             PATH=/plain/dir:$PATH\n",
        )
        .unwrap();
        std::fs::write(home.join(".profile"), "export PATH=~/bin:$PATH\n").unwrap();

        let prefixes = parse_shell_path_prefixes(&home, RC_FILES);

        assert_eq!(
            prefixes,
            vec![
                format!("{}/.local/bin", home.display()),
                format!("{}/.npm-global/bin", home.display()),
                "/plain/dir".to_string(),
                format!("{}/bin", home.display()),
            ]
        );
        // `$(...)` 命令行无法静态求值，整行被跳过
        assert!(!prefixes.iter().any(|p| p.contains("/derived/dir")));

        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn parse_shell_path_prefixes_handles_missing_rc_files() {
        let root = temp_dir();
        let home = root.join("empty_home");
        std::fs::create_dir_all(&home).unwrap();

        // 没有任何 rc 文件 -> 空前缀（configured_shell_path 仍会补继承的 PATH）
        assert!(parse_shell_path_prefixes(&home, RC_FILES).is_empty());

        std::fs::remove_dir_all(&root).ok();
    }
}
