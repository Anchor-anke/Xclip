#!/usr/bin/env python3
"""Install Xclip at one stable path; clean known builds and verified fixed-location copies."""

import argparse
import ctypes
import fcntl
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile


PRODUCTION_ID = "local.cclip.app"
COPY_IDS = {PRODUCTION_ID, "local.cclip.capture-preview", "local.cclip.qa"}
DATA_NAMES = {"data", "history", "attachments", "preview-data", "qa-data"}
GENERATED_DIRS = {"capture-upgrade", "screenshot-direct", "qa", "tests"}
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


class InstallError(RuntimeError):
    pass


def checked_path(value):
    path = Path(value).expanduser()
    if ".." in path.parts:
        raise InstallError(f"拒绝包含 .. 的路径：{path}")
    path = Path(os.path.abspath(path))
    for part in (path, *path.parents):
        if part.is_symlink():
            raise InstallError(f"拒绝符号链接路径：{part}")
    return path


def inside(path, parent):
    return path == parent or parent in path.parents


def bundle_id(path):
    checked_path(path)
    if not path.is_dir() or path.suffix != ".app":
        raise InstallError(f"不是应用目录：{path}")
    for root, dirs, files in os.walk(path, followlinks=False):
        for name in dirs + files:
            if (Path(root) / name).is_symlink():
                raise InstallError(f"应用中包含符号链接，保留原文件：{Path(root) / name}")
    try:
        with (path / "Contents/Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        raise InstallError(f"无法读取应用信息：{path}") from error
    if info.get("CFBundleExecutable") != "Xclip":
        raise InstallError(f"应用执行文件不是 Xclip：{path}")
    executable = path / "Contents/MacOS/Xclip"
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise InstallError(f"缺少可执行的 Xclip：{path}")
    return info.get("CFBundleIdentifier")


def verify_signature(path):
    result = subprocess.run(
        ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(path)],
        capture_output=True, text=True,
    )
    if result.returncode:
        raise InstallError(f"签名校验失败：{path}\n{result.stderr.strip()}")


def external_copy_paths():
    """Fixed installation locations only; never search a user's Desktop or home recursively."""
    user = Path.home()
    return (user / "Desktop/Xclip.app", user / "Applications/Xclip.app", Path("/Applications/Xclip.app"))


