#!/usr/bin/env python3
"""Delux M900 Pro (1d57:fa65 2.4G 8K HS Receiver) 无线鼠标电量读取。

只读实现：只打开厂商 collection（usage_page 0xff00, report ID 3），
从不打开鼠标/指针 collection，也不向设备写任何字节。

接收器每 ~4 秒推一帧 5 字节状态包：

    buf[0] = 0x03           report id
    buf[1] = 0x30           (常量)
    buf[2] = 0x40           (常量)
    buf[3] = flags          bit0 = 鼠标链路在线, bit1 = 充电中
    buf[4] = 电量百分比     0x00..0x64

⚠ 充电期间 buf[4] 会被充电电压顶成 0x64(100), 是不可信值（实测 81% 放上底座
   3 秒就变 100）。官方 Compx/Delux 网页驱动对这种情况的处理是：连续读到 8 次
   100 才采信，且优先用电压换算百分比。本工具因此在充电时只显示"上次已知电量"，
   不把 100 当成真实电量。

鼠标关机时整条链路静默，不会收到任何帧（= 不在线）。
状态刚变化的那一帧会先给一个 0x64(100) 的占位值，约 2 秒后落到真实值，
所以读取时要等帧稳定后再取值（见 settle()）。

用法:
    python3 mouse_battery.py              # 打印一次
    python3 mouse_battery.py --watch      # 持续打印变化
    python3 mouse_battery.py --json       # 机器可读
    python3 mouse_battery.py --offline-ok # 鼠标关机时退出码 0（默认 3）
"""

import argparse
import json
import sys
import time

VID, PID = 0x1D57, 0xFA65
VENDOR_USAGE_PAGE = 0xFF00
REPORT_ID = 0x03

PLACEHOLDER = 100          # 状态切换时的占位值
SETTLE_SECONDS = 3.0       # 等待占位值落地的时长
POLL_TIMEOUT = 12.0        # 等第一帧的上限（离线判定）

EXIT_OFFLINE = 3


def find_vendor_path():
    import hid
    for d in hid.enumerate(VID, PID):
        if d["usage_page"] == VENDOR_USAGE_PAGE:
            return d["path"]
    return None


def open_device():
    import hid
    path = find_vendor_path()
    if path is None:
        raise SystemExit("没找到 1d57:fa65 的厂商接口（接收器没插？）")
    dev = hid.device()
    try:
        dev.open_path(path)
    except OSError as e:
        raise SystemExit(f"打开失败（可能另一个抓包进程占着）：{e}")
    dev.set_nonblocking(1)
    return dev


def wait_frame(dev, timeout=POLL_TIMEOUT):
    """返回 (flags, level) 或 None（离线）。丢弃非法帧。"""
    deadline = time.time() + timeout
    while time.time() < deadline:
        r = dev.read(64)
        if r and len(r) >= 5 and r[0] == REPORT_ID:
            return bytes(r)
        time.sleep(0.002)
    return None


def parse(buf):
    flags = buf[3]
    charging = bool(flags & 0x02)
    level = buf[4]
    # 充电中读到 100 属于充电电压造成的假值，不可信
    trust = not (charging and level == PLACEHOLDER)
    # 能收到帧就说明接收器在线；flags bit0 在充电时会抖动，不可单独当在线判据
    return {"online": True, "link_bit": bool(flags & 0x01), "charging": charging,
            "level": level, "trustworthy": trust, "raw": bytes(buf).hex()}


def settle(dev, first):
    """状态刚切换时会先报 100 占位值；等真实值落下再返回。"""
    st = parse(first)
    if st["level"] != PLACEHOLDER:
        return st
    deadline = time.time() + SETTLE_SECONDS
    while time.time() < deadline:
        r = dev.read(64)
        if r and len(r) >= 5 and r[0] == REPORT_ID:
            st = parse(r)
            if st["level"] != PLACEHOLDER:
                return st
        time.sleep(0.002)
    return st


def render(st, last_good=None):
    if st is None:
        return "offline（鼠标关机或没连上）"
    if not st.get("trustworthy", True):
        base = f"{last_good}%（上次）" if last_good is not None else "电量未知"
        return f"{base}  充电中（实时电量被充电电压顶成 100，不可信）"
    tag = "充电中" if st["charging"] else "放电中"
    return f"{st['level']}%  {tag}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--watch", action="store_true", help="持续监听并打印变化")
    ap.add_argument("--json", action="store_true", help="输出 JSON")
    ap.add_argument("--offline-ok", action="store_true", help="离线时退出码为 0")
    ap.add_argument("--interval", type=float, default=0.0, help="watch 时两次采样间隔下限(秒)")
    args = ap.parse_args()

    dev = open_device()
    try:
        if not args.watch:
            buf = wait_frame(dev)
            st = None if buf is None else settle(dev, buf)
            if args.json:
                print(json.dumps(st or {"online": False}))
            else:
                print(render(st))
            return 0 if (st or args.offline_ok) else EXIT_OFFLINE

        print(f"监听中… {VID:04x}:{PID:04x}（Ctrl-C 退出）")
        last = None
        last_print = 0.0
        last_good = None
        while True:
            buf = wait_frame(dev, timeout=POLL_TIMEOUT)
            st = None if buf is None else settle(dev, buf)
            if st and st.get("trustworthy", True):
                last_good = st["level"]
            key = None if st is None else (st["link_bit"], st["charging"],
                                           st["level"], st.get("trustworthy"))
            if key != last or time.time() - last_print > 60:
                ts = time.strftime("%H:%M:%S")
                print(f"{ts}  {render(st, last_good)}" + ("" if st is None else f"   raw={st['raw']}"))
                last = key
                last_print = time.time()
            if args.interval:
                time.sleep(args.interval)
    except KeyboardInterrupt:
        return 0
    finally:
        dev.close()


if __name__ == "__main__":
    sys.exit(main())
