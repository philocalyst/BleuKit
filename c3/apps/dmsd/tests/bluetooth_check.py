#!/usr/bin/env python3
"""Checks of dmsd's `bluetooth` module, driven the way the DMS shell drives it.

    bluetooth_check.py <socket> <tests dir>

tests/bluetooth.sh starts dmsd on a private system bus where two mocks run: logind
(mock_logind.py, so the handshake shows the module order) and BlueZ, the mock that
libs/bleu_bluetooth.c3l/tests/mock_bluez.py provides (read here, not copied). The BlueZ
mock's devices:

* 01 headset (AA:BB:CC:DD:EE:01): Pair asks the agent to confirm 123456, then pairs.
* 02 mouse (AA:BB:CC:DD:EE:02, found by discovery): Pair asks for a PIN and accepts 4321 only.
* 03 keyboard (AA:BB:CC:DD:EE:03): Pair waits for CancelPairing and asks nothing.
* 04 phone (AA:BB:CC:DD:EE:04): Pair asks for a passkey; Connect fails.

Each check prints "ok" or "FAIL" on one line. The exit status is 1 when a check failed.
Uses tests/dmsclient.py. The field order is checked against golden/bluetooth_go_tags.json,
which is extracted from DMS's Go structs.
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dmsclient import DmsClient  # noqa: E402

SOCK, TESTS = sys.argv[1], sys.argv[2]
GOLDEN = os.path.join(TESTS, 'golden')
with open(os.path.join(GOLDEN, 'bluetooth_go_tags.json')) as f:
    TAGS = json.load(f)['structs']
with open(os.path.join(GOLDEN, 'bluetooth_state_initial.json')) as f:
    INITIAL_STATE = f.read().strip()

ADAPTER = '00:1A:7D:DA:71:13'
HEADSET, MOUSE, KEYBOARD, PHONE = ('AA:BB:CC:DD:EE:01', 'AA:BB:CC:DD:EE:02',
                                   'AA:BB:CC:DD:EE:03', 'AA:BB:CC:DD:EE:04')
HEADSET_PATH = '/org/bluez/hci0/dev_AA_BB_CC_DD_EE_01'
WAIT = 5.0  # seconds a state change may take to appear

failures = 0


def check(ok, what):
    global failures
    if ok:
        print('ok   ' + what)
    else:
        failures += 1
        print('FAIL ' + what)


def keys_ok(obj, struct):
    """The keys of `obj` are the Go tags of `struct`, in order; omitempty tags only when present."""
    tags = TAGS[struct]['tags']
    omit = TAGS[struct].get('omitempty', [])
    want = [t for t in tags if t not in omit or t in obj]
    return list(obj.keys()) == want


class Replies:
    """Requests on one connection. A reply that comes before the one asked for is kept, not dropped."""

    def __init__(self, client):
        self.client = client
        self.kept = {}

    def send(self, method, params=None):
        req_id = self.client.next_id()
        obj = {'id': req_id, 'method': method}
        if params is not None:
            obj['params'] = params
        self.client.requests.send(obj)
        return req_id

    def reply(self, req_id):
        if req_id in self.kept:
            return self.kept.pop(req_id)
        while True:
            obj = self.client.requests.read()
            if obj.get('id') == req_id:
                return obj
            if 'id' in obj:
                self.kept[obj['id']] = obj

    def call(self, method, params=None):
        return self.reply(self.send(method, params))


def next_frame(sub, service):
    """The data of the next frame of `service` on a subscription, or None after WAIT seconds."""
    deadline = time.time() + WAIT
    while time.time() < deadline:
        name, data, _ = sub.next_frame()
        if name == service:
            return data
    return None


def wait_state(p, predicate):
    """The state, once `predicate` holds for it, or None after WAIT seconds."""
    deadline = time.time() + WAIT
    while True:
        state = p.call('bluetooth.getState')['result']
        if predicate(state):
            return state
        if time.time() > deadline:
            return None
        time.sleep(0.1)


def device(state, address):
    return next((d for d in state['devices'] if d['address'] == address), None)


def is_(state, address, key, value):
    d = device(state, address)
    return d is not None and d[key] == value


def open_prompts():
    """A subscription to `bluetooth.pairing`, with its first frame read, so the subscription is in place."""
    sub = DmsClient(SOCK)
    sub.subscribe(['bluetooth.pairing'])
    name, _, _ = sub.next_frame()
    assert name == 'server', name
    return sub


def pair_with_prompt(p, prompts, device_arg):
    """Start a pairing and return (its reply id, the prompt the shell receives)."""
    pair_id = p.send('bluetooth.pair', {'device': device_arg})
    return pair_id, next_frame(prompts, 'bluetooth.pairing')


main = DmsClient(SOCK)
p = Replies(main)

# --- handshake and state -------------------------------------------------------------
caps = main.requests.handshake['capabilities']
# Other modules may advertise too; the three here keep DMS's order (server.go getCapabilities).
ordered = [c for c in caps if c in ('loginctl', 'bluetooth', 'brightness')]
check(ordered == ['loginctl', 'bluetooth', 'brightness'],
      'handshake lists bluetooth between loginctl and brightness: %s' % caps)
check(p.call('getServerInfo')['result']['capabilities'] == caps,
      'getServerInfo lists the same capabilities')

state = p.call('bluetooth.getState')['result']
check(json.dumps(state, separators=(',', ':')) == INITIAL_STATE,
      'getState at start matches golden/bluetooth_state_initial.json')
check(keys_ok(state, 'BluetoothState') and keys_ok(state['adapters'][0], 'AdapterInfo')
      and keys_ok(state['devices'][0], 'Device'),
      'BluetoothState, AdapterInfo and Device keys follow the DMS Go tags, in order')

# --- power ----------------------------------------------------------------------------
r = p.call('bluetooth.setPowered', {'powered': True})
check(r.get('result') == {'success': True, 'message': 'powered state updated'},
      'setPowered is answered with the DMS success result')
check(wait_state(p, lambda s: s['powered']) is not None, 'the powered state reaches getState')
r = p.call('bluetooth.togglePowered', {})
check(r.get('result') == {'success': True, 'powered': False},
      'togglePowered turns the radio off and answers PoweredResult')
check(wait_state(p, lambda s: not s['powered']) is not None, 'togglePowered takes effect in the state')
r = p.call('bluetooth.togglePowered', {})
check(r.get('result') == {'success': True, 'powered': True}, 'togglePowered turns it on again')
check(wait_state(p, lambda s: s['powered']) is not None, 'the radio is on for the rest of the checks')
check(p.call('bluetooth.setPowered', {}).get('error') == "missing or invalid 'powered' parameter",
      'setPowered without `powered` gets the dankgo parameter error')
r = p.call('bluetooth.setPowered', {'powered': True, 'adapter': '11:22:33:44:55:66'})
check('error' in r and 'result' not in r, 'setPowered for an unknown adapter is refused')

# --- discovery -------------------------------------------------------------------------
r = p.call('bluetooth.startDiscovery', {})
check(r.get('result') == {'success': True, 'message': 'discovery started'}, 'startDiscovery is answered')
check(wait_state(p, lambda s: s['discovering'] and len(s['devices']) == 4) is not None,
      'discovery shows the four devices of the mock while it runs')
r = p.call('bluetooth.stopDiscovery', {})
check(r.get('result') == {'success': True, 'message': 'discovery stopped'}, 'stopDiscovery is answered')
check(wait_state(p, lambda s: not s['discovering']) is not None, 'discovery stops in the state')
check('error' in p.call('bluetooth.startDiscovery', {'adapter': '11:22:33:44:55:66'}),
      'startDiscovery for an unknown adapter is refused')

# --- pairing with a confirmation -------------------------------------------------------
prompts = open_prompts()
pair_id, prompt = pair_with_prompt(p, prompts, HEADSET_PATH)
check(prompt is not None and keys_ok(prompt, 'PairingPrompt'),
      'the pairing prompt carries the DMS keys in the Go order')
check(prompt is not None and prompt['deviceAddr'] == HEADSET and prompt['deviceName'] == 'Bleu Headset'
      and prompt['requestType'] == 'confirm' and prompt['fields'] == ['decision']
      and prompt['hints'] == ['123456'] and prompt['passkey'] == 123456 and prompt['devicePath'] == ''
      and prompt['token'].isdigit(),
      'the confirmation prompt names the device, the code 123456 and the decision field')
token = prompt['token']
r = p.call('bluetooth.pairing.submit', {'token': token, 'secrets': {'decision': 'yes'}, 'accept': True})
check(r.get('result') == {'success': True, 'message': 'pairing response submitted'},
      'pairing.submit is answered once the answer is handed to BlueZ')
r = p.reply(pair_id)
check(r.get('result') == {'success': True, 'message': 'pairing initiated'},
      'pair is answered when the pairing completes (not at the request)')
st = wait_state(p, lambda s: is_(s, HEADSET, 'paired', True) and is_(s, HEADSET, 'trusted', True)
                and is_(s, HEADSET, 'connected', True))
check(st is not None, 'after pairing the headset is paired, trusted and connected (DMS does that too)')
r = p.call('bluetooth.pairing.submit', {'token': '999999', 'accept': True})
check(r.get('error') == 'unknown or expired token: 999999', 'a token that names no prompt is refused as DMS does')

# --- pairing with a PIN ----------------------------------------------------------------
pair_id, prompt = pair_with_prompt(p, prompts, MOUSE)
check(prompt is not None and prompt['requestType'] == 'pin' and prompt['fields'] == ['pin']
      and prompt['hints'] == [] and 'passkey' not in prompt,
      'a PIN prompt asks for the pin field and carries no passkey')
p.call('bluetooth.pairing.submit', {'token': prompt['token'], 'secrets': {'pin': '0000'}, 'accept': True})
r = p.reply(pair_id)
check('error' in r and 'result' not in r, 'a wrong PIN fails the pairing with an error text')
check(not is_(p.call('bluetooth.getState')['result'], MOUSE, 'paired', True), 'the mouse is not paired after a wrong PIN')
pair_id, prompt = pair_with_prompt(p, prompts, MOUSE)
p.call('bluetooth.pairing.submit', {'token': prompt['token'], 'secrets': {'pin': '4321'}, 'accept': True})
r = p.reply(pair_id)
check(r.get('result') == {'success': True, 'message': 'pairing initiated'}, 'the right PIN completes the pairing')
check(wait_state(p, lambda s: is_(s, MOUSE, 'paired', True)) is not None, 'the mouse is paired')

# --- pairing with a passkey, refused and then accepted ---------------------------------
pair_id, prompt = pair_with_prompt(p, prompts, PHONE)
check(prompt is not None and prompt['requestType'] == 'passkey' and prompt['fields'] == ['passkey'],
      'a passkey prompt asks for the passkey field')
r = p.call('bluetooth.pairing.cancel', {'token': prompt['token']})
check(r.get('result') == {'success': True, 'message': 'pairing cancelled'}, 'pairing.cancel is answered')
r = p.reply(pair_id)
check('error' in r and 'result' not in r, 'a cancelled prompt fails the pairing with an error text')
check(p.call('bluetooth.pairing.cancel', {'token': prompt['token']}).get('error')
      == 'unknown or expired token: %s' % prompt['token'], 'a cancelled prompt cannot be cancelled again')
pair_id, prompt = pair_with_prompt(p, prompts, PHONE)
p.call('bluetooth.pairing.submit', {'token': prompt['token'], 'secrets': {'passkey': '123456'}, 'accept': True})
r = p.reply(pair_id)
check(r.get('result') == {'success': True, 'message': 'pairing initiated'}, 'an accepted passkey completes the pairing')
check(wait_state(p, lambda s: is_(s, PHONE, 'paired', True)) is not None, 'the phone is paired')

# --- connect, disconnect, trust ---------------------------------------------------------
r = p.call('bluetooth.disconnect', {'device': HEADSET})
check(r.get('result') == {'success': True, 'message': 'disconnected'}, 'disconnect is answered')
check(wait_state(p, lambda s: is_(s, HEADSET, 'connected', False)) is not None, 'disconnect shows in the state')
r = p.call('bluetooth.connect', {'device': HEADSET_PATH})
check(r.get('result') == {'success': True, 'message': 'connecting'},
      'connect takes a BlueZ object path, as DMS does')
check(wait_state(p, lambda s: is_(s, HEADSET, 'connected', True)) is not None, 'connect shows in the state')
r = p.call('bluetooth.untrust', {'device': HEADSET})
check(r.get('result') == {'success': True, 'message': 'device untrusted'}, 'untrust is answered')
check(wait_state(p, lambda s: is_(s, HEADSET, 'trusted', False)) is not None, 'untrust shows in the state')
r = p.call('bluetooth.trust', {'device': HEADSET})
check(r.get('result') == {'success': True, 'message': 'device trusted'}, 'trust is answered')
check(wait_state(p, lambda s: is_(s, HEADSET, 'trusted', True)) is not None, 'trust shows in the state')
check(p.call('bluetooth.connect', {}).get('error') == "missing or invalid 'device' parameter",
      'connect without `device` gets the dankgo parameter error')
check(p.call('bluetooth.remove', {'device': '/org/bluez/hci0/dev_ZZ'}).get('error')
      == 'invalid device path: /org/bluez/hci0/dev_ZZ', 'a device path that names no address is refused')

# --- remove ----------------------------------------------------------------------------
r = p.call('bluetooth.remove', {'device': MOUSE})
check(r.get('result') == {'success': True, 'message': 'device removed'}, 'remove is answered')
check(wait_state(p, lambda s: device(s, MOUSE) is None) is not None, 'the removed device leaves the state')

# --- methods Bleu cannot serve ---------------------------------------------------------
r = p.call('bluetooth.mpris.publish', {'lease': 'x'})
check(r.get('error', '').startswith('not supported: Bleu cannot export an MPRIS player'),
      'mpris.publish answers not supported, with the reason')
r = p.call('bluetooth.subscribe', {})
check(r.get('error', '').startswith('not supported: a streaming method')
      and 'subscribe with services' in r.get('error', ''), 'bluetooth.subscribe answers not supported and says what to use')

# --- the state topic -------------------------------------------------------------------
sub = DmsClient(SOCK)
sub.subscribe(['bluetooth'])
name, _, _ = sub.next_frame()
snapshot = next_frame(sub, 'bluetooth')
check(snapshot == p.call('bluetooth.getState')['result'], 'a bluetooth subscription starts with the current state')
p.call('bluetooth.setPowered', {'powered': False})
published = None
deadline = time.time() + WAIT
while published is None and time.time() < deadline:
    data = next_frame(sub, 'bluetooth')
    if data is not None and data['powered'] is False:
        published = data
check(published is not None, 'a change of power is published on the bluetooth topic')
p.call('bluetooth.setPowered', {'powered': True})

# --- a pairing left waiting, so that dmsd's shutdown can be checked with one in flight -----
p.send('bluetooth.pair', {'device': KEYBOARD})

for client in (sub, prompts, main):
    client.close()
print('bluetooth checks: %d failed' % failures)
sys.exit(1 if failures else 0)