def version_key(path):
    with (path / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    values = []
    for name in ("CFBundleShortVersionString", "CFBundleVersion"):
        value = info.get(name)
        if not isinstance(value, str) or not re.fullmatch(r"[0-9]{1,9}(?:\.[0-9]{1,9}){0,3}", value):
            raise InstallError(f"无法确定版本先后，保留应用：{path}")
        parts = tuple(int(item) for item in value.split("."))
        values.append(parts + (0,) * (4 - len(parts)))
    return tuple(values)


def signing_certificate(path):
    """Read the actual signing leaf, never the non-unique certificate display name."""
    with tempfile.TemporaryDirectory(prefix="xclip-signature-") as directory:
        prefix = Path(directory) / "certificate-"
        result = subprocess.run(
            ["/usr/bin/codesign", "--display", "--extract-certificates=" + str(prefix), str(path)],
            capture_output=True, text=True,
        )
        certificate = Path(str(prefix) + "0")
        if result.returncode or not certificate.is_file():
            raise InstallError(f"无法确认签名证书，保留外部副本：{path}")
        return hashlib.sha1(certificate.read_bytes()).hexdigest()


def verify_project_signature(path, certificate):
    verify_signature(path)
    # Check the signed executable identity, not only the editable Info.plist display metadata.
    requirement = f'=identifier "{PRODUCTION_ID}" and certificate leaf = H"{certificate}"'
    result = subprocess.run(
        ["/usr/bin/codesign", "--verify", "--strict", "--all-architectures", "-R", requirement, str(path)],
        capture_output=True, text=True,
    )
    if result.returncode:
        raise InstallError(f"签名来源与当前项目不一致，保留外部副本：{path}")


def verify_sealed_contents(path):
    """Only remove signed bundle payload; omitted or unexpected user files make it ineligible."""
    try:
        info = plistlib.loads((path / "Contents/Info.plist").read_bytes())
        if info.get("CClipTestDataDirectory"):
            raise InstallError(f"应用声明了测试数据目录，保留外部副本：{path}")
        seal = plistlib.loads((path / "Contents/_CodeSignature/CodeResources").read_bytes())
        entries = seal.get("files2")
        if not isinstance(entries, dict):
            raise InstallError(f"无法核对封存资源，保留外部副本：{path}")
        allowed = {
            "Contents/Info.plist", "Contents/MacOS/Xclip", "Contents/PkgInfo",
            "Contents/_CodeSignature/CodeResources",
        }
        for name in entries:
            if not isinstance(name, str) or name.startswith("/") or ".." in Path(name).parts:
                raise InstallError(f"封存资源路径无效，保留外部副本：{path}")
            allowed.add("Contents/" + name)
        for child in path.rglob("*"):
            relative = child.relative_to(path).as_posix()
            if any(part.lower() in DATA_NAMES or part.lower().endswith("-data") for part in child.relative_to(path).parts):
                raise InstallError(f"应用内含数据目录，保留外部副本：{child}")
            if child.is_symlink() or (child.is_file() and relative not in allowed) or (
                child.is_dir() and not any(name.startswith(relative + "/") for name in allowed)
            ) or not (child.is_file() or child.is_dir()):
                raise InstallError(f"应用内含未确认文件，保留外部副本：{child}")
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        raise InstallError(f"无法核对应用资源，保留外部副本：{path}") from error


def running_executables():
    result = subprocess.run(
        ["/bin/ps", "-ww", "-axo", "pid=,comm="], capture_output=True, text=True,
    )
    if result.returncode:
        raise InstallError("无法核对运行中的应用；未替换或清理任何应用。")
    processes = []
    for line in result.stdout.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and fields[0].isdigit() and fields[1].startswith("/"):
            processes.append((int(fields[0]), Path(fields[1])))
    return processes


def tracked_files(repo):
    result = subprocess.run(
        ["git", "-C", str(repo), "ls-files", "-z"], capture_output=True,
    )
    if result.returncode:
        raise InstallError("无法核对 Git 跟踪文件；停止安装以保护源码。")
    return [repo / os.fsdecode(name) for name in result.stdout.split(b"\0") if name]


def atomic_move(source, target, exchange=False):
    """macOS renamex_np: an atomic exchange, or a rename that cannot overwrite."""
    if sys.platform != "darwin":
        raise InstallError("本地安装仅支持 macOS。")
    rename = ctypes.CDLL(None, use_errno=True).renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    # SDK sys/stdio.h: RENAME_SWAP = 2; RENAME_EXCL = 4.
    if rename(os.fsencode(source), os.fsencode(target), 2 if exchange else 4):
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(target))


def copy_bundle(source, target):
    subprocess.run(["/usr/bin/ditto", str(source), str(target)], check=True)


def registered_bundle_paths(identifier):
    """Read the public LaunchServices URL lookup; errors never mean an empty registry."""
    cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    ls = ctypes.CDLL("/System/Library/Frameworks/CoreServices.framework/CoreServices")
    pointer = ctypes.c_void_p

    def function(library, name, arguments, result):
        value = getattr(library, name)
        value.argtypes, value.restype = arguments, result
        return value

    string = function(cf, "CFStringCreateWithCString", [pointer, ctypes.c_char_p, ctypes.c_uint32], pointer)
    release = function(cf, "CFRelease", [pointer], None)
    lookup = function(ls, "LSCopyApplicationURLsForBundleIdentifier", [pointer, ctypes.POINTER(pointer)], pointer)
    count = function(cf, "CFArrayGetCount", [pointer], ctypes.c_long)
    item = function(cf, "CFArrayGetValueAtIndex", [pointer, ctypes.c_long], pointer)
    filesystem = function(cf, "CFURLGetFileSystemRepresentation", [pointer, ctypes.c_bool, pointer, ctypes.c_long], ctypes.c_bool)
    error_code = function(cf, "CFErrorGetCode", [pointer], ctypes.c_long)
    error_domain = function(cf, "CFErrorGetDomain", [pointer], pointer)
    equal = function(cf, "CFEqual", [pointer, pointer], ctypes.c_bool)
    osstatus_domain = pointer.in_dll(cf, "kCFErrorDomainOSStatus")
    bundle = string(None, identifier.encode("utf-8"), 0x08000100)  # kCFStringEncodingUTF8
    if not bundle:
        raise InstallError("无法创建应用登记查询，保留旧副本。")
    error = pointer()
    urls = None
    try:
        urls = lookup(bundle, ctypes.byref(error))
        if error.value:
            # LSInfo.h documents this specific error when no app has the bundle identifier.
            if not urls and error_code(error) == -10814 and equal(error_domain(error), osstatus_domain):
                return set()
            raise InstallError("系统应用登记查询失败，保留旧副本。")
        if not urls:
            raise InstallError("系统应用登记查询没有返回确定结果，保留旧副本。")
        paths = set()
        for index in range(count(urls)):
            buffer = ctypes.create_string_buffer(65536)
            if not filesystem(item(urls, index), True, buffer, len(buffer)):
                raise InstallError("无法读取已登记应用路径，保留旧副本。")
            paths.add(Path(os.fsdecode(buffer.value)).resolve())
        return paths
    finally:
        if urls:
            release(urls)
        if error.value:
            release(error)
        release(bundle)


