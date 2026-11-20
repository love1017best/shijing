#!/usr/bin/env python3
"""iOS 描述文件（.mobileprovision）检查、备份与嵌入指纹读取工具。"""

import datetime
import glob
import hashlib
import os
import plistlib
import shutil
import sys

PROFILE_DIRS = [
    os.path.expanduser("~/Library/Developer/Xcode/UserData/Provisioning Profiles"),
    os.path.expanduser("~/Library/MobileDevice/Provisioning Profiles"),
]


def parse_mobileprovision(path):
    """读取并解析 .mobileprovision 文件，返回 (原始字节, plist 字典)；无法解析时返回 (None, None)。"""
    try:
        with open(path, "rb") as f:
            data = f.read()
        start = data.find(b"<?xml")
        end = data.find(b"</plist>", start)
        if start < 0 or end < 0:
            return data, None
        return data, plistlib.loads(data[start : end + 8])
    except (OSError, plistlib.InvalidFileException, ValueError):
        return None, None


def matches_bundle(plist_data, bundle_id):
    appid = plist_data.get("Entitlements", {}).get("application-identifier", "")
    if not appid:
        return ""
    suffix = appid.split(".", 1)[1] if "." in appid else appid
    if suffix == bundle_id or suffix.startswith(bundle_id + "."):
        return appid
    return ""


def normalize_utc(dt):
    if dt.tzinfo is None:
        return dt.replace(tzinfo=datetime.timezone.utc)
    return dt


def iter_host_profiles(bundle_id):
    """枚举本机缓存中匹配指定 bundle_id 的描述文件，按路径排序输出 (path, appid, plist_data)。"""
    for directory in PROFILE_DIRS:
        for path in sorted(glob.glob(os.path.join(directory, "*.mobileprovision"))):
            _, plist_data = parse_mobileprovision(path)
            if not plist_data:
                continue
            appid = matches_bundle(plist_data, bundle_id)
            if appid:
                yield path, appid, plist_data


def cmd_inspect(bundle_id):
    by_app = {}
    file_count = 0
    for path, appid, plist_data in iter_host_profiles(bundle_id):
        exp = plist_data.get("ExpirationDate")
        if not isinstance(exp, datetime.datetime):
            continue
        file_count += 1
        by_app.setdefault(appid, []).append((normalize_utc(exp), path))

    if not by_app:
        print("0|||0")
        return

    now = datetime.datetime.now(datetime.timezone.utc)
    earliest = min(max(items, key=lambda item: item[0])[0] for items in by_app.values())
    rem_sec = int((earliest - now).total_seconds())
    exp_local = earliest.astimezone().strftime("%Y-%m-%d %H:%M")
    print(f"{len(by_app)}|{rem_sec}|{exp_local}|{file_count}")


def cmd_backup_remove(bundle_id, backup_dir):
    idx = 0
    manifest_path = os.path.join(backup_dir, "manifest.tsv")
    with open(manifest_path, "w", encoding="utf-8") as mf:
        for path, _, _ in iter_host_profiles(bundle_id):
            try:
                idx += 1
                shutil.copy2(path, os.path.join(backup_dir, str(idx)))
                mf.write(f"{idx}\t{path}\n")
                os.remove(path)
            except OSError:
                continue


def cmd_inspect_embedded(app_path):
    paths = [os.path.join(app_path, "embedded.mobileprovision")]
    paths.extend(sorted(glob.glob(os.path.join(app_path, "PlugIns", "*.appex", "embedded.mobileprovision"))))

    exps = []
    digests = []
    for path in paths:
        if not os.path.isfile(path):
            continue
        data, plist_data = parse_mobileprovision(path)
        if data is not None:
            digests.append(hashlib.sha256(data).hexdigest())
        if not plist_data:
            continue
        exp = plist_data.get("ExpirationDate")
        if isinstance(exp, datetime.datetime):
            exps.append(normalize_utc(exp))

    fingerprint = hashlib.sha256("\n".join(digests).encode()).hexdigest() if digests else ""
    if not exps:
        print(f"||{fingerprint}")
        return

    now = datetime.datetime.now(datetime.timezone.utc)
    earliest = min(exps)
    rem_sec = int((earliest - now).total_seconds())
    exp_local = earliest.astimezone().strftime("%Y-%m-%d %H:%M")
    if rem_sec <= 0:
        rem_text = "已过期"
    elif rem_sec < 3600:
        rem_text = f"剩余 {max(1, rem_sec // 60)} 分钟"
    elif rem_sec < 48 * 3600:
        rem_text = f"剩余 {rem_sec // 3600} 小时"
    else:
        rem_text = f"剩余 {round(rem_sec / 86400)} 天"
    print(f"{exp_local}|{rem_text}|{fingerprint}")


def main(argv):
    if len(argv) < 3:
        sys.exit(2)
    cmd = argv[1]
    if cmd == "inspect":
        cmd_inspect(argv[2])
    elif cmd == "backup-remove" and len(argv) >= 4:
        cmd_backup_remove(argv[2], argv[3])
    elif cmd == "inspect-embedded":
        cmd_inspect_embedded(argv[2])
    else:
        sys.exit(2)


if __name__ == "__main__":
    main(sys.argv)
