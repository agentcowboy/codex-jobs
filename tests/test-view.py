#!/usr/bin/env python3
import errno
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
loader = importlib.machinery.SourceFileLoader('job_view', str(ROOT/'bin/codex-view'))
spec = importlib.util.spec_from_loader(loader.name, loader)
view = importlib.util.module_from_spec(spec)
loader.exec_module(view)


def event(kind, **kwargs):
    return (json.dumps(dict(type=kind, **kwargs))+'\n').encode()


class ViewTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.path = self.root/'log'
        self.f = view.Follower(str(self.path))

    def write(self, value):
        self.path.write_bytes(value)
        self.f.refresh()

    def descriptor(self):
        with open('/proc/{}/stat'.format(os.getpid())) as f:
            start = view.pid_start(f.read())
        with open('/proc/sys/kernel/random/boot_id') as f:
            boot = f.read().strip()
        return dict(schema=1, job_id='demo', model='demo-model', effort='high',
                    started_at='2026-10-03T00:00:00Z', pid=os.getpid(), pid_start=start,
                    boot_id=boot, runlog=str(self.path), session_id=None)

    def test_failure_visible_after_success(self):
        self.write(event('turn.failed', error={'message':'turn failure'}) +
                   event('error', message='earlier error') + event('turn.completed'))
        self.assertTrue(self.f.failed)
        self.assertEqual(self.f.status, 'completed (earlier error)')
        v = view.View(log=str(self.path)); v.refresh()
        console = view.Console(file=io.StringIO(), width=80, height=24, force_terminal=False)
        console.print(v.render(80,24))
        output = console.file.getvalue()
        self.assertIn('turn failure', output)
        self.assertIn('earlier error', output)

    def test_null_failure_shows_unknown_error(self):
        self.write(event('turn.failed', error=None))
        self.assertEqual(self.f.status, 'failed')
        self.assertIn('turn.failed: unknown error', self.f.detail)

    def test_command_output_omitted(self):
        self.write(event('item.completed', item=dict(id='a', type='command_execution',
                         command='echo visible-command', aggregated_output='hidden-body')))
        self.assertIn('visible-command', '\n'.join(self.f.detail))
        self.assertNotIn('hidden-body', '\n'.join(self.f.detail))
        self.assertIn('output omitted', '\n'.join(self.f.detail))

    def test_split_and_eof(self):
        full = event('turn.completed')
        self.write(full[:10]); self.assertEqual(self.f.status, 'waiting')
        with self.path.open('ab') as f: f.write(full[10:-1])
        self.f.refresh(); self.assertEqual(self.f.status, 'waiting')
        with self.path.open('ab') as f: f.write(b'\n')
        self.f.refresh(); self.assertEqual(self.f.status, 'completed')

    def test_oversized_record_recovers(self):
        self.write(b'x'*(view.RECORD_CAP+1)+b'\n'+event('turn.completed'))
        self.assertIn('[record truncated]', self.f.detail)
        self.assertEqual(self.f.status, 'completed')
        self.assertLessEqual(len(self.f.partial),view.RECORD_CAP)

    def test_unterminated_record_recovers(self):
        self.write(b'x'*view.READ_CAP)
        self.assertTrue(self.f.discard)
        self.assertEqual(self.f.partial,b'')
        with self.path.open('ab') as f: f.write(b'more\n'+event('turn.completed'))
        self.f.refresh(); self.assertEqual(self.f.status,'completed')
        self.assertEqual(list(self.f.detail).count('[record truncated]'),1)

    def test_read_budget(self):
        self.write(b'\n'*(view.READ_CAP*2+1))
        self.assertEqual(self.f.bytes_read,view.READ_CAP)
        self.assertEqual(self.f.offset,view.READ_CAP)
        self.f.refresh(); self.assertEqual(self.f.bytes_read,view.READ_CAP)
        self.f.refresh(); self.assertEqual(self.f.bytes_read,1)

    def test_detail_budget(self):
        self.write(b''.join(event('item.completed', item=dict(id=str(i),type='agent_message',text=str(i))) for i in range(230)))
        self.assertEqual(len(self.f.detail),200)
        self.assertEqual(self.f.detail[0],'agent_message: 30')
        self.assertEqual(self.f.detail[-1],'agent_message: 229')

    def test_inflight_budget(self):
        self.write(b''.join(event('item.started', item=dict(id=str(i),type='command_execution')) for i in range(300)))
        self.assertEqual(len(self.f.inflight),256)
        self.assertEqual(self.f.evicted,44)
        self.assertEqual(next(iter(self.f.inflight)),'44')
        self.f.feed(event('item.completed',item=dict(id='299',type='command_execution')))
        self.assertNotIn('299',self.f.inflight)

    def test_truncation(self):
        self.write(event('error',message='previous failure')+event('item.started',item=dict(id='a',type='agent_message',text='long text')))
        self.assertTrue(self.f.failed)
        self.path.write_bytes(event('turn.completed')); self.f.refresh()
        self.assertEqual(self.f.status,'completed')
        self.assertFalse(self.f.inflight)
        self.assertFalse(self.f.failed)
        self.assertIn('[log replaced or truncated]',self.f.detail)

    def test_replacement(self):
        self.write(event('error',message='previous failure')+b'partial')
        self.assertTrue(self.f.failed)
        other=self.root/'new'; other.write_bytes(event('turn.completed'))
        os.replace(str(other),str(self.path)); self.f.refresh()
        self.assertEqual(self.f.status,'completed')
        self.assertEqual(self.f.partial,b'')
        self.assertFalse(self.f.failed)

    def test_malformed_records(self):
        self.write(b'invalid\n[]\n'+event('item.completed',item='bad')+event('turn.completed'))
        self.assertIn('[malformed record]',self.f.detail)
        self.assertIn('[malformed item]',self.f.detail)
        self.assertEqual(self.f.status,'completed')
        self.assertEqual(self.f.input_state,'malformed')

    def test_input_states(self):
        self.f.refresh(); self.assertEqual(self.f.input_state,'unavailable')
        self.write(b''); self.assertEqual(self.f.input_state,'empty')
        with patch('builtins.open',side_effect=PermissionError()): self.f.refresh()
        self.assertEqual(self.f.input_state,'unreadable')
        self.assertEqual(self.f.status,'waiting')

    def test_unreadable_inputs_and_vanished_descriptor(self):
        for path in ('bad\x00path', 'bad\ud800path'):
            with self.subTest(path=repr(path)):
                follower=view.Follower(path)
                try:
                    follower.refresh()
                except (ValueError, UnicodeError):
                    self.fail('path error escaped refresh')
                self.assertEqual(follower.input_state,'unreadable')
        descriptor=self.root/'vanished.json'
        descriptor.write_text(json.dumps(self.descriptor()))
        entries=list(os.scandir(self.root))
        descriptor.unlink()
        with patch.object(view.os,'scandir',return_value=entries):
            self.assertEqual(view.roster(str(self.root)),('empty',[]))
        descriptor.symlink_to(self.root/'absent')
        self.assertEqual(view.roster(str(self.root))[1][0]['state'],'unreadable')

    def test_registry_states(self):
        self.assertEqual(view.roster(str(self.root/'absent'))[0],'unavailable')
        self.assertEqual(view.roster(str(self.root))[0],'empty')
        with patch.object(view.os,'scandir',side_effect=PermissionError()):
            self.assertEqual(view.roster(str(self.root))[0],'unreadable')

    def test_registry_bad_entries(self):
        (self.root/'bad.json').write_text('{')
        state,jobs=view.roster(str(self.root))
        self.assertEqual(state,'available'); self.assertEqual(jobs[0]['state'],'malformed')
        (self.root/'bad.json').write_text(json.dumps(self.descriptor()))
        real_open=open
        def denied(path,*args,**kwargs):
            if str(path).endswith('bad.json'): raise PermissionError()
            return real_open(path,*args,**kwargs)
        with patch('builtins.open',side_effect=denied):
            self.assertEqual(view.roster(str(self.root))[1][0]['state'],'unreadable')

    def test_fifo_descriptor(self):
        os.mkfifo(str(self.root/'fifo.json'))
        result=subprocess.run([str(ROOT/'bin/codex-view'),'--once','--registry',str(self.root)],
                              stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=2)
        self.assertEqual(result.returncode,0,result.stderr.decode())
        self.assertIn(b'fifo.json',result.stdout)
        self.assertIn(b'malformed',result.stdout)

    def test_fifo_log(self):
        os.mkfifo(str(self.path))
        result=subprocess.run([str(ROOT/'bin/codex-view'),'--once','--log',str(self.path)],
                              stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=2)
        self.assertEqual(result.returncode,0,result.stderr.decode())
        self.assertIn(b'unreadable',result.stdout)
        # Registry-selected logs use the same guard as explicit logs.
        (self.root/'demo.json').write_text(json.dumps(self.descriptor()))
        result=subprocess.run([str(ROOT/'bin/codex-view'),'--once','--registry',str(self.root)],
                              stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=2)
        self.assertEqual(result.returncode,0,result.stderr.decode())
        self.assertIn(b'unreadable',result.stdout)

    def test_fifo_rejected_before_open(self):
        os.mkfifo(str(self.path))
        os.mkfifo(str(self.root/'fifo.json'))
        with patch('builtins.open',wraps=open) as builtin_open, \
             patch.object(view.os,'open',wraps=os.open) as raw_open:
            self.f.refresh()
            self.assertEqual(self.f.input_state,'unreadable')
            self.assertEqual(view.roster(str(self.root))[1][0]['state'],'malformed')
            builtin_open.assert_not_called()
            raw_open.assert_not_called()

    def test_registry_deeply_nested(self):
        (self.root/'deep.json').write_text('['*1100+'0'+']'*1100)
        state,jobs=view.roster(str(self.root))
        self.assertEqual(state,'available')
        self.assertEqual(jobs[0]['state'],'malformed')
        result=subprocess.run([str(ROOT/'bin/codex-view'),'--once','--registry',str(self.root)],
                              stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        self.assertEqual(result.returncode,0,result.stderr.decode())
        self.assertIn(b'malformed',result.stdout)

    def test_identity_stale(self):
        data=self.descriptor(); self.assertEqual(view.identity(data),'active')
        data['pid_start']+=1; self.assertEqual(view.identity(data),'stale')
        data=self.descriptor(); data['boot_id']='different-boot'
        self.assertEqual(view.identity(data),'stale')
        data=self.descriptor()
        real_open=open
        def missing_stat(path,*args,**kwargs):
            if str(path).endswith('/stat'): raise FileNotFoundError(errno.ENOENT,'missing')
            return real_open(path,*args,**kwargs)
        with patch('builtins.open',side_effect=missing_stat):
            self.assertEqual(view.identity(data),'stale')

    def descriptor_cached(self):
        return dict(pid=os.getpid(),pid_start=1,boot_id='demo-boot')

    def test_identity_unreadable_unknown(self):
        with patch('builtins.open',side_effect=FileNotFoundError(errno.ENOENT,'missing')):
            self.assertEqual(view.identity(self.descriptor_cached()),'unknown')
        with patch('builtins.open',side_effect=PermissionError(errno.EACCES,'denied')):
            self.assertEqual(view.identity(self.descriptor_cached()),'unknown')

    def test_proc_parser(self):
        fields=['S']+['0']*18+['2468']+['0']*5
        self.assertEqual(view.pid_start('123 (name with ) spaces) '+' '.join(fields)),2468)

    def test_focus_stable(self):
        first=self.descriptor(); second=dict(first,job_id='second')
        v=view.View(directory=str(self.root))
        with patch.object(view,'roster',return_value=('available',[first,second])):
            v.refresh(); v.move(1); self.assertEqual(v.focus,'second')
        with patch.object(view,'roster',return_value=('available',[second,first])):
            v.refresh(); self.assertEqual(v.focus,'second')
        with patch.object(view,'roster',return_value=('empty',[])):
            v.refresh(); self.assertIsNone(v.focus); self.assertFalse(v.followers)

    def test_cropping(self):
        self.write(event('error',message='a'*200))
        v=view.View(log=str(self.path)); v.refresh()
        for width,height in ((1,1),(12,5),(80,24)):
            text=v.render(width,height).plain
            self.assertLessEqual(len(text.splitlines()),height)
            self.assertTrue(all(len(line)<=width for line in text.splitlines()))

    def test_real_cli_failure_render(self):
        self.path.write_bytes(event('error',message='visible failure'))
        result=subprocess.run([str(ROOT/'bin/codex-view'),'--once','--log',str(self.path)],
                              stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=dict(os.environ,COLUMNS='100'))
        self.assertEqual(result.returncode,0,result.stderr.decode())
        self.assertIn(b'visible failure',result.stdout)
        self.assertIn(b'failed',result.stdout)
        self.assertNotIn(b'boot_id',result.stdout)

    def test_log_and_registry_are_exclusive(self):
        result=subprocess.run([sys.executable,str(ROOT/'bin/codex-view'),'--once','--log',str(self.path),
                               '--registry',str(self.root)],stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE)
        self.assertEqual(result.returncode,2)
        self.assertIn(b'not allowed with argument',result.stderr)

    def test_control_characters_sanitized(self):
        controls=''.join(chr(i) for i in list(range(32))+list(range(127,160)))
        self.write(event('item.completed',item=dict(id='a',type='agent_message',
                         text='prefix'+controls+'suffix\x1b[2J')))
        v=view.View(log=str(self.path)); v.refresh()
        rendered=v.render(200,24)
        line=rendered.plain.splitlines()[-1]
        self.assertEqual(line,'agent_message: prefix'+' '*len(controls)+'suffix [2J')
        output=io.StringIO()
        view.Console(file=output,width=200,force_terminal=False).print(rendered)
        self.assertNotRegex(output.getvalue(),r'[\x00-\x09\x0b-\x1f\x7f-\x9f]')

    def test_registry_render_omits_boot_identity(self):
        self.path.write_bytes(event('turn.started'))
        data=self.descriptor()
        (self.root/'demo.json').write_text(json.dumps(data))
        v=view.View(directory=str(self.root)); v.refresh()
        self.assertEqual(v.state,'available')
        self.assertEqual(v.jobs[0]['state'],'active')
        output=io.StringIO()
        view.Console(file=output,width=100,height=24,force_terminal=False).print(v.render(100,24))
        rendered=output.getvalue()
        self.assertTrue('demo-model' in rendered,'registry model rendered')
        self.assertTrue('running' in rendered,'registry running state rendered')
        # Use boolean assertions so failures cannot print the identity value.
        self.assertTrue('boot_id' not in rendered,'identity field name omitted')
        self.assertTrue(data['boot_id'] not in rendered,'identity value omitted')

    def test_missing_rich_fails(self):
        result=subprocess.run([sys.executable,'-S',str(ROOT/'bin/codex-view'),'--once'],
                              stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        self.assertNotEqual(result.returncode,0)
        self.assertIn(b'Rich is required',result.stderr)


if __name__ == '__main__':
    suite=unittest.defaultTestLoader.loadTestsFromTestCase(ViewTests)
    result=unittest.TextTestRunner(stream=sys.stderr,verbosity=1).run(suite)
    if result.testsRun != 30 or result.skipped or not result.wasSuccessful():
        sys.stderr.write('ASSERTION: viewer executed case count=30, zero failures/errors/skips required; actual={} skips={}\n'.format(result.testsRun,len(result.skipped)))
        sys.exit(1)
    print('VIEW cases={} passed={} failures=0 skips=0'.format(result.testsRun,result.testsRun))
