#!/usr/bin/env bash
# SSH -> DingTalk login alert with manually maintained trusted IPs.
# Debian/Ubuntu, OpenSSH + PAM. No external Python modules needed.
set -euo pipefail
umask 077

CONFIG='/etc/ssh-login-dingtalk.json'
SENDER='/usr/local/sbin/ssh-login-dingtalk.py'
HOOK='/usr/local/sbin/ssh-login-dingtalk-hook.sh'
PAM='/etc/pam.d/sshd'
PAM_RULE='session optional pam_exec.so type=open_session quiet /usr/local/sbin/ssh-login-dingtalk-hook.sh'
BACKUP_DIR='/var/backups/ssh-login-dingtalk'

fail() { echo "错误：$*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || fail '请使用 sudo bash install-ssh-dingtalk.sh'
command -v python3 >/dev/null 2>&1 || fail '缺少 python3'
[ -f "$PAM" ] || fail '未找到 /etc/pam.d/sshd，仅支持启用 PAM 的 Debian/Ubuntu SSH 服务'

if [[ "${1:-}" == '--uninstall' ]]; then
  if grep -Fxq "$PAM_RULE" "$PAM"; then
    install -d -m 700 "$BACKUP_DIR"
    cp -a "$PAM" "$BACKUP_DIR/sshd.before-uninstall.$(date +%Y%m%d-%H%M%S)"
    sed -i '\|^# DingTalk SSH login alerts$|d;\|^session optional pam_exec.so type=open_session quiet /usr/local/sbin/ssh-login-dingtalk-hook.sh$|d' "$PAM"
  fi
  rm -f "$HOOK" "$SENDER"
  echo '已停用 SSH 钉钉登录提醒。凭据与 IP 白名单仍保留在 /etc/ssh-login-dingtalk.json。'
  exit 0
fi
[[ "${1:-}" == '' || "${1:-}" == '--reconfigure' ]] || fail '仅支持 --reconfigure 或 --uninstall'

SSHD_BIN="$(command -v sshd || true)"
[ -n "$SSHD_BIN" ] || SSHD_BIN='/usr/sbin/sshd'
[ -x "$SSHD_BIN" ] || fail '未找到 sshd'
SSHD_CONFIG="$($SSHD_BIN -T 2>/dev/null)" || fail 'sshd -T 失败，未修改任何 SSH 配置'
grep -Fxq 'usepam yes' <<< "$SSHD_CONFIG" || fail 'SSH 未启用 UsePAM yes，无法使用此安装方式'

RECONFIGURE=false
if [[ "${1:-}" == '--reconfigure' || ! -s "$CONFIG" ]]; then
  RECONFIGURE=true
else
  echo "发现已有配置：$CONFIG"
  read -r -p '保留原 Webhook、密钥及 IP 白名单？[Y/n] ' answer </dev/tty
  if [[ "${answer:-Y}" =~ ^[Nn]$ ]]; then RECONFIGURE=true; fi
fi

if $RECONFIGURE; then
  [ -r /dev/tty ] || fail '需要终端交互输入 Webhook，请通过 SSH 终端安装'
  echo '敏感信息只保存在 VPS 本地，绝不上传到 GitHub。'
  read -r -s -p '钉钉机器人 Webhook URL（隐藏输入）：' WEBHOOK </dev/tty
  printf '\n' >/dev/tty
  read -r -s -p '加签密钥 SEC...（未启用加签直接回车）：' SECRET </dev/tty
  printf '\n' >/dev/tty
  read -r -p '自定义关键词（没有可直接回车，默认 服务器登录）：' KEYWORD </dev/tty
  read -r -p "服务器显示名称 [$(hostname -s)]：" SERVER </dev/tty
  KEYWORD="${KEYWORD:-服务器登录}"
  SERVER="${SERVER:-$(hostname -s)}"
  export WEBHOOK SECRET KEYWORD SERVER
  python3 - <<'PY'
import json, os, tempfile, urllib.parse
from pathlib import Path


def normalize_input(field, value, *, ascii_only=False):
    """Recover GB18030/GBK input that some SSH clients pass as raw bytes.

    On POSIX Python decodes invalid environment bytes with surrogateescape;
    json.dump(ensure_ascii=False) cannot encode these surrogate code points.
    """
    if any(0xDC80 <= ord(c) <= 0xDCFF for c in value):
        if ascii_only:
            raise SystemExit(f'{field} 存在非 ASCII 字符，请检查粘贴内容后重试。')
        raw = value.encode('utf-8', 'surrogateescape')
        try:
            value = raw.decode('gb18030', 'strict')
        except UnicodeDecodeError:
            raise SystemExit(f'{field} 的输入编码无法识别。请将 SSH 客户端设为 UTF-8，或改用英文服务器名重试。')
        print(f'提示：检测到 {field} 使用非 UTF-8 编码，已自动转换。')
    try:
        value.encode('utf-8', 'strict')
    except UnicodeEncodeError:
        raise SystemExit(f'{field} 存在非法字符。请将 SSH 客户端设为 UTF-8 后重试。')
    if ascii_only and not value.isascii():
        raise SystemExit(f'{field} 仅允许 ASCII 字符，请检查是否有中文标点或空格。')
    return value.strip()


p = Path('/etc/ssh-login-dingtalk.json')
webhook = normalize_input('Webhook', os.environ['WEBHOOK'], ascii_only=True)
u = urllib.parse.urlsplit(webhook)
q = urllib.parse.parse_qs(u.query)
if not (u.scheme == 'https' and u.hostname == 'oapi.dingtalk.com' and
        u.path == '/robot/send' and q.get('access_token', [''])[0]):
    raise SystemExit('Webhook 必须是 https://oapi.dingtalk.com/robot/send?access_token=...')
old = {}
if p.is_file():
    try:
        old = json.loads(p.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        pass
cfg = {'webhook': webhook,
       'secret': normalize_input('加签密钥', os.environ['SECRET'], ascii_only=True),
       'keyword': normalize_input('自定义关键词', os.environ['KEYWORD']),
       'server': normalize_input('服务器名称', os.environ['SERVER']),
       'trusted_ips': old.get('trusted_ips', []),
       'geo_enabled': old.get('geo_enabled', True)}
fd, path = tempfile.mkstemp(prefix='.ssh-login-dingtalk.', dir=str(p.parent))
try:
    with os.fdopen(fd, 'w', encoding='utf-8') as fp:
        json.dump(cfg, fp, ensure_ascii=False, indent=2)
        fp.write('\n')
    os.chmod(path, 0o600)
    os.replace(path, p)
finally:
    if os.path.exists(path): os.unlink(path)
print('配置已写入本机（权限 600）。')
PY
  unset WEBHOOK SECRET KEYWORD SERVER
else
  python3 - <<'PY'
import json
p='/etc/ssh-login-dingtalk.json'
with open(p, encoding='utf-8') as f: cfg=json.load(f)
assert isinstance(cfg.get('webhook'),str) and cfg['webhook'].startswith('https://oapi.dingtalk.com/robot/send?'), '配置中缺少有效 Webhook'
assert isinstance(cfg.get('trusted_ips',[]),list), 'trusted_ips 必须是数组'
PY
  chmod 600 "$CONFIG"
fi

install -d -m 700 "$BACKUP_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
for item in "$SENDER" "$HOOK"; do
  if [ -f "$item" ]; then cp -a "$item" "$BACKUP_DIR/$(basename "$item").$STAMP"; fi
done

cat > "$SENDER" <<'PYTHON'
#!/usr/bin/env python3
"""SSH login to DingTalk with trusted IP classification and optional GeoIP.

Stdlib-only; invoked asynchronously from the SSH PAM session hook.
Never automatically trusts the first SSH login or IP location.
"""
import argparse
import base64
import hashlib
import hmac
import ipaddress
import json
import os
import re
import socket
import sys
import syslog
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

CONFIG = Path('/etc/ssh-login-dingtalk.json')
CACHE_DIR = Path('/var/cache/ssh-login-dingtalk')
BEIJING = timezone(timedelta(hours=8))


def clean(v, n=100):
    value = str(v if v is not None else '未知')
    if any(0xDC80 <= ord(c) <= 0xDCFF for c in value):
        try:
            value = value.encode('utf-8', 'surrogateescape').decode('gb18030')
        except UnicodeError:
            value = value.encode('utf-8', 'replace').decode('utf-8')
    return re.sub(r'[\x00-\x1f\x7f]', ' ', value).strip()[:n]


def log(ok, message, verbose=False):
    syslog.openlog('ssh-login-dingtalk', syslog.LOG_PID, syslog.LOG_AUTH)
    syslog.syslog(syslog.LOG_INFO if ok else syslog.LOG_ERR, clean(message, 380))
    if verbose:
        print(message)
    return 0 if ok else 1


def load_config():
    with CONFIG.open(encoding='utf-8') as fp:
        cfg = json.load(fp)
    if not isinstance(cfg, dict):
        raise ValueError('无效配置')
    return cfg


def save_config(cfg):
    # Atomic write, root-only file; do not leak the webhook via shell history.
    fd, name = tempfile.mkstemp(prefix='.ssh-login-dingtalk.', dir=str(CONFIG.parent))
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as fp:
            json.dump(cfg, fp, ensure_ascii=False, indent=2)
            fp.write('\n')
        os.chmod(name, 0o600)
        os.replace(name, CONFIG)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def normalize_network(value):
    """Reject host-bit-bearing CIDRs to avoid accidentally trusting a large subnet."""
    value = str(value).strip()
    if '/' not in value:
        addr = ipaddress.ip_address(value)
        return ipaddress.ip_network(f'{addr}/{addr.max_prefixlen}')
    return ipaddress.ip_network(value, strict=True)


def classify(source, entries):
    try:
        ip = ipaddress.ip_address(str(source).strip())
    except ValueError:
        return None, '⚠️ 来源地址无法识别（需核实）', None
    for entry in entries:
        try:
            if isinstance(entry, str):
                network, label = normalize_network(entry), '自定义白名单'
            else:
                network = normalize_network(entry['network'])
                label = entry.get('label', '自定义白名单')
            if ip in network:
                return ip, '✅ 常用 IP（可信白名单）', clean(label, 40)
        except (ValueError, KeyError, TypeError):
            continue
    if ip.is_global:
        return ip, '🚨 陌生公网 IP（不在白名单，需核实）', None
    return ip, '⚠️ 非公网来源（不在白名单，需核实）', None


def direct_opener():
    # Do not inherit HTTP(S)_PROXY from a PAM environment.
    return urllib.request.build_opener(urllib.request.ProxyHandler({}))


def fetch_geo(ip):
    """Approximate location/ISP only, not an intrusion reputation score."""
    empty = {'location': '查询失败或不可用', 'isp': '未知', 'asn': '未知'}
    if ip is None:
        return {'location': '无法识别来源', 'isp': '未知', 'asn': '未知'}
    if not ip.is_global:
        return {'location': '内网、Tailscale 或其他非公网地址', 'isp': '不适用', 'asn': '不适用'}

    key = hashlib.sha256(str(ip).encode('ascii')).hexdigest() + '.json'
    cache_path = CACHE_DIR / key
    try:
        old = json.loads(cache_path.read_text(encoding='utf-8'))
        if time.time() - float(old.get('_saved', 0)) < 86400:
            return {k: clean(old.get(k, '未知')) for k in ('location', 'isp', 'asn')}
    except (OSError, ValueError, TypeError):
        pass

    try:
        req = urllib.request.Request('https://ipwho.is/' + urllib.parse.quote(str(ip)),
                                     headers={'User-Agent': 'ssh-login-dingtalk/2'})
        with direct_opener().open(req, timeout=2.5) as resp:
            raw = resp.read(24576)
        obj = json.loads(raw.decode('utf-8'))
        if not isinstance(obj, dict) or obj.get('success') is not True:
            return empty
        location = ' / '.join(clean(obj.get(k), 48) for k in ('country','region','city') if obj.get(k))
        connection = obj.get('connection') or {}
        if not isinstance(connection, dict):
            connection = {}
        item = {'location': location or '未知',
                'isp': clean(connection.get('isp') or connection.get('org') or '未知'),
                'asn': clean(connection.get('asn') or '未知', 40)}
        try:
            CACHE_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
            os.chmod(CACHE_DIR, 0o700)
            fd, temp = tempfile.mkstemp(prefix='.tmp-', dir=CACHE_DIR)
            try:
                with os.fdopen(fd, 'w', encoding='utf-8') as fp:
                    json.dump({**item, '_saved': time.time()}, fp, ensure_ascii=False)
                os.chmod(temp, 0o600)
                os.replace(temp, cache_path)
            finally:
                if os.path.exists(temp): os.unlink(temp)
        except OSError:
            pass
        return item
    except (OSError, ValueError, urllib.error.URLError, TimeoutError):
        return empty


def send_to_dingtalk(cfg, body):
    url = cfg['webhook']
    secret = cfg.get('secret', '').strip()
    if secret:
        timestamp = str(int(time.time() * 1000))
        msg = f'{timestamp}\n{secret}'.encode('utf-8')
        sign = base64.b64encode(hmac.new(secret.encode('utf-8'), msg, hashlib.sha256).digest()).decode('ascii')
        url += ('&' if '?' in url else '?') + urllib.parse.urlencode({'timestamp': timestamp, 'sign': sign})
    payload = json.dumps({'msgtype': 'text', 'text': {'content': body}}, ensure_ascii=False).encode('utf-8')
    req = urllib.request.Request(url, data=payload,
            headers={'Content-Type':'application/json; charset=utf-8'}, method='POST')
    with direct_opener().open(req, timeout=6) as resp:
        data = json.loads(resp.read(4096).decode('utf-8'))
    if str(data.get('errcode')) != '0':
        raise ValueError('DingTalk errcode=' + clean(data.get('errcode'), 20) + ' ' + clean(data.get('errmsg'), 80))


def notify(user, source, test=False):
    try:
        cfg = load_config()
        keyword = clean(cfg.get('keyword', '服务器登录'), 80)
        name = clean(cfg.get('server') or socket.gethostname(), 80)
        entries = cfg.get('trusted_ips', [])
        if not isinstance(entries, list): entries = []
        ip, verdict, label = classify(source, entries)
        geo = fetch_geo(ip) if cfg.get('geo_enabled', True) and not test else {
            'location': '未查询（测试或配置关闭）', 'isp': '未查询', 'asn': '未查询'}
        now = datetime.now(BEIJING).strftime('%Y-%m-%d %H:%M:%S')
        if test:
            verdict = '🧪 测试消息（不代表真实 SSH 登录）'
        body = (f'【{keyword}】{"🧪 安装测试" if test else "🔐 SSH 登录成功"}\n'
                f'🖥 服务器：{name}\n'
                f'👤 登录账户：{clean(user)}\n'
                f'🌐 来源 IP：{clean(source)}\n'
                f'🧭 归属地：{clean(geo["location"], 180)}\n'
                f'🏢 运营商：{clean(geo["isp"])}\n'
                f'🔢 ASN：{clean(geo["asn"])}\n'
                f'🛡 来源判断：{verdict}\n'
                + (f'🏷 白名单备注：{label}\n' if label else '')
                + (('💡 提示：尚未设置常用 IP，请先添加白名单。\n') if not entries and not test else '')
                + f'🕒 登录时间：{now}（北京时间）')
        send_to_dingtalk(cfg, body)
        return log(True, f'通知成功 server={name} user={clean(user)} src={clean(source)} trust={bool(label)}', test)
    except (OSError, ValueError, KeyError, TypeError, urllib.error.URLError, TimeoutError) as exc:
        # Do not log sensitive signed URLs or webhook, even on HTTPError.
        if isinstance(exc, urllib.error.HTTPError):
            desc = 'DingTalk HTTP status=' + str(exc.code)
        elif isinstance(exc, ValueError) and str(exc).startswith('DingTalk errcode='):
            desc = str(exc)
        else:
            desc = type(exc).__name__
        return log(False, '发送失败：' + desc, test)


def trust(args):
    if os.geteuid() != 0:
        print('需要 root 权限：sudo python3 /usr/local/sbin/ssh-login-dingtalk.py trust ...', file=sys.stderr)
        return 1
    cfg = load_config()
    entries = cfg.setdefault('trusted_ips', [])
    if not isinstance(entries, list):
        raise ValueError('trusted_ips 非列表')
    if args.action == 'list':
        if not entries: print('暂无可信 IP。请通过 trust add 添加。')
        for item in entries:
            print(f'- {item["network"]}  {clean(item.get("label", ""), 80)}' if isinstance(item, dict) else f'- {item}')
        return 0
    if args.action == 'add':
        network = str(normalize_network(args.network))
        label = clean(args.label or '我的常用网络', 40)
        entries[:] = [e for e in entries if (e.get('network') if isinstance(e,dict) else e) != network]
        entries.append({'network':network, 'label':label})
        save_config(cfg)
        print(f'已添加可信 IP/CIDR：{network}（{label}）')
        return 0
    if args.action == 'remove':
        network = str(normalize_network(args.network))
        before = len(entries)
        entries[:] = [e for e in entries if (e.get('network') if isinstance(e,dict) else e) != network]
        if len(entries) == before:
            print(f'未找到：{network}')
            return 1
        save_config(cfg)
        print(f'已移除：{network}')
        return 0
    if args.action == 'check':
        ip, verdict, label = classify(args.network, entries)
        print(f'{ip or args.network}：{verdict}' + (f'（{label}）' if label else ''))
        return 0
    return 1


def main():
    p = argparse.ArgumentParser(description='SSH 登录钉钉通知；常用 IP 只保存在服务器本地')
    sub = p.add_subparsers(dest='command', required=True)
    alert = sub.add_parser('notify', help='PAM 登录事件发送，通常无需手工调用')
    alert.add_argument('--user', required=True)
    alert.add_argument('--ip', required=True)
    sub.add_parser('test', help='发送一条测试钉钉消息')
    geo = sub.add_parser('geo', help='控制是否向第三方查询公网 IP 归属地')
    geo.add_argument('state', choices=('on', 'off'))
    t = sub.add_parser('trust', help='管理服务器本地 IP 白名单')
    t.add_argument('action', choices=('add','remove','list','check'))
    t.add_argument('network', nargs='?', help='IPv4/IPv6 地址或 CIDR')
    t.add_argument('label', nargs='?', help='备注：办公室 / 家庭 / Tailscale')
    args = p.parse_args()
    if args.command == 'test':
        return notify('测试账号', '198.51.100.10', True)
    if args.command == 'notify':
        return notify(args.user, args.ip)
    if args.command == 'geo':
        if os.geteuid() != 0:
            p.error('geo on/off 需要 sudo/root 权限')
        cfg = load_config()
        cfg['geo_enabled'] = args.state == 'on'
        save_config(cfg)
        print('IP 归属地查询已' + ('开启' if cfg['geo_enabled'] else '关闭'))
        return 0
    if args.action in ('add','remove','check') and not args.network:
        p.error('trust ' + args.action + ' 需要填写 IP 或 CIDR')
    try:
        return trust(args)
    except (OSError, ValueError, KeyError) as exc:
        print('可信 IP 操作失败：' + type(exc).__name__ + ' ' + clean(exc, 150), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
PYTHON

cat > "$HOOK" <<'SH'
#!/bin/sh
# pam_exec calls this as root at SSH session open; never block the SSH login.
[ "${PAM_TYPE:-}" = 'open_session' ] || exit 0
[ "${PAM_SERVICE:-}" = 'sshd' ] || exit 0
/usr/bin/nohup /usr/bin/python3 /usr/local/sbin/ssh-login-dingtalk.py \
  notify --user "${PAM_USER:-未知}" --ip "${PAM_RHOST:-未知}" \
  </dev/null >/dev/null 2>&1 &
exit 0
SH
chmod 0755 "$SENDER" "$HOOK"
python3 -m py_compile "$SENDER"

if ! grep -Fxq "$PAM_RULE" "$PAM"; then
  cp -a "$PAM" "$BACKUP_DIR/sshd.before-install.$STAMP"
  printf '\n# DingTalk SSH login alerts\n%s\n' "$PAM_RULE" >> "$PAM"
  echo "PAM 已备份：$BACKUP_DIR/sshd.before-install.$STAMP"
else
  echo 'SSH PAM 钩子已存在：本次只更新通知脚本，没有重复插入。'
fi

printf '\n=== 初始可信 IP 白名单（可留空） ===\n'
read -r -p '添加一个常用 IP/CIDR（留空跳过）：' INITIAL_IP </dev/tty
if [ -n "${INITIAL_IP// /}" ]; then
  read -r -p '为这个 IP 写一个备注（例如：公司电脑）：' INITIAL_LABEL </dev/tty
  python3 "$SENDER" trust add "$INITIAL_IP" "${INITIAL_LABEL:-常用网络}" || echo 'IP 格式有误，请之后通过 trust add 重试。'
fi

printf '\n=== 安装完成：测试钉钉通知 ===\n'
if ! python3 "$SENDER" test; then
  echo '测试通知未成功，请检查 Webhook、加签或网络；SSH 登录不受影响。'
fi
cat <<'MSG'

请保留当前 SSH 窗口，再开一个新的 ZeeTerm SSH 窗口测试实际登录。
查看发送记录：sudo journalctl -t ssh-login-dingtalk -n 30 --no-pager
添加可信 IP：sudo python3 /usr/local/sbin/ssh-login-dingtalk.py trust add 203.0.113.10 "公司网络"
查看白名单：sudo python3 /usr/local/sbin/ssh-login-dingtalk.py trust list
移除可信 IP：sudo python3 /usr/local/sbin/ssh-login-dingtalk.py trust remove 203.0.113.10
查询某 IP 是否可信：sudo python3 /usr/local/sbin/ssh-login-dingtalk.py trust check 203.0.113.10
关闭第三方 IP 归属地查询：sudo python3 /usr/local/sbin/ssh-login-dingtalk.py geo off
MSG
