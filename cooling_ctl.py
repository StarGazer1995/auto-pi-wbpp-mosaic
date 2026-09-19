#!/usr/bin/env python3
"""whyLIAN 冷却控制: 在长时间任务前后强制/恢复泵与风扇转速。

用法:
  cooling_ctl.py save-full SNAPSHOT.json
      把当前 ~/.config/lianli/config.json 备份到 SNAPSHOT.json，
      将全部 AIO 泵与风扇设为 255(全速) 并写回 config.json，
      然后等待实际转速到位(约 30-50s)。
  cooling_ctl.py save-fans SNAPSHOT.json
      同上，但只把 AIO 冷排风扇拉满(255)，泵策略保持不动；
      适合 GPU 训练这类只要加大冷排/机箱风量的场景。
  cooling_ctl.py restore SNAPSHOT.json
      用 SNAPSHOT.json 恢复 daemon 与 config.json，
      然后等待转速回落到位。
      若快照本身是"满速"状态（泵/风扇都被钉在 255），说明上次任务没恢复干净，
      此时改为切回温度曲线控制（而不是把满速再恢复一遍）。
      需要严格照着快照恢复时用: restore --keep SNAPSHOT.json
  cooling_ctl.py curves [--pump 曲线名] [--fans 曲线名]
      把 AIO 泵/风扇从固定转速切回**温度曲线控制**（闲置安静，负载自动升速）。
      默认 --pump Pump --fans MaxTemp
      （Pump 曲线跟冷却液温度；MaxTemp 曲线取 max(CPU,GPU) 温度）
      传 none 可只改其中一项，例如: --fans none

如果无线风扇 hub 变成 wireless-unbound，会自动尝试重新绑定。
"""

import json
import os
import socket
import sys
import time

CFG_PATH = os.path.expanduser("~/.config/lianli/config.json")

# 闲置/正常状态用的温度曲线名（config.json 里 pump_target_rpm / fan_speeds 支持填曲线名）
DEFAULT_PUMP_CURVE = "Pump"
DEFAULT_FAN_CURVE = "MaxTemp"


def daemon_socket() -> str:
    runtime = os.environ.get("XDG_RUNTIME_DIR", "")
    if not runtime:
        runtime = "/run/user/%d" % os.getuid()
    return os.path.join(runtime, "lianli-daemon.sock")


def call(method: str, params=None):
    req = {"method": method, "params": params}
    payload = (json.dumps(req, separators=(",", ":")) + "\n").encode()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(5)
        s.connect(daemon_socket())
        s.sendall(payload)
        buf = b""
        while b"\n" not in buf:
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
    line = buf.split(b"\n", 1)[0].decode()
    return json.loads(line)


def read_cfg() -> dict:
    with open(CFG_PATH, "r", encoding="utf-8") as fh:
        return json.load(fh)


def write_cfg(cfg: dict) -> None:
    with open(CFG_PATH, "w", encoding="utf-8") as fh:
        json.dump(cfg, fh, ensure_ascii=False, indent=2)


def aio_radiator_serials(cfg: dict):
    serials = set()
    aio = cfg.get("aio")
    if isinstance(aio, dict):
        for dev_cfg in aio.values():
            if not isinstance(dev_cfg, dict):
                continue
            rid = dev_cfg.get("radiator_fan_device_id")
            if isinstance(rid, str) and ":" in rid:
                serials.add(rid.split(":", 1)[1])
    return serials


def ensure_fan_hub_bound(cfg: dict) -> bool:
    serials = aio_radiator_serials(cfg)
    if not serials:
        return True
    resp = call("ListDevices")
    if resp.get("status") != "ok":
        return False
    for dev in resp.get("data", []):
        dev_id = dev.get("device_id", "")
        if not dev_id.startswith("wireless-unbound:"):
            continue
        serial = dev_id.split(":", 1)[1]
        if serial in serials:
            print("fan hub unbound, rebinding:", serial)
            r = call("BindWirelessDevice", {"mac": serial})
            if r.get("status") != "ok":
                print("bind failed:", json.dumps(r, ensure_ascii=False))
                return False
            time.sleep(6)
            return True
    return True