def exact_not_found(result, path):
    # Accept only the observed, path-specific -10814 failure, never a mixed scan error.
    lines = [line.strip() for stream in (result.stdout, result.stderr) for line in stream.splitlines() if line.strip()]
    expected = f"failed to scan {path}: -10814"
    return result.returncode == 1 and lines.count(expected) == 1 and all(
        line == expected or line == "from spotlight" for line in lines
    ) and lines.count("from spotlight") <= 1


def register_bundle(path, unregister=False):
    # Use an exact bundle path; never rebuild or clear the user's LaunchServices database.
    result = subprocess.run(
        [LSREGISTER, "-u" if unregister else "-f", str(path)],
        capture_output=True, text=True,
    )
    if result.returncode:
        if unregister and exact_not_found(result, path):
            # A never-registered build can return -10814. Confirm the exact path is absent
            # independently before treating this as an already-completed unregistration.
            if path.resolve() not in registered_bundle_paths(bundle_id(path)):
                return
        operation = "注销旧应用" if unregister else "登记应用"
        detail = result.stderr.strip() or result.stdout.strip()
        raise InstallError(f"系统{operation}失败：{path}\n{detail}")


class Installer:
    def __init__(self, repo, source, cleanup=True, emit=print, destination=None):
        self.repo = checked_path(repo)
        self.source = checked_path(source)
        if destination is not None and cleanup:
            raise InstallError("自定义安装位置必须同时使用 --no-cleanup。")
        self.target = checked_path(destination if destination is not None else self.repo / "src/dist/Xclip.app")
        if self.target.name != "Xclip.app":
            raise InstallError("安装目标必须命名为 Xclip.app。")
        self.roots = [self.repo / ".build", self.repo / "src/dist"]
        self.cleanup = cleanup
        self.emit = emit
        self.data_paths = set()
        self.external_paths = {
            Path(os.path.abspath(Path(path).expanduser())) for path in external_copy_paths()
        } if cleanup else set()
        self.external_planned = set()

    def preserves_data(self, path):
        return (
            any(part.lower() in DATA_NAMES or part.lower().endswith("-data") for part in path.parts)
            or any(part.startswith(".xclip-install-") for part in path.parts)
            or any(inside(path, data) for data in self.data_paths)
        )

    def collect_data_path(self, app):
        """Retain fixture data referenced by a bundle, even when it has a custom name."""
        with (app / "Contents/Info.plist").open("rb") as handle:
            value = plistlib.load(handle).get("CClipTestDataDirectory")
        if isinstance(value, str) and value:
            path = Path(value).expanduser()
            for base in (self.repo, app.parent):
                self.data_paths.add(Path(os.path.abspath(base / path)))

    def protect(self, path, check_running=True):
        checked_path(path)
        repositories = {self.repo}
        if not inside(path, self.repo):
            for parent in path.parents:
                if (parent / ".git").exists():
                    repositories.add(parent)
                    break
        if any(inside(item, path) for repo in repositories for item in tracked_files(repo)):
            raise InstallError(f"拒绝修改包含 Git 跟踪文件的目录：{path}")
        if check_running:
            active = [(pid, exe) for pid, exe in running_executables() if inside(exe, path)]
            if active:
                details = ", ".join(f"PID {pid}: {exe}" for pid, exe in active)
                raise InstallError(f"请先完全退出以下应用，再重新安装；未自动终止进程：{details}")

    def copies(self):
        found = []
        generated = [self.repo / "src/dist"]
        build = checked_path(self.repo / ".build")
        if build.is_dir():
            # Only known build locations. Arbitrary folders in .build are not an app inventory.
            for child in build.iterdir():
                if child.is_symlink() or self.preserves_data(child):
                    continue
                if child.suffix == ".app" and child.is_dir():
                    generated.append(child)
                elif child.is_dir():
                    if child.name in GENERATED_DIRS or child.name.startswith("build."):
                        generated.append(child)
                    else:
                        generated.extend([child / "dist", child / "Build/Products"])
        for top in generated:
            if top.is_symlink() or self.preserves_data(top):
                continue
            checked_path(top)
            if not top.exists():
                continue
            candidates = [top] if top.suffix == ".app" else []
            if not candidates:
                for root, dirs, _ in os.walk(top, followlinks=False):
                    for name in list(dirs):
                        app = Path(root) / name
                        if app.is_symlink() or self.preserves_data(app):
                            dirs.remove(name)
                        elif app.suffix == ".app":
                            dirs.remove(name)
                            candidates.append(app)
            for app in candidates:
                if app == self.target:
                    continue
                try:
                    if bundle_id(app) in COPY_IDS:
                        self.collect_data_path(app)
                        found.append(app)
                except InstallError:
                    continue
        return sorted({app for app in found if not self.preserves_data(app)})

    def verify_external_copy(self, app, reference):
        if app not in self.external_paths or app == self.target or self.preserves_data(app):
            raise InstallError(f"不在已确认外部副本范围内：{app}")
        checked_path(app)
        if bundle_id(app) != PRODUCTION_ID:
            raise InstallError(f"不是正式 Xclip，保留原文件：{app}")
        if version_key(app) > version_key(reference):
            raise InstallError(f"版本比安装源更新，保留外部副本：{app}")
        certificate = signing_certificate(reference)
        verify_project_signature(reference, certificate)
        verify_project_signature(app, certificate)
        verify_sealed_contents(app)

    def external_copies(self):
        found = []
        for app in sorted(self.external_paths):
            if app == self.target or not (app.exists() or app.is_symlink()):
                continue
            try:
                self.verify_external_copy(app, self.source)
                found.append(app)
            except (InstallError, OSError, ValueError, plistlib.InvalidFileException) as error:
                self.emit(f"保留外部副本：{app}；{error}")
        return found

    def plan(self):
        if bundle_id(self.source) != PRODUCTION_ID:
            raise InstallError(f"安装源必须是正式 Xclip（{PRODUCTION_ID}）：{self.source}")
        verify_signature(self.source)
        self.collect_data_path(self.source)
        self.protect(self.target)
        if self.target.exists() and bundle_id(self.target) != PRODUCTION_ID:
            raise InstallError(f"目标位置已有其他应用，保留原文件：{self.target}")
        if self.target.exists():
            self.collect_data_path(self.target)
            try:
                newer_target = version_key(self.target) > version_key(self.source)
            except InstallError:
                newer_target = False  # Legacy builds without comparable versions remain installable.
            if newer_target:
                raise InstallError(f"已安装版本比安装源更新，拒绝降级：{self.target}")
        old = self.copies() if self.cleanup else []
        external = self.external_copies() if self.cleanup else []
        self.external_planned = set(external)
        old.extend(external)
        for app in old:
            self.protect(app)
        return old

    def remove_copy(self, app):
        external = app in self.external_paths
        if app == self.target or self.preserves_data(app) or not (
            any(inside(app, root) for root in self.roots) or app in self.external_planned
        ):
            raise InstallError(f"清理范围外的路径：{app}")
        self.protect(app)
        if bundle_id(app) not in COPY_IDS:
            raise InstallError(f"不是已知的 Xclip 副本：{app}")
        if external:
            # Source build copies may already be removed. Compare again with the verified install.
            self.verify_external_copy(app, self.target)
            self.protect(app)  # Signature verification can take time; recheck processes afterwards.
        register_bundle(app, unregister=True)
        shutil.rmtree(app)
        self.emit(f"已删除旧副本：{app}")

    def run(self, dry_run=False):
        old = self.plan()
        self.emit(f"{'预览安装' if dry_run else '安装目标'}：{self.source} → {self.target}")
        if dry_run:
            for app in old:
                self.emit(f"验证新版成功后删除：{app}")
            return self.target

        self.target.parent.mkdir(parents=True, exist_ok=True)
        checked_path(self.target.parent)
        lock_path = checked_path(self.target.parent / ".xclip-install.lock")
        self.protect(lock_path, check_running=False)
        descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise InstallError("另一个 Xclip 安装正在进行，请等待其完成。") from error
            old = self.plan()  # Recheck after obtaining the installation lock.
            if self.source != self.target:
                self.replace()
            else:
                register_bundle(self.target)
            for app in old:
                self.remove_copy(app)
        self.emit(f"安装完成：{self.target}")
        return self.target

    def replace(self):
        container = Path(tempfile.mkdtemp(prefix=".xclip-install-", dir=self.target.parent))
        stage = container / "Xclip.app"
        exchanged = False
        keep_recovery = False
        registration_attempted = False
        try:
            copy_bundle(self.source, stage)
            if bundle_id(stage) != PRODUCTION_ID:
                raise InstallError("暂存应用标识校验失败。")
            verify_signature(stage)
            self.protect(self.target)
            exchanged = self.target.exists()
            if exchanged and bundle_id(self.target) != PRODUCTION_ID:
                raise InstallError("目标位置的应用已发生变化；保留原文件。")
            atomic_move(stage, self.target, exchange=exchanged)
            try:
                if bundle_id(self.target) != PRODUCTION_ID:
                    raise InstallError("安装后应用标识校验失败。")
                verify_signature(self.target)
                registration_attempted = True
                register_bundle(self.target)
            except Exception as error:
                if not exchanged and registration_attempted:
                    try:
                        register_bundle(self.target, unregister=True)
                    except Exception as registration_error:
                        self.emit(f"系统可能保留失败安装的登记，需要检查该路径：{self.target}；{registration_error}")
                try:
                    # Keep the old bundle until the new target passes signing and system registration.
                    atomic_move(self.target, stage, exchange=exchanged)
                except Exception as rollback_error:
                    keep_recovery = True
                    raise InstallError(
                        f"安装验证失败且无法自动回滚；保留恢复副本：{stage}。"
                        f" 原因：{error}；回滚：{rollback_error}"
                    ) from rollback_error
                if exchanged:
                    try:
                        register_bundle(self.target)
                    except Exception as registration_error:
                        self.emit(f"旧应用文件已恢复，但系统登记仍需检查：{self.target}；{registration_error}")
                raise InstallError(f"安装验证失败，已恢复安装前状态：{error}") from error
        finally:
            if not keep_recovery:
                # Only remove the private, generated staging bundle, never its siblings.
                if stage.exists():
                    try:
                        self.protect(stage)
                        bundle_id(stage)
                        shutil.rmtree(stage)
                    except Exception:
                        # A damaged copy can contain links. Preserve it instead of broad cleanup.
                        self.emit(f"保留待检查的暂存目录：{container}")
                        raise
                if container.exists():
                    container.rmdir()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, help="已签名的正式 Xclip.app 路径")
    parser.add_argument("--destination", help="自定义 Xclip.app 输出位置；必须同时指定 --no-cleanup")
    parser.add_argument("--dry-run", action="store_true", help="仅验证并显示安装、清理计划")
    parser.add_argument("--no-cleanup", action="store_true", help="安装后保留生成目录和固定外部位置的其他副本")
    args = parser.parse_args()
    try:
        Installer(
            Path(__file__).resolve().parents[1], args.source,
            cleanup=not args.no_cleanup, destination=args.destination,
        ).run(args.dry_run)
    except (InstallError, OSError, subprocess.SubprocessError) as error:
        print(f"Xclip 安装未完成：{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
