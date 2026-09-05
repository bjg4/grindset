"""Run the real guard loop against a compile-time fake pmset implementation."""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest

GUARD = str(Path('.build/guard-tests').resolve())


class GuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='grindset-test-', dir='/tmp')
        self.root = Path(self.temp.name)
        self.state = self.root / 'sleep'
        self.state.write_text('0')
        self.server = socket.socket(socket.AF_UNIX)
        self.server.bind(str(self.root / 'guard.sock'))
        self.server.listen(1)
        self.server.settimeout(5)
        self.child = None
        self.client = None

    def tearDown(self):
        if self.client:
            self.client.close()
        self.server.close()
        if self.child:
            try:
                self.child.wait(timeout=7)
            except subprocess.TimeoutExpired:
                self.child.kill()
                self.child.wait()
        self.temp.cleanup()

    def start(self, **environment):
        env = {**os.environ, 'GRINDSET_TEST_STATE': str(self.state), **environment}
        self.child = subprocess.Popen([GUARD, str(os.getpid()), str(os.getuid()), str(self.root/'guard.sock')], env=env)
        self.client, _ = self.server.accept()
        self.client.settimeout(7)
        self.reader = self.client.makefile('rb')
        return self.read()

    def read(self):
        return json.loads(self.reader.readline())

    def send(self, **message):
        self.client.sendall(json.dumps(message).encode() + b'\n')

    def restored(self, reason):
        message = self.read()
        while message['status'] == 'restoring':
            message = self.read()
        self.assertEqual(message, {'status': 'restored', 'reason': reason})
        self.child.wait(timeout=3)
        self.assertEqual(self.state.read_text(), '0')

    def test_explicit_stop(self):
        self.assertEqual(self.start()['status'], 'active')
        self.assertEqual(self.state.read_text(), '1')
        self.send(command='stop')
        self.restored('stopped')

    def test_deadline_is_enforced_without_app_timer(self):
        self.start()
        self.send(command='configure', deadline=time.time() - 1)
        self.restored('expired')

    def test_socket_loss_restores_sleep(self):
        self.start()
        self.reader.close()
        self.client.close()
        self.child.wait(timeout=4)
        self.assertEqual(self.state.read_text(), '0')

    def test_low_battery_is_enforced_in_guard(self):
        self.start(GRINDSET_TEST_BATTERY='9')
        self.restored('battery-low')

    def test_existing_external_override_is_preserved(self):
        self.state.write_text('1')
        self.assertEqual(self.start(), {'status': 'error', 'reason': 'sleep-already-disabled'})
        self.child.wait(timeout=3)
        self.assertEqual(self.state.read_text(), '1')

    def test_malformed_command_restores_sleep(self):
        self.start()
        self.client.sendall(b'not-json\n')
        self.restored('guard-error')

    def test_restore_is_retried_until_confirmed(self):
        self.start(GRINDSET_TEST_RESTORE_FAILURES='2')
        self.send(command='stop')
        self.assertEqual(self.read()['status'], 'restoring')
        self.assertEqual(self.state.read_text(), '1')
        self.restored('stopped')

    def test_helper_termination_signal_restores_sleep(self):
        self.start()
        self.child.send_signal(signal.SIGTERM)
        self.restored('app-exited')

    def test_parent_force_quit_restores_sleep(self):
        self.server.close()
        (self.root / 'guard.sock').unlink()
        program = '''import os,socket,subprocess,sys,json
s=socket.socket(socket.AF_UNIX);s.bind(sys.argv[1]);s.listen(1)
p=subprocess.Popen([sys.argv[2],str(os.getpid()),str(os.getuid()),sys.argv[1]])
c,_=s.accept();print(c.recv(4096).decode().strip(),flush=True)
while True: c.recv(4096)
'''
        parent = subprocess.Popen([sys.executable, '-c', program, str(self.root/'guard.sock'), GUARD],
            env={**os.environ, 'GRINDSET_TEST_STATE': str(self.state)}, stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(json.loads(parent.stdout.readline())['status'], 'active')
            parent.kill()
            parent.wait(timeout=3)
            deadline = time.monotonic() + 5
            while self.state.read_text() != '0' and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertEqual(self.state.read_text(), '0')
        finally:
            if parent.poll() is None:
                parent.kill()
            parent.wait()


if __name__ == '__main__':
    unittest.main()