def force_full(cfg: dict) -> int:
    changed = 0
    aio = cfg.get("aio")
    if not isinstance(aio, dict):
        return 0
    for device_cfg in aio.values():
        if not isinstance(device_cfg, dict):
            continue
        if "pump_target_rpm" in device_cfg:
            device_cfg["pump_target_rpm"] = 255
            changed += 1
        fans = device_cfg.get("fan_speeds")
        if isinstance(fans, list) and fans:
            device_cfg["fan_speeds"] = [255] * len(fans)
            changed += 1
    return changed


def set_curves(cfg: dict, pump: str, fans: str) -> int:
    """把 AIO 的泵/风扇目标从固定占空比(0-255)切回曲线名。"""
    changed = 0
    aio = cfg.get("aio")
    if not isinstance(aio, dict):
        return 0
    for _dev, device_cfg in aio.items():
        if not isinstance(device_cfg, dict):
            continue
        if pump and pump.lower() != "none":
            device_cfg["pump_target_rpm"] = pump
            changed += 1
        if fans and fans.lower() != "none":
            cur = device_cfg.get("fan_speeds")
            n = len(cur) if isinstance(cur, list) and cur else 4
            device_cfg["fan_speeds"] = [fans] * n
            changed += n
    return changed


def is_full_state(cfg: dict) -> bool:
    """判断配置是否为"泵与风扇全部钉在 255(全速)"。"""
    aio = cfg.get("aio")
    if not isinstance(aio, dict) or not aio:
        return False
    for _dev, device_cfg in aio.items():
        if not isinstance(device_cfg, dict):
            continue
        if device_cfg.get("pump_target_rpm") != 255:
            return False
        fans = device_cfg.get("fan_speeds")
        if not isinstance(fans, list) or not fans:
            continue
        if any(f != 255 for f in fans):
            return False
    return True


def speed_state(cfg: dict):
    """返回 (pump_rpm, max_other_fan_rpm)；AIO 数组最后一项视为泵。"""
    data = call("GetTelemetry").get("data", {})
    rpms = data.get("fan_rpms", {})
    aio_keys = set()
    aio = cfg.get("aio")
    if isinstance(aio, dict):
        aio_keys = set(aio.keys())
    pump = 0
    fans = []
    for dev, vals in rpms.items():
        vals = vals or []
        if dev in aio_keys:
            if len(vals) > 1:
                fans.extend(vals[:-1])
                pump = max(pump, vals[-1])
            elif vals:
                pump = max(pump, vals[0])
        else:
            fans.extend(vals)
    return pump, max(fans or [0])


def wait_speed(cfg: dict, want_full: bool, timeout: float) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            pump, fan = speed_state(cfg)
        except Exception as exc:
            pump, fan = 0, 0
        if want_full and pump >= 2400 and fan >= 2400:
            print("full speed reached: pump=%d fan=%d" % (pump, fan))
            return True
        if not want_full and pump <= 2350 and fan <= 1200:
            print("idle curve reached: pump=%d fan=%d" % (pump, fan))
            return True
        time.sleep(2)
    try:
        pump, fan = speed_state(cfg)
    except Exception:
        pump, fan = 0, 0
    print("warning: speed wait timeout want_full=%s pump=%d fan=%d" % (want_full, pump, fan))
    return False


def force_fans(cfg: dict) -> int:
    """只把 AIO 的 fan_speeds 拉满，pump_target_rpm 保持不变。"""
    changed = 0
    aio = cfg.get("aio")
    if not isinstance(aio, dict):
        return 0
    for device_cfg in aio.values():
        if not isinstance(device_cfg, dict):
            continue
        fans = device_cfg.get("fan_speeds")
        if isinstance(fans, list) and fans:
            device_cfg["fan_speeds"] = [255] * len(fans)
            changed += len(fans)
    return changed


def wait_fans(cfg: dict, min_rpm: int, timeout: float) -> bool:
    """只等风扇转速到 min_rpm，忽略泵。"""
    deadline = time.time() + timeout
    fan = 0
    while time.time() < deadline:
        try:
            _, fan = speed_state(cfg)
        except Exception:
            fan = 0
        if fan >= min_rpm:
            print("fans at %d rpm (>= %d)" % (fan, min_rpm))
            return True
        time.sleep(3)
    print("warning: fan wait timeout max=%d rpm want>=%d" % (fan, min_rpm))
    return False


