#!/usr/bin/env python3
"""Select an existing signing identity without changing the user's keychains."""

import argparse
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


class SigningError(RuntimeError):
    pass


def parse_identities(output):
    identities = {}
    for line in output.splitlines():
        match = re.fullmatch(r'\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"([^"\n]+)"\s*', line)
        if match:
            identities[match[1].upper()] = match[2]
    return identities


def choose_identity(identities, explicit=None, installed=None):
    """Return a certificate SHA-1, or '-' only when no certificate is replaced."""
    if explicit is not None:
        explicit = explicit.strip()
        if explicit == "-":
            if installed:
                raise SigningError("已安装版本使用证书签名，拒绝降级为 ad-hoc；请恢复原证书或明确选择其他有效证书。")
            return "-"
        matches = [key for key, name in identities.items()
                   if key == explicit.upper() or name == explicit]
        if len(matches) != 1:
            raise SigningError("指定的签名身份无效或不唯一；请使用 security find-identity -v -p codesigning 中的完整 SHA-1。")
        return matches[0]
    if installed:
        if installed not in identities:
            raise SigningError("已安装版本的签名证书不可用，已停止更新；请恢复证书及私钥，禁止自动回退到 ad-hoc。")
        return installed
    if len(identities) == 1:
        return next(iter(identities))
    if not identities:
        return "-"
    raise SigningError("发现多个有效签名身份；请用 XCLIP_CODE_SIGN_IDENTITY 指定完整 SHA-1 后再构建。")


def installed_certificate(app):
    if not app.exists():
        return None
    with tempfile.TemporaryDirectory(prefix="xclip-signing-") as folder:
        prefix = str(Path(folder) / "certificate")
        result = subprocess.run(
            ["/usr/bin/codesign", "-d", "--extract-certificates=" + prefix, str(app)],
            capture_output=True, text=True,
        )
        if result.returncode:
            raise SigningError(f"无法核对已安装版本的签名，停止更新：{app}\n{result.stderr.strip()}")
        certificate = Path(prefix + "0")
        if certificate.exists():
            return hashlib.sha1(certificate.read_bytes()).hexdigest().upper()
        details = subprocess.run(
            ["/usr/bin/codesign", "-d", "--verbose=4", str(app)], capture_output=True, text=True,
        )
        if details.returncode or "Signature=adhoc" not in details.stderr.splitlines():
            raise SigningError(f"已安装版本的签名类型不明确，停止更新：{app}")
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--installed-app", required=True, type=Path)
    args = parser.parse_args()
    try:
        result = subprocess.run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"],
                                capture_output=True, text=True)
        if result.returncode:
            raise SigningError("无法读取有效签名身份；停止构建，不更改钥匙串。\n" + result.stderr.strip())
        identities = parse_identities(result.stdout)
        count = re.search(r"(\d+) valid identities found", result.stdout)
        if not count or (int(count[1]) > 0 and not identities):
            raise SigningError("无法解析有效签名身份列表；停止构建，不自动回退到 ad-hoc。")
        installed = installed_certificate(args.installed_app)
        explicit = os.environ.get("XCLIP_CODE_SIGN_IDENTITY", os.environ.get("CCLIP_CODE_SIGN_IDENTITY"))
        selected = choose_identity(identities, explicit, installed)
        if selected == "-":
            print("警告：没有使用稳定证书，本次为 ad-hoc 签名。新版代码会改变签名身份，屏幕录制授权仍可能需要重新添加；固定路径和删除旧版不能保证授权延续。", file=sys.stderr)
        else:
            print(f"签名身份：{identities[selected]} ({selected})", file=sys.stderr)
            if installed and selected != installed:
                print("注意：显式配置正在更换已安装版本的签名证书，可能需要重新授权。", file=sys.stderr)
        print(selected)
        return 0
    except (OSError, SigningError) as error:
        print(f"签名选择失败：{error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