def main() -> None:
    if len(sys.argv) >= 2 and sys.argv[1] == "curves":
        pump, fans = "Pump", "MaxTemp"
        rest = sys.argv[2:]
        i = 0
        while i < len(rest):
            if rest[i] == "--pump" and i + 1 < len(rest):
                pump = rest[i + 1]
                i += 2
            elif rest[i] == "--fans" and i + 1 < len(rest):
                fans = rest[i + 1]
                i += 2
            else:
                print(__doc__)
                sys.exit(2)
        cfg = read_cfg()
        ensure_fan_hub_bound(cfg)
        changed = set_curves(cfg, pump, fans)
        resp = call("SetConfig", {"config": cfg})
        if resp.get("status") != "ok":
            print(json.dumps(resp, ensure_ascii=False))
            sys.exit(1)
        write_cfg(cfg)
        ok = wait_speed(cfg, False, 120.0)
        print("curves applied (pump=%s fans=%s changed=%d)" % (pump, fans, changed))
        sys.exit(0 if ok else 1)

    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)

    op, snapshot = sys.argv[1], sys.argv[2]

    if op == "save-full":
        cfg = read_cfg()
        ensure_fan_hub_bound(cfg)
        with open(snapshot, "w", encoding="utf-8") as fh:
            json.dump(cfg, fh, ensure_ascii=False, indent=2)
        changed = force_full(cfg)
        resp = call("SetConfig", {"config": cfg})
        if resp.get("status") != "ok":
            print(json.dumps(resp, ensure_ascii=False))
            sys.exit(1)
        write_cfg(cfg)
        ok = wait_speed(cfg, True, 60.0)
        print("full-speed applied (changed=%d); snapshot=%s" % (changed, snapshot))
        sys.exit(0 if ok else 1)

    if op == "save-fans":
        cfg = read_cfg()
        ensure_fan_hub_bound(cfg)
        with open(snapshot, "w", encoding="utf-8") as fh:
            json.dump(cfg, fh, ensure_ascii=False, indent=2)
        changed = force_fans(cfg)
        resp = call("SetConfig", {"config": cfg})
        if resp.get("status") != "ok":
            print(json.dumps(resp, ensure_ascii=False))
            sys.exit(1)
        write_cfg(cfg)
        ok = wait_fans(cfg, 2000, 75.0)
        print("fan-full applied (fans=%d); snapshot=%s" % (changed, snapshot))
        sys.exit(0 if ok else 1)

    if op == "restore":
        keep = False
        if snapshot == "--keep":
            # restore --keep SNAPSHOT.json
            if len(sys.argv) != 4:
                print(__doc__)
                sys.exit(2)
            keep, snapshot = True, sys.argv[3]
        with open(snapshot, "r", encoding="utf-8") as fh:
            cfg = json.load(fh)
        ensure_fan_hub_bound(cfg)
        if not keep and is_full_state(cfg):
            n = set_curves(cfg, DEFAULT_PUMP_CURVE, DEFAULT_FAN_CURVE)
            print("snapshot 是全速状态(上次任务未恢复干净) -> 改为曲线控制 "
                  "(pump=%s fans=%s, changed=%d)" % (DEFAULT_PUMP_CURVE, DEFAULT_FAN_CURVE, n))
        resp = call("SetConfig", {"config": cfg})
        if resp.get("status") != "ok":
            print(json.dumps(resp, ensure_ascii=False))
            sys.exit(1)
        write_cfg(cfg)
        ok = wait_speed(cfg, False, 120.0)
        aio = cfg.get("aio") or {}
        for _dev, device_cfg in aio.items():
            if isinstance(device_cfg, dict):
                print("restored from %s (pump=%s fans=%s)" % (
                    snapshot, device_cfg.get("pump_target_rpm"),
                    device_cfg.get("fan_speeds")))
                break
        else:
            print("restored from %s" % snapshot)
        sys.exit(0 if ok else 1)

    print(__doc__)
    sys.exit(2)


if __name__ == "__main__":
    main()
